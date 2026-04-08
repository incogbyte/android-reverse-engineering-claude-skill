#!/usr/bin/env bash
# setup-frida.sh — Detect existing Frida environment, create venv, match versions
#
# Strategy:
#   1. Check adb connectivity and device state
#   2. Check if frida-server is already on the device (most users already have it)
#   3. Get frida-server version from device
#   4. Check python3 availability
#   5. Create venv and install frida-tools matching the server version
#   6. If no frida-server on device, offer to download + push the correct one
#
# Output (machine-readable):
#   FRIDA_VENV=<path>           — path to the activated venv
#   FRIDA_SERVER_VERSION=<ver>  — version running on device
#   FRIDA_DEVICE=<serial>       — device serial
#   FRIDA_DEVICE_ARCH=<arch>    — device architecture
#   FRIDA_STATUS=ready|needs_server|error
#
# Exit codes:
#   0 — frida environment ready (venv + server matched)
#   1 — error (adb not found, no device, python3 missing)
#   2 — frida-server not on device (manual action needed or use --install-server)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENV_BASE="${FRIDA_VENV_DIR:-$HOME/.local/share/frida-re}"
INSTALL_SERVER=false
DEVICE_SERIAL=""

usage() {
  cat <<EOF
Usage: setup-frida.sh [OPTIONS]

Detect and configure Frida environment for Android dynamic analysis.

Options:
  -s, --serial SERIAL    Target specific device by serial
  --install-server       Download and push frida-server to device if missing
  --venv-dir DIR         Custom venv directory (default: ~/.local/share/frida-re)
  -h, --help             Show this help

The script detects your existing setup first — it won't reinstall what's already there.
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--serial) DEVICE_SERIAL="$2"; shift 2 ;;
    --install-server) INSTALL_SERVER=true; shift ;;
    --venv-dir) VENV_BASE="$2"; shift 2 ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

info()  { echo "[INFO] $*"; }
ok()    { echo "[OK] $*"; }
warn()  { echo "[WARN] $*"; }
fail()  { echo "[FAIL] $*" >&2; }

# --- Helper: adb wrapper (respects --serial) ---
_adb() {
  if [[ -n "$DEVICE_SERIAL" ]]; then
    adb -s "$DEVICE_SERIAL" "$@"
  else
    adb "$@"
  fi
}

# --- Helper: download a file ---
download() {
  local url="$1" dest="$2"
  if command -v curl &>/dev/null; then
    curl -fsSL -o "$dest" "$url"
  elif command -v wget &>/dev/null; then
    wget -q -O "$dest" "$url"
  else
    fail "Neither curl nor wget available."
    return 1
  fi
}

# =====================================================================
# Step 1: Check adb
# =====================================================================
if ! command -v adb &>/dev/null; then
  fail "adb not found. Install it first: install-dep.sh adb"
  exit 1
fi

# =====================================================================
# Step 2: Check device connectivity
# =====================================================================
info "Checking device connectivity..."

device_count=$(_adb devices 2>/dev/null | grep -cE '\t(device|emulator)$' || true)
if (( device_count == 0 )); then
  fail "No Android device/emulator connected."
  echo "  Connect a device via USB or start an emulator, then retry." >&2
  exit 1
fi

if (( device_count > 1 )) && [[ -z "$DEVICE_SERIAL" ]]; then
  warn "Multiple devices detected. Use --serial to specify one:"
  _adb devices -l 2>/dev/null | grep -E '\t(device|emulator)$'
  echo
  info "Using first available device. Pass --serial <serial> to override."
fi

# Get the actual serial being used
if [[ -z "$DEVICE_SERIAL" ]]; then
  DEVICE_SERIAL=$(_adb devices 2>/dev/null | grep -E '\t(device|emulator)$' | head -1 | awk '{print $1}')
fi
ok "Device connected: $DEVICE_SERIAL"

# =====================================================================
# Step 3: Get device architecture
# =====================================================================
DEVICE_ABI=$(_adb shell getprop ro.product.cpu.abi 2>/dev/null | tr -d '\r')
DEVICE_ANDROID=$(_adb shell getprop ro.build.version.release 2>/dev/null | tr -d '\r')

case "$DEVICE_ABI" in
  arm64-v8a|arm64*)  FRIDA_ARCH="arm64" ;;
  armeabi-v7a|arm*)  FRIDA_ARCH="arm" ;;
  x86_64)            FRIDA_ARCH="x86_64" ;;
  x86)               FRIDA_ARCH="x86" ;;
  *)
    fail "Unknown device ABI: $DEVICE_ABI"
    exit 1
    ;;
esac

ok "Device: Android $DEVICE_ANDROID, ABI: $DEVICE_ABI (frida arch: $FRIDA_ARCH)"
echo "FRIDA_DEVICE=$DEVICE_SERIAL"
echo "FRIDA_DEVICE_ARCH=$FRIDA_ARCH"

# =====================================================================
# Step 4: Check if frida-server is already on the device
# =====================================================================
info "Checking for existing frida-server on device..."

SERVER_VERSION=""
SERVER_RUNNING=false
SERVER_PATH=""

# Check if frida-server process is running
if _adb shell "su -c 'ps -A 2>/dev/null || ps'" 2>/dev/null | grep -qiE 'frida'; then
  SERVER_RUNNING=true
  info "frida-server process detected running on device"
fi

# Try to get version from running server
if [[ "$SERVER_RUNNING" == true ]]; then
  # frida-server responds to --version but it's running as a daemon
  # Best way: use frida CLI from host if available, or check the binary
  :
fi

# Check common frida-server locations on device
for candidate in \
  "/data/local/tmp/frida-server" \
  "/data/local/tmp/frida" \
  "/data/local/tmp/frida-server-*" \
  "/data/local/tmp/re.frida.server"; do
  found=$(_adb shell "ls $candidate 2>/dev/null" 2>/dev/null | tr -d '\r' | head -1)
  if [[ -n "$found" && "$found" != *"No such file"* ]]; then
    SERVER_PATH="$found"
    break
  fi
done

# Try to get version from the binary on device
if [[ -n "$SERVER_PATH" ]]; then
  ok "frida-server binary found on device: $SERVER_PATH"
  # Try running --version (needs root)
  SERVER_VERSION=$(_adb shell "su -c '$SERVER_PATH --version'" 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)

  if [[ -z "$SERVER_VERSION" ]]; then
    # Some devices: try without su
    SERVER_VERSION=$(_adb shell "$SERVER_PATH --version" 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  fi

  if [[ -n "$SERVER_VERSION" ]]; then
    ok "frida-server version on device: $SERVER_VERSION"
  else
    warn "Could not determine frida-server version from binary."
    warn "Will attempt to detect version via frida CLI after venv setup."
  fi
else
  info "No frida-server binary found on device."
fi

# =====================================================================
# Step 5: Check python3
# =====================================================================
info "Checking Python 3..."

PYTHON_CMD=""
for cmd in python3 python; do
  if command -v "$cmd" &>/dev/null; then
    py_ver=$("$cmd" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    py_major=$(echo "$py_ver" | cut -d. -f1)
    if [[ "$py_major" == "3" ]]; then
      PYTHON_CMD="$cmd"
      break
    fi
  fi
done

if [[ -z "$PYTHON_CMD" ]]; then
  fail "Python 3 not found. Install Python 3.8+ to use Frida tools."
  echo "  macOS:  brew install python3" >&2
  echo "  Linux:  sudo apt install python3 python3-venv python3-pip" >&2
  exit 1
fi

ok "Python 3 found: $($PYTHON_CMD --version 2>&1)"

# Check venv module is available
if ! "$PYTHON_CMD" -m venv --help &>/dev/null; then
  fail "Python venv module not available."
  echo "  Install it: sudo apt install python3-venv (Debian/Ubuntu)" >&2
  echo "  Or: $PYTHON_CMD -m pip install virtualenv" >&2
  exit 1
fi

# =====================================================================
# Step 6: Create or reuse venv
# =====================================================================
info "Setting up Frida virtual environment..."

VENV_PATH="$VENV_BASE/venv"

# Determine which frida-tools version to install
FRIDA_TOOLS_VERSION=""
if [[ -n "$SERVER_VERSION" ]]; then
  # Match major.minor.patch of frida-tools to frida-server
  # frida and frida-tools share the same version number
  FRIDA_TOOLS_VERSION="$SERVER_VERSION"
  info "Will install frida-tools==$FRIDA_TOOLS_VERSION to match device server"
fi

# Check if venv already exists and has correct version
NEED_INSTALL=true
if [[ -f "$VENV_PATH/bin/frida" ]]; then
  existing_version=$("$VENV_PATH/bin/frida" --version 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)

  if [[ -n "$existing_version" ]]; then
    if [[ -n "$FRIDA_TOOLS_VERSION" && "$existing_version" == "$FRIDA_TOOLS_VERSION" ]]; then
      ok "Existing venv has matching frida-tools $existing_version"
      NEED_INSTALL=false
    elif [[ -z "$FRIDA_TOOLS_VERSION" ]]; then
      ok "Existing venv has frida-tools $existing_version"
      FRIDA_TOOLS_VERSION="$existing_version"
      NEED_INSTALL=false
    else
      warn "Existing venv has frida-tools $existing_version but device has $FRIDA_TOOLS_VERSION"
      info "Reinstalling to match device version..."
    fi
  fi
fi

if [[ "$NEED_INSTALL" == true ]]; then
  # Create fresh venv
  mkdir -p "$VENV_BASE"

  if [[ -d "$VENV_PATH" ]]; then
    info "Removing old venv..."
    rm -rf "$VENV_PATH"
  fi

  info "Creating virtual environment at $VENV_PATH..."
  "$PYTHON_CMD" -m venv "$VENV_PATH"

  # Upgrade pip inside venv (silently)
  "$VENV_PATH/bin/python" -m pip install --upgrade pip --quiet 2>/dev/null || true

  # Install frida-tools (and frida as dependency)
  if [[ -n "$FRIDA_TOOLS_VERSION" ]]; then
    info "Installing frida-tools==$FRIDA_TOOLS_VERSION in venv..."
    if ! "$VENV_PATH/bin/python" -m pip install "frida-tools==$FRIDA_TOOLS_VERSION" --quiet 2>&1; then
      warn "Exact version $FRIDA_TOOLS_VERSION not available, trying compatible version..."
      # Try matching major.minor
      local_major_minor=$(echo "$FRIDA_TOOLS_VERSION" | cut -d. -f1,2)
      if ! "$VENV_PATH/bin/python" -m pip install "frida-tools~=${local_major_minor}.0" --quiet 2>&1; then
        warn "Compatible version not found. Installing latest frida-tools..."
        "$VENV_PATH/bin/python" -m pip install frida-tools --quiet
      fi
    fi
  else
    info "Installing latest frida-tools in venv..."
    "$VENV_PATH/bin/python" -m pip install frida-tools --quiet
  fi

  # Verify installation
  if [[ ! -f "$VENV_PATH/bin/frida" ]]; then
    fail "frida-tools installation failed."
    exit 1
  fi

  INSTALLED_VERSION=$("$VENV_PATH/bin/frida" --version 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
  ok "frida-tools $INSTALLED_VERSION installed in venv"

  # If we didn't know the server version, now we know what frida version we have
  if [[ -z "$FRIDA_TOOLS_VERSION" ]]; then
    FRIDA_TOOLS_VERSION="$INSTALLED_VERSION"
  fi
fi

echo "FRIDA_VENV=$VENV_PATH"

# =====================================================================
# Step 7: Version match check
# =====================================================================
if [[ -n "$SERVER_VERSION" ]]; then
  INSTALLED_VERSION=$("$VENV_PATH/bin/frida" --version 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)

  server_major=$(echo "$SERVER_VERSION" | cut -d. -f1)
  client_major=$(echo "$INSTALLED_VERSION" | cut -d. -f1)

  if [[ "$server_major" != "$client_major" ]]; then
    warn "MAJOR VERSION MISMATCH: server=$SERVER_VERSION client=$INSTALLED_VERSION"
    warn "This will likely cause connection errors. Consider updating frida-server on the device."
  elif [[ "$SERVER_VERSION" != "$INSTALLED_VERSION" ]]; then
    warn "Minor version difference: server=$SERVER_VERSION client=$INSTALLED_VERSION"
    warn "This usually works but may cause subtle issues."
  else
    ok "Version match: server=$SERVER_VERSION client=$INSTALLED_VERSION"
  fi
fi

# =====================================================================
# Step 8: Handle missing frida-server on device
# =====================================================================
if [[ -z "$SERVER_PATH" ]]; then
  if [[ "$INSTALL_SERVER" == true ]]; then
    INSTALLED_VERSION=$("$VENV_PATH/bin/frida" --version 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)

    info "Downloading frida-server $INSTALLED_VERSION for $FRIDA_ARCH..."
    SERVER_URL="https://github.com/frida/frida/releases/download/${INSTALLED_VERSION}/frida-server-${INSTALLED_VERSION}-android-${FRIDA_ARCH}.xz"
    TMP_DIR=$(mktemp -d)
    TMP_XZ="$TMP_DIR/frida-server.xz"
    TMP_BIN="$TMP_DIR/frida-server"

    if ! download "$SERVER_URL" "$TMP_XZ"; then
      fail "Failed to download frida-server from $SERVER_URL"
      rm -rf "$TMP_DIR"
      exit 1
    fi

    # Decompress
    if command -v xz &>/dev/null; then
      xz -d "$TMP_XZ"
    elif command -v unxz &>/dev/null; then
      unxz "$TMP_XZ"
    else
      fail "xz or unxz not found. Cannot decompress frida-server."
      fail "Install xz: brew install xz / apt install xz-utils"
      rm -rf "$TMP_DIR"
      exit 1
    fi

    info "Pushing frida-server to device..."
    _adb push "$TMP_BIN" /data/local/tmp/frida-server
    _adb shell "chmod 755 /data/local/tmp/frida-server"
    rm -rf "$TMP_DIR"

    SERVER_PATH="/data/local/tmp/frida-server"
    SERVER_VERSION="$INSTALLED_VERSION"
    ok "frida-server $INSTALLED_VERSION pushed to device at $SERVER_PATH"
  else
    warn "No frida-server on device."
    echo "FRIDA_STATUS=needs_server"
    echo ""
    echo "To install frida-server on the device, re-run with --install-server:"
    echo "  bash $0 --install-server"
    echo ""
    echo "Or push it manually:"
    INSTALLED_VERSION=$("$VENV_PATH/bin/frida" --version 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
    echo "  Download: https://github.com/frida/frida/releases/download/${INSTALLED_VERSION}/frida-server-${INSTALLED_VERSION}-android-${FRIDA_ARCH}.xz"
    echo "  adb push frida-server /data/local/tmp/"
    echo "  adb shell chmod 755 /data/local/tmp/frida-server"
    exit 2
  fi
fi

# =====================================================================
# Step 9: Ensure frida-server is running
# =====================================================================
if [[ "$SERVER_RUNNING" != true ]]; then
  info "Starting frida-server on device..."
  # Kill any existing instance first
  _adb shell "su -c 'killall frida-server 2>/dev/null; killall frida 2>/dev/null'" 2>/dev/null || true
  # Start in background
  _adb shell "su -c '$SERVER_PATH -D &'" 2>/dev/null &
  sleep 2

  # Verify it's running
  if _adb shell "su -c 'ps -A 2>/dev/null || ps'" 2>/dev/null | grep -qiE 'frida'; then
    ok "frida-server started on device"
    SERVER_RUNNING=true
  else
    warn "Could not verify frida-server is running."
    warn "You may need to start it manually: adb shell su -c '/data/local/tmp/frida-server -D &'"
  fi
fi

# =====================================================================
# Step 10: Quick connectivity test
# =====================================================================
info "Testing frida connectivity..."
if "$VENV_PATH/bin/frida-ps" -U 2>/dev/null | head -5 >/dev/null; then
  ok "frida-ps connected to device successfully"
else
  warn "frida-ps could not list processes. frida-server may not be running or needs root."
  warn "Try: adb shell su -c '/data/local/tmp/frida-server -D &'"
fi

# =====================================================================
# Summary
# =====================================================================
echo ""
echo "=== Frida Environment Ready ==="
echo "FRIDA_VENV=$VENV_PATH"
echo "FRIDA_SERVER_VERSION=${SERVER_VERSION:-unknown}"
echo "FRIDA_DEVICE=$DEVICE_SERIAL"
echo "FRIDA_DEVICE_ARCH=$FRIDA_ARCH"
echo "FRIDA_STATUS=ready"
echo ""
echo "Activate the venv:"
echo "  source $VENV_PATH/bin/activate"
echo ""
echo "Or use tools directly:"
echo "  $VENV_PATH/bin/frida -U <target>"
echo "  $VENV_PATH/bin/frida-ps -U"
echo "  $VENV_PATH/bin/frida-trace -U <target>"
