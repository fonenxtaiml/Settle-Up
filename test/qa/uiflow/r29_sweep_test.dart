// QA UIFLOW round 29: final regression sweep on the real Ledger. Probes of
// the charter's flows across the round 27 and 28 fixes (every saving form
// is locked while it saves and closes only its own screen): archive,
// unarchive and delete from Edit group, delete and undo from a detail
// reached from Search and from the Activity tab, a new group replacing its
// form, a payment edit, the discard prompt, and a deep link over a form.
// Tests named "QA UIFLOW-R29-NN" with `skip: true` are failing repros of
// an open finding.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

import 'real_harness.dart';

Finder _tab(String label) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

Future<bool> _androidBack(WidgetTester tester) async {
  final handled = await tester.binding.handlePopRoute();
  await qaSettle(tester);
  return handled;
}

Future<ExpenseId> _dinner(RealWorld w, GroupId gid, {int total = 30000}) {
  final me = w.member(gid, 'Arjun');
  return w.ledger.addExpense(
    ExpenseDraft(
      groupId: gid,
      description: 'Dinner',
      total: total,
      currency: 'INR',
      paidBy: SplitSpec.single(me, total),
      owedBy: SplitSpec.equal([
        for (final m in w.group(gid).activeMembers) m.id,
      ]),
      category: 'food',
      date: qaNow.toUtc(),
      notes: 'Beach shack',
    ),
  );
}

Future<void> _deleteFromDetail(WidgetTester tester) async {
  await qaTap(tester, find.byTooltip(S.moreOptions));
  await qaTap(tester, find.text(S.deleteExpense));
  await qaTap(
    tester,
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.text(S.delete),
    ),
  );
}

void main() {
  testWidgets('R29 probe: Archive on Edit group closes only Edit group, '
      'Home lists the group as archived, and Move back to groups restores '
      'it', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    w.push(Routes.editGroup(gid));
    await qaSettle(tester);

    await qaTap(tester, find.text(S.archiveGroup));
    expect(w.group(gid).group!.archived, isTrue);
    expect(snackText(tester), S.groupArchived);
    expect(w.location, Routes.group(gid));
    expect(tester.takeException(), isNull);

    w.push(Routes.editGroup(gid));
    await qaSettle(tester);
    await qaTap(tester, find.text(S.unarchiveGroup));
    expect(w.group(gid).group!.archived, isFalse);
    expect(w.location, Routes.group(gid));

    // Back from the group lands on Home, which lists it again.
    expect(await _androidBack(tester), isTrue);
    expect(w.location, Routes.home);
    expect(find.text('Goa trip'), findsWidgets);
    await w.shutdown(tester);
  });

  testWidgets('R29 probe: Delete group on Edit group lands on Home; nothing '
      'of the group stays in the back stack', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await _dinner(w, gid);
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    w.push(Routes.editGroup(gid));
    await qaSettle(tester);

    await qaTap(tester, find.text(S.deleteGroup));
    await qaTap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(S.delete),
      ),
    );
    expect(w.state.visibleGroups.where((g) => g.groupId == gid), isEmpty);
    expect(w.location, Routes.home);
    expect(snackText(tester), S.groupDeleted);
    expect(find.text('Goa trip'), findsNothing);
    // Android back on the Home root is left to the system.
    expect(await _androidBack(tester), isFalse);
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });

  testWidgets('R29 probe: delete from a detail opened from Search returns to '
      'Search; Undo brings the expense back', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final eid = await _dinner(w, gid);
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.search);
    await qaSettle(tester);
    await tester.enterText(find.byType(TextField).first, 'beach');
    await tester.pump(const Duration(milliseconds: 500));
    await qaSettle(tester);
    expect(find.text('Dinner'), findsOneWidget);
    await qaTap(tester, find.text('Dinner'));
    expect(w.location, startsWith('/expense/$eid'));

    await _deleteFromDetail(tester);
    expect(w.state.expenseIn(gid, eid)!.isDeleted, isTrue);
    expect(w.location, Routes.search);
    expect(snackText(tester), S.expenseDeleted);
    // The query is kept and the deleted expense is no longer listed.
    expect(find.text('beach'), findsOneWidget);
    expect(find.text('Dinner'), findsNothing);

    await tester.tap(find.text(S.undo));
    await qaSettle(tester);
    expect(w.state.expenseIn(gid, eid)!.isDeleted, isFalse);
    expect(find.text('Dinner'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });

  testWidgets('R29 probe: delete from a detail opened from the Activity tab '
      'returns to the Activity tab with the shell kept', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final eid = await _dinner(w, gid);
    await pumpReal(tester, w, location: Routes.home);
    await qaTap(tester, _tab(KitStrings.activity));
    expect(w.location, Routes.activity);
    await qaTap(tester, find.textContaining('Dinner').first);
    expect(w.location, startsWith('/expense/$eid'));

    await _deleteFromDetail(tester);
    expect(w.state.expenseIn(gid, eid)!.isDeleted, isTrue);
    expect(w.location, Routes.activity);
    expect(find.byType(NavigationBar), findsOneWidget);
    // Back on a non-Home tab goes to Home first.
    expect(await _androidBack(tester), isTrue);
    expect(w.location, Routes.home);
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });

  testWidgets('R29 probe: a deleted expense opened again can be restored '
      'from its detail and deleted once more', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final eid = await _dinner(w, gid);
    await w.ledger.deleteExpense(eid, groupId: gid);
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    w.push(Routes.expense(eid, groupId: gid));
    await qaSettle(tester);
    expect(find.text(S.deletedBanner), findsOneWidget);

    await qaTap(
      tester,
      find.descendant(
        of: find.byType(FilledButton),
        matching: find.text(S.restore),
      ),
    );
    expect(w.state.expenseIn(gid, eid)!.isDeleted, isFalse);
    expect(snackText(tester), S.expenseRestored);
    expect(find.text(S.deletedBanner), findsNothing);
    // The detail stays open after a restore.
    expect(w.location, startsWith('/expense/$eid'));

    await _deleteFromDetail(tester);
    expect(w.state.expenseIn(gid, eid)!.isDeleted, isTrue);
    expect(w.location, Routes.group(gid));
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });

  testWidgets('R29 probe: New group replaces its form with the group; Back '
      'from the group lands on Home', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.newGroup);
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), 'Flat 4B');
    await tester.pump();
    await tester.enterText(fieldLabeled(S.personName), 'Priya');
    await tester.pump();
    await qaTap(tester, find.text(S.createGroupAction));
    final g = w.groupNamed('Flat 4B');
    expect(
      g.activeMembers.map((m) => m.displayName),
      unorderedEquals(['Arjun', 'Priya']),
    );
    expect(w.location, Routes.group(g.groupId));
    expect(snackText(tester), S.groupCreated);
    expect(await _androidBack(tester), isTrue);
    expect(w.location, Routes.home);
    expect(find.text(S.newGroupTitle), findsNothing);
    await w.shutdown(tester);
  });

  testWidgets('R29 probe: a payment edit from its detail saves only the '
      'amount and returns to the detail', (tester) async {
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
        amount: 40000,
        currency: 'INR',
        method: PaymentMethod.upi,
        date: qaNow.toUtc(),
        notes: 'Rent share',
      ),
    );
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    w.push(Routes.expense(pid, groupId: gid));
    await qaSettle(tester);
    await qaTap(tester, find.byTooltip(S.edit));
    expect(find.text(S.paymentTitle), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, '350');
    await tester.pump();
    await qaTap(tester, find.text(S.saveChanges));
    final p = w.state.expenseIn(gid, pid)!;
    expect(p.money.total, 35000);
    expect(p.paymentMethod, PaymentMethod.upi);
    expect(p.notes, 'Rent share');
    expect(p.payer, priya);
    expect(p.receiver, me);
    expect(snackText(tester), S.expenseSaved);
    expect(w.location, startsWith('/expense/$pid'));
    expect(find.textContaining('350'), findsWidgets);
    expect(await _androidBack(tester), isTrue);
    expect(w.location, Routes.group(gid));
    await w.shutdown(tester);
  });

  testWidgets('R29 probe: a changed expense asks before closing; Keep '
      'editing keeps the text, Discard returns to the detail unchanged', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final eid = await _dinner(w, gid);
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.expense(eid, groupId: gid));
    await qaSettle(tester);
    await qaTap(tester, find.byTooltip(S.edit));
    await tester.enterText(fieldLabeled(S.description), 'Dinner and drinks');
    await tester.pump();

    expect(await _androidBack(tester), isTrue);
    expect(find.text(S.discardTitle), findsOneWidget);
    await qaTap(tester, find.text(S.keepEditing));
    expect(find.text('Dinner and drinks'), findsOneWidget);
    expect(find.text(S.editExpenseTitle), findsOneWidget);

    expect(await _androidBack(tester), isTrue);
    await qaTap(tester, find.text(S.discardAndClose));
    expect(w.location, startsWith('/expense/$eid'));
    expect(find.text(S.editExpenseTitle), findsNothing);
    expect(w.state.expenseIn(gid, eid)!.description, 'Dinner');
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });

  testWidgets('R29 probe: a settleup://sync link over Edit group opens Scan '
      'on top; Back returns to the form with what was typed', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    w.push(Routes.editGroup(gid));
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), 'Goa 2027');
    await tester.pump();

    await tester.binding.handlePushRoute('settleup://sync?v=1&x=bad');
    await qaSettle(tester);
    await tester.pump(const Duration(seconds: 2));
    await qaSettle(tester);
    expect(w.location, startsWith(Routes.syncScan));
    expect(tester.takeException(), isNull);
    final snack = snackText(tester);
    if (snack != null) {
      expect(snack.toLowerCase(), isNot(contains('exception')));
    }

    expect(await _androidBack(tester), isTrue);
    expect(w.location, Routes.editGroup(gid));
    expect(find.text('Goa 2027'), findsOneWidget);
    await qaTap(tester, find.text(S.saveChanges));
    expect(w.group(gid).group!.name, 'Goa 2027');
    expect(w.location, Routes.group(gid));
    await w.shutdown(tester);
  });
  testWidgets('R29 probe: Undo on "Payment recorded" takes the payment out '
      'and the group balance back', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await _dinner(w, gid);
    final me = w.member(gid, 'Arjun');
    final priya = w.member(gid, 'Priya');
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    w.push(Routes.settle(groupId: gid, from: priya, to: me));
    await qaSettle(tester);
    await qaTap(tester, find.text(S.recordPayment('₹100')));
    await tester.pump(const Duration(seconds: 2));
    await qaSettle(tester);
    expect(w.location, Routes.group(gid));
    expect(snackText(tester), S.paymentRecorded);
    expect(BalanceCalculator.groupNets(w.group(gid))['INR']![me], 10000);

    await tester.tap(find.text(S.undo));
    await qaSettle(tester);
    expect(w.group(gid).liveExpenses.where((e) => e.isPayment), isEmpty);
    expect(BalanceCalculator.groupNets(w.group(gid))['INR']![me], 20000);
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });

  testWidgets('R29 probe: Android back on Settle up while the recorded '
      'moment plays closes only Settle up, once, with no error', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await _dinner(w, gid);
    final me = w.member(gid, 'Arjun');
    final priya = w.member(gid, 'Priya');
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    w.push(Routes.settle(groupId: gid, from: priya, to: me));
    await qaSettle(tester);
    await tester.tap(find.text(S.recordPayment('₹100')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(seconds: 3));
    await qaSettle(tester);
    expect(tester.takeException(), isNull);
    expect(w.location, Routes.group(gid));
    expect(w.group(gid).liveExpenses.where((e) => e.isPayment), hasLength(1));
    // Back again leaves the group for Home: nothing else was popped.
    expect(await _androidBack(tester), isTrue);
    expect(w.location, Routes.home);
    await w.shutdown(tester);
  });
  testWidgets('R29 probe: Add expense from a person screen returns to that '
      'person with the new 1:1 balance', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya']);
    final me = w.member(gid, 'Arjun');
    await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Dinner',
        total: 60000,
        currency: 'INR',
        paidBy: SplitSpec.single(me, 60000),
        owedBy: SplitSpec.equal([me, w.member(gid, 'Priya')]),
        category: 'general',
        date: qaNow.toUtc(),
      ),
    );
    final priyaPerson = w
        .group(gid)
        .activeMembers
        .firstWhere((m) => m.displayName == 'Priya')
        .personId;
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.person(priyaPerson));
    await qaSettle(tester);
    expect(find.text(S.personOwesYou('Priya')), findsOneWidget);
    await qaTap(tester, find.widgetWithText(FilledButton, S.addExpense));
    expect(find.text(S.addExpenseTitle), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), '500');
    await tester.enterText(fieldLabeled(S.description), 'Movie tickets');
    await tester.pump();
    await qaTap(tester, find.text(S.saveExpense));

    final direct = w.state.visibleGroups.where((g) => g.group!.isDirect);
    expect(direct, hasLength(1));
    expect(direct.single.liveExpenses.single.money.total, 50000);
    expect(w.location, Routes.person(priyaPerson));
    expect(snackText(tester), S.expenseAdded);
    // 300 in the trip and 250 one to one: Priya owes 550 in all.
    expect(find.textContaining('550'), findsWidgets);
    expect(await _androidBack(tester), isTrue);
    expect(w.location, Routes.home);
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });
  testWidgets('R29 probe: New group refused as too big unlocks the form; '
      'taking one person out creates it with 50', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.newGroup);
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), 'Wedding');
    for (var i = 1; i <= 50; i++) {
      await tester.enterText(fieldLabeled(S.personName), 'Guest $i');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
    }
    await qaTap(tester, find.text(S.createGroupAction));
    expect(snackText(tester), S.errGroupFull);
    expect(w.state.visibleGroups, isEmpty);
    expect(w.location, Routes.newGroup);
    expect(filledButton(tester, S.createGroupAction).onPressed, isNotNull);

    // Let the snack bar go so it covers nothing.
    await tester.pump(const Duration(seconds: 6));
    await qaSettle(tester);
    final chip = find.widgetWithText(InputChip, 'Guest 50');
    await qaReveal(tester, chip);
    await tester.tap(
      find.descendant(of: chip, matching: find.byIcon(Icons.clear)).first,
    );
    await tester.pump();
    expect(find.text('Guest 50'), findsNothing);
    await qaTap(tester, find.text(S.createGroupAction));
    final g = w.groupNamed('Wedding');
    expect(g.activeMembers, hasLength(50));
    expect(w.location, Routes.group(g.groupId));
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });

  // UIFLOW-R29-01: a payment's detail speaks of it as an expense. The menu
  // offers "Delete expense", the prompt (titled "Delete payment?") says it
  // can be restored "from the expense", and the snack bars after delete and
  // restore say "Expense deleted" and "Expense restored". Everywhere else
  // (detail title, edit screen, Activity) it is a payment.
  testWidgets(
    'QA UIFLOW-R29-01: deleting and restoring a payment from its detail says '
    'payment, not expense, in the menu, the prompt and the snack bars',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup();
      final pid = await w.ledger.recordPayment(
        PaymentDraft(
          groupId: gid,
          from: w.member(gid, 'Priya'),
          to: w.member(gid, 'Arjun'),
          amount: 40000,
          currency: 'INR',
          method: PaymentMethod.upi,
          date: qaNow.toUtc(),
        ),
      );
      await pumpReal(tester, w, location: Routes.home);
      w.push(Routes.group(gid));
      await qaSettle(tester);
      w.push(Routes.expense(pid, groupId: gid));
      await qaSettle(tester);

      await qaTap(tester, find.byTooltip(S.moreOptions));
      // The one menu item: what it deletes is a payment.
      final item = tester
          .widgetList<Text>(
            find.descendant(
              of: find.byWidgetPredicate((w) => w is PopupMenuItem),
              matching: find.byType(Text),
            ),
          )
          .single
          .data!;
      expect(item.toLowerCase(), isNot(contains('expense')));
      await qaTap(tester, find.text(item));
      final dialog = find.byType(AlertDialog);
      final prompt = [
        for (final t in tester.widgetList<Text>(
          find.descendant(of: dialog, matching: find.byType(Text)),
        ))
          t.data ?? '',
      ].join(' ');
      expect(prompt, contains('payment'));
      expect(prompt.toLowerCase(), isNot(contains('expense')));
      await qaTap(
        tester,
        find.descendant(of: dialog, matching: find.text(S.delete)),
      );
      expect(w.state.expenseIn(gid, pid)!.isDeleted, isTrue);
      expect(snackText(tester)!.toLowerCase(), isNot(contains('expense')));
      expect(snackText(tester)!.toLowerCase(), contains('payment'));

      w.push(Routes.expense(pid, groupId: gid));
      await qaSettle(tester);
      await qaTap(
        tester,
        find.descendant(
          of: find.byType(FilledButton),
          matching: find.text(S.restore),
        ),
      );
      expect(w.state.expenseIn(gid, pid)!.isDeleted, isFalse);
      expect(snackText(tester)!.toLowerCase(), isNot(contains('expense')));
      expect(snackText(tester)!.toLowerCase(), contains('payment'));
      await w.shutdown(tester);
    },
  );
}
