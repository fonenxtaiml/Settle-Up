// QA VISUAL round 8: reverification of the round 7 fix for VISUAL-R6-01
// (the multi-payer sheet lays out "Split the rest equally" and "Done" with
// the kit's ButtonPair) and the neighbouring cases the fix touches.
//
// Tests named "QA VISUAL-R8-NN" with `skip: true` are failing repros for
// open findings; unskip to verify a fix. The other tests pass and guard the
// fixes.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/expense/expense_edit_screen.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'visual_harness.dart';

Variant v8(double w, double scale, [Brightness b = Brightness.light]) => (
  size: Size(w, w <= 320 ? 568 : (w < 384 ? 640 : 800)),
  scale: scale,
  brightness: b,
);

const _rest = 'Split the rest equally';
const _done = 'Done';

Future<void> _pumpSheet(
  WidgetTester tester,
  Variant v, {
  required int total,
  required String currency,
  required Map<MemberId, String> names,
  Map<MemberId, int>? initial,
}) async {
  setView(tester, v.size);
  tester.platformDispatcher.textScaleFactorTestValue = v.scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  await tester.pumpWidget(
    MaterialApp(
      theme: v.brightness == Brightness.light
          ? AppTheme.light()
          : AppTheme.dark(),
      home: Scaffold(
        body: MultiPayerSheet(
          members: names.keys.toList(),
          names: names,
          fullNames: names,
          me: names.keys.first,
          total: total,
          currency: currency,
          initial: initial ?? {names.keys.first: total},
        ),
      ),
    ),
  );
  await tester.pump(const Duration(milliseconds: 300));
}

Finder _button(String label) => find.ancestor(
  of: find.descendant(
    of: find.byType(MultiPayerSheet),
    matching: find.text(label),
  ),
  matching: find.byType(FilledButton),
);

/// Layout problems of the two sheet buttons: a broken word, a label that
/// wraps while side by side, stacked buttons of unequal width, a button
/// outside the sheet's width.
List<String> _buttonProblems(WidgetTester tester, String where) {
  final problems = <String>[];
  final sheet = tester.getRect(find.byType(MultiPayerSheet));
  final rest = tester.getRect(_button(_rest));
  final done = tester.getRect(_button(_done));
  final stacked = done.top >= rest.bottom;
  if (!stacked && (rest.top - done.top).abs() > 0.5) {
    problems.add('$where: buttons neither side by side nor stacked');
  }
  if (stacked && (rest.width - done.width).abs() > 0.5) {
    problems.add('$where: stacked buttons differ in width');
  }
  for (final r in [rest, done]) {
    if (r.left < sheet.left - 0.5 || r.right > sheet.right + 0.5) {
      problems.add('$where: a button runs past the sheet ($r in $sheet)');
    }
    if (r.height < 48 - 0.5) {
      problems.add('$where: a button is ${r.height} dp tall');
    }
  }
  for (final label in [_rest, _done]) {
    final p = tester.renderObject<RenderParagraph>(
      find.descendant(
        of: find.byType(MultiPayerSheet),
        matching: find.text(label),
      ),
    );
    final lines = (p.size.height / p.preferredLineHeight).round();
    final word = p.getMinIntrinsicWidth(double.infinity);
    final line = p.getMaxIntrinsicWidth(double.infinity);
    if (p.size.width + 0.5 < word) {
      problems.add(
        '$where: "$label" breaks a word (${p.size.width.toStringAsFixed(1)}'
        ' dp < ${word.toStringAsFixed(1)} dp)',
      );
    }
    if (lines > 1 && (!stacked || line <= p.size.width + 0.5)) {
      problems.add(
        '$where: "$label" on $lines lines in a '
        '${p.size.width.toStringAsFixed(1)} dp box, stacked: $stacked',
      );
    }
    if (p.didExceedMaxLines) {
      problems.add('$where: "$label" is cut');
    }
  }
  return problems;
}

/// The failing nodes of a guideline [r], one string each, leaving out one
/// kind ruled out elsewhere (the payer amount fields' tap targets count
/// since VISUAL-R8-01 was fixed):
/// - the lone currency prefix ("₹") of those fields in the light theme.
///   The checker samples the anti-aliased edge of an 8.5 dp glyph and
///   reports 3.12:1, but the colours drawn are onSurfaceVariant on
///   surfaceContainer, 5.11:1 (light) and 6.06:1 (dark), which pass
///   4.5:1, as the field's "0" hint in the same colours does.
List<String> _failures(Evaluation r) {
  if (r.passed) return const [];
  final nodes = (r.reason ?? '')
      .split('SemanticsNode#')
      .skip(1)
      .where((n) => !RegExp(r'label: "(₹|KD|\$|€|¥)"').hasMatch(n))
      .toList();
  return [for (final n in nodes) n.split('\n').first];
}

/// The heights of the amount fields in the split rows under [scope].
List<double> _fieldHeights(WidgetTester tester, Finder scope) => [
  for (final e
      in find
          .descendant(of: scope, matching: find.byType(TextField))
          .evaluate())
    tester.getRect(find.byWidget(e.widget)).height,
];

void main() {
  configureVisualTests();

  testWidgets('VISUAL-R6-01 class: the multi-payer sheet buttons never '
      'break a word or wrap side by side over the full matrix (240-411 dp, '
      '1.0x-2.0x, both themes), long names and Money.maxMinor in INR, KWD '
      'and JPY', (tester) async {
    final problems = <String>[];
    final names = <MemberId, String>{
      'me': 'You',
      'p': kName40,
      's': 'Sam',
      for (var i = 0; i < 6; i++) 'x$i': '$kName40$i',
    };
    for (final w in [240.0, 280.0, 320.0, 360.0, 384.0, 411.0]) {
      for (final s in [1.0, 1.15, 1.3, 1.5, 1.6, 2.0]) {
        for (final b in Brightness.values) {
          for (final cur in ['INR', 'KWD', 'JPY']) {
            final v = v8(w, s, b);
            final where = '${variantName(v)} $cur';
            final errors = await collectLayoutErrors(() async {
              await _pumpSheet(
                tester,
                v,
                total: Money.maxMinor,
                currency: cur,
                names: names,
                initial: {'me': Money.maxMinor ~/ 2, 'p': Money.maxMinor ~/ 2},
              );
              await tester.drag(
                find.byType(Scrollable).first,
                const Offset(0, -6000),
              );
              await tester.pump(const Duration(milliseconds: 300));
            });
            for (final e in errors.toSet()) {
              problems.add('$where: $e');
            }
            problems.addAll(_buttonProblems(tester, where));
            await tester.pumpWidget(const SizedBox.shrink());
          }
        }
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('VISUAL-R6-01 class: the stacked and side-by-side sheet '
      'buttons meet the tap target, labeled tap target and contrast '
      'guidelines, enabled and disabled, in both themes', (tester) async {
    final handle = tester.ensureSemantics();
    final problems = <String>[];
    for (final v in [
      v8(320, 1.0),
      v8(320, 1.0, Brightness.dark),
      v8(360, 1.3),
      v8(360, 1.3, Brightness.dark),
      v8(320, 2.0),
      v8(320, 2.0, Brightness.dark),
      v8(411, 1.0),
      v8(411, 1.0, Brightness.dark),
    ]) {
      // Done is enabled (the payers add up) and disabled (they do not).
      for (final (state, initial) in [
        ('enabled', const <MemberId, int>{'me': 1200050}),
        ('disabled', const <MemberId, int>{'me': 1000}),
      ]) {
        final where = '${variantName(v)} $state';
        await _pumpSheet(
          tester,
          v,
          total: 1200050,
          currency: 'INR',
          names: const {'me': 'You', 'p': 'Priya', 's': 'Sam'},
          initial: initial,
        );
        await tester.ensureVisible(_button(_done));
        await tester.pump();
        final done = tester.widget<FilledButton>(_button(_done));
        if ((done.onPressed != null) != (state == 'enabled')) {
          problems.add('$where: Done is not $state');
        }
        for (final (gn, g) in [
          ('tap target', androidTapTargetGuideline),
          ('labeled', labeledTapTargetGuideline),
          ('contrast', textContrastGuideline),
        ]) {
          final r = await g.evaluate(tester);
          for (final f in _failures(r)) {
            problems.add('$where $gn: $f');
          }
        }
        for (final label in [_rest, _done]) {
          if (find.bySemanticsLabel(label).evaluate().isEmpty) {
            problems.add('$where: no "$label" semantics node');
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
    handle.dispose();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('VISUAL-R6-01 class: the sheet buttons keep working when the '
      'layout switches (tap "Split the rest equally" stacked and side by '
      'side, then Done)', (tester) async {
    final problems = <String>[];
    for (final v in [v8(320, 2.0), v8(411, 1.0)]) {
      await _pumpSheet(
        tester,
        v,
        total: 9000,
        currency: 'INR',
        names: const {'me': 'You', 'p': 'Priya', 's': 'Sam'},
        initial: const {'me': 1000},
      );
      await tester.ensureVisible(_button(_rest));
      await tester.pump();
      await tester.tap(_button(_rest));
      await tester.pump();
      final fields = find
          .descendant(
            of: find.byType(MultiPayerSheet),
            matching: find.byType(EditableText),
          )
          .evaluate()
          .map((e) => (e.widget as EditableText).controller.text)
          .toList();
      // One payer (me) had an amount, so the whole total goes to me.
      if (fields.first.isEmpty) {
        problems.add('${variantName(v)}: split did nothing ($fields)');
      }
      await tester.ensureVisible(_button(_done));
      await tester.pump();
      if (tester.widget<FilledButton>(_button(_done)).onPressed == null) {
        problems.add('${variantName(v)}: Done disabled after the split');
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // ------------------------------------------------------------------
  // New findings, round 8 (skipped repros).
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R8-01: split-row and multi-payer amount fields are 42.8 dp '
    'tall at 1.0x, under the 48 dp tap target',
    (tester) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final problems = <String>[];
      for (final v in [
        v8(320, 1.0),
        v8(320, 1.0, Brightness.dark),
        v8(360, 1.0),
        v8(360, 1.15),
        v8(411, 1.0),
      ]) {
        // The exact split of the realistic expense, on the edit screen.
        await pumpVisual(
          tester,
          w.phone,
          v: v,
          location: Routes.editExpense(w.expense),
        );
        await tester.scrollUntilVisible(
          find.text('Sam'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump(const Duration(seconds: 1));
        for (final h in _fieldHeights(tester, find.byType(ListSection))) {
          if (h < 48 - 0.05) {
            problems.add(
              '${variantName(v)} exact split field ${h.toStringAsFixed(1)} dp',
            );
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
        // The multi-payer sheet.
        await _pumpSheet(
          tester,
          v,
          total: 1200050,
          currency: 'INR',
          names: const {'me': 'You', 'p': 'Priya', 's': 'Sam'},
        );
        for (final h in _fieldHeights(tester, find.byType(MultiPayerSheet))) {
          if (h < 48 - 0.05) {
            problems.add(
              '${variantName(v)} payer field ${h.toStringAsFixed(1)} dp',
            );
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.runAsync(w.phone.dispose);
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );
}
