// VISUAL-R9-01 class, app-wide: on every screen, in every split method,
// scrolled top to bottom, no node says "button" without a tap action, so
// TalkBack can activate everything it calls a button. With the tap action
// exposed, the tap target guidelines see every such node.
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

import '../../qa/visual/visual_harness.dart';

List<String> _deadButtons(WidgetTester tester, String where) {
  final out = <String>[];
  void visit(SemanticsNode n) {
    final d = n.getSemanticsData();
    final f = d.flagsCollection;
    if (f.isButton &&
        f.isEnabled != Tristate.isFalse &&
        !n.isInvisible &&
        !d.hasAction(SemanticsAction.tap)) {
      out.add('$where: "${d.label.replaceAll('\n', ' ')}"');
    }
    n.visitChildren((c) {
      visit(c);
      return true;
    });
  }

  visit(
    tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!,
  );
  return out;
}

Future<List<String>> _sweep(WidgetTester tester, String where) async {
  final out = [..._deadButtons(tester, where)];
  final s = find.byType(Scrollable);
  if (s.evaluate().isEmpty) return out;
  for (var i = 0; i < 8; i++) {
    final pos = tester.state<ScrollableState>(s.first).position;
    if (pos.pixels >= pos.maxScrollExtent) break;
    pos.jumpTo((pos.pixels + 250).clamp(0, pos.maxScrollExtent));
    await tester.pump(const Duration(milliseconds: 300));
    out.addAll(_deadButtons(tester, '$where @${pos.pixels.round()}'));
  }
  return out;
}

void main() {
  configureVisualTests();

  testWidgets('every button on every screen has a semantic tap action, at '
      '1.0x light and 2.0x dark', (tester) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());
    final handle = tester.ensureSemantics();
    final problems = <String>{};
    final screens = {
      ...w.screens,
      'new group': Routes.newGroup,
      'scan': Routes.syncScan,
      'edit payment': Routes.editExpense(w.payment),
    };
    for (final v in <Variant>[
      (size: const Size(360, 640), scale: 1.0, brightness: Brightness.light),
      (size: const Size(360, 640), scale: 2.0, brightness: Brightness.dark),
    ]) {
      for (final e in screens.entries) {
        await pumpVisual(tester, w.phone, v: v, location: e.value);
        problems.addAll(await _sweep(tester, '${variantName(v)} ${e.key}'));
        await tester.pumpWidget(const SizedBox.shrink());
      }
      for (final m in [
        KitStrings.splitExact,
        KitStrings.splitPercent,
        KitStrings.splitShares,
        KitStrings.splitAdjust,
      ]) {
        await pumpVisual(
          tester,
          w.phone,
          v: v,
          location: Routes.editExpense(w.expense),
        );
        await tester.scrollUntilVisible(
          find.text(m),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text(m));
        await tester.pump(const Duration(milliseconds: 500));
        problems.addAll(await _sweep(tester, '${variantName(v)} split $m'));
        await tester.pumpWidget(const SizedBox.shrink());
      }
    }
    handle.dispose();
    await tester.runAsync(w.phone.dispose);
    expect(problems, isEmpty, reason: problems.join('\n'));
  });
}
