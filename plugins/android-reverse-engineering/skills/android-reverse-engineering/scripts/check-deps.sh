#!/usr/bin/env bash
# check-deps.sh — Verify dependencies and report what's missing
# Output includes machine-readable INSTALL:<dep> lines for each missing dependency.
# The install-dep.sh script can install each one.
set -euo pipefail

REQUIRED_JAVA_MAJOR=17
errors=0
missing_required=()
missing_optional=()

echo "=== Android Reverse Engineering: Dependency Check ==="
echo

# --- Java ---
java_ok=false
if command -v java &>/dev/null; then
  java_version_output=$(java -version 2>&1 | head -1)
  java_version=$(echo "$java_version_output" | sed -n 's/.*"\([0-9]*\)\..*/\1/p')
  if [[ -z "$java_version" ]]; then
    java_version=$(echo "$java_version_output" | grep -oE '[0-9]+' | head -1)
  fi
  if [[ "$java_version" == "1" ]]; then
    java_version=$(echo "$java_version_output" | sed -n 's/.*"1\.\([0-9]*\)\..*/\1/p')
  fi

  if [[ -n "$java_version" ]] && (( java_version >= REQUIRED_JAVA_MAJOR )); then
    echo "[OK] Java $java_version detected"
    java_ok=true
  else
    echo "[WARN] Java detected but version $java_version is below $REQUIRED_JAVA_MAJOR"
    errors=$((errors + 1))
    missing_required+=("java")
  fi
else
  echo "[MISSING] Java is not installed or not in PATH"
  errors=$((errors + 1))
  missing_required+=("java")
fi

# --- jadx ---
if command -v jadx &>/dev/null; then
  jadx_version=$(jadx --version 2>/dev/null || echo "unknown")
  echo "[OK] jadx $jadx_version detected"
else
  echo "[MISSING] jadx is not installed or not in PATH"
  errors=$((errors + 1))
  missing_required+=("jadx")
fi

# --- Fernflower / Vineflower ---
ff_found=false
if command -v vineflower &>/dev/null; then
  echo "[OK] vineflower CLI detected"
  ff_found=true
elif command -v fernflower &>/dev/null; then
  echo "[OK] fernflower CLI detected"
  ff_found=true
else
  for candidate in \
    "${FERNFLOWER_JAR_PATH:-}" \
    "$HOME/.local/share/vineflower/vineflower.jar" \
    "$HOME/fernflower/build/libs/fernflower.jar" \
    "$HOME/vineflower/build/libs/vineflower.jar" \
    "$HOME/fernflower/fernflower.jar" \
    "$HOME/vineflower/vineflower.jar"; do
    if [[ -n "$candidate" ]] && [[ -f "$candidate" ]]; then
      echo "[OK] Fernflower/Vineflower JAR found: $candidate"
      ff_found=true
      break
    fi
  done
fi
if [[ "$ff_found" == false ]]; then
  echo "[MISSING] Fernflower/Vineflower not found (optional — better output on complex Java code)"
  missing_optional+=("vineflower")
fi

# --- dex2jar ---
if command -v d2j-dex2jar &>/dev/null || command -v d2j-dex2jar.sh &>/dev/null; then
  echo "[OK] dex2jar detected"
else
  echo "[MISSING] dex2jar not found (optional — needed to use Fernflower on APK/DEX files)"
  missing_optional+=("dex2jar")
fi

# --- Optional: bundletool ---
bt_found=false
if command -v bundletool &>/dev/null; then
  echo "[OK] bundletool detected (optional)"
  bt_found=true
else
  for candidate in \
    "${BUNDLETOOL_JAR_PATH:-}" \
    "$HOME/.local/share/bundletool/bundletool.jar" \
    "$HOME/bundletool/bundletool.jar"; do
    if [[ -n "$candidate" ]] && [[ -f "$candidate" ]]; then
      echo "[OK] bundletool JAR found: $candidate (optional)"
      bt_found=true
      break
    fi
  done
fi
if [[ "$bt_found" == false ]]; then
  echo "[MISSING] bundletool not found (optional — needed to decompile AAB files)"
  missing_optional+=("bundletool")
fi

# --- Optional: apktool ---
if command -v apktool &>/dev/null; then
  echo "[OK] apktool detected (optional)"
else
  echo "[MISSING] apktool not found (optional — useful for resource decoding)"
  missing_optional+=("apktool")
fi

# --- Optional: adb ---
if command -v adb &>/dev/null; then
  echo "[OK] adb detected (optional)"
else
  echo "[MISSING] adb not found (optional — useful for pulling APKs from devices)"
  missing_optional+=("adb")
fi

# --- Optional: Python 3 (needed for Frida) ---
python3_found=false
python3_cmd=""
for cmd in python3 python; do
  if command -v "$cmd" &>/dev/null; then
    py_ver=$("$cmd" --version 2>&1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
    py_major=$(echo "$py_ver" | cut -d. -f1)
    if [[ "$py_major" == "3" ]]; then
      python3_found=true
      python3_cmd="$cmd"
      echo "[OK] Python 3 detected: $($cmd --version 2>&1) (optional — needed for Frida)"
      # Check venv module
      if "$cmd" -m venv --help &>/dev/null; then
        echo "[OK] Python venv module available"
      else
        echo "[WARN] Python venv module not available — install python3-venv"
        missing_optional+=("python3-venv")
      fi
      break
    fi
  fi
done
if [[ "$python3_found" == false ]]; then
  echo "[MISSING] Python 3 not found (optional — needed for Frida tools)"
  missing_optional+=("python3")
fi

# --- Optional: Frida venv ---
frida_venv="${FRIDA_VENV_DIR:-$HOME/.local/share/frida-re}/venv"
if [[ -f "$frida_venv/bin/frida" ]]; then
  frida_ver=$("$frida_venv/bin/frida" --version 2>/dev/null | tr -d '\r' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "unknown")
  echo "[OK] Frida tools $frida_ver detected in venv ($frida_venv)"
else
  echo "[MISSING] Frida venv not found (optional — run setup-frida.sh for dynamic analysis)"
  missing_optional+=("frida")
fi

# --- Optional: Frida server on device (via adb) ---
if command -v adb &>/dev/null; then
  device_count=$(adb devices 2>/dev/null | grep -cE '\t(device|emulator)$' || true)
  if (( device_count > 0 )); then
    frida_server_running=false
    if adb shell "su -c 'ps -A 2>/dev/null || ps'" 2>/dev/null | grep -qiE 'frida'; then
      frida_server_running=true
    fi
    if [[ "$frida_server_running" == true ]]; then
      echo "[OK] frida-server process running on device"
    else
      # Check if binary exists even if not running
      frida_on_device=$(adb shell "ls /data/local/tmp/frida-server 2>/dev/null" 2>/dev/null | tr -d '\r' || true)
      if [[ -n "$frida_on_device" && "$frida_on_device" != *"No such file"* ]]; then
        echo "[OK] frida-server binary found on device (not running)"
      else
        echo "[MISSING] frida-server not found on device (optional — run setup-frida.sh --install-server)"
      fi
    fi
  fi
fi

# --- Machine-readable summary ---
echo
if [[ ${#missing_required[@]} -gt 0 ]]; then
  for dep in "${missing_required[@]}"; do
    echo "INSTALL_REQUIRED:$dep"
  done
fi
if [[ ${#missing_optional[@]} -gt 0 ]]; then
  for dep in "${missing_optional[@]}"; do
    echo "INSTALL_OPTIONAL:$dep"
  done
fi

echo
if (( errors > 0 )); then
  echo "*** ${#missing_required[@]} required dependency/ies missing. ***"
  echo "Run install-dep.sh <name> to install, or see references/setup-guide.md."
  exit 1
else
  if [[ ${#missing_optional[@]} -gt 0 ]]; then
    echo "Required dependencies OK. ${#missing_optional[@]} optional dependency/ies missing."
    echo "Run install-dep.sh <name> to install optional tools."
  else
    echo "All dependencies are installed. Ready to decompile."
  fi
  exit 0
fi
