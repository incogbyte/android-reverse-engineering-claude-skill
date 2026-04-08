# Android Reverse Engineering - Claude Code Skill

**Author:** [incogbyte](https://github.com/incogbyte)

Claude Code skill that automates Android application reverse engineering. Decompiles APK, XAPK, AAB, DEX, JAR, and AAR files, extracts HTTP endpoints (Retrofit, OkHttp, Volley, GraphQL, WebSocket), traces call flows, analyzes security patterns, documents discovered APIs, and performs adaptive dynamic analysis with Frida — generating custom bypass scripts based on static analysis findings and iterating through crash logs to defeat runtime protections (RASP, root detection, SSL pinning, anti-tamper).

## What this skill does

- **Decompiles** APK, XAPK, AAB, DEX, JAR, and AAR using jadx or Fernflower/Vineflower (individually or side by side for comparison)
- **Extracts HTTP APIs**: Retrofit endpoints, OkHttp calls, Volley, GraphQL queries/mutations, WebSocket connections, hardcoded URLs, authentication headers
- **Traces call flows** from Activities/Fragments to network calls, through ViewModels, Repositories, coroutines/Flow, and RxJava chains
- **Analyzes app structure**: AndroidManifest, packages, architectural pattern (MVP, MVVM, Clean Architecture)
- **Audits security**: certificate pinning, disabled SSL verification, exposed secrets, debug flags, weak crypto
- **Dynamic analysis with Frida**: adaptive bypass loop that generates custom scripts based on decompiled code, runs them, captures crash logs, and iterates until protections are bypassed
- **Bypasses runtime protections**: RASP, root detection (RootBeer, SafetyNet), SSL pinning, anti-tamper, Frida detection — all via targeted hooks generated from static analysis, not generic scripts
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

### For dynamic analysis (Phase 7)

| Tool | Purpose |
|---|---|
| **Python 3.8+** | Runtime for frida-tools (installed in a venv, never globally) |
| **adb** | Communication with device/emulator |
| **frida-server** | Runs on the Android device/emulator (the skill detects if you already have it) |
| **frida-tools** | Client-side Frida CLI — auto-installed in a venv matching your server version |

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

### Frida setup

The Frida setup is handled by a dedicated script that **detects your existing environment first** before changing anything:

```bash
# Detect everything: device, frida-server version, create matching venv
bash scripts/setup-frida.sh

# If frida-server is not on the device, auto-download and push it:
bash scripts/setup-frida.sh --install-server
```

What `setup-frida.sh` does:

1. **Checks adb** — verifies a device/emulator is connected, gets architecture (arm64, x86, etc.)
2. **Finds existing frida-server** — checks `/data/local/tmp/frida-server` and running processes on the device
3. **Gets frida-server version** — extracts version from the binary on device
4. **Checks Python 3 + venv module** — required for frida-tools
5. **Creates a venv** at `~/.local/share/frida-re/venv` — **frida-tools is never installed globally**
6. **Installs frida-tools matching your server version** — avoids version mismatch errors
7. **Tests connectivity** — runs `frida-ps -U` to verify everything works

If you already have frida-server on your device (most users do), the script just creates the venv and matches the client version. No unnecessary reinstalls.

#### Manual Frida installation

```bash
# 1. Create venv (always use a venv, never install globally)
python3 -m venv ~/.local/share/frida-re/venv

# 2. Check your frida-server version on device
adb shell /data/local/tmp/frida-server --version

# 3. Install matching frida-tools
~/.local/share/frida-re/venv/bin/pip install frida-tools==<server-version>

# 4. Verify
~/.local/share/frida-re/venv/bin/frida-ps -U
```

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
- "Bypass the root detection in this app"
- "Hook the login method and capture credentials"
- "The app crashes on my rooted device, find out why and bypass it"
- "Trace all API calls this app makes at runtime"

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

# --- Dynamic Analysis (Frida) ---

# Setup Frida environment (detect device, create venv, match versions)
bash scripts/setup-frida.sh

# Setup + auto-install frida-server on device if missing
bash scripts/setup-frida.sh --install-server

# Launch app and capture crash diagnostics (before any hooks)
bash scripts/adb-crash-capture.sh -p com.example.app

# Launch with longer monitoring window and save logs
bash scripts/adb-crash-capture.sh -p com.example.app -t 20 -o ./crash-logs/

# Run a Frida script against an app (spawn mode)
bash scripts/frida-run.sh -p com.example.app -l bypass.js

# Run with early hook (pause on spawn, hook before app code runs)
bash scripts/frida-run.sh -p com.example.app -l bypass.js --pause

# Run inline JavaScript
bash scripts/frida-run.sh -p com.example.app -e "Java.perform(function() { console.log('hooked'); })"

# Attach to already running app
bash scripts/frida-run.sh -p com.example.app -l analysis.js --attach

# Run with timeout and save output
bash scripts/frida-run.sh -p com.example.app -l bypass.js -t 60 --output-dir ./frida-output/
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

### setup-frida.sh options

| Option | Description |
|---|---|
| `-s, --serial SERIAL` | Target specific device by serial |
| `--install-server` | Download and push frida-server to device if missing |
| `--venv-dir DIR` | Custom venv directory (default: `~/.local/share/frida-re`) |

### frida-run.sh options

| Option | Description |
|---|---|
| `-p, --package PKG` | Target package name (required) |
| `-l, --load FILE` | JavaScript file to load (required, or use `-e`) |
| `-e, --eval CODE` | Inline JavaScript to execute |
| `-t, --timeout SECS` | Max seconds to run (default: 30, 0=unlimited) |
| `--attach` | Attach to running process instead of spawning |
| `--pause` | Pause app on spawn (hooks run before any app code) |
| `-s, --serial SERIAL` | Target specific device |
| `--output-dir DIR` | Save stdout/stderr/crash logs to directory |

### adb-crash-capture.sh options

| Option | Description |
|---|---|
| `-p, --package PKG` | Target package name (required) |
| `-a, --activity ACT` | Specific activity to launch (default: auto-detect) |
| `-t, --time SECS` | Monitor window in seconds (default: 10) |
| `-s, --serial SERIAL` | Target specific device |
| `-o, --output-dir DIR` | Save logs to directory |
| `-v, --verbose` | Include full logcat output |

### When to use each engine

| Scenario | Recommended engine |
|---|---|
| First pass on any APK/AAB | `jadx` (faster, decodes resources) |
| JAR/AAR library analysis | `fernflower` (better Java output) |
| jadx has warnings or broken code | `both` (compare and pick the best per class) |
| Complex lambdas, generics, streams | `fernflower` |
| Quick overview of a large APK | `jadx --no-res` |
| DEX file analysis | `jadx` (native support) or `fernflower` (via dex2jar) |

## How dynamic analysis works (adaptive bypass loop)

Unlike tools that ship generic bypass scripts, this skill uses Claude as the intelligence layer. The approach:

1. **Static analysis first** (Phases 1–6): decompile the app, understand its structure, find protection mechanisms in the code
2. **Baseline crash check**: launch the app and capture crash logs — does it even run on a rooted device/emulator?
3. **Identify the protection**: cross-reference the crash stack trace with the decompiled code to find the exact method that triggered the crash
4. **Generate a targeted Frida script**: hook that specific method based on what the code actually does (not a generic bypass)
5. **Run and capture**: execute the script, monitor for new crashes
6. **Iterate**: if a new crash occurs, it means a different protection check triggered — analyze, generate another hook, repeat
7. **Analyze**: once the app runs cleanly, use Frida to intercept traffic, monitor crypto, trace methods

```
Static Analysis → Find protections in code
       ↓
Launch app → Crash? → Read crash logs
       ↓                    ↓
  No crash              Cross-reference with
  (skip to analysis)    decompiled source
       ↓                    ↓
  Runtime analysis      Generate targeted hook
  (traffic, crypto,         ↓
   method tracing)      Run with Frida → New crash?
                            ↓              ↓
                         Success        Repeat (next check)
```

This approach handles RASP, root detection, SSL pinning, anti-tamper, and Frida detection — because it doesn't rely on known signatures. It reads the actual code and adapts.

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
│       │           ├── find-api-calls.sh
│       │           ├── setup-frida.sh
│       │           ├── frida-run.sh
│       │           └── adb-crash-capture.sh
│       └── commands/
│           └── decompile.md
├── LICENSE
└── README.md
```
