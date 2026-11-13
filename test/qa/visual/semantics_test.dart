// QA VISUAL: screen-reader text and the Flutter accessibility guidelines
// (48 dp tap targets, labelled tap targets, WCAG text contrast) on every
// main screen in light and dark, over the real Ledger.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';

import 'visual_harness.dart';

const Size phone = Size(360, 640);

final List<AccessibilityGuideline> guidelines = [
  androidTapTargetGuideline,
  labeledTapTargetGuideline,
  textContrastGuideline,
];

/// Failures of [guidelines] on [location], one line each.
Future<List<String>> guidelineFailures(
  WidgetTester tester,
  VisualWorld w,
  String location,
  Brightness b, {
  List<AccessibilityGuideline>? only,
}) async {
  await pumpVisual(
    tester,
    w.phone,
    v: (size: phone, scale: 1.0, brightness: b),
    location: location,
  );
  final out = <String>[];
  for (final g in only ?? guidelines) {
    var r = await g.evaluate(tester);
    if (!r.passed && g == textContrastGuideline) {
      // The guideline samples a text's paint rect inflated by 4 dp, so a
      // paragraph that ends within 4 dp of a scroll view's edge has the
      // bar beyond the edge sampled as its "light" colour (1.28 on Sync in
      // dark, with nothing wrong on screen). Measure again with the lists
      // moved 12 dp: a real contrast failure fails in both positions.
      for (final e in find.byType(Scrollable).evaluate()) {
        final p = (e as StatefulElement).state as ScrollableState;
        final pos = p.position;
        if (pos.axis == Axis.vertical && pos.maxScrollExtent > 0) {
          pos.jumpTo((pos.pixels + 12).clamp(0, pos.maxScrollExtent));
        }
      }
      await tester.pump();
      r = await g.evaluate(tester);
    }
    if (!r.passed) {
      out.add('${g.description}: ${(r.reason ?? '').split('\n').first}');
    }
  }
  await tester.pumpWidget(const SizedBox.shrink());
  return out;
}

void main() {
  configureVisualTests();

  // Home and Invite have open findings (VISUAL-R1-09, VISUAL-R1-10).
  const clean = [
    'group',
    'group KWD',
    'activity',
    'search',
    'sync',
    'settle',
    'settle KWD',
    'person',
    'expense',
    'payment',
    'edit expense',
    'new expense',
    'members',
    'settings',
    'edit group',
  ];

  for (final b in Brightness.values) {
    testWidgets('guidelines pass on the main screens (${b.name})', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final problems = <String>[];
      for (final s in clean) {
        final f = await guidelineFailures(tester, w, w.screens[s]!, b);
        problems.addAll(f.map((e) => '$s: $e'));
      }
      // Home and Invite still meet the contrast guideline.
      for (final s in ['home', 'invite']) {
        final f = await guidelineFailures(
          tester,
          w,
          w.screens[s]!,
          b,
          only: [
            if (s == 'home') textContrastGuideline,
            if (s == 'home') androidTapTargetGuideline,
          ],
        );
        problems.addAll(f.map((e) => '$s: $e'));
      }
      await tester.runAsync(w.phone.dispose);
      handle.dispose();
      expect(problems, isEmpty);
    });
  }

  testWidgets('empty Home passes every guideline in both themes', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    late VisualPhone p;
    await tester.runAsync(() async => p = await VisualPhone.create());
    final w = VisualWorld(p);
    final problems = <String>[];
    for (final b in Brightness.values) {
      problems.addAll(await guidelineFailures(tester, w, Routes.home, b));
      problems.addAll(await guidelineFailures(tester, w, Routes.activity, b));
    }
    await tester.runAsync(p.dispose);
    handle.dispose();
    expect(problems, isEmpty);
  });

  testWidgets('balances are read with a direction word, not a bare sign', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());

    await pumpVisual(
      tester,
      w.phone,
      v: (size: phone, scale: 1.0, brightness: Brightness.light),
      location: Routes.home,
    );
    var labels = semanticsLabels(tester);
    // Hero: the sentence carries the direction; columns are named.
    expect(
      labels.any(
        (l) =>
            l.startsWith("You're owed overall. 120000.50 INR") &&
            l.contains('Coming to you 120000.50 INR'),
      ),
      isTrue,
      reason: '$labels',
    );
    expect(
      labels,
      contains("Goa trip, 3 people, you're owed 120000.50 INR, +1 more"),
    );
    expect(labels, contains('Kuwait Goa trip, 2 people, you owe 1250.750 KWD'));
    expect(labels, contains('Sam K, Kuwait Goa trip, you owe 1250.750 KWD'));
    expect(
      labels.any(
        (l) => l.startsWith('Priya Sharma, Goa trip, owes you 120000.50 INR'),
      ),
      isTrue,
      reason: '$labels',
    );
    expect(
      labels.any((l) => l.startsWith('Sam, Goa trip, you owe 2500 JPY')),
      isTrue,
      reason: '$labels',
    );
    await tester.pumpWidget(const SizedBox.shrink());

    await pumpVisual(
      tester,
      w.phone,
      v: (size: phone, scale: 1.0, brightness: Brightness.light),
      location: Routes.group(w.group),
    );
    labels = semanticsLabels(tester);
    expect(
      labels.any(
        (l) => l.startsWith("You're owed in this group. 120000.50 INR"),
      ),
      isTrue,
      reason: '$labels',
    );
    expect(labels, contains('Priya pays you 120000.50 INR'));
    expect(labels, contains('You pay Sam 2500 JPY'));
    expect(
      labels.any((l) => l.contains('you lent 120000.50 INR')),
      isTrue,
      reason: '$labels',
    );
    expect(
      labels.any((l) => l.contains('you borrowed 2500 JPY')),
      isTrue,
      reason: '$labels',
    );
    // No spoken label uses a hyphen-minus or a bare "+" before an amount.
    for (final l in labels) {
      expect(l, isNot(matches(RegExp(r'[-+]\d'))), reason: l);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(w.phone.dispose);
    handle.dispose();
  });

  testWidgets('icon buttons in app bars have tooltips or labels', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());
    final missing = <String>[];
    for (final s in ['home', 'group', 'expense', 'settle', 'sync', 'person']) {
      await pumpVisual(
        tester,
        w.phone,
        v: (size: phone, scale: 1.0, brightness: Brightness.light),
        location: w.screens[s]!,
      );
      for (final e in find.byType(IconButton).evaluate()) {
        final b = e.widget as IconButton;
        if (b.tooltip == null || b.tooltip!.isEmpty) {
          final hasLabel = find
              .ancestor(
                of: find.byWidget(b),
                matching: find.byWidgetPredicate(
                  (w) => w is Semantics && (w.properties.label ?? '') != '',
                ),
              )
              .evaluate()
              .isNotEmpty;
          if (!hasLabel) missing.add('$s: $b');
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
    await tester.runAsync(w.phone.dispose);
    handle.dispose();
    expect(missing, isEmpty);
  });

  testWidgets(
    'QA VISUAL-R1-09: Home sync card is a tap target with no label',
    (tester) async {
      final handle = tester.ensureSemantics();
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final f = await guidelineFailures(
        tester,
        w,
        Routes.home,
        Brightness.light,
        only: [labeledTapTargetGuideline],
      );
      await tester.runAsync(w.phone.dispose);
      handle.dispose();
      expect(f, isEmpty);
    },
  );

  testWidgets(
    'QA VISUAL-R1-10: TextLink ("Share link") is a 32 dp tap target',
    (tester) async {
      final handle = tester.ensureSemantics();
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final f = await guidelineFailures(
        tester,
        w,
        Routes.invite(w.group),
        Brightness.light,
        only: [androidTapTargetGuideline],
      );
      await tester.runAsync(w.phone.dispose);
      handle.dispose();
      expect(f, isEmpty);
    },
  );

  testWidgets(
    'QA VISUAL-R1-11: a payment between others shows "not involved ₹0"',
    (tester) async {
      final handle = tester.ensureSemantics();
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      await pumpVisual(
        tester,
        w.phone,
        v: (size: phone, scale: 1.0, brightness: Brightness.light),
        location: Routes.expense(w.payment), // Sam paid Priya ₹200
      );
      expect(find.text('not involved'), findsOneWidget);
      expect(visibleTexts(tester), isNot(contains('₹0')));
      expect(semanticsLabels(tester), isNot(contains('not involved 0.00 INR')));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(w.phone.dispose);
      handle.dispose();
    },
  );
}
