// QA VISUAL round 14: reverification of the VISUAL-R13-01 fix (the date
// picker's year list opens on the selected year at every text size) over
// the whole class, and a regression sweep around the changed scroll
// behavior: the charter phones (320x568, 360x640) and phone landscape in
// both themes, the text sizes either side of the stock 1.3x and 1.65x
// thresholds, the ends of the range, the year shown after paging months,
// a year picked and the list reopened, the user's scroll kept across a
// theme and text size change, contrast and tap targets in the year list,
// and the editors end to end.
//
// Tests named "QA VISUAL-R14-NN" with `skip:` are failing repros for open
// findings; unskip to verify a fix. The other tests pass and guard the
// fixes.
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/rendering.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/format/app_material_localizations.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/widgets/entry_date_picker.dart';

import 'visual_harness.dart';

final DateTime _now = DateTime(2026, 11, 10);

Finder get _dialog => find.byType(DatePickerDialog);

Finder _inDialog(Finder f) => find.descendant(of: _dialog, matching: f);

Finder get _yearList => find.descendant(
  of: find.byType(YearPicker),
  matching: find.byType(Scrollable),
);

Finder get _calendar => _inDialog(find.byType(CalendarDatePicker));

/// Opens [pickEntryDate] on [initial] in a bare app with the real theme,
/// the app's Material strings and the text at [scale], in [theme] (which
/// the test can flip while the picker is open).
Future<void> _bare(
  WidgetTester t,
  Size size,
  double scale,
  ValueNotifier<Brightness> theme,
  DateTime initial,
) async {
  t.view.physicalSize = size * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
  t.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  await t.pumpWidget(const SizedBox.shrink());
  late BuildContext ctx;
  await t.pumpWidget(
    ValueListenableBuilder<Brightness>(
      valueListenable: theme,
      builder: (_, b, _) => MaterialApp(
        theme: b == Brightness.light ? AppTheme.light() : AppTheme.dark(),
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

/// Taps the calendar's month and year row for [year]; false in input mode.
Future<bool> _openYears(WidgetTester t, int year) async {
  if (_calendar.evaluate().isEmpty) return false;
  await t.tap(
    find
        .descendant(of: _calendar, matching: find.textContaining('$year'))
        .first,
  );
  await t.pump();
  return true;
}

ScrollPosition _position(WidgetTester t) =>
    t.state<ScrollableState>(_yearList.first).position;

/// What is wrong with the year list as it is laid out now, or null.
String? _problem(WidgetTester t, int year) {
  final view = t.getRect(_yearList.first);
  final text = find.descendant(
    of: find.byType(YearPicker),
    matching: find.text('$year'),
  );
  if (text.evaluate().isEmpty) return 'year $year not built';
  final r = t.getRect(text.first);
  if (r.top < view.top - 0.01 || r.bottom > view.bottom + 0.01) {
    return 'year $year at ${r.top.toStringAsFixed(1)}-'
        '${r.bottom.toStringAsFixed(1)}, list '
        '${view.top.toStringAsFixed(1)}-${view.bottom.toStringAsFixed(1)}';
  }
  final p = _position(t);
  if (p.pixels < p.minScrollExtent - 0.01 ||
      p.pixels > p.maxScrollExtent + 0.01) {
    return 'list outside its extent (${p.pixels} of ${p.maxScrollExtent})';
  }
  final selected = t
      .getSemantics(text.first)
      .getSemanticsData()
      .flagsCollection
      .isSelected;
  if (selected != Tristate.isTrue) return 'year $year not marked selected';
  return null;
}

void main() {
  configureVisualTests();

  // ------------------------------------------------------------------
  // VISUAL-R13-01 class: the charter phones, phone landscape, both
  // themes, every text size either side of the thresholds, the ends of
  // the range (pass).
  // ------------------------------------------------------------------

  testWidgets('VISUAL-R13-01 class: the year list opens on the selected '
      'year on its first frame on the charter phones and in landscape, in '
      'both themes, with no layout errors and no spring back', (tester) async {
    final handle = tester.ensureSemantics();
    final problems = <String>[];
    var checked = 0;
    const sizes = [
      Size(320, 568),
      Size(360, 640),
      Size(411, 891),
      Size(568, 320),
      Size(640, 360),
      Size(891, 411),
    ];
    const scales = [1.0, 1.2, 1.3, 1.45, 1.65, 1.66, 1.8, 2.0, 2.4, 3.0, 3.2];
    // 2000 is the first year, 2027 the last for today's clock; 10000 is
    // the widened end for a far peer date seen east of UTC.
    const years = [2000, 2002, 2013, 2026, 2027, 2090, 7777, 9999, 10000];
    for (final size in sizes) {
      for (final scale in scales) {
        for (final b in Brightness.values) {
          // Both themes at the charter sizes; one elsewhere.
          if (b == Brightness.dark &&
              !(size == const Size(320, 568) || size == const Size(360, 640))) {
            continue;
          }
          for (final year in years) {
            final where =
                '${size.width.toInt()}x${size.height.toInt()} '
                '@${scale}x ${b.name} $year';
            final errors = await collectLayoutErrors(() async {
              await _bare(
                tester,
                size,
                scale,
                ValueNotifier(b),
                DateTime(year, 1 + year % 12, 1 + year % 28),
              );
              if (!await _openYears(tester, year)) return;
              checked++;
              final first = _problem(tester, year);
              if (first != null) problems.add('$where (first frame): $first');
              final before = _position(tester).pixels;
              await tester.pumpAndSettle();
              final moved = _position(tester).pixels - before;
              if (moved.abs() > 0.01) {
                problems.add('$where: list moved by $moved after opening');
              }
            });
            if (errors.isNotEmpty) {
              problems.add('$where: ${errors.toSet().join('; ')}');
            }
            await tester.pumpWidget(const SizedBox.shrink());
          }
        }
      }
    }
    handle.dispose();
    expect(checked, greaterThan(150), reason: 'calendar mode not swept');
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('VISUAL-R13-01 class: after paging months into another year '
      'the year list opens on the year shown, and on a picked year when '
      'reopened', (tester) async {
    final handle = tester.ensureSemantics();
    final problems = <String>[];
    for (final scale in const [1.0, 1.3, 2.0]) {
      final where = '411x891 @${scale}x';
      await _bare(
        tester,
        const Size(411, 891),
        scale,
        ValueNotifier(Brightness.light),
        DateTime(2026, 12, 20),
      );
      if (_calendar.evaluate().isEmpty) {
        problems.add('$where: no calendar');
        continue;
      }
      // Page forward into January 2027.
      await tester.tap(_inDialog(find.byTooltip('Next month')));
      await tester.pumpAndSettle();
      if (_inDialog(find.text('January 2027')).evaluate().isEmpty) {
        problems.add('$where: did not page to January 2027');
      }
      await _openYears(tester, 2027);
      final p = _problem(tester, 2027);
      if (p != null) problems.add('$where after paging: $p');
      await tester.pumpAndSettle();
      // Scroll to the top, pick 2001, reopen.
      _position(tester).jumpTo(0);
      await tester.pumpAndSettle();
      final y2001 = find.descendant(
        of: find.byType(YearPicker),
        matching: find.text('2001'),
      );
      await tester.tap(y2001);
      await tester.pumpAndSettle();
      await _openYears(tester, 2001);
      final q = _problem(tester, 2001);
      if (q != null) problems.add('$where reopened on 2001: $q');
      await tester.pumpWidget(const SizedBox.shrink());
    }
    handle.dispose();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('VISUAL-R13-01 sweep: the open year list passes contrast and '
      'tap target guidelines in both themes on the charter phones', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final problems = <String>[];
    for (final v in [
      ...kVariants,
      for (final b in Brightness.values)
        (size: const Size(411, 891), scale: 2.0, brightness: b),
    ]) {
      final where = variantName(v);
      await _bare(
        tester,
        v.size,
        v.scale,
        ValueNotifier(v.brightness),
        DateTime(2026, 11, 9),
      );
      if (!await _openYears(tester, 2026)) {
        await tester.pumpWidget(const SizedBox.shrink());
        continue;
      }
      await tester.pumpAndSettle();
      for (final g in [
        textContrastGuideline,
        androidTapTargetGuideline,
        labeledTapTargetGuideline,
      ]) {
        final r = await g.evaluate(tester);
        if (!r.passed) problems.add('$where ${g.description}: ${r.reason}');
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
    handle.dispose();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('VISUAL-R13-01 class: through the expense editor at 2.0x the '
      'year list opens on the expense year', (tester) async {
    late VisualWorld w;
    late String id;
    await tester.runAsync(() async {
      w = await VisualWorld.realistic();
      final gs = w.phone.gs(w.group);
      final me = gs.members.values.firstWhere((m) => m.personId == w.phone.me);
      id = await w.phone.ledger.addExpense(
        ExpenseDraft(
          groupId: w.group,
          description: 'Far future',
          total: 10000,
          currency: 'INR',
          paidBy: SplitSpec.single(me.id, 10000),
          owedBy: SplitSpec.equal(gs.members.keys.toList()),
          category: 'food.dining',
          date: DateTime(2090, 6, 1, 12),
        ),
      );
    });
    final handle = tester.ensureSemantics();
    final problems = <String>[];
    for (final v in [
      (size: const Size(411, 891), scale: 2.0, brightness: Brightness.dark),
      (size: const Size(411, 891), scale: 1.3, brightness: Brightness.light),
    ]) {
      await pumpVisual(tester, w.phone, v: v, location: Routes.editExpense(id));
      final date = find.semantics.byLabel(RegExp(r'^Date, '));
      for (var i = 0; i < 12 && date.evaluate().isEmpty; i++) {
        final s = find.byType(Scrollable).first;
        final pos = tester.state<ScrollableState>(s).position;
        pos.jumpTo((pos.pixels + 200).clamp(0, pos.maxScrollExtent));
        await tester.pump(const Duration(milliseconds: 200));
      }
      tester.semantics.tap(find.semantics.byLabel(RegExp(r'^Date, ')).first);
      await settleFrames(tester);
      if (!await _openYears(tester, 2090)) {
        problems.add('${variantName(v)}: picker not in calendar mode');
      } else {
        final p = _problem(tester, 2090);
        if (p != null) problems.add('${variantName(v)}: $p');
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
    handle.dispose();
    await tester.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('yearListOffset at the ends: first and last tiles stay inside the '
      'list for every stock grid shape', () {
    for (final cols in [2, 3]) {
      for (final row in [52.0, 54.7, 61.0, 70.0]) {
        final grid = SliverGridRegularTileLayout(
          crossAxisCount: cols,
          mainAxisStride: row,
          crossAxisStride: 100,
          childMainAxisExtent: row,
          childCrossAxisExtent: 96,
          reverseCrossAxis: false,
        );
        for (final count in [18, 28, 8001]) {
          for (final viewport in [100.0, 180.0, 300.0]) {
            for (final i in [0, count - 1]) {
              final o = yearListOffset(
                grid: grid,
                index: i,
                childCount: count,
                viewport: viewport,
              );
              final g = grid.getGeometryForChildIndex(i);
              expect(g.scrollOffset >= o - 0.01, isTrue);
              expect(
                g.scrollOffset + g.mainAxisExtent <= o + viewport + 0.01 ||
                    g.mainAxisExtent > viewport,
                isTrue,
                reason: '$cols x $row $count $viewport $i',
              );
            }
          }
        }
      }
    }
  });

  // ------------------------------------------------------------------
  // New findings.
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R14-01: rotating the phone or switching the theme while the '
    'year list is open throws away where the user scrolled and jumps back '
    'to the selected year',
    (tester) async {
      final problems = <String>[];
      // Rotation, through the expense editor as the user meets it.
      final w = (await tester.runAsync(VisualWorld.realistic))!;
      final handle = tester.ensureSemantics();
      for (final v in [
        (size: const Size(411, 891), scale: 1.0, brightness: Brightness.light),
        (size: const Size(411, 891), scale: 2.0, brightness: Brightness.dark),
        (size: const Size(360, 640), scale: 1.0, brightness: Brightness.light),
      ]) {
        final where = variantName(v);
        await pumpVisual(
          tester,
          w.phone,
          v: v,
          location: Routes.newExpense(groupId: w.group),
        );
        final date = find.semantics.byLabel(RegExp(r'^Date, '));
        for (var i = 0; i < 12 && date.evaluate().isEmpty; i++) {
          final pos = tester
              .state<ScrollableState>(find.byType(Scrollable).first)
              .position;
          pos.jumpTo((pos.pixels + 200).clamp(0, pos.maxScrollExtent));
          await tester.pump(const Duration(milliseconds: 200));
        }
        tester.semantics.tap(date.first);
        await settleFrames(tester);
        if (_calendar.evaluate().isEmpty) {
          problems.add('$where: picker not in calendar mode');
          await tester.pumpWidget(const SizedBox.shrink());
          continue;
        }
        await tester.tap(
          find
              .descendant(
                of: _calendar,
                matching: find.textContaining(RegExp(r'^[A-Z][a-z]+ \d{4}$')),
              )
              .first,
        );
        await settleFrames(tester);
        await tester.drag(_yearList.first, const Offset(0, 100));
        await settleFrames(tester);
        final scrolled = _position(tester).pixels;
        tester.view.physicalSize = Size(v.size.height, v.size.width) * 3;
        await settleFrames(tester);
        if (find.byType(YearPicker).evaluate().isEmpty) {
          problems.add('$where: year list closed on rotation');
        } else if ((_position(tester).pixels - scrolled).abs() > 0.5) {
          problems.add(
            '$where rotated: list at ${_position(tester).pixels}, '
            'user had scrolled it to $scrolled',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
      handle.dispose();
      await tester.runAsync(w.phone.dispose);

      // A theme change (dark mode switching on), and a larger text size,
      // while the list is open. The stock picker keeps the offset in both.
      tester.view.reset();
      for (final change in ['dark mode on', 'text 2.0x to 2.4x']) {
        final theme = ValueNotifier(Brightness.light);
        await _bare(
          tester,
          const Size(411, 891),
          2.0,
          theme,
          DateTime(2026, 11, 9),
        );
        await _openYears(tester, 2026);
        await tester.pumpAndSettle();
        await tester.drag(_yearList.first, const Offset(0, 100));
        await tester.pumpAndSettle();
        final scrolled = _position(tester).pixels;
        if (change == 'dark mode on') {
          theme.value = Brightness.dark;
        } else {
          tester.platformDispatcher.textScaleFactorTestValue = 2.4;
        }
        await tester.pumpAndSettle();
        if (find.byType(YearPicker).evaluate().isEmpty) {
          problems.add('411x891 @2.0x $change: year list closed');
        } else if ((_position(tester).pixels - scrolled).abs() > 0.5) {
          problems.add(
            '411x891 @2.0x $change: list at ${_position(tester).pixels}, '
            'user had scrolled it to $scrolled',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );
}
