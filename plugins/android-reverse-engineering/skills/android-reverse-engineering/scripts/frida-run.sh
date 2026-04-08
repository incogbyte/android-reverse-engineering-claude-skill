#!/usr/bin/env bash
# frida-run.sh — Run Frida with a generated script via the managed venv
#
# This script is infrastructure for the adaptive analysis loop:
#   1. Claude generates a JS script based on static analysis
#   2. This script runs it against the target app
#   3. Captures stdout, stderr, and crash signals
#   4. Returns structured output for Claude to analyze and iterate
#
# Usage:
#   frida-run.sh -p <package> -l <script.js> [OPTIONS]
#   frida-run.sh -p <package> -e "Java.perform(...)" [OPTIONS]
#
# Exit codes:
#   0 — script ran and app stayed alive
#   1 — setup error (venv not found, no device, etc.)
#   2 — app crashed during instrumentation
#   3 — frida connection failed (server not running, version mismatch)
#   4 — timeout reached
set -euo pipefail

VENV_BASE="${FRIDA_VENV_DIR:-$HOME/.local/share/frida-re}"
VENV_PATH="$VENV_BASE/venv"
PACKAGE=""
SCRIPT_FILE=""
SCRIPT_INLINE=""
TIMEOUT=30
SPAWN=true
DEVICE_SERIAL=""
OUTPUT_DIR=""
EXTRA_ARGS=()

usage() {
  cat <<EOF
Usage: frida-run.sh -p <package> -l <script.js> [OPTIONS]

Run a Frida script against an Android app using the managed venv.

Required:
  -p, --package PKG      Target package name (e.g. com.example.app)
  -l, --load FILE        JavaScript file to load
  -e, --eval CODE        Inline JavaScript to execute (alternative to -l)

Options:
  -s, --serial SERIAL    Target specific device
  -t, --timeout SECS     Max seconds to run (default: 30, 0=unlimited)
  --attach               Attach to running process instead of spawning
  --output-dir DIR       Save stdout/stderr/crash to files in DIR
  --pause                Pause app on spawn (for early hooks, resumes after script loads)
  -h, --help             Show this help

Output:
  stdout: Frida script console output (send(), console.log())
  stderr: Frida errors, crash info
  Exit code indicates result (0=ok, 2=crash, 3=connection fail, 4=timeout)
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--package) PACKAGE="$2"; shift 2 ;;
    -l|--load) SCRIPT_FILE="$2"; shift 2 ;;
    -e|--eval) SCRIPT_INLINE="$2"; shift 2 ;;
    -s|--serial) DEVICE_SERIAL="$2"; shift 2 ;;
    -t|--timeout) TIMEOUT="$2"; shift 2 ;;
    --attach) SPAWN=false; shift ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    --pause) EXTRA_ARGS+=("--pause"); shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# --- Validation ---
if [[ -z "$PACKAGE" ]]; then
  echo "[FAIL] --package is required" >&2
  exit 1
fi

if [[ -z "$SCRIPT_FILE" && -z "$SCRIPT_INLINE" ]]; then
  echo "[FAIL] Either --load <file> or --eval <code> is required" >&2
  exit 1
fi

# --- Check venv ---
FRIDA_BIN="$VENV_PATH/bin/frida"
if [[ ! -f "$FRIDA_BIN" ]]; then
  echo "[FAIL] Frida venv not found at $VENV_PATH" >&2
  echo "       Run setup-frida.sh first" >&2
  exit 1
fi

# --- Handle inline script ---
if [[ -n "$SCRIPT_INLINE" ]]; then
  SCRIPT_FILE=$(mktemp /tmp/frida-inline-XXXXXX.js)
  echo "$SCRIPT_INLINE" > "$SCRIPT_FILE"
  trap "rm -f '$SCRIPT_FILE'" EXIT
fi

if [[ ! -f "$SCRIPT_FILE" ]]; then
  echo "[FAIL] Script file not found: $SCRIPT_FILE" >&2
  exit 1
fi

# --- Build frida command ---
FRIDA_CMD=("$FRIDA_BIN" "-U")

if [[ -n "$DEVICE_SERIAL" ]]; then
  FRIDA_CMD=("$FRIDA_BIN" "-D" "$DEVICE_SERIAL")
fi

if [[ "$SPAWN" == true ]]; then
  FRIDA_CMD+=("-f" "$PACKAGE")
else
  FRIDA_CMD+=("-n" "$PACKAGE")
fi

FRIDA_CMD+=("-l" "$SCRIPT_FILE")
FRIDA_CMD+=("${EXTRA_ARGS[@]}")

# --- Setup output capture ---
STDOUT_FILE=""
STDERR_FILE=""
if [[ -n "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  STDOUT_FILE="$OUTPUT_DIR/frida_stdout_${TIMESTAMP}.log"
  STDERR_FILE="$OUTPUT_DIR/frida_stderr_${TIMESTAMP}.log"
fi

# --- adb helper ---
_adb() {
  if [[ -n "$DEVICE_SERIAL" ]]; then
    adb -s "$DEVICE_SERIAL" "$@"
  else
    adb "$@"
  fi
}

# --- Clear logcat before run (for crash capture) ---
_adb logcat -c 2>/dev/null || true

# --- Run Frida ---
echo "[INFO] Running: ${FRIDA_CMD[*]}"
echo "[INFO] Target: $PACKAGE | Timeout: ${TIMEOUT}s | Mode: $(if $SPAWN; then echo spawn; else echo attach; fi)"
echo "---"

EXIT_CODE=0

run_frida() {
  if [[ -n "$STDOUT_FILE" ]]; then
    "${FRIDA_CMD[@]}" > >(tee "$STDOUT_FILE") 2> >(tee "$STDERR_FILE" >&2)
  else
    "${FRIDA_CMD[@]}"
  fi
}

if (( TIMEOUT > 0 )); then
  # Run with timeout
  if command -v timeout &>/dev/null; then
    timeout "$TIMEOUT" bash -c "$(declare -f run_frida); FRIDA_CMD=(${FRIDA_CMD[*]@Q}); STDOUT_FILE=${STDOUT_FILE@Q}; STDERR_FILE=${STDERR_FILE@Q}; run_frida" || EXIT_CODE=$?
  else
    # macOS: no timeout command, use background + wait
    run_frida &
    FRIDA_PID=$!
    (
      sleep "$TIMEOUT"
      kill "$FRIDA_PID" 2>/dev/null || true
    ) &
    TIMER_PID=$!
    wait "$FRIDA_PID" 2>/dev/null || EXIT_CODE=$?
    kill "$TIMER_PID" 2>/dev/null || true
  fi
else
  run_frida || EXIT_CODE=$?
fi

echo "---"

# --- Analyze exit ---
# timeout exits with 124, macOS kill gives 137/143
if (( EXIT_CODE == 124 || EXIT_CODE == 137 || EXIT_CODE == 143 )); then
  echo "[INFO] Timeout reached (${TIMEOUT}s). App may still be running."
  EXIT_CODE=4
fi

# --- Capture crash logs if app died ---
echo ""
echo "[INFO] Checking for crashes..."
CRASH_LOG=$(_adb logcat -d -s "AndroidRuntime:E" "DEBUG:E" "FATAL:E" 2>/dev/null | tail -50 || true)

if echo "$CRASH_LOG" | grep -qiE "(FATAL|SIGABRT|SIGSEGV|java\.lang\.|Exception|Error.*$PACKAGE)"; then
  echo "[CRASH] Application crashed during instrumentation"
  echo ""
  echo "=== CRASH LOG ==="
  echo "$CRASH_LOG"
  echo "=== END CRASH LOG ==="

  if [[ -n "$OUTPUT_DIR" ]]; then
    echo "$CRASH_LOG" > "$OUTPUT_DIR/crash_${TIMESTAMP:-$(date +%Y%m%d_%H%M%S)}.log"
    echo "[INFO] Crash log saved to $OUTPUT_DIR/"
  fi

  if (( EXIT_CODE == 0 )); then
    EXIT_CODE=2
  fi
else
  # Check if process is still alive
  if _adb shell "pidof $PACKAGE" &>/dev/null; then
    echo "[OK] App process is still alive"
  else
    echo "[WARN] App process not found — it may have exited or crashed silently"
    # Grab broader logcat for silent crashes
    BROAD_LOG=$(_adb logcat -d -t 100 2>/dev/null | grep -iE "(kill|died|crash|abort|$PACKAGE)" | tail -20 || true)
    if [[ -n "$BROAD_LOG" ]]; then
      echo ""
      echo "=== RELEVANT LOG ENTRIES ==="
      echo "$BROAD_LOG"
      echo "=== END LOG ==="
    fi
    if (( EXIT_CODE == 0 )); then
      EXIT_CODE=2
    fi
  fi
fi

# --- Summary ---
echo ""
case $EXIT_CODE in
  0) echo "FRIDA_RESULT=success" ;;
  2) echo "FRIDA_RESULT=crash" ;;
  3) echo "FRIDA_RESULT=connection_failed" ;;
  4) echo "FRIDA_RESULT=timeout" ;;
  *) echo "FRIDA_RESULT=error (exit=$EXIT_CODE)" ;;
esac

exit $EXIT_CODE
