# Setup Guide: Dependencies for Android Reverse Engineering

## Java JDK 17+

jadx requires Java 17 or later.

### Ubuntu / Debian

```bash
sudo apt update
sudo apt install openjdk-17-jdk
```

### Fedora

```bash
sudo dnf install java-17-openjdk-devel
```

### Arch Linux

```bash
sudo pacman -S jdk17-openjdk
```

### macOS (Homebrew)

```bash
brew install openjdk@17
```

After installation on macOS, follow the symlink instructions printed by Homebrew, or add to your shell profile:

```bash
export PATH="/opt/homebrew/opt/openjdk@17/bin:$PATH"
```

### Verify

```bash
java -version
# Should show version 17.x or higher
```

---

## jadx

jadx is the Java decompiler used to convert APK/JAR/AAR files to readable Java source.

### Option 1: GitHub Releases (recommended)

1. Go to <https://github.com/skylot/jadx/releases/latest>
2. Download the `jadx-<version>.zip` file (not the source archive)
3. Extract and add to PATH:

```bash
unzip jadx-*.zip -d ~/jadx
export PATH="$HOME/jadx/bin:$PATH"
# Add the export line to your ~/.bashrc or ~/.zshrc for persistence
```

### Option 2: Homebrew (macOS / Linux)

```bash
brew install jadx
```

### Option 3: Build from source

```bash
git clone https://github.com/skylot/jadx.git
cd jadx
./gradlew dist
# Binaries will be in build/jadx/bin/
export PATH="$(pwd)/build/jadx/bin:$PATH"
```

### Verify

```bash
jadx --version
```

---

## Fernflower / Vineflower (optional, recommended)

Fernflower is the JetBrains Java decompiler. It produces better output than jadx on complex Java constructs, lambdas, and generics. [Vineflower](https://github.com/Vineflower/vineflower) is the actively maintained community fork with published releases — prefer it over upstream Fernflower.

### Option 1: Vineflower from GitHub Releases (recommended)

1. Go to <https://github.com/Vineflower/vineflower/releases/latest>
2. Download `vineflower-<version>.jar`
3. Place it and set the environment variable:

```bash
mkdir -p ~/vineflower
mv vineflower-*.jar ~/vineflower/vineflower.jar
export FERNFLOWER_JAR_PATH="$HOME/vineflower/vineflower.jar"
# Add the export to ~/.bashrc or ~/.zshrc for persistence
```

### Option 2: Build Fernflower from source

```bash
git clone https://github.com/JetBrains/fernflower.git
cd fernflower
./gradlew jar
# Produces: build/libs/fernflower.jar
export FERNFLOWER_JAR_PATH="$(pwd)/build/libs/fernflower.jar"
```

### Option 3: Homebrew (Vineflower)

```bash
brew install vineflower
```

### Verify

```bash
java -jar "$FERNFLOWER_JAR_PATH" --version
```

> **Note**: Fernflower only works on JVM bytecode (JAR, class files). For APK/DEX files, you also need **dex2jar** (see below) as an intermediate conversion step.

---

## dex2jar (optional, needed for Fernflower on APK files)

Converts Android DEX bytecode to standard Java JAR files.

### GitHub Releases

1. Go to <https://github.com/pxb1988/dex2jar/releases/latest>
2. Download and extract:

```bash
unzip dex-tools-*.zip -d ~/dex2jar
export PATH="$HOME/dex2jar:$PATH"
```

### Homebrew

```bash
brew install dex2jar
```

### Verify

```bash
d2j-dex2jar --help
```

### Usage

```bash
# Convert APK (or DEX) to JAR
d2j-dex2jar -f -o output.jar app.apk

# Then decompile with Fernflower
java -jar vineflower.jar output.jar decompiled/
```

---

## Optional Tools

### bundletool (needed for AAB files)

bundletool converts Android App Bundles (AAB) to APK sets for decompilation.

```bash
# macOS (Homebrew)
brew install bundletool

# Or download the JAR:
# https://github.com/google/bundletool/releases/latest
mkdir -p ~/bundletool
mv bundletool-all-*.jar ~/bundletool/bundletool.jar
export BUNDLETOOL_JAR_PATH="$HOME/bundletool/bundletool.jar"
# Add the export to ~/.bashrc or ~/.zshrc for persistence
```

#### Verify

```bash
bundletool version
# Or: java -jar "$BUNDLETOOL_JAR_PATH" version
```

---

### apktool

Useful for decoding resources (XML layouts, drawables) that jadx sometimes handles poorly.

```bash
# Ubuntu/Debian
sudo apt install apktool

# macOS
brew install apktool

# Manual: https://apktool.org/docs/install
```

### adb (Android Debug Bridge)

Useful for pulling APKs directly from a connected Android device.

```bash
# Ubuntu/Debian
sudo apt install adb

# macOS
brew install android-platform-tools
```

Pull an APK from a device:

```bash
# List installed packages
adb shell pm list packages | grep <keyword>

# Get APK path
adb shell pm path com.example.app

# Pull the APK
adb pull /data/app/com.example.app-xxxx/base.apk ./app.apk
```

---

## Frida (Dynamic Analysis)

Frida is used for runtime instrumentation — hooking methods, bypassing protections, intercepting traffic. The setup involves two parts: **frida-tools** (Python client on your machine) and **frida-server** (binary on the Android device).

### Automated Setup (recommended)

The `setup-frida.sh` script handles everything:

```bash
bash scripts/setup-frida.sh
```

What it does:
1. Checks if a device is connected via adb
2. Looks for an existing frida-server on the device (most users already have one)
3. Gets the frida-server version from the device binary
4. Creates a Python venv at `~/.local/share/frida-re/venv`
5. Installs `frida-tools` matching the device's frida-server version
6. Validates version compatibility
7. Tests connectivity with `frida-ps -U`

If no frida-server exists on the device:
```bash
bash scripts/setup-frida.sh --install-server
```

### Manual Setup

#### 1. Python 3 + venv

```bash
# macOS
brew install python3

# Ubuntu/Debian
sudo apt install python3 python3-venv python3-pip

# Verify
python3 --version
python3 -m venv --help
```

#### 2. Frida Tools (always in a venv)

**Never install frida-tools globally.** Always use a virtual environment:

```bash
# Create venv
python3 -m venv ~/.local/share/frida-re/venv

# Activate
source ~/.local/share/frida-re/venv/bin/activate

# Install frida-tools (match your frida-server version)
pip install frida-tools==16.5.2  # example — use YOUR server version

# Verify
frida --version
frida-ps -U
```

To match a specific frida-server version:
```bash
# Check server version on device
adb shell /data/local/tmp/frida-server --version

# Install matching client
pip install frida-tools==<same version>
```

#### 3. Frida Server on Device

```bash
# Check device architecture
adb shell getprop ro.product.cpu.abi
# Output: arm64-v8a, armeabi-v7a, x86_64, or x86

# Download matching frida-server from:
# https://github.com/frida/frida/releases
# Look for: frida-server-<version>-android-<arch>.xz

# Decompress
xz -d frida-server-*.xz

# Push to device
adb push frida-server /data/local/tmp/
adb shell chmod 755 /data/local/tmp/frida-server

# Start (requires root)
adb shell su -c '/data/local/tmp/frida-server -D &'

# Verify from host
frida-ps -U
```

### Version Matching

**Client and server versions must match** (at least the major version). Mismatched versions cause cryptic connection errors.

```bash
# Check server version
adb shell /data/local/tmp/frida-server --version

# Check client version
~/.local/share/frida-re/venv/bin/frida --version

# If they differ, reinstall the client to match:
~/.local/share/frida-re/venv/bin/pip install frida-tools==<server-version>
```

### Using Frida via the Venv

After setup, always use the venv binaries directly:

```bash
# Without activating venv
~/.local/share/frida-re/venv/bin/frida -U <target>
~/.local/share/frida-re/venv/bin/frida-ps -U
~/.local/share/frida-re/venv/bin/frida-trace -U -f <package> -j 'com.example.*!*'

# Or activate the venv first
source ~/.local/share/frida-re/venv/bin/activate
frida -U <target>
```

The `frida-run.sh` script handles this automatically — it uses the venv without requiring activation.

---

## Troubleshooting

| Problem | Solution |
|---|---|
| `jadx: command not found` | Ensure the jadx `bin/` directory is in your `$PATH` |
| `Error: Could not find or load main class` | Java is missing or wrong version — verify with `java -version` |
| jadx runs out of memory on large APKs | Increase heap: `jadx -Xmx4g -d output app.apk` or set `JAVA_OPTS="-Xmx4g"` |
| Decompiled code has many `// Error` comments | Try `--show-bad-code` to see partial output, or use `--deobf` for obfuscated apps |
| Fernflower hangs on a method | Use `-mpm=60` to set a 60-second timeout per method |
| Fernflower JAR not found | Set `FERNFLOWER_JAR_PATH` env variable to the full path of the JAR |
| dex2jar fails with `ZipException` | The APK may have a non-standard ZIP structure — try `jadx` instead |
| bundletool not found for AAB file | Install bundletool or set `BUNDLETOOL_JAR_PATH` env variable |
| AAB fails with signing error | Use `--mode=universal` (default in decompile.sh) — no signing needed for analysis |
| DEX file not recognized | Ensure the file has `.dex` extension; jadx handles DEX natively |
| `frida-ps -U` shows nothing | frida-server not running — `adb shell su -c '/data/local/tmp/frida-server -D &'` |
| `Failed to enumerate processes` | Version mismatch between frida-tools and frida-server — check both versions |
| `unable to connect to remote frida-server` | Server not started, or device not in adb devices list |
| `frida-tools` install fails in venv | Upgrade pip first: `venv/bin/python -m pip install --upgrade pip` |
| `python3 -m venv` fails | Install venv module: `sudo apt install python3-venv` (Debian/Ubuntu) |
| App crashes immediately with Frida | RASP detection — use `--pause` flag and hook before app code runs |
| frida-server killed after a few seconds | Anti-frida process scanner — rename the binary or use a non-default port |
