import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'kit_harness.dart';

void main() {
  setUpAll(configureKitTests);

  testKitVariants(
    'selector and remainder bars',
    () => Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          SplitMethodSelector(value: SplitMethod.exact, onChanged: (_) {}),
          const SizedBox(height: 16),
          const RemainderBar(
            method: SplitMethod.exact,
            targetUnits: 6000,
            assignedUnits: 5550,
            currency: 'GBP',
          ),
          const RemainderBar(
            method: SplitMethod.percent,
            targetUnits: 10000,
            assignedUnits: 10000,
            currency: 'GBP',
          ),
          const RemainderBar(
            method: SplitMethod.exact,
            targetUnits: 6000,
            assignedUnits: 6200,
            currency: 'GBP',
          ),
          const RemainderBar(
            method: SplitMethod.equal,
            targetUnits: 6000,
            assignedUnits: 0,
            currency: 'GBP',
          ),
        ],
      ),
    ),
    verify: (tester, v) async {
      expect(find.text('£4.50 left to assign'), findsOneWidget);
      expect(find.text('All 100% assigned'), findsOneWidget);
      expect(
        find.text("£2.00 too much. Lower someone's share."),
        findsOneWidget,
      );
      if (v.$2 >= 2) {
        expect(find.byType(ChoiceChip), findsNWidgets(4));
      } else {
        expect(find.byType(SegmentedButton<SplitMethod>), findsOneWidget);
      }
    },
  );

  for (final scale in [1.0, 2.0]) {
    testWidgets('selecting a segment reports the method (@${scale}x)', (
      tester,
    ) async {
      SplitMethod? picked;
      await tester.pumpWidget(
        kitApp(
          SplitMethodSelector(
            value: SplitMethod.equal,
            onChanged: (m) => picked = m,
          ),
          textScale: scale,
        ),
      );
      await tester.tap(find.text('Percent'));
      await tester.pump();
      expect(picked, SplitMethod.percent);
    });
  }

  testWidgets('adjustment selects no segment', (tester) async {
    await tester.pumpWidget(
      kitApp(
        SplitMethodSelector(value: SplitMethod.adjustment, onChanged: (_) {}),
      ),
    );
    final b = tester.widget<SegmentedButton<SplitMethod>>(
      find.byType(SegmentedButton<SplitMethod>),
    );
    expect(b.selected, isEmpty);
  });

  test('percent labels from basis points', () {
    expect(RemainderBar.percentLabel(10000), '100%');
    expect(RemainderBar.percentLabel(1250), '12.5%');
    expect(RemainderBar.percentLabel(1225), '12.25%');
    expect(RemainderBar.percentLabel(5), '0.05%');
  });
}
