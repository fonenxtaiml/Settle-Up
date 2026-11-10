// QA VISUAL round 4: reverification of the VISUAL-R3-01 fix (Activity rows
// measure the sentence and stack the trailing block early) over a finer
// sweep of widths and text scales, and over the Activity rows the round 3
// worlds did not have: a payment I made or got (a neutral "Paid" /
// "Received" block), huge JPY, and a deleted expense with its Restore
// button.
//
// Tests named "QA VISUAL-R4-NN" with `skip: true` are failing repros for
// open findings; unskip to verify a fix. The other tests pass and guard the
// fixes.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'visual_harness.dart';

const List<double> kFineScales = [
  1.0,
  1.1,
  1.2,
  1.3,
  1.35,
  1.4,
  1.45,
  1.5,
  1.55,
  1.59,
  1.6,
  2.0,
];

Variant v4(double w, double scale, [Brightness b = Brightness.light]) => (
  size: Size(w, w <= 320 ? 568 : (w < 384 ? 640 : 800)),
  scale: scale,
  brightness: b,
);

double _longestWord(RenderParagraph p) {
  var widest = 0.0;
  for (final word in p.text.toPlainText().split(RegExp(r'\s+'))) {
    final tp = TextPainter(
      text: TextSpan(text: word, style: p.text.style),
      textDirection: p.textDirection,
      textScaler: p.textScaler,
    )..layout();
    if (tp.width > widest) widest = tp.width;
    tp.dispose();
  }
  return widest;
}

/// The RenderEditable under [r].
RenderEditable? _editableIn(RenderObject r) {
  if (r is RenderEditable) return r;
  RenderEditable? out;
  r.visitChildren((c) => out ??= _editableIn(c));
  return out;
}

/// Amount fields on screen whose text does not fit their box: the part
/// of the amount that is scrolled out of sight, in dp, at each end.
List<String> _hiddenAmounts(WidgetTester tester, String where) {
  final out = <String>[];
  for (final e in find.byType(EditableText).evaluate()) {
    final ed = e.widget as EditableText;
    final t = ed.controller.text;
    if (t.isEmpty || !RegExp(r'^[\d.,]+$').hasMatch(t)) continue;
    final re = _editableIn(e.renderObject!)!;
    final start = re.getLocalRectForCaret(const TextPosition(offset: 0)).left;
    final end = re.getLocalRectForCaret(TextPosition(offset: t.length)).left;
    if (start < -1 || end > re.size.width + 1) {
      out.add(
        '$where: "$t" in a ${re.size.width.toStringAsFixed(1)} dp field '
        'hides ${(-start).clamp(0, 1e9).toStringAsFixed(1)} dp at the start '
        'and ${(end - re.size.width).clamp(0, 1e9).toStringAsFixed(1)} dp '
        'at the end',
      );
    }
  }
  return out;
}

/// KitListRows with a trailing block whose title is narrower than its
/// longest word.
List<String> _squeezedTitles(WidgetTester tester, String where) {
  final out = <String>[];
  for (final r in find.byType(KitListRow).evaluate()) {
    final row = r.widget as KitListRow;
    if (row.trailing == null) continue;
    final f = find.descendant(
      of: find.byWidget(row),
      matching: find.text(row.title),
    );
    if (f.evaluate().isEmpty) continue;
    final p = tester.renderObject<RenderParagraph>(f.first);
    final word = _longestWord(p);
    if (p.size.width + 0.5 < word) {
      out.add(
        '$where: "${row.title}" gets ${p.size.width.toStringAsFixed(1)} dp '
        '< its longest word ${word.toStringAsFixed(1)} dp',
      );
    }
  }
  return out;
}

/// A world whose Activity feed has every kind of trailing block: the huge
/// world plus a KWD payment I made at Money.maxMinor, a JPY expense where I
/// lent the most a JPY amount can be, and a deleted expense (Restore).
Future<VisualWorld> _allTrailing() async {
  final w = await VisualWorld.huge();
  final p = w.phone;
  final kwd = p.gs(w.kwdGroup);
  final meK = kwd.members.values.firstWhere((m) => m.personId == p.me).id;
  final samK = kwd.members.values.firstWhere((m) => m.personId != p.me).id;
  await p.pay(
    w.kwdGroup,
    from: meK,
    to: samK,
    amount: Money.maxMinor,
    currency: 'KWD',
  );
  final inr = p.gs(w.group);
  final me = inr.members.values.firstWhere((m) => m.personId == p.me).id;
  final friend = inr.members.values
      .firstWhere((m) => m.personId != p.me && m.displayName != 'Sam')
      .id;
  await p.add(
    w.group,
    total: Money.maxMinor,
    currency: 'JPY',
    payer: me,
    owedBy: SplitSpec.single(friend, Money.maxMinor),
    description: 'Ryokan',
  );
  final gone = await p.add(
    w.group,
    total: 4250,
    payer: me,
    split: [me, friend],
    description: kDesc120,
  );
  await p.ledger.deleteExpense(gone, groupId: w.group);
  return w;
}

/// Every Activity row problem on screen: a sentence or subline narrower
/// than its longest word, or a cut amount.
List<String> _rowProblems(WidgetTester tester, String where) {
  final out = <String>[];
  for (final r in find.byType(KitListRow).evaluate()) {
    final row = r.widget as KitListRow;
    if (row.trailing == null) continue;
    for (final t in [row.title, ?row.subtitle]) {
      final f = find.descendant(of: find.byWidget(row), matching: find.text(t));
      if (f.evaluate().isEmpty) continue;
      final p = tester.renderObject<RenderParagraph>(f.first);
      final word = _longestWord(p);
      if (p.size.width + 0.5 < word) {
        out.add(
          '$where: "$t" gets ${p.size.width.toStringAsFixed(1)} dp < its '
          'longest word ${word.toStringAsFixed(1)} dp',
        );
      }
    }
  }
  for (final c in pureOnly(findCutAmounts(tester))) {
    out.add('$where: $c');
  }
  return out;
}

void main() {
  configureVisualTests();

  for (final (name, build) in [
    ('realistic', VisualWorld.realistic),
    ('long names', VisualWorld.longNames),
    ('every trailing block', _allTrailing),
  ]) {
    testWidgets('Activity rows keep a word beside the amount or stack, '
        'with no overflow ($name world, 320-384 dp, 1.0x-2.0x)', (
      tester,
    ) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await build());
      final problems = <String>[];
      for (final width in const [320.0, 340.0, 360.0, 384.0]) {
        for (final scale in kFineScales) {
          final variant = v4(width, scale);
          for (final loc in [Routes.activity, Routes.groupActivity(w.group)]) {
            final where = '${variantName(variant)} $loc';
            final errors = await collectLayoutErrors(
              () => pumpVisual(tester, w.phone, v: variant, location: loc),
            );
            for (final e in errors.toSet()) {
              problems.add('$where: $e');
            }
            problems.addAll(_rowProblems(tester, where));
            await tester.pumpWidget(const SizedBox.shrink());
          }
        }
      }
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }

  testWidgets('every Activity trailing block is on screen in the world', (
    tester,
  ) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await _allTrailing());
    await pumpVisual(
      tester,
      w.phone,
      v: v4(411, 1.0),
      location: Routes.activity,
    );
    final trailing = [
      for (final r in find.byType(KitListRow).evaluate())
        (r.widget as KitListRow).trailing,
    ].nonNulls.toList();
    expect(trailing.whereType<TextButton>(), isNotEmpty);
    final words = trailing.whereType<BalanceTrailing>().map((b) => b.word);
    expect(words, containsAll([KitStrings.paid, KitStrings.youLent]));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(w.phone.dispose);
  });

  testWidgets('dark theme, KWD group feed: same layout as light', (
    tester,
  ) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await _allTrailing());
    final problems = <String>[];
    for (final scale in const [1.3, 1.45, 1.59]) {
      final variant = v4(320, scale, Brightness.dark);
      final loc = Routes.groupActivity(w.kwdGroup);
      final where = '${variantName(variant)} $loc';
      final errors = await collectLayoutErrors(
        () => pumpVisual(tester, w.phone, v: variant, location: loc),
      );
      for (final e in errors.toSet()) {
        problems.add('$where: $e');
      }
      problems.addAll(_rowProblems(tester, where));
      await tester.pumpWidget(const SizedBox.shrink());
    }
    await tester.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('a stacked Activity row still reads its direction word and '
      'signed amount, and keeps 48 dp labelled targets', (tester) async {
    final handle = tester.ensureSemantics();
    late VisualWorld w;
    await tester.runAsync(() async => w = await _allTrailing());
    await pumpVisual(
      tester,
      w.phone,
      v: v4(320, 1.45),
      location: Routes.activity,
    );
    final stacked = [
      for (final r in find.byType(KitListRow).evaluate())
        if ((r.widget as KitListRow).stackTrailing) r.widget as KitListRow,
    ];
    expect(stacked, isNotEmpty);
    final labels = semanticsLabels(tester).join(' | ');
    expect(labels, contains('paid 99999999.999 KWD'));
    expect(labels, contains('you lent 99999999999 JPY'));
    expect(labels, contains(KitStrings.paid));
    expect(labels.toLowerCase(), contains(KitStrings.youLent.toLowerCase()));
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(w.phone.dispose);
    handle.dispose();
  });

  testWidgets('a stacked Activity row meets text contrast in both themes', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    late VisualWorld w;
    await tester.runAsync(() async => w = await _allTrailing());
    for (final b in Brightness.values) {
      await pumpVisual(
        tester,
        w.phone,
        v: v4(320, 1.45, b),
        location: Routes.activity,
      );
      await expectLater(tester, meetsGuideline(textContrastGuideline));
      await tester.pumpWidget(const SizedBox.shrink());
    }
    await tester.runAsync(w.phone.dispose);
    handle.dispose();
  });

  // ------------------------------------------------------------------
  // New findings, round 4 (skipped repros).
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R4-01: the Sync tether overflows its row at 320-340 dp '
    'between 1.4x and 1.59x',
    skip: true, // QA VISUAL-R4-01
    (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final problems = <String>[];
      for (final variant in [
        v4(320, 1.4),
        v4(320, 1.5),
        v4(320, 1.59),
        v4(340, 1.55),
        v4(320, 1.5, Brightness.dark),
      ]) {
        final errors = await collectLayoutErrors(
          () => pumpVisual(tester, w.phone, v: variant, location: Routes.sync),
        );
        for (final e in errors.toSet()) {
          problems.add('${variantName(variant)} sync: $e');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  testWidgets(
    'QA VISUAL-R4-02: the expense amount field hides part of a realistic '
    'amount (₹1,20,000.50 at 320 dp 1.0x, 360 dp 1.3x)',
    skip: true, // QA VISUAL-R4-02
    (tester) async {
      final problems = <String>[];
      for (final build in [VisualWorld.realistic, VisualWorld.longNames]) {
        late VisualWorld w;
        await tester.runAsync(() async => w = await build());
        for (final variant in [v4(320, 1.0), v4(360, 1.3), v4(360, 2.0)]) {
          // Editing a saved expense: the field opens on the amount.
          await pumpVisual(
            tester,
            w.phone,
            v: variant,
            location: Routes.editExpense(w.expense),
          );
          final scope = find.byType(AmountField);
          expect(scope, findsOneWidget);
          problems.addAll(
            _hiddenAmounts(tester, '${variantName(variant)} edit expense'),
          );
          await tester.pumpWidget(const SizedBox.shrink());
        }
        await tester.runAsync(w.phone.dispose);
      }
      // Typing a new one: the caret follows the end, so the start goes.
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      for (final variant in [v4(320, 1.0), v4(360, 1.3)]) {
        await pumpVisual(
          tester,
          w.phone,
          v: variant,
          location: Routes.newExpense(groupId: w.group),
        );
        final field = find.descendant(
          of: find.byType(AmountField),
          matching: find.byType(EditableText),
        );
        await tester.enterText(field, '120000.50');
        await tester.pump();
        problems.addAll(
          _hiddenAmounts(tester, '${variantName(variant)} new expense, typed'),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  testWidgets(
    'QA VISUAL-R4-03: expense editor split rows break the share amount over '
    'two lines and the 112 dp share field hides digits',
    skip: true, // QA VISUAL-R4-03
    (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final problems = <String>[];
      for (final variant in [v4(320, 1.0), v4(360, 1.45), v4(411, 1.0)]) {
        final where = '${variantName(variant)} edit expense';
        await pumpVisual(
          tester,
          w.phone,
          v: variant,
          location: Routes.editExpense(w.expense),
        );
        // Bring the split rows on screen.
        await tester.scrollUntilVisible(
          find.text('Priya'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump();
        for (final e in find.byType(RichText).evaluate()) {
          final p = e.renderObject as RenderParagraph;
          final t = p.text.toPlainText();
          if (!t.contains('₹') || !RegExp(r'\d').hasMatch(t)) continue;
          final word = p.getMinIntrinsicWidth(double.infinity);
          if (p.size.width + 0.5 < word) {
            problems.add(
              '$where: "$t" broken over lines '
              '(box ${p.size.width.toStringAsFixed(1)} < '
              '${word.toStringAsFixed(1)})',
            );
          }
        }
        problems.addAll(
          _hiddenAmounts(tester, where).where((p) => p.contains('120000.50')),
        );
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  testWidgets(
    'QA VISUAL-R4-04: expense detail "Who paid / Who owes" rows squeeze the '
    'name below one word, to 0 dp, and overflow with huge amounts',
    skip: true, // QA VISUAL-R4-04
    (tester) async {
      final problems = <String>[];
      for (final (build, variants) in [
        (VisualWorld.realistic, [v4(320, 1.59)]),
        (VisualWorld.longNames, [v4(320, 1.3), v4(360, 1.45)]),
        (VisualWorld.huge, [v4(320, 1.3), v4(320, 1.59), v4(360, 1.59)]),
      ]) {
        late VisualWorld w;
        await tester.runAsync(() async => w = await build());
        for (final variant in variants) {
          final where = '${variantName(variant)} expense detail';
          final errors = await collectLayoutErrors(
            () => pumpVisual(
              tester,
              w.phone,
              v: variant,
              location: Routes.expense(w.expense),
            ),
          );
          for (final e in errors.toSet()) {
            problems.add('$where: $e');
          }
          problems.addAll(_squeezedTitles(tester, where));
          await tester.pumpWidget(const SizedBox.shrink());
        }
        await tester.runAsync(w.phone.dispose);
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );

  testWidgets(
    'QA VISUAL-R4-05: Home and Person balance rows squeeze the group name '
    'below one word at 320-360 dp, 1.3x to 1.59x',
    skip: true, // QA VISUAL-R4-05
    (tester) async {
      final problems = <String>[];
      for (final (build, variants) in [
        (VisualWorld.realistic, [v4(320, 1.59)]),
        (VisualWorld.longNames, [v4(320, 1.59)]),
        (VisualWorld.huge, [v4(320, 1.3), v4(320, 1.45), v4(360, 1.59)]),
      ]) {
        late VisualWorld w;
        await tester.runAsync(() async => w = await build());
        for (final variant in variants) {
          for (final (name, loc) in [
            ('home', Routes.home),
            ('person', Routes.person(w.person)),
          ]) {
            await pumpVisual(tester, w.phone, v: variant, location: loc);
            problems.addAll(
              _squeezedTitles(tester, '${variantName(variant)} $name'),
            );
            await tester.pumpWidget(const SizedBox.shrink());
          }
        }
        await tester.runAsync(w.phone.dispose);
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );
}
