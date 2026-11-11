// VISUAL-R13-01 regression: the editors' date picker opens its year list on
// the selected year at every text size, phone shape and date, from the
// first frame, without springing back, and keeps where the user scrolls.
//
// The stock YearPicker placed its list from three columns of 52 dp rows
// while its grid lays rows out taller with the text and in two columns past
// 1.65x. The picker now places the list from the grid's real layout
// (yearListOffset), so the sweep covers the text sizes either side of every
// stock threshold, a seeded random set of sizes and years, the ends of the
// range and short ranges padded with disabled years.
import 'dart:math' as math;
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/format/app_material_localizations.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/widgets/entry_date_picker.dart';

final DateTime _now = DateTime(2026, 11, 10);

Finder get _dialog => find.byType(DatePickerDialog);

Finder get _yearList => find.descendant(
  of: find.byType(YearPicker),
  matching: find.byType(Scrollable),
);

/// Opens the picker in a bare app with the real theme at [scale]. With
/// [first] and [last] it opens [showEntryDatePicker] on that range,
/// otherwise [pickEntryDate] as the editors do.
Future<void> _open(
  WidgetTester t, {
  required Size size,
  required double scale,
  required DateTime initial,
  DateTime? first,
  DateTime? last,
  Brightness brightness = Brightness.light,
}) async {
  t.view.physicalSize = size * 3;
  t.view.devicePixelRatio = 3;
  t.platformDispatcher.textScaleFactorTestValue = scale;
  await t.pumpWidget(const SizedBox.shrink());
  late BuildContext ctx;
  await t.pumpWidget(
    MaterialApp(
      theme: brightness == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark(),
      localizationsDelegates: const [AppMaterialLocalizations.delegate],
      home: Builder(
        builder: (c) {
          ctx = c;
          return const Scaffold();
        },
      ),
    ),
  );
  final Future<DateTime?> pending = first == null
      ? pickEntryDate(ctx, initial: initial, now: _now)
      : showEntryDatePicker(
          ctx,
          initialDate: initial,
          firstDate: first,
          lastDate: last!,
        );
  pending.ignore();
  await t.pumpAndSettle();
}

/// Taps the calendar's month and year row; false in input mode.
Future<bool> _openYears(WidgetTester t, int year) async {
  final calendar = find.descendant(
    of: _dialog,
    matching: find.byType(CalendarDatePicker),
  );
  if (calendar.evaluate().isEmpty) return false;
  await t.tap(
    find.descendant(of: calendar, matching: find.textContaining('$year')).first,
  );
  // Only one frame: the year must be in place on the first one.
  await t.pump();
  return true;
}

ScrollPosition _position(WidgetTester t) =>
    t.state<ScrollableState>(_yearList.first).position;

/// What is wrong with the year list as it is laid out now.
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
  tearDown(() {
    final b = TestWidgetsFlutterBinding.instance;
    b.platformDispatcher.clearTextScaleFactorTestValue();
    b.platformDispatcher.views.first.reset();
  });

  // The text sizes either side of the stock thresholds (1.0, 1.3, 1.65)
  // and up to and past the stock 3.0x clamp.
  const scales = [1.0, 1.1, 1.3, 1.31, 1.5, 1.65, 1.66, 1.75, 2.0, 2.5, 3.0];
  const sizes = [
    Size(360, 640),
    Size(393, 851),
    Size(411, 891),
    Size(480, 800),
    Size(800, 600),
    Size(1280, 800),
  ];

  testWidgets('the year list opens on the selected year on its first frame '
      'at every text size, phone and date', (tester) async {
    final handle = tester.ensureSemantics();
    final random = math.Random(1301);
    final years = <int>{
      2000,
      2001,
      2026,
      2027,
      2090,
      9999,
      10000,
      for (var i = 0; i < 2; i++) 2000 + random.nextInt(8001),
    };
    final shapes = <(Size, double)>[
      for (final s in sizes)
        for (final x in scales) (s, x),
      for (var i = 0; i < 8; i++)
        (sizes[random.nextInt(sizes.length)], 1 + 2 * random.nextDouble()),
    ];
    final problems = <String>[];
    var checked = 0;
    for (final (size, scale) in shapes) {
      for (final year in years) {
        final d = DateTime(year, 1 + (year % 12), 1 + (year % 28));
        await _open(tester, size: size, scale: scale, initial: d);
        if (!await _openYears(tester, year)) continue;
        checked++;
        final where =
            '${size.width.toInt()}x${size.height.toInt()} '
            '@${scale.toStringAsFixed(2)}x $year';
        final first = _problem(tester, year);
        if (first != null) problems.add('$where (first frame): $first');
        final before = _position(tester).pixels;
        await tester.pumpAndSettle();
        final moved = _position(tester).pixels - before;
        if (moved.abs() > 0.01) {
          problems.add('$where: list moved by $moved after opening');
        }
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    handle.dispose();
    expect(checked, greaterThan(300), reason: 'calendar mode was not swept');
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('at 1.0x the list opens where the stock picker places it', (
    tester,
  ) async {
    for (final year in [2003, 2010, 2026]) {
      await _open(
        tester,
        size: const Size(411, 891),
        scale: 1.0,
        initial: DateTime(year, 6, 1),
      );
      expect(await _openYears(tester, year), isTrue);
      await tester.pumpAndSettle();
      final p = _position(tester);
      // The stock offset: the selected row two 52 dp rows below the top.
      final stock = ((year - 2000) ~/ 3 - 2) * 52.0;
      expect(
        p.pixels,
        moreOrLessEquals(stock.clamp(0, p.maxScrollExtent).toDouble()),
        reason: '$year',
      );
    }
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('a short range padded with disabled years opens on the year', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final problems = <String>[];
    for (final scale in [1.0, 1.3, 2.0, 3.0]) {
      for (final (first, last) in [(2020, 2025), (2020, 2020), (2010, 2026)]) {
        for (final year in {first, (first + last) ~/ 2, last}) {
          await _open(
            tester,
            size: const Size(411, 891),
            scale: scale,
            initial: DateTime(year, 3, 3),
            first: DateTime(first),
            last: DateTime(last, 12, 31),
          );
          if (!await _openYears(tester, year)) continue;
          final p = _problem(tester, year);
          if (p != null) problems.add('@${scale}x $first-$last: $p');
        }
      }
    }
    await tester.pumpWidget(const SizedBox.shrink());
    handle.dispose();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('where the user scrolls is kept across a relayout, and a year '
      'picked from the list is where the list opens next', (tester) async {
    await _open(
      tester,
      size: const Size(411, 891),
      scale: 2.0,
      initial: DateTime(2026, 11, 9),
    );
    expect(await _openYears(tester, 2026), isTrue);
    await tester.pumpAndSettle();
    await tester.drag(_yearList.first, const Offset(0, 150));
    await tester.pumpAndSettle();
    final scrolled = _position(tester).pixels;
    // A slightly larger text size relays the list out; it stays put.
    tester.platformDispatcher.textScaleFactorTestValue = 2.05;
    await tester.pumpAndSettle();
    expect(_position(tester).pixels, moreOrLessEquals(scrolled));

    // Pick a year that is on screen, then reopen the list.
    final shown = find.descendant(
      of: find.byType(YearPicker),
      matching: find.text('2018'),
    );
    expect(shown, findsOneWidget);
    await tester.tap(shown);
    await tester.pumpAndSettle();
    expect(find.byType(YearPicker), findsNothing);
    final handle = tester.ensureSemantics();
    expect(await _openYears(tester, 2018), isTrue);
    expect(_problem(tester, 2018), isNull);
    handle.dispose();
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('the other scrollables in the dialog keep the app behavior', (
    tester,
  ) async {
    await _open(
      tester,
      size: const Size(411, 891),
      scale: 1.0,
      initial: DateTime(2026, 11, 9),
    );
    final behavior = ScrollConfiguration.of(
      tester.element(find.byType(CalendarDatePicker)),
    );
    expect(behavior, isA<YearListScrollBehavior>());
    final parent = (behavior as YearListScrollBehavior).parent;
    final ctx = tester.element(find.byType(CalendarDatePicker));
    expect(
      behavior.getScrollPhysics(ctx).runtimeType,
      parent.getScrollPhysics(ctx).runtimeType,
    );
    expect(behavior.dragDevices, parent.dragDevices);
    expect(behavior.getPlatform(ctx), parent.getPlatform(ctx));
    // The month pager swipes as before.
    expect(find.text('November 2026'), findsWidgets);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  group('yearListOffset', () {
    SliverGridLayout grid(int columns, double row) =>
        SliverGridRegularTileLayout(
          crossAxisCount: columns,
          mainAxisStride: row,
          crossAxisStride: 100,
          childMainAxisExtent: row,
          childCrossAxisExtent: 92,
          reverseCrossAxis: false,
        );

    test('property: always inside the list, the tile visible, two rows '
        'above it where there is room', () {
      final random = math.Random(1302);
      final problems = <String>[];
      for (var i = 0; i < 20000; i++) {
        final columns = 1 + random.nextInt(4);
        final row = 30 + random.nextDouble() * 90;
        final count = 1 + random.nextInt(i.isEven ? 30 : 10000);
        final index = random.nextInt(count);
        final viewport = row + random.nextDouble() * 900;
        final before = random.nextBool() ? 0.0 : random.nextDouble() * 20;
        final after = random.nextBool() ? 0.0 : random.nextDouble() * 20;
        final g = grid(columns, row);
        final o = yearListOffset(
          grid: g,
          index: index,
          childCount: count,
          viewport: viewport,
          paddingBefore: before,
          paddingAfter: after,
        );
        final content = before + (count / columns).ceil() * row + after;
        final max = math.max(0.0, content - viewport);
        final top = before + (index ~/ columns) * row;
        final where =
            'cols $columns row $row count $count index $index '
            'viewport $viewport';
        if (o < -1e-9 || o > max + 1e-9) problems.add('$where: $o of $max');
        if (top < o - 1e-6 || top + row > o + viewport + 1e-6) {
          problems.add('$where: tile at $top, view $o');
        }
        if (viewport >= 5 * row && top - 2 * row >= 0 && top - 2 * row <= max) {
          if ((top - o - 2 * row).abs() > 1e-6) {
            problems.add('$where: not two rows below the top');
          }
        }
        if (problems.length > 20) break;
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });

    test('an empty list stays at the top', () {
      expect(
        yearListOffset(
          grid: grid(3, 52),
          index: 4,
          childCount: 0,
          viewport: 300,
        ),
        0,
      );
    });
  });

  test('yearPickerIndex follows the stock tiles, short ranges padded', () {
    YearPicker picker(int first, int last, int? selected) => YearPicker(
      firstDate: DateTime(first),
      lastDate: DateTime(last, 12, 31),
      selectedDate: selected == null ? null : DateTime(selected),
      onChanged: (_) {},
    );
    expect(yearPickerIndex(picker(2000, 2027, 2026)), 26);
    expect(yearPickerIndex(picker(2000, 10000, 10000)), 8000);
    expect(yearPickerIndex(picker(2000, 2027, null)), 0);
    // Six years padded to 18 tiles: six disabled years before them.
    expect(yearPickerIndex(picker(2020, 2025, 2022)), 8);
    expect(yearPickerIndex(picker(2020, 2020, 2020)), 8);
  });
}
