# API Extraction Patterns

Patterns and grep commands for finding HTTP API calls in decompiled Android source code.

## Retrofit

Retrofit is the most common HTTP client in Android apps. API endpoints are declared as annotated interface methods.

### Annotations to search for

```bash
# HTTP method annotations
grep -rn '@GET\|@POST\|@PUT\|@DELETE\|@PATCH\|@HEAD' sources/

# Parameter annotations
grep -rn '@Query\|@QueryMap\|@Path\|@Body\|@Field\|@FieldMap\|@Part\|@Header\|@HeaderMap' sources/

# Headers annotation (static headers)
grep -rn '@Headers' sources/

# Base URL configuration
grep -rn 'baseUrl\|\.baseUrl(' sources/
```

### Typical Retrofit interface

```java
public interface ApiService {
    @GET("users/{id}")
    Call<User> getUser(@Path("id") String userId);

    @POST("auth/login")
    @Headers({"Content-Type: application/json"})
    Call<LoginResponse> login(@Body LoginRequest request);
}
```

When documenting, capture: HTTP method, path, path parameters, query parameters, request body type, response type, and any static headers.

## OkHttp

OkHttp is often used directly or as the transport layer for Retrofit.

```bash
# Request building
grep -rn 'Request\.Builder\|Request.Builder\|\.url(\|\.post(\|\.put(\|\.delete(\|\.patch(' sources/

# URL construction
grep -rn 'HttpUrl\|\.addQueryParameter\|\.addPathSegment' sources/

# Interceptors (often add auth headers)
grep -rn 'Interceptor\|addInterceptor\|addNetworkInterceptor\|intercept(' sources/

# Response handling
grep -rn '\.execute()\|\.enqueue(' sources/
```

## Volley

```bash
grep -rn 'StringRequest\|JsonObjectRequest\|JsonArrayRequest\|Volley\.newRequestQueue\|RequestQueue' sources/
```

Volley requests typically pass the URL as a constructor argument and override `getHeaders()` or `getParams()` for custom headers/parameters.

## Kotlin Coroutines & Flow

Modern Android apps use Kotlin coroutines for async network calls. Retrofit interfaces return `suspend` functions, and repositories expose `Flow`.

### Coroutines

```bash
# Suspend functions (async entry points)
grep -rn 'suspend\s\+fun' sources/

# Coroutine context/dispatchers
grep -rn 'withContext\|Dispatchers\.IO\|Dispatchers\.Main\|Dispatchers\.Default' sources/

# Await calls (Deferred → result)
grep -rn '\.await()' sources/

# Coroutine scope/launch
grep -rn 'viewModelScope\|lifecycleScope\|CoroutineScope\|launch\s*{' sources/
```

### Flow

```bash
# Flow types
grep -rn 'Flow<\|StateFlow<\|SharedFlow<\|MutableStateFlow\|MutableSharedFlow' sources/

# Flow collection
grep -rn '\.collect\s*{\|\.collectLatest\|\.stateIn\|\.shareIn' sources/

# Flow builders
grep -rn 'flowOf\|channelFlow\|callbackFlow\|flow\s*{' sources/

# Channel (used for one-shot events)
grep -rn 'Channel<\|\.send(\|\.receive(\|\.consumeEach' sources/
```

### Typical Kotlin Retrofit + Coroutines interface

```kotlin
interface ApiService {
    @GET("users/{id}")
    suspend fun getUser(@Path("id") userId: String): User

    @POST("auth/login")
    suspend fun login(@Body request: LoginRequest): LoginResponse
}

// Repository using Flow
class UserRepository(private val api: ApiService) {
    fun getUser(id: String): Flow<User> = flow {
        emit(api.getUser(id))
    }
}
```

## RxJava / RxKotlin

Many apps use RxJava for reactive network calls, especially older codebases.

```bash
# Observable types
grep -rn 'Observable<\|Single<\|Completable\|Maybe<\|Flowable<' sources/

# Subscription
grep -rn '\.subscribe\s*(\|\.subscribeOn\|\.observeOn\|CompositeDisposable\|DisposableObserver' sources/

# Common operators (network-related)
grep -rn '\.flatMap\s*(\|\.map\s*(\|\.switchMap\|\.concatMap\|\.zip(\|\.merge(' sources/

# Retry logic
grep -rn '\.retry(\|\.retryWhen' sources/

# Schedulers
grep -rn 'Schedulers\.io\|Schedulers\.computation\|AndroidSchedulers\.mainThread' sources/
```

### Typical RxJava Retrofit interface

```java
public interface ApiService {
    @GET("users/{id}")
    Single<User> getUser(@Path("id") String userId);

    @POST("auth/login")
    Observable<LoginResponse> login(@Body LoginRequest request);
}
```

## LiveData

```bash
# LiveData types
grep -rn 'LiveData<\|MutableLiveData<\|MediatorLiveData<' sources/

# Observation
grep -rn '\.observe\s*(\|\.postValue\|\.setValue' sources/

# Transformations
grep -rn 'Transformations\.map\|Transformations\.switchMap' sources/
```

## GraphQL

Apps using GraphQL (often via Apollo) define queries and mutations instead of REST endpoints.

```bash
# Apollo Client
grep -rn 'ApolloClient\|ApolloCall\|\.query(\|\.mutate(' sources/

# GraphQL operations
grep -rn 'query\s*{\|mutation\s*{\|subscription\s*{' sources/

# GraphQL endpoint configuration
grep -rni 'graphql[_-]\?url\|graphql[_-]\?endpoint' sources/

# Operation names
grep -rn 'operationName' sources/
```

### Typical Apollo usage

```kotlin
val apolloClient = ApolloClient.Builder()
    .serverUrl("https://api.example.com/graphql")
    .build()

val response = apolloClient.query(GetUserQuery(id = "123")).execute()
```

## WebSocket

Real-time features use WebSocket connections.

```bash
# OkHttp WebSocket
grep -rn 'WebSocket\|WebSocketListener\|newWebSocket\s*(' sources/

# WebSocket URLs
grep -rn 'wss\?://[^"]*"' sources/

# Socket.IO
grep -rn 'io\.socket\|Socket\.IO' sources/

# Scarlet (type-safe WebSocket client)
grep -rn 'Scarlet\|@Receive\|@Send\|MessageAdapter\|StreamAdapter' sources/
```

## HttpURLConnection (legacy)

```bash
grep -rn 'HttpURLConnection\|HttpsURLConnection\|openConnection\|setRequestMethod\|setRequestProperty' sources/
```

## WebView

```bash
grep -rn 'loadUrl\|evaluateJavascript\|addJavascriptInterface\|WebViewClient\|shouldOverrideUrlLoading' sources/
```

WebView-based apps may load API endpoints via JavaScript bridges. Look for `@JavascriptInterface` annotated methods.

## Hardcoded URLs and Secrets

```bash
# HTTP/HTTPS URLs
grep -rn '"https\?://[^"]*"' sources/

# API keys and tokens
grep -rni 'api[_-]\?key\|api[_-]\?secret\|auth[_-]\?token\|bearer\|access[_-]\?token\|client[_-]\?secret' sources/

# Base URL constants
grep -rni 'BASE_URL\|API_URL\|SERVER_URL\|ENDPOINT\|API_BASE' sources/
```

## Security Patterns

### Certificate Pinning

```bash
# OkHttp CertificatePinner
grep -rn 'CertificatePinner\|\.pin\s*(\|sha256/' sources/

# Custom TrustManager
grep -rn 'TrustManager\|X509TrustManager\|SSLContext\|TrustManagerFactory' sources/

# HostnameVerifier
grep -rn 'HostnameVerifier\|ALLOW_ALL_HOSTNAME_VERIFIER' sources/

# Network Security Config (referenced in AndroidManifest)
grep -rn 'network_security_config\|NetworkSecurityConfig' sources/ resources/
```

### Disabled Security (red flags)

```bash
# Dangerous: trust all certificates
grep -rn 'checkClientTrusted\|checkServerTrusted\|getAcceptedIssuers\|trustAllCerts\|trustAll\|disableSSL' sources/

# Dangerous: disabled hostname verification
grep -rn 'ALLOW_ALL\|verify.*return\s\+true\|setHostnameVerifier' sources/
```

### Exposed Secrets

```bash
# Hardcoded passwords and keys
grep -rni 'password\s*=\s*"\|secret\s*=\s*"\|private[_-]\?key\|ENCRYPTION[_-]\?KEY' sources/

# Third-party API keys
grep -rni 'firebase[_-]\?key\|aws[_-]\?key\|google[_-]\?api\|maps[_-]\?key\|STRIPE[_-]\?KEY\|SENDGRID\|TWILIO\|PAYPAL' sources/
```

### Crypto Usage

```bash
# Cipher and encryption
grep -rn 'Cipher\.getInstance\|SecretKeySpec\|KeyGenerator\|MessageDigest' sources/
grep -rn '\.encrypt(\|\.decrypt(\|AES\|RSA\|PBKDF2\|SHA-256\|MD5' sources/
```

### Debug & Development Flags

```bash
grep -rni 'BuildConfig\.DEBUG\|isDebuggable\|android:debuggable\|StrictMode' sources/
grep -rni 'DEBUG_MODE\|STAGING\|DEV_MODE\|enableLogging' sources/
```

## Documentation Template

For each discovered API endpoint, document it using this template:

```markdown
### `METHOD /path/to/endpoint`

- **Source**: `com.example.app.api.ApiService` (file:line)
- **Base URL**: `https://api.example.com/v1`
- **Full URL**: `https://api.example.com/v1/path/to/endpoint`
- **Path parameters**: `id` (String)
- **Query parameters**: `page` (int), `limit` (int)
- **Headers**:
  - `Authorization: Bearer <token>`
  - `Content-Type: application/json`
- **Request body**: `LoginRequest { email: String, password: String }`
- **Response type**: `ApiResponse<User>`
- **Async pattern**: suspend / Single / Observable / Flow
- **Notes**: Called from `LoginActivity.onLoginClicked()`
```

## Search Strategy

1. Start with **base URL constants** — find where the API root is configured
2. Search for **Retrofit interfaces** — they give the clearest picture of all endpoints
3. Check **interceptors** — they reveal auth schemes and common headers
4. Search for **hardcoded URLs** — catch any one-off API calls outside the main client
5. Look for **WebView URLs** — some apps use hybrid web/native approaches
6. Search for **GraphQL operations** — catch apps using Apollo or similar
7. Check **WebSocket connections** — find real-time communication endpoints
8. Run **security patterns** — identify cert pinning, disabled security, and exposed secrets
