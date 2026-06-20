#!/usr/bin/env bash
# run_tests.sh — exercise the skill's detection scripts against committed
# synthetic decompiled fixtures under tests/fixtures/.
#
# These tests guard the bash heuristics that are easy to silently break:
#   - manifest parsing (self-closing AND paired <activity> tags, minified
#     single-line manifests)
#   - isValidFragment status classification (missing / always_true / whitelist)
#   - targetSdkVersion gating (missing override -> candidate only if < 19,
#     else broken)
#   - AndroidX dynamic-load correlation (instantiate + extra on adjacent lines)
#   - Firebase config detection (key shape + Firebase values)
#
# Run:  bash tests/run_tests.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/../skills/android-reverse-engineering" && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
FIXTURES="$SCRIPT_DIR/fixtures"

PASS=0
FAIL=0
FAILED_TESTS=()

# assert_exit <name> <expected> <actual>
assert_exit() {
  local name="$1" exp="$2" act="$3"
  if [[ "$act" == "$exp" ]]; then
    echo "  PASS  $name (exit $act)"
    PASS=$((PASS+1))
  else
    echo "  FAIL  $name (expected exit $exp, got $act)"
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$name")
  fi
}

# assert_grep <name> <pattern> <haystack>
assert_grep() {
  local name="$1" pat="$2" hay="$3"
  if printf '%s' "$hay" | grep -qE "$pat"; then
    echo "  PASS  $name"
    PASS=$((PASS+1))
  else
    echo "  FAIL  $name (no match for /$pat/)"
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$name")
  fi
}

# assert_no_grep <name> <pattern> <haystack>
assert_no_grep() {
  local name="$1" pat="$2" hay="$3"
  if printf '%s' "$hay" | grep -qE "$pat"; then
    echo "  FAIL  $name (unexpected match for /$pat/)"
    FAIL=$((FAIL+1))
    FAILED_TESTS+=("$name")
  else
    echo "  PASS  $name"
    PASS=$((PASS+1))
  fi
}

run_frag() { bash "$SCRIPTS/find-fragment-injection.sh" "$1" 2>&1; }

echo "=== find-fragment-injection.sh ==="

# --- vulnerable: exported PreferenceActivity, always_true, targetSdk 33 ---
out="$(run_frag "$FIXTURES/vulnerable")"; rc=$?
assert_exit "vulnerable: exit 0" 0 "$rc"
assert_grep "vulnerable: candidate flagged" 'FRAG_INJECTION_CANDIDATE=com\.vuln\.app\.SettingsActivity' "$out"
assert_grep "vulnerable: always_true status" 'IS_VALID_FRAGMENT=com\.vuln\.app\.SettingsActivity:always_true' "$out"
assert_grep "vulnerable: targetSdk read" 'TARGET_SDK_VERSION=33' "$out"

# --- legacy: missing override, exported, targetSdk 18 -> candidate (not broken) ---
out="$(run_frag "$FIXTURES/legacy")"; rc=$?
assert_exit "legacy: exit 0" 0 "$rc"
assert_grep "legacy: candidate flagged" 'FRAG_INJECTION_CANDIDATE=com\.legacy\.app\.OldSettings' "$out"
assert_grep "legacy: missing status" 'IS_VALID_FRAGMENT=com\.legacy\.app\.OldSettings:missing' "$out"
assert_grep "legacy: targetSdk 18" 'TARGET_SDK_VERSION=18' "$out"
assert_no_grep "legacy: not broken" 'FRAG_INJECTION_BROKEN' "$out"

# --- broken: missing override, exported, targetSdk 33 -> broken, exit 2 ---
out="$(run_frag "$FIXTURES/broken")"; rc=$?
assert_exit "broken: exit 2" 2 "$rc"
assert_grep "broken: broken flagged" 'FRAG_INJECTION_BROKEN=com\.broken\.app\.Settings' "$out"
assert_grep "broken: candidate count 0" 'CANDIDATE_COUNT=0' "$out"
assert_grep "broken: broken count 1" 'BROKEN_COUNT=1' "$out"
assert_no_grep "broken: not a candidate" 'FRAG_INJECTION_CANDIDATE' "$out"

# --- safe: whitelist override, exported -> no candidate, no broken ---
out="$(run_frag "$FIXTURES/safe")"; rc=$?
assert_exit "safe: exit 2" 2 "$rc"
assert_grep "safe: whitelist status" 'IS_VALID_FRAGMENT=com\.safe\.app\.Settings:whitelist' "$out"
assert_grep "safe: candidate count 0" 'CANDIDATE_COUNT=0' "$out"
assert_no_grep "safe: no candidate" 'FRAG_INJECTION_CANDIDATE' "$out"
assert_no_grep "safe: no broken" 'FRAG_INJECTION_BROKEN' "$out"

# --- androidx: modern preference API + dynamic load from extra ---
out="$(run_frag "$FIXTURES/androidx")"; rc=$?
assert_exit "androidx: exit 2 (no PrefActivity candidate)" 2 "$rc"
assert_grep "androidx: dynamic load flagged" 'DYNAMIC_FRAGMENT_LOAD=.*HostActivity\.java' "$out"
assert_grep "androidx: modern pref API flagged" 'ANDROIDX_PREFERENCE=.*PreferenceFragmentCompat' "$out"
assert_no_grep "androidx: no import-line false positive" 'DYNAMIC_FRAGMENT_LOAD=.*:import ' "$out"

# --- clean: nothing preference-related ---
out="$(run_frag "$FIXTURES/clean")"; rc=$?
assert_exit "clean: exit 2" 2 "$rc"
assert_grep "clean: candidate count 0" 'CANDIDATE_COUNT=0' "$out"
assert_no_grep "clean: no PREFERENCE_ACTIVITY" 'PREFERENCE_ACTIVITY=' "$out"

# --- minified: single-line manifest, vulnerable always_true ---
out="$(run_frag "$FIXTURES/minified")"; rc=$?
assert_exit "minified: exit 0" 0 "$rc"
assert_grep "minified: exported activity parsed" 'EXPORTED_ACTIVITY=com\.min\.app\.Settings' "$out"
assert_grep "minified: candidate flagged" 'FRAG_INJECTION_CANDIDATE=com\.min\.app\.Settings' "$out"
assert_grep "minified: targetSdk parsed from single line" 'TARGET_SDK_VERSION=33' "$out"

echo
echo "=== find-firebase-config.sh ==="

# --- firebase: keys + config present -> exit 0 ---
out="$(bash "$SCRIPTS/find-firebase-config.sh" "$FIXTURES/firebase" 2>&1)"; rc=$?
assert_exit "firebase: exit 0" 0 "$rc"
assert_grep "firebase: FIREBASE_FOUND" 'FIREBASE_FOUND=true' "$out"
assert_grep "firebase: GOOGLE_API_KEY_FOUND" 'GOOGLE_API_KEY_FOUND=true' "$out"
assert_grep "firebase: project_id" 'PROJECT_ID=audit-project' "$out"
assert_grep "firebase: api key index" 'API_KEY\[0\]=AIzaSyA0123456789abcdefghijklmnopqrstuv' "$out"

# --- no-firebase: clean fixture -> exit 2 ---
out="$(bash "$SCRIPTS/find-firebase-config.sh" "$FIXTURES/clean" 2>&1)"; rc=$?
assert_exit "no-firebase: exit 2" 2 "$rc"
assert_grep "no-firebase: FIREBASE_FOUND false" 'FIREBASE_FOUND=false' "$out"

# --- firebase_minified: single-line strings.xml + manifest -> still parsed ---
out="$(bash "$SCRIPTS/find-firebase-config.sh" "$FIXTURES/firebase_minified" 2>&1)"; rc=$?
assert_exit "firebase_minified: exit 0" 0 "$rc"
assert_grep "firebase_minified: key parsed from single line" 'API_KEY\[0\]=AIzaSyB0123456789abcdefghijklmnopqrstuv' "$out"
assert_grep "firebase_minified: project_id parsed" 'PROJECT_ID=min-project' "$out"
assert_grep "firebase_minified: package parsed" 'PACKAGE_NAME=com\.fb\.min' "$out"

echo
echo "==============================================="
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ "$FAIL" -gt 0 ]]; then
  echo "Failed tests:"
  for t in "${FAILED_TESTS[@]}"; do echo "  - $t"; done
  exit 1
fi
echo "All tests passed."
exit 0