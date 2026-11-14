// QA UIFLOW round 42: final regression sweep of the UI flows on the real
// Ledger. Probes paths the earlier rounds left out: a name left in New
// group's person field that cannot be a name, the Activity filter kept
// across tabs, Search after a rename, the new group currency following the
// home currency, a payment between two other people edited from its
// detail, and delete > Undo seen from Activity and Search.
// Tests named "QA UIFLOW-R42-NN" with `skip:` are failing repros of an
// open finding.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

import 'real_harness.dart';

Future<void> _io(WidgetTester tester) async {
  await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  await qaSettle(tester);
}

void main() {
  for (final typed in const ['😎', '?!', '---']) {
    testWidgets(
      'QA UIFLOW-R42-01 ($typed): New group, a name with no letter '
      'or number left in the person field on Create is not dropped '
      'without a word',
      (tester) async {
        qaPhone(tester);
        final w = await RealWorld.create(name: 'Arjun');
        await pumpReal(tester, w);
        w.push(Routes.newGroup);
        await qaSettle(tester);
        await tester.enterText(fieldLabeled(S.groupName), 'Ladakh');
        await tester.enterText(fieldLabeled(S.personName), 'Meera');
        await tester.pump();
        await qaTap(tester, find.text(S.addPerson));
        await tester.enterText(fieldLabeled(S.personName), typed);
        await tester.pump();
        await qaTap(tester, find.text(S.createGroupAction));
        await _io(tester);
        final groups = w.ledger.current.state.visibleGroups;
        // What the user typed is refused with the copy the keyboard's
        // Done shows and the form stays open: the group is never created
        // with the person silently left out.
        if (groups.isNotEmpty) {
          fail(
            'Created "${groups.single.group!.name}" with '
            '${groups.single.activeMembers.map((m) => m.displayName).toList()}'
            '; "$typed" was dropped and nothing was said '
            '(on screen: ${w.location})',
          );
        }
        expect(find.text(S.nameNeedsLetter), findsOneWidget);
        expect(w.location, Routes.newGroup);
        await w.shutdown(tester);
      },
      // QA UIFLOW-R42-01: fixed, New group's Create refuses such a name the
      // way the keyboard's Done does.
    );
  }

  testWidgets('R42 probe: the same name left in the field on Create still '
      'creates the group with that person once (premise)', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    w.push(Routes.newGroup);
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), 'Ladakh');
    await tester.enterText(fieldLabeled(S.personName), 'Meera');
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    await tester.enterText(fieldLabeled(S.personName), 'meera');
    await tester.pump();
    await qaTap(tester, find.text(S.createGroupAction));
    await _io(tester);
    final g = w.ledger.current.state.visibleGroups.single;
    expect(g.activeMembers.map((m) => m.displayName).toSet(), {
      'Arjun',
      'Meera',
    });
    await w.shutdown(tester);
  });

  testWidgets('R42 probe (premise of UIFLOW-R42-01): with "😎" in the person '
      'field Add person is off, and the keyboard action says why', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    w.push(Routes.newGroup);
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.personName), '😎');
    await tester.pump();
    final add = tester.widget<FilledButton>(
      find.ancestor(
        of: find.text(S.addPerson),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      ),
    );
    expect(add.onPressed, isNull);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await qaSettle(tester);
    expect(find.text(S.nameNeedsLetter), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('R42 probe: the Activity tab keeps its filter while Home is '
      'open, and the filter only shows payments', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final me = w.member(gid, 'Arjun');
    final priya = w.member(gid, 'Priya');
    await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Ferry tickets',
        total: 30000,
        currency: 'INR',
        category: 'general',
        paidBy: SplitSpec(SplitMethod.exact, {me: 30000}),
        owedBy: SplitSpec(SplitMethod.equal, {
          me: 1,
          priya: 1,
          w.member(gid, 'Rahul'): 1,
        }),
        date: qaNow.toUtc(),
      ),
    );
    await w.ledger.recordPayment(
      PaymentDraft(
        groupId: gid,
        from: priya,
        to: me,
        amount: 10000,
        currency: 'INR',
        method: PaymentMethod.upi,
        date: qaNow.toUtc(),
      ),
    );
    await pumpReal(tester, w, location: Routes.home);
    await qaTap(tester, find.text(KitStrings.activity));
    expect(w.location, Routes.activity);
    expect(find.textContaining('Ferry tickets'), findsWidgets);
    await qaTap(tester, find.widgetWithText(ChoiceChip, S.filterPayments));
    expect(find.textContaining('Ferry tickets'), findsNothing);
    expect(find.textContaining('Priya'), findsWidgets);

    await qaTap(tester, find.text(KitStrings.home));
    expect(w.location, Routes.home);
    await qaTap(tester, find.text(KitStrings.activity));
    final chip = tester.widget<ChoiceChip>(
      find.widgetWithText(ChoiceChip, S.filterPayments),
    );
    expect(chip.selected, isTrue);
    expect(find.textContaining('Ferry tickets'), findsNothing);
    await w.shutdown(tester);
  });

  testWidgets('R42 probe: Search finds an expense by a member\'s new name '
      'after a rename on Members, and no longer by the old one', (
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
        description: 'Scooter rental',
        total: 40000,
        currency: 'INR',
        category: 'general',
        paidBy: SplitSpec(SplitMethod.exact, {priya: 40000}),
        owedBy: SplitSpec(SplitMethod.equal, {me: 1, priya: 1}),
        date: qaNow.toUtc(),
      ),
    );
    await w.ledger.renameMember(gid, priya, 'Priyanka Iyer');
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.search);
    await qaSettle(tester);
    await tester.enterText(find.byType(TextField).first, 'iyer');
    await qaSettle(tester);
    expect(find.text('Scooter rental'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'priya ');
    await qaSettle(tester);
    // "priya" is still a part of "Priyanka": found.
    expect(find.text('Scooter rental'), findsOneWidget);
    await tester.enterText(find.byType(TextField).first, 'rahul');
    await qaSettle(tester);
    // Rahul is not in the expense.
    expect(find.text('Scooter rental'), findsNothing);
    await w.shutdown(tester);
  });

  testWidgets('R42 probe: a new home currency picked in Settings is the '
      'currency New group starts with', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.home);
    await w.settings.updateProfile(
      w.container.read(profileProvider).value!.copyWith(homeCurrency: 'USD'),
    );
    await _io(tester);
    w.push(Routes.newGroup);
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), 'NYC');
    await tester.pump();
    await qaTap(tester, find.text(S.createGroupAction));
    await _io(tester);
    expect(w.ledger.current.state.visibleGroups.single.group!.currency, 'USD');
    await w.shutdown(tester);
  });

  testWidgets('R42 probe: a payment between two other people, edited from '
      'its detail, keeps who paid whom; balances follow', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final priya = w.member(gid, 'Priya');
    final rahul = w.member(gid, 'Rahul');
    final pid = await w.ledger.recordPayment(
      PaymentDraft(
        groupId: gid,
        from: priya,
        to: rahul,
        amount: 25000,
        currency: 'INR',
        method: PaymentMethod.cash,
        date: qaNow.toUtc(),
      ),
    );
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    w.push(Routes.expense(pid, groupId: gid));
    await qaSettle(tester);
    await qaTap(tester, find.byTooltip(S.edit));
    expect(find.text(S.paymentTitle), findsWidgets);
    await tester.enterText(find.byType(TextField).first, '300');
    await tester.pump();
    await qaTap(tester, find.text(S.saveChanges));
    await _io(tester);
    final p = w.state.expense(pid)!;
    expect(p.money.total, 30000);
    expect(p.payer, priya);
    expect(p.receiver, rahul);
    final nets = BalanceCalculator.groupNets(w.group(gid))['INR']!;
    expect(nets[priya], 30000);
    expect(nets[rahul], -30000);
    expect(snackText(tester), S.expenseSaved);
    expect(w.location, Routes.expense(pid, groupId: gid));
    // Back from the detail reaches the group.
    await tester.pageBack();
    await qaSettle(tester);
    expect(w.location, Routes.group(gid));
    await w.shutdown(tester);
  });

  testWidgets('R42 probe: delete from detail and Undo: Activity lists the '
      'delete and the restore, Search finds it again, the hero is back', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final me = w.member(gid, 'Arjun');
    final eid = await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Houseboat',
        total: 90000,
        currency: 'INR',
        category: 'general',
        paidBy: SplitSpec(SplitMethod.exact, {me: 90000}),
        owedBy: SplitSpec(SplitMethod.equal, {
          me: 1,
          w.member(gid, 'Priya'): 1,
          w.member(gid, 'Rahul'): 1,
        }),
        notes: 'Alleppey backwaters',
        date: qaNow.toUtc(),
      ),
    );
    await pumpReal(tester, w, location: Routes.home);
    expect(find.text(KitStrings.heroOwed), findsOneWidget);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    await qaTap(tester, find.text('Houseboat'));
    await qaTap(tester, find.byTooltip(S.moreOptions));
    await qaTap(tester, find.text(S.deleteExpense));
    await qaTap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(S.delete),
      ),
    );
    expect(w.state.expense(eid)!.isDeleted, isTrue);
    await tester.tap(find.text(S.undo));
    await qaSettle(tester);
    expect(w.state.expense(eid)!.isDeleted, isFalse);

    w.go(Routes.activity);
    await qaSettle(tester);
    expect(find.text(S.actDeletedExpense(S.you, 'Houseboat')), findsOneWidget);
    expect(find.text(S.actRestoredExpense(S.you, 'Houseboat')), findsOneWidget);

    w.push(Routes.search);
    await qaSettle(tester);
    await tester.enterText(find.byType(TextField).first, 'alleppey');
    await qaSettle(tester);
    expect(find.text('Houseboat'), findsOneWidget);
    await tester.pageBack();
    await qaSettle(tester);
    w.go(Routes.home);
    await qaSettle(tester);
    expect(find.text(KitStrings.heroOwed), findsOneWidget);
    await w.shutdown(tester);
  });
}
