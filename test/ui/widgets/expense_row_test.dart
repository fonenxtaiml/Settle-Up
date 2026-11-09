import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'kit_harness.dart';

const names = {'me': 'You', 'priya': 'Priya', 'ravi': 'Ravi', 'sam': 'Sam'};

final lent = testExpense(
  description: 'Dinner at the shack',
  paid: {'me': 6000},
  owed: {'me': 1500, 'priya': 1500, 'ravi': 1500, 'sam': 1500},
);
final borrowed = testExpense(
  id: 'e2',
  description: 'Taxi to airport',
  category: 'transport.taxi',
  paid: {'priya': 2400},
  owed: {'me': 600, 'priya': 600, 'ravi': 600, 'sam': 600},
);
final notInvolved = testExpense(
  id: 'e3',
  description: 'Hotel deposit',
  category: 'transport.hotel',
  paid: {'ravi': 30000},
  owed: {'ravi': 15000, 'sam': 15000},
);
final multiPayer = testExpense(
  id: 'e4',
  description: 'Groceries',
  category: 'food.groceries',
  paid: {'me': 4000, 'sam': 4000},
  owed: {'me': 4000, 'sam': 4000},
);
final payment = testExpense(
  id: 'e5',
  kind: ExpenseKind.payment,
  description: '',
  paid: {'sam': 2000},
  owed: {'me': 2000},
);

void main() {
  setUpAll(configureKitTests);

  testKitVariants(
    'expense rows',
    () => Column(
      children: [
        ExpenseRow(expense: lent, memberNames: names, myMemberId: 'me'),
        ExpenseRow(
          expense: borrowed,
          memberNames: names,
          myMemberId: 'me',
          unshared: true,
        ),
        ExpenseRow(expense: notInvolved, memberNames: names, myMemberId: 'me'),
        ExpenseRow(expense: multiPayer, memberNames: names, myMemberId: 'me'),
        ExpenseRow(expense: payment, memberNames: names, myMemberId: 'me'),
        ExpenseRow(
          expense: lent,
          memberNames: names,
          myMemberId: 'me',
          deleted: true,
          onRestore: () {},
        ),
      ],
    ),
    verify: (tester, v) async {
      expect(find.text('you lent'), findsOneWidget);
      expect(find.text('+£45.00'), findsOneWidget);
      expect(find.text('You paid £60.00'), findsNWidgets(2));
      expect(find.text('you borrowed'), findsOneWidget);
      expect(find.text('−£6.00'), findsOneWidget);
      expect(find.text('Priya paid £24.00'), findsOneWidget);
      expect(find.text('not involved'), findsOneWidget);
      expect(find.text('2 people paid £80.00'), findsOneWidget);
      expect(find.text('Sam paid you'), findsOneWidget);
      expect(find.text('Payment'), findsOneWidget);
      expect(find.text('£20.00'), findsOneWidget);
      expect(find.text('Restore'), findsOneWidget);
    },
  );

  testWidgets('restore button fires and unshared dot is labelled', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    var restored = 0;
    await tester.pumpWidget(
      kitApp(
        Column(
          children: [
            ExpenseRow(
              expense: lent,
              memberNames: names,
              myMemberId: 'me',
              deleted: true,
              onRestore: () => restored++,
            ),
            ExpenseRow(
              expense: borrowed,
              memberNames: names,
              myMemberId: 'me',
              unshared: true,
            ),
          ],
        ),
      ),
    );
    await tester.tap(find.text('Restore'));
    expect(restored, 1);
    expect(
      find.bySemanticsLabel(RegExp('Taxi to airport.*Not yet shared')),
      findsOneWidget,
    );
    handle.dispose();
  });

  test('impact classification', () {
    expect(ExpenseRow.impactOf(lent, 'me'), ExpenseImpact.lent);
    expect(ExpenseRow.impactOf(borrowed, 'me'), ExpenseImpact.borrowed);
    expect(ExpenseRow.impactOf(notInvolved, 'me'), ExpenseImpact.notInvolved);
    expect(ExpenseRow.impactOf(multiPayer, 'me'), ExpenseImpact.even);
    expect(ExpenseRow.impactOf(lent, null), ExpenseImpact.notInvolved);
  });

  test('payment titles name both sides', () {
    final row = ExpenseRow(
      expense: payment,
      memberNames: names,
      myMemberId: 'me',
    );
    expect(row.paymentTitle(), 'Sam paid you');
    final other = ExpenseRow(
      expense: payment,
      memberNames: names,
      myMemberId: 'ravi',
    );
    expect(other.paymentTitle(), 'Sam paid You');
  });
}
