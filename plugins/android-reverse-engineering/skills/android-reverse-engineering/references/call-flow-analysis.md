# Call Flow Analysis

Techniques for tracing execution flows in decompiled Android applications, from entry points down to network calls.

## 1. Start from AndroidManifest.xml

The manifest declares all entry points. After decompilation, find it at:

```
<output-dir>/resources/AndroidManifest.xml
```

Key elements to look for:

```bash
# Activities (UI screens)
grep -n 'android:name=.*Activity' resources/AndroidManifest.xml

# Services (background work)
grep -n 'android:name=.*Service' resources/AndroidManifest.xml

# BroadcastReceivers
grep -n '<receiver' resources/AndroidManifest.xml

# ContentProviders
grep -n '<provider' resources/AndroidManifest.xml

# Launcher activity (main entry point)
grep -A5 'MAIN' resources/AndroidManifest.xml | grep 'android:name'
```

## 2. Follow the Android Lifecycle

Typical call chain from UI to network:

```
Activity.onCreate()
  -> setContentView(R.layout.activity_main)
  -> findViewById() / View Binding
  -> button.setOnClickListener()
    -> onClick()
      -> viewModel.doSomething()
        -> repository.fetchData()
          -> apiService.getEndpoint()
            -> HTTP request
```

Key lifecycle methods to search:

```bash
grep -rn 'onCreate\|onResume\|onStart\|onViewCreated' sources/
```

## 3. Identify Click Handlers

User interactions trigger API calls. Common patterns:

```bash
# XML onClick
grep -rn 'setOnClickListener\|onClick\|OnClickListener' sources/

# Data Binding
grep -rn '@BindingAdapter\|android:onClick' sources/ resources/

# Navigation actions
grep -rn 'findNavController\|NavController\|navigate(' sources/
```

## 4. Application Class Initialization

The `Application` subclass initializes global singletons (HTTP clients, DI frameworks, analytics):

```bash
# Find Application subclass
grep -rn 'extends Application\|: Application()' sources/

# Check onCreate for initialization
# Then read the class to see what gets configured at startup
```

Look for:
- Retrofit/OkHttp client setup
- Dagger/Hilt/Koin component initialization
- Firebase/analytics initialization
- Base URL configuration

## 5. Dependency Injection

Modern Android apps use DI frameworks. Trace bindings to find implementations.

### Dagger / Hilt

```bash
# Hilt modules
grep -rn '@Module\|@InstallIn\|@Provides\|@Binds' sources/

# Hilt entry points
grep -rn '@HiltAndroidApp\|@AndroidEntryPoint\|@HiltViewModel' sources/

# Dagger components
grep -rn '@Component\|@Subcomponent' sources/

# Injected fields
grep -rn '@Inject' sources/
```

To trace a call flow through Dagger/Hilt:
1. Find where an interface is used (e.g., `ApiService` injected into a repository)
2. Find the `@Provides` or `@Binds` method that creates the implementation
3. Follow the implementation to the actual HTTP call

### Koin

```bash
# Koin module definitions
grep -rn 'module\s*{\|single\s*{\|factory\s*{\|viewModel\s*{' sources/

# Koin injection in Activities/Fragments
grep -rn 'by inject()\|by viewModel()\|get()\|koinApplication' sources/

# Koin start
grep -rn 'startKoin\|KoinApplication\|androidContext' sources/
```

To trace a call flow through Koin:
1. Find `startKoin` in the Application class to locate module declarations
2. In the module, find `single { }` or `factory { }` blocks that provide network-related classes
3. Follow `by inject()` usage in Activities/ViewModels to see where those classes are consumed

### Manual DI / Service Locator

Some apps use manual DI patterns without a framework:

```bash
# Singleton patterns
grep -rn 'companion object\|getInstance()\|INSTANCE' sources/

# ServiceLocator pattern
grep -rn 'ServiceLocator\|Locator\|Container' sources/
```

## 6. Kotlin Coroutines Flow

Modern Android apps use coroutines for async network calls. Understanding the flow is essential.

### ViewModel → Repository → API

```kotlin
// ViewModel
class LoginViewModel @Inject constructor(
    private val repository: UserRepository
) : ViewModel() {
    private val _state = MutableStateFlow<LoginState>(LoginState.Idle)
    val state: StateFlow<LoginState> = _state

    fun login(email: String, password: String) {
        viewModelScope.launch {
            _state.value = LoginState.Loading
            repository.login(email, password)
                .collect { result ->
                    _state.value = LoginState.Success(result)
                }
        }
    }
}

// Repository
class UserRepository(private val api: ApiService) {
    fun login(email: String, password: String): Flow<LoginResponse> = flow {
        emit(api.login(LoginRequest(email, password)))
    }
}
```

### Key search patterns for coroutine flows

```bash
# ViewModel scope launches (entry point for async work)
grep -rn 'viewModelScope\.launch\|lifecycleScope\.launch' sources/

# Flow collection in UI
grep -rn '\.collect\s*{\|\.collectLatest\|repeatOnLifecycle' sources/

# StateFlow observation
grep -rn '\.stateIn\|\.shareIn\|MutableStateFlow\|StateFlow' sources/
```

## 7. RxJava Call Chains

For apps using RxJava, follow the reactive chain:

```bash
# Find where observables are subscribed (the consumption point)
grep -rn '\.subscribe\s*(\|\.subscribeWith' sources/

# Find where observables are created (the source)
grep -rn '\.create(\|\.just(\|\.fromCallable' sources/

# Schedulers indicate thread switches (IO = network/disk)
grep -rn 'Schedulers\.io\|subscribeOn\|observeOn' sources/

# Composite disposables (lifecycle management)
grep -rn 'CompositeDisposable\|\.add(\|\.dispose()' sources/
```

### Typical RxJava call chain

```
Activity.onClick()
  -> viewModel.login()
    -> repository.login()
      -> apiService.login()         // Returns Single<LoginResponse>
        .subscribeOn(Schedulers.io())
        .observeOn(AndroidSchedulers.mainThread())
        .subscribe(onSuccess, onError)
```

## 8. Find Constants and Configuration

Hardcoded values are rarely obfuscated:

```bash
# Base URLs
grep -rni 'BASE_URL\|API_URL\|SERVER_URL\|HOST' sources/

# API keys
grep -rni 'API_KEY\|CLIENT_ID\|APP_KEY\|SECRET' sources/

# BuildConfig values
grep -rn 'BuildConfig\.' sources/

# SharedPreferences keys (runtime config)
grep -rn 'getSharedPreferences\|getString(\|putString(' sources/

# Gradle-injected build fields
grep -rn 'BuildConfig\.API\|BuildConfig\.BASE\|BuildConfig\.SERVER' sources/
```

## 9. Navigating Obfuscated Code

When code is obfuscated (ProGuard/R8):

### What gets obfuscated
- Class names -> `a`, `b`, `c`
- Method names -> `a()`, `b()`, `c()`
- Field names -> `f1234a`, `f1235b`

### What does NOT get obfuscated
- **String literals** — URLs, keys, error messages remain readable
- **Android framework classes** — `Activity`, `Fragment`, `Intent` keep their names
- **Library public APIs** — Retrofit annotations, OkHttp builders retain names
- **AndroidManifest entries** — Activity/Service names must be real
- **Enum values** — often preserved for serialization
- **Annotation parameters** — `@GET("path")` keeps the path string

### Strategy for obfuscated code

1. **Start from strings**: Search for URLs, error messages, and known constants
2. **Start from framework classes**: Activities and Fragments are named in the manifest
3. **Follow library calls**: Retrofit `@GET`/`@POST` annotations are readable even when the interface class name is obfuscated
4. **Use `--deobf`**: jadx can generate readable replacement names
5. **Cross-reference**: If `class a` calls `Retrofit.create(b.class)`, then `b` is a Retrofit service interface

## 10. Tracing a Complete Call Flow: Example

Goal: Find how login works in an obfuscated app.

```
1. grep for "login" in strings -> find "auth/login" URL in class `c.a.b.d`
2. Class `c.a.b.d` has @POST("auth/login") -> it's a Retrofit interface
3. grep for `c.a.b.d` usage -> class `c.a.b.f` calls it (the repository)
4. grep for `c.a.b.f` usage -> class `c.a.a.g` calls it (the ViewModel)
5. grep for `c.a.a.g` usage -> `LoginActivity` has a field of this type
6. Read LoginActivity.onCreate() -> sets click listener -> calls ViewModel method
```

Result: `LoginActivity -> ViewModel -> Repository -> Retrofit @POST("auth/login")`

## 11. Tools and Commands Summary

| Goal | Command |
|---|---|
| Find entry points | `grep 'android:name' resources/AndroidManifest.xml` |
| Find lifecycle methods | `grep -rn 'onCreate\|onResume' sources/` |
| Find click handlers | `grep -rn 'setOnClickListener\|onClick' sources/` |
| Find Hilt/Dagger DI bindings | `grep -rn '@Provides\|@Binds\|@Inject' sources/` |
| Find Koin DI bindings | `grep -rn 'single\s*{\|factory\s*{\|by inject' sources/` |
| Find coroutine launches | `grep -rn 'viewModelScope\.launch\|lifecycleScope' sources/` |
| Find Flow collection | `grep -rn '\.collect\s*{\|\.collectLatest' sources/` |
| Find RxJava subscriptions | `grep -rn '\.subscribe\s*(\|\.subscribeOn' sources/` |
| Find constants | `grep -rni 'BASE_URL\|API_KEY' sources/` |
| Find usages of a class | `grep -rn 'ClassName' sources/` |
| Follow a string | `grep -rn '"some text"' sources/` |
