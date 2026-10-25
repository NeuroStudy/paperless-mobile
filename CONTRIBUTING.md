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
- Install the flutter SDK (https://docs.flutter.dev/get-started/install) _or_ use the flutter git submodule pinned in this project by running `git submodule update --init` inside the project root directory.

## Install dependencies and generate files

1. First, clone the repository:

```sh
git clone https://github.com/astubenbord/paperless-mobile.git
```

You can now run the `scripts/install_dependencies.sh` script at the root of the project, which will automatically install dependencies and generate files for both the app and local packages.

If you want to manually install dependencies and build generated files, you can also run the following commands:

### Inside the `packages/paperless_api/` folder:

2. Install the dependencies for `paperless_api`
   ```sh
   dart pub get
   ```
3. Build generated files for `paperless_api`
   ```sh
    dart pub run build_runner build --delete-conflicting-outputs
   ```

### Inside the project's root folder

4. Install the dependencies for the app
   ```sh
   dart pub get
   ```
5. Build generated files for the app
   ```sh
   dart pub run build_runner build --delete-conflicting-outputs
   ```
6. Generate the localization files for the app
   ```sh
   flutter gen-l10n
   ```

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

### Build and install

1. Build the app with release profile (here for android):

```sh
flutter build apk
```

The --release flag is implicit for the build command. You can also run this command with --split-per-abi, which will generate three separate (smaller) binaries.

2. Install the app to your device (when omitting the `--split-per-abi` flag)

```sh
flutter install
```

or when you built with `--split-per-abi`

```sh
flutter install --use-application-binary=build/app/outputs/flutter-apk/<apk_file_name>.apk
```
