#!/usr/bin/env bash
# find-fragment-injection.sh — Detect Android Fragment Injection exposure
# in a decompiled Android app, and emit machine-readable findings that the
# analyst (and the android-fragment-injection.md playbook) can consume.
#
# Companion to Phase 8 of the skill. Fragment Injection is the classic
# PreferenceActivity flaw: an exported (or otherwise launchable) Activity that
# honours the ":android:show_fragment" Intent extra will instantiate an
# attacker-chosen Fragment class inside its own process/UID. The framework
# mitigation is PreferenceActivity.isValidFragment(); a missing or permissive
# override means the activity is exploitable.
set -euo pipefail

usage() {
  cat <<EOF
Usage: find-fragment-injection.sh <decompiled-dir> [OPTIONS]

Scan a decompiled Android output directory for Fragment Injection exposure:
exported/launchable activities, PreferenceActivity subclasses, readers of the
":android:show_fragment" / EXTRA_SHOW_FRAGMENT extras, isValidFragment()
overrides, and dynamic fragment instantiation driven by Intent extras.

Arguments:
  <decompiled-dir>   Path to the decompile output (the dir that contains
                     resources/ and sources/). Also accepts resources/
                     or sources/ directly.

Options:
  --report FILE      Write a structured Markdown report to FILE.
  --json FILE        Write findings as JSON to FILE.
  -h, --help         Show this help message.

Machine-readable output (always printed to stdout):
  FRAG_INJECTION_SCAN=true
  TARGET_SDK_VERSION=<n>                    (drives the isValidFragment gate)
  MIN_SDK_VERSION=<n>
  EXPORTED_ACTIVITY=<name>                  (android:exported="true")
  LAUNCHABLE_ACTIVITY=<name>                (has an <intent-filter>, implicitly
                                            exported on targetSdk < 31)
  PREFERENCE_ACTIVITY=<fully.qualified.Class>
  SHOW_FRAGMENT_READER=<file>:<line>:<class-ish snippet>
  IS_VALID_FRAGMENT=<class>:<status>        (missing|always_true|whitelist)
  DYNAMIC_FRAGMENT_LOAD=<file>:<line>:<snippet>
  ANDROIDX_PREFERENCE=<file>:<line>:<snippet> (modern preference API in use —
                                            classic show_fragment vector does
                                            NOT apply; check DYNAMIC_FRAGMENT_LOAD)
  FRAG_INJECTION_CANDIDATE=<class>          (exported/launchable PreferenceActivity
                                            that is injectable: always_true
                                            override, OR missing override with
                                            targetSdk < 19 / unknown)
  FRAG_INJECTION_BROKEN=<class>             (missing override + targetSdk >= 19:
                                            app crashes on injection, not
                                            exploitable — report as robustness)
  CANDIDATE_COUNT=<n>
  BROKEN_COUNT=<n>

Exit codes:
  0  at least one fragment-injection candidate was found -> investigate
  2  no candidates found (may still print informational/broken findings)
  1  usage / input error
EOF
  exit 0
}

TARGET=""
REPORT_FILE=""
JSON_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --report) REPORT_FILE="$2"; shift 2 ;;
    --json)   JSON_FILE="$2"; shift 2 ;;
    -h|--help) usage ;;
    -*)       echo "Error: Unknown option $1" >&2; exit 1 ;;
    *)        TARGET="$1"; shift ;;
  esac
done

if [[ -z "$TARGET" ]]; then
  echo "Error: No decompiled directory specified." >&2
  exit 1
fi
if [[ ! -d "$TARGET" ]]; then
  echo "Error: Directory not found: $TARGET" >&2
  exit 1
fi

# Resolve roots. Accept the decompile root, or resources/ / sources/ directly.
if [[ -d "$TARGET/resources" ]]; then
  RES_DIR="$TARGET/resources"
else
  RES_DIR="$TARGET"
fi
if [[ -d "$TARGET/sources" ]]; then
  SRC_DIR="$TARGET/sources"
elif [[ -d "$TARGET" ]]; then
  SRC_DIR="$TARGET"
else
  SRC_DIR="$TARGET"
fi

MANIFEST="$RES_DIR/AndroidManifest.xml"
PACKAGE_NAME=""
[[ -f "$MANIFEST" ]] && PACKAGE_NAME="$(sed -n -E 's|.*package="([^"]+)".*|\1|p' "$MANIFEST" | head -n1)"

# targetSdkVersion drives the isValidFragment gate. With targetSdk < 19 the
# framework does NOT call isValidFragment, so a missing override is exploitable.
# With targetSdk >= 19 a missing override makes the app crash on injection
# (broken, not exploitable). Extract from <uses-sdk .../> in the manifest.
TARGET_SDK_VERSION=""
MIN_SDK_VERSION=""
if [[ -f "$MANIFEST" ]]; then
  TARGET_SDK_VERSION="$(grep -oE 'targetSdkVersion="[0-9]+"' "$MANIFEST" | sed -E 's/.*="([0-9]+)"/\1/' | head -n1)"
  MIN_SDK_VERSION="$(grep -oE 'minSdkVersion="[0-9]+"' "$MANIFEST" | sed -E 's/.*="([0-9]+)"/\1/' | head -n1)"
fi

echo "FRAG_INJECTION_SCAN=true"
echo "PACKAGE_NAME=${PACKAGE_NAME}"
echo "TARGET_SDK_VERSION=${TARGET_SDK_VERSION}"
echo "MIN_SDK_VERSION=${MIN_SDK_VERSION}"

# --- Manifest: exported + launchable activities ------------------------------
# Parse <activity> tags with a stateful awk that handles BOTH self-closing
# tags (<activity ... />) and paired tags (<activity ...> ... </activity>).
# Splitting records on '>' gives one record per tag; we track the current
# activity's name/exported and whether it contains an <intent-filter>, and
# emit on close (either '/>' self-close or '</activity>'). This fixes the
# common jadx output where activities are self-closing and have no
# '</activity>' terminator (which broke naive RS="</activity>" parsing).
#
# An activity is:
#   EXPORTED   -> android:exported="true"
#   LAUNCHABLE -> exported="true", OR has an <intent-filter> without
#                 exported="false" (implicitly exported on targetSdk < 31).

EXPORTED_ACTIVITIES=()
LAUNCHABLE_ACTIVITIES=()

if [[ -f "$MANIFEST" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    tag="${line%% *}"; val="${line#* }"
    case "$tag" in
      EXPORTED)   EXPORTED_ACTIVITIES+=("$val") ;;
      LAUNCHABLE) LAUNCHABLE_ACTIVITIES+=("$val"); echo "LAUNCHABLE_ACTIVITY=${val}" ;;
    esac
  done < <(
    awk '
      BEGIN { RS=">"; FS="" }
      function emit() {
        if (name == "") return
        if (exported == "true") print "EXPORTED " name
        if (exported == "true" || (hasfilter == 1 && exported != "false"))
          print "LAUNCHABLE " name
      }
      {
        rec = $0
        if (rec ~ /<activity[[:space:]]/) {
          if (pending) emit()          # safety: previous activity never closed
          name=""; exported=""; hasfilter=0; pending=1
          if (match(rec, /android:name="[^"]*"/)) {
            s=substr(rec, RSTART, RLENGTH)
            sub(/.*android:name="/, "", s); sub(/".*/, "", s); name=s
          }
          if (match(rec, /android:exported="[^"]*"/)) {
            s=substr(rec, RSTART, RLENGTH)
            sub(/.*android:exported="/, "", s); sub(/".*/, "", s); exported=s
          }
          if (rec ~ /\/[[:space:]]*$/) { emit(); pending=0 }   # self-closing
          next
        }
        if (pending) {
          if (rec ~ /<intent-filter/) hasfilter=1
          if (rec ~ /<\/activity/) { emit(); pending=0 }
        }
      }
      END { if (pending) emit() }
    ' "$MANIFEST"
  )
fi

for a in "${EXPORTED_ACTIVITIES[@]:-}"; do
  [[ -n "$a" ]] && echo "EXPORTED_ACTIVITY=${a}"
done

# --- Source: PreferenceActivity subclasses -----------------------------------
PREF_CLASSES=()
if [[ -d "$SRC_DIR" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    # line is "file:match"
    file="${line%%:*}"; match="${line#*:}"
    # Heuristic FQN from path: sources/com/example/Foo.java -> com.example.Foo
    rel="${file#$SRC_DIR/}"
    rel="${rel#/}"
    cls="${rel%.java}"; cls="${cls%.kt}"
    cls="$(echo "$cls" | sed 's#/#.#g')"
    PREF_CLASSES+=("$cls")
    echo "PREFERENCE_ACTIVITY=${cls}"
  done < <(grep -rnE 'extends[[:space:]]+PreferenceActivity|:[[:space:]]*PreferenceActivity\(' "$SRC_DIR" 2>/dev/null || true)
fi

# --- Source: readers of the show_fragment extras -----------------------------
SHOW_FRAGMENT_READERS=()
if [[ -d "$SRC_DIR" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "SHOW_FRAGMENT_READER=${line}"
    SHOW_FRAGMENT_READERS+=("$line")
  done < <(grep -rnE ':android:show_fragment|EXTRA_SHOW_FRAGMENT|show_fragment' "$SRC_DIR" 2>/dev/null | head -n 200 || true)
fi

# --- Source: isValidFragment overrides ---------------------------------------
# Status: missing (no override in the class), always_true (returns true
# unconditionally), whitelist (returns true conditionally / compares to a
# constant). Determined per PreferenceActivity subclass.
IS_VALID_STATUS=()
if [[ -d "$SRC_DIR" ]] && [[ ${#PREF_CLASSES[@]:-} -gt 0 ]]; then
  for cls in "${PREF_CLASSES[@]:-}"; do
    # Locate the source file for this class.
    rel="$(echo "$cls" | sed 's#\.#/#g')"
    f=""
    for cand in "$SRC_DIR/${rel}.java" "$SRC_DIR/${rel}.kt"; do
      [[ -f "$cand" ]] && f="$cand" && break
    done
    if [[ -z "$f" ]]; then
      IS_VALID_STATUS+=("${cls}:missing")
      continue
    fi
    if grep -qE 'isValidFragment' "$f"; then
      # Look at the body of isValidFragment to guess the return policy.
      body="$(awk '/isValidFragment/{flag=1} flag{print} /return/{if(flag){flag=0}}' "$f")"
      if echo "$body" | grep -qE 'return[[:space:]]+true[[:space:]]*;'; then
        # Unconditional `return true;` -> permissive.
        if echo "$body" | grep -qE 'if|equals|contains|\?|&&|\|\|'; then
          IS_VALID_STATUS+=("${cls}:whitelist")
        else
          IS_VALID_STATUS+=("${cls}:always_true")
        fi
      else
        IS_VALID_STATUS+=("${cls}:whitelist")
      fi
    else
      IS_VALID_STATUS+=("${cls}:missing")
    fi
  done
  for s in "${IS_VALID_STATUS[@]:-}"; do echo "IS_VALID_FRAGMENT=${s}"; done
fi

# --- Source: dynamic fragment instantiation from extras ----------------------
# --- Source: dynamic fragment instantiation from extras ----------------------
# The generic (non-PreferenceActivity) variant: any Activity/Fragment that
# instantiates a Fragment class from an attacker-controlled Intent extra. This
# is also the relevant signal for modern AndroidX apps, which use
# androidx.fragment.app.Fragment / FragmentFactory instead of the legacy
# android.preference.PreferenceActivity show_fragment mechanism.
DYNAMIC_LOADS=()
if [[ -d "$SRC_DIR" ]]; then
  # Find each Fragment.instantiate / FragmentFactory / Class.forName / loadClass
  # call, then keep it only if an Intent-extra / Bundle read appears within a
  # +/-8 line window. This catches the common AndroidX pattern where the class
  # name is read from an extra on one line and instantiated on the next.
  while IFS= read -r m; do
    [[ -z "$m" ]] && continue
    file="${m%%:*}"; rest="${m#*:}"; ln="${rest%%:*}"
    start=$((ln-8)); [[ "$start" -lt 1 ]] && start=1
    if sed -n "${start},$((ln+2))p" "$file" 2>/dev/null \
       | grep -qiE 'extra|intent|bundle|getSerializable|getStringExtra|getParcelableExtra|show_fragment|forName|loadClass'; then
      echo "DYNAMIC_FRAGMENT_LOAD=${m}"
      DYNAMIC_LOADS+=("$m")
    fi
  done < <(
    grep -rnE 'Fragment\.instantiate|FragmentFactory|FragmentManager.*instantiate|loadClass|Class\.forName' "$SRC_DIR" 2>/dev/null \
      | grep -vE ':[0-9]+:[[:space:]]*(import|package)[[:space:]]' \
      | head -n 400 || true
  )
fi

# --- Source: AndroidX modern preference API (informational) -------------------
# androidx.preference.PreferenceFragmentCompat replaces the legacy
# PreferenceActivity and does NOT honour the ":android:show_fragment" extra, so
# the classic vector does not apply. Emit so the report can state that "no
# PreferenceActivity found" is NOT proof of safety for modern apps — the
# DYNAMIC_FRAGMENT_LOAD findings above are what matter there.
ANDROIDX_PREFERENCE=()
if [[ -d "$SRC_DIR" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    echo "ANDROIDX_PREFERENCE=${line}"
    ANDROIDX_PREFERENCE+=("$line")
  done < <(grep -rnE 'PreferenceFragmentCompat|androidx\.preference' "$SRC_DIR" 2>/dev/null | head -n 50 || true)
fi

# --- Build candidate set -----------------------------------------------------
# A candidate is a PreferenceActivity subclass that is exported or launchable
# AND can actually be injected:
#   - isValidFragment = always_true  -> vulnerable regardless of targetSdk
#   - isValidFragment = missing       -> vulnerable ONLY if targetSdk < 19
#     (the framework skips the isValidFragment gate on legacy targets). With
#     targetSdk >= 19 a missing override makes the app crash on injection
#     instead — broken, not exploitable -> emitted as FRAG_INJECTION_BROKEN.
#   - isValidFragment = whitelist     -> safe, skipped.

# Whether targetSdk is known to be >= 19 (the isValidFragment-enforcing range).
TARGET_SDK_GE_19=false
if [[ -n "$TARGET_SDK_VERSION" ]] && [[ "$TARGET_SDK_VERSION" -ge 19 ]]; then
  TARGET_SDK_GE_19=true
fi

CANDIDATES=()
BROKEN_CLASSES=()
for cls in "${PREF_CLASSES[@]:-}"; do
  # Resolve this class's isValidFragment status.
  status="missing"
  for s in "${IS_VALID_STATUS[@]:-}"; do
    if [[ "${s%%:*}" == "$cls" ]]; then status="${s#*:}"; break; fi
  done
  # Skip classes with a restrictive whitelist override.
  if [[ "$status" == "whitelist" ]]; then continue; fi

  # Match against exported/launchable activity names. Match on the simple
  # (last) class segment as well as the full FQN, since manifests often use
  # relative names (".SettingsActivity") that jadx expands differently.
  simple="${cls##*.}"
  hit=false
  for act in "${LAUNCHABLE_ACTIVITIES[@]:-}"; do
    [[ -z "$act" ]] && continue
    if [[ "$act" == "$cls" || "$act" == ".$simple" || "$act" == "$simple" \
       || "$act" == *".$simple" ]]; then
      hit=true; break
    fi
  done

  if [[ "$hit" != true ]]; then continue; fi

  if [[ "$status" == "always_true" ]]; then
    CANDIDATES+=("$cls")
    echo "FRAG_INJECTION_CANDIDATE=${cls}"
  elif [[ "$status" == "missing" ]]; then
    if [[ "$TARGET_SDK_GE_19" == true ]]; then
      # Framework throws -> app crashes on injection. Broken, not exploitable.
      BROKEN_CLASSES+=("$cls")
      echo "FRAG_INJECTION_BROKEN=${cls}"
    else
      # targetSdk < 19, or unknown -> treat as injectable (legacy gate skipped).
      CANDIDATES+=("$cls")
      echo "FRAG_INJECTION_CANDIDATE=${cls}"
    fi
  fi
done

CANDIDATE_COUNT=${#CANDIDATES[@]}
BROKEN_COUNT=${#BROKEN_CLASSES[@]}
echo "CANDIDATE_COUNT=${CANDIDATE_COUNT}"
echo "BROKEN_COUNT=${BROKEN_COUNT}"

# --- Optional Markdown report ------------------------------------------------
if [[ -n "$REPORT_FILE" ]]; then
  {
    echo "# Fragment Injection Scan Report"
    echo
    echo "Generated by \`find-fragment-injection.sh\` on $(date -u '+%Y-%m-%d %H:%M:%S UTC')."
    echo
    echo "**Package:** \`${PACKAGE_NAME}\`"
    echo "**targetSdkVersion:** ${TARGET_SDK_VERSION:-_(unknown)_}  ·  **minSdkVersion:** ${MIN_SDK_VERSION:-_(unknown)_}"
    echo "**Candidates (injectable):** ${CANDIDATE_COUNT}  ·  **Broken (crash, not exploitable):** ${BROKEN_COUNT}"
    echo
    echo "## Exported activities"
    if [[ ${#EXPORTED_ACTIVITIES[@]:-} -gt 0 ]]; then
      for a in "${EXPORTED_ACTIVITIES[@]:-}"; do echo "- \`${a}\`"; done
    else
      echo "- _(none with android:exported=\"true\")_"
    fi
    echo
    echo "## PreferenceActivity subclasses"
    if [[ ${#PREF_CLASSES[@]:-} -gt 0 ]]; then
      for c in "${PREF_CLASSES[@]:-}"; do echo "- \`${c}\`"; done
    else
      echo "- _(none found)_"
    fi
    echo
    echo "## isValidFragment() override status"
    if [[ ${#IS_VALID_STATUS[@]:-} -gt 0 ]]; then
      for s in "${IS_VALID_STATUS[@]:-}"; do
        echo "- \`${s%%:*}\` → \`${s#*:}\`"
      done
    else
      echo "- _(no PreferenceActivity subclasses to check)_"
    fi
    echo
    echo "## \`:android:show_fragment\` / EXTRA_SHOW_FRAGMENT readers"
    if [[ ${#SHOW_FRAGMENT_READERS[@]:-} -gt 0 ]]; then
      for r in "${SHOW_FRAGMENT_READERS[@]:-}"; do echo "- \`${r}\`"; done
    else
      echo "- _(none found)_"
    fi
    echo
    echo "## Dynamic fragment instantiation from Intent extras"
    if [[ ${#DYNAMIC_LOADS[@]:-} -gt 0 ]]; then
      for d in "${DYNAMIC_LOADS[@]:-}"; do echo "- \`${d}\`"; done
    else
      echo "- _(none found)_"
    fi
    echo
    echo "## AndroidX modern preference API (informational)"
    if [[ ${#ANDROIDX_PREFERENCE[@]:-} -gt 0 ]]; then
      for d in "${ANDROIDX_PREFERENCE[@]:-}"; do echo "- \`${d}\`"; done
      echo
      echo "> _The classic \`PreferenceActivity\` / \`:android:show_fragment\` vector does **not** apply to AndroidX \`PreferenceFragmentCompat\`. For these apps, review the **Dynamic fragment instantiation** findings above — that is the relevant surface._"
    else
      echo "- _(none found)_"
    fi
    echo
    echo "## Fragment injection candidates (injectable)"
    if [[ ${#CANDIDATES[@]:-} -gt 0 ]]; then
      for c in "${CANDIDATES[@]:-}"; do echo "- \`${c}\`"; done
    else
      echo "- _(none — see the playbook for manual confirmation steps)_"
    fi
    echo
    echo "## Broken — missing isValidFragment with targetSdk ≥ 19 (crash, not exploitable)"
    if [[ ${#BROKEN_CLASSES[@]:-} -gt 0 ]]; then
      for c in "${BROKEN_CLASSES[@]:-}"; do echo "- \`${c}\`"; done
    else
      echo "- _(none)_"
    fi
  } > "$REPORT_FILE"
  echo "REPORT_FILE=${REPORT_FILE}"
fi

# --- Optional JSON report ----------------------------------------------------
if [[ -n "$JSON_FILE" ]]; then
  {
    echo "{"
    echo "  \"package_name\": \"${PACKAGE_NAME}\","
    echo "  \"target_sdk_version\": \"${TARGET_SDK_VERSION}\","
    echo "  \"min_sdk_version\": \"${MIN_SDK_VERSION}\","
    printf '  \"exported_activities\": ['
    if [[ ${#EXPORTED_ACTIVITIES[@]} -gt 0 ]]; then
      for i in "${!EXPORTED_ACTIVITIES[@]}"; do
        [[ "$i" -gt 0 ]] && printf ','
        printf '"%s"' "${EXPORTED_ACTIVITIES[$i]}"
      done
    fi
    echo "],"
    printf '  \"preference_activities\": ['
    if [[ ${#PREF_CLASSES[@]} -gt 0 ]]; then
      for i in "${!PREF_CLASSES[@]}"; do
        [[ "$i" -gt 0 ]] && printf ','
        printf '"%s"' "${PREF_CLASSES[$i]}"
      done
    fi
    echo "],"
    printf '  \"is_valid_fragment\": ['
    if [[ ${#IS_VALID_STATUS[@]} -gt 0 ]]; then
      for i in "${!IS_VALID_STATUS[@]}"; do
        [[ "$i" -gt 0 ]] && printf ','
        s="${IS_VALID_STATUS[$i]}"
        printf '{"class":"%s","status":"%s"}' "${s%%:*}" "${s#*:}"
      done
    fi
    echo "],"
    printf '  \"candidates\": ['
    if [[ ${#CANDIDATES[@]} -gt 0 ]]; then
      for i in "${!CANDIDATES[@]}"; do
        [[ "$i" -gt 0 ]] && printf ','
        printf '"%s"' "${CANDIDATES[$i]}"
      done
    fi
    echo "],"
    printf '  \"broken\": ['
    if [[ ${#BROKEN_CLASSES[@]} -gt 0 ]]; then
      for i in "${!BROKEN_CLASSES[@]}"; do
        [[ "$i" -gt 0 ]] && printf ','
        printf '"%s"' "${BROKEN_CLASSES[$i]}"
      done
    fi
    echo "],"
    echo "  \"candidate_count\": ${CANDIDATE_COUNT},"
    echo "  \"broken_count\": ${BROKEN_COUNT},"
    echo "  \"androidx_preference_count\": ${#ANDROIDX_PREFERENCE[@]}"
    echo "}"
  } > "$JSON_FILE"
  echo "JSON_FILE=${JSON_FILE}"
fi

# --- Exit code ---------------------------------------------------------------
if [[ "$CANDIDATE_COUNT" -gt 0 ]]; then
  exit 0
else
  exit 2
fi