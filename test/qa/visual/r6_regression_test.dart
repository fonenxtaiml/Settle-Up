// QA VISUAL round 6: reverification of the round 5 fixes (BesideOrUnder
// keeps a share field in place while its split row switches layout,
// FitWordsText sets a subline amount smaller instead of breaking it, and
// MemberSplitRow stacks its share before it squeezes the name) and the
// neighbouring cases those fixes touch.
//
// Tests named "QA VISUAL-R6-NN" with `skip: true` are failing repros for
// open findings; unskip to verify a fix. The other tests pass and guard the
// fixes.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/expense/expense_edit_screen.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'visual_harness.dart';

Variant v6(double w, double scale, [Brightness b = Brightness.light]) => (
  size: Size(w, w <= 320 ? 568 : (w < 384 ? 640 : 800)),
  scale: scale,
  brightness: b,
);

double _minWord(RenderParagraph p) => p.getMinIntrinsicWidth(double.infinity);

/// Paragraphs under [scope] narrower than their longest word.
List<String> _broken(Finder scope, String where) => [
  for (final e
      in find.descendant(of: scope, matching: find.byType(RichText)).evaluate())
    if (e.renderObject case final RenderParagraph p)
      if (p.hasSize && p.size.width + 0.5 < _minWord(p))
        '$where: "${p.text.toPlainText()}" gets '
            '${p.size.width.toStringAsFixed(1)} dp < its longest word '
            '${_minWord(p).toStringAsFixed(1)} dp',
];

/// Builds a world whose extra expenses use percent, adjustment and
/// several-payer splits, and an equal split that someone else paid (so
/// my row shows "you owe Priya" with a tether). Call inside runAsync.
Future<
  ({
    VisualWorld w,
    String percent,
    String adjust,
    String equalOther,
    String equalOtherKwd,
    String multi,
    Map<String, MemberId> m,
  })
>
_splitWorld({int total = 12000050, int kwd = 1250750, String? friend}) async {
  final w = await (friend == null
      ? VisualWorld.build(inr: total, kwd: kwd)
      : VisualWorld.build(friend: friend, inr: total, kwd: kwd));
  final p = w.phone;
  final gs = p.gs(w.group);
  final m = <String, MemberId>{};
  for (final mem in gs.members.values) {
    m[mem.personId == p.me ? 'me' : mem.displayName] = mem.id;
  }
  final me = m['me']!;
  final f = m[friend ?? 'Priya Sharma']!;
  final sam = m['Sam']!;
  ExpenseDraft draft(SplitSpec paid, SplitSpec owed, [int? t]) => ExpenseDraft(
    groupId: w.group,
    description: 'Hotel',
    total: t ?? total,
    currency: 'INR',
    paidBy: paid,
    owedBy: owed,
    category: 'food.dining',
    date: kNow.subtract(const Duration(hours: 3)),
  );
  final percent = await p.ledger.addExpense(
    draft(
      SplitSpec.single(me, total),
      SplitSpec(SplitMethod.percent, {me: 3333, f: 3333, sam: 3334}),
    ),
  );
  final adjust = await p.ledger.addExpense(
    draft(
      SplitSpec.single(me, total),
      SplitSpec(SplitMethod.adjustment, {me: 0, f: 0, sam: 0}),
    ),
  );
  final equalOther = await p.ledger.addExpense(
    draft(SplitSpec.single(f, total), SplitSpec.equal([me, f, sam])),
  );
  final half = total ~/ 2;
  final multi = await p.ledger.addExpense(
    draft(
      SplitSpec(SplitMethod.exact, {me: half, f: total - half}),
      SplitSpec.equal([me, f, sam]),
    ),
  );
  final kg = p.gs(w.kwdGroup);
  final km = {
    for (final mem in kg.members.values)
      mem.personId == p.me ? 'me' : mem.displayName: mem.id,
  };
  final equalOtherKwd = await p.ledger.addExpense(
    ExpenseDraft(
      groupId: w.kwdGroup,
      description: 'Hotel',
      total: kwd,
      currency: 'KWD',
      paidBy: SplitSpec.single(km['Sam K']!, kwd),
      owedBy: SplitSpec.equal([km['me']!, km['Sam K']!]),
      category: 'food.dining',
      date: kNow.subtract(const Duration(hours: 3)),
    ),
  );
  return (
    w: w,
    percent: percent,
    adjust: adjust,
    equalOther: equalOther,
    equalOtherKwd: equalOtherKwd,
    multi: multi,
    m: m,
  );
}

Finder _fieldOf(TextEditingController c) => find.byWidgetPredicate(
  (w) => w is EditableText && identical(w.controller, c),
);

/// Types [steps] into the focused field one value at a time; returns the
/// first step after which the field no longer has focus, or null.
Future<String?> _typeUntilFocusLost(
  WidgetTester tester,
  TextEditingController c,
  List<String> steps,
) async {
  for (final text in steps) {
    if (!tester.testTextInput.hasAnyClients) return 'before "$text"';
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ),
    );
    await tester.pump();
    final f = _fieldOf(c);
    final focused =
        f.evaluate().isNotEmpty &&
        (f.evaluate().first.widget as EditableText).focusNode.hasFocus;
    if (!focused || !tester.testTextInput.hasAnyClients) return 'after "$text"';
  }
  return null;
}

List<String> _typing(String s) => [
  for (var i = 1; i <= s.length; i++) s.substring(0, i),
];
List<String> _deleting(String s) => [
  for (var i = s.length - 1; i >= 0; i--) s.substring(0, i),
];

/// Scrolls the editor to the split rows and focuses the [index]th share
/// field (EditableText that is not the amount or description field).
Future<TextEditingController> _focusShareField(
  WidgetTester tester,
  int index,
) async {
  await tester.scrollUntilVisible(
    find.text('Sam'),
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
  final shares = find.descendant(
    of: find.byType(ListSection),
    matching: find.byType(EditableText),
  );
  final f = shares.at(index);
  await tester.ensureVisible(f);
  await tester.pump();
  await tester.tap(f);
  await tester.pump();
  return (f.evaluate().first.widget as EditableText).controller;
}

/// The multi-payer sheet over the app's theme at [v], as the editor
/// shows it.
Future<void> _pumpSheet(
  WidgetTester tester,
  Variant v, {
  required int total,
  required String currency,
  Map<MemberId, int>? initial,
  Map<MemberId, String>? names,
}) async {
  setView(tester, v.size);
  tester.platformDispatcher.textScaleFactorTestValue = v.scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final n = names ?? const {'me': 'You', 'p': 'Priya', 's': 'Sam'};
  await tester.pumpWidget(
    MaterialApp(
      theme: v.brightness == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark(),
      home: Scaffold(
        body: MultiPayerSheet(
          members: n.keys.toList(),
          names: n,
          fullNames: n,
          me: 'me',
          total: total,
          currency: currency,
          initial: initial ?? {'me': total},
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  configureVisualTests();

  // ------------------------------------------------------------------
  // Guards and probes for the round 5 fixes.
  // ------------------------------------------------------------------

  testWidgets('VISUAL-R5-01 neighbours: share fields keep focus while '
      'typing and deleting in exact, percent and adjustment splits, '
      'Money.maxMinor included', (tester) async {
    late ({
      VisualWorld w,
      String percent,
      String adjust,
      String equalOther,
      String equalOtherKwd,
      String multi,
      Map<String, MemberId> m,
    })
    s;
    await tester.runAsync(() async => s = await _splitWorld());
    final problems = <String>[];
    for (final v in [
      v6(320, 1.0),
      v6(360, 1.0, Brightness.dark),
      v6(411, 1.0),
      v6(360, 1.3),
      v6(320, 2.0),
    ]) {
      for (final (label, loc, index, steps) in [
        (
          'exact, typing maxMinor into Priya',
          Routes.editExpense(s.w.expense),
          1,
          [..._deleting('120000.50'), ..._typing('9999999999.99')],
        ),
        (
          'percent, Priya',
          Routes.editExpense(s.percent),
          1,
          [..._deleting('33.33'), ..._typing('33.33')],
        ),
        (
          'adjustment, Sam',
          Routes.editExpense(s.adjust),
          2,
          _typing('-9999999999.99'),
        ),
      ]) {
        await pumpVisual(tester, s.w.phone, v: v, location: loc);
        final c = await _focusShareField(tester, index);
        final lost = await _typeUntilFocusLost(tester, c, steps);
        if (lost == null && c.text != steps.last) {
          problems.add('${variantName(v)} $label: ended at "${c.text}"');
        }
        if (lost != null) {
          problems.add(
            '${variantName(v)} $label: focus lost $lost (now "${c.text}")',
          );
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
    await tester.runAsync(s.w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('VISUAL-R5-01 neighbours: the multi-payer sheet keeps focus '
      'while typing Money.maxMinor', (tester) async {
    final problems = <String>[];
    for (final v in [
      v6(320, 1.0),
      v6(360, 1.3, Brightness.dark),
      v6(411, 1.45),
      v6(320, 2.0),
    ]) {
      for (final (cur, typed) in [
        ('INR', '9999999999.99'),
        ('KWD', '99999999.999'),
      ]) {
        await _pumpSheet(tester, v, total: Money.maxMinor, currency: cur);
        final f = find.byType(EditableText).at(1);
        await tester.ensureVisible(f);
        await tester.tap(f);
        await tester.pump();
        final c = (f.evaluate().first.widget as EditableText).controller;
        final lost = await _typeUntilFocusLost(tester, c, _typing(typed));
        if (lost != null) {
          problems.add('${variantName(v)} $cur: focus lost $lost');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('VISUAL-R5-02 neighbours: equal-split rows with a payer '
      'other than me ("you owe Priya" with a tether), several payers and '
      'Money.maxMinor keep names and amounts whole with no overflow', (
    tester,
  ) async {
    final problems = <String>[];
    for (final (wn, total, kwd, friend) in [
      ('realistic', 12000050, 1250750, null),
      ('huge', Money.maxMinor, Money.maxMinor, null),
      ('long names', 1234550, 125750, kName40),
    ]) {
      late ({
        VisualWorld w,
        String percent,
        String adjust,
        String equalOther,
        String equalOtherKwd,
        String multi,
        Map<String, MemberId> m,
      })
      s;
      await tester.runAsync(
        () async =>
            s = await _splitWorld(total: total, kwd: kwd, friend: friend),
      );
      for (final v in [
        v6(320, 1.0),
        v6(320, 1.3, Brightness.dark),
        v6(320, 2.0),
        v6(360, 1.0),
        v6(360, 1.59, Brightness.dark),
        v6(411, 1.45),
      ]) {
        for (final (ln, loc) in [
          ('equal, Priya paid', Routes.editExpense(s.equalOther)),
          ('equal KWD, Sam K paid', Routes.editExpense(s.equalOtherKwd)),
          ('equal, two payers', Routes.editExpense(s.multi)),
        ]) {
          final where = '$wn ${variantName(v)} $ln';
          final errors = await collectLayoutErrors(() async {
            await pumpVisual(tester, s.w.phone, v: v, location: loc);
            await tester.drag(
              find.byType(Scrollable).first,
              const Offset(0, -2000),
            );
            await tester.pump(const Duration(milliseconds: 300));
          });
          for (final e in errors.toSet()) {
            problems.add('$where: $e');
          }
          if (find.byType(MemberSplitRow).evaluate().length < 2) {
            problems.add('$where: split rows not shown');
          }
          problems.addAll(_broken(find.byType(MemberSplitRow), where));
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
      await tester.runAsync(s.w.phone.dispose);
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('VISUAL-R4-03 neighbours: stacked input split rows (exact, '
      'percent, adjustment) and the multi-payer sheet never break an amount '
      'at 1.8x-2.0x with Money.maxMinor', (tester) async {
    final problems = <String>[];
    late ({
      VisualWorld w,
      String percent,
      String adjust,
      String equalOther,
      String equalOtherKwd,
      String multi,
      Map<String, MemberId> m,
    })
    s;
    await tester.runAsync(
      () async =>
          s = await _splitWorld(total: Money.maxMinor, kwd: Money.maxMinor),
    );
    for (final v in [
      v6(320, 1.8),
      v6(320, 2.0, Brightness.dark),
      v6(340, 2.0),
      v6(360, 2.0),
    ]) {
      for (final (ln, loc) in [
        ('percent', Routes.editExpense(s.percent)),
        ('adjustment', Routes.editExpense(s.adjust)),
      ]) {
        final where = '${variantName(v)} $ln';
        final errors = await collectLayoutErrors(() async {
          await pumpVisual(tester, s.w.phone, v: v, location: loc);
          await tester.drag(
            find.byType(Scrollable).first,
            const Offset(0, -2000),
          );
          await tester.pump(const Duration(milliseconds: 300));
        });
        for (final e in errors.toSet()) {
          problems.add('$where: $e');
        }
        if (find.byType(Checkbox).evaluate().length < 3) {
          problems.add('$where: split rows not shown');
        }
        problems.addAll(_broken(find.byType(ListSection), where));
        await tester.pumpWidget(const SizedBox.shrink());
      }
      for (final cur in ['INR', 'KWD']) {
        final where = '${variantName(v)} multi-payer sheet $cur';
        final errors = await collectLayoutErrors(
          () => _pumpSheet(
            tester,
            v,
            total: Money.maxMinor,
            currency: cur,
            initial: {'me': Money.maxMinor ~/ 2, 'p': Money.maxMinor ~/ 2},
          ),
        );
        for (final e in errors.toSet()) {
          problems.add('$where: $e');
        }
        // The rows and the summary; the buttons under them are
        // VISUAL-R6-01.
        problems.addAll(_broken(find.byType(ListSection), where));
        problems.addAll(_broken(find.byType(SplitSummaryBar), where));
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
    await tester.runAsync(s.w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('split rows meet the tap target, labeled tap target and '
      'contrast guidelines once they stack (320 dp 2.0x, both themes)', (
    tester,
  ) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());
    final handle = tester.ensureSemantics();
    final problems = <String>[];
    for (final b in Brightness.values) {
      for (final (ln, loc) in [
        ('edit (exact)', Routes.editExpense(w.expense)),
        ('new (equal)', Routes.newExpense(groupId: w.group)),
      ]) {
        await pumpVisual(tester, w.phone, v: v6(320, 2.0, b), location: loc);
        if (ln.startsWith('new')) {
          await tester.enterText(
            find.descendant(
              of: find.byType(AmountField),
              matching: find.byType(EditableText),
            ),
            '120000.50',
          );
          await tester.pump();
          FocusManager.instance.primaryFocus?.unfocus();
          await tester.pump();
        }
        await tester.scrollUntilVisible(
          find.text('Sam'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump();
        for (final (gn, g) in [
          ('tap target', androidTapTargetGuideline),
          ('labeled', labeledTapTargetGuideline),
          ('contrast', textContrastGuideline),
        ]) {
          final r = await g.evaluate(tester);
          if (!r.passed) {
            problems.add('${b.name} $ln $gn: ${r.reason}');
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
    handle.dispose();
    await tester.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // ------------------------------------------------------------------
  // New findings, round 6 (skipped repros).
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R6-01: the multi-payer sheet squeezes "Split the rest '
    'equally" beside "Done": two to five lines, and "equally" broken at '
    '320 dp 2.0x',
    (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final problems = <String>[];
      for (final v in [
        v6(320, 1.0),
        v6(360, 1.0, Brightness.dark),
        v6(360, 1.3),
        v6(320, 2.0),
      ]) {
        await pumpVisual(
          tester,
          w.phone,
          v: v,
          location: Routes.editExpense(w.expense),
        );
        // "Paid by" opens the payer picker; "Multiple people" the sheet.
        tester
            .widget<PickerTile>(
              find.byType(PickerTile, skipOffstage: false).first,
            )
            .onTap!();
        await settleFrames(tester);
        await tester.tap(find.text('Multiple people'));
        await settleFrames(tester);
        final sheet = find.byType(MultiPayerSheet);
        expect(sheet, findsOneWidget);
        for (final label in ['Split the rest equally', 'Done']) {
          final p = tester.renderObject<RenderParagraph>(
            find.descendant(of: sheet, matching: find.text(label)),
          );
          final lines = (p.size.height / p.preferredLineHeight).round();
          final word = p.getMinIntrinsicWidth(double.infinity);
          if (lines > 1 || p.size.width + 0.5 < word) {
            problems.add(
              '${variantName(v)}: "$label" on $lines lines in a '
              '${p.size.width.toStringAsFixed(1)} dp box (one line needs '
              '${p.getMaxIntrinsicWidth(double.infinity).toStringAsFixed(1)}'
              ' dp, its longest word ${word.toStringAsFixed(1)} dp)',
            );
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
    skip: true, // VISUAL-R6-01
  );
}
