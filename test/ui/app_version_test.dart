// Settings > About shows the version the app was built with, taken from
// pubspec.yaml by the Flutter tool (UIFLOW-R1-12).
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/app_version.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'screens/screen_harness.dart';

void main() {
  final pubspec = RegExp(
    r'^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$',
    multiLine: true,
  ).firstMatch(File('pubspec.yaml').readAsStringSync())!;

  test('the build carries the pubspec version name and number', () {
    expect(appBuildName, pubspec.group(1));
    expect(appBuildNumber, pubspec.group(2));
  });

  test('appVersion is "name (number)" from the build', () {
    expect(appVersion, '${pubspec.group(1)} (${pubspec.group(2)})');
    expect(appVersion, isNot(contains('dev')));
  });

  testWidgets('Settings > About > Version shows the build version', (
    tester,
  ) async {
    phoneView(tester, size: const Size(360, 1600));
    final w = await TestWorld.demo();
    await pumpApp(tester, w);
    w.go(Routes.settings);
    await settle(tester);
    await tester.scrollUntilVisible(find.text(S.version), 200);
    final row = find.ancestor(
      of: find.text(S.version),
      matching: find.byType(KitListRow),
    );
    expect(
      find.descendant(of: row, matching: find.text(appVersion)),
      findsOneWidget,
    );
  });
}
