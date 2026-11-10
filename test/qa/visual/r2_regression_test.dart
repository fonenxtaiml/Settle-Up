// QA VISUAL round 2: reverification of the round 1 fixes and a regression
// sweep around the changed code (amounts that scale down, rows whose
// trailing block is capped, 48 dp text links, still spinners).
//
// Tests named "QA VISUAL-R1-NN" or "QA VISUAL-R2-NN" with `skip: true` are
// failing repros for open findings; unskip to verify a fix. The other tests
// pass and guard the fixes.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'visual_harness.dart';

Variant v(double w, double scale, [Brightness b = Brightness.light]) =>
    (size: Size(w, w == 320 ? 568 : 640), scale: scale, brightness: b);

/// Paragraphs under [scope] that are narrower than their longest word, so
/// a word is broken across lines or cut ("borrowe/d", "Cas", "Hom/e"), or
/// that were ellipsized.
List<String> brokenOrCut(WidgetTester tester, Finder scope) {
  final out = <String>[];
  final paragraphs = find.descendant(
    of: scope,
    matching: find.byType(RichText),
  );
  for (final e in paragraphs.evaluate()) {
    final ro = e.renderObject;
    if (ro is! RenderParagraph || !ro.hasSize || !ro.attached) continue;
    final t = ro.text.toPlainText();
    if (t.trim().isEmpty) continue;
    final word = ro.getMinIntrinsicWidth(double.infinity);
    if (ro.didExceedMaxLines) {
      out.add('"$t" cut (box ${ro.size.width.toStringAsFixed(1)})');
    } else if (ro.size.width + 0.5 < word) {
      out.add(
        '"$t" word broken (box ${ro.size.width.toStringAsFixed(1)} < '
        'word ${word.toStringAsFixed(1)})',
      );
    }
  }
  return out;
}

/// Single-word labels (no space) anywhere on screen that are narrower than
/// the word: the word is broken or clipped.
List<String> brokenLabels(WidgetTester tester, Set<String> labels) => [
  for (final e in find.byType(RichText).evaluate())
    if (e.renderObject case final RenderParagraph p
        when p.hasSize &&
            labels.contains(p.text.toPlainText()) &&
            p.size.width + 0.5 < p.getMinIntrinsicWidth(double.infinity))
      '"${p.text.toPlainText()}" box ${p.size.width.toStringAsFixed(1)} < '
          'word ${p.getMinIntrinsicWidth(double.infinity).toStringAsFixed(1)}',
];

/// Paragraphs containing [needle] that were ellipsized or clipped.
List<String> cutContaining(WidgetTester tester, String needle) => [
  for (final e in find.byType(RichText).evaluate())
    if (e.renderObject case final RenderParagraph p
        when p.text.toPlainText().contains(needle) && p.didExceedMaxLines)
      p.text.toPlainText(),
];

bool animating(WidgetTester tester) =>
    tester.binding.transientCallbackCount > 0;

void main() {
  configureVisualTests();

  // ------------------------------------------------------------------
  // Guards for the round 1 fixes (pass).
  // ------------------------------------------------------------------

  testWidgets('VISUAL-R1-07: "₹X spent" is never cut, any size or theme '
      '(realistic and long-name worlds; Money.maxMinor INR)', (tester) async {
    final problems = <String>[];
    for (final (build, kwd) in [
      (VisualWorld.realistic, true),
      (VisualWorld.longNames, true),
      // KD999,999.999 at 320 dp, 1.3x+ is QA VISUAL-R2-07 below.
      (VisualWorld.huge, false),
    ]) {
      late VisualWorld w;
      await tester.runAsync(() async => w = await build());
      for (final variant in kVariants) {
        // Since UIFLOW-R2-04 the huge INR total is ₹99,99,99,999.99: at
        // 320 dp, 1.3x+ that is the short-form cut of QA VISUAL-R2-07 below.
        final r207 = !kwd && variant.size.width == 320 && variant.scale > 1;
        for (final loc in [
          if (!r207) Routes.group(w.group),
          if (kwd) Routes.group(w.kwdGroup),
        ]) {
          await pumpVisual(tester, w.phone, v: variant, location: loc);
          for (final c in cutContaining(tester, ' spent')) {
            problems.add('${variantName(variant)} $loc: $c');
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
      await tester.runAsync(w.phone.dispose);
    }
    expect(problems, isEmpty);
  });

  testWidgets('VISUAL-R1-06: on a 360 dp phone the "X paid ¥Y" subline is '
      'never cut, at every text scale', (tester) async {
    final problems = <String>[];
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());
    for (final variant in kVariants.where((x) => x.size.width == 360)) {
      for (final loc in [
        Routes.group(w.group),
        Routes.group(w.kwdGroup),
        Routes.person(w.person),
      ]) {
        await pumpVisual(tester, w.phone, v: variant, location: loc);
        for (final c in cutContaining(tester, ' paid ')) {
          problems.add('${variantName(variant)} $loc: $c');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
    await tester.runAsync(w.phone.dispose);
    expect(problems, isEmpty);
  });

  testWidgets('VISUAL-R1-11: an expense (not only a payment) between others '
      'reads "not involved" with no amount', (tester) async {
    final handle = tester.ensureSemantics();
    late VisualPhone p;
    late String eid;
    await tester.runAsync(() async {
      p = await VisualPhone.create(name: 'Arjun Mehta');
      final a = await p.group('Goa trip', ['Priya', 'Sam']);
      eid = await p.add(
        a.g,
        total: 90000,
        payer: a.m['Sam']!,
        split: [a.m['Sam']!, a.m['Priya']!],
      );
    });
    await pumpVisual(tester, p, v: v(360, 1.0), location: Routes.expense(eid));
    final labels = semanticsLabels(tester);
    expect(labels, contains('not involved'));
    expect(labels.where((l) => l.startsWith('not involved ')), isEmpty);
    expect(visibleTexts(tester), isNot(contains('₹0')));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(p.dispose);
    handle.dispose();
  });

  for (final b in Brightness.values) {
    testWidgets('VISUAL-R1-09/R1-10: tap targets are 48 dp and labelled on '
        'every screen at 1.0, 1.3 and 2.0x (${b.name})', (tester) async {
      final handle = tester.ensureSemantics();
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final screens = {
        ...w.screens,
        'host': Routes.syncHost,
        'claim': Routes.claim(w.group),
        'new group': Routes.newGroup,
        'group activity': Routes.groupActivity(w.group),
      };
      final problems = <String>[];
      for (final scale in const [1.0, 1.3, 2.0]) {
        for (final s in screens.entries) {
          await pumpVisual(
            tester,
            w.phone,
            v: v(360, scale, b),
            location: s.value,
          );
          for (final g in [
            androidTapTargetGuideline,
            labeledTapTargetGuideline,
          ]) {
            final r = await g.evaluate(tester);
            if (!r.passed) {
              problems.add(
                '$scale ${s.key}: ${(r.reason ?? '').split('\n').first}',
              );
            }
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
      await tester.runAsync(w.phone.dispose);
      handle.dispose();
      expect(problems, isEmpty);
    });
  }

  testWidgets('VISUAL-R1-10: onboarding links are 48 dp, labelled tap '
      'targets at 1.0 and 2.0x', (tester) async {
    final handle = tester.ensureSemantics();
    late VisualPhone p;
    await tester.runAsync(
      () async => p = await VisualPhone.create(onboard: false),
    );
    final problems = <String>[];
    for (final scale in const [1.0, 2.0]) {
      await pumpVisual(
        tester,
        p,
        v: v(320, scale),
        location: Routes.onboarding,
      );
      for (final g in [androidTapTargetGuideline, labeledTapTargetGuideline]) {
        final r = await g.evaluate(tester);
        if (!r.passed) {
          problems.add('$scale: ${(r.reason ?? '').split('\n').first}');
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
    await tester.runAsync(p.dispose);
    handle.dispose();
    expect(problems, isEmpty);
  });

  testWidgets('VISUAL-R1-09: the stacked sync card at 2.0x is one labelled '
      'button plus its own Sync button', (tester) async {
    final handle = tester.ensureSemantics();
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());
    await pumpVisual(
      tester,
      w.phone,
      v: v(320, 2.0, Brightness.dark),
      location: Routes.home,
    );
    for (final g in [androidTapTargetGuideline, labeledTapTargetGuideline]) {
      final r = await g.evaluate(tester);
      expect(r.passed, isTrue, reason: r.reason);
    }
    final labels = semanticsLabels(tester);
    expect(labels.where((l) => l.startsWith('Sync, ')), hasLength(1));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(w.phone.dispose);
    handle.dispose();
  });

  testWidgets('VISUAL-R1-13: the session strip and loading spinners are '
      'still under reduce motion', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: const Scaffold(
            body: Column(
              children: [
                SizedBox.square(dimension: 20, child: KitSpinner()),
                NearbyPhoneRow(
                  name: "Priya's Pixel 8",
                  subtitle: 'Goa trip',
                  action: NearbyPhoneAction.busy,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 100));
    expect(animating(tester), isFalse);
  });

  // ------------------------------------------------------------------
  // Reopened round 1 findings (skipped repros).
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R1-03: suggested payment sentence is squeezed to one letter '
    '("P", "Y") at 320 dp, 1.3x',
    (tester) async {
      final problems = <String>[];
      for (final (build, variant) in [
        (VisualWorld.realistic, v(320, 1.3)),
        (VisualWorld.realistic, v(360, 1.3)),
        (VisualWorld.longNames, v(320, 1.0)),
      ]) {
        late VisualWorld w;
        await tester.runAsync(() async => w = await build());
        for (final loc in [
          Routes.group(w.group),
          Routes.group(w.kwdGroup),
          Routes.settle(groupId: w.group),
        ]) {
          await pumpVisual(tester, w.phone, v: variant, location: loc);
          for (final row in find.byType(TransferRow).evaluate()) {
            final scope = find.byWidget(row.widget);
            for (final c in brokenOrCut(tester, scope)) {
              problems.add('${variantName(variant)} $loc: $c');
            }
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
        await tester.runAsync(w.phone.dispose);
      }
      expect(problems, isEmpty);
    },
    skip: true, // QA VISUAL-R1-03 (reopened)
  );

  testWidgets(
    'QA VISUAL-R1-05: expense editor title is cut to "Edit ex…" at 320 dp, '
    '1.3x',
    (tester) async {
      final problems = <String>[];
      for (final (name, variant) in [
        ('Annual family trip to Kerala backwaters', v(320, 1.3)),
        (kGroup60, v(320, 1.3)),
      ]) {
        late VisualWorld w;
        await tester.runAsync(
          () async => w = await VisualWorld.build(groupName: name),
        );
        for (final (loc, title) in [
          (Routes.editExpense(w.expense), 'Edit expense'),
          (Routes.newExpense(groupId: w.group), 'Add expense'),
        ]) {
          await pumpVisual(tester, w.phone, v: variant, location: loc);
          for (final e in find.byType(RichText).evaluate()) {
            if (e.renderObject case final RenderParagraph p
                when p.text.toPlainText() == title && p.didExceedMaxLines) {
              problems.add('${variantName(variant)} "$name": "$title" cut');
            }
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
        await tester.runAsync(w.phone.dispose);
      }
      expect(problems, isEmpty);
    },
    skip: true, // QA VISUAL-R1-05 (reopened)
  );

  testWidgets(
    'QA VISUAL-R1-06: on a 320 dp phone the subline still cuts the amount '
    '("You paid ₹1,20,000.…", "Sam paid KD1,250.7…")',
    (tester) async {
      final problems = <String>[];
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      for (final variant in [v(320, 1.0), v(320, 1.3)]) {
        for (final loc in [Routes.group(w.group), Routes.group(w.kwdGroup)]) {
          await pumpVisual(tester, w.phone, v: variant, location: loc);
          for (final c in cutContaining(tester, ' paid ')) {
            problems.add('${variantName(variant)} $loc: $c');
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty);
    },
    skip: true, // QA VISUAL-R1-06 (reopened)
  );

  // ------------------------------------------------------------------
  // New findings, round 2 (skipped repros).
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R2-01: expense row direction word is broken mid-word '
    '("you borrowe/d") at 320 dp, 1.3x',
    (tester) async {
      final problems = <String>[];
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      for (final loc in [Routes.group(w.group), Routes.group(w.kwdGroup)]) {
        await pumpVisual(tester, w.phone, v: v(320, 1.3), location: loc);
        for (final row in find.byType(BalanceTrailing).evaluate()) {
          for (final c in brokenOrCut(tester, find.byWidget(row.widget))) {
            problems.add('$loc: $c');
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty);
    },
    skip: true, // QA VISUAL-R2-01
  );

  testWidgets(
    'QA VISUAL-R2-02: Settle up "How you paid" clips "Cash" to "Cas" on a '
    '360 dp phone at 1.0x',
    (tester) async {
      final problems = <String>[];
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      for (final variant in [v(360, 1.0), v(320, 1.0), v(360, 1.3)]) {
        await pumpVisual(
          tester,
          w.phone,
          v: variant,
          location: Routes.settle(groupId: w.kwdGroup),
        );
        for (final c in brokenLabels(tester, {
          'UPI',
          'Cash',
          'Bank',
          'Other',
        })) {
          problems.add('${variantName(variant)}: $c');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty);
    },
    skip: true, // QA VISUAL-R2-02
  );

  testWidgets(
    'QA VISUAL-R2-03: group type segments break mid-word ("Hom/e", '
    '"Cou/ple", "Othe/r") at large text',
    (tester) async {
      final problems = <String>[];
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      for (final variant in [v(360, 2.0), v(320, 1.3)]) {
        for (final loc in [Routes.editGroup(w.group), Routes.newGroup]) {
          await pumpVisual(tester, w.phone, v: variant, location: loc);
          for (final c in brokenLabels(tester, {
            'Trip',
            'Home',
            'Couple',
            'Other',
          })) {
            problems.add('${variantName(variant)} $loc: $c');
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty);
    },
    skip: true, // QA VISUAL-R2-03
  );

  testWidgets(
    'QA VISUAL-R2-04: hero buttons break mid-word at 2.0x ("All bal/ances", '
    '"Add expens/e")',
    (tester) async {
      final problems = <String>[];
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      for (final variant in [v(360, 2.0), v(320, 2.0)]) {
        for (final loc in [Routes.group(w.group), Routes.person(w.person)]) {
          await pumpVisual(tester, w.phone, v: variant, location: loc);
          for (final b in [
            ...find.byType(FilledButton).evaluate(),
            ...find.byType(OutlinedButton).evaluate(),
          ]) {
            for (final c in brokenOrCut(tester, find.byWidget(b.widget))) {
              problems.add('${variantName(variant)} $loc: $c');
            }
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty);
    },
    skip: true, // QA VISUAL-R2-04
  );

  testWidgets(
    'QA VISUAL-R2-05: sync progress bar keeps animating under reduce motion '
    'before the transfer starts',
    (tester) async {
      late VisualPhone p;
      await tester.runAsync(() async => p = await VisualPhone.create());
      await pumpVisual(
        tester,
        p,
        v: v(360, 1.0),
        location: Routes.syncSession,
        disableAnimations: true,
      );
      p.engine.emitStatus(
        const SyncStatus(
          session: SessionActive(
            SyncProgress(
              peerName: "Priya's Pixel 8",
              transport: TransportKind.lan,
              phase: SyncPhase.handshaking,
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      expect(animating(tester), isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(p.dispose);
    },
    skip: true, // QA VISUAL-R2-05
  );

  testWidgets(
    'QA VISUAL-R2-06: Search "no results" headline splits an emoji when it '
    'shortens a long query',
    (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      await pumpVisual(
        tester,
        w.phone,
        v: v(360, 1.0),
        location: Routes.search,
      );
      // 38 letters, then an emoji whose two UTF-16 units straddle the cut.
      final q = '${'a' * 38}🍕 pizza night at the beach shack';
      await tester.enterText(find.byType(TextField).first, q);
      await settleFrames(tester);
      final headline = visibleTexts(tester)
          .firstWhere((t) => t.startsWith('No expenses match'));
      final lone = RegExp(r'[\uD800-\uDBFF](?![\uDC00-\uDFFF])');
      expect(lone.hasMatch(headline), isFalse, reason: headline);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(w.phone.dispose);
    },
    skip: true, // QA VISUAL-R2-06
  );

  testWidgets(
    'QA VISUAL-R2-07: group app bar still cuts "KD999,999.999 spent" at '
    '320 dp, 1.3x and 2.0x',
    (tester) async {
      final problems = <String>[];
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.huge());
      for (final variant in [v(320, 1.3), v(320, 2.0, Brightness.dark)]) {
        // Also the INR group: ₹99,99,99,999.99 since UIFLOW-R2-04.
        for (final group in [w.kwdGroup, w.group]) {
          await pumpVisual(
            tester,
            w.phone,
            v: variant,
            location: Routes.group(group),
          );
          for (final c in cutContaining(tester, ' spent')) {
            problems.add('${variantName(variant)}: $c');
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty);
    },
    skip: true, // QA VISUAL-R2-07
  );
}
