// QA VISUAL: empty states on Home, Group, Activity, Search and Sync, at
// every size, text scale and theme, over a freshly onboarded real Ledger.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'visual_harness.dart';

Future<void> searchFor(WidgetTester tester, String q) async {
  await tester.enterText(find.byType(TextField).first, q);
  await settleFrames(tester);
}

void main() {
  configureVisualTests();

  testWidgets('empty states show their copy and fit everywhere', (
    tester,
  ) async {
    late VisualPhone p;
    late String g;
    await tester.runAsync(() async {
      p = await VisualPhone.create();
      g = (await p.group('Goa trip', ['Priya'])).g;
    });
    // A second phone with no groups at all.
    late VisualPhone fresh;
    await tester.runAsync(() async => fresh = await VisualPhone.create());

    final problems = <String>[];
    for (final v in kVariants) {
      Future<void> check(
        VisualPhone phone,
        String name,
        String location,
        String expected, {
        Future<void> Function()? then,
      }) async {
        final errors = await collectLayoutErrors(() async {
          await pumpVisual(tester, phone, v: v, location: location);
          if (then != null) await then();
        });
        if (errors.isNotEmpty) problems.add('${variantName(v)} $name $errors');
        final target = find.textContaining(expected);
        if (target.evaluate().isEmpty &&
            find.byType(Scrollable).evaluate().isNotEmpty) {
          // Lazy lists build what is on screen; scroll to it.
          await tester.scrollUntilVisible(
            target,
            100,
            scrollable: find.byType(Scrollable).last,
            maxScrolls: 30,
          );
        }
        if (target.evaluate().isEmpty) {
          problems.add('${variantName(v)} $name: "$expected" not shown');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }

      await check(fresh, 'home', Routes.home, S.homeEmptyHeadline);
      await check(fresh, 'activity', Routes.activity, S.activityEmptyHeadline);
      await check(p, 'group', Routes.group(g), S.groupEmptyHeadline);
      await check(fresh, 'sync', Routes.sync, S.noneNearbyHeadline);
      await check(fresh, 'search', Routes.search, S.searchPrompt);
      // 320 dp at 2.0x is VISUAL-R1-12 (repro below).
      if (v.size.width == 320 && v.scale == 2.0) continue;
      await check(
        p,
        'search none',
        Routes.search,
        S.searchNoneBody,
        then: () => searchFor(tester, 'zz'),
      );
    }
    await tester.runAsync(() async {
      await p.dispose();
      await fresh.dispose();
    });
    expect(problems, isEmpty);
  });

  testWidgets('empty Home offers one way forward: create a group', (
    tester,
  ) async {
    late VisualPhone p;
    await tester.runAsync(() async => p = await VisualPhone.create());
    await pumpVisual(
      tester,
      p,
      v: (size: const Size(360, 640), scale: 1.0, brightness: Brightness.light),
    );
    expect(find.byType(EmptyState), findsOneWidget);
    expect(find.text(S.createGroup), findsWidgets);
    // No balances or hero without data.
    expect(find.byType(BalanceHero), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(p.dispose);
  });

  testWidgets(
    'QA VISUAL-R1-12: Search "no results" overflows and hides Clear search',
    (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final problems = <String>[];
      for (final (q, v) in [
        // A typo'd description pasted into search, on a small phone.
        (
          kDesc120,
          (
            size: const Size(320, 568),
            scale: 1.3,
            brightness: Brightness.light,
          ),
        ),
        (
          'zzz',
          (size: const Size(320, 568), scale: 2.0, brightness: Brightness.dark),
        ),
      ]) {
        final errors = await collectLayoutErrors(() async {
          await pumpVisual(tester, w.phone, v: v, location: Routes.search);
          await searchFor(tester, q);
        });
        if (errors.isNotEmpty) problems.add('${variantName(v)} "$q" $errors');
        await tester.pumpWidget(const SizedBox.shrink());
      }
      // Everyday case: 360 dp phone, default text, keyboard open (search
      // autofocuses), a short query with no match.
      tester.view.viewInsets = const FakeViewPadding(bottom: 280 * 3);
      final errors = await collectLayoutErrors(() async {
        await pumpVisual(
          tester,
          w.phone,
          v: (
            size: const Size(360, 640),
            scale: 1.0,
            brightness: Brightness.light,
          ),
          location: Routes.search,
        );
        await searchFor(tester, 'zzz');
      });
      if (errors.isNotEmpty) problems.add('360x640 keyboard "zzz" $errors');
      await tester.pumpWidget(const SizedBox.shrink());
      tester.view.resetViewInsets();
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty);
    },
  );
}
