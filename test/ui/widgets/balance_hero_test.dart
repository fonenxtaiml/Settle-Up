import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'kit_harness.dart';

void main() {
  setUpAll(configureKitTests);

  testKitVariants(
    'owed hero with totals and a second currency',
    () => const Padding(
      padding: EdgeInsets.all(16),
      child: BalanceHero(
        net: {'GBP': 4250, 'EUR': 1200},
        owedToMe: {'GBP': 5090, 'EUR': 1200},
        iOwe: {'GBP': 840},
        mainCurrency: 'GBP',
      ),
    ),
    verify: (tester, v) async {
      expect(find.text('Overall, you are owed'), findsOneWidget);
      expect(find.text('£42.50'), findsOneWidget);
      expect(find.textContaining('Plus €12.00 owed to you'), findsOneWidget);
      expect(find.textContaining('You owe £8.40 in total.'), findsOneWidget);
      expect(
        find.bySemanticsLabel('Overall, you are owed 42.50 GBP'),
        findsOneWidget,
      );
    },
  );

  testKitVariants(
    'owe hero',
    () => const Padding(
      padding: EdgeInsets.all(16),
      child: BalanceHero(
        net: {'GBP': -1200},
        owedToMe: {},
        iOwe: {'GBP': 1200},
        mainCurrency: 'GBP',
      ),
    ),
    verify: (tester, v) async {
      expect(find.text('Overall, you owe'), findsOneWidget);
      expect(find.text('£12.00'), findsOneWidget);
      expect(find.textContaining('in total'), findsNothing);
    },
  );

  testKitVariants(
    'settled hero hides the amount',
    () => const Padding(
      padding: EdgeInsets.all(16),
      child: BalanceHero(
        net: {'GBP': 0},
        owedToMe: {},
        iOwe: {},
        mainCurrency: 'GBP',
      ),
    ),
    verify: (tester, v) async {
      expect(find.text("You're all even"), findsOneWidget);
      expect(find.textContaining('£'), findsNothing);
    },
  );

  testWidgets('huge amounts scale down instead of overflowing', (tester) async {
    await tester.pumpWidget(
      kitApp(
        const SizedBox(
          width: 280,
          child: BalanceHero(
            net: {'GBP': 999999999},
            owedToMe: {'GBP': 999999999},
            iOwe: {},
            mainCurrency: 'GBP',
          ),
        ),
        textScale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('tap calls onTap', (tester) async {
    var taps = 0;
    await tester.pumpWidget(
      kitApp(
        BalanceHero(
          net: const {'GBP': 100},
          owedToMe: const {'GBP': 100},
          iOwe: const {},
          mainCurrency: 'GBP',
          onTap: () => taps++,
        ),
      ),
    );
    await tester.tap(find.byType(BalanceHero));
    expect(taps, 1);
  });

  test('orderedNets puts the main currency first, then by size', () {
    final o = BalanceHero.orderedNets({
      'EUR': -5000,
      'GBP': 10,
      'USD': 7000,
      'JPY': 0,
    }, 'GBP');
    expect(o.map((e) => e.key), ['GBP', 'USD', 'EUR']);
  });
}
