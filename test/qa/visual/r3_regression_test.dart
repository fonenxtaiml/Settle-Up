// QA VISUAL round 3: reverification of the round 2 fixes over a wider
// sweep (phone widths between 320 and 411 dp, text scales on both sides of
// the 1.6x stacking threshold) and the code the fixes added (rows that
// measure their text and stack early, labels that scale down, the group
// chip that moves out of the editor app bar).
//
// Tests named "QA VISUAL-R3-NN" with `skip: true` are failing repros for
// open findings; unskip to verify a fix. The other tests pass and guard the
// fixes.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'visual_harness.dart';

const List<double> kWidths = [320, 340, 360, 384, 411];
const List<double> kScales = [1.0, 1.15, 1.3, 1.45, 1.59, 1.6, 2.0];

Variant sv(double w, double scale, [Brightness b = Brightness.light]) => (
  size: Size(w, w <= 320 ? 568 : (w < 384 ? 640 : 800)),
  scale: scale,
  brightness: b,
);

/// Paragraphs under [scope] that were ellipsized, or are narrower than
/// their longest word.
List<String> brokenOrCut(Finder scope) {
  final out = <String>[];
  for (final e
      in find
          .descendant(of: scope, matching: find.byType(RichText))
          .evaluate()) {
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

/// Labels from [labels] anywhere on screen that are narrower than the word.
List<String> brokenLabels(Set<String> labels) => [
  for (final e in find.byType(RichText).evaluate())
    if (e.renderObject case final RenderParagraph p
        when p.hasSize &&
            labels.contains(p.text.toPlainText()) &&
            p.size.width + 0.5 < p.getMinIntrinsicWidth(double.infinity))
      '"${p.text.toPlainText()}" box ${p.size.width.toStringAsFixed(1)} < '
          'word ${p.getMinIntrinsicWidth(double.infinity).toStringAsFixed(1)}',
];

/// Paragraphs containing [needle] that were ellipsized.
List<String> cutContaining(String needle) => [
  for (final e in find.byType(RichText).evaluate())
    if (e.renderObject case final RenderParagraph p
        when p.text.toPlainText().contains(needle) && p.didExceedMaxLines)
      p.text.toPlainText(),
];

/// How much [text] is scaled down on screen: painted width over laid-out
/// width (1.0 when no FittedBox shrinks it). The lowest over all matches.
double shrinkOf(WidgetTester tester, String text) {
  var lowest = 1.0;
  for (final e in find.text(text).evaluate()) {
    final box = e.renderObject;
    if (box is! RenderBox || !box.hasSize || !box.attached) continue;
    final painted = tester.getRect(find.byWidget(e.widget).first).width;
    final ratio = painted / box.size.width;
    if (ratio < lowest) lowest = ratio;
  }
  return lowest;
}

final RegExp _hasDigit = RegExp(r'\d');

bool animating(WidgetTester tester) =>
    tester.binding.transientCallbackCount > 0;

void main() {
  configureVisualTests();

  testWidgets('VISUAL-R1-03 sweep: suggested-payment sentences are whole '
      'at every width and scale (realistic, long names, huge)', (tester) async {
    final problems = <String>[];
    for (final build in [
      VisualWorld.realistic,
      VisualWorld.longNames,
      VisualWorld.huge,
    ]) {
      late VisualWorld w;
      await tester.runAsync(() async => w = await build());
      for (final width in kWidths) {
        for (final scale in kScales) {
          final variant = sv(width, scale);
          for (final loc in [
            Routes.group(w.group),
            Routes.group(w.kwdGroup),
            Routes.settle(groupId: w.group),
            Routes.settle(groupId: w.kwdGroup),
          ]) {
            final errors = await collectLayoutErrors(
              () => pumpVisual(tester, w.phone, v: variant, location: loc),
            );
            for (final e in errors) {
              problems.add('${variantName(variant)} $loc: $e');
            }
            for (final row in find.byType(TransferRow).evaluate()) {
              for (final c in brokenOrCut(find.byWidget(row.widget))) {
                problems.add('${variantName(variant)} $loc: $c');
              }
            }
            await tester.pumpWidget(const SizedBox.shrink());
          }
        }
      }
      await tester.runAsync(w.phone.dispose);
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('VISUAL-R1-05 sweep: the expense editor title is whole at '
      'every width and scale, short to 60-char group names', (tester) async {
    final problems = <String>[];
    for (final name in [
      'Goa trip',
      'Annual family trip to Kerala backwaters',
      kGroup60,
    ]) {
      late VisualWorld w;
      await tester.runAsync(
        () async => w = await VisualWorld.build(groupName: name),
      );
      for (final width in kWidths) {
        for (final scale in kScales) {
          final variant = sv(width, scale);
          for (final (loc, title) in [
            (Routes.editExpense(w.expense), 'Edit expense'),
            (Routes.newExpense(groupId: w.group), 'Add expense'),
            (Routes.newExpense(personId: w.person), 'Add expense'),
          ]) {
            final errors = await collectLayoutErrors(
              () => pumpVisual(tester, w.phone, v: variant, location: loc),
            );
            for (final e in errors) {
              problems.add('${variantName(variant)} $loc: $e');
            }
            for (final e in find.byType(RichText).evaluate()) {
              if (e.renderObject case final RenderParagraph p
                  when p.text.toPlainText() == title && p.didExceedMaxLines) {
                problems.add('${variantName(variant)} "$name" $loc: cut');
              }
            }
            await tester.pumpWidget(const SizedBox.shrink());
          }
        }
      }
      await tester.runAsync(w.phone.dispose);
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('VISUAL-R1-06/R2-01 sweep: expense rows keep the subline '
      'amount and whole direction words at every width and scale', (
    tester,
  ) async {
    final problems = <String>[];
    for (final build in [
      VisualWorld.realistic,
      VisualWorld.longNames,
      VisualWorld.huge,
    ]) {
      late VisualWorld w;
      await tester.runAsync(() async => w = await build());
      for (final width in kWidths) {
        for (final scale in kScales) {
          final variant = sv(width, scale);
          for (final loc in [
            Routes.group(w.group),
            Routes.group(w.kwdGroup),
            Routes.person(w.person),
          ]) {
            final errors = await collectLayoutErrors(
              () => pumpVisual(tester, w.phone, v: variant, location: loc),
            );
            for (final e in errors) {
              problems.add('${variantName(variant)} $loc: $e');
            }
            // The subline "Sam paid ¥5,000" (a payment's title "Sam paid
            // Bartholomew" holds no amount and may ellipsize like a name).
            for (final c in cutContaining(' paid ').where(_hasDigit.hasMatch)) {
              problems.add('${variantName(variant)} $loc: $c');
            }
            for (final row in find.byType(BalanceTrailing).evaluate()) {
              for (final c in brokenOrCut(find.byWidget(row.widget))) {
                problems.add('${variantName(variant)} $loc: $c');
              }
            }
            for (final c in pureOnly(findCutAmounts(tester))) {
              problems.add('${variantName(variant)} $loc: $c');
            }
            await tester.pumpWidget(const SizedBox.shrink());
          }
        }
      }
      await tester.runAsync(w.phone.dispose);
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('VISUAL-R2-02/R2-03 sweep: payment method and group type '
      'labels are whole words at every width and scale', (tester) async {
    final problems = <String>[];
    final shrink = <String>[];
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());
    for (final width in kWidths) {
      for (final scale in kScales) {
        final variant = sv(width, scale);
        for (final (loc, labels) in [
          (
            Routes.settle(groupId: w.kwdGroup),
            {'UPI', 'Cash', 'Bank', 'Other'},
          ),
          (Routes.settle(groupId: w.group), {'UPI', 'Cash', 'Bank', 'Other'}),
          (Routes.editGroup(w.group), {'Trip', 'Home', 'Couple', 'Other'}),
          (Routes.newGroup, {'Trip', 'Home', 'Couple', 'Other'}),
        ]) {
          final errors = await collectLayoutErrors(
            () => pumpVisual(tester, w.phone, v: variant, location: loc),
          );
          for (final e in errors) {
            problems.add('${variantName(variant)} $loc: $e');
          }
          for (final c in brokenLabels(labels)) {
            problems.add('${variantName(variant)} $loc: $c');
          }
          for (final l in labels) {
            final s = shrinkOf(tester, l);
            if (s < 0.999) {
              shrink.add(
                '${variantName(variant)} $loc "$l" x${s.toStringAsFixed(2)}',
              );
            }
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    }
    await tester.runAsync(w.phone.dispose);
    // ignore: avoid_print
    print('SHRINK\n${shrink.join('\n')}');
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('VISUAL-R2-04 sweep: hero buttons never break a word', (
    tester,
  ) async {
    final problems = <String>[];
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());
    for (final width in kWidths) {
      for (final scale in kScales) {
        final variant = sv(width, scale);
        for (final loc in [Routes.group(w.group), Routes.person(w.person)]) {
          await pumpVisual(tester, w.phone, v: variant, location: loc);
          for (final b in [
            ...find.byType(FilledButton).evaluate(),
            ...find.byType(OutlinedButton).evaluate(),
            ...find.byType(TextButton).evaluate(),
          ]) {
            for (final c in brokenOrCut(find.byWidget(b.widget))) {
              problems.add('${variantName(variant)} $loc: $c');
            }
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    }
    await tester.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  for (final phase in [
    SyncPhase.connecting,
    SyncPhase.handshaking,
    SyncPhase.comparing,
  ]) {
    testWidgets('VISUAL-R2-05: the sync progress bar is still under reduce '
        'motion in ${phase.name}', (tester) async {
      late VisualPhone p;
      await tester.runAsync(() async => p = await VisualPhone.create());
      await pumpVisual(
        tester,
        p,
        v: sv(360, 1.0),
        location: Routes.syncSession,
        disableAnimations: true,
      );
      p.engine.emitStatus(
        SyncStatus(
          session: SessionActive(
            SyncProgress(
              peerName: "Priya's Pixel 8",
              transport: TransportKind.lan,
              phase: phase,
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
    });
  }

  for (final (name, q) in [
    ('Devanagari', '${'a' * 38}क्षि गोवा ट्रिप की रात का खाना और भी कुछ'),
    ('Tamil', '${'a' * 38}க்ஷ கோவா பயணம் இரவு உணவு மேலும் சில'),
    ('flag emoji', '${'a' * 38}🇮🇳 independence day dinner party'),
    ('ZWJ family', '${'a' * 38}👨‍👩‍👧 family dinner at the beach shack'),
  ]) {
    testWidgets('VISUAL-R2-06: Search shortens a long $name query by whole '
        'characters', (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      await pumpVisual(
        tester,
        w.phone,
        v: sv(360, 1.0),
        location: Routes.search,
      );
      final errors = await collectLayoutErrors(() async {
        await tester.enterText(find.byType(TextField).first, q);
        await settleFrames(tester);
      });
      expect(errors, isEmpty);
      final headline = visibleTexts(tester)
          .firstWhere((t) => t.startsWith('No expenses match'));
      final lone = RegExp(
        r'[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]',
      );
      expect(lone.hasMatch(headline), isFalse, reason: headline);
      // The kept part is a prefix of the query in whole characters.
      final start = headline.indexOf('a' * 38);
      final kept = headline.substring(start, headline.indexOf('…', start));
      expect(q.startsWith(kept), isTrue);
      expect(kept.endsWith('\u094D'), isFalse, reason: 'dangling virama');
      expect(kept.endsWith('\u200D'), isFalse, reason: 'dangling ZWJ');
      // A Tamil pulli (U+0BCD) may end a cut: it is not a conjunct linker in
      // Unicode 15.1, and the dead consonant it makes is a whole letter.
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.runAsync(w.phone.dispose);
    });
  }

  testWidgets('VISUAL-R2-07 sweep: the group app bar total is never cut, '
      'and how far the short form scales down', (tester) async {
    final problems = <String>[];
    final shrink = <String>[];
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.huge());
    for (final width in kWidths) {
      for (final scale in kScales) {
        final variant = sv(width, scale);
        for (final group in [w.kwdGroup, w.group]) {
          await pumpVisual(
            tester,
            w.phone,
            v: variant,
            location: Routes.group(group),
          );
          for (final c in cutContaining(' spent')) {
            problems.add('${variantName(variant)}: $c');
          }
          for (final t in visibleTexts(
            tester,
          ).where((t) => t.endsWith(' spent'))) {
            final s = shrinkOf(tester, t);
            if (s < 0.999) {
              shrink.add(
                '${variantName(variant)} "$t" x${s.toStringAsFixed(2)}',
              );
            }
          }
          await tester.pumpWidget(const SizedBox.shrink());
        }
      }
    }
    await tester.runAsync(w.phone.dispose);
    // ignore: avoid_print
    print('SHRINK\n${shrink.join('\n')}');
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
  for (final b in Brightness.values) {
    testWidgets('round 2 fix layouts pass the tap target, label and contrast '
        'guidelines (${b.name}): group type chips, group chip in the form, '
        'stacked payment and expense rows, payment methods without the check', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      final problems = <String>[];
      late VisualWorld w;
      await tester.runAsync(
        () async => w = await VisualWorld.build(groupName: kGroup60),
      );
      for (final (variant, loc) in [
        (sv(360, 2.0, b), Routes.newGroup),
        (sv(320, 1.3, b), Routes.editGroup(w.group)),
        (sv(320, 1.0, b), Routes.newExpense(groupId: w.group)),
        (sv(320, 1.3, b), Routes.editExpense(w.expense)),
        (sv(320, 1.3, b), Routes.group(w.group)),
        (sv(320, 1.3, b), Routes.settle(groupId: w.group)),
        (sv(320, 1.0, b), Routes.settle(groupId: w.kwdGroup)),
      ]) {
        await pumpVisual(tester, w.phone, v: variant, location: loc);
        for (final g in [
          androidTapTargetGuideline,
          labeledTapTargetGuideline,
          textContrastGuideline,
        ]) {
          final r = await g.evaluate(tester);
          if (!r.passed) {
            problems.add(
              '${variantName(variant)} $loc: '
              '${(r.reason ?? '').split('\n').first}',
            );
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.runAsync(w.phone.dispose);
      handle.dispose();
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }

  testWidgets('VISUAL-R1-05: the group chip that moves to the form is one '
      'labelled button, read once', (tester) async {
    final handle = tester.ensureSemantics();
    late VisualWorld w;
    await tester.runAsync(
      () async => w = await VisualWorld.build(groupName: kGroup60),
    );
    await pumpVisual(
      tester,
      w.phone,
      v: sv(320, 1.3),
      location: Routes.newExpense(groupId: w.group),
    );
    final labels = semanticsLabels(tester)
        .where((l) => l.contains(kGroup60.substring(0, 20)))
        .toList();
    expect(labels, hasLength(1), reason: '$labels');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(w.phone.dispose);
    handle.dispose();
  });

  // ------------------------------------------------------------------
  // New findings, round 3 (skipped repros).
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R3-01: Activity rows squeeze the sentence below one word '
    '(and overflow with huge amounts) at 320 dp, 1.3x to 1.59x',
    skip: true, // QA VISUAL-R3-01
    (tester) async {
      final problems = <String>[];
      for (final build in [VisualWorld.realistic, VisualWorld.huge]) {
        late VisualWorld w;
        await tester.runAsync(() async => w = await build());
        for (final variant in [sv(320, 1.3), sv(320, 1.45), sv(320, 1.59)]) {
          for (final loc in [Routes.activity, Routes.groupActivity(w.group)]) {
            final errors = await collectLayoutErrors(
              () => pumpVisual(tester, w.phone, v: variant, location: loc),
            );
            for (final e in errors.toSet()) {
              problems.add('${variantName(variant)} $loc: $e');
            }
            for (final r in find.byType(KitListRow).evaluate()) {
              final row = r.widget as KitListRow;
              if (row.trailing == null) continue;
              final title = find.descendant(
                of: find.byWidget(row),
                matching: find.text(row.title),
              );
              if (title.evaluate().isEmpty) continue;
              final p = tester.renderObject<RenderParagraph>(title.first);
              final word = p.getMinIntrinsicWidth(double.infinity);
              if (p.size.width + 0.5 < word) {
                problems.add(
                  '${variantName(variant)} $loc: "${row.title}" gets '
                  '${p.size.width.toStringAsFixed(1)} dp < its longest word '
                  '${word.toStringAsFixed(1)} dp',
                );
              }
            }
            await tester.pumpWidget(const SizedBox.shrink());
          }
        }
        await tester.runAsync(w.phone.dispose);
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );
}
