// QA SECURITY-R1-04: expense ids are scoped by group (SPEC 7.2). When a
// peer of one group reuses the id of an expense in another group, each
// group's list opens its own expense, and delete from the detail screen
// only touches the group it was opened from.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/split.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import '../../qa/uiflow/real_harness.dart';

const DeviceId _mallory = 'eeeeeeee-0000-7000-8000-000000000001';

void main() {
  test('expense routes carry the group when it is known', () {
    expect(Routes.expense('e1'), '/expense/e1');
    expect(Routes.expense('e1', groupId: 'g1'), '/expense/e1?gid=g1');
    expect(Routes.editExpense('e1'), '/expense/e1/edit');
    expect(Routes.editExpense('e1', groupId: 'g1'), '/expense/e1/edit?gid=g1');
  });

  testWidgets('each group opens and deletes its own expense when an id is '
      'reused across groups', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final goa = await w.seedGroup(name: 'Goa trip');
    final private = await w.seedGroup(name: 'Private', people: ['Ravi']);
    final me = w.member(private, 'Arjun');
    final ravi = w.member(private, 'Ravi');
    final eid = await w.ledger.addExpense(
      ExpenseDraft(
        groupId: private,
        description: 'Rent',
        total: 900000,
        currency: 'INR',
        paidBy: SplitSpec.single(me, 900000),
        owedBy: SplitSpec.equal([me, ravi]),
        category: 'home.rent',
        date: DateTime.utc(2026, 11, 5),
        notes: '',
      ),
    );
    final create = w.ledger.current.ops.firstWhere((o) => o.entityId == eid);
    final goaMe = w.member(goa, 'Arjun');
    final goaPriya = w.member(goa, 'Priya');
    await w.ledger.applyRemote(goa, [
      Operation(
        id: 'forged-create',
        groupId: goa,
        deviceId: _mallory,
        counter: 1,
        hlc: const Hlc(1, 0, _mallory),
        entityType: EntityType.expense,
        entityId: eid,
        kind: OpKind.create,
        payload: {
          ...create.payload,
          ExpenseFields.description: 'Forged',
          ExpenseFields.money: SplitCalculator.buildMoneyBlock(
            total: 1000,
            currency: 'INR',
            paidBy: SplitSpec.single(goaPriya, 1000),
            owedBy: SplitSpec.equal([goaMe, goaPriya]),
          ).toJson(),
        },
      ),
    ]);
    expect(w.state.expenseIn(private, eid)!.description, 'Rent');
    expect(w.state.expenseIn(goa, eid)!.description, 'Forged');

    await pumpReal(tester, w, location: Routes.home);
    for (final (gid, text) in [(private, 'Rent'), (goa, 'Forged')]) {
      w.go(Routes.group(gid));
      await qaSettle(tester);
      await qaTap(tester, find.text(text));
      expect(w.location, Routes.expense(eid, groupId: gid));
      expect(find.text(text), findsWidgets);
    }

    // Delete from the Private detail screen: only Private's copy goes.
    w.go(Routes.group(private));
    await qaSettle(tester);
    await qaTap(tester, find.text('Rent'));
    await qaTap(tester, find.byTooltip(S.moreOptions));
    await qaTap(tester, find.text(S.deleteExpense));
    await qaTap(tester, find.widgetWithText(FilledButton, S.delete));
    expect(w.state.expenseIn(private, eid)!.isDeleted, isTrue);
    expect(w.state.expenseIn(goa, eid)!.isDeleted, isFalse);
    expect(
      w.ledger.current.ops.where((o) => o.groupId == goa && o.entityId == eid),
      hasLength(1),
      reason: 'nothing about the Private expense is written into Goa trip',
    );
    await w.shutdown(tester);
  });
}
