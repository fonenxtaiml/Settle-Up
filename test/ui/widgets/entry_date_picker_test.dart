// VISUAL-R10-01 and VISUAL-R10-02 regression: the editors' date picker
// (pickEntryDate) on every phone shape and text size, not only the charter
// variants. On each one, opened from a real button:
//
// * nothing overflows, in calendar mode, input mode, the year list and an
//   input error;
// * every tappable node meets the 48 dp and labelled tap target
//   guidelines, the calendar's days included;
// * the chosen date in the header sits on one line, uncut, inside the
//   header;
// * the calendar is still offered wherever its days can be full size (a
//   360 dp portrait phone at 1.0x to 2.0x), so the fix is not "never show
//   the calendar";
// * a date picked returns that date.
//
// The sweep runs once in the test font (each glyph a 1 em square, wider
// than any real font) and once in Familjen Grotesk, over the listed phones
// and a seeded random set of shapes and text sizes.
import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/widgets/entry_date_picker.dart';

import 'kit_harness.dart' show loadRealFonts;

typedef Shape = ({Size size, double scale, Brightness brightness});

const List<Size> _phones = [
  Size(320, 568),
  Size(340, 600),
  Size(359, 640),
  Size(360, 560),
  Size(360, 640),
  Size(375, 667),
  Size(393, 851),
  Size(411, 915),
  Size(480, 800),
  // Landscape: phones, then a window or tablet with room for the
  // portrait calendar.
  Size(568, 320),
  Size(640, 360),
  Size(915, 411),
  Size(800, 600),
  Size(1280, 800),
];

const List<double> _scales = [1.0, 1.15, 1.3, 1.5, 1.75, 2.0];

List<Shape> _shapes() {
  final out = <Shape>[];
  var i = 0;
  for (final size in _phones) {
    for (final scale in _scales) {
      out.add((
        size: size,
        scale: scale,
        brightness: Brightness.values[i++ % 2],
      ));
    }
  }
  // Seeded random phones, portrait and landscape, 1.0x to 2.0x.
  final r = math.Random(20261110);
  for (var n = 0; n < 40; n++) {
    final w = 300 + r.nextInt(200).toDouble();
    final h = 480 + r.nextInt(500).toDouble();
    final size = r.nextInt(4) == 0 ? Size(h, w) : Size(w, h);
    final scale = 1 + (r.nextInt(21) / 20);
    out.add((size: size, scale: scale, brightness: Brightness.values[n % 2]));
  }
  return out;
}

String _name(Shape s) =>
    '${s.size.width.round()}x${s.size.height.round()} '
    '@${s.scale}x ${s.brightness.name}';

final DateTime _initial = DateTime(2026, 9, 23); // Wed, Sep 23
final DateTime _now = DateTime(2026, 11, 10);

/// Pumps a page whose button opens pickEntryDate, opens it, and returns
/// the future of the date it returns.
Future<Future<DateTime?>> _open(WidgetTester t, Shape s) async {
  t.view.physicalSize = s.size * 2;
  t.view.devicePixelRatio = 2;
  t.platformDispatcher.textScaleFactorTestValue = s.scale;
  late BuildContext ctx;
  await t.pumpWidget(
    MaterialApp(
      theme: s.brightness == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark(),
      home: Builder(
        builder: (c) {
          ctx = c;
          return const Scaffold();
        },
      ),
    ),
  );
  final f = pickEntryDate(ctx, initial: _initial, now: _now);
  await t.pumpAndSettle();
  return f;
}

Future<List<String>> _check(WidgetTester t, String where) async {
  final out = <String>[];
  for (final g in [androidTapTargetGuideline, labeledTapTargetGuideline]) {
    final r = await g.evaluate(t);
    if (r.passed) continue;
    for (final n in (r.reason ?? '').split('SemanticsNode#').skip(1)) {
      out.add('$where: ${n.split('\n').take(2).join(' ')}');
    }
  }
  final dialog = find.byType(DatePickerDialog);
  final help = find.descendant(of: dialog, matching: find.text('Select date'));
  if (help.evaluate().isEmpty) return out;
  final header = t.getRect(
    find.ancestor(of: help, matching: find.byType(Material)).first,
  );
  final screen = Offset.zero & (t.view.physicalSize / t.view.devicePixelRatio);
  final box = t.getRect(dialog);
  if (box.left < screen.left - 0.5 ||
      box.right > screen.right + 0.5 ||
      box.top < screen.top - 0.5 ||
      box.bottom > screen.bottom + 0.5) {
    out.add('$where: the dialog $box leaves the screen');
  }
  final titles = find.descendant(
    of: dialog,
    matching: find.byWidgetPredicate(
      (w) => w is Text && RegExp(r'^\w{3}, \w{3} \d{1,2}$').hasMatch(w.data!),
    ),
  );
  for (final e in titles.evaluate()) {
    final rich = find.descendant(
      of: find.byElementPredicate((x) => x == e),
      matching: find.byType(RichText),
    );
    final p = t.renderObject<RenderParagraph>(rich);
    final r = t.getRect(rich);
    final text = (e.widget as Text).data;
    if (p.didExceedMaxLines) out.add('$where: the title "$text" is cut');
    // Inside the header: below "Select date" and above the header's end.
    if (r.bottom > header.bottom + 0.5 || r.right > header.right + 0.5) {
      out.add('$where: the title "$text" $r leaves the header $header');
    }
    final lines = p.getBoxesForSelection(
      TextSelection(baseOffset: 0, extentOffset: text!.length),
    );
    final tops = lines.map((b) => b.top.round()).toSet();
    final portrait = screen.height > screen.width;
    if (portrait && tops.length > 1) {
      out.add('$where: the title "$text" wraps onto ${tops.length} lines');
    }
  }
  return out;
}

Future<List<String>> _layoutErrors(Future<void> Function() body) async {
  final errors = <String>[];
  final old = FlutterError.onError;
  FlutterError.onError = (d) =>
      errors.add(d.exceptionAsString().split('\n').first);
  try {
    await body();
  } finally {
    FlutterError.onError = old;
  }
  return errors;
}

/// Opens the picker on [s], checks every mode it offers and picks a date.
Future<List<String>> _sweep(WidgetTester t, Shape s) async {
  final where = _name(s);
  final out = <String>[];
  late Future<DateTime?> picked;
  out.addAll(
    (await _layoutErrors(() async {
      picked = await _open(t, s);
    })).map((e) => '$where open: $e'),
  );
  out.addAll(await _check(t, '$where open'));
  final calendar = find.byType(CalendarDatePicker).evaluate().isNotEmpty;

  if (calendar) {
    // The year list.
    out.addAll(
      (await _layoutErrors(() async {
        await t.tap(find.text('September 2026'));
        await t.pumpAndSettle();
      })).map((e) => '$where years: $e'),
    );
    out.addAll(await _check(t, '$where years'));
    if (find.byType(YearPicker).evaluate().isEmpty) {
      out.add('$where: the month row did not open the year list');
    }
    await t.tap(find.text('September 2026'));
    await t.pumpAndSettle();
    // Input mode, from the header.
    out.addAll(
      (await _layoutErrors(() async {
        await t.tap(find.byIcon(Icons.edit_outlined));
        await t.pumpAndSettle();
      })).map((e) => '$where to input: $e'),
    );
    out.addAll(await _check(t, '$where to input'));
    // ...and back, then pick the 3rd.
    await t.tap(find.byIcon(Icons.calendar_today));
    await t.pumpAndSettle();
    await t.tap(find.text('3'));
    await t.pumpAndSettle();
    out.addAll(await _check(t, '$where picked'));
    await t.tap(find.text('OK'));
    await t.pumpAndSettle();
    final d = await picked;
    if (d != DateTime(2026, 9, 3)) out.add('$where: picked $d, not Sep 3');
    return out;
  }

  // Input mode: a wrong date shows its error without overflowing...
  final field = find.byType(TextField);
  if (field.evaluate().isEmpty) return [...out, '$where: no date field'];
  out.addAll(
    (await _layoutErrors(() async {
      await t.enterText(field, 'not a date');
      await t.tap(find.text('OK'));
      await t.pumpAndSettle();
    })).map((e) => '$where input error: $e'),
  );
  if (find.text('Invalid format.').evaluate().isEmpty) {
    out.add('$where: no error for a wrong date');
  }
  out.addAll(await _check(t, '$where input error'));
  // ...and a right one is returned.
  await t.enterText(field, '09/03/2026');
  await t.tap(find.text('OK'));
  await t.pumpAndSettle();
  final d = await picked;
  if (d != DateTime(2026, 9, 3)) out.add('$where: typed $d, not Sep 3');
  return out;
}

Future<void> _run(WidgetTester t) async {
  final handle = t.ensureSemantics();
  addTearDown(t.view.reset);
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  final problems = <String>[];
  final calendarOn = <String>[];
  for (final s in _shapes()) {
    problems.addAll(await _sweep(t, s));
    await t.pumpWidget(const SizedBox.shrink());
    final p = await _open(t, s);
    if (find.byType(CalendarDatePicker).evaluate().isNotEmpty) {
      calendarOn.add(_name(s));
    }
    unawaited(p);
    await t.pumpWidget(const SizedBox.shrink());
  }
  handle.dispose();
  expect(problems, isEmpty, reason: problems.join('\n'));
  // The calendar stays where its days can be full size.
  for (final s in [
    for (final size in const [Size(360, 640), Size(393, 851), Size(411, 915)])
      for (final scale in const [1.0, 1.3, 2.0])
        if (!(size.width == 360 && scale == 2.0))
          _name((size: size, scale: scale, brightness: Brightness.light)),
  ]) {
    final key = s.replaceAll(' light', '');
    expect(
      calendarOn.any((c) => c.startsWith(key)),
      isTrue,
      reason: 'no calendar on $key ($calendarOn)',
    );
  }
}

void main() {
  testWidgets(
    'the date picker meets the charter on every phone shape and '
    'text size (test font)',
    _run,
  );

  testWidgets('the date picker meets the charter on every phone shape and '
      'text size (Familjen Grotesk)', (t) async {
    await t.runAsync(loadRealFonts);
    await _run(t);
  });

  test('the layout opens the calendar only where its days are 48 dp', () {
    final style = AppTheme.light().textTheme;
    EntryDatePickerLayout at(Size room, double scale, [Orientation? o]) =>
        entryDatePickerLayout(
          room: room,
          orientation:
              o ??
              (room.width > room.height
                  ? Orientation.landscape
                  : Orientation.portrait),
          textScaler: TextScaler.linear(scale),
          headline: style.headlineSmall!,
          help: style.labelLarge!,
          widestTitleAt1: 6,
        );
    expect(at(const Size(320, 568), 1).calendar, isFalse);
    expect(at(const Size(359, 900), 1).calendar, isFalse);
    expect(at(const Size(360, 640), 1).calendar, isTrue);
    expect(at(const Size(411, 915), 2).calendar, isTrue);
    expect(at(const Size(640, 360), 1).calendar, isFalse);
    expect(at(const Size(915, 411), 1).calendar, isFalse);
    // A tablet or a wide window on its side has room for the portrait
    // calendar, and gets it.
    final wide = at(const Size(800, 600), 1);
    expect(wide.calendar, isTrue);
    expect(wide.orientation, Orientation.portrait);
    expect(at(const Size(915, 411), 1).orientation, Orientation.landscape);
    // Too short for seven 48 dp rows under the header.
    expect(at(const Size(360, 500), 1).calendar, isFalse);
    // The header date never takes more than one line in portrait.
    for (final s in [1.0, 1.3, 2.0, 2.5, 3.0]) {
      final l = at(const Size(360, 640), s);
      expect(l.headlineSize * s, lessThan(70), reason: '@$s');
      expect(l.headlineSize, lessThanOrEqualTo(30));
    }
  });
}
