// QA VISUAL round 17: the VISUAL-R15-01 class guarded at the charter
// matrix with the bundled Familjen Grotesk. The currency picker, opened
// from Settings on each long-symbol currency, shows the symbol and code
// whole, never shrinks a symbol below 0.9 of its size, lays out with no
// errors, and passes the tap target, label and contrast guidelines at
// every size, scale and theme.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/pickers.dart';

import '../../ui/widgets/kit_harness.dart' show loadRealFonts;
import 'visual_harness.dart';

/// The longest symbols at 1.0x to 2.0x, and the charter's KWD.
const _codes = ['SOS', 'MOP', 'XAF', 'UZS', 'BBD', 'LYD', 'KWD', 'WST'];

/// How far [p] is scaled by the FittedBox around it (1 when none).
double _scale(RenderParagraph p) {
  RenderObject? r = p.parent;
  while (r != null && r is! RenderFittedBox) {
    r = r.parent;
  }
  return r == null ? 1 : (r as RenderBox).size.width / p.size.width;
}

void main() {
  configureVisualTests();
  setUpAll(loadRealFonts);

  testWidgets('VISUAL-R15-01 class: the currency picker shows long symbols '
      'whole at every size, scale and theme, within the guidelines', (t) async {
    final handle = t.ensureSemantics();
    final problems = <String>[];
    for (final v in kVariants) {
      late VisualPhone p;
      await t.runAsync(() async => p = await VisualPhone.create(home: 'SOS'));
      final errors = await collectLayoutErrors(() async {
        await pumpVisual(t, p, v: v, location: Routes.settings);
        for (final code in _codes) {
          final ctx = t.element(find.byType(Scaffold).first);
          pickCurrency(ctx, selected: code).ignore();
          await t.pumpAndSettle();
          final c = Currencies.of(code);
          final tile = find.byType(ListTile).first;
          for (final e
              in find
                  .descendant(of: tile, matching: find.byType(RichText))
                  .evaluate()) {
            final ro = e.renderObject! as RenderParagraph;
            final text = ro.text.toPlainText();
            if (text != c.symbol && text != c.code) continue;
            if (ro.didExceedMaxLines ||
                ro.getMaxIntrinsicWidth(double.infinity) >
                    ro.size.width + 0.5) {
              problems.add('${variantName(v)} $code: "$text" cut');
            }
            if (text == c.symbol && _scale(ro) < 0.9) {
              problems.add('${variantName(v)} $code: symbol shrunk');
            }
          }
          if (code == 'SOS') {
            for (final g in [
              androidTapTargetGuideline,
              labeledTapTargetGuideline,
              textContrastGuideline,
            ]) {
              final r = await g.evaluate(t);
              if (!r.passed) problems.add('${variantName(v)}: ${r.reason}');
            }
          }
          Navigator.of(ctx).pop();
          await t.pumpAndSettle();
        }
        await t.pumpWidget(const SizedBox.shrink());
      });
      if (errors.isNotEmpty) {
        problems.add('${variantName(v)}: ${errors.toSet()}');
      }
      await t.runAsync(p.ledger.close);
    }
    handle.dispose();
    expect(problems, isEmpty);
  });
}
