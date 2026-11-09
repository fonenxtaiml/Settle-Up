// QA UIFLOW: Home edge cases on the real Ledger: 1:1 (direct) balances,
// archived groups and the Add expense FAB default, and the group activity
// feed required by SPEC 1.2 feature 10.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

import 'real_harness.dart';

void main() {
  testWidgets('add expense with a person creates a 1:1 group and Home shows '
      'what they owe', (tester) async {
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
    await tester.enterText(find.byType(TextField).at(0), '500');
    await tester.enterText(fieldLabeled(S.description), 'Movie tickets');
    await tester.pump();
    await qaTap(tester, find.text(S.saveExpense));
    final direct = w.state.visibleGroups.where((g) => g.group!.isDirect);
    expect(direct, hasLength(1));
    expect(direct.single.liveExpenses.single.money.total, 50000);
    expect(w.location, Routes.home);
    expect(find.text(KitStrings.heroOwed), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('Home People row opens the person; Settle up there opens the '
      'pair in the right group', (tester) async {
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
    await pumpReal(tester, w);
    final row = find.text('Priya');
    await qaReveal(tester, row);
    await qaTap(tester, row.first);
    expect(w.location, startsWith('/people/'));
    expect(find.text(S.personOwesYou('Priya')), findsOneWidget);
    await qaTap(tester, find.widgetWithText(FilledButton, S.settleUp));
    expect(w.location, startsWith('/settle'));
    expect(find.text(S.recordPayment('₹300')), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-15: with only a 1:1 balance left (the shared group '
      'was deleted) Home shows "Start your first group" and hides the debt',
      (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya']);
    final priyaPerson = w
        .group(gid)
        .activeMembers
        .firstWhere((m) => m.displayName == 'Priya')
        .personId;
    final direct = await w.ledger.directGroupWith(
      personId: priyaPerson,
      displayName: 'Priya',
      currency: 'INR',
    );
    final d = w.group(direct);
    final me = d.memberForPerson(w.settings.profile!.personId)!.id;
    final priya = d.memberForPerson(priyaPerson)!.id;
    await w.ledger.addExpense(
      ExpenseDraft(
        groupId: direct,
        description: 'Movie tickets',
        total: 50000,
        currency: 'INR',
        paidBy: SplitSpec.single(me, 50000),
        owedBy: SplitSpec.equal([me, priya]),
        category: 'general',
        date: qaNow.toUtc(),
      ),
    );
    await w.ledger.deleteGroup(gid);
    await pumpReal(tester, w);
    // Expected: the ₹250 Priya owes is still on Home.
    expect(find.text(S.homeEmptyHeadline), findsNothing);
    expect(find.text(KitStrings.heroOwed), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-16: the Home FAB starts a new expense in an archived '
      'group when that group sorts first (it has an open balance)', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final old = await w.seedGroup(name: 'Old trip', people: const ['Priya']);
    final me = w.member(old, 'Arjun');
    await w.ledger.addExpense(
      ExpenseDraft(
        groupId: old,
        description: 'Leftover',
        total: 10000,
        currency: 'INR',
        paidBy: SplitSpec.single(me, 10000),
        owedBy: SplitSpec.equal([me, w.member(old, 'Priya')]),
        category: 'general',
        date: qaNow.toUtc(),
      ),
    );
    await w.ledger.updateGroup(old, const GroupPatch(archived: true));
    await w.seedGroup(name: 'Flat 4B', people: const ['Rahul']);
    await pumpReal(tester, w);
    await qaTap(tester, find.byType(FloatingActionButton));
    expect(find.text(S.addExpenseTitle), findsOneWidget);
    // Expected: an active group (Flat 4B), never an archived one; the
    // group picker itself hides archived groups.
    expect(find.text('Old trip'), findsNothing);
    expect(find.text('Flat 4B'), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-17: there is no per-group activity feed (SPEC 1.2 '
      'feature 10: "Activity feed per group and global")', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await w.ledger.addMember(gid, displayName: 'Meera');
    await pumpReal(tester, w);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    // Look on the group screen, then in its overflow menu.
    var found = find
        .text(S.actAddedMember(S.you, 'Meera'))
        .evaluate()
        .isNotEmpty;
    if (!found) {
      await qaTap(tester, find.byTooltip(S.moreOptions));
      final entry = find.text(S.activityTitle);
      if (entry.evaluate().isNotEmpty) {
        await qaTap(tester, entry.last);
        found = find
            .text(S.actAddedMember(S.you, 'Meera'))
            .evaluate()
            .isNotEmpty;
      }
    }
    expect(found, isTrue);
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-21: a 1:1 group ("Just you two") accepts a third '
      'person from its Members screen', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya']);
    final priyaPerson = w
        .group(gid)
        .activeMembers
        .firstWhere((m) => m.displayName == 'Priya')
        .personId;
    final direct = await w.ledger.directGroupWith(
      personId: priyaPerson,
      displayName: 'Priya',
      currency: 'INR',
    );
    await pumpReal(tester, w);
    w.push(Routes.group(direct));
    await qaSettle(tester);
    expect(find.text(S.justYouTwo), findsOneWidget);
    await qaTap(tester, find.byTooltip(S.moreOptions));
    await qaTap(tester, find.text(S.members).last);
    final field = fieldLabeled(S.personName);
    if (field.evaluate().isNotEmpty) {
      await tester.enterText(field, 'Rahul');
      await tester.pump();
      await qaTap(tester, find.text(S.addPerson));
    }
    // Expected: a 1:1 group stays two people.
    expect(w.group(direct).activeMembers, hasLength(2));
    await w.shutdown(tester);
  });
}
