// QA UIFLOW round 21, final regression sweep: the class of UIFLOW-R17-01
// (the editors send only what the user changed) on every split method and
// on a multi-payer expense, not only the equal split the fix was tested on.
// The editor loads the money block into the split editor; when it is left
// untouched, Save must send the live money, and with no other phone
// involved, Save must not change the money at all.
//
// The same class on Settings > Your name: tests named "UIFLOW-R21-NN" with
// `skip:` are failing repros for open findings; unskip to verify a fix.
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

import 'real_harness.dart';

const _otherPhone = 'dddddddd-0000-7000-8000-000000002101';

var _counter = 0;

Future<void> _remote(
  RealWorld w,
  GroupId gid,
  ExpenseId id,
  Map<String, Object?> payload,
) async {
  _counter++;
  final added = await w.ledger.applyRemote(gid, [
    Operation(
      id: '$gid/$_otherPhone/$_counter',
      groupId: gid,
      deviceId: _otherPhone,
      counter: _counter,
      hlc: Hlc(qaNow.millisecondsSinceEpoch + 60000, _counter, _otherPhone),
      entityType: EntityType.expense,
      entityId: id,
      kind: OpKind.update,
      payload: payload,
    ),
  ]);
  expect(added, hasLength(1));
}

typedef _Case = ({
  String label,
  SplitSpec Function(RealWorld w, GroupId gid) paid,
  SplitSpec Function(RealWorld w, GroupId gid) owed,
});

final List<_Case> _cases = [
  (
    label: 'exact',
    paid: (w, g) => SplitSpec.single(w.member(g, 'Arjun'), 90000),
    owed: (w, g) => SplitSpec(SplitMethod.exact, {
      w.member(g, 'Arjun'): 10000,
      w.member(g, 'Priya'): 30000,
      w.member(g, 'Rahul'): 50000,
    }),
  ),
  (
    label: 'percent',
    paid: (w, g) => SplitSpec.single(w.member(g, 'Arjun'), 90000),
    owed: (w, g) => SplitSpec(SplitMethod.percent, {
      w.member(g, 'Arjun'): 3333,
      w.member(g, 'Priya'): 3333,
      w.member(g, 'Rahul'): 3334,
    }),
  ),
  (
    label: 'shares',
    paid: (w, g) => SplitSpec.single(w.member(g, 'Arjun'), 90000),
    owed: (w, g) => SplitSpec(SplitMethod.shares, {
      w.member(g, 'Arjun'): 1,
      w.member(g, 'Priya'): 2,
      w.member(g, 'Rahul'): 3,
    }),
  ),
  (
    label: 'adjustment',
    paid: (w, g) => SplitSpec.single(w.member(g, 'Arjun'), 90000),
    owed: (w, g) => SplitSpec(SplitMethod.adjustment, {
      w.member(g, 'Arjun'): 0,
      w.member(g, 'Priya'): 15000,
      w.member(g, 'Rahul'): -5000,
    }),
  ),
  (
    label: 'equal, two of three',
    paid: (w, g) => SplitSpec.single(w.member(g, 'Arjun'), 90000),
    owed: (w, g) => SplitSpec(SplitMethod.equal, {
      w.member(g, 'Priya'): 1,
      w.member(g, 'Rahul'): 1,
    }),
  ),
  (
    label: 'multi-payer, equal split',
    paid: (w, g) => SplitSpec(SplitMethod.exact, {
      w.member(g, 'Arjun'): 60000,
      w.member(g, 'Priya'): 30000,
    }),
    owed: (w, g) => SplitSpec(SplitMethod.equal, {
      w.member(g, 'Arjun'): 1,
      w.member(g, 'Priya'): 1,
      w.member(g, 'Rahul'): 1,
    }),
  ),
];

Future<ExpenseId> _expense(RealWorld w, GroupId gid, _Case c) =>
    w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Houseboat',
        total: 90000,
        currency: 'INR',
        paidBy: c.paid(w, gid),
        owedBy: c.owed(w, gid),
        category: 'travel.hotel',
        date: DateTime.utc(2026, 11, 5),
        notes: 'first note',
      ),
    );

Future<void> _open(WidgetTester tester, RealWorld w, ExpenseId id) async {
  await pumpReal(tester, w, location: Routes.home);
  w.push(Routes.editExpense(id));
  await qaSettle(tester);
}

Finder get _save => find.byWidgetPredicate(
  (w) => w is Text && (w.data == S.saveExpense || w.data == S.saveChanges),
);

void main() {
  group('Settings, Your name', settingsNameProbes);
  for (final c in _cases) {
    testWidgets('R21 sweep UIFLOW-R17-01 class (${c.label}): saving a '
        'description edit leaves the money block exactly as stored', (
      tester,
    ) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup();
      final id = await _expense(w, gid, c);
      final before = w.state.expense(id)!.money;
      await _open(tester, w, id);
      await tester.enterText(
        fieldLabeled(S.description),
        'Houseboat, Alleppey',
      );
      await tester.pump();
      await qaTap(tester, _save);
      final e = w.state.expense(id)!;
      expect(e.description, 'Houseboat, Alleppey');
      expect(e.money.total, before.total);
      expect(e.money.paidBy, before.paidBy);
      expect(e.money.owedBy, before.owedBy);
      expect(e.money.owed, before.owed);
      expect(e.money.paid, before.paid);
      await w.shutdown(tester);
    });

    testWidgets('R21 sweep UIFLOW-R17-01 class (${c.label}): another phone '
        'changes the money while the editor is open; a description edit '
        'keeps it', (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup();
      final id = await _expense(w, gid, c);
      await _open(tester, w, id);
      final theirs = SplitCalculator.buildMoneyBlock(
        total: 120000,
        currency: 'INR',
        paidBy: SplitSpec.single(w.member(gid, 'Rahul'), 120000),
        owedBy: SplitSpec(SplitMethod.equal, {
          w.member(gid, 'Arjun'): 1,
          w.member(gid, 'Priya'): 1,
          w.member(gid, 'Rahul'): 1,
        }),
      );
      await _remote(w, gid, id, {ExpenseFields.money: theirs.toJson()});
      await qaSettle(tester);
      expect(w.state.expense(id)!.money.total, 120000);
      await tester.enterText(
        fieldLabeled(S.description),
        'Houseboat, Alleppey',
      );
      await tester.pump();
      await qaTap(tester, _save);
      final e = w.state.expense(id)!;
      expect(e.description, 'Houseboat, Alleppey');
      expect(e.money.total, 120000);
      expect(e.money.paid, {w.member(gid, 'Rahul'): 120000});
      expect(e.money.owedBy, theirs.owedBy);
      await w.shutdown(tester);
    });
  }
}

/// UIFLOW-R21-01: Settings > Your name, saved as it opened, still renames
/// my member in every group whose name for me differs from the profile.
void settingsNameProbes() {
  testWidgets(
    'UIFLOW-R21-01: Settings, Your name saved unchanged leaves the name a '
    'group has for me alone',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final goa = await w.seedGroup();
      final office = await w.seedGroup(name: 'Office', people: ['Meera']);
      final me = w.settings.profile!.personId;
      final mine = w.group(office).memberForPerson(me)!.id;
      // Members > Rename on myself (or a friend's phone renaming me there
      // and syncing): the Office group knows me as "Arjun K".
      await w.ledger.renameMember(office, mine, 'Arjun K');
      expect(w.group(office).members[mine]!.displayName, 'Arjun K');
      final membersBefore = w.ledger.current.state.groups[office]!.members.length;

      await pumpReal(tester, w, location: Routes.settings);
      await qaTap(tester, find.text('Arjun'));
      expect(find.byType(AlertDialog), findsOneWidget);
      // Save with the field exactly as it opened.
      await qaTap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(S.save),
        ),
      );
      expect(find.byType(AlertDialog), findsNothing);
      expect(w.settings.profile!.displayName, 'Arjun');
      expect(w.group(office).members.length, membersBefore);
      // Nothing was changed, so nothing is renamed.
      expect(w.group(office).members[mine]!.displayName, 'Arjun K');
      expect(w.group(goa).memberForPerson(me)!.displayName, 'Arjun');
      await w.shutdown(tester);
    },
  );

  testWidgets(
    'UIFLOW-R21-01: Settings, Your name saved unchanged does not undo a '
    'rename a friend\'s phone gave me in a group',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final office = await w.seedGroup(name: 'Office', people: ['Meera']);
      final me = w.settings.profile!.personId;
      final mine = w.group(office).memberForPerson(me)!.id;
      _counter++;
      await w.ledger.applyRemote(office, [
        Operation(
          id: '$office/$_otherPhone/$_counter',
          groupId: office,
          deviceId: _otherPhone,
          counter: _counter,
          hlc: Hlc(qaNow.millisecondsSinceEpoch + 60000, _counter, _otherPhone),
          entityType: EntityType.member,
          entityId: mine,
          kind: OpKind.update,
          payload: {MemberFields.displayName: 'Arjun (Pune)'},
        ),
      ]);
      expect(w.group(office).members[mine]!.displayName, 'Arjun (Pune)');
      await pumpReal(tester, w, location: Routes.settings);
      await qaTap(tester, find.text('Arjun'));
      await qaTap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(S.save),
        ),
      );
      expect(w.settings.profile!.displayName, 'Arjun');
      expect(w.group(office).members[mine]!.displayName, 'Arjun (Pune)');
      await w.shutdown(tester);
    },
  );

  testWidgets(
    'R21 probe (premise of UIFLOW-R21-01): a name the user does change in '
    'Settings is given to my member in every group',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final goa = await w.seedGroup();
      final office = await w.seedGroup(name: 'Office', people: ['Meera']);
      final me = w.settings.profile!.personId;
      final mine = w.group(office).memberForPerson(me)!.id;
      await w.ledger.renameMember(office, mine, 'Arjun K');
      await pumpReal(tester, w, location: Routes.settings);
      await qaTap(tester, find.text('Arjun'));
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        'Arjun Mehta',
      );
      await tester.pump();
      await qaTap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(S.save),
        ),
      );
      expect(w.settings.profile!.displayName, 'Arjun Mehta');
      expect(w.group(office).members[mine]!.displayName, 'Arjun Mehta');
      expect(w.group(goa).memberForPerson(me)!.displayName, 'Arjun Mehta');
      await w.shutdown(tester);
    },
  );
}
