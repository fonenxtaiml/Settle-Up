// QA UIFLOW: Settings on the real KvSettingsRepository: name, home
// currency, theme, vibration, phone name and CSV export (share sheet
// stubbed at the platform channel).
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/settings/settings_screen.dart';
import 'package:settle_up/ui/strings.dart';

import 'real_harness.dart';

const _share = MethodChannel('dev.fluttercommunity.plus/share');
const _paths = MethodChannel('plugins.flutter.io/path_provider');

/// Records share sheet calls and haptic calls.
final class Platform$ {
  final List<Map<Object?, Object?>> shares = [];
  final List<String> haptics = [];
  late final Directory tmp = Directory.systemTemp.createTempSync('qa_share');

  void install(WidgetTester tester) {
    final m = tester.binding.defaultBinaryMessenger;
    m.setMockMethodCallHandler(_share, (call) async {
      shares.add(call.arguments as Map<Object?, Object?>);
      return 'dev.fluttercommunity.plus/share/success';
    });
    m.setMockMethodCallHandler(_paths, (call) async => tmp.path);
    m.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'HapticFeedback.vibrate') {
        haptics.add('${call.arguments}');
      }
      return null;
    });
    addTearDown(() {
      m.setMockMethodCallHandler(_share, null);
      m.setMockMethodCallHandler(_paths, null);
      m.setMockMethodCallHandler(SystemChannels.platform, null);
      tmp.deleteSync(recursive: true);
    });
  }
}

Future<void> promptAndSave(WidgetTester tester, String value) async {
  await tester.enterText(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    ),
    value,
  );
  await tester.pump();
  await qaTap(
    tester,
    find.descendant(of: find.byType(AlertDialog), matching: find.text(S.save)),
  );
}

Future<void> pickInSheet(WidgetTester tester, String label) => qaTap(
  tester,
  find.descendant(of: find.byType(BottomSheet), matching: find.text(label)),
);

/// Waits for real file I/O started by the export.
Future<void> letIoFinish(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

void main() {
  testWidgets('Home avatar opens Settings; name and home currency persist '
      'through the real repository', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    await qaTap(tester, find.byTooltip(S.yourProfile));
    expect(w.location, Routes.settings);
    expect(find.text(S.thisPhoneLine('Pixel 8')), findsOneWidget);

    await qaTap(tester, find.text('Arjun'));
    await promptAndSave(tester, '  Arjun Mehta ');
    expect(w.settings.profile!.displayName, 'Arjun Mehta');
    expect(find.text('Arjun Mehta'), findsOneWidget);

    await qaTap(tester, find.text(S.homeCurrency));
    await tester.enterText(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(TextField),
      ),
      'USD',
    );
    await qaSettle(tester);
    await qaTap(tester, find.widgetWithText(ListTile, 'USD').first);
    expect(w.settings.profile!.homeCurrency, 'USD');
    expect(find.text('\$ USD'), findsOneWidget);

    // Whitespace-only name: Save stays disabled, nothing changes.
    await qaTap(tester, find.text('Arjun Mehta'));
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      '   ',
    );
    await tester.pump();
    final save = tester.widget<FilledButton>(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(FilledButton),
      ),
    );
    expect(save.onPressed, isNull);
    await qaTap(tester, find.text(S.cancel));
    expect(w.settings.profile!.displayName, 'Arjun Mehta');
    await w.shutdown(tester);
  });

  testWidgets('theme: Dark and Light switch the app theme mode', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.settings);
    ThemeMode mode() =>
        tester.widget<MaterialApp>(find.byType(MaterialApp)).themeMode!;
    expect(mode(), ThemeMode.system);
    await qaTap(tester, find.text(S.theme));
    await pickInSheet(tester, S.themeDark);
    expect(w.settings.settings.themeMode, AppThemeMode.dark);
    expect(mode(), ThemeMode.dark);
    expect(Theme.of(tester.element(find.text(S.theme))).brightness,
        Brightness.dark);
    await qaTap(tester, find.text(S.theme));
    await pickInSheet(tester, S.themeLight);
    expect(mode(), ThemeMode.light);
    await w.shutdown(tester);
  });

  testWidgets('vibration off silences haptics app-wide', (tester) async {
    qaPhone(tester);
    final p = Platform$()..install(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await w.seedGroup();
    await pumpReal(tester, w, location: Routes.activity);
    await qaTap(tester, find.widgetWithText(ChoiceChip, S.filterExpenses));
    expect(p.haptics, isNotEmpty);

    w.push(Routes.settings);
    await qaSettle(tester);
    await qaTap(tester, find.text(S.vibration));
    expect(w.settings.settings.vibration, isFalse);
    await qaTap(tester, find.byTooltip(S.back));
    p.haptics.clear();
    await qaTap(tester, find.widgetWithText(ChoiceChip, S.filterAll));
    expect(p.haptics, isEmpty);
    await w.shutdown(tester);
  });

  testWidgets('phone name: renamed through the real repository and shown', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text(S.phoneName));
    await promptAndSave(tester, "Arjun's Pixel");
    expect(w.settings.device.deviceName, "Arjun's Pixel");
    expect(w.ledger.localDeviceName, "Arjun's Pixel");
    expect(find.text(S.thisPhoneLine("Arjun's Pixel")), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('CSV export: no groups shows the copy', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text(S.exportGroupCsv));
    expect(snackText(tester), S.noGroupsToExport);
    await w.shutdown(tester);
  });

  testWidgets('CSV export: the share sheet gets one .csv named after the '
      'group', (tester) async {
    qaPhone(tester);
    final p = Platform$()..install(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await w.seedGroup();
    await pumpReal(tester, w);
    await qaTap(tester, find.byTooltip(S.yourProfile));
    await qaTap(tester, find.text(S.exportGroupCsv));
    expect(find.text(S.exportPick), findsOneWidget);
    await pickInSheet(tester, 'Goa trip');
    await letIoFinish(tester);
    expect(p.shares, hasLength(1));
    final paths = (p.shares.single['paths']! as List).cast<String>();
    expect(paths.single, endsWith('.csv'));
    expect(p.shares.single['mimeTypes'], ['text/csv']);
    expect(p.shares.single['subject'], S.csvSubject('Goa trip'));
    final csv = await tester.runAsync(() => File(paths.single).readAsString());
    expect(csv, isNotEmpty);
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-13: Settings CSV export reads a stale ledger: a '
      'group that arrives while Settings is open is "not there"', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    await qaTap(tester, find.byTooltip(S.yourProfile));
    // A group arrives (for example by a sync running in the background)
    // while Settings covers Home.
    await w.seedGroup();
    await qaSettle(tester);
    await qaTap(tester, find.text(S.exportGroupCsv));
    expect(snackText(tester), isNot(S.noGroupsToExport));
    expect(find.text(S.exportPick), findsOneWidget);
    await w.shutdown(tester);
  }, skip: true); // QA UIFLOW-R1-13

  testWidgets('UIFLOW-R1-09: the exported CSV is not named after the group '
      '(share_plus ignores XFile.fromData name; a random id is used)', (
    tester,
  ) async {
    qaPhone(tester);
    final p = Platform$()..install(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await w.seedGroup();
    await pumpReal(tester, w);
    await qaTap(tester, find.byTooltip(S.yourProfile));
    await qaTap(tester, find.text(S.exportGroupCsv));
    await pickInSheet(tester, 'Goa trip');
    await letIoFinish(tester);
    final path = (p.shares.single['paths']! as List).cast<String>().single;
    expect(path.split('/').last, 'Goa trip.csv');
    await w.shutdown(tester);
  }, skip: true); // QA UIFLOW-R1-09

  testWidgets('UIFLOW-R1-10: CSV export failure (share sheet error) is '
      'unhandled: no copy is shown', (tester) async {
    qaPhone(tester);
    final m = tester.binding.defaultBinaryMessenger;
    final tmp = Directory.systemTemp.createTempSync('qa_share_fail');
    m.setMockMethodCallHandler(_paths, (call) async => tmp.path);
    m.setMockMethodCallHandler(_share, (call) async {
      throw PlatformException(code: 'error', message: 'No activity found');
    });
    addTearDown(() {
      m.setMockMethodCallHandler(_share, null);
      m.setMockMethodCallHandler(_paths, null);
      tmp.deleteSync(recursive: true);
    });
    final w = await RealWorld.create(name: 'Arjun');
    await w.seedGroup();
    await pumpReal(tester, w);
    await qaTap(tester, find.byTooltip(S.yourProfile));
    await qaTap(tester, find.text(S.exportGroupCsv));
    await pickInSheet(tester, 'Goa trip');
    await letIoFinish(tester);
    // Expected: the error is caught and mapped to copy (errGeneric).
    expect(tester.takeException(), isNull);
    expect(snackText(tester), S.errGeneric);
    await w.shutdown(tester);
  }, skip: true); // QA UIFLOW-R1-10

  testWidgets('UIFLOW-R1-11: Settings rename accepts a name over 40 '
      'characters (onboarding caps it at 40)', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text('Arjun'));
    await promptAndSave(tester, 'N' * 80);
    expect(w.settings.profile!.displayName.length, lessThanOrEqualTo(40));
    await w.shutdown(tester);
  }, skip: true); // QA UIFLOW-R1-11

  testWidgets('UIFLOW-R1-11b: phone name accepts any length (SPEC 8.9: the '
      'mDNS service name is the device name, at most 40 characters)', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text(S.phoneName));
    await promptAndSave(tester, 'P' * 90);
    expect(w.settings.device.deviceName.length, lessThanOrEqualTo(40));
    await w.shutdown(tester);
  }, skip: true); // QA UIFLOW-R1-11

  test('UIFLOW-R1-12: Settings shows version "1.0.0 (1)" while pubspec '
      'builds 0.1.0+1', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final v = RegExp(r'^version:\s*(\S+)', multiLine: true)
        .firstMatch(pubspec)!
        .group(1)!;
    final parts = v.split('+');
    expect(appVersion, '${parts[0]} (${parts[1]})');
  }, skip: 'QA UIFLOW-R1-12: About version is hard-coded');
}
