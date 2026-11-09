import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'kit_harness.dart';

void main() {
  setUpAll(configureKitTests);

  group('LevelVial.positionFor', () {
    test('even and empty balances sit in the middle', () {
      expect(LevelVial.positionFor(owedToMe: 0, iOwe: 0), 0);
      expect(LevelVial.positionFor(owedToMe: 500, iOwe: 500), 0);
    });

    test('all owed / all owe reach the ends', () {
      expect(LevelVial.positionFor(owedToMe: 5090, iOwe: 0), 1);
      expect(LevelVial.positionFor(owedToMe: 0, iOwe: 840), -1);
    });

    test('small imbalances are eased with sign*sqrt', () {
      // x = (5090 - 840) / 5930 = 0.7167 -> sqrt = 0.8466
      expect(
        LevelVial.positionFor(owedToMe: 5090, iOwe: 840),
        closeTo(0.8466, 1e-4),
      );
      // x = -0.01 -> -0.1
      expect(
        LevelVial.positionFor(owedToMe: 495, iOwe: 505),
        closeTo(-0.1, 1e-9),
      );
    });
  });

  testKitVariants(
    'vial with end labels',
    () => const Padding(
      padding: EdgeInsets.all(16),
      child: Column(
        children: [
          LevelVial(position: 0.6),
          SizedBox(height: 16),
          LevelVial(position: -1, showEndLabels: false),
          SizedBox(height: 16),
          LevelVial(position: 0, settled: true, height: 24),
        ],
      ),
    ),
    verify: (tester, v) async {
      expect(find.text('owe'), findsNWidgets(2));
      expect(find.text('owed'), findsNWidgets(2));
    },
  );

  testWidgets('springs to a new position and settles', (tester) async {
    Widget at(double p, {bool settled = false}) =>
        kitApp(LevelVial(position: p, settled: settled));
    await tester.pumpWidget(at(-0.8));
    await tester.pumpWidget(at(0, settled: true));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('reduced motion jumps without animating', (tester) async {
    await tester.pumpWidget(
      kitApp(const LevelVial(position: -0.5), disableAnimations: true),
    );
    await tester.pumpWidget(
      kitApp(const LevelVial(position: 0.5), disableAnimations: true),
    );
    expect(tester.hasRunningAnimations, isFalse);
  });
}
