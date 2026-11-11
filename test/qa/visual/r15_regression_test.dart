// QA VISUAL round 15: reverification of the VISUAL-R14-01 fix (the date
// picker's year list keeps where the user scrolled it when its scroll
// position is replaced) over the whole class, and a regression sweep
// around the changed placement state: the charter phones (320x568,
// 360x640) and a large phone, portrait and landscape, at the text sizes
// that flip the dialog layout, a change landing mid-fling, a list scrolled
// to either end, the year list closed without picking and reopened (it
// must open on the selected year again, VISUAL-R13-01), and the three
// editors that open the picker.
//
// Tests named "QA VISUAL-R15-NN" with `skip:` are failing repros for open
// findings; unskip to verify a fix. The other tests pass and guard the
// fixes.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/format/app_material_localizations.dart';
import 'package:settle_up/ui/screens/common.dart';

import 'visual_harness.dart';

final DateTime _now = DateTime(2026, 11, 10);

Finder get _dialog => find.byType(DatePickerDialog);

Finder _inDialog(Finder f) => find.descendant(of: _dialog, matching: f);

Finder get _yearList => find.descendant(
  of: find.byType(YearPicker),
  matching: find.byType(Scrollable),
);

Finder get _calendar => _inDialog(find.byType(CalendarDatePicker));

ScrollPosition _position(WidgetTester t) =>
    t.state<ScrollableState>(_yearList.first).position;

/// Opens the editors' date picker on [initial] in a bare app with the real
/// themes, at [size] and [scale], with the app theme mode in [mode].
Future<void> _open(
  WidgetTester t,
  Size size,
  double scale,
  ValueNotifier<ThemeMode> mode,
  DateTime initial,
) async {
  t.view.reset();
  t.platformDispatcher.clearAllTestValues();
  t.view.physicalSize = size * 3;
  t.view.devicePixelRatio = 3;
  t.platformDispatcher.textScaleFactorTestValue = scale;
  await t.pumpWidget(const SizedBox.shrink());
  late BuildContext ctx;
  await t.pumpWidget(
    ValueListenableBuilder<ThemeMode>(
      valueListenable: mode,
      builder: (_, m, _) => MaterialApp(
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: m,
        localizationsDelegates: const [AppMaterialLocalizations.delegate],
        home: Builder(
          builder: (c) {
            ctx = c;
            return const Scaffold();
          },
        ),
      ),
    ),
  );
  pickEntryDate(ctx, initial: initial, now: _now).ignore();
  await t.pumpAndSettle();
}

/// Taps the month/year row to toggle the year list.
Future<bool> _toggleYears(WidgetTester t, int year) async {
  if (_calendar.evaluate().isEmpty) return false;
  final header = find.descendant(
    of: _calendar,
    matching: find.textContaining(RegExp('^[A-Z][a-z]+ $year\$')),
  );
  if (header.evaluate().isEmpty) return false;
  await t.tap(header.first);
  await t.pumpAndSettle();
  return true;
}

/// Whether [year]'s tile is fully inside the year list.
String? _yearVisible(WidgetTester t, int year) {
  final view = t.getRect(_yearList.first);
  final text = find.descendant(
    of: find.byType(YearPicker),
    matching: find.text('$year'),
  );
  if (text.evaluate().isEmpty) return 'year $year not built';
  final r = t.getRect(text.first);
  if (r.top < view.top - 0.01 || r.bottom > view.bottom + 0.01) {
    return 'year $year at ${r.top.toStringAsFixed(1)}, list '
        '${view.top.toStringAsFixed(1)}-${view.bottom.toStringAsFixed(1)}';
  }
  return null;
}

void main() {
  configureVisualTests();

  testWidgets('VISUAL-R14-01 class: the scroll is kept across rotation, '
      'theme and text size changes on the charter phones, at the text sizes '
      'that flip the dialog layout, mid-fling and at both ends of the list', (
    tester,
  ) async {
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    addTearDown(tester.view.reset);
    final mode = ValueNotifier(ThemeMode.light);
    addTearDown(mode.dispose);
    final problems = <String>[];
    var checked = 0;
    final changes = <String, void Function()>{
      'rotate': () =>
          tester.view.physicalSize = tester.view.physicalSize.flipped,
      'dark': () => mode.value = mode.value == ThemeMode.dark
          ? ThemeMode.light
          : ThemeMode.dark,
      'text +0.35': () => tester.platformDispatcher.textScaleFactorTestValue =
          tester.platformDispatcher.textScaleFactor + 0.35,
      'text -0.35': () => tester.platformDispatcher.textScaleFactorTestValue =
          math.max(1.0, tester.platformDispatcher.textScaleFactor - 0.35),
      'split screen': () => tester.view.physicalSize = Size(
        tester.view.physicalSize.width,
        tester.view.physicalSize.height * 0.55,
      ),
    };
    for (final size in const [
      Size(320, 568),
      Size(360, 640),
      Size(411, 891),
      Size(640, 360),
    ]) {
      for (final scale in const [1.0, 1.3, 1.65, 2.0]) {
        for (final scroll in const ['drag', 'fling', 'top', 'bottom']) {
          for (final name in changes.keys) {
            final where = '$size @${scale}x $scroll then $name';
            mode.value = ThemeMode.light;
            await _open(tester, size, scale, mode, DateTime(2026, 11, 9));
            if (!await _toggleYears(tester, 2026)) continue;
            final p = _position(tester);
            if (p.maxScrollExtent <= 0) {
              await tester.pumpWidget(const SizedBox.shrink());
              continue;
            }
            switch (scroll) {
              case 'drag':
                await tester.drag(_yearList.first, const Offset(0, 80));
                await tester.pumpAndSettle();
              case 'fling':
                await tester.fling(_yearList.first, const Offset(0, 120), 900);
                await tester.pump(const Duration(milliseconds: 50));
              case 'top':
                p.jumpTo(0);
                await tester.pumpAndSettle();
              case 'bottom':
                p.jumpTo(p.maxScrollExtent);
                await tester.pumpAndSettle();
            }
            final before = _position(tester).pixels;
            final beforeMax = _position(tester).maxScrollExtent;
            changes[name]!();
            if (scroll == 'fling') {
              // The change lands mid-fling: compare where the fling ends
              // with the change against where the stock list would be,
              // which is never back on the selected year.
              await tester.pump();
              final after = _position(tester).pixels;
              if (after < before - 1) {
                problems.add(
                  '$where: mid-fling list jumped from $before to $after',
                );
              }
              await tester.pumpAndSettle();
            } else {
              await tester.pumpAndSettle();
            }
            if (find.byType(YearPicker).evaluate().isEmpty) {
              problems.add('$where: year list closed');
              await tester.pumpWidget(const SizedBox.shrink());
              continue;
            }
            checked++;
            final after = _position(tester);
            if (scroll != 'fling') {
              // The stock list keeps the pixels, clamped to the new extent
              // (a list at its end stays at its end only if it was there
              // on the new extent too).
              final expected = scroll == 'bottom' && beforeMax > 0
                  ? math.min(before, after.maxScrollExtent)
                  : before.clamp(after.minScrollExtent, after.maxScrollExtent);
              if ((after.pixels - expected).abs() > 0.5) {
                problems.add(
                  '$where: list at ${after.pixels.toStringAsFixed(1)}, user '
                  'had it at ${before.toStringAsFixed(1)}',
                );
              }
            }
            if (after.pixels < after.minScrollExtent - 0.01 ||
                after.pixels > after.maxScrollExtent + 0.01) {
              problems.add('$where: list outside its extent');
            }
            await tester.pumpWidget(const SizedBox.shrink());
          }
        }
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
    // Some phone and text size pairs open in input mode, or with a list
    // that does not scroll; the rest must be swept.
    expect(checked, greaterThan(140), reason: 'sweep did not run');
  });

  testWidgets('VISUAL-R13-01 regression: a year list scrolled away and '
      'closed without picking reopens on the selected year, also after a '
      'rotation or theme change in between', (tester) async {
    addTearDown(tester.platformDispatcher.clearAllTestValues);
    addTearDown(tester.view.reset);
    final mode = ValueNotifier(ThemeMode.light);
    addTearDown(mode.dispose);
    final problems = <String>[];
    var checked = 0;
    for (final size in const [Size(320, 568), Size(360, 640), Size(411, 891)]) {
      for (final scale in const [1.0, 1.3, 2.0]) {
        for (final between in const [
          'nothing',
          'rotate while open',
          'rotate while closed',
          'dark while open',
        ]) {
          final where = '$size @${scale}x $between';
          mode.value = ThemeMode.light;
          await _open(tester, size, scale, mode, DateTime(2026, 11, 9));
          if (!await _toggleYears(tester, 2026)) continue;
          // Scroll the selected year well out of view.
          _position(tester).jumpTo(0);
          await tester.pumpAndSettle();
          if (between == 'rotate while open') {
            tester.view.physicalSize = tester.view.physicalSize.flipped;
            await tester.pumpAndSettle();
          } else if (between == 'dark while open') {
            mode.value = ThemeMode.dark;
            await tester.pumpAndSettle();
          }
          // Close the year list without picking.
          if (!await _toggleYears(tester, 2026)) {
            problems.add('$where: could not close the year list');
            await tester.pumpWidget(const SizedBox.shrink());
            continue;
          }
          if (find.byType(YearPicker).evaluate().isNotEmpty) {
            problems.add('$where: year list did not close');
          }
          if (between == 'rotate while closed') {
            tester.view.physicalSize = tester.view.physicalSize.flipped;
            await tester.pumpAndSettle();
          }
          if (!await _toggleYears(tester, 2026)) {
            problems.add('$where: could not reopen the year list');
            await tester.pumpWidget(const SizedBox.shrink());
            continue;
          }
          checked++;
          final v = _yearVisible(tester, 2026);
          if (v != null) problems.add('$where reopened: $v');
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
    expect(checked, greaterThan(20), reason: 'sweep did not run');
  });
}
