// The version of the running build, as Settings > About shows it.
//
// The Flutter tool embeds `version:` from pubspec.yaml (or --build-name and
// --build-number when a build overrides them) into every build as
// appBuildName and appBuildNumber, the same values Gradle writes to
// versionName and versionCode. So the text always matches the APK and never
// needs a hand edit when the version is bumped.
import 'package:flutter/services.dart' show appBuildName, appBuildNumber;

/// "1.0.0 (2)": versionName (versionCode). Only a compile outside the
/// Flutter tool, which has no version, shows "dev".
const String appVersion = appBuildNumber == null
    ? appBuildName ?? 'dev'
    : '${appBuildName ?? 'dev'} ($appBuildNumber)';
