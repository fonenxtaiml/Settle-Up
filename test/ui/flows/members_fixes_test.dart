// Regression tests for Members / group fixes from QA round 1
// (UIFLOW-R1-01, -03, -17, -19, -21), on the real Ledger.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/split.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import '../../qa/uiflow/real_harness.dart';

void main() {
  testWidgets('UIFLOW-R1-01: Members refuses a name already in the group', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya']);
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.members(gid));
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.personName), ' priya ');
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    expect(find.text(S.alreadyInGroup('Priya')), findsOneWidget);
    expect(w.group(gid).activeMembers, hasLength(2));
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-19: Remove is allowed once the member is settled', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya']);
    final priya = w.member(gid, 'Priya');
    await pumpReal(tester, w);
    w.push(Routes.members(gid));
    await qaSettle(tester);
    await qaTap(tester, find.text('Priya'));
    await qaTap(
      tester,
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text(S.remove),
      ),
    );
    await qaTap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(S.remove),
      ),
    );
    expect(w.group(gid).members[priya]!.isRemoved, isTrue);
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-21: a 1:1 group has no "Add a person" field', (
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
    final direct = await w.ledger.directGroupWith(
      personId: priyaPerson,
      displayName: 'Priya',
      currency: 'INR',
    );
    await pumpReal(tester, w);
    w.push(Routes.members(direct));
    await qaSettle(tester);
    expect(fieldLabeled(S.personName), findsNothing);
    await expectLater(
      w.ledger.addMember(direct, displayName: 'Rahul'),
      throwsA(isA<LedgerException>()),
    );
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-03: the Ledger refuses a member name over 40', (
    tester,
  ) async {
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya']);
    await expectLater(
      w.ledger.addMember(gid, displayName: 'N' * 41),
      throwsA(isA<LedgerException>()),
    );
    await w.ledger.addMember(gid, displayName: 'प्रियंका' * 5); // 40+ runes
    await expectLater(
      w.ledger.renameMember(gid, w.member(gid, 'Priya'), 'P' * 41),
      throwsA(isA<LedgerException>()),
    );
  });

  testWidgets('UIFLOW-R1-17: the group activity shows only that group', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final a = await w.seedGroup(name: 'Goa trip', people: const ['Priya']);
    final b = await w.seedGroup(name: 'Flat 4B', people: const ['Rahul']);
    final me = w.member(b, 'Arjun');
    await w.ledger.addExpense(
      ExpenseDraft(
        groupId: b,
        description: 'Rent',
        total: 10000,
        currency: 'INR',
        paidBy: SplitSpec.single(me, 10000),
        owedBy: SplitSpec.equal([me, w.member(b, 'Rahul')]),
        category: 'general',
        date: qaNow.toUtc(),
      ),
    );
    await pumpReal(tester, w);
    w.push(Routes.groupActivity(a));
    await qaSettle(tester);
    expect(find.text(S.activityTitle), findsOneWidget);
    expect(find.textContaining('Rent'), findsNothing);
    expect(find.text(S.filterSyncs), findsNothing);
    await w.shutdown(tester);
  });
}
