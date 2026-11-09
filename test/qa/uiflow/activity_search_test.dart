// QA UIFLOW: the Activity feed lists every command, and Search finds by
// description, note, category label and member name, on the real Ledger.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import 'real_harness.dart';

Future<void> scrollToText(WidgetTester tester, String text) =>
    qaReveal(tester, find.text(text));

void main() {
  testWidgets('global Activity shows a sentence for every command', (
    tester,
  ) async {
    qaPhone(tester, size: const Size(412, 2400));
    final w = await RealWorld.create(name: 'Arjun');
    final l = w.ledger;
    final gid = await w.seedGroup(people: const ['Priya', 'Rahul']);
    final me = w.member(gid, 'Arjun');
    final priya = w.member(gid, 'Priya');
    final rahul = w.member(gid, 'Rahul');
    await l.updateGroup(gid, const GroupPatch(name: 'Goa 2026'));
    final meera = await l.addMember(gid, displayName: 'Meera');
    await l.renameMember(gid, meera, 'Meera K');
    await l.removeMember(gid, meera);
    final eid = await l.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Scooter rental',
        total: 120000,
        currency: 'INR',
        paidBy: SplitSpec.single(me, 120000),
        owedBy: SplitSpec.equal([me, priya, rahul]),
        category: 'transport',
        date: qaNow.toUtc(),
      ),
    );
    await l.updateExpense(
      eid,
      ExpenseDraft(
        groupId: gid,
        description: 'Scooter rental x2',
        total: 120000,
        currency: 'INR',
        paidBy: SplitSpec.single(me, 120000),
        owedBy: SplitSpec.equal([me, priya, rahul]),
        category: 'transport',
        date: qaNow.toUtc(),
      ),
    );
    await l.deleteExpense(eid);
    await l.restoreExpense(eid);
    final pid = await l.recordPayment(
      PaymentDraft(
        groupId: gid,
        from: priya,
        to: me,
        amount: 40000,
        currency: 'INR',
        method: PaymentMethod.upi,
        date: qaNow.toUtc(),
      ),
    );
    await l.updatePayment(
      pid,
      PaymentDraft(
        groupId: gid,
        from: priya,
        to: me,
        amount: 30000,
        currency: 'INR',
        method: PaymentMethod.upi,
        date: qaNow.toUtc(),
      ),
    );
    await l.deleteExpense(pid);
    await l.restoreExpense(pid);

    await pumpReal(tester, w, location: Routes.activity);
    final expected = [
      S.actCreatedGroup(S.you, 'Goa 2026'),
      S.actEditedGroup(S.you, 'Goa 2026'),
      S.actAddedMember(S.you, 'Meera K'),
      S.actEditedMember(S.you, 'Meera K'),
      S.actRemovedMember(S.you, 'Meera K'),
      S.actAddedExpense(S.you, 'Scooter rental x2'),
      S.actEditedExpense(S.you, 'Scooter rental x2'),
      S.actDeletedExpense(S.you, 'Scooter rental x2'),
      S.actRestoredExpense(S.you, 'Scooter rental x2'),
      S.actPayment(S.you, 'Priya', 'you'),
      S.actEditedPayment(S.you),
      S.actDeletedPayment(S.you),
      S.actRestoredPayment(S.you),
    ];
    for (final t in expected) {
      await scrollToText(tester, t);
      expect(find.text(t), findsWidgets, reason: t);
    }

    // Filters.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await qaSettle(tester);
    await qaTap(tester, find.widgetWithText(ChoiceChip, S.filterPayments));
    expect(find.text(S.actEditedPayment(S.you)), findsOneWidget);
    expect(find.text(S.actAddedExpense(S.you, 'Scooter rental x2')),
        findsNothing);
    await qaTap(tester, find.widgetWithText(ChoiceChip, S.filterSyncs));
    expect(find.text(S.activityEmptyHeadline), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('a merge shows in Activity', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya', 'Priya S']);
    await w.ledger.mergeMembers(
      gid,
      from: w.member(gid, 'Priya S'),
      into: w.member(gid, 'Priya'),
    );
    await pumpReal(tester, w, location: Routes.activity);
    expect(find.textContaining('merged'), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('Search finds by description, note, category label and member '
      'name; deleted expenses are not listed', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya', 'Rahul']);
    final me = w.member(gid, 'Arjun');
    final rahul = w.member(gid, 'Rahul');
    final l = w.ledger;
    await l.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Fish thali',
        total: 60000,
        currency: 'INR',
        paidBy: SplitSpec.single(me, 60000),
        owedBy: SplitSpec.equal([me, rahul]),
        category: 'food.dining',
        date: qaNow.toUtc(),
        notes: 'Martins corner',
      ),
    );
    final gone = await l.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Ferry tickets',
        total: 10000,
        currency: 'INR',
        paidBy: SplitSpec.single(me, 10000),
        owedBy: SplitSpec.equal([me]),
        category: 'transport',
        date: qaNow.toUtc(),
      ),
    );
    await l.deleteExpense(gone);

    await pumpReal(tester, w, location: Routes.home);
    await qaTap(tester, find.byTooltip(S.searchExpenses));
    expect(w.location, Routes.search);
    final field = find.byType(TextField).first;

    Future<void> search(String q) async {
      await tester.enterText(field, q);
      await qaSettle(tester);
    }

    await search('thali');
    expect(find.text('Fish thali'), findsOneWidget);
    await search('MARTINS');
    expect(find.text('Fish thali'), findsOneWidget);
    await search('Dining');
    expect(find.text('Fish thali'), findsOneWidget);
    await search('rahul');
    expect(find.text('Fish thali'), findsOneWidget);
    await search('fish rahul');
    expect(find.text('Fish thali'), findsOneWidget);
    await search('ferry');
    expect(find.text('Ferry tickets'), findsNothing);
    expect(find.text(S.searchNone('ferry')), findsOneWidget);
    await w.shutdown(tester);
  });
}
