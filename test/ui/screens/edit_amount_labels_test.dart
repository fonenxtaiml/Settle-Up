// VISUAL-R34-03 as a class: an edit screen never shows an amount that
// says nothing about what it is, and nothing on it contradicts the amount
// being edited. Edit payment used to show the stored total, bare, under
// the note ("₹200"), and kept it after the user typed a new amount.
//
// For Edit payment and Edit expense over the charter matrix, light and
// dark: after the user types a new amount, no text on screen and no
// TalkBack label is the stored total, and no text is an amount alone
// outside the amount field.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/format/money_format.dart';
import 'package:settle_up/ui/router.dart';

import '../../qa/visual/visual_harness.dart';

/// "₹200", "KD1,250.750", "-₹5" in [currency]: an amount and nothing else.
RegExp _bareAmount(String currency) {
  final symbol = RegExp.escape(
    MoneyFormat.format(0, currency).replaceAll(RegExp(r'[\d.,\s]'), ''),
  );
  return RegExp('^[-−]?(?:$symbol\\s*[\\d.,]+|[\\d.,]+\\s*$symbol)\$');
}

void main() {
  configureVisualTests();

  testWidgets('edit screens show no bare or stale amount after the amount '
      'is changed', (t) async {
    late VisualWorld w;
    await t.runAsync(() async => w = await VisualWorld.realistic());
    final handle = t.ensureSemantics();
    final stored = <String, (String, int)>{};
    await t.runAsync(() async {
      final s = w.phone.ledger.current.state;
      for (final id in [w.payment, w.expense]) {
        final e = s.expenseIn(w.group, id)!;
        stored[id] = (e.money.currency, e.money.total);
      }
    });
    final problems = <String>[];
    for (final v in kVariants) {
      for (final (name, id) in [
        ('edit payment', w.payment),
        ('edit expense', w.expense),
      ]) {
        final at = '${variantName(v)} $name';
        await pumpVisual(
          t,
          w.phone,
          v: (
            size: Size(v.size.width, 2400),
            scale: v.scale,
            brightness: v.brightness,
          ),
          location: Routes.editExpense(id, groupId: w.group),
        );
        final (currency, total) = stored[id]!;
        final old = MoneyFormat.format(total, currency);
        await t.enterText(find.byType(EditableText).first, '350');
        await settleFrames(t);
        final field = find.byType(EditableText).first;
        for (final e in find.byType(RichText).evaluate()) {
          final inField = find
              .ancestor(
                of: find.byElementPredicate((x) => x == e),
                matching: field,
              )
              .evaluate()
              .isNotEmpty;
          if (inField) continue;
          final p = e.renderObject;
          if (p is! RenderParagraph) continue;
          final text = p.text.toPlainText();
          if (text.trim() == old) problems.add('$at: stale "$text"');
          if (_bareAmount(currency).hasMatch(text.trim())) {
            problems.add('$at: bare amount "$text"');
          }
        }
        for (final l in semanticsLabels(t)) {
          if (l.trim() == old) problems.add('$at: TalkBack reads only "$l"');
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    handle.dispose();
    await t.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
