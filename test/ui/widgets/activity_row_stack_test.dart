// VISUAL-R3-01: an Activity row stacks its trailing amount under the
// sentence only when the sentence would get less room than a word beside
// it, as ExpenseRow does.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import '../../qa/visual/visual_harness.dart';

Future<List<KitListRow>> _rows(
  WidgetTester tester,
  VisualWorld w,
  Size size,
  double scale,
) async {
  await pumpVisual(
    tester,
    w.phone,
    v: (size: size, scale: scale, brightness: Brightness.light),
    location: Routes.activity,
  );
  final rows = [
    for (final e in find.byType(KitListRow).evaluate())
      if ((e.widget as KitListRow).trailing != null) e.widget as KitListRow,
  ];
  await tester.pumpWidget(const SizedBox.shrink());
  return rows;
}

void main() {
  testWidgets('a roomy phone keeps the amount beside the sentence', (
    tester,
  ) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());
    final rows = await _rows(tester, w, const Size(411, 800), 1.0);
    expect(rows, isNotEmpty);
    expect(rows.where((r) => r.stackTrailing), isEmpty);
    await tester.runAsync(w.phone.dispose);
  });

  testWidgets('a huge amount at 320 dp and 1.45x stacks', (tester) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.huge());
    final rows = await _rows(tester, w, const Size(320, 568), 1.45);
    expect(rows.where((r) => r.stackTrailing), isNotEmpty);
    await tester.runAsync(w.phone.dispose);
  });
}
