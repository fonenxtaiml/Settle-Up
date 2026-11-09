// QA SECURITY round 1: static checks of the Android app manifest and
// activity (SPEC 9.1). These read the source files; the merged manifest of
// a release build was reviewed by hand (see the QA report).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _manifest = 'android/app/src/main/AndroidManifest.xml';

String _read(String path) => File(path).readAsStringSync();

/// `<tag ...>` openings of [tag] with their attribute text.
List<String> _openings(String xml, String tag) => [
  for (final m in RegExp('<$tag\\b([^>]*)>').allMatches(xml)) m.group(1)!,
];

String _withoutComments(String xml) =>
    xml.replaceAll(RegExp(r'<!--[\s\S]*?-->'), '');

void main() {
  final xml = _withoutComments(_read(_manifest));

  test('only the main activity is exported, and nothing else is declared', () {
    final activities = _openings(xml, 'activity');
    expect(activities, hasLength(1));
    expect(activities.single, contains('android:name=".MainActivity"'));
    expect(activities.single, contains('android:exported="true"'));
    for (final tag in ['service', 'receiver', 'provider']) {
      expect(_openings(xml, tag), isEmpty, reason: tag);
    }
  });

  test(
    'VIEW intent filters accept only settleup://join and settleup://sync',
    () {
      final filters = RegExp(r'<intent-filter>([\s\S]*?)</intent-filter>')
          .allMatches(xml)
          .map((m) => m.group(1)!)
          .toList();
      final view = filters.where((f) => f.contains('action.VIEW')).toList();
      expect(view, hasLength(1));
      final data = _openings(view.single, 'data');
      expect(data, hasLength(2));
      final pairs = {
        for (final d in data)
          (
            RegExp(r'android:scheme="([^"]*)"').firstMatch(d)?.group(1),
            RegExp(r'android:host="([^"]*)"').firstMatch(d)?.group(1),
          ),
      };
      expect(pairs, {('settleup', 'join'), ('settleup', 'sync')});
      expect(view.single, isNot(contains('android:autoVerify')));
      expect(xml, isNot(contains('android:scheme="http')));
    },
  );

  test('backup is off and cleartext is not opted into', () {
    final app = _openings(xml, 'application').single;
    expect(app, contains('android:allowBackup="false"'));
    expect(app, contains('android:fullBackupContent="false"'));
    expect(app, isNot(contains('usesCleartextTraffic="true"')));
    expect(app, isNot(contains('android:debuggable')));
  });

  test(
    'API 31+ device-to-device transfer is excluded by dataExtractionRules',
    skip:
        'QA SECURITY-R1-07: no android:dataExtractionRules; on Android 12+ '
        'allowBackup=false does not stop device-to-device transfer',
    () {
      final app = _openings(xml, 'application').single;
      final m = RegExp(r'android:dataExtractionRules="@xml/([^"]+)"')
          .firstMatch(app);
      expect(m, isNotNull);
      final rules = _read('android/app/src/main/res/xml/${m!.group(1)}.xml');
      expect(rules, contains('<cloud-backup'));
      expect(rules, contains('<device-transfer'));
      // Everything excluded in both: database, shared prefs (secure
      // storage), files.
      for (final section in ['cloud-backup', 'device-transfer']) {
        final body = RegExp('<$section[^>]*>([\\s\\S]*?)</$section>')
            .firstMatch(rules)
            ?.group(1);
        expect(body, isNotNull, reason: section);
        for (final domain in ['database', 'sharedpref', 'file', 'root']) {
          expect(
            body,
            contains('domain="$domain"'),
            reason: '$section $domain',
          );
        }
      }
    },
  );

  test('location and legacy Bluetooth stay capped after plugin merges', () {
    for (final p in [
      'BLUETOOTH"',
      'BLUETOOTH_ADMIN"',
      'ACCESS_COARSE_LOCATION"',
      'ACCESS_FINE_LOCATION"',
    ]) {
      final decl = RegExp('<uses-permission[^>]*android.permission.$p[^>]*>')
          .firstMatch(xml)
          ?.group(0);
      expect(decl, isNotNull, reason: p);
      expect(decl, contains('android:maxSdkVersion'), reason: p);
      expect(decl, contains('tools:node="replace"'), reason: p);
    }
    for (final p in ['BLUETOOTH_SCAN', 'NEARBY_WIFI_DEVICES']) {
      final decl = RegExp('<uses-permission[^>]*android.permission.$p"[^>]*>')
          .firstMatch(xml)
          ?.group(0);
      expect(decl, contains('neverForLocation'), reason: p);
    }
    // No background location, no SMS/contacts/storage.
    for (final p in [
      'ACCESS_BACKGROUND_LOCATION',
      'READ_EXTERNAL_STORAGE',
      'WRITE_EXTERNAL_STORAGE',
      'READ_CONTACTS',
      'RECORD_AUDIO',
    ]) {
      expect(xml, isNot(contains(p)), reason: p);
    }
  });

  test(
    'the invite QR screen is protected from screenshots and the recents '
    'thumbnail',
    skip:
        'QA SECURITY-R1-09: invite QR (the group key) is captured in the '
        'recents thumbnail and screenshots; no FLAG_SECURE',
    () {
      final activity = _read(
        'android/app/src/main/kotlin/app/settleup/settle_up/MainActivity.kt',
      );
      final invite = _read('lib/ui/screens/group/invite_screen.dart');
      expect(
        activity.contains('FLAG_SECURE') ||
            invite.contains('FLAG_SECURE') ||
            invite.contains('secure'),
        isTrue,
      );
    },
  );
}
