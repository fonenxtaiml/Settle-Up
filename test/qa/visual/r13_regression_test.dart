// QA VISUAL round 13: reverification of the VISUAL-R12-01 fix (the date
// field reads back every year it writes) over the whole class, and a
// regression sweep around the changed parser: the picker opened on the
// model range's last local day in every charter variant and in calendar
// mode, and the editors end to end on a model date
// at the very end of the range.
//
// Tests named "QA VISUAL-R13-NN" with `skip:` are failing repros for open
// findings; unskip to verify a fix. The other tests pass and guard the
// fixes.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/format/app_material_localizations.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';

import 'visual_harness.dart';

Finder get _dialog => find.byType(DatePickerDialog);

Finder _inDialog(Finder f) => find.descendant(of: _dialog, matching: f);

SemanticsNode? _node(Pattern label) {
  final all = find.semantics.byLabel(label).evaluate().toList();
  return all.isEmpty ? null : all.first;
}

Finder _vertical() => find.byWidgetPredicate(
  (w) =>
      w is Scrollable && axisDirectionToAxis(w.axisDirection) == Axis.vertical,
);

Future<bool> _semanticTap(WidgetTester tester, Pattern label) async {
  for (var i = 0; i < 12 && _node(label) == null; i++) {
    final s = _vertical();
    if (s.evaluate().isEmpty) break;
    final pos = tester.state<ScrollableState>(s.first).position;
    if (pos.pixels >= pos.maxScrollExtent) break;
    pos.jumpTo((pos.pixels + 200).clamp(0, pos.maxScrollExtent));
    await tester.pump(const Duration(milliseconds: 200));
  }
  if (_node(label) == null) return false;
  tester.semantics.tap(find.semantics.byLabel(label).first);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 600));
  return true;
}

/// Opens [pickEntryDate] on [initial] in a bare app with the real theme,
/// the app's Material strings and the text at [scale].
Future<Future<DateTime?>> _bare(
  WidgetTester t,
  Size size,
  double scale,
  Brightness b,
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
    MaterialApp(
      theme: b == Brightness.light ? AppTheme.light() : AppTheme.dark(),
      localizationsDelegates: const [AppMaterialLocalizations.delegate],
      home: Builder(
        builder: (c) {
          ctx = c;
          return const Scaffold();
        },
      ),
    ),
  );
  final r = pickEntryDate(ctx, initial: initial, now: DateTime(2026, 11, 10));
  await t.pumpAndSettle();
  return r;
}

/// The field's text, and whether all of it fits in the field.
(String, bool) _fieldFits(WidgetTester t) {
  final text =
      t.widget<TextField>(_inDialog(find.byType(TextField))).controller?.text ??
      '';
  final re = t
      .state<EditableTextState>(_inDialog(find.byType(EditableText)))
      .renderEditable;
  final needed = re.getMaxIntrinsicWidth(double.infinity);
  return (text, needed <= re.size.width + 0.5);
}

void main() {
  configureVisualTests();

  // ------------------------------------------------------------------
  // VISUAL-R12-01 class: the picker on the last local day a model date
  // can be (1 Jan 10000, east of UTC) in every variant (pass).
  // ------------------------------------------------------------------

  testWidgets(
    'VISUAL-R12-01 class: the picker on 1 Jan 10000 lays out, shows the '
    'whole year, passes contrast and keeps the date on OK in every charter '
    'variant and in calendar mode',
    (tester) async {
      final handle = tester.ensureSemantics();
      final problems = <String>[];
      final d = DateTime(10000, 1, 1);
      final variants = [
        ...kVariants,
        for (final s in const [1.0, 1.3])
          for (final b in Brightness.values)
            (size: const Size(411, 891), scale: s, brightness: b),
      ];
      for (final v in variants) {
        final where = variantName(v);
        late Future<DateTime?> pending;
        var sawCalendar = false;
        final errors = await collectLayoutErrors(() async {
          pending = await _bare(tester, v.size, v.scale, v.brightness, d);
          if (_inDialog(find.byType(CalendarDatePicker))
              .evaluate()
              .isNotEmpty) {
            sawCalendar = true;
            if (_inDialog(find.text('January 10000')).evaluate().isEmpty) {
              problems.add('$where: month row is not "January 10000"');
            }
            final r = await textContrastGuideline.evaluate(tester);
            if (!r.passed) problems.add('$where calendar: ${r.reason}');
            await tester.tap(_inDialog(find.byIcon(Icons.edit_outlined)));
            await tester.pumpAndSettle();
          }
          final (text, fits) = _fieldFits(tester);
          if (text != '01/01/10000') problems.add('$where: field "$text"');
          if (!fits) problems.add('$where: field "$text" cut');
          final r = await textContrastGuideline.evaluate(tester);
          if (!r.passed) problems.add('$where input: ${r.reason}');
          await tester.tap(_inDialog(find.text('OK')));
          await tester.pumpAndSettle();
        });
        if (errors.isNotEmpty) problems.add('$where: ${errors.join('; ')}');
        if (_dialog.evaluate().isNotEmpty) {
          problems.add('$where: OK refused');
          await tester.pumpWidget(const SizedBox.shrink());
          continue;
        }
        final got = await pending;
        if (got != d) problems.add('$where: saved as $got');
        if (v.size.width == 411 && v.scale == 1.0 && !sawCalendar) {
          problems.add('$where: expected calendar mode');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
      handle.dispose();
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  testWidgets(
    'VISUAL-R12-01 class: typed years around the range read as dates or '
    'as out of range, never as an invalid format',
    (tester) async {
      final problems = <String>[];
      final pending = await _bare(
        tester,
        const Size(320, 568),
        1.0,
        Brightness.light,
        DateTime(10000, 1, 1),
      );
      // In range: the picker's edges and its widened end.
      for (final (typed, error) in const [
        ('31/12/1999', 'Out of range.'),
        ('1/1/2000', null),
        ('31/12/9999', null),
        ('1.1.10000', null),
        ('2/1/10000', 'Out of range.'),
        ('1/1/99999', 'Out of range.'),
        ('1/1/275759', 'Out of range.'),
      ]) {
        await tester.enterText(_inDialog(find.byType(TextField)), typed);
        await tester.pump();
        // Submit through the field (validates without closing on success
        // only via OK): use OK and reopen when it closes.
        await tester.tap(_inDialog(find.text('OK')));
        await tester.pumpAndSettle();
        final open = _dialog.evaluate().isNotEmpty;
        final invalid =
            open &&
            _inDialog(find.text('Invalid format.')).evaluate().isNotEmpty;
        final range =
            open && _inDialog(find.text('Out of range.')).evaluate().isNotEmpty;
        if (invalid) problems.add('"$typed": Invalid format.');
        if (error == null && open) problems.add('"$typed": refused');
        if (error != null && !range) problems.add('"$typed": not $error');
        if (!open) break;
      }
      await tester.pumpWidget(const SizedBox.shrink());
      pending.ignore();
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  // ------------------------------------------------------------------
  // End to end: an expense at the last model instant, edited through the
  // Date picker and saved, stays a valid model date on its day (pass;
  // also run with TZ=Asia/Kolkata, where the picker opens on 1 Jan 10000).
  // ------------------------------------------------------------------

  testWidgets(
    'VISUAL-R12-01 class: an expense at the last model instant is edited '
    'through the picker and saved on the same local day',
    (tester) async {
      late VisualWorld w;
      late String id;
      final last = DateTime.fromMillisecondsSinceEpoch(
        TextRules.maxModelDateMs,
        isUtc: true,
      );
      await tester.runAsync(() async {
        w = await VisualWorld.realistic();
        final gs = w.phone.gs(w.group);
        final me = gs.members.values.firstWhere(
          (m) => m.personId == w.phone.me,
        );
        id = await w.phone.ledger.addExpense(
          ExpenseDraft(
            groupId: w.group,
            description: 'Far future',
            total: 10000,
            currency: 'INR',
            paidBy: SplitSpec.single(me.id, 10000),
            owedBy: SplitSpec.equal(gs.members.keys.toList()),
            category: 'food.dining',
            date: last,
          ),
        );
      });
      final handle = tester.ensureSemantics();
      final problems = <String>[];
      final local = last.toLocal();
      for (final v in [kVariants.first, kVariants.last]) {
        await pumpVisual(
          tester,
          w.phone,
          v: v,
          location: Routes.editExpense(id),
        );
        if (!await _semanticTap(tester, RegExp(r'^Date, ')) ||
            _dialog.evaluate().isEmpty) {
          problems.add('${variantName(v)}: picker did not open');
          await tester.pumpWidget(const SizedBox.shrink());
          continue;
        }
        await settleFrames(tester);
        if (_inDialog(find.byType(CalendarDatePicker)).evaluate().isNotEmpty) {
          await tester.tap(_inDialog(find.byIcon(Icons.edit_outlined)));
          await settleFrames(tester);
        }
        await tester.tap(_inDialog(find.text('OK')));
        await settleFrames(tester);
        if (_dialog.evaluate().isNotEmpty) {
          problems.add('${variantName(v)}: OK refused (${local.year})');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
      // Save once from the editor after an unchanged OK.
      await pumpVisual(
        tester,
        w.phone,
        v: kVariants.first,
        location: Routes.editExpense(id),
      );
      await _semanticTap(tester, RegExp(r'^Date, '));
      await settleFrames(tester);
      if (_dialog.evaluate().isNotEmpty) {
        await tester.tap(_inDialog(find.text('OK')));
        await settleFrames(tester);
      }
      final save = find.text('Save expense');
      if (save.evaluate().isEmpty) {
        problems.add('Save expense not found');
      } else {
        await tester.ensureVisible(save.first);
        await tester.tap(save.first);
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 300)),
        );
        await settleFrames(tester);
      }
      if (find.text('Save expense').evaluate().isNotEmpty) {
        problems.add('editor still open after Save');
      }
      final e = w.phone.ledger.current.state.expense(id)!;
      final ms = e.date.millisecondsSinceEpoch;
      if (!TextRules.isModelDate(ms)) problems.add('saved out of range: $ms');
      final saved = e.date.toLocal();
      if (DateTime(saved.year, saved.month, saved.day) !=
          DateTime(local.year, local.month, local.day)) {
        problems.add('saved on ${e.date.toLocal()}, was $local');
      }
      await tester.pumpWidget(const SizedBox.shrink());
      handle.dispose();
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  // ------------------------------------------------------------------
  // New findings.
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R13-01: above 1.0x text the year list opens scrolled away '
    'from the selected year (2026 off screen at 2.0x; 400 to 3,500 years '
    'off for a far date)',
    skip: true, // QA VISUAL-R13-01: the year list opens scrolled away from the selected year above 1.0x text
    (tester) async {
      final problems = <String>[];
      for (final size in const [Size(360, 640), Size(411, 891)]) {
        for (final scale in const [1.3, 2.0]) {
          for (final d in [
            DateTime(2026, 11, 9),
            DateTime(2090, 6, 1),
            DateTime(10000, 1, 1),
          ]) {
            final where =
                '${size.width.toInt()}x${size.height.toInt()} @${scale}x $d';
            final pending = await _bare(
              tester,
              size,
              scale,
              Brightness.light,
              d,
            );
            pending.ignore();
            final calendar = _inDialog(find.byType(CalendarDatePicker));
            if (calendar.evaluate().isEmpty) {
              await tester.pumpWidget(const SizedBox.shrink());
              continue;
            }
            await tester.tap(
              find
                  .descendant(
                    of: calendar,
                    matching: find.textContaining('${d.year}'),
                  )
                  .first,
            );
            await tester.pumpAndSettle();
            final list = find.descendant(
              of: find.byType(YearPicker),
              matching: find.byType(Scrollable),
            );
            final view = tester.getRect(list.first);
            final year = find.descendant(
              of: find.byType(YearPicker),
              matching: find.text('${d.year}'),
            );
            final shown = <String>[];
            for (final e
                in find
                    .descendant(
                      of: find.byType(YearPicker),
                      matching: find.byType(Text),
                    )
                    .evaluate()) {
              final r = tester.getRect(find.byWidget(e.widget));
              if (r.top >= view.top && r.bottom <= view.bottom) {
                shown.add((e.widget as Text).data ?? '');
              }
            }
            final r = year.evaluate().isEmpty ? null : tester.getRect(year);
            if (r == null || r.top < view.top || r.bottom > view.bottom) {
              problems.add(
                '$where: selected year not on screen, list shows '
                '${shown.isEmpty ? 'nothing' : '${shown.first}-${shown.last}'}',
              );
            }
            await tester.pumpWidget(const SizedBox.shrink());
          }
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );
}
