// QA UIFLOW round 44: final full regression sweep of the UI flows on the
// real Ledger. Probes the code changed since the last sweep from the paths
// the earlier rounds left out: the currency picker on Edit expense (several
// payers and an exact split loaded from the ledger), an edit in a group
// whose currency is not the expense's, Add expense with a person who has
// no 1:1 group yet moved to another currency, and the one-line prompts
// (your name, phone name) that now wrap on screen and save on the
// keyboard's Done.
// Tests named "QA UIFLOW-R44-NN" with `skip:` are failing repros of an open
// finding.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'real_harness.dart';

Future<void> _pickCurrencyCode(
  WidgetTester tester,
  String from,
  String code,
) async {
  final symbol = find.descendant(
    of: find.byType(AmountField),
    matching: find.text(Currencies.of(from).symbol),
  );
  await qaTap(tester, symbol.first);
  await tester.enterText(
    find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(TextField),
    ),
    code,
  );
  await qaSettle(tester);
  await qaTap(tester, find.widgetWithText(ListTile, code).first);
}

String _amountText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text;

Future<void> _io(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await qaSettle(tester);
}

/// Goa (Arjun, Priya, Rahul) with one expense paid by two people.
Future<(GroupId, ExpenseId)> _seedTwoPayers(
  RealWorld w, {
  required int mine,
  required int priyas,
  SplitSpec? owed,
}) async {
  final gid = await w.seedGroup(name: 'Goa');
  final me = w.member(gid, 'Arjun');
  final priya = w.member(gid, 'Priya');
  final rahul = w.member(gid, 'Rahul');
  final eid = await w.ledger.addExpense(
    ExpenseDraft(
      groupId: gid,
      description: 'Houseboat',
      total: mine + priyas,
      currency: 'INR',
      paidBy: SplitSpec(SplitMethod.exact, {me: mine, priya: priyas}),
      owedBy: owed ?? SplitSpec.equal([me, priya, rahul]),
      category: 'travel.hotel',
      date: DateTime.utc(2026, 11, 5, 18, 30),
      notes: 'Two nights',
    ),
  );
  return (gid, eid);
}

void main() {
  testWidgets('R44 sweep: Edit an expense two people paid (₹200 + ₹100), '
      'currency to yen: Save stores ¥200 + ¥100, and the untouched fields '
      'stay', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final (gid, eid) = await _seedTwoPayers(w, mine: 20000, priyas: 10000);
    final before = w.state.expense(eid)!;
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.editExpense(eid));
    await qaSettle(tester);
    expect(find.text(S.peoplePaid(2)), findsOneWidget);
    await _pickCurrencyCode(tester, 'INR', 'JPY');
    expect(_amountText(tester), '300');
    expect(find.text(S.peoplePaid(2)), findsOneWidget);
    await qaTap(tester, find.text(S.saveExpense));
    await _io(tester);
    expect(snackText(tester), S.expenseSaved);
    final e = w.state.expense(eid)!;
    expect(e.money.currency, 'JPY');
    expect(e.money.total, 300);
    expect(e.money.paid, {
      w.member(gid, 'Arjun'): 200,
      w.member(gid, 'Priya'): 100,
    });
    expect(e.money.owed.values.toSet(), {100});
    expect(e.description, before.description);
    expect(e.notes, before.notes);
    expect(e.category, before.category);
    expect(e.date, before.date);
    await w.shutdown(tester);
  });

  testWidgets('R44 sweep: Edit an expense two people paid (₹150.50 + '
      '₹149.50), currency to yen: the payers stay, nothing is rounded, and '
      'Save writes nothing until the amounts are typed again', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final (gid, eid) = await _seedTwoPayers(w, mine: 15050, priyas: 14950);
    final ops = w.ledger.current.ops.length;
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.editExpense(eid));
    await qaSettle(tester);
    await _pickCurrencyCode(tester, 'INR', 'JPY');
    // ₹300.00 moves; the payers' halves cannot.
    expect(_amountText(tester), '300');
    expect(find.text(S.multiplePeople), findsOneWidget);
    await qaTap(tester, find.text(S.saveExpense));
    await _io(tester);
    expect(w.ledger.current.ops.length, ops);
    final e = w.state.expense(eid)!;
    expect(e.money.currency, 'INR');
    expect(e.money.total, 30000);
    expect(w.location, Routes.editExpense(eid));
    // Typing the payers again in yen saves exactly that.
    await qaTap(tester, find.text(S.paidBy));
    await qaTap(tester, find.text(S.multiplePeople).last);
    final fields = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), '151');
    await tester.enterText(fields.at(1), '149');
    await tester.pump();
    await qaTap(tester, find.widgetWithText(FilledButton, S.done));
    expect(find.text(S.peoplePaid(2)), findsOneWidget);
    await qaTap(tester, find.text(S.saveExpense));
    await _io(tester);
    final saved = w.state.expense(eid)!;
    expect(saved.money.currency, 'JPY');
    expect(saved.money.total, 300);
    expect(saved.money.paid, {
      w.member(gid, 'Arjun'): 151,
      w.member(gid, 'Priya'): 149,
    });
    await w.shutdown(tester);
  });

  testWidgets('R44 sweep: Edit an exact split loaded from the ledger '
      '(₹100 / ₹200 / ₹300), currency to yen: the typed shares read in yen '
      'and Save stores ¥600 as ¥100 / ¥200 / ¥300', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(name: 'Goa');
    final me = w.member(gid, 'Arjun');
    final priya = w.member(gid, 'Priya');
    final rahul = w.member(gid, 'Rahul');
    final eid = await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Scuba',
        total: 60000,
        currency: 'INR',
        paidBy: SplitSpec.single(me, 60000),
        owedBy: SplitSpec(SplitMethod.exact, {
          me: 10000,
          priya: 20000,
          rahul: 30000,
        }),
        category: 'general',
        date: DateTime.utc(2026, 11, 5),
      ),
    );
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.editExpense(eid));
    await qaSettle(tester);
    await _pickCurrencyCode(tester, 'INR', 'JPY');
    expect(_amountText(tester), '600');
    await qaTap(tester, find.text(S.saveExpense));
    await _io(tester);
    final e = w.state.expense(eid)!;
    expect(e.money.currency, 'JPY', reason: 'on screen: ${w.location}');
    expect(e.money.total, 600);
    expect(e.money.owed, {me: 100, priya: 200, rahul: 300});
    expect(e.money.owedBy.method, SplitMethod.exact);
    await w.shutdown(tester);
  });

  testWidgets('R44 sweep: an expense in dollars in a rupee group, opened in '
      'Edit and saved untouched, writes no op and keeps \$45.50', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(name: 'Goa', people: const ['Priya']);
    final me = w.member(gid, 'Arjun');
    final priya = w.member(gid, 'Priya');
    final eid = await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Visa fee',
        total: 4550,
        currency: 'USD',
        paidBy: SplitSpec(SplitMethod.exact, {me: 2550, priya: 2000}),
        owedBy: SplitSpec.equal([me, priya]),
        category: 'general',
        date: DateTime.utc(2026, 11, 5),
      ),
    );
    final ops = w.ledger.current.ops.length;
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.editExpense(eid));
    await qaSettle(tester);
    expect(_amountText(tester), '45.50');
    expect(find.text(S.peoplePaid(2)), findsOneWidget);
    await qaTap(tester, find.text(S.saveExpense));
    await _io(tester);
    expect(w.ledger.current.ops.length, ops);
    final e = w.state.expense(eid)!;
    expect(e.money.currency, 'USD');
    expect(e.money.total, 4550);
    expect(e.money.paid, {me: 2550, priya: 2000});
    await w.shutdown(tester);
  });

  testWidgets('R44 sweep: an expense in a yen group opened in Edit, currency '
      'to rupees: ¥300 reads ₹300 and Save stores 30000 INR', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(
      name: 'Tokyo',
      people: const ['Kenji'],
      currency: 'JPY',
    );
    final me = w.member(gid, 'Arjun');
    final kenji = w.member(gid, 'Kenji');
    final eid = await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Ramen',
        total: 300,
        currency: 'JPY',
        paidBy: SplitSpec.single(me, 300),
        owedBy: SplitSpec.equal([me, kenji]),
        category: 'general',
        date: DateTime.utc(2026, 11, 5),
      ),
    );
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.editExpense(eid));
    await qaSettle(tester);
    expect(_amountText(tester), '300');
    await _pickCurrencyCode(tester, 'JPY', 'INR');
    expect(_amountText(tester), '300');
    await qaTap(tester, find.text(S.saveExpense));
    await _io(tester);
    final e = w.state.expense(eid)!;
    expect(e.money.currency, 'INR');
    expect(e.money.total, 30000);
    expect(e.money.paid, {me: 30000});
    expect(e.money.owed, {me: 15000, kenji: 15000});
    await w.shutdown(tester);
  });

  testWidgets('R44 sweep: Add expense with a person who has no 1:1 group '
      'yet, ₹300 moved to yen: Save stores ¥300 in the new 1:1 group', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya']);
    final priyaPerson = w
        .group(gid)
        .activeMembers
        .firstWhere((m) => m.displayName == 'Priya')
        .personId;
    await pumpReal(tester, w);
    w.push(Routes.newExpense(personId: priyaPerson));
    await qaSettle(tester);
    await tester.enterText(find.byType(TextField).at(0), '300');
    await tester.enterText(fieldLabeled(S.description), 'Sushi');
    await tester.pump();
    await _pickCurrencyCode(tester, 'INR', 'JPY');
    expect(_amountText(tester), '300');
    await qaTap(tester, find.text(S.saveExpense));
    await _io(tester);
    final direct = w.state.visibleGroups.where((g) => g.group!.isDirect);
    expect(direct, hasLength(1));
    final e = direct.single.liveExpenses.single;
    expect(e.money.currency, 'JPY');
    expect(e.money.total, 300);
    expect(e.money.owed.values.toSet(), {150});
    await w.shutdown(tester);
  });

  testWidgets('R44 sweep: Settings, your name: the keyboard\'s Done saves '
      'the new name, and every group you are in takes it', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text('Arjun'));
    expect(find.text(S.editName), findsOneWidget);
    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, 'Arjun Mehta');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _io(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(w.settings.profile!.displayName, 'Arjun Mehta');
    expect(
      w.group(gid).memberForPerson(w.settings.profile!.personId)!.displayName,
      'Arjun Mehta',
    );
    await w.shutdown(tester);
  });

  testWidgets('R44 sweep: Settings, your name: a pasted line break never '
      'reaches the saved name', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text('Arjun'));
    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, 'Arjun\nMehta');
    await tester.pump();
    final typed = tester.widget<TextField>(field).controller!.text;
    expect(typed.contains('\n'), isFalse, reason: 'field holds "$typed"');
    await qaTap(tester, find.widgetWithText(FilledButton, S.save));
    await _io(tester);
    expect(w.settings.profile!.displayName.contains('\n'), isFalse);
    await w.shutdown(tester);
  });

  testWidgets('R44 sweep: Settings, phone name: the keyboard\'s Done saves '
      'it; a blank one is refused and the old name stays', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text(S.phoneName));
    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '   ');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _io(tester);
    expect(find.byType(AlertDialog), findsOneWidget);
    await tester.enterText(field, "Arjun's Pixel");
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await _io(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(w.settings.device.deviceName, "Arjun's Pixel");
    expect(find.text(S.thisPhoneLine("Arjun's Pixel")), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('R44 sweep: Settle up with Priya: the note prompt stays a '
      'multiline field, and Record stores a two-line note', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(name: 'Goa', people: const ['Priya']);
    final me = w.member(gid, 'Arjun');
    final priya = w.member(gid, 'Priya');
    await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Dinner',
        total: 60000,
        currency: 'INR',
        paidBy: SplitSpec.single(me, 60000),
        owedBy: SplitSpec.equal([me, priya]),
        category: 'general',
        date: qaNow.toUtc(),
      ),
    );
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.settle(groupId: gid, from: priya, to: me));
    await qaSettle(tester);
    await qaTap(tester, find.text(S.notes));
    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(
      tester.widget<TextField>(field).keyboardType,
      TextInputType.multiline,
    );
    await tester.enterText(field, 'GPay\nref 42');
    await tester.pump();
    await qaTap(tester, find.widgetWithText(FilledButton, S.save));
    await qaTap(tester, find.textContaining('Record'));
    await _io(tester);
    await tester.pump(const Duration(seconds: 3));
    await qaSettle(tester);
    final p = w.group(gid).liveExpenses.where((e) => e.isPayment).single;
    expect(p.notes, 'GPay\nref 42');
    expect(p.money.total, 30000);
    await w.shutdown(tester);
  });
}
