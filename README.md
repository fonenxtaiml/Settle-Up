# Settle Up

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
