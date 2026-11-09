// QA PLATFORM round 1: production metadata and build configuration, read
// from the files that go into the APK (pubspec, Gradle scripts, the
// Android manifest and resources) and the release docs.
//
// These checks run under `flutter test` from the package root, so they
// catch regressions without a device. The manual part (install, launcher,
// signature on a phone) is in docs/qa/TEST-PLAN.md section 7.
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/bootstrap.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

String _read(String path) => File(path).readAsStringSync();

const _manifest = 'android/app/src/main/AndroidManifest.xml';
const _appGradle = 'android/app/build.gradle.kts';
const _res = 'android/app/src/main/res';

/// SHA-256 of the stock Flutter template launcher icons (flutter create),
/// per density.
const _flutterDefaultIcons = {
  'mipmap-hdpi':
      '6a7c8f0d703e3682108f9662f813302236240d3f8f638bb391e32bfb96055fef',
  'mipmap-mdpi':
      'c7c0c0189145e4e32a401c61c9bdc615754b0264e7afae24e834bb81049eaf81',
  'mipmap-xhdpi':
      'e14aa40904929bf313fded22cf7e7ffcbf1d1aac4263b5ef1be8bfce650397aa',
  'mipmap-xxhdpi':
      '4d470bf22d5c17d84edc5f82516d1ba8a1c09559cd761cefb792f86d9f52b540',
  'mipmap-xxxhdpi':
      '3c34e1f298d0c9ea3455d46db6b7759c8211a49e9ec6e44b635fc5c87dfb4180',
};

Future<String> _sha256(String path) async {
  final hash = await Sha256().hash(File(path).readAsBytesSync());
  return hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}

void main() {
  group('app identity (passes today)', () {
    test('launcher label is "Settle Up" and matches the in-app name', () {
      expect(_read(_manifest), contains('android:label="Settle Up"'));
      expect(S.appName, 'Settle Up');
    });

    test('settleup:// join and sync deep links are declared', () {
      final m = _read(_manifest);
      expect(m, contains('android:scheme="settleup" android:host="join"'));
      expect(m, contains('android:scheme="settleup" android:host="sync"'));
    });

    test('minSdk 26, targetSdk 36 (SPEC 9.1)', () {
      final g = _read(_appGradle);
      expect(g, contains(RegExp(r'minSdk\s*=\s*26\b')));
      expect(g, contains(RegExp(r'targetSdk\s*=\s*36\b')));
    });

    test('no android:debuggable or cleartext overrides in the manifest', () {
      final m = _read(_manifest);
      expect(m, isNot(contains('android:debuggable')));
      expect(m, isNot(contains('usesCleartextTraffic="true"')));
    });

    test('cloud backup is off (SPEC 7.4)', () {
      expect(_read(_manifest), contains('android:allowBackup="false"'));
    });

    test('key.properties and keystores are git-ignored', () {
      final ignore = _read('android/.gitignore');
      expect(ignore, contains('key.properties'));
      expect(ignore, contains('*.jks'));
      expect(ignore, contains('*.keystore'));
    });
  });

  group('no debug paths in a normal build (passes today)', () {
    test('SETTLEUP_FAKE is off unless --dart-define sets it', () {
      expect(kUseFakes, isFalse);
    });

    test('debug banner is disabled', () {
      expect(
        _read('lib/ui/app.dart'),
        contains('debugShowCheckedModeBanner: false'),
      );
    });

    test('no dev, debug or demo route is registered', () {
      final router = _read('lib/ui/router.dart');
      for (final word in ['/dev', '/debug', '/demo', '/fake']) {
        expect(router, isNot(contains("'$word")), reason: word);
      }
      expect(Routes.home, '/home');
    });

    test('lib/ui/dev is only reachable from bootstrap behind kUseFakes', () {
      final users = <String>[];
      for (final f in Directory('lib').listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        if (f.path.contains(
          '${Platform.pathSeparator}dev${Platform.pathSeparator}',
        )) {
          continue;
        }
        if (f.readAsStringSync().contains('ui/dev/')) users.add(f.path);
      }
      expect(users, [
        'lib/bootstrap.dart'.replaceAll('/', Platform.pathSeparator),
      ]);
    });
  });

  group('version', () {
    test('pubspec version is 1.0.0+N for the production release', () {
      final version = RegExp(
        r'^version:\s*(\S+)',
        multiLine: true,
      ).firstMatch(_read('pubspec.yaml'))!.group(1)!;
      expect(version, matches(RegExp(r'^1\.0\.0\+[1-9][0-9]*$')));
    }, skip: 'QA PLATFORM-R1-04: pubspec version is 0.1.0+1, not 1.0.0+N');
  });

  group('launcher icon', () {
    test(
      'icons are not the stock Flutter icon in any density',
      () async {
        for (final e in _flutterDefaultIcons.entries) {
          final path = '$_res/${e.key}/ic_launcher.png';
          expect(File(path).existsSync(), isTrue, reason: path);
          expect(
            await _sha256(path),
            isNot(e.value),
            reason: '$path is the Flutter template icon',
          );
        }
      },
    );

    test(
      'adaptive icon (API 26+) with foreground and monochrome layers',
      () {
        final file = File('$_res/mipmap-anydpi-v26/ic_launcher.xml');
        expect(
          file.existsSync(),
          isTrue,
          reason: 'minSdk is 26, so every phone uses the adaptive icon',
        );
        final xml = file.readAsStringSync();
        expect(xml, contains('<adaptive-icon'));
        expect(xml, contains('<foreground'));
        expect(
          xml,
          contains('<monochrome'),
          reason: 'Android 13+ themed icons',
        );
      },
    );
  });

  group('release signing', () {
    test(
      'release is not signed with the debug key unconditionally',
      () {
        final g = _read(_appGradle);
        expect(
          g,
          contains('key.properties'),
          reason: 'release signing must read android/key.properties',
        );
        final release = RegExp(
          r'release\s*\{[^}]*\}',
          dotAll: true,
        ).firstMatch(g.substring(g.indexOf('buildTypes')))!.group(0)!;
        expect(
          release,
          isNot(
            contains('signingConfig = signingConfigs.getByName("debug")\n'),
          ),
          reason: 'a debug fallback must be conditional and logged',
        );
      },
    );
  });

  group('template leftovers', () {
    test(
      'no Flutter template TODOs left in the Android build',
      () {
        final hits = <String>[];
        for (final path in [
          _appGradle,
          'android/build.gradle.kts',
          _manifest,
        ]) {
          final lines = _read(path).split('\n');
          for (var i = 0; i < lines.length; i++) {
            if (lines[i].contains('TODO')) hits.add('$path:${i + 1}');
          }
        }
        expect(hits, isEmpty);
      },
    );
  });

  group('device-to-device transfer (Android 12+)', () {
    test(
      'data extraction rules exclude the op log and settings',
      () {
        // allowBackup="false" stops cloud backup only; for targetSdk >= 31 the
        // device-to-device transfer (new phone setup, cable or Wi-Fi) still
        // copies app data unless dataExtractionRules excludes it.
        final m = _read(_manifest);
        final ref = RegExp(r'android:dataExtractionRules="@xml/([a-z_]+)"')
            .firstMatch(m);
        expect(
          ref,
          isNotNull,
          reason: 'targetSdk 36 needs android:dataExtractionRules',
        );
        final rules = _read('$_res/xml/${ref!.group(1)}.xml');
        expect(rules, contains('<device-transfer>'));
        expect(rules, contains('<exclude'));
      },
    );
  });

  group('release docs', () {
    test('README explains run, build, test and release', () {
      final readme = _read('README.md').toLowerCase();
      for (final word in [
        'flutter run',
        'flutter test',
        'flutter build apk',
        'key.properties',
        'settleup_fake',
      ]) {
        expect(readme, contains(word), reason: 'README lacks "$word"');
      }
    }, skip: 'QA PLATFORM-R1-08: README.md is a single heading');

    test('privacy policy and store listing are in the repo', () {
      final docs = Directory('docs')
          .listSync(recursive: true)
          .whereType<File>()
          .map((f) => f.path.toLowerCase())
          .toList();
      expect(
        docs.any((p) => p.contains('privacy')),
        isTrue,
        reason: 'no privacy policy under docs/',
      );
      expect(
        docs.any((p) => p.contains('store') || p.contains('listing')),
        isTrue,
        reason: 'no store listing text under docs/',
      );
    }, skip: 'QA PLATFORM-R1-10: no privacy policy or store listing');
  });
}
