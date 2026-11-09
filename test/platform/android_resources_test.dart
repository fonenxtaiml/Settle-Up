// Android launcher icon, launch window and splash resources (PLATFORM-R1-05,
// VISUAL-R1-14): the Point to Point mark on stone, in the theme's colours,
// so a cold start blends into the first Flutter frame.
import 'dart:io';
import 'dart:ui' show Color;

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/theme/tokens.dart';
import 'package:settle_up/ui/platform/app_window.dart';

const _res = 'android/app/src/main/res';

String _read(String path) => File(path).readAsStringSync();

/// `<color name="[name]">` in [file], as a [Color].
Color _color(String file, String name) {
  final m = RegExp('<color name="$name">#([0-9A-Fa-f]{8})</color>')
      .firstMatch(_read(file));
  expect(m, isNotNull, reason: '$name in $file');
  return Color(int.parse(m!.group(1)!, radix: 16));
}

/// Width and height of a PNG from its IHDR chunk.
(int, int) _pngSize(String path) {
  final b = File(path).readAsBytesSync();
  int u32(int o) =>
      (b[o] << 24) | (b[o + 1] << 16) | (b[o + 2] << 8) | b[o + 3];
  return (u32(16), u32(20));
}

void main() {
  group('launch window', () {
    test('colours are the stone and ink tokens, day and night', () {
      expect(
        _color('$_res/values/colors.xml', 'launch_background'),
        Palette.stone,
      );
      expect(_color('$_res/values/colors.xml', 'launch_mark'), Palette.ink);
      expect(
        _color('$_res/values-night/colors.xml', 'launch_background'),
        Palette.stoneDark,
      );
      expect(
        _color('$_res/values-night/colors.xml', 'launch_mark'),
        Palette.inkDark,
      );
      expect(
        _color('$_res/values/colors.xml', 'ic_launcher_background'),
        Palette.stone,
      );
    });

    test('the launch background is stone with the mark, not the template', () {
      final xml = _read('$_res/drawable/launch_background.xml');
      expect(xml, contains('@color/launch_background'));
      expect(xml, contains('@drawable/ic_launch_mark'));
      expect(xml, isNot(contains('@android:color/white')));
      expect(xml, isNot(contains('?android:colorBackground')));
      // minSdk 26: a drawable-v21 copy would always win over this one.
      expect(
        File('$_res/drawable-v21/launch_background.xml').existsSync(),
        isFalse,
      );
      expect(
        _read('$_res/drawable/ic_launch_mark.xml'),
        contains('@color/launch_mark'),
      );
    });

    for (final dir in [
      'values',
      'values-night',
      'values-v31',
      'values-night-v31',
    ]) {
      test('$dir: LaunchTheme and NormalTheme use the stone colours', () {
        final xml = _read('$_res/$dir/styles.xml');
        expect(xml, isNot(contains('Theme.Light.NoTitleBar')));
        expect(xml, isNot(contains('Theme.Black.NoTitleBar')));
        final launch = RegExp(r'<style name="LaunchTheme"[\s\S]*?</style>')
            .firstMatch(xml)!
            .group(0)!;
        expect(launch, contains('@drawable/launch_background'));
        final normal = RegExp(r'<style name="NormalTheme"[\s\S]*?</style>')
            .firstMatch(xml)!
            .group(0)!;
        expect(normal, contains('@color/launch_background'));
        if (dir.endsWith('v31')) {
          // Android 12+ system splash.
          expect(
            launch,
            contains('windowSplashScreenBackground">@color/launch_background'),
          );
          expect(
            launch,
            contains(
              'windowSplashScreenAnimatedIcon">@drawable/ic_launch_mark',
            ),
          );
        }
      });
    }

    test('MainActivity answers the window channel the app calls', () {
      final activity = _read(
        'android/app/src/main/kotlin/app/settleup/settle_up/MainActivity.kt',
      );
      expect(activity, contains('"${AppWindow.channel.name}"'));
      for (final method in ['setSecure', 'setNightMode']) {
        expect(activity, contains('"$method"'), reason: method);
      }
      expect(activity, contains('FLAG_SECURE'));
      expect(activity, contains('setApplicationNightMode'));
    });
  });

  group('launcher icon', () {
    test('adaptive icon and round icon share the stone background', () {
      for (final name in ['ic_launcher', 'ic_launcher_round']) {
        final xml = _read('$_res/mipmap-anydpi-v26/$name.xml');
        expect(xml, contains('@color/ic_launcher_background'), reason: name);
        expect(xml, contains('@drawable/ic_launcher_foreground'), reason: name);
        expect(xml, contains('<monochrome'), reason: name);
      }
      expect(
        _read('android/app/src/main/AndroidManifest.xml'),
        contains('android:roundIcon="@mipmap/ic_launcher_round"'),
      );
    });

    test('legacy icons exist in every density at the right size', () {
      const sizes = {
        'mdpi': 48,
        'hdpi': 72,
        'xhdpi': 96,
        'xxhdpi': 144,
        'xxxhdpi': 192,
      };
      for (final e in sizes.entries) {
        for (final name in ['ic_launcher', 'ic_launcher_round']) {
          final path = '$_res/mipmap-${e.key}/$name.png';
          expect(_pngSize(path), (e.value, e.value), reason: path);
        }
      }
    });

    test(
      'the iOS icon set is the same mark, not the Flutter default',
      () async {
        const dir = 'ios/Runner/Assets.xcassets/AppIcon.appiconset';
        final big = '$dir/Icon-App-1024x1024@1x.png';
        expect(_pngSize(big), (1024, 1024));
        final hash = await Sha256().hash(File(big).readAsBytesSync());
        final hex = hash.bytes
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        // The `flutter create` template icon.
        expect(
          hex,
          isNot(
            '7770183009e914112de7d8ef1d235a6a30c5834424858e0d2f8253f6b8d31926',
          ),
        );
      },
    );
  });
}
