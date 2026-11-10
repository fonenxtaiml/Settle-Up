// QA VISUAL round 1: failing repros for layout defects, over the real
// Ledger and the real app. Each one is skipped with its finding id so the
// suite stays green; unskip to verify a fix.
//
// testWidgets only takes a bool skip, so the id is in the test name and in
// the comment next to `skip: true`.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/ui/format/money_format.dart';
import 'package:settle_up/ui/router.dart';

import 'visual_harness.dart';

const Variant small13 = (
  size: Size(320, 568),
  scale: 1.3,
  brightness: Brightness.light,
);
const Variant mid10 = (
  size: Size(360, 640),
  scale: 1.0,
  brightness: Brightness.light,
);
const Variant mid13 = (
  size: Size(360, 640),
  scale: 1.3,
  brightness: Brightness.light,
);
const Variant mid20 = (
  size: Size(360, 640),
  scale: 2.0,
  brightness: Brightness.light,
);
const Variant small20 = (
  size: Size(320, 568),
  scale: 2.0,
  brightness: Brightness.dark,
);

/// Paragraphs containing [needle] that were ellipsized or clipped.
List<String> cutContaining(WidgetTester tester, String needle) => [
  for (final e in find.byType(RichText).evaluate())
    if (e.renderObject case final RenderParagraph p
        when p.text.toPlainText().contains(needle) && p.didExceedMaxLines)
      p.text.toPlainText(),
];

void main() {
  configureVisualTests();

  testWidgets(
    'QA VISUAL-R1-01: expense detail total is clipped, not scaled down',
    (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      // ₹1,20,000.50 on a 360 dp phone at the default text size.
      await pumpVisual(
        tester,
        w.phone,
        v: mid10,
        location: Routes.expense(w.expense),
      );
      expect(
        pureOnly(findCutAmounts(tester)),
        isEmpty,
        reason: 'the 46 dp total must fit (FittedBox) or wrap, never clip',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      // A ₹200 payment at text scale 2.0 is clipped as well.
      await pumpVisual(
        tester,
        w.phone,
        v: mid20,
        location: Routes.expense(w.payment),
      );
      expect(pureOnly(findCutAmounts(tester)), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(w.phone.dispose);
    },
  );

  testWidgets(
    'QA VISUAL-R1-02: Home hero "Coming to you" amount is clipped at 2.0x',
    (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      await pumpVisual(tester, w.phone, v: mid20, location: Routes.home);
      final coming = MoneyFormat.format(12000050, 'INR', signed: true);
      expect(visibleTexts(tester), contains(coming));
      expect(
        pureOnly(findCutAmounts(tester)).map((c) => c.text),
        isNot(contains(coming)),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(w.phone.dispose);
    },
  );

  testWidgets(
    'QA VISUAL-R1-03: suggested payment row overflows at 320 dp, 1.3x',
    (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      for (final loc in [
        Routes.group(w.group),
        Routes.group(w.kwdGroup),
        Routes.settle(groupId: w.group),
      ]) {
        final r = await inspect(tester, w, small13, loc);
        expect(r.errors, isEmpty, reason: loc);
      }
      await tester.runAsync(w.phone.dispose);
    },
  );

  testWidgets(
    'QA VISUAL-R1-04: Settle up "What changes" clips KD1,250.750 at 1.3x',
    (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final r = await inspect(
        tester,
        w,
        mid13,
        Routes.settle(groupId: w.kwdGroup),
      );
      expect(pureOnly(r.cut), isEmpty);
      await tester.runAsync(w.phone.dispose);
    },
  );

  testWidgets(
    'QA VISUAL-R1-05: expense editor app bar overflows with a long group name',
    (tester) async {
      // The group editor allows 60 characters; 39 is enough at 320 dp, 1.3x.
      for (final (name, v) in [
        (kGroup60, mid10),
        ('Annual family trip to Kerala backwaters', small13),
      ]) {
        late VisualWorld w;
        await tester.runAsync(
          () async => w = await VisualWorld.build(groupName: name),
        );
        for (final loc in [
          Routes.editExpense(w.expense),
          Routes.newExpense(groupId: w.group),
        ]) {
          final r = await inspect(tester, w, v, loc);
          expect(r.errors, isEmpty, reason: '$loc ${variantName(v)}');
        }
        await tester.runAsync(w.phone.dispose);
      }
    },
  );

  testWidgets(
    'QA VISUAL-R1-06: expense row subline hides "Sam paid ¥5,000" at 1.3x',
    (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      await pumpVisual(
        tester,
        w.phone,
        v: mid13,
        location: Routes.group(w.group),
      );
      expect(cutContaining(tester, ' paid '), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(w.phone.dispose);
    },
  );

  testWidgets(
    'QA VISUAL-R1-07: group app bar "N people, ₹X spent" is cut at 2.0x',
    (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      await pumpVisual(
        tester,
        w.phone,
        v: mid20,
        location: Routes.group(w.group),
      );
      expect(cutContaining(tester, ' spent'), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(w.phone.dispose);
    },
  );

  testWidgets(
    'QA VISUAL-R1-08: Activity amounts at Money.maxMinor clip at 320 dp, 2.0x',
    (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.huge());
      final r = await inspect(tester, w, small20, Routes.activity);
      expect(pureOnly(r.cut), isEmpty);
      await tester.runAsync(w.phone.dispose);
    },
  );

  // Sanity for the repro inputs (runs): the amounts are what the findings
  // quote.
  test('repro amounts', () {
    expect(MoneyFormat.format(12000050, 'INR', signed: true), '+₹1,20,000.50');
    expect(MoneyFormat.format(Money.maxMinor, 'INR'), '₹99,99,99,999.99');
  });
}
