// Round 4 layout regressions with the largest amounts: the amount field
// scales its text down (VISUAL-R4-02), split rows keep amounts whole
// (VISUAL-R4-03), expense detail and balance rows stack before a name
// loses its longest word (VISUAL-R4-04, VISUAL-R4-05), and the Sync tether
// stacks its labels when they do not fit (VISUAL-R4-01).
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import '../../qa/visual/visual_harness.dart';

Variant _v(double w, double scale) => (
  size: Size(w, w <= 320 ? 568 : 640),
  scale: scale,
  brightness: Brightness.light,
);

RenderEditable? _editableIn(RenderObject r) {
  if (r is RenderEditable) return r;
  RenderEditable? out;
  r.visitChildren((c) => out ??= _editableIn(c));
  return out;
}

/// Amount text fields whose value is partly out of sight.
List<String> _hidden(String where) => [
  for (final e in find.byType(EditableText).evaluate())
    if (RegExp(r'^[\d.,]+$')
        .hasMatch((e.widget as EditableText).controller.text))
      ...() {
        final t = (e.widget as EditableText).controller.text;
        final re = _editableIn(e.renderObject!)!;
        final start = re.getLocalRectForCaret(const TextPosition(offset: 0));
        final end = re.getLocalRectForCaret(TextPosition(offset: t.length));
        return [
          if (start.left < -1 || end.left > re.size.width + 1)
            '$where: "$t" hidden in ${re.size.width.toStringAsFixed(1)} dp',
        ];
      }(),
];

/// Amounts broken over two lines.
List<String> _brokenAmounts(String where) => [
  for (final e in find.byType(RichText).evaluate())
    if ((e.renderObject! as RenderParagraph).text.toPlainText().contains('₹'))
      if ((e.renderObject! as RenderParagraph).size.width + 0.5 <
          (e.renderObject! as RenderParagraph).getMinIntrinsicWidth(
            double.infinity,
          ))
        '$where: "${(e.renderObject! as RenderParagraph).text.toPlainText()}"',
];

void main() {
  configureVisualTests();

  testWidgets('the largest amounts stay whole in the expense editor', (
    tester,
  ) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.huge());
    final problems = <String>[];
    for (final variant in [
      _v(320, 1.0),
      _v(320, 1.3),
      _v(360, 1.45),
      _v(360, 1.59),
      _v(360, 2.0),
    ]) {
      final where = variantName(variant);
      final errors = await collectLayoutErrors(
        () => pumpVisual(
          tester,
          w.phone,
          v: variant,
          location: Routes.editExpense(w.expense),
        ),
      );
      problems
        ..addAll(errors.toSet().map((e) => '$where: $e'))
        ..addAll(_hidden('$where top'));
      final scrollable = find.byType(Scrollable).first;
      for (var i = 0; i < 12; i++) {
        await tester.drag(scrollable, const Offset(0, -200));
        await tester.pump();
        problems
          ..addAll(_hidden('$where scrolled $i'))
          ..addAll(_brokenAmounts('$where scrolled $i'));
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
    await tester.runAsync(w.phone.dispose);
    expect(problems.toSet(), isEmpty, reason: problems.toSet().join('\n'));
  });

  testWidgets('detail, Home and Person rows stack before a name is cut', (
    tester,
  ) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.huge());
    final problems = <String>[];
    for (final variant in [_v(320, 1.1), _v(320, 1.5), _v(340, 1.55)]) {
      for (final loc in [
        Routes.expense(w.expense),
        Routes.home,
        Routes.person(w.person),
        Routes.sync,
      ]) {
        final where = '${variantName(variant)} $loc';
        final errors = await collectLayoutErrors(
          () => pumpVisual(tester, w.phone, v: variant, location: loc),
        );
        problems.addAll(errors.toSet().map((e) => '$where: $e'));
        for (final r in find.byType(KitListRow).evaluate()) {
          final row = r.widget as KitListRow;
          if (row.trailing == null) continue;
          final f = find.descendant(
            of: find.byWidget(row),
            matching: find.text(row.title),
          );
          if (f.evaluate().isEmpty) continue;
          final p = tester.renderObject<RenderParagraph>(f.first);
          final words = row.title.split(RegExp(r'\s+'));
          for (final word in words) {
            final tp = TextPainter(
              text: TextSpan(text: word, style: p.text.style),
              textDirection: TextDirection.ltr,
              textScaler: p.textScaler,
            )..layout();
            if (p.size.width + 0.5 < tp.width) {
              problems.add('$where: "${row.title}" cut inside "$word"');
            }
            tp.dispose();
          }
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
    await tester.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
