// Regression tests for QA VISUAL-R39-01: Settle up never offers a payment
// the ledger refuses. A balance above Money.maxMinor (one payment's limit)
// is offered up to that limit, the screen names what will still be owed,
// "Pay part of it" opens on the offered amount, and the balance is settled
// in as many payments as it takes. Every currency, any size of debt.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/format/money_format.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import 'real_harness.dart';

/// [n] expenses of [each] minor units, paid by me, owed by Priya.
Future<(GroupId, MemberId, MemberId)> _debt(
  RealWorld w,
  String currency,
  List<int> amounts,
) async {
  final gid = await w.seedGroup(
    name: 'Goa',
    people: const ['Priya'],
    currency: currency,
  );
  final me = w.member(gid, 'Arjun');
  final priya = w.member(gid, 'Priya');
  for (final a in amounts) {
    await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Land',
        total: a,
        currency: currency,
        paidBy: SplitSpec(SplitMethod.exact, {me: a}),
        owedBy: SplitSpec.single(priya, a),
        date: qaNow.toUtc(),
        category: 'transport',
      ),
    );
  }
  return (gid, me, priya);
}

int _owed(RealWorld w, GroupId gid) => BalanceCalculator.suggestedTransfers(
  w.group(gid),
).fold(0, (a, t) => a + t.amount);

Future<void> _record(WidgetTester tester, RealWorld w, String label) async {
  await qaTap(tester, find.text(S.recordPayment(label)));
  await tester.pump(const Duration(seconds: 2));
  await qaSettle(tester);
}

void main() {
  for (final code in ['INR', 'JPY', 'KWD', 'USD']) {
    testWidgets('$code: a balance of twice the limit is settled in two '
        'payments, each one the ledger records', (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final (gid, me, priya) = await _debt(w, code, [
        Money.maxMinor,
        Money.maxMinor,
      ]);
      await pumpReal(tester, w, location: Routes.home);
      final most = MoneyFormat.format(Money.maxMinor, code);

      w.push(Routes.settle(groupId: gid, from: priya, to: me));
      await qaSettle(tester);
      expect(find.text(S.recordPayment(most)), findsOneWidget);
      expect(find.text(S.paymentCap(most, most)), findsOneWidget);
      expect(find.text(S.errInvalidInput), findsNothing);
      await _record(tester, w, most);
      expect(find.text(S.errInvalidInput), findsNothing);
      expect(snackText(tester), S.paymentRecorded);
      expect(
        w.group(gid).liveExpenses.where((e) => e.isPayment).single.money.total,
        Money.maxMinor,
      );
      expect(_owed(w, gid), Money.maxMinor);

      // The rest: one payment of exactly the limit, no note.
      w.push(Routes.settle(groupId: gid, from: priya, to: me));
      await qaSettle(tester);
      expect(find.text(S.recordPayment(most)), findsOneWidget);
      expect(find.textContaining('at most'), findsNothing);
      await _record(tester, w, most);
      expect(_owed(w, gid), 0);
      await w.shutdown(tester);
    });
  }

  testWidgets('a balance one minor unit above the limit: the limit is '
      'offered and ₹0.01 is named as still owed', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final (gid, me, priya) = await _debt(w, 'INR', [Money.maxMinor, 1]);
    await pumpReal(tester, w, location: Routes.home);
    final most = MoneyFormat.format(Money.maxMinor, 'INR');
    w.push(Routes.settle(groupId: gid, from: priya, to: me));
    await qaSettle(tester);
    expect(find.text(S.paymentCap(most, '₹0.01')), findsOneWidget);
    await _record(tester, w, most);
    expect(_owed(w, gid), 1);
    w.push(Routes.settle(groupId: gid, from: priya, to: me));
    await qaSettle(tester);
    expect(find.text(S.recordPayment('₹0.01')), findsOneWidget);
    expect(find.textContaining('at most'), findsNothing);
    await _record(tester, w, '₹0.01');
    expect(_owed(w, gid), 0);
    await w.shutdown(tester);
  });

  testWidgets('"Pay part of it" on a balance above the limit opens on the '
      'offered amount, not on 0, and a smaller part drops the note', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final (gid, me, priya) = await _debt(w, 'INR', [
      Money.maxMinor,
      Money.maxMinor,
    ]);
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.settle(groupId: gid, from: priya, to: me));
    await qaSettle(tester);
    await qaTap(tester, find.text(S.payPartOfIt));
    expect(find.text(S.partTitle), findsOneWidget);
    expect(find.text('99,99,99,999.99'), findsOneWidget);
    await tester.enterText(find.text('99,99,99,999.99'), '500');
    await tester.pump();
    await qaTap(tester, find.text(S.done));
    expect(find.text(S.recordPayment('₹500')), findsOneWidget);
    expect(find.textContaining('at most'), findsNothing);
    await _record(tester, w, '₹500');
    expect(_owed(w, gid), 2 * Money.maxMinor - 50000);
    await w.shutdown(tester);
  });

  testWidgets('a balance of exactly the limit is offered in full with no '
      'note', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final (gid, me, priya) = await _debt(w, 'INR', [Money.maxMinor]);
    await pumpReal(tester, w, location: Routes.home);
    final most = MoneyFormat.format(Money.maxMinor, 'INR');
    w.push(Routes.settle(groupId: gid, from: priya, to: me));
    await qaSettle(tester);
    expect(find.text(S.recordPayment(most)), findsOneWidget);
    expect(find.text(S.payPartOfIt), findsOneWidget);
    expect(find.textContaining('at most'), findsNothing);
    await _record(tester, w, most);
    expect(_owed(w, gid), 0);
    await w.shutdown(tester);
  });
}
