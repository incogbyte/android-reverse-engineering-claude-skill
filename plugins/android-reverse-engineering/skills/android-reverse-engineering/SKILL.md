---
description: Decompile Android APK, XAPK, AAB, DEX, JAR, and AAR files using jadx or Fernflower/Vineflower. Reverse engineer Android apps, extract HTTP API endpoints (Retrofit, OkHttp, Volley, GraphQL, WebSocket), trace call flows from UI to network layer, and analyze security patterns (cert pinning, exposed secrets). Use when the user wants to decompile, analyze, or reverse engineer Android packages, find API endpoints, follow call flows, or audit app security.
---

# Android Reverse Engineering

Decompile Android APK, XAPK, AAB, DEX, JAR, and AAR files using jadx and Fernflower/Vineflower, trace call flows through application code and libraries, analyze security patterns, and produce structured documentation of extracted APIs. Two decompiler engines are supported — jadx for broad Android coverage and Fernflower for higher-quality output on complex Java code — and can be used together for comparison.

## Prerequisites

This skill requires **Java JDK 17+** and **jadx** to be installed. **Fernflower/Vineflower** and **dex2jar** are optional but recommended for better decompilation quality. **bundletool** is required for AAB (App Bundle) files. Run the dependency checker to verify:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/check-deps.sh
```

If anything is missing, follow the installation instructions in `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/setup-guide.md`.

## Workflow

### Phase 1: Verify and Install Dependencies

Before decompiling, confirm that the required tools are available — and install any that are missing.

**Action**: Run the dependency check script.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/check-deps.sh
```

The output contains machine-readable lines:
- `INSTALL_REQUIRED:<dep>` — must be installed before proceeding
- `INSTALL_OPTIONAL:<dep>` — recommended but not blocking

**If required dependencies are missing** (exit code 1), install them automatically:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/install-dep.sh <dep>
```

The install script detects the OS and package manager, then:
- Installs without sudo when possible (downloads to `~/.local/share/`, symlinks in `~/.local/bin/`)
- Uses sudo and the system package manager when necessary (apt, dnf, pacman)
- If sudo is needed but unavailable or the user declines, it prints the exact manual command and exits with code 2 — show these instructions to the user

**For optional dependencies**, ask the user if they want to install them. Vineflower and dex2jar are recommended for best results.

After installation, re-run `check-deps.sh` to confirm everything is in place. Do not proceed to Phase 2 until all required dependencies are OK.

### Phase 2: Decompile

Use the decompile wrapper script to process the target file. The script supports three engines: `jadx`, `fernflower`, and `both`.

**Action**: Choose the engine and run the decompile script. The script handles APK, XAPK, AAB, DEX, JAR, and AAR files.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/decompile.sh [OPTIONS] <file>
```

For **XAPK** files (ZIP bundles containing multiple APKs, used by APKPure and similar stores): the script automatically extracts the archive, identifies all APK files inside (base + split APKs), and decompiles each one into a separate subdirectory. The XAPK manifest is copied to the output for reference.

For **AAB** files (Android App Bundles): the script uses bundletool to generate a universal APK from the bundle, then decompiles it. bundletool must be installed (run `install-dep.sh bundletool`).

For **DEX** files: jadx handles them natively. For Fernflower, dex2jar is used as an intermediate step (same as APK files).

Options:
- `-o <dir>` — Custom output directory (default: `<filename>-decompiled`)
- `--deobf` — Enable deobfuscation (recommended for obfuscated apps)
- `--no-res` — Skip resources, decompile code only (faster)
- `--engine ENGINE` — `jadx` (default), `fernflower`, or `both`

**Engine selection strategy**:

| Situation | Engine |
|---|---|
| First pass on any APK/AAB | `jadx` (fastest, handles resources) |
| JAR/AAR library analysis | `fernflower` (better Java output) |
| jadx output has warnings/broken code | `both` (compare and pick best per class) |
| Complex lambdas, generics, streams | `fernflower` |
| Quick overview of a large APK | `jadx --no-res` |
| DEX file analysis | `jadx` (native support) or `fernflower` (via dex2jar) |

When using `--engine both`, the outputs go into `<output>/jadx/` and `<output>/fernflower/` respectively, with a comparison summary at the end showing file counts and jadx warning counts. Review classes with jadx warnings in the Fernflower output for better code.

For APK files with Fernflower, the script automatically uses dex2jar as an intermediate step. dex2jar must be installed for this to work.

See `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/jadx-usage.md` and `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/fernflower-usage.md` for the full CLI references.

### Phase 3: Analyze Structure

Navigate the decompiled output to understand the app's architecture.

**Actions**:

1. **Read AndroidManifest.xml** from `<output>/resources/AndroidManifest.xml`:
   - Identify the main launcher Activity
   - List all Activities, Services, BroadcastReceivers, ContentProviders
   - Note permissions (especially `INTERNET`, `ACCESS_NETWORK_STATE`)
   - Find the application class (`android:name` on `<application>`)

2. **Survey the package structure** under `<output>/sources/`:
   - Identify the main app package and sub-packages
   - Distinguish app code from third-party libraries
   - Look for packages named `api`, `network`, `data`, `repository`, `service`, `retrofit`, `http` — these are where API calls live

3. **Identify the architecture pattern**:
   - MVP: look for `Presenter` classes
   - MVVM: look for `ViewModel` classes and `LiveData`/`StateFlow`
   - Clean Architecture: look for `domain`, `data`, `presentation` packages
   - This informs where to look for network calls in the next phases

### Phase 4: Trace Call Flows

Follow execution paths from user-facing entry points down to network calls.

**Actions**:

1. **Start from entry points**: Read the main Activity or Application class identified in Phase 3.

2. **Follow the initialization chain**: Application.onCreate() often sets up the HTTP client, base URL, and DI framework. Read this first.

3. **Trace user actions**: From an Activity, follow:
   - `onCreate()` → view setup → click listeners
   - Click handler → ViewModel/Presenter method
   - ViewModel → Repository → API service interface
   - API service → actual HTTP call

4. **Map DI bindings** (if Dagger/Hilt is used): Find `@Module` classes to understand which implementations are provided for which interfaces.

5. **Handle obfuscated code**: When class names are mangled, use string literals and library API calls as anchors. Retrofit annotations and URL strings are never obfuscated.

See `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/call-flow-analysis.md` for detailed techniques and grep commands.

### Phase 5: Extract and Document APIs

Find all API endpoints and produce structured documentation.

**Action**: Run the API search script for a broad sweep.

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-api-calls.sh <output>/sources/
```

Additional options:
- `--context N` — Show N lines of context around each match (recommended: `--context 3`)
- `--report FILE` — Export results as a structured Markdown report
- `--dedup` — Deduplicate results by endpoint/URL

Targeted searches:
```bash
# Only Retrofit
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-api-calls.sh <output>/sources/ --retrofit

# Only hardcoded URLs
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-api-calls.sh <output>/sources/ --urls

# Only auth patterns
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-api-calls.sh <output>/sources/ --auth

# Only Kotlin coroutines/Flow patterns
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-api-calls.sh <output>/sources/ --kotlin

# Only RxJava patterns
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-api-calls.sh <output>/sources/ --rxjava

# Only GraphQL patterns
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-api-calls.sh <output>/sources/ --graphql

# Only WebSocket patterns
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-api-calls.sh <output>/sources/ --websocket

# Only security patterns (cert pinning, exposed secrets, debug flags)
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-api-calls.sh <output>/sources/ --security

# Full analysis with context and Markdown report
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-api-calls.sh <output>/sources/ --context 3 --dedup --report report.md
```

Then, for each discovered endpoint, read the surrounding source code to extract:
- HTTP method and path
- Base URL
- Path parameters, query parameters, request body
- Headers (especially authentication)
- Response type
- Where it's called from (the call chain from Phase 4)

**Document each endpoint** using this format:

```markdown
### `METHOD /path`

- **Source**: `com.example.api.ApiService` (ApiService.java:42)
- **Base URL**: `https://api.example.com/v1`
- **Path params**: `id` (String)
- **Query params**: `page` (int), `limit` (int)
- **Headers**: `Authorization: Bearer <token>`
- **Request body**: `{ "email": "string", "password": "string" }`
- **Response**: `ApiResponse<User>`
- **Called from**: `LoginActivity → LoginViewModel → UserRepository → ApiService`
```

See `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/api-extraction-patterns.md` for library-specific search patterns and the full documentation template.

### Phase 6: Security Analysis

Scan for security-relevant patterns in the decompiled code.

**Action**: Run the security-focused search:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-api-calls.sh <output>/sources/ --security --context 3
```

Look for and flag:
- **Disabled certificate pinning** — custom `TrustManager` that trusts all certs, `ALLOW_ALL_HOSTNAME_VERIFIER`
- **Exposed secrets** — hardcoded passwords, API keys, encryption keys in source code
- **Debug flags left on** — `BuildConfig.DEBUG` checks, staging URLs, verbose logging
- **Weak crypto** — MD5 hashing, ECB mode encryption, hardcoded IVs/salts
- **Network Security Config** — check `res/xml/network_security_config.xml` for `cleartextTrafficPermitted="true"` or overly broad trust anchors

See `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/api-extraction-patterns.md` for the full list of security patterns.

## Output

At the end of the workflow, deliver:

1. **Decompiled source** in the output directory
2. **Architecture summary** — app structure, main packages, pattern used
3. **API documentation** — all discovered endpoints in the format above
4. **Call flow map** — key paths from UI to network (especially authentication and main features)
5. **Security findings** — certificate pinning status, exposed secrets, debug flags, crypto issues

Use `--report report.md` on find-api-calls.sh to generate a structured Markdown report automatically.

## References

- `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/setup-guide.md` — Installing Java, jadx, Fernflower/Vineflower, dex2jar, and optional tools
- `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/jadx-usage.md` — jadx CLI options and workflows
- `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/fernflower-usage.md` — Fernflower/Vineflower CLI options, when to use, APK workflow
- `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/api-extraction-patterns.md` — Library-specific search patterns and documentation template
- `${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/references/call-flow-analysis.md` — Techniques for tracing call flows in decompiled code
