// QA VISUAL round 12: reverification of the round 11 date picker fixes
// (VISUAL-R11-01 day-first dates, VISUAL-R11-02 dark picker contrast) over
// the whole class, and a regression sweep around the changed code: the
// app-wide AppMaterialLocalizations, the picker's own field theme and the
// dialog surface it now sits on.
//
// Tests named "QA VISUAL-R12-NN" with `skip:` are failing repros for open
// findings; unskip to verify a fix. The other tests pass and guard the
// fixes.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/format/app_material_localizations.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;
import 'visual_harness.dart';

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

Finder get _dialog => find.byType(DatePickerDialog);

Finder _inDialog(Finder f) => find.descendant(of: _dialog, matching: f);

double _contrast(Color a, Color b) {
  final la = a.computeLuminance(), lb = b.computeLuminance();
  return (la > lb ? la + 0.05 : lb + 0.05) / (la > lb ? lb + 0.05 : la + 0.05);
}

/// Opens the picker straight from [pickEntryDate] in a bare app with the
/// real theme and the app's Material strings; returns the pending result.
Future<Future<DateTime?>> _bare(
  WidgetTester t,
  Size size,
  Brightness b,
  DateTime initial,
) async {
  t.view.physicalSize = size * 3;
  t.view.devicePixelRatio = 3;
  addTearDown(t.view.reset);
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

void main() {
  configureVisualTests();

  // ------------------------------------------------------------------
  // VISUAL-R11-02 class: every picker state, every charter variant, every
  // opener, in the real app (pass).
  // ------------------------------------------------------------------

  testWidgets(
    'VISUAL-R11-02 class: the picker passes textContrastGuideline on every '
    'variant from every opener, with the keyboard up, and in the year list',
    (tester) async {
      await tester.runAsync(loadRealFonts);
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final handle = tester.ensureSemantics();
      final problems = <String>[];
      final openers = {
        'expense': Routes.editExpense(w.expense),
        'payment': Routes.editExpense(w.payment),
        'settle': _settle(w),
      };
      for (final v in kVariants) {
        for (final e in openers.entries) {
          // Every opener in the dark theme, the expense opener in both.
          if (v.brightness == Brightness.light && e.key != 'expense') {
            continue;
          }
          final where = '${variantName(v)} ${e.key}';
          await pumpVisual(tester, w.phone, v: v, location: e.value);
          if (!await _semanticTap(tester, RegExp(r'^Date, ')) ||
              _dialog.evaluate().isEmpty) {
            problems.add('$where: picker did not open');
            await tester.pumpWidget(const SizedBox.shrink());
            continue;
          }
          await tester.pumpAndSettle();
          Future<void> check(String state) async {
            final r = await textContrastGuideline.evaluate(tester);
            if (!r.passed) problems.add('$where $state: ${r.reason}');
          }

          if (_inDialog(find.byType(CalendarDatePicker))
              .evaluate()
              .isNotEmpty) {
            await check('calendar');
            await tester.tap(_inDialog(find.text('November 2026')));
            await tester.pumpAndSettle();
            await check('years');
            await tester.tap(_inDialog(find.text('2026')));
            await tester.pumpAndSettle();
            await tester.tap(_inDialog(find.byIcon(Icons.edit_outlined)));
            await tester.pumpAndSettle();
          }
          await check('input');
          tester.view.viewInsets = FakeViewPadding(
            bottom: 280 * tester.view.devicePixelRatio,
          );
          await tester.pumpAndSettle();
          await check('input kb');
          // The format stays named while the field holds a date.
          if (find
              .descendant(
                of: _dialog,
                matching: find.textContaining(kCompactDateFormat),
              )
              .evaluate()
              .isEmpty) {
            problems.add('$where: format not on screen');
          }
          tester.view.resetViewInsets();
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
      handle.dispose();
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  testWidgets(
    'VISUAL-R11-02 class: the picker icons (mode switch, month arrows) and '
    'the field outline are at least 3:1 on the picker surface in both themes',
    (tester) async {
      final problems = <String>[];
      for (final b in Brightness.values) {
        final pending = await _bare(
          tester,
          const Size(360, 640),
          b,
          DateTime(2026, 11, 9),
        );
        pending.ignore();
        final surface = tester
            .widget<Material>(_inDialog(find.byType(Material)).first)
            .color!;
        for (final icon in [
          Icons.edit_outlined,
          Icons.chevron_left,
          Icons.chevron_right,
        ]) {
          final f = _inDialog(find.byIcon(icon));
          if (f.evaluate().isEmpty) continue;
          final color =
              tester.widget<Icon>(f.first).color ??
              IconTheme.of(tester.element(f.first)).color!;
          final r = _contrast(color, surface);
          if (r < 3) {
            problems.add('${b.name} $icon: ${r.toStringAsFixed(2)}:1');
          }
        }
        await tester.tap(_inDialog(find.byIcon(Icons.edit_outlined)));
        await tester.pumpAndSettle();
        // Unfocus so the enabled (not focused) outline is drawn.
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        final deco = tester
            .widget<InputDecorator>(_inDialog(find.byType(InputDecorator)))
            .decoration;
        final side = deco.enabledBorder?.borderSide;
        if (side == null ||
            side.style == BorderStyle.none ||
            _contrast(side.color, surface) < 3) {
          problems.add('${b.name} field outline: $side on $surface');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  // ------------------------------------------------------------------
  // VISUAL-R11-01 class: the field writes every date the picker can open
  // on in a form it reads back (pass for 1900 to 9999).
  // ------------------------------------------------------------------

  testWidgets(
    'VISUAL-R11-01 class: OK on an unchanged field keeps the date, at the '
    'ends of the model date range and around them',
    (tester) async {
      final problems = <String>[];
      for (final d in [
        DateTime(1900, 1, 1),
        DateTime(1970, 1, 1),
        DateTime(2000, 2, 29),
        DateTime(2026, 12, 31),
        DateTime(2090, 6, 1),
        DateTime(9999, 12, 31),
      ]) {
        final pending = await _bare(
          tester,
          const Size(320, 568),
          Brightness.light,
          d,
        );
        await tester.tap(_inDialog(find.text('OK')));
        await tester.pumpAndSettle();
        if (_dialog.evaluate().isNotEmpty) {
          problems.add('$d: OK refused');
          await tester.pumpWidget(const SizedBox.shrink());
          continue;
        }
        final got = await pending;
        if (got != d) problems.add('$d: saved as $got');
        await tester.pumpWidget(const SizedBox.shrink());
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  // ------------------------------------------------------------------
  // New findings.
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R12-01: an entry dated 1 Jan 10000 local time (9999-12-31 '
    'late UTC, a valid model date, seen east of UTC) opens with a field the '
    'picker refuses on OK',
    (tester) async {
      // The model accepts dates up to the end of 9999-12-31 UTC
      // (TextRules.maxModelDateMs) and the editors pass the local date to
      // the picker: in India (UTC+05:30) 9999-12-31 18:30 UTC or later is
      // 1 Jan 10000. Tests run in UTC, so the local date is given directly.
      final d = DateTime(10000, 1, 1);
      final pending = await _bare(
        tester,
        const Size(320, 568),
        Brightness.light,
        d,
      );
      final field = tester.widget<TextField>(_inDialog(find.byType(TextField)));
      final shown = field.controller?.text;
      await tester.tap(_inDialog(find.text('OK')));
      await tester.pumpAndSettle();
      final refused = _dialog.evaluate().isNotEmpty;
      final error = _inDialog(find.text('Invalid format.'))
          .evaluate()
          .isNotEmpty;
      if (refused) await tester.pumpWidget(const SizedBox.shrink());
      expect(
        refused,
        isFalse,
        reason:
            'field shows "$shown"; OK unchanged '
            '${error ? 'shows "Invalid format."' : 'is refused'}',
      );
      expect(await pending, d);
    },
  );
}
