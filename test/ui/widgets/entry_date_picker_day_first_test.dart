// VISUAL-R11-01 regression: in the real app, on every charter variant and
// from every opener (expense, payment, settle up), the date picker writes
// and reads dates day first and names the format the whole time the field
// holds a date.
//
// For each one, in input mode (the only mode on 320 dp phones and at 2.0x
// text; switched to from the calendar elsewhere), with a keyboard up:
//
// * the field shows the stored date as dd/mm/yyyy, and OK with it
//   unchanged keeps the date;
// * the label naming "dd/mm/yyyy" is painted, on one line, uncut, inside
//   the field;
// * "05/11/2026" is saved as 5 Nov and "11/05/2026" as 11 May;
// * a month-first date that cannot be day-first ("11/25/2026") is refused
//   with the format error and saves nothing.
//
// In calendar mode the header shows the date day first.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/format/app_material_localizations.dart';
import 'package:settle_up/ui/router.dart';

import '../../qa/visual/visual_harness.dart';

Finder get _dialog => find.byType(DatePickerDialog);

Finder _inDialog(Finder f) => find.descendant(of: _dialog, matching: f);

SemanticsNode? _node(Pattern label) {
  final all = find.semantics.byLabel(label).evaluate().toList();
  return all.isEmpty ? null : all.first;
}

/// Scrolls the editor until its Date row is built (the keyboard down) and
/// returns its label, or null when it has none.
Future<String?> _dateRow(WidgetTester t) async {
  t.view.resetViewInsets();
  await t.pumpAndSettle();
  final row = RegExp(r'^Date, ');
  final s = find.byWidgetPredicate(
    (w) =>
        w is Scrollable &&
        axisDirectionToAxis(w.axisDirection) == Axis.vertical,
  );
  if (s.evaluate().isNotEmpty) {
    t.state<ScrollableState>(s.first).position.jumpTo(0);
    await t.pump(const Duration(milliseconds: 200));
  }
  for (var i = 0; i < 12 && _node(row) == null; i++) {
    if (s.evaluate().isEmpty) break;
    final pos = t.state<ScrollableState>(s.first).position;
    if (pos.pixels >= pos.maxScrollExtent) break;
    pos.jumpTo((pos.pixels + 200).clamp(0, pos.maxScrollExtent));
    await t.pump(const Duration(milliseconds: 200));
  }
  return _node(row)?.getSemanticsData().label;
}

/// Opens the picker from the Date row, in input mode with a keyboard up;
/// returns the row's label before it opened, or null if it did not open.
Future<String?> _openPicker(WidgetTester t) async {
  final row = await _dateRow(t);
  if (row == null) return null;
  t.semantics.tap(find.semantics.byLabel(RegExp(r'^Date, ')).first);
  await t.pump();
  await t.pump(const Duration(milliseconds: 600));
  await t.pumpAndSettle();
  if (_dialog.evaluate().isEmpty) return null;
  if (_inDialog(find.byType(CalendarDatePicker)).evaluate().isNotEmpty) {
    await t.tap(_inDialog(find.byIcon(Icons.edit_outlined)));
    await t.pumpAndSettle();
  }
  t.view.viewInsets = FakeViewPadding(bottom: 280 * t.view.devicePixelRatio);
  await t.pumpAndSettle();
  return row;
}

String _settle(VisualWorld w) {
  final gs = w.phone.gs(w.group);
  final me = gs.members.values.firstWhere((m) => m.personId == w.phone.me);
  final f = gs.members.values.firstWhere(
    (m) => m.displayName == 'Priya Sharma',
  );
  return Routes.settle(
    groupId: w.group,
    from: f.id,
    to: me.id,
    currency: 'INR',
  );
}

void main() {
  configureVisualTests();

  testWidgets('the app runs with the day-first Material strings', (t) async {
    late VisualWorld w;
    await t.runAsync(() async => w = await VisualWorld.realistic());
    await pumpVisual(
      t,
      w.phone,
      v: kVariants.first,
      location: Routes.editExpense(w.expense),
    );
    final ctx = t.element(find.byType(Scaffold).first);
    expect(MaterialLocalizations.of(ctx), isA<AppMaterialLocalizations>());
    await t.pumpWidget(const SizedBox.shrink());
    await t.runAsync(w.phone.dispose);
  });

  testWidgets(
    'every variant and opener writes and reads the date day first, with '
    'the format on screen',
    (t) async {
      late VisualWorld w;
      await t.runAsync(() async => w = await VisualWorld.realistic());
      final handle = t.ensureSemantics();
      addTearDown(t.view.resetViewInsets);
      final problems = <String>[];
      final openers = {
        'expense': Routes.editExpense(w.expense),
        'payment': Routes.editExpense(w.payment),
        'settle': _settle(w),
      };
      const label = 'Date ($kCompactDateFormat)';
      for (final v in kVariants) {
        for (final e in openers.entries) {
          final where = '${variantName(v)} ${e.key}';
          Future<String?> open() async {
            await pumpVisual(t, w.phone, v: v, location: e.value);
            final row = await _openPicker(t);
            if (row == null) problems.add('$where: the picker did not open');
            return row;
          }

          final before = await open();
          if (before == null) continue;
          final field = _inDialog(find.byType(TextField));
          final text = t.widget<TextField>(field).controller!.text;
          final stored = const AppMaterialLocalizations().parseCompactDate(
            text,
          );
          if (!RegExp(r'^\d\d/\d\d/\d{4}$').hasMatch(text) || stored == null) {
            problems.add('$where: the field shows "$text"');
          } else if (!before.contains(
            const AppMaterialLocalizations().formatShortMonthDay(stored),
          )) {
            problems.add('$where: "$text" is not the row\'s "$before"');
          }
          // The label names the format, painted on one line inside the
          // field.
          final l = _inDialog(find.text(label));
          if (l.evaluate().isEmpty) {
            problems.add('$where: no "$label" label');
          } else {
            final p = t.renderObject<RenderParagraph>(
              find.descendant(of: l.first, matching: find.byType(RichText)),
            );
            final r = t.getRect(l.first);
            final fr = t.getRect(field);
            final painter = TextPainter(
              text: p.text,
              textDirection: TextDirection.ltr,
              textScaler: p.textScaler,
            )..layout();
            if (p.didExceedMaxLines ||
                painter.width > p.size.width + 0.5 ||
                r.left < fr.left - 0.5 ||
                r.right > fr.right + 0.5) {
              problems.add('$where: the label is cut ($r in $fr)');
            }
            painter.dispose();
            var o = p as RenderObject?;
            while (o != null) {
              if (o is RenderOpacity && o.opacity == 0 ||
                  o is RenderAnimatedOpacity && o.opacity.value == 0) {
                problems.add('$where: the label is not painted');
                break;
              }
              o = o.parent;
            }
          }
          // OK with the date unchanged keeps it.
          await t.tap(_inDialog(find.text('OK')));
          await t.pumpAndSettle();
          final kept = await _dateRow(t);
          if (kept != before) {
            problems.add('$where: unchanged "$text" saved as "$kept"');
          }
          for (final c in const [
            ('05/11/2026', '5 Nov'),
            ('11/05/2026', '11 May'),
          ]) {
            if (await open() == null) break;
            await t.enterText(_inDialog(find.byType(TextField)), c.$1);
            await t.tap(_inDialog(find.text('OK')));
            await t.pumpAndSettle();
            final stuck = _dialog.evaluate().isNotEmpty;
            final saved = stuck ? null : await _dateRow(t);
            if (saved == null || !saved.contains(c.$2)) {
              problems.add('$where: "${c.$1}" saved as "$saved"');
            }
          }
          // Month first cannot be read day first: refused, nothing saved.
          final now = await open();
          if (now != null) {
            await t.enterText(_inDialog(find.byType(TextField)), '11/25/2026');
            await t.tap(_inDialog(find.text('OK')));
            await t.pumpAndSettle();
            if (_inDialog(find.text('Invalid format.')).evaluate().isEmpty) {
              problems.add('$where: "11/25/2026" was not refused');
            }
            await t.tap(_inDialog(find.text('Cancel')));
            await t.pumpAndSettle();
            final saved = await _dateRow(t);
            if (saved != now) {
              problems.add('$where: "11/25/2026" saved "$saved"');
            }
          }
          t.view.resetViewInsets();
          await t.pumpWidget(const SizedBox.shrink());
        }
      }
      handle.dispose();
      await t.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  testWidgets('the calendar header shows the chosen date day first', (t) async {
    late VisualWorld w;
    await t.runAsync(() async => w = await VisualWorld.realistic());
    final handle = t.ensureSemantics();
    await pumpVisual(
      t,
      w.phone,
      v: (size: const Size(360, 640), scale: 1.0, brightness: Brightness.light),
      location: Routes.editExpense(w.expense),
    );
    t.semantics.tap(find.semantics.byLabel(RegExp(r'^Date, ')).first);
    await t.pumpAndSettle();
    expect(_inDialog(find.byType(CalendarDatePicker)), findsOneWidget);
    expect(_inDialog(find.text('Mon, 9 Nov')), findsOneWidget);
    expect(_inDialog(find.text('Mon, Nov 9')), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
    handle.dispose();
    await t.runAsync(w.phone.dispose);
  });
}
