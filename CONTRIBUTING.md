<!-- CONTRIBUTING -->

# Contributing

Contributions are what make the open source community such an amazing place to learn, inspire, and create. Any contributions you make are **greatly appreciated**.
All bug reports or feature requests are welcome, even if you can't contribute code!

If you have a suggestion that would make this better, please fork the repo and create a pull request. You can also simply open an issue with the tag "enhancement".
Don't forget to give the project a star! Thanks again!

1. Fork the Project
2. Create your Feature Branch (`git checkout -b feature/AmazingFeature`)
3. Commit your Changes (`git commit -m 'feat: Add some AmazingFeature'`)
4. Push to the Branch (`git push origin feature/AmazingFeature`)
5. Open a Pull Request

<!-- GETTING STARTED -->

## Getting Started

To get a local copy up and running follow these simple steps.

## Prerequisites

- Install an IDE of your choice (e.g. VSCode with the Dart/Flutter extensions)
- Use the Flutter SDK pinned by the `flutter` git submodule (Flutter 3.35.4 / Dart 3.9.2). Run `git submodule update --init flutter` after cloning. The FVM pin uses the same version.
- For Android, install Android SDK platform 36, build tools 35.0.0, and NDK 27.0.12077973. Use a JDK compatible with Gradle 8.13 (JDK 17 or 21, such as Android Studio's bundled JDK). The project uses Android Gradle Plugin 8.13.2 and Kotlin 2.3.0; AGP 8.13.2 includes D8/R8 support for Kotlin 2.3 metadata.
- In VS Code, the workspace settings select the bundled Flutter SDK. In Android Studio, set the project's Flutter SDK path to `<project>/flutter` and the Gradle JDK to your installed JDK. Avoid mixing a different SDK from your system PATH with this project's SDK.

## Install dependencies and generate files

1. First, clone the repository:

```sh
git clone https://github.com/astubenbord/paperless-mobile.git
```

Initialize the pinned SDK, then install dependencies and generate files from the project root.

On Windows (PowerShell):

```powershell
git submodule update --init flutter
.\scripts\install_dependencies.ps1
.\flutter\bin\flutter.bat analyze
.\flutter\bin\flutter.bat test
.\flutter\bin\flutter.bat emulators --launch Pixel_9_API_36
.\flutter\bin\flutter.bat run
```

Use the name of your own Android virtual device if it differs. Alternatively, connect an Android phone with USB debugging enabled.

On macOS/Linux:

```sh
git submodule update --init flutter
bash scripts/install_dependencies.sh
./flutter/bin/flutter analyze
./flutter/bin/flutter test
./flutter/bin/flutter run
```

Both setup scripts use the pinned SDK to run `flutter pub get`, `flutter gen-l10n`, and `dart run build_runner build --delete-conflicting-outputs`. The API code is part of the app; there is no separate `packages/paperless_api` setup step.

Use `flutter/bin/flutter` (or `flutter\bin\flutter.bat` on Windows) for subsequent Flutter commands. It updates the ignored `android/local.properties` SDK path automatically. Machine-specific SDK paths should not be committed.

The bundled `flutter/` SDK is excluded from app analysis; `lib/`, tests, and `packages/edge_detection` remain analyzed. Android libraries compile against at least SDK 36, including older plugins whose hard-coded SDK levels do not meet their AndroidX dependencies' requirements. On Windows, Kotlin incremental compilation is disabled only for plugin projects located on a different drive from the app, avoiding cross-drive cache failures while keeping it enabled for other projects.

Gradle workers and Kotlin daemon heaps are bounded in `android/gradle.properties` so builds can run alongside an emulator without starting many large compiler processes. Test the local scanner through the host Android project:

```powershell
Push-Location android
.\gradlew.bat :edge_detection:testDebugUnitTest
# Requires a running Android emulator or connected device:
.\gradlew.bat :edge_detection:connectedDebugAndroidTest
Pop-Location
```

## Build release version

In order to build a release version, you have to...

1. Exchange the signing configuration in android/app/build.gradle from

```gradle
buildTypes {
    release {
        signingConfig signingConfigs.release
    }
}
```

to

```gradle
buildTypes {
    release {
        signingConfig signingConfigs.debug
    }
}
```

or use your own signing configuration as described in https://docs.flutter.dev/deployment/android#signing-the-app and leave the `build.gradle` as is.

2. Build the app with release profile (here for android):

```sh
flutter build apk
```

The --release flag is implicit for the build command. You can also run this command with --split-per-abi, which will generate three separate (smaller) binaries.

3. Install the app to your device (when omitting the `--split-per-abi` flag)

```sh
flutter install
```

or when you built with `--split-per-abi`

```sh
flutter install --use-application-binary=build/pp/outputs/flutter-apk/<apk_file_name>.apk
```
