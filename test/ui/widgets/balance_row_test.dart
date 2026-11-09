import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'kit_harness.dart';

void main() {
  setUpAll(configureKitTests);

  Widget rows() => const Column(
    children: [
      BalanceRow(
        kind: BalanceRowKind.person,
        id: 'p-sam',
        title: 'Sam Patel',
        subtitle: 'In Flat 4B and Goa trip',
        net: {'GBP': 1200},
      ),
      BalanceRow(
        kind: BalanceRowKind.group,
        id: 'g-goa',
        title: 'Goa trip with a very long name that has to ellipsize',
        subtitle: '6 people',
        net: {'GBP': -840, 'EUR': 300},
      ),
      BalanceRow(
        kind: BalanceRowKind.member,
        id: 'm-ravi',
        title: 'Ravi',
        subtitle: 'Not on Settle Up yet',
        net: {'INR': -96000},
        isPlaceholder: true,
      ),
      BalanceRow(
        kind: BalanceRowKind.group,
        id: 'g-flat',
        title: 'Flat 4B',
        subtitle: '3 people, settled 2 Nov',
        net: {},
      ),
    ],
  );

  testKitVariants(
    'balance rows',
    rows,
    verify: (tester, v) async {
      expect(find.text('+£12.00'), findsOneWidget);
      expect(find.text('owes you'), findsOneWidget);
      expect(find.text('−£8.40'), findsOneWidget);
      expect(find.text('you owe'), findsOneWidget);
      expect(find.text('+1 more'), findsOneWidget);
      expect(find.text('owes'), findsOneWidget);
      expect(find.text('even'), findsOneWidget);
    },
  );

  testWidgets('stacks the amount under the title at text scale 2', (
    tester,
  ) async {
    await tester.pumpWidget(kitApp(rows(), textScale: 2));
    final title = tester.getRect(find.text('Sam Patel'));
    final amount = tester.getRect(find.text('+£12.00'));
    expect(amount.top, greaterThan(title.bottom));
    await tester.pumpWidget(kitApp(rows()));
    final title1 = tester.getRect(find.text('Sam Patel'));
    final amount1 = tester.getRect(find.text('+£12.00'));
    expect(amount1.top, lessThan(title1.bottom));
  });

  testWidgets('one semantics node with name, direction and amount', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var taps = 0;
    await tester.pumpWidget(
      kitApp(
        BalanceRow(
          kind: BalanceRowKind.person,
          id: 'p',
          title: 'Sam',
          subtitle: 'In Flat 4B',
          net: const {'GBP': 1200},
          onTap: () => taps++,
        ),
      ),
    );
    expect(
      find.bySemanticsLabel('Sam, owes you 12.00 GBP, In Flat 4B'),
      findsOneWidget,
    );
    await tester.tap(find.byType(BalanceRow));
    expect(taps, 1);
    handle.dispose();
  });

  test('direction words are fixed per kind', () {
    expect(BalanceRow.directionWord(BalanceRowKind.person, 1), 'owes you');
    expect(BalanceRow.directionWord(BalanceRowKind.person, -1), 'you owe');
    expect(BalanceRow.directionWord(BalanceRowKind.group, 1), "you're owed");
    expect(BalanceRow.directionWord(BalanceRowKind.member, 1), 'gets back');
    expect(BalanceRow.directionWord(BalanceRowKind.member, -1), 'owes');
    expect(BalanceRow.directionWord(BalanceRowKind.group, 0), 'even');
  });

  test('leading currency is the largest absolute amount', () {
    expect(BalanceRow.leadingEntry({'GBP': 10, 'EUR': -500})!.key, 'EUR');
    expect(BalanceRow.leadingEntry({'GBP': 0}), isNull);
  });
}
