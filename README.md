# Settle Up

An expense-splitting app that works with no internet. Groups, expenses and
payments live on the phone, and two phones sync directly over Wi-Fi or a
hotspot (TCP + mDNS), Google Nearby Connections or Bluetooth LE, encrypted
with the group keys (X25519 handshake, AES-256-GCM). Flutter, Android
first.

| Document | What it is |
| --- | --- |
| [docs/SPEC.md](docs/SPEC.md) | Build specification: data model, op log, sync protocol, platform setup. |
| [docs/design/DESIGN.md](docs/design/DESIGN.md) | The approved "Point to Point" design; screens in `docs/design/point-to-point/`. |
| [docs/QA.md](docs/QA.md) | Manual checklist for the radios and permissions on real phones. |
| [docs/qa/TEST-PLAN.md](docs/qa/TEST-PLAN.md) | QA test plan: what the automated suites cover and what needs a device. |
| [docs/PRIVACY.md](docs/PRIVACY.md) | Privacy policy (the Play listing links to it). |
| [docs/STORE-LISTING.md](docs/STORE-LISTING.md) | Play store text, Data safety answers, permission justifications. |
| [docs/release-notes.md](docs/release-notes.md) | What changed in each release. |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Branches and pull requests. |

## Prerequisites

- Flutter 3.47.x (stable) with Dart 3.13. Check with `flutter --version`.
- Android SDK with platform 37 (`compileSdk 37`, `targetSdk 36`, `minSdk
  26`) and the build tools Flutter asks for; `flutter doctor` lists what
  is missing.
- JDK 17 or newer (the Android build targets Java 17; JDK 21 works).
- For sync testing: two Android phones (8.0 or newer). An emulator has no
  Bluetooth or Nearby Connections.

## Run

```sh
flutter pub get
flutter run                      # on a connected phone (debug build)
flutter run --release            # closer to what testers get
```

The demo world (groups "Goa trip", "Flat 4B" and "Cabin weekend" with
balances, in-memory fakes, no real storage or radios) is a compile-time
switch:

```sh
flutter run --dart-define=SETTLEUP_FAKE=true
```

Leave `SETTLEUP_FAKE` out of every build you hand to anyone: it replaces
the database and sync with fakes and nothing it shows is saved.

## Test and analyze

```sh
flutter analyze                  # must report "No issues found!"
flutter test                     # the whole suite, no device needed
flutter test test/core           # one folder
flutter test --run-skipped test/qa   # also run QA repro tests still skipped
```

Golden images live in `test/ui/screens/goldens/`. After an intended visual
change, regenerate them with
`flutter test --update-goldens test/ui/screens/screens_golden_test.dart`
and review the PNG diff before committing. The radio checks that need real
phones are in [docs/QA.md](docs/QA.md).

## Build

```sh
flutter build apk --release                  # one APK for all ABIs
flutter build apk --release --split-per-abi  # smaller APKs, one per ABI
flutter build appbundle --release            # .aab for Google Play
```

Outputs: `build/app/outputs/flutter-apk/app-release.apk` (or
`app-arm64-v8a-release.apk` and friends with `--split-per-abi`) and
`build/app/outputs/bundle/release/app-release.aab`. Most phones need the
`arm64-v8a` APK. With `--split-per-abi`, Flutter adds `1000 x` an ABI
number to the versionCode of each APK.

### Version

`version:` in `pubspec.yaml` (`1.0.0+2`) is the only place the version is
set: Gradle takes versionName and versionCode from it, and Settings >
About shows the same `1.0.0 (2)` from the build. For every APK given to
testers or uploaded to Play, raise the number after `+` (Android refuses
to update to a versionCode it already has), and add an entry to
[docs/release-notes.md](docs/release-notes.md).

## Release signing

Release APKs and app bundles are signed with the upload key named in
`android/key.properties`. That file and every `*.jks` / `*.keystore` are
git-ignored: never commit them.

### Create the upload key (once)

```sh
keytool -genkeypair -v -storetype PKCS12 \
  -keystore ~/keys/settle-up-upload.jks \
  -alias upload -keyalg RSA -keysize 4096 -validity 10000
```

Then create `android/key.properties`:

```properties
storeFile=/home/you/keys/settle-up-upload.jks
storePassword=<keystore password>
keyAlias=upload
keyPassword=<key password>
```

A relative `storeFile` is resolved from the `android/` folder. All four
keys are required; a missing one stops the build with a message.

**Back up the keystore and both passwords** in two places outside this
machine (for example a password manager and an offline drive). If the key
is lost, an installed app can never be updated: every user would have to
uninstall, and because backup and device transfer are off (SPEC 7.4),
uninstalling deletes their data on that phone. With Play App Signing the
upload key can be reset through Play support, but the app signing key
cannot.

### Build

```sh
flutter build apk --release        # or: flutter build appbundle --release
apksigner verify --print-certs build/app/outputs/flutter-apk/app-release.apk
```

The printed certificate must be yours, not `CN=Android Debug`.

### Without key.properties

A release build still works for local testing: it falls back to the debug
key and Gradle prints `WARNING: android/key.properties not found: this
RELEASE build is signed with the DEBUG key`. Such an APK must not be
published. For CI or store builds pass `-PrequireReleaseKey`, which turns
the warning into an error:

```sh
flutter build appbundle --release -PrequireReleaseKey
```

### Upgrading from 0.1.0

The 0.1.0 test APKs were signed with the debug key and used the codename
id `app.settleup.settle_up`. From 1.0.0 the app id is
`app.settleup.settleup` and the APK is signed with the upload key, so 1.0.0
installs as a separate app and cannot update 0.1.0. See
[docs/release-notes.md](docs/release-notes.md).
