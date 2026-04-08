#!/usr/bin/env bash
# adb-crash-capture.sh — Launch an app and capture crash/exit diagnostics
#
# Designed for the adaptive analysis loop:
#   1. Clears logcat
#   2. Launches the app via am start or monkey
#   3. Monitors for crash signals within a time window
#   4. Returns structured crash data for analysis
#
# This is useful BEFORE applying any Frida script — to understand the app's
# baseline behavior, or after a Frida bypass attempt to check if it worked.
#
# Usage:
#   adb-crash-capture.sh -p <package> [OPTIONS]
#
# Exit codes:
#   0 — app launched and stayed alive for the monitoring window
#   1 — setup error
#   2 — app crashed
#   3 — app exited cleanly but unexpectedly (possible RASP kill)
set -euo pipefail

PACKAGE=""
DEVICE_SERIAL=""
MONITOR_SECS=10
ACTIVITY=""
OUTPUT_DIR=""
VERBOSE=false

usage() {
  cat <<EOF
Usage: adb-crash-capture.sh -p <package> [OPTIONS]

Launch an Android app and capture crash/exit diagnostics via logcat.

Required:
  -p, --package PKG        Target package name

Options:
  -a, --activity ACT       Specific activity to launch (default: auto-detect launcher)
  -s, --serial SERIAL      Target specific device
  -t, --time SECS          Monitor window in seconds (default: 10)
  -o, --output-dir DIR     Save logs to directory
  -v, --verbose            Include full logcat, not just crash-related
  -h, --help               Show this help

Output:
  Machine-readable lines:
    APP_STATUS=running|crashed|exited|not_found
    APP_PID=<pid>
    CRASH_SIGNAL=<signal if crashed>
    CRASH_EXCEPTION=<exception class if Java crash>
    CRASH_MESSAGE=<first line of crash message>

  Followed by the relevant log section.
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--package) PACKAGE="$2"; shift 2 ;;
    -a|--activity) ACTIVITY="$2"; shift 2 ;;
    -s|--serial) DEVICE_SERIAL="$2"; shift 2 ;;
    -t|--time) MONITOR_SECS="$2"; shift 2 ;;
    -o|--output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    -v|--verbose) VERBOSE=true; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [[ -z "$PACKAGE" ]]; then
  echo "[FAIL] --package is required" >&2
  exit 1
fi

# --- adb helper ---
_adb() {
  if [[ -n "$DEVICE_SERIAL" ]]; then
    adb -s "$DEVICE_SERIAL" "$@"
  else
    adb "$@"
  fi
}

# --- Check device ---
if ! command -v adb &>/dev/null; then
  echo "[FAIL] adb not found" >&2
  exit 1
fi

device_count=$(_adb devices 2>/dev/null | grep -cE '\t(device|emulator)$' || true)
if (( device_count == 0 )); then
  echo "[FAIL] No device connected" >&2
  exit 1
fi

# =====================================================================
# Step 1: Force-stop the app (clean state)
# =====================================================================
echo "[INFO] Force-stopping $PACKAGE..."
_adb shell "am force-stop $PACKAGE" 2>/dev/null || true
sleep 1

# =====================================================================
# Step 2: Clear logcat
# =====================================================================
_adb logcat -c 2>/dev/null || true

# =====================================================================
# Step 3: Launch the app
# =====================================================================
echo "[INFO] Launching $PACKAGE..."

if [[ -n "$ACTIVITY" ]]; then
  # Launch specific activity
  LAUNCH_OUTPUT=$(_adb shell "am start -n '$PACKAGE/$ACTIVITY'" 2>&1)
else
  # Auto-detect launcher activity
  LAUNCH_OUTPUT=$(_adb shell "monkey -p '$PACKAGE' -c android.intent.category.LAUNCHER 1" 2>&1)
fi

echo "[INFO] Launch output: $LAUNCH_OUTPUT"

# Check if launch itself failed
if echo "$LAUNCH_OUTPUT" | grep -qiE "(Error|does not exist|not found)"; then
  echo "[FAIL] Could not launch $PACKAGE"
  echo "$LAUNCH_OUTPUT"
  echo "APP_STATUS=not_found"
  exit 1
fi

sleep 1

# Get initial PID
APP_PID=$(_adb shell "pidof $PACKAGE" 2>/dev/null | tr -d '\r' || true)
if [[ -n "$APP_PID" ]]; then
  echo "[INFO] App started with PID: $APP_PID"
else
  echo "[WARN] Could not get PID immediately — app may have crashed on start"
fi

# =====================================================================
# Step 4: Monitor for crashes
# =====================================================================
echo "[INFO] Monitoring for ${MONITOR_SECS}s..."

# Start logcat capture in background
LOGCAT_TMP=$(mktemp /tmp/logcat-XXXXXX.log)
_adb logcat -v threadtime > "$LOGCAT_TMP" 2>/dev/null &
LOGCAT_PID=$!

# Wait for the monitoring window
sleep "$MONITOR_SECS"

# Stop logcat capture
kill "$LOGCAT_PID" 2>/dev/null || true
wait "$LOGCAT_PID" 2>/dev/null || true

# =====================================================================
# Step 5: Check app state
# =====================================================================
FINAL_PID=$(_adb shell "pidof $PACKAGE" 2>/dev/null | tr -d '\r' || true)

EXIT_CODE=0
APP_STATUS="running"
CRASH_SIGNAL=""
CRASH_EXCEPTION=""
CRASH_MESSAGE=""

if [[ -z "$FINAL_PID" ]]; then
  # App is not running — determine why
  APP_STATUS="exited"
  EXIT_CODE=3
fi

# =====================================================================
# Step 6: Analyze logcat for crash patterns
# =====================================================================

# Java crash (uncaught exception)
JAVA_CRASH=$(grep -A 30 "FATAL EXCEPTION" "$LOGCAT_TMP" 2>/dev/null | head -40 || true)
if [[ -n "$JAVA_CRASH" ]]; then
  APP_STATUS="crashed"
  EXIT_CODE=2
  CRASH_EXCEPTION=$(echo "$JAVA_CRASH" | grep -oE '(java|kotlin|android|com|org|net)\.[a-zA-Z0-9_.]+Exception' | head -1 || true)
  CRASH_MESSAGE=$(echo "$JAVA_CRASH" | grep -A1 "FATAL EXCEPTION" | tail -1 | sed 's/^[[:space:]]*//' || true)
fi

# Native crash (SIGSEGV, SIGABRT, etc.)
NATIVE_CRASH=$(grep -B2 -A 20 "signal [0-9]" "$LOGCAT_TMP" 2>/dev/null | head -30 || true)
if [[ -z "$NATIVE_CRASH" ]]; then
  NATIVE_CRASH=$(grep -B2 -A 20 "SIGABRT\|SIGSEGV\|SIGBUS\|SIGFPE\|SIGILL" "$LOGCAT_TMP" 2>/dev/null | head -30 || true)
fi
if [[ -n "$NATIVE_CRASH" ]]; then
  APP_STATUS="crashed"
  EXIT_CODE=2
  CRASH_SIGNAL=$(echo "$NATIVE_CRASH" | grep -oE 'signal [0-9]+ \([A-Z]+\)' | head -1 || true)
  if [[ -z "$CRASH_SIGNAL" ]]; then
    CRASH_SIGNAL=$(echo "$NATIVE_CRASH" | grep -oE 'SIG[A-Z]+' | head -1 || true)
  fi
fi

# ANR (Application Not Responding)
ANR_LOG=$(grep -A 5 "ANR in $PACKAGE" "$LOGCAT_TMP" 2>/dev/null | head -10 || true)
if [[ -n "$ANR_LOG" ]]; then
  CRASH_MESSAGE="ANR: $ANR_LOG"
fi

# RASP-style kills: look for specific patterns
RASP_INDICATORS=$(grep -iE "(security|tamper|integrity|root|frida|xposed|magisk|substrate|debug|hook)" "$LOGCAT_TMP" 2>/dev/null | grep -iE "$PACKAGE" | head -10 || true)

# Process kill signals
KILL_LOG=$(grep -iE "(kill|died|low memory|Process.*has died)" "$LOGCAT_TMP" 2>/dev/null | grep -iE "$PACKAGE" | head -5 || true)
if [[ -n "$KILL_LOG" && "$APP_STATUS" == "exited" ]]; then
  CRASH_MESSAGE="Process killed: $(echo "$KILL_LOG" | head -1)"
fi

# =====================================================================
# Step 7: Extract app-specific log lines
# =====================================================================
APP_LOGS=""
if [[ -n "$APP_PID" ]]; then
  APP_LOGS=$(grep " $APP_PID " "$LOGCAT_TMP" 2>/dev/null | tail -50 || true)
fi

# =====================================================================
# Output
# =====================================================================
echo ""
echo "=== RESULT ==="
echo "APP_STATUS=$APP_STATUS"
echo "APP_PID=${APP_PID:-none}"
[[ -n "$CRASH_SIGNAL" ]] && echo "CRASH_SIGNAL=$CRASH_SIGNAL"
[[ -n "$CRASH_EXCEPTION" ]] && echo "CRASH_EXCEPTION=$CRASH_EXCEPTION"
[[ -n "$CRASH_MESSAGE" ]] && echo "CRASH_MESSAGE=$CRASH_MESSAGE"

if [[ "$APP_STATUS" == "crashed" || "$APP_STATUS" == "exited" ]]; then
  echo ""
  echo "=== JAVA CRASH ==="
  if [[ -n "$JAVA_CRASH" ]]; then
    echo "$JAVA_CRASH"
  else
    echo "(none)"
  fi

  echo ""
  echo "=== NATIVE CRASH ==="
  if [[ -n "$NATIVE_CRASH" ]]; then
    echo "$NATIVE_CRASH"
  else
    echo "(none)"
  fi

  echo ""
  echo "=== RASP/SECURITY INDICATORS ==="
  if [[ -n "$RASP_INDICATORS" ]]; then
    echo "$RASP_INDICATORS"
  else
    echo "(none detected in logs)"
  fi

  echo ""
  echo "=== PROCESS KILL LOG ==="
  if [[ -n "$KILL_LOG" ]]; then
    echo "$KILL_LOG"
  else
    echo "(none)"
  fi
fi

if [[ -n "$APP_LOGS" ]]; then
  echo ""
  echo "=== APP LOG (last 50 lines from PID $APP_PID) ==="
  echo "$APP_LOGS"
fi

if [[ "$VERBOSE" == true ]]; then
  echo ""
  echo "=== FULL LOGCAT ==="
  cat "$LOGCAT_TMP"
fi

# Save logs if output dir specified
if [[ -n "$OUTPUT_DIR" ]]; then
  mkdir -p "$OUTPUT_DIR"
  TIMESTAMP=$(date +%Y%m%d_%H%M%S)
  cp "$LOGCAT_TMP" "$OUTPUT_DIR/logcat_${TIMESTAMP}.log"
  echo ""
  echo "[INFO] Full logcat saved to $OUTPUT_DIR/logcat_${TIMESTAMP}.log"
fi

rm -f "$LOGCAT_TMP"
exit $EXIT_CODE
