// QA UIFLOW round 15: final regression sweep on the integrated build, over
// the real Ledger(MemoryOpStore) + KvSettingsRepository and the real
// DefaultSyncEngine with no transports. Probes the charter's riskiest
// paths again where code changed after round 6: the stock date picker in
// every editor, the strict amount grammar in split inputs, the shares
// prompt, the stored-length name cap on every name field, and editing an
// expense whose people left the group.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

import 'expense_flow_test.dart'
    show openAddExpense, saveEnabled, splitInput, typeAmountAndDescription;
import 'expense_lifecycle_test.dart' show lastOp, seedExpense;
import 'real_harness.dart';

Finder _inDialog(Finder f) =>
    find.descendant(of: find.byType(Dialog), matching: f);

/// Opens the date row of the editor on screen and picks [day] of the
/// month the picker opens on.
Future<void> _pickDay(WidgetTester tester, int day) async {
  await qaTap(tester, find.text(S.date));
  expect(find.byType(DatePickerDialog), findsOneWidget);
  await tester.tap(_inDialog(find.text('$day')).first);
  await tester.pump();
  await tester.tap(_inDialog(find.text('OK')));
  await qaSettle(tester);
}

void main() {
  testWidgets('R15 probe: Edit expense, only the date changed through the '
      'picker writes only the date; the time of day, payers, split, notes '
      'and category survive', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final (_, eid) = await seedExpense(w);
    final before = w.state.expense(eid)!;
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.editExpense(eid));
    await qaSettle(tester);
    await _pickDay(tester, 2);
    await qaTap(tester, find.text(S.saveExpense));
    expect(snackText(tester), S.expenseSaved);

    final op = lastOp(w);
    expect(op.kind, OpKind.update);
    expect(op.payload.keys.toSet(), {ExpenseFields.date});
    final after = w.state.expense(eid)!;
    final local = after.date.toLocal();
    final was = before.date.toLocal();
    expect((local.year, local.month, local.day), (was.year, was.month, 2));
    expect((local.hour, local.minute), (was.hour, was.minute));
    expect(after.money.paid, before.money.paid);
    expect(after.money.owed, before.money.owed);
    expect(after.notes, before.notes);
    expect(after.category, before.category);
    expect(after.description, before.description);
    await w.shutdown(tester);
  });

  testWidgets('R15 probe: Cancel on the date picker changes nothing and '
      'leaves the editor pristine (Android back closes it without asking)', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final (gid, eid) = await seedExpense(w);
    final ops = w.ledger.current.ops.length;
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    w.push(Routes.editExpense(eid));
    await qaSettle(tester);
    await qaTap(tester, find.text(S.date));
    await tester.tap(_inDialog(find.text('Cancel')));
    await qaSettle(tester);
    expect(find.byType(DatePickerDialog), findsNothing);
    await tester.binding.handlePopRoute();
    await qaSettle(tester);
    expect(find.text(S.discardTitle), findsNothing);
    expect(w.location, Routes.group(gid));
    expect(w.ledger.current.ops.length, ops);
    await w.shutdown(tester);
  });

  testWidgets('R15 probe: payment edit, a new date through the picker is '
      'saved with the time of day; amount, method and people stay', (
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
        date: DateTime(2026, 11, 8, 19, 45).toUtc(),
        notes: 'Dinner',
      ),
    );
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.editExpense(pid));
    await qaSettle(tester);
    expect(find.text(S.paymentTitle), findsWidgets);
    await _pickDay(tester, 3);
    await qaTap(tester, find.text(S.saveChanges));
    final p = w.state.expense(pid)!;
    final d = p.date.toLocal();
    expect((d.year, d.month, d.day, d.hour, d.minute), (2026, 11, 3, 19, 45));
    expect(p.money.total, 50000);
    expect(p.paymentMethod, PaymentMethod.upi);
    expect((p.payer, p.receiver), (priya, me));
    expect(p.notes, 'Dinner');
    await w.shutdown(tester);
  });

  testWidgets('R15 probe: payment edit with no change writes no op', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final pid = await w.ledger.recordPayment(
      PaymentDraft(
        groupId: gid,
        from: w.member(gid, 'Priya'),
        to: w.member(gid, 'Arjun'),
        amount: 50000,
        currency: 'INR',
        method: PaymentMethod.cash,
        date: DateTime.utc(2026, 11, 8),
      ),
    );
    final ops = w.ledger.current.ops.length;
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.editExpense(pid));
    await qaSettle(tester);
    await qaTap(tester, find.text(S.saveChanges));
    expect(w.ledger.current.ops.length, ops);
    await w.shutdown(tester);
  });

  testWidgets('R15 probe: settle up through the screen with a picked date '
      'records the payment on that day, and the Home hero follows', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final me = w.member(gid, 'Arjun');
    final priya = w.member(gid, 'Priya');
    await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Cab',
        total: 60000,
        currency: 'INR',
        paidBy: SplitSpec.single(me, 60000),
        owedBy: SplitSpec(SplitMethod.exact, {
          me: 20000,
          priya: 20000,
          w.member(gid, 'Rahul'): 20000,
        }),
        category: 'transport.taxi',
        date: DateTime.utc(2026, 11, 5),
      ),
    );
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.settle(groupId: gid, from: priya, to: me));
    await qaSettle(tester);
    await _pickDay(tester, 6);
    final record = find.byWidgetPredicate(
      (x) => x is FilledButton && x.onPressed != null,
    );
    await qaTap(tester, record.last);
    final pay = w.group(gid).liveExpenses.singleWhere((e) => e.isPayment);
    final d = pay.date.toLocal();
    expect((d.year, d.month, d.day), (2026, 11, 6));
    expect(pay.money.total, 20000);
    expect((pay.payer, pay.receiver), (priya, me));
    w.go(Routes.home);
    await qaSettle(tester);
    // Rahul alone still owes me ₹200.
    expect(find.textContaining('200'), findsWidgets);
    await w.shutdown(tester);
  });

  testWidgets('R15 probe: an old expense whose person settled up and was '
      'removed is still edited, and the removed person stays in its split', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final me = w.member(gid, 'Arjun');
    final rahul = w.member(gid, 'Rahul');
    final eid = await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Fuel',
        total: 40000,
        currency: 'INR',
        paidBy: SplitSpec.single(me, 40000),
        owedBy: SplitSpec(SplitMethod.equal, {me: 1, rahul: 1}),
        category: 'transport.fuel',
        date: DateTime.utc(2026, 11, 1),
      ),
    );
    await w.ledger.recordPayment(
      PaymentDraft(
        groupId: gid,
        from: rahul,
        to: me,
        amount: 20000,
        currency: 'INR',
        method: PaymentMethod.cash,
        date: DateTime.utc(2026, 11, 2),
      ),
    );
    await w.ledger.removeMember(gid, rahul);
    expect(w.group(gid).activeMembers.map((m) => m.id), isNot(contains(rahul)));

    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.editExpense(eid, groupId: gid));
    await qaSettle(tester);
    expect(find.text(S.editExpenseTitle), findsOneWidget);
    await tester.enterText(fieldLabeled(S.description), 'Fuel to Lonavala');
    await tester.pump();
    expect(saveEnabled(tester), isTrue);
    await qaTap(tester, find.text(S.saveExpense));
    expect(snackText(tester), S.expenseSaved);
    final e = w.state.expense(eid)!;
    expect(e.description, 'Fuel to Lonavala');
    expect(e.money.owed[rahul], 20000);
    expect(lastOp(w).payload.keys.toSet(), {ExpenseFields.description});
    await w.shutdown(tester);
  });

  for (final typed in ['–30', '(30)', '30-', '- 30x']) {
    testWidgets('R15 probe: adjustment "$typed" is never read with its sign '
        'dropped: the split says it cannot read it and Save stays off', (
      tester,
    ) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await openAddExpense(tester, w);
      await typeAmountAndDescription(tester, '330', 'Drinks');
      await qaTap(tester, find.text(KitStrings.splitAdjust));
      await tester.enterText(splitInput(S.adjustmentOf('Priya')), typed);
      await tester.pump();
      final shown = tester
          .widget<TextField>(splitInput(S.adjustmentOf('Priya')))
          .controller!
          .text;
      if (shown.isNotEmpty && shown != typed) {
        // The input refused part of the edit: whatever it kept must read
        // as the user's sign, never a plus.
        expect(shown, isNot('30'), reason: 'sign dropped from "$typed"');
      }
      if (saveEnabled(tester)) {
        await qaTap(tester, find.text(S.saveExpense));
        final e = w.group(gid).liveExpenses.single;
        expect(
          e.money.owed[w.member(gid, 'Priya')],
          lessThan(11000),
          reason: '"$typed" saved as a plus',
        );
      } else {
        expect(find.text(S.splitUnreadable), findsOneWidget);
        expect(w.group(gid).liveExpenses, isEmpty);
      }
      await w.shutdown(tester);
    });
  }

  testWidgets('R15 probe: adjustment "₹-30" (symbol first) is read as minus '
      '30 and saves', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await openAddExpense(tester, w);
    await typeAmountAndDescription(tester, '330', 'Drinks');
    await qaTap(tester, find.text(KitStrings.splitAdjust));
    await tester.enterText(splitInput(S.adjustmentOf('Priya')), '-30');
    await tester.pump();
    expect(saveEnabled(tester), isTrue);
    await qaTap(tester, find.text(S.saveExpense));
    final e = w.group(gid).liveExpenses.single;
    expect(e.money.owed[w.member(gid, 'Priya')], 9000);
    expect(e.money.owed[w.member(gid, 'Arjun')], 12000);
    await w.shutdown(tester);
  });

  testWidgets('R15 probe: the shares number opens its prompt; a paste of '
      '"1 2" is refused whole and "3" sets three shares', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await openAddExpense(tester, w);
    await typeAmountAndDescription(tester, '500', 'Villa');
    await qaTap(tester, find.text(KitStrings.splitShares));
    // The middle "1" of the first stepper (my row).
    await qaTap(tester, find.text('1').first);
    final prompt = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(prompt, findsOneWidget);
    final field = tester.widget<TextField>(prompt);
    final before = field.controller!.text;
    // The formatter refuses an edit with anything but digits.
    final out = field.inputFormatters!.fold<TextEditingValue>(
      TextEditingValue(
        text: '1 2',
        selection: const TextSelection.collapsed(offset: 3),
      ),
      (v, f) => f.formatEditUpdate(TextEditingValue(text: before), v),
    );
    expect(out.text, before);
    await tester.enterText(prompt, '3');
    await tester.pump();
    await qaTap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byWidgetPredicate((x) => x is FilledButton),
      ),
    );
    expect(find.text(S.sharesSummary(5, 3)), findsOneWidget);
    await qaTap(tester, find.text(S.saveExpense));
    final e = w.group(gid).liveExpenses.single;
    expect(e.money.owedBy.method, SplitMethod.shares);
    expect(e.money.owed[w.member(gid, 'Arjun')], 30000);
    expect(e.money.owed[w.member(gid, 'Priya')], 10000);
    await w.shutdown(tester);
  });

  testWidgets('R15 probe: New group name is capped at 60 as stored, a 60th '
      'character that grows when stored is kept out, and the group is '
      'created with the shown name', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.newGroup);
    await qaSettle(tester);
    final name = fieldLabeled(S.groupName);
    await tester.enterText(name, 'a' * 65);
    await tester.pump();
    expect(tester.widget<TextField>(name).controller!.text, 'a' * 60);
    // 58 letters + "…" (stored as "...") would be 61 once stored.
    await tester.enterText(name, '${'b' * 58}…');
    await tester.pump();
    final shown = tester.widget<TextField>(name).controller!.text;
    expect(shown.length, lessThanOrEqualTo(60));
    await tester.enterText(name, '${'c' * 57}…');
    await tester.pump();
    expect(tester.widget<TextField>(name).controller!.text, '${'c' * 57}…');
    await qaTap(tester, find.text(S.createGroup));
    final g = w.state.visibleGroups.single;
    expect(g.group!.name, '${'c' * 57}...');
    await w.shutdown(tester);
  });

  testWidgets('R15 probe: Members > Add person with only symbols keeps the '
      'button off; Done shows the letter copy and adds nobody', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final count = w.group(gid).activeMembers.length;
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.members(gid));
    await qaSettle(tester);
    final field = find.byType(TextField).first;
    await tester.enterText(field, '...');
    await tester.pump();
    expect(filledButton(tester, S.addPerson).onPressed, isNull);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await qaSettle(tester);
    expect(find.text(S.nameNeedsLetter), findsOneWidget);
    expect(w.group(gid).activeMembers.length, count);
    expect(find.text(S.errGeneric), findsNothing);
    await w.shutdown(tester);
  });

  testWidgets('R15 probe: search finds a member by the name they were '
      'renamed to, and no longer by the old one', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final (gid, _) = await seedExpense(w);
    await w.ledger.renameMember(gid, w.member(gid, 'Rahul'), 'Rahul Kumar');
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.search);
    await qaSettle(tester);
    await tester.enterText(find.byType(TextField).first, 'kumar');
    await qaSettle(tester);
    expect(find.text('Groceries at Nature Basket'), findsWidgets);
    await w.shutdown(tester);
  });

  testWidgets('R15 probe: the group Activity names a payment edit and a '
      'date-only expense edit', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final (gid, eid) = await seedExpense(w);
    final e = w.state.expense(eid)!;
    await w.ledger.updateExpense(
      eid,
      ExpenseDraft(
        groupId: gid,
        description: e.description,
        total: e.money.total,
        currency: e.money.currency,
        paidBy: e.money.paidBy,
        owedBy: e.money.owedBy,
        category: e.category,
        date: DateTime.utc(2026, 11, 1, 18, 30),
        notes: e.notes,
      ),
    );
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.groupActivity(gid));
    await qaSettle(tester);
    expect(
      find.text(S.actEditedExpense(S.you, 'Groceries at Nature Basket')),
      findsOneWidget,
    );
    await w.shutdown(tester);
  });

  testWidgets('R15 probe: onboarding, while the keyboard composes, a name '
      'that grows past 40 when stored shows "too long" with Get started off; '
      'committing the word cuts it to fit and saves that', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create();
    await pumpReal(tester, w);
    expect(find.text(S.onboardingTitle), findsOneWidget);
    final field = find.byType(TextField).first;
    await tester.showKeyboard(field);
    // 39 letters and U+2026, stored as "..." (42 characters).
    final long = '${'a' * 39}…';
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: long,
        selection: TextSelection.collapsed(offset: long.length),
        composing: TextRange(start: 35, end: long.length),
      ),
    );
    await tester.pump();
    expect(filledButton(tester, S.getStarted).onPressed, isNull);
    expect(find.text(S.errTooLong), findsOneWidget);
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: long,
        selection: TextSelection.collapsed(offset: long.length),
      ),
    );
    await tester.pump();
    final shown = tester.widget<TextField>(field).controller!.text;
    expect(shown, 'a' * 39);
    expect(find.text(S.errTooLong), findsNothing);
    await qaTap(tester, find.text(S.getStarted));
    expect(w.settings.profile?.displayName, 'a' * 39);
    await w.shutdown(tester);
  });

  testWidgets('R15 probe: onboarding, 42 letters composed are held at 40 '
      '(Android enforces the counter while composing) and save as 40', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create();
    await pumpReal(tester, w);
    final field = find.byType(TextField).first;
    await tester.showKeyboard(field);
    final long = '${'a' * 38}bcde';
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: long,
        selection: TextSelection.collapsed(offset: long.length),
        composing: TextRange(start: 38, end: long.length),
      ),
    );
    await tester.pump();
    expect(tester.widget<TextField>(field).controller!.text.length, 40);
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: '${'a' * 38}bc',
        selection: const TextSelection.collapsed(offset: 40),
      ),
    );
    await tester.pump();
    await qaTap(tester, find.text(S.getStarted));
    expect(w.settings.profile?.displayName, '${'a' * 38}bc');
    await w.shutdown(tester);
  });
}
