// QA UIFLOW: delete -> undo -> restore, edit keeps untouched fields, and
// payment edit, on the real Ledger.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import 'real_harness.dart';

Future<(GroupId, ExpenseId)> seedExpense(RealWorld w) async {
  final gid = await w.seedGroup();
  final me = w.member(gid, 'Arjun');
  final priya = w.member(gid, 'Priya');
  final rahul = w.member(gid, 'Rahul');
  final eid = await w.ledger.addExpense(
    ExpenseDraft(
      groupId: gid,
      description: 'Groceries at Nature Basket',
      total: 90000,
      currency: 'INR',
      paidBy: SplitSpec(SplitMethod.exact, {me: 60000, priya: 30000}),
      owedBy: SplitSpec(SplitMethod.exact, {
        me: 20000,
        priya: 30000,
        rahul: 40000,
      }),
      category: 'food.groceries',
      date: DateTime.utc(2026, 11, 5, 18, 30),
      notes: 'Includes the wine',
    ),
  );
  return (gid, eid);
}

Operation lastOp(RealWorld w) => w.ledger.current.ops.reduce(
  (a, b) => a.hlc.compareTo(b.hlc) >= 0 ? a : b,
);

void main() {
  testWidgets('delete from detail, Undo on the snack bar restores it', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final (gid, eid) = await seedExpense(w);
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    await qaTap(tester, find.text('Groceries at Nature Basket'));
    expect(w.location, Routes.expense(eid));

    await qaTap(tester, find.byTooltip(S.moreOptions));
    await qaTap(tester, find.text(S.deleteExpense));
    expect(
      find.text(S.deleteExpenseTitle('Groceries at Nature Basket')),
      findsOneWidget,
    );
    await qaTap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(S.delete),
      ),
    );
    expect(w.state.expense(eid)!.isDeleted, isTrue);
    expect(w.location, Routes.group(gid));
    expect(snackText(tester), S.expenseDeleted);
    expect(find.text('Groceries at Nature Basket'), findsNothing);

    await tester.tap(find.text(S.undo));
    await qaSettle(tester);
    expect(w.state.expense(eid)!.isDeleted, isFalse);
    expect(find.text('Groceries at Nature Basket'), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('a deleted expense is restored from its detail banner, and '
      'from the Activity feed', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final (gid, eid) = await seedExpense(w);
    await w.ledger.deleteExpense(eid);
    await pumpReal(tester, w, location: Routes.home);

    w.push(Routes.expense(eid));
    await qaSettle(tester);
    expect(find.text(S.deletedBanner), findsOneWidget);
    expect(find.byTooltip(S.edit), findsNothing);
    await qaTap(tester, find.widgetWithText(FilledButton, S.restore));
    expect(w.state.expense(eid)!.isDeleted, isFalse);
    expect(snackText(tester), S.expenseRestored);
    expect(find.text(S.deletedBanner), findsNothing);

    // Delete again and restore from the Activity row.
    await w.ledger.deleteExpense(eid);
    w.go(Routes.activity);
    await qaSettle(tester);
    expect(
      find.text(S.actDeletedExpense(S.you, 'Groceries at Nature Basket')),
      findsNWidgets(2),
    );
    await qaTap(tester, find.widgetWithText(TextButton, S.restore).first);
    expect(w.state.expense(eid)!.isDeleted, isFalse);
    expect(gid, isNotEmpty);
    await w.shutdown(tester);
  });

  testWidgets('edit: changing only the description writes only the '
      'description; payers, split, date, notes, category survive', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final (_, eid) = await seedExpense(w);
    final before = w.state.expense(eid)!;
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.expense(eid));
    await qaSettle(tester);
    await qaTap(tester, find.byTooltip(S.edit));
    expect(find.text(S.editExpenseTitle), findsOneWidget);
    expect(find.text(S.peoplePaid(2)), findsOneWidget);

    await tester.enterText(fieldLabeled(S.description), 'Groceries (big shop)');
    await tester.pump();
    await qaTap(tester, find.text(S.saveExpense));
    expect(snackText(tester), S.expenseSaved);
    expect(w.location, Routes.expense(eid));

    final op = lastOp(w);
    expect(op.kind, OpKind.update);
    expect(op.payload.keys.toSet(), {ExpenseFields.description});
    final after = w.state.expense(eid)!;
    expect(after.description, 'Groceries (big shop)');
    expect(after.money.paid, before.money.paid);
    expect(after.money.owed, before.money.owed);
    expect(after.money.owedBy.method, SplitMethod.exact);
    expect(after.date, before.date);
    expect(after.notes, 'Includes the wine');
    expect(after.category, 'food.groceries');
    await w.shutdown(tester);
  });

  testWidgets('edit with no change writes no op', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final (_, eid) = await seedExpense(w);
    final ops = w.ledger.current.ops.length;
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.editExpense(eid));
    await qaSettle(tester);
    await qaTap(tester, find.text(S.saveExpense));
    expect(w.ledger.current.ops.length, ops);
    await w.shutdown(tester);
  });

  testWidgets('payment edit: amount and note change, people stay', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final me = w.member(gid, 'Arjun');
    final priya = w.member(gid, 'Priya');
    final pid = await w.ledger.recordPayment(
      PaymentDraft(
        groupId: gid,
        from: priya,
        to: me,
        amount: 50000,
        currency: 'INR',
        method: PaymentMethod.upi,
        date: DateTime.utc(2026, 11, 8),
      ),
    );
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.editExpense(pid));
    await qaSettle(tester);
    expect(find.text(S.paymentTitle), findsWidgets);
    await tester.enterText(find.byType(TextField).first, '450');
    await tester.enterText(fieldLabeled(S.notes), 'GPay');
    await tester.pump();
    await qaTap(tester, find.text(S.saveChanges));
    final p = w.state.expense(pid)!;
    expect(p.isPayment, isTrue);
    expect(p.money.total, 45000);
    expect(p.notes, 'GPay');
    expect(p.payer, priya);
    expect(p.receiver, me);
    expect(p.paymentMethod, PaymentMethod.upi);
    await w.shutdown(tester);
  });

  testWidgets('Undo on "Expense added" deletes the new expense', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.newExpense(groupId: gid));
    await qaSettle(tester);
    await tester.enterText(find.byType(TextField).at(0), '120');
    await tester.enterText(fieldLabeled(S.description), 'Chai');
    await tester.pump();
    await qaTap(tester, find.text(S.saveExpense));
    expect(w.group(gid).liveExpenses, hasLength(1));
    await tester.tap(find.text(S.undo));
    await qaSettle(tester);
    expect(w.group(gid).liveExpenses, isEmpty);
    await w.shutdown(tester);
  });
}
