#!/usr/bin/env bash
# find-firebase-config.sh — Detect Google API keys and Firebase configuration
# in a decompiled Android app output, and emit machine-readable values that
# downstream tooling (test-firebase-google.sh) can consume.
#
# Gatekeeper for Phase 9 of the skill: if this script does not find any
# Google API keys or Firebase configuration, the Firebase/Google API testing
# phase MUST be skipped.
set -euo pipefail

usage() {
  cat <<EOF
Usage: find-firebase-config.sh <decompiled-dir> [OPTIONS]

Scan a decompiled Android output directory for Google API keys and
Firebase configuration values (strings.xml, google-services.json,
appsettings.json, AndroidManifest.xml, etc.).

Arguments:
  <decompiled-dir>   Path to the decompile output (the dir that contains
                     resources/ and sources/). Also accepts resources/
                     directly.

Options:
  --env FILE         Write extracted values as shell exports to FILE
                     (ready to \`source\` before running curl tests).
  --json FILE        Write extracted values as JSON to FILE.
  -h, --help         Show this help message.

Machine-readable output (always printed to stdout):
  FIREBASE_FOUND=true|false
  GOOGLE_API_KEY_FOUND=true|false
  API_KEY_COUNT=<n>
  API_KEY[<i>]=<value>
  PROJECT_ID=<value>
  FIREBASE_DATABASE_URL=<value>
  GCM_SENDER_ID=<value>
  GOOGLE_APP_ID=<value>
  STORAGE_BUCKET=<value>
  OAUTH_CLIENT_ID=<value>
  PACKAGE_NAME=<value>

Exit codes:
  0  at least one Google API key or Firebase config value was found
     -> Phase 9 testing SHOULD run
  2  nothing relevant found
     -> Phase 9 testing MUST be skipped
  1  usage / input error
EOF
  exit 0
}

TARGET=""
ENV_FILE=""
JSON_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)    ENV_FILE="$2"; shift 2 ;;
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

# Resolve the resources root. Accept either the decompile root or resources/.
if [[ -d "$TARGET/resources" ]]; then
  RES_DIR="$TARGET/resources"
else
  RES_DIR="$TARGET"
fi

# --- Helpers -----------------------------------------------------------------

# Extract the value of an Android string resource by name.
# Usage: xml_string_value <name>
xml_string_value() {
  local name="$1"
  local file="$RES_DIR/res/values/strings.xml"
  [[ -f "$file" ]] || { echo ""; return; }
  # Match: <string name="foo">value</string>  (allow extra attrs, CDATA-free)
  sed -n -E "s|.*<string[^>]*name=\"${name}\"[^>]*>([^<]*)</string>.*|\1|p" \
    "$file" | head -n1
}

# Extract a Google API key (AIza...) from any file under the target.
extract_api_keys() {
  # Google API keys have a well-known shape: "AIza" + 35 chars (letters, digits, _-).
  grep -rhoE 'AIza[0-9A-Za-z_\-]{35}' "$TARGET" 2>/dev/null | sort -u || true
}

# Extract package from AndroidManifest.xml.
extract_package() {
  local file="$RES_DIR/AndroidManifest.xml"
  [[ -f "$file" ]] || { echo ""; return; }
  sed -n -E 's|.*package="([^"]+)".*|\1|p' "$file" | head -n1
}

# Check common asset files for extra keys/ids.
asset_first_match() {
  local pattern="$1"
  local file
  for file in \
    "$TARGET/assets/google-services.json" \
    "$TARGET/assets/appsettings.json" \
    "$RES_DIR/assets/google-services.json" \
    "$RES_DIR/assets/appsettings.json"; do
    if [[ -f "$file" ]]; then
      grep -oE "$pattern" "$file" | head -n1 && return 0
    fi
  done
  return 0
}

# --- Extraction --------------------------------------------------------------

PROJECT_ID="$(xml_string_value project_id)"
FIREBASE_DATABASE_URL="$(xml_string_value firebase_database_url)"
GCM_SENDER_ID="$(xml_string_value gcm_defaultSenderId)"
GOOGLE_APP_ID="$(xml_string_value google_app_id)"
STORAGE_BUCKET="$(xml_string_value google_storage_bucket)"
OAUTH_CLIENT_ID="$(xml_string_value default_web_client_id)"
STRINGS_GOOGLE_API_KEY="$(xml_string_value google_api_key)"
PACKAGE_NAME="$(extract_package)"

# Collect API keys from anywhere in the decompile tree (manifest meta-data,
# strings.xml, JSON assets, embedded in code, etc.).
# Portable alternative to `mapfile` (bash 3.2 compatible).
API_KEYS=()
while IFS= read -r line; do
  [[ -n "$line" ]] && API_KEYS+=("$line")
done < <(extract_api_keys)

# Promote strings.xml key into the list if it wasn't caught (rare).
if [[ -n "$STRINGS_GOOGLE_API_KEY" ]]; then
  FOUND=false
  for k in "${API_KEYS[@]:-}"; do
    [[ "$k" == "$STRINGS_GOOGLE_API_KEY" ]] && FOUND=true && break
  done
  if [[ "$FOUND" == false ]]; then
    API_KEYS+=("$STRINGS_GOOGLE_API_KEY")
  fi
fi

# Any Firebase-specific value present?
FIREBASE_FOUND=false
for v in "$PROJECT_ID" "$FIREBASE_DATABASE_URL" "$GCM_SENDER_ID" \
         "$GOOGLE_APP_ID" "$STORAGE_BUCKET" "$OAUTH_CLIENT_ID"; do
  if [[ -n "$v" ]]; then FIREBASE_FOUND=true; break; fi
done

# Also treat presence of google-services.json as a Firebase indicator.
if [[ "$FIREBASE_FOUND" == false ]]; then
  if [[ -f "$TARGET/assets/google-services.json" ]] \
     || [[ -f "$RES_DIR/assets/google-services.json" ]]; then
    FIREBASE_FOUND=true
  fi
fi

API_KEY_COUNT=${#API_KEYS[@]}
GOOGLE_API_KEY_FOUND=false
[[ "$API_KEY_COUNT" -gt 0 ]] && GOOGLE_API_KEY_FOUND=true

# --- Emit machine-readable stdout --------------------------------------------

echo "FIREBASE_FOUND=${FIREBASE_FOUND}"
echo "GOOGLE_API_KEY_FOUND=${GOOGLE_API_KEY_FOUND}"
echo "API_KEY_COUNT=${API_KEY_COUNT}"
for i in "${!API_KEYS[@]}"; do
  echo "API_KEY[${i}]=${API_KEYS[$i]}"
done
echo "PROJECT_ID=${PROJECT_ID}"
echo "FIREBASE_DATABASE_URL=${FIREBASE_DATABASE_URL}"
echo "GCM_SENDER_ID=${GCM_SENDER_ID}"
echo "GOOGLE_APP_ID=${GOOGLE_APP_ID}"
echo "STORAGE_BUCKET=${STORAGE_BUCKET}"
echo "OAUTH_CLIENT_ID=${OAUTH_CLIENT_ID}"
echo "PACKAGE_NAME=${PACKAGE_NAME}"

# --- Optional: env export file ----------------------------------------------
if [[ -n "$ENV_FILE" ]]; then
  {
    echo "# Extracted by find-firebase-config.sh on $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    # Export the first API key as API_KEY; expose all as API_KEYS array.
    if [[ "$API_KEY_COUNT" -gt 0 ]]; then
      echo "export API_KEY=\"${API_KEYS[0]}\""
      printf 'export API_KEYS=('
      for k in "${API_KEYS[@]}"; do printf ' %q' "$k"; done
      printf ' )\n'
    fi
    [[ -n "$PROJECT_ID" ]]            && echo "export PROJECT_ID=\"${PROJECT_ID}\""
    [[ -n "$FIREBASE_DATABASE_URL" ]] && echo "export DB_URL=\"${FIREBASE_DATABASE_URL}\""
    [[ -n "$GCM_SENDER_ID" ]]         && echo "export GCM_SENDER_ID=\"${GCM_SENDER_ID}\""
    [[ -n "$GOOGLE_APP_ID" ]]         && echo "export APP_ID=\"${GOOGLE_APP_ID}\""
    [[ -n "$STORAGE_BUCKET" ]]        && echo "export STORAGE_BUCKET=\"${STORAGE_BUCKET}\""
    [[ -n "$OAUTH_CLIENT_ID" ]]       && echo "export OAUTH_CLIENT_ID=\"${OAUTH_CLIENT_ID}\""
    [[ -n "$PACKAGE_NAME" ]]          && echo "export PACKAGE=\"${PACKAGE_NAME}\""
  } > "$ENV_FILE"
  echo "ENV_FILE=${ENV_FILE}"
fi

# --- Optional: JSON file -----------------------------------------------------
if [[ -n "$JSON_FILE" ]]; then
  {
    echo "{"
    echo "  \"firebase_found\": ${FIREBASE_FOUND},"
    echo "  \"google_api_key_found\": ${GOOGLE_API_KEY_FOUND},"
    printf '  "api_keys": ['
    for i in "${!API_KEYS[@]}"; do
      [[ "$i" -gt 0 ]] && printf ','
      printf '"%s"' "${API_KEYS[$i]}"
    done
    echo "],"
    echo "  \"project_id\": \"${PROJECT_ID}\","
    echo "  \"firebase_database_url\": \"${FIREBASE_DATABASE_URL}\","
    echo "  \"gcm_sender_id\": \"${GCM_SENDER_ID}\","
    echo "  \"google_app_id\": \"${GOOGLE_APP_ID}\","
    echo "  \"storage_bucket\": \"${STORAGE_BUCKET}\","
    echo "  \"oauth_client_id\": \"${OAUTH_CLIENT_ID}\","
    echo "  \"package_name\": \"${PACKAGE_NAME}\""
    echo "}"
  } > "$JSON_FILE"
  echo "JSON_FILE=${JSON_FILE}"
fi

# --- Exit code drives Phase 9 gating ----------------------------------------
if [[ "$FIREBASE_FOUND" == true || "$GOOGLE_API_KEY_FOUND" == true ]]; then
  exit 0
else
  exit 2
fi
