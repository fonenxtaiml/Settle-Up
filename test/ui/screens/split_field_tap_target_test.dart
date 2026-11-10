// VISUAL-R8-01 regression: every text field of the expense editor (the
// amount fields of the exact, percent and adjustment split rows, and the
// labelled description field) and of the multi-payer sheet is at least
// 48 dp tall at every text scale, and the Android tap target guideline
// passes for text fields with the rows on screen.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/expense/expense_edit_screen.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

import '../../qa/visual/visual_harness.dart';

Variant _v(double w, double scale, [Brightness b = Brightness.light]) =>
    (size: Size(w, 800), scale: scale, brightness: b);

/// Heights of the text fields under [scope] that are on screen.
List<double> _heights(WidgetTester tester, Finder scope) => [
  for (final e
      in find
          .descendant(of: scope, matching: find.byType(TextField))
          .evaluate())
    tester.getRect(find.byWidget(e.widget)).height,
];

void main() {
  configureVisualTests();

  testWidgets('VISUAL-R8-01: the editor fields with exact, percent and '
      'adjustment split rows on screen are at least 48 dp tall from 1.0x to 2.0x and meet the tap target '
      'guideline', (tester) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());
    final handle = tester.ensureSemantics();
    final problems = <String>[];
    for (final v in [
      _v(320, 1.0),
      _v(360, 1.15, Brightness.dark),
      _v(411, 1.0),
      _v(411, 1.3),
      _v(360, 2.0),
    ]) {
      for (final method in [
        KitStrings.splitExact,
        KitStrings.splitPercent,
        KitStrings.splitAdjust,
      ]) {
        await pumpVisual(
          tester,
          w.phone,
          v: v,
          location: Routes.editExpense(w.expense),
        );
        await tester.scrollUntilVisible(
          find.text(method),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text(method));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.scrollUntilVisible(
          find.text('Sam'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump(const Duration(seconds: 1));
        final hs = _heights(tester, find.byType(ExpenseEditScreen));
        // The split rows' amount fields (labelled through their semantic
        // counter text) are on screen.
        expect(
          find.byWidgetPredicate(
            (w) => w is TextField && w.decoration?.semanticCounterText != null,
          ),
          findsAtLeastNWidgets(2),
          reason: '${variantName(v)} $method',
        );
        for (final h in hs) {
          if (h < 48 - 0.05) {
            problems.add(
              '${variantName(v)} $method field ${h.toStringAsFixed(1)} dp',
            );
          }
        }
        final r = await androidTapTargetGuideline.evaluate(tester);
        if (!r.passed && (r.reason ?? '').contains('isTextField')) {
          problems.add('${variantName(v)} $method: ${r.reason}');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
    handle.dispose();
    await tester.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('VISUAL-R8-01: multi-payer sheet amount fields are at least '
      '48 dp tall from 1.0x to 2.0x and meet the tap target guideline', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    final problems = <String>[];
    const names = {'me': 'You', 'p': 'Priya', 's': 'Sam'};
    for (final v in [
      _v(320, 1.0),
      _v(360, 1.15),
      _v(411, 1.0, Brightness.dark),
      _v(360, 2.0),
    ]) {
      setView(tester, v.size);
      tester.platformDispatcher.textScaleFactorTestValue = v.scale;
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
              me: 'me',
              total: 1200050,
              currency: 'INR',
              initial: const {'me': 1200050},
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));
      final hs = _heights(tester, find.byType(MultiPayerSheet));
      expect(hs, isNotEmpty);
      for (final h in hs) {
        if (h < 48 - 0.05) {
          problems.add('${variantName(v)} payer field ${h.toStringAsFixed(1)}');
        }
      }
      final r = await androidTapTargetGuideline.evaluate(tester);
      if (!r.passed && (r.reason ?? '').contains('isTextField')) {
        problems.add('${variantName(v)}: ${r.reason}');
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
    tester.platformDispatcher.clearTextScaleFactorTestValue();
    handle.dispose();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
