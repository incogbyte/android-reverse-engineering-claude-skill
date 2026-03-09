#!/usr/bin/env bash
# find-api-calls.sh — Search decompiled source for API calls and HTTP endpoints
set -euo pipefail

usage() {
  cat <<EOF
Usage: find-api-calls.sh <source-dir> [OPTIONS]

Search decompiled Java/Kotlin source for HTTP API calls and endpoints.

Arguments:
  <source-dir>    Path to the decompiled sources directory

Options:
  --retrofit      Search only for Retrofit annotations
  --okhttp        Search only for OkHttp patterns
  --volley        Search only for Volley patterns
  --urls          Search only for hardcoded URLs
  --auth          Search only for auth-related patterns
  --kotlin        Search only for Kotlin coroutines/Flow patterns
  --rxjava        Search only for RxJava patterns
  --graphql       Search only for GraphQL patterns
  --websocket     Search only for WebSocket patterns
  --security      Search only for security patterns (cert pinning, debug flags)
  --all           Search all patterns (default)
  --report FILE   Export results as Markdown report to FILE
  --context N     Show N lines of context around matches (default: 0)
  --dedup         Deduplicate results by endpoint/URL
  -h, --help      Show this help message

Output:
  Results are printed as file:line:match for easy navigation.
  With --report, a structured Markdown report is also generated.
EOF
  exit 0
}

SOURCE_DIR=""
SEARCH_RETROFIT=false
SEARCH_OKHTTP=false
SEARCH_VOLLEY=false
SEARCH_URLS=false
SEARCH_AUTH=false
SEARCH_KOTLIN=false
SEARCH_RXJAVA=false
SEARCH_GRAPHQL=false
SEARCH_WEBSOCKET=false
SEARCH_SECURITY=false
SEARCH_ALL=true
REPORT_FILE=""
CONTEXT_LINES=0
DEDUP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --retrofit)   SEARCH_RETROFIT=true;   SEARCH_ALL=false; shift ;;
    --okhttp)     SEARCH_OKHTTP=true;     SEARCH_ALL=false; shift ;;
    --volley)     SEARCH_VOLLEY=true;      SEARCH_ALL=false; shift ;;
    --urls)       SEARCH_URLS=true;        SEARCH_ALL=false; shift ;;
    --auth)       SEARCH_AUTH=true;        SEARCH_ALL=false; shift ;;
    --kotlin)     SEARCH_KOTLIN=true;      SEARCH_ALL=false; shift ;;
    --rxjava)     SEARCH_RXJAVA=true;      SEARCH_ALL=false; shift ;;
    --graphql)    SEARCH_GRAPHQL=true;     SEARCH_ALL=false; shift ;;
    --websocket)  SEARCH_WEBSOCKET=true;   SEARCH_ALL=false; shift ;;
    --security)   SEARCH_SECURITY=true;    SEARCH_ALL=false; shift ;;
    --all)        SEARCH_ALL=true; shift ;;
    --report)     REPORT_FILE="$2"; shift 2 ;;
    --context)    CONTEXT_LINES="$2"; shift 2 ;;
    --dedup)      DEDUP=true; shift ;;
    -h|--help)    usage ;;
    -*)           echo "Error: Unknown option $1" >&2; usage ;;
    *)            SOURCE_DIR="$1"; shift ;;
  esac
done

if [[ -z "$SOURCE_DIR" ]]; then
  echo "Error: No source directory specified." >&2
  usage
fi

if [[ ! -d "$SOURCE_DIR" ]]; then
  echo "Error: Directory not found: $SOURCE_DIR" >&2
  exit 1
fi

GREP_OPTS="-rn --include=*.java --include=*.kt"
CONTEXT_FLAG=""
if [[ "$CONTEXT_LINES" -gt 0 ]]; then
  CONTEXT_FLAG="-C $CONTEXT_LINES"
fi

# Report buffer
REPORT_CONTENT=""
SECTION_COUNTS=()

section() {
  echo
  echo "==== $1 ===="
  echo
  if [[ -n "$REPORT_FILE" ]]; then
    REPORT_CONTENT+=$'\n'"## $1"$'\n\n'
  fi
}

run_grep() {
  local case_flag=""
  if [[ "$1" == "-i" ]]; then
    case_flag="-i"
    shift
  fi
  local pattern="$1"
  local results=""
  # shellcheck disable=SC2086
  results=$(grep $GREP_OPTS $CONTEXT_FLAG $case_flag -E "$pattern" "$SOURCE_DIR" 2>/dev/null || true)

  if [[ -n "$results" ]]; then
    if [[ "$DEDUP" == true ]]; then
      results=$(echo "$results" | sort -t: -k3 -u)
    fi
    echo "$results"
    local count
    count=$(echo "$results" | grep -c '' || true)
    SECTION_COUNTS+=("$count")
    if [[ -n "$REPORT_FILE" ]]; then
      REPORT_CONTENT+='```'$'\n'"$results"$'\n''```'$'\n\n'
    fi
  else
    SECTION_COUNTS+=("0")
    if [[ -n "$REPORT_FILE" ]]; then
      REPORT_CONTENT+="_No matches found._"$'\n\n'
    fi
  fi
}

# --- Retrofit ---
if [[ "$SEARCH_ALL" == true || "$SEARCH_RETROFIT" == true ]]; then
  section "Retrofit Annotations"
  run_grep '@(GET|POST|PUT|DELETE|PATCH|HEAD|OPTIONS|HTTP)\s*\('
  section "Retrofit Headers & Parameters"
  run_grep '@(Headers|Header|Query|QueryMap|Path|Body|Field|FieldMap|Part|PartMap|Url)\s*\('
  section "Retrofit Base URL"
  run_grep '(baseUrl|base_url)\s*\('
fi

# --- OkHttp ---
if [[ "$SEARCH_ALL" == true || "$SEARCH_OKHTTP" == true ]]; then
  section "OkHttp Request Building"
  run_grep '(Request\.Builder|HttpUrl|\.newCall|\.enqueue|addInterceptor|addNetworkInterceptor)'
  section "OkHttp URL Construction"
  run_grep '(\.url\s*\(|\.addQueryParameter|\.addPathSegment|\.scheme\s*\(|\.host\s*\()'
fi

# --- Volley ---
if [[ "$SEARCH_ALL" == true || "$SEARCH_VOLLEY" == true ]]; then
  section "Volley Requests"
  run_grep '(StringRequest|JsonObjectRequest|JsonArrayRequest|ImageRequest|RequestQueue|Volley\.newRequestQueue)'
fi

# --- Kotlin Coroutines / Flow ---
if [[ "$SEARCH_ALL" == true || "$SEARCH_KOTLIN" == true ]]; then
  section "Kotlin Coroutines (suspend functions)"
  run_grep '(suspend\s+fun|\.await\(\)|withContext\s*\(|Dispatchers\.(IO|Main|Default))'
  section "Kotlin Flow"
  run_grep '(Flow<|StateFlow<|SharedFlow<|MutableStateFlow|MutableSharedFlow|\.collect\s*\{|\.collectLatest|\.stateIn|\.shareIn|flowOf|channelFlow|callbackFlow)'
  section "Kotlin Channel"
  run_grep '(Channel<|\.send\(|\.receive\(|\.consumeEach|produce\s*\{)'
fi

# --- RxJava / RxKotlin ---
if [[ "$SEARCH_ALL" == true || "$SEARCH_RXJAVA" == true ]]; then
  section "RxJava Observable/Single/Completable"
  run_grep '(Observable<|Single<|Completable|Maybe<|Flowable<|\.subscribe\s*\(|\.subscribeOn|\.observeOn|CompositeDisposable|DisposableObserver)'
  section "RxJava Operators (network-related)"
  run_grep '(\.flatMap\s*\(|\.map\s*\(|\.switchMap|\.concatMap|\.zip\(|\.merge\(|\.retry\(|\.retryWhen|Schedulers\.(io|computation|newThread))'
  section "LiveData"
  run_grep '(LiveData<|MutableLiveData<|MediatorLiveData<|\.observe\s*\(|\.postValue|\.setValue|Transformations\.(map|switchMap))'
fi

# --- GraphQL ---
if [[ "$SEARCH_ALL" == true || "$SEARCH_GRAPHQL" == true ]]; then
  section "GraphQL Queries & Mutations"
  run_grep '(query\s*\{|mutation\s*\{|subscription\s*\{|""".*query|graphql|GraphQL|ApolloClient|ApolloCall|\.query\(|\.mutate\()'
  section "GraphQL Schema & Operations"
  run_grep -i '(graphql[_-]?url|graphql[_-]?endpoint|operationName|variables.*query)'
fi

# --- WebSocket ---
if [[ "$SEARCH_ALL" == true || "$SEARCH_WEBSOCKET" == true ]]; then
  section "WebSocket Connections"
  run_grep '(WebSocket|WebSocketListener|OkHttpClient.*newWebSocket|\.newWebSocket\s*\(|wss?://[^"]*")'
  section "Socket.IO & Scarlet"
  run_grep '(io\.socket|Socket\.IO|Scarlet|@Receive|@Send|MessageAdapter|StreamAdapter)'
fi

# --- Hardcoded URLs ---
if [[ "$SEARCH_ALL" == true || "$SEARCH_URLS" == true ]]; then
  section "Hardcoded URLs (http:// and https://)"
  run_grep '"https?://[^"]+'
  section "HttpURLConnection"
  run_grep '(openConnection|setRequestMethod|HttpURLConnection|HttpsURLConnection)'
  section "WebView URLs"
  run_grep '(loadUrl|loadData|evaluateJavascript|addJavascriptInterface|WebViewClient|WebChromeClient)'
fi

# --- Auth patterns ---
if [[ "$SEARCH_ALL" == true || "$SEARCH_AUTH" == true ]]; then
  section "Authentication & API Keys"
  run_grep -i '(api[_-]?key|auth[_-]?token|bearer|authorization|x-api-key|client[_-]?secret|access[_-]?token)'
  section "Base URLs and Constants"
  run_grep -i '(BASE_URL|API_URL|SERVER_URL|ENDPOINT|API_BASE|HOST_NAME)'
fi

# --- Security Patterns ---
if [[ "$SEARCH_ALL" == true || "$SEARCH_SECURITY" == true ]]; then
  section "Certificate Pinning"
  run_grep '(CertificatePinner|\.pin\s*\(|sha256/|TrustManager|X509TrustManager|SSLContext|TrustManagerFactory|HostnameVerifier|ALLOW_ALL_HOSTNAME_VERIFIER|network_security_config|NetworkSecurityConfig)'
  section "Disabled Security (Dangerous)"
  run_grep '(checkClientTrusted|checkServerTrusted|getAcceptedIssuers|ALLOW_ALL|trustAllCerts|trustAll|disableSSL|insecure|verify.*return\s+true|setHostnameVerifier)'
  section "Debug & Development Flags"
  run_grep -i '(BuildConfig\.DEBUG|isDebuggable|android:debuggable|StrictMode|\.setDebug|LOG_LEVEL|VERBOSE|enableLogging|DEBUG_MODE|STAGING|DEV_MODE)'
  section "Exposed Secrets & Credentials"
  run_grep -i '(password\s*=\s*"|secret\s*=\s*"|private[_-]?key|ENCRYPTION[_-]?KEY|AES[_-]?KEY|IV[_-]?VECTOR|SALT\s*=|firebase[_-]?key|aws[_-]?key|google[_-]?api|maps[_-]?key|SENDGRID|TWILIO|STRIPE[_-]?KEY|PAYPAL)'
  section "Crypto & Encryption Usage"
  run_grep '(Cipher\.getInstance|SecretKeySpec|KeyGenerator|MessageDigest|\.encrypt\(|\.decrypt\(|AES|RSA|PBKDF2|SHA-256|MD5)'
fi

# --- Summary ---
echo
echo "=== Search complete ==="

total_matches=0
for c in "${SECTION_COUNTS[@]}"; do
  total_matches=$((total_matches + c))
done
echo "Total matches: $total_matches"

# --- Generate report ---
if [[ -n "$REPORT_FILE" ]]; then
  {
    echo "# API & Security Analysis Report"
    echo
    echo "**Source directory**: \`$SOURCE_DIR\`"
    echo "**Generated**: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "**Total matches**: $total_matches"
    echo
    echo "$REPORT_CONTENT"
    echo "---"
    echo
    echo "_Report generated by android-reverse-engineering-skill_"
  } > "$REPORT_FILE"
  echo "Report saved to: $REPORT_FILE"
fi
