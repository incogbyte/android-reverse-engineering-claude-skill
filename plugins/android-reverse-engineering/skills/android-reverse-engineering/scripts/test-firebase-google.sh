#!/usr/bin/env bash
# test-firebase-google.sh — Run the Phase 9 Firebase & Google API test matrix.
#
# Consumes the env file produced by find-firebase-config.sh (or accepts the
# same variables via --env/CLI flags) and exercises Firebase Auth, Realtime
# Database, Firestore, Remote Config, Storage, Dynamic Links, FCM, the Gemini
# API, and the billable Maps/AI family. Outputs a structured Markdown report
# and machine-readable status lines.
#
# ONLY use this script on applications you are authorized to test.
set -euo pipefail

usage() {
  cat <<EOF
Usage: test-firebase-google.sh [OPTIONS]

Run the Firebase & Google API test playbook (references/firebase-google-api-testing.md).

Options:
  --env FILE            Source FILE (produced by find-firebase-config.sh --env)
                        to set API_KEY, PROJECT_ID, DB_URL, APP_ID,
                        GCM_SENDER_ID, PACKAGE, etc.
  --api-key KEY         Override/set API_KEY for this run.
  --project-id ID       Override/set PROJECT_ID.
  --db-url URL          Override/set DB_URL (Firebase Realtime DB base URL).
  --app-id ID           Override/set APP_ID (google_app_id).
  --gcm-sender-id ID    Override/set GCM_SENDER_ID.
  --package NAME        Override/set PACKAGE (Android package name).
  --report FILE         Write a Markdown report to FILE (default:
                        firebase-google-report.md in \$PWD).
  --skip-billable       Skip Section 9 (Maps/AI/YouTube — all billable).
  --skip-writes         Skip write/create tests (RealtimeDB PUT, FCM send,
                        Dynamic Links creation).
  --only SECTIONS       Comma-separated subset: auth,rtdb,firestore,
                        remoteconfig,storage,dynamiclinks,fcm,gemini,billable
  -h, --help            Show this help message.

Exit codes:
  0  run completed (findings may or may not exist; see report)
  1  usage / input error
  3  no API_KEY available — cannot run any probe
EOF
  exit 0
}

# --- Defaults ---------------------------------------------------------------
ENV_FILE=""
API_KEY="${API_KEY:-}"
PROJECT_ID="${PROJECT_ID:-}"
DB_URL="${DB_URL:-}"
APP_ID="${APP_ID:-}"
GCM_SENDER_ID="${GCM_SENDER_ID:-}"
PACKAGE="${PACKAGE:-}"
REPORT_FILE=""
SKIP_BILLABLE=false
SKIP_WRITES=false
ONLY=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)            ENV_FILE="$2"; shift 2 ;;
    --api-key)        API_KEY="$2"; shift 2 ;;
    --project-id)     PROJECT_ID="$2"; shift 2 ;;
    --db-url)         DB_URL="$2"; shift 2 ;;
    --app-id)         APP_ID="$2"; shift 2 ;;
    --gcm-sender-id)  GCM_SENDER_ID="$2"; shift 2 ;;
    --package)        PACKAGE="$2"; shift 2 ;;
    --report)         REPORT_FILE="$2"; shift 2 ;;
    --skip-billable)  SKIP_BILLABLE=true; shift ;;
    --skip-writes)    SKIP_WRITES=true; shift ;;
    --only)           ONLY="$2"; shift 2 ;;
    -h|--help)        usage ;;
    *)                echo "Error: Unknown option $1" >&2; exit 1 ;;
  esac
done

if [[ -n "$ENV_FILE" ]]; then
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "Error: --env file not found: $ENV_FILE" >&2; exit 1
  fi
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

if [[ -z "$API_KEY" ]]; then
  echo "Error: API_KEY is empty. Pass --api-key, or an --env file produced by find-firebase-config.sh." >&2
  exit 3
fi

REPORT_FILE="${REPORT_FILE:-$PWD/firebase-google-report.md}"

# Section enablement -- default: all on, then restrict if --only supplied.
RUN_AUTH=true
RUN_RTDB=true
RUN_FIRESTORE=true
RUN_REMOTECONFIG=true
RUN_STORAGE=true
RUN_DYNAMICLINKS=true
RUN_FCM=true
RUN_GEMINI=true
RUN_BILLABLE=true
if [[ -n "$ONLY" ]]; then
  RUN_AUTH=false; RUN_RTDB=false; RUN_FIRESTORE=false; RUN_REMOTECONFIG=false
  RUN_STORAGE=false; RUN_DYNAMICLINKS=false; RUN_FCM=false; RUN_GEMINI=false
  RUN_BILLABLE=false
  IFS=',' read -ra parts <<< "$ONLY"
  for p in "${parts[@]}"; do
    case "$p" in
      auth)          RUN_AUTH=true ;;
      rtdb)          RUN_RTDB=true ;;
      firestore)     RUN_FIRESTORE=true ;;
      remoteconfig)  RUN_REMOTECONFIG=true ;;
      storage)       RUN_STORAGE=true ;;
      dynamiclinks)  RUN_DYNAMICLINKS=true ;;
      fcm)           RUN_FCM=true ;;
      gemini)        RUN_GEMINI=true ;;
      billable)      RUN_BILLABLE=true ;;
      *) echo "Error: unknown --only section: $p" >&2; exit 1 ;;
    esac
  done
fi
[[ "$SKIP_BILLABLE" == true ]] && RUN_BILLABLE=false

# --- Report & test plumbing -------------------------------------------------
VULN_COUNT=0
PROBE_COUNT=0
REPORT_BUF=""

# Append a header line to the buffer.
rep_section() { REPORT_BUF+=$'\n'"## $1"$'\n\n'; }

# Run a curl probe and record result.
# Usage: run_probe "<label>" <curl args...>
run_probe() {
  local label="$1"; shift
  PROBE_COUNT=$((PROBE_COUNT + 1))

  local tmp_body tmp_headers
  tmp_body="$(mktemp)"; tmp_headers="$(mktemp)"
  local status
  status=$(curl -sS -o "$tmp_body" -D "$tmp_headers" -w '%{http_code}' "$@" || echo "000")

  local body_preview
  body_preview=$(head -c 1500 "$tmp_body")

  # Heuristic classification.
  local verdict="INFO"
  if [[ "$status" == "200" ]]; then
    if grep -qE '"(idToken|items|documents|entries|fields|shortLink|state":"UPDATE"|localId)"' "$tmp_body"; then
      verdict="VULNERABLE"
      VULN_COUNT=$((VULN_COUNT + 1))
    elif grep -q '"error"' "$tmp_body"; then
      verdict="ERROR-200"
    else
      verdict="OK"
    fi
  elif [[ "$status" == "400" || "$status" == "401" || "$status" == "403" ]]; then
    if grep -qE 'ADMIN_ONLY_OPERATION|OPERATION_NOT_ALLOWED|PERMISSION_DENIED|SERVICE_DISABLED|REQUEST_DENIED|NO_TEMPLATE|EMAIL_NOT_FOUND|INVALID_IDP_RESPONSE' "$tmp_body"; then
      verdict="SAFE"
    else
      verdict="BLOCKED"
    fi
  elif [[ "$status" == "404" ]]; then
    verdict="NOT_FOUND"
  elif [[ "$status" == "000" ]]; then
    verdict="NETWORK_ERROR"
  fi

  printf '[%s] %s -> HTTP %s\n' "$verdict" "$label" "$status"

  REPORT_BUF+="### ${label}"$'\n\n'
  REPORT_BUF+="- Status: \`${status}\`"$'\n'
  REPORT_BUF+="- Verdict: **${verdict}**"$'\n\n'
  REPORT_BUF+='```json'$'\n'"${body_preview}"$'\n''```'$'\n\n'

  rm -f "$tmp_body" "$tmp_headers"

  # Stash idToken when we see one so later probes can use $JWT.
  if [[ "$verdict" == "VULNERABLE" && -z "${JWT:-}" ]]; then
    JWT=$(printf '%s' "$body_preview" | sed -n -E 's/.*"idToken":"([^"]+)".*/\1/p' | head -n1 || true)
    if [[ -n "$JWT" ]]; then
      echo "  > captured idToken for authenticated probes"
    fi
  fi
}

# --- Banner -----------------------------------------------------------------
echo "=== Firebase & Google API test run ==="
echo "API_KEY fingerprint : ${API_KEY:0:6}...${API_KEY: -4}"
echo "PROJECT_ID          : ${PROJECT_ID:-<unset>}"
echo "DB_URL              : ${DB_URL:-<unset>}"
echo "APP_ID              : ${APP_ID:-<unset>}"
echo "GCM_SENDER_ID       : ${GCM_SENDER_ID:-<unset>}"
echo "PACKAGE             : ${PACKAGE:-<unset>}"
echo

JWT=""

# --- 1. Firebase Auth -------------------------------------------------------
if [[ "$RUN_AUTH" == true ]]; then
  rep_section "Firebase Authentication"

  run_probe "1.1 Anonymous signUp" \
    -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"returnSecureToken":true}'

  run_probe "1.2 Email/password signUp (audit-test)" \
    -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"email":"audit-'"$RANDOM"'@proton.me","password":"AuditTest123!","returnSecureToken":true}'

  run_probe "1.3 Email/password signInWithPassword" \
    -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"email":"test@test.com","password":"test123","returnSecureToken":true}'

  run_probe "1.4 createAuthUri (user enumeration)" \
    -X POST "https://identitytoolkit.googleapis.com/v1/accounts:createAuthUri?key=${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"identifier":"test@test.com","continueUri":"https://example.com"}'

  run_probe "1.5 signInWithIdp google.com" \
    -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"postBody":"id_token=test&providerId=google.com","requestUri":"https://example.com","returnSecureToken":true}'

  run_probe "1.6 signInWithIdp apple.com" \
    -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"postBody":"id_token=test&providerId=apple.com","requestUri":"https://example.com","returnSecureToken":true}'

  run_probe "1.7 Phone sendVerificationCode" \
    -X POST "https://identitytoolkit.googleapis.com/v1/accounts:sendVerificationCode?key=${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"phoneNumber":"+1234567890","recaptchaToken":"test"}'

  run_probe "1.8 sendOobCode EMAIL_SIGNIN" \
    -X POST "https://identitytoolkit.googleapis.com/v1/accounts:sendOobCode?key=${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"requestType":"EMAIL_SIGNIN","email":"test@test.com","continueUrl":"https://example.com"}'

  run_probe "1.9 sendOobCode PASSWORD_RESET (enumeration)" \
    -X POST "https://identitytoolkit.googleapis.com/v1/accounts:sendOobCode?key=${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"requestType":"PASSWORD_RESET","email":"admin@target.com"}'

  run_probe "1.10 signInWithCustomToken" \
    -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"token":"test","returnSecureToken":true}'

  if [[ -n "$JWT" ]]; then
    run_probe "1.11 accounts:lookup (using captured idToken)" \
      -X POST "https://identitytoolkit.googleapis.com/v1/accounts:lookup?key=${API_KEY}" \
      -H "Content-Type: application/json" \
      -d "{\"idToken\":\"${JWT}\"}"
  fi
fi

# --- 2. Realtime Database ---------------------------------------------------
if [[ "$RUN_RTDB" == true ]]; then
  rep_section "Firebase Realtime Database"
  if [[ -z "$DB_URL" ]]; then
    REPORT_BUF+="_No DB_URL configured — skipped._"$'\n\n'
  else
    run_probe "2.1 Root read (unauth)" "${DB_URL}/.json"
    run_probe "2.1 Root read shallow (unauth)" "${DB_URL}/.json?shallow=true"
    for path in users config app_config settings stores products public version notifications orders customers messages; do
      run_probe "2.2 /${path}.json (unauth)" "${DB_URL}/${path}.json"
    done
    run_probe "2.3 Read rules" "${DB_URL}/.settings/rules.json"

    if [[ -n "$JWT" ]]; then
      run_probe "2.4 Root read (auth=JWT)" "${DB_URL}/.json?auth=${JWT}"
      run_probe "2.4 Root shallow (auth=JWT)" "${DB_URL}/.json?shallow=true&auth=${JWT}"
      for path in users config settings stores; do
        run_probe "2.4 /${path}.json (auth=JWT)" "${DB_URL}/${path}.json?auth=${JWT}"
      done
    fi

    if [[ "$SKIP_WRITES" == false ]]; then
      run_probe "2.5 PUT audit_test (unauth)" -X PUT "${DB_URL}/audit_test.json" -d '{"test":true}'
      run_probe "2.5 DELETE audit_test (cleanup)" -X DELETE "${DB_URL}/audit_test.json"
    fi
  fi
fi

# --- 3. Firestore -----------------------------------------------------------
if [[ "$RUN_FIRESTORE" == true ]]; then
  rep_section "Cloud Firestore"
  if [[ -z "$PROJECT_ID" ]]; then
    REPORT_BUF+="_No PROJECT_ID configured — skipped._"$'\n\n'
  else
    run_probe "3.1 List root documents" \
      "https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents?key=${API_KEY}"
    for col in users customers orders products config settings app_config prescriptions stores notifications; do
      run_probe "3.2 /${col} (pageSize=3)" \
        "https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents/${col}?key=${API_KEY}&pageSize=3"
    done
    if [[ -n "$JWT" ]]; then
      run_probe "3.3 List documents (Bearer JWT)" \
        -H "Authorization: Bearer ${JWT}" \
        "https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents"
    fi
  fi
fi

# --- 4. Remote Config -------------------------------------------------------
if [[ "$RUN_REMOTECONFIG" == true ]]; then
  rep_section "Firebase Remote Config"
  if [[ -z "$GCM_SENDER_ID" || -z "$APP_ID" || -z "$PACKAGE" ]]; then
    REPORT_BUF+="_Missing GCM_SENDER_ID/APP_ID/PACKAGE — skipped._"$'\n\n'
  else
    run_probe "4. remoteconfig:fetch" \
      -X POST "https://firebaseremoteconfig.googleapis.com/v1/projects/${GCM_SENDER_ID}/namespaces/firebase:fetch?key=${API_KEY}" \
      -H "Content-Type: application/json" \
      -H "X-Goog-Api-Key: ${API_KEY}" \
      -H "X-Android-Package: ${PACKAGE}" \
      -d "{\"appInstanceId\":\"test_instance\",\"appId\":\"${APP_ID}\",\"languageCode\":\"en\",\"platformVersion\":\"26\",\"sdkVersion\":\"21.6.4\",\"packageName\":\"${PACKAGE}\",\"appVersion\":\"1.0.0\"}"
  fi
fi

# --- 5. Storage -------------------------------------------------------------
if [[ "$RUN_STORAGE" == true ]]; then
  rep_section "Firebase Cloud Storage"
  if [[ -z "$PROJECT_ID" ]]; then
    REPORT_BUF+="_No PROJECT_ID configured — skipped._"$'\n\n'
  else
    run_probe "5. Bucket listing (.appspot.com)" \
      "https://firebasestorage.googleapis.com/v0/b/${PROJECT_ID}.appspot.com/o?key=${API_KEY}"
    run_probe "5. Bucket listing (.firebasestorage.app)" \
      "https://firebasestorage.googleapis.com/v0/b/${PROJECT_ID}.firebasestorage.app/o?key=${API_KEY}"
  fi
fi

# --- 6. Dynamic Links -------------------------------------------------------
if [[ "$RUN_DYNAMICLINKS" == true && "$SKIP_WRITES" == false ]]; then
  rep_section "Firebase Dynamic Links"
  run_probe "6. shortLinks create (phishing vector check)" \
    -X POST "https://firebasedynamiclinks.googleapis.com/v1/shortLinks?key=${API_KEY}" \
    -H "Content-Type: application/json" \
    -d "{\"longDynamicLink\":\"https://example.page.link/?link=https://evil.com&apn=${PACKAGE:-com.example}\"}"
fi

# --- 7. FCM -----------------------------------------------------------------
if [[ "$RUN_FCM" == true && "$SKIP_WRITES" == false ]]; then
  rep_section "Firebase Cloud Messaging (legacy)"
  run_probe "7. fcm/send (legacy)" \
    -X POST "https://fcm.googleapis.com/fcm/send" \
    -H "Authorization: key=${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"to":"test_token","notification":{"title":"Security Audit","body":"Test"}}'
fi

# --- 8. Gemini --------------------------------------------------------------
if [[ "$RUN_GEMINI" == true ]]; then
  rep_section "Gemini API (TruffleSecurity vector)"
  run_probe "8.1 List files"           "https://generativelanguage.googleapis.com/v1beta/files?key=${API_KEY}"
  run_probe "8.2 List models"          "https://generativelanguage.googleapis.com/v1beta/models?key=${API_KEY}"
  run_probe "8.3 Cached contents"      "https://generativelanguage.googleapis.com/v1beta/cachedContents?key=${API_KEY}"
  run_probe "8.4 gemini-pro:generateContent" \
    -X POST "https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent?key=${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"contents":[{"parts":[{"text":"Say hello"}]}]}'
fi

# --- 9. Billable ------------------------------------------------------------
if [[ "$RUN_BILLABLE" == true ]]; then
  rep_section "Other Google APIs (billable — keep sample minimal)"

  run_probe "9.1 Places textsearch"    "https://maps.googleapis.com/maps/api/place/textsearch/json?query=test&key=${API_KEY}"
  run_probe "9.1 Geocoding"            "https://maps.googleapis.com/maps/api/geocode/json?address=test&key=${API_KEY}"
  run_probe "9.1 Directions"           "https://maps.googleapis.com/maps/api/directions/json?origin=A&destination=B&key=${API_KEY}"
  run_probe "9.1 Distance Matrix"      "https://maps.googleapis.com/maps/api/distancematrix/json?origins=A&destinations=B&key=${API_KEY}"
  run_probe "9.1 Elevation"            "https://maps.googleapis.com/maps/api/elevation/json?locations=0,0&key=${API_KEY}"
  run_probe "9.1 Roads snapToRoads"    "https://roads.googleapis.com/v1/snapToRoads?path=0,0|1,1&key=${API_KEY}"

  run_probe "9.2 Vision annotate" \
    -X POST "https://vision.googleapis.com/v1/images:annotate?key=${API_KEY}" \
    -H "Content-Type: application/json" -d '{"requests":[]}'

  run_probe "9.2 NLP analyzeSentiment" \
    -X POST "https://language.googleapis.com/v1/documents:analyzeSentiment?key=${API_KEY}" \
    -H "Content-Type: application/json" -d '{"document":{"type":"PLAIN_TEXT","content":"test"}}'

  run_probe "9.2 Translate v2" \
    -X POST "https://translation.googleapis.com/language/translate/v2?key=${API_KEY}" \
    -H "Content-Type: application/json" -d '{"q":"hello","target":"es"}'

  run_probe "9.2 Speech recognize" \
    -X POST "https://speech.googleapis.com/v1/speech:recognize?key=${API_KEY}" \
    -H "Content-Type: application/json" -d '{"config":{"languageCode":"en-US"},"audio":{"content":""}}'

  run_probe "9.2 Text-to-Speech synthesize" \
    -X POST "https://texttospeech.googleapis.com/v1/text:synthesize?key=${API_KEY}" \
    -H "Content-Type: application/json" -d '{"input":{"text":"test"},"voice":{"languageCode":"en-US"},"audioConfig":{"audioEncoding":"MP3"}}'

  run_probe "9.3 YouTube search" \
    "https://www.googleapis.com/youtube/v3/search?key=${API_KEY}&part=snippet&q=test&maxResults=1"

  if [[ -n "$PROJECT_ID" ]]; then
    run_probe "9.3 Cloud Functions list" \
      "https://cloudfunctions.googleapis.com/v1/projects/${PROJECT_ID}/locations/-/functions?key=${API_KEY}"
  fi
fi

# --- Final report -----------------------------------------------------------
{
  echo "# Firebase & Google API Test Report"
  echo
  echo "- Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
  echo "- API key fingerprint: \`${API_KEY:0:6}...${API_KEY: -4}\`"
  echo "- PROJECT_ID: \`${PROJECT_ID:-<unset>}\`"
  echo "- DB_URL: \`${DB_URL:-<unset>}\`"
  echo "- APP_ID: \`${APP_ID:-<unset>}\`"
  echo "- GCM_SENDER_ID: \`${GCM_SENDER_ID:-<unset>}\`"
  echo "- PACKAGE: \`${PACKAGE:-<unset>}\`"
  echo "- Probes run: ${PROBE_COUNT}"
  echo "- Probes flagged VULNERABLE: ${VULN_COUNT}"
  echo
  echo "Verdict key: **VULNERABLE** (200 + interesting payload), SAFE (expected block), BLOCKED (unexpected 4xx), NOT_FOUND (404), OK (200, empty/benign), ERROR-200 (200 with error body), INFO (other), NETWORK_ERROR."
  echo "$REPORT_BUF"
} > "$REPORT_FILE"

echo
echo "=== Run complete ==="
echo "PROBE_COUNT=${PROBE_COUNT}"
echo "VULN_COUNT=${VULN_COUNT}"
echo "REPORT_FILE=${REPORT_FILE}"
