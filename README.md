# Android Reverse Engineering — Claude Code Skill

**Author:** [incogbyte](https://github.com/incogbyte)

Claude Code skill that automates Android application reverse engineering. Decompiles APK, XAPK, AAB, DEX, JAR, and AAR files, extracts HTTP endpoints (Retrofit, OkHttp, Volley, GraphQL, WebSocket), traces call flows, analyzes security patterns, and documents discovered APIs.

## What this skill does

- **Decompiles** APK, XAPK, AAB, DEX, JAR, and AAR using jadx or Fernflower/Vineflower (individually or side by side for comparison)
- **Extracts HTTP APIs**: Retrofit endpoints, OkHttp calls, Volley, GraphQL queries/mutations, WebSocket connections, hardcoded URLs, authentication headers
- **Traces call flows** from Activities/Fragments to network calls, through ViewModels, Repositories, coroutines/Flow, and RxJava chains
- **Analyzes app structure**: AndroidManifest, packages, architectural pattern (MVP, MVVM, Clean Architecture)
- **Audits security**: certificate pinning, disabled SSL verification, exposed secrets, debug flags, weak crypto
- **Handles obfuscated code**: strategies for navigating ProGuard/R8 output, using strings and annotations as anchors
- **Generates reports**: structured Markdown reports with all findings

## Required tools

### Mandatory

| Tool | Minimum version | Purpose |
|---|---|---|
| **Java JDK** | 17+ | Runtime for jadx and Fernflower |
| **jadx** | any | Primary decompiler (APK/DEX/JAR/AAR to Java) |

### Optional (recommended)

| Tool | Purpose |
|---|---|
| **Vineflower** (Fernflower fork) | Higher quality decompilation for lambdas, generics, and complex Java code |
| **dex2jar** | Convert DEX to JAR (required to use Fernflower with APKs/DEX files) |
| **bundletool** | Convert AAB (App Bundle) to APK for decompilation |
| **apktool** | Resource decoding (XML, drawables) when jadx fails |
| **adb** | Extract APKs directly from a connected Android device |

### How to install the tools

The skill includes a script that automatically detects the OS and package manager:

```bash
# Check what is installed and what is missing
bash scripts/check-deps.sh

# Install dependencies individually (detects brew/apt/dnf/pacman)
bash scripts/install-dep.sh java
bash scripts/install-dep.sh jadx
bash scripts/install-dep.sh vineflower
bash scripts/install-dep.sh dex2jar
bash scripts/install-dep.sh bundletool
```

The script installs without sudo when possible (local download to `~/.local/`). When sudo is needed, it asks for confirmation. If it cannot install, it prints manual instructions.

#### Manual installation

**Java JDK 17+:**

```bash
# macOS
brew install openjdk@17

# Ubuntu/Debian
sudo apt install openjdk-17-jdk

# Fedora
sudo dnf install java-17-openjdk-devel

# Arch
sudo pacman -S jdk17-openjdk
```

**jadx:**

```bash
# macOS/Linux (Homebrew)
brew install jadx

# Or download directly from GitHub:
# https://github.com/skylot/jadx/releases/latest
# Extract and add bin/ to PATH
```

**Vineflower (Fernflower fork):**

```bash
# macOS (Homebrew)
brew install vineflower

# Or download the JAR:
# https://github.com/Vineflower/vineflower/releases/latest
# Save the JAR and set:
export FERNFLOWER_JAR_PATH="$HOME/vineflower/vineflower.jar"
```

**dex2jar:**

```bash
# macOS (Homebrew)
brew install dex2jar

# Or download:
# https://github.com/pxb1988/dex2jar/releases/latest
# Extract and add to PATH
```

**bundletool:**

```bash
# macOS (Homebrew)
brew install bundletool

# Or download the JAR:
# https://github.com/google/bundletool/releases/latest
# Save and set:
export BUNDLETOOL_JAR_PATH="$HOME/bundletool/bundletool.jar"
```

## Skill installation

### Via GitHub (recommended)

In Claude Code, add the marketplace and install:

```
/plugin marketplace add incogbyte/android-reverse-engineering-skill
/plugin install android-reverse-engineering@android-reverse-engineering-skill
```

### Via local clone

```bash
git clone https://github.com/incogbyte/android-reverse-engineering-skill.git
```

In Claude Code, add the local marketplace and install:

```
/plugin marketplace add /path/to/android-reverse-engineering-skill
/plugin install android-reverse-engineering@android-reverse-engineering-skill
```

### Quick test (no installation)

Load the plugin directly for the current session:

```bash
claude --plugin-dir /path/to/android-reverse-engineering-skill/plugins/android-reverse-engineering
```

## Usage

### /decompile command

```
/decompile path/to/app.apk
```

Runs the full flow: checks dependencies, decompiles, and analyzes the app structure.

### Natural language

The skill activates automatically with phrases like:

- "Decompile this APK"
- "Reverse engineer this Android app"
- "Extract the API endpoints from this app"
- "Follow the call flow from LoginActivity"
- "Analyze this AAR library"
- "Find the hardcoded URLs in this APK"
- "Decompile this AAB file"
- "Audit the security of this app"
- "Find GraphQL endpoints in this APK"
- "Check for certificate pinning"

### Standalone scripts

The scripts can be used directly outside of Claude Code:

```bash
# Decompile with jadx (default)
bash scripts/decompile.sh app.apk

# Decompile XAPK (extracts and decompiles each internal APK)
bash scripts/decompile.sh app-bundle.xapk

# Decompile AAB (uses bundletool to extract universal APK)
bash scripts/decompile.sh app-bundle.aab

# Decompile DEX file directly
bash scripts/decompile.sh classes.dex

# Decompile with Fernflower (better for JARs)
bash scripts/decompile.sh --engine fernflower library.jar

# Decompile with both engines and compare
bash scripts/decompile.sh --engine both --deobf app.apk

# Decompile code only (no resources, faster)
bash scripts/decompile.sh --no-res app.apk

# Search for API calls in decompiled code (all patterns)
bash scripts/find-api-calls.sh output/sources/

# Search with context lines for better readability
bash scripts/find-api-calls.sh output/sources/ --context 3

# Search for Retrofit endpoints only
bash scripts/find-api-calls.sh output/sources/ --retrofit

# Search for hardcoded URLs only
bash scripts/find-api-calls.sh output/sources/ --urls

# Search for authentication patterns
bash scripts/find-api-calls.sh output/sources/ --auth

# Search for Kotlin coroutines/Flow patterns
bash scripts/find-api-calls.sh output/sources/ --kotlin

# Search for RxJava patterns
bash scripts/find-api-calls.sh output/sources/ --rxjava

# Search for GraphQL queries/mutations
bash scripts/find-api-calls.sh output/sources/ --graphql

# Search for WebSocket connections
bash scripts/find-api-calls.sh output/sources/ --websocket

# Security audit (cert pinning, exposed secrets, debug flags, crypto)
bash scripts/find-api-calls.sh output/sources/ --security

# Full analysis with Markdown report, context, and deduplication
bash scripts/find-api-calls.sh output/sources/ --context 3 --dedup --report report.md
```

### decompile.sh options

| Option | Description |
|---|---|
| `-o <dir>` | Output directory (default: `<name>-decompiled`) |
| `--deobf` | Enable deobfuscation (renames obfuscated classes/methods) |
| `--no-res` | Skip resource decoding (faster) |
| `--engine ENGINE` | `jadx` (default), `fernflower`, or `both` |

### find-api-calls.sh options

| Option | Description |
|---|---|
| `--retrofit` | Search only for Retrofit annotations |
| `--okhttp` | Search only for OkHttp patterns |
| `--volley` | Search only for Volley patterns |
| `--urls` | Search only for hardcoded URLs |
| `--auth` | Search only for auth-related patterns |
| `--kotlin` | Search only for Kotlin coroutines/Flow patterns |
| `--rxjava` | Search only for RxJava patterns |
| `--graphql` | Search only for GraphQL patterns |
| `--websocket` | Search only for WebSocket patterns |
| `--security` | Search only for security patterns (cert pinning, secrets, debug flags, crypto) |
| `--all` | Search all patterns (default) |
| `--context N` | Show N lines of context around matches |
| `--dedup` | Deduplicate results by endpoint/URL |
| `--report FILE` | Export results as structured Markdown report |

### When to use each engine

| Scenario | Recommended engine |
|---|---|
| First pass on any APK/AAB | `jadx` (faster, decodes resources) |
| JAR/AAR library analysis | `fernflower` (better Java output) |
| jadx has warnings or broken code | `both` (compare and pick the best per class) |
| Complex lambdas, generics, streams | `fernflower` |
| Quick overview of a large APK | `jadx --no-res` |
| DEX file analysis | `jadx` (native support) or `fernflower` (via dex2jar) |

## Repository structure

```
android-reverse-engineering-skill/
├── .claude-plugin/
│   └── marketplace.json
├── plugins/
│   └── android-reverse-engineering/
│       ├── .claude-plugin/
│       │   └── plugin.json
│       ├── skills/
│       │   └── android-reverse-engineering/
│       │       ├── SKILL.md
│       │       ├── references/
│       │       │   ├── setup-guide.md
│       │       │   ├── jadx-usage.md
│       │       │   ├── fernflower-usage.md
│       │       │   ├── api-extraction-patterns.md
│       │       │   └── call-flow-analysis.md
│       │       └── scripts/
│       │           ├── check-deps.sh
│       │           ├── install-dep.sh
│       │           ├── decompile.sh
│       │           └── find-api-calls.sh
│       └── commands/
│           └── decompile.md
├── LICENSE
└── README.md
```

## Disclaimer

This skill is provided exclusively for **legitimate use**, including:

- Authorized security research and pentesting
- Interoperability analysis permitted by law
- Malware analysis and incident response
- Educational use and CTF competitions

**You are solely responsible** for ensuring that your use of this tool complies with applicable laws and terms of service.

## License

Apache 2.0 — see [LICENSE](LICENSE)
