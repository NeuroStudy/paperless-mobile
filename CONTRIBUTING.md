<!-- CONTRIBUTING -->

# Contributing

Contributions are what make the open source community such an amazing place to learn, inspire, and create. Any contributions you make are **greatly appreciated**.
All bug reports or feature requests are welcome, even if you can't contribute code!

This fork has one maintained development line. Read [AGENTS.md](AGENTS.md) and
[the consolidation log](docs/alpha2-consolidation.md) before making changes.

1. Work in `D:\DEV\paperless-mobile` on `codex/scan-enhancement-alpha2`.
2. Keep each improvement focused, run its regression checks and commit it separately.
3. Do not create/switch development branches or worktrees without an explicit user request.
4. Build verification APKs with the guarded command below, then push the maintained branch.

Upstream branches and archive tags are historical references, not development targets.

<!-- GETTING STARTED -->

## Getting Started

To get a local copy up and running follow these simple steps.

## Prerequisites and generated files

Use the Flutter submodule pinned by this repository. A separate installed Flutter
SDK can generate incompatible caches and test dependency versions. In PowerShell,
from the project root:

```powershell
git submodule update --init flutter
.\flutter\bin\flutter.bat pub get --enforce-lockfile
.\flutter\bin\flutter.bat gen-l10n
.\flutter\bin\dart.bat run build_runner build --delete-conflicting-outputs
```

The standalone scanner is in `packages/paperless_mobile_document_scanner`; its
runtime dependencies are resolved with the root app. There is no separate
`packages/paperless_api` code-generation step.

Run the maintained test entrypoints and Android harness:

```powershell
.\flutter\bin\flutter.bat test --no-pub test/scanner test/api test/features/chat test/src/widget_test.dart
.\scripts\test_scanner_android.ps1 -DeviceId emulator-5556
.\flutter\bin\flutter.bat analyze --no-pub --no-fatal-infos
```

Use a working JDK 21 for direct Gradle commands. Flutter also supports a configured
JDK location; verify it if the environment points to a removed Android Studio install.

## Build release version

### Local testing

Add the following line to `android/local.properties` (keep its existing SDK settings):

```properties
useDebugSigning=true
```

This ignored, checkout-specific setting persists across builds and signs release APKs
with the machine's debug key. Gradle prints a warning for these artifacts; use them
only for local testing. No changes to the Gradle build files are needed. An installed
app signed with a different key cannot be updated with this APK.

For a single PowerShell session, you can instead set
`$env:ORG_GRADLE_PROJECT_useDebugSigning = 'true'`. Direct Gradle commands also accept
`-PuseDebugSigning=true`; an explicit Gradle property overrides `local.properties`.

### Distribution releases

Remove `useDebugSigning=true` (or set it to `false`), copy
`android/key.properties.example` to `android/key.properties`, and fill in all four
properties using your existing release keystore. Relative `storeFile` paths start
at `android/app`, matching CI. On Windows, use forward slashes or escaped backslashes
in the keystore path. Keep credentials and keystores out of version control.

Release builds without the local testing opt-in validate missing properties and
keystore paths before app compilation. Debug builds do not require release keys.
See the [Flutter signing instructions](https://docs.flutter.dev/deployment/android#sign-the-app)
for keystore setup. CI continues to use its existing signing action.

### Build and identify verification APKs

Commit source changes first. The standard build command checks the project folder,
branch, Alpha 2 ancestry, clean working tree, standalone scanner and pinned SDK.
It resolves locked dependencies, regenerates sources and verifies that the source
revision did not change during compilation.

```powershell
.\scripts\build_alpha2_apk.ps1 -CheckOnly
.\scripts\build_alpha2_apk.ps1 -Mode release -TargetPlatform android-arm64
```

`-Mode debug -TargetPlatform android-x64` builds an emulator verification APK.
The default output is `build/verified-apks/`. Each filename identifies Alpha 2,
mode, target, version and source revision. The adjacent JSON manifest records
source/SDK revisions, dependency lock hash, application ID, signing mode and APK
SHA-256. About displays the short source revision. Builds made outside this
entrypoint display `unrecorded build` and are not verified artifacts.

A release-mode APK using the local debug signing opt-in remains a local test
artifact. This workflow does not publish an app release or increment its version.
Preserve the manifest with the APK; the version label alone is not build identity.

To install a chosen artifact, use its full path explicitly:

```powershell
adb install -r "build/verified-apks/<verified-apk-name>.apk"
```

Installing with a different signing key requires separate handling of existing
app data; do not uninstall the installed app merely to bypass a signature mismatch.
