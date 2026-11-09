// The Android window controls that Flutter has no API for, answered by
// MainActivity on the `app.settleup/window` channel:
//
// - FLAG_SECURE while a secret is on screen (the invite QR carries the
//   group key), so it stays out of screenshots, screen recordings and the
//   recents thumbnail (see [AppWindow.holdSecure]).
// - The app's night mode (API 31+), so the system splash and the launch
//   window on the next cold start match the theme picked in Settings.
//
// Every call is best effort: on other platforms, in tests without a mock
// handler and on old Android versions it does nothing.
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/models.dart';

abstract final class AppWindow {
  static const MethodChannel channel = MethodChannel('app.settleup/window');

  static int _secureHolds = 0;
  static AppThemeMode? _nightMode;

  /// Whether FLAG_SECURE is currently requested.
  static bool get isSecure => _secureHolds > 0;

  /// Requests FLAG_SECURE. Pair every call with [releaseSecure]; the flag
  /// is cleared when the last hold is released.
  static Future<void> holdSecure() {
    _secureHolds++;
    return _secureHolds == 1 ? _invoke('setSecure', true) : Future.value();
  }

  static Future<void> releaseSecure() {
    if (_secureHolds == 0) return Future.value();
    _secureHolds--;
    return _secureHolds == 0 ? _invoke('setSecure', false) : Future.value();
  }

  /// Stores [mode] as the app's night mode. Repeats of the last value sent
  /// in this process are skipped.
  static Future<void> setNightMode(AppThemeMode mode) {
    if (_nightMode == mode) return Future.value();
    _nightMode = mode;
    return _invoke('setNightMode', mode.name);
  }

  @visibleForTesting
  static void resetForTest() {
    _secureHolds = 0;
    _nightMode = null;
  }

  static Future<void> _invoke(String method, Object? arguments) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await channel.invokeMethod<Object?>(method, arguments);
    } on MissingPluginException {
      // No MainActivity handler (widget tests, add-to-app).
    } on PlatformException catch (e) {
      developer.log(
        'Window call $method failed: $e',
        name: 'settle_up.ui.window',
      );
    }
  }
}
