// The expense editor and Edit payment send only what the user changed
// (the class of UIFLOW-R17-01): a field still holding what the form loaded
// takes the live value at Save, so a change another phone made to it while
// the form was open is not undone. A field the user did change is sent.
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
import 'package:settle_up/ui/widgets/kit_strings.dart';

import '../../qa/uiflow/real_harness.dart';

const _otherPhone = 'dddddddd-0000-7000-8000-000000000172';

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

Future<ExpenseId> _expense(RealWorld w, GroupId gid) => w.ledger.addExpense(
  ExpenseDraft(
    groupId: gid,
    description: 'Dinner',
    total: 60000,
    currency: 'INR',
    paidBy: SplitSpec.single(w.member(gid, 'Arjun'), 60000),
    owedBy: SplitSpec(SplitMethod.equal, {
      w.member(gid, 'Arjun'): 1,
      w.member(gid, 'Priya'): 1,
    }),
    category: 'food.dining',
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

/// One field another phone changes while the editor is open.
typedef _Change = ({
  String label,
  Map<String, Object?> Function(RealWorld w, GroupId gid) payload,
  void Function(Expense e, RealWorld w, GroupId gid) holds,
});

final List<_Change> _changes = [
  (
    label: 'description',
    payload: (_, _) => {ExpenseFields.description: 'Dinner at Thalassa'},
    holds: (e, _, _) => expect(e.description, 'Dinner at Thalassa'),
  ),
  (
    label: 'notes',
    payload: (_, _) => {ExpenseFields.notes: 'Priya added this'},
    holds: (e, _, _) => expect(e.notes, 'Priya added this'),
  ),
  (
    label: 'category',
    payload: (_, _) => {ExpenseFields.category: 'food.groceries'},
    holds: (e, _, _) => expect(e.category, 'food.groceries'),
  ),
  (
    label: 'date',
    payload: (_, _) => {
      ExpenseFields.date: DateTime.utc(2026, 11, 3).millisecondsSinceEpoch,
    },
    holds: (e, _, _) => expect(e.date, DateTime.utc(2026, 11, 3)),
  ),
  (
    label: 'money',
    payload: (w, gid) => {
      ExpenseFields.money: SplitCalculator.buildMoneyBlock(
        total: 90000,
        currency: 'INR',
        paidBy: SplitSpec.single(w.member(gid, 'Priya'), 90000),
        owedBy: SplitSpec(SplitMethod.equal, {
          w.member(gid, 'Arjun'): 1,
          w.member(gid, 'Priya'): 1,
        }),
      ).toJson(),
    },
    holds: (e, w, gid) {
      expect(e.money.total, 90000);
      expect(e.money.paid, {w.member(gid, 'Priya'): 90000});
    },
  ),
];

void main() {
  for (final c in _changes) {
    final userField = c.label == 'description' ? S.notes : S.description;
    testWidgets('another phone changes the ${c.label} while the expense '
        'editor is open; saving a change to the $userField keeps it', (
      tester,
    ) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup();
      final id = await _expense(w, gid);
      await _open(tester, w, id);
      await _remote(w, gid, id, c.payload(w, gid));
      await qaSettle(tester);
      c.holds(w.state.expense(id)!, w, gid);
      await qaReveal(tester, fieldLabeled(userField));
      await tester.enterText(fieldLabeled(userField), 'Typed here');
      await tester.pump();
      await qaTap(tester, _save);
      final e = w.state.expense(id)!;
      c.holds(e, w, gid);
      if (userField == S.notes) {
        expect(e.notes, 'Typed here');
      } else {
        expect(e.description, 'Typed here');
      }
      await w.shutdown(tester);
    });
  }

  testWidgets('a description the user typed wins over the one another '
      'phone set while the editor was open', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final id = await _expense(w, gid);
    await _open(tester, w, id);
    await _remote(w, gid, id, {ExpenseFields.description: 'Theirs'});
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.description), 'Mine');
    await tester.pump();
    await qaTap(tester, _save);
    expect(w.state.expense(id)!.description, 'Mine');
    await w.shutdown(tester);
  });

  group('Edit payment', () {
    Future<ExpenseId> payment(RealWorld w, GroupId gid) =>
        w.ledger.recordPayment(
          PaymentDraft(
            groupId: gid,
            from: w.member(gid, 'Priya'),
            to: w.member(gid, 'Arjun'),
            amount: 50000,
            currency: 'INR',
            method: PaymentMethod.upi,
            date: DateTime.utc(2026, 11, 8),
            notes: 'first note',
          ),
        );

    testWidgets('another phone changes the note and the amount while it is '
        'open; saving a method change keeps both', (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup();
      final pid = await payment(w, gid);
      await _open(tester, w, pid);
      await _remote(w, gid, pid, {ExpenseFields.notes: 'Priya added this'});
      await _remote(w, gid, pid, {
        ExpenseFields.money: SplitCalculator.paymentBlock(
          from: w.member(gid, 'Priya'),
          to: w.member(gid, 'Arjun'),
          amount: 70000,
          currency: 'INR',
        ).toJson(),
      });
      await qaSettle(tester);
      await qaTap(tester, find.text(KitStrings.cash));
      await qaTap(tester, find.text(S.saveChanges));
      final e = w.state.expense(pid)!;
      expect(e.paymentMethod, PaymentMethod.cash);
      expect(e.notes, 'Priya added this');
      expect(e.money.total, 70000);
      await w.shutdown(tester);
    });

    testWidgets('another phone changes the method while it is open; saving '
        'a note keeps the method', (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup();
      final pid = await payment(w, gid);
      await _open(tester, w, pid);
      await _remote(w, gid, pid, {
        ExpenseFields.paymentMethod: PaymentMethod.bank.name,
      });
      await qaSettle(tester);
      await qaReveal(tester, fieldLabeled(S.notes));
      await tester.enterText(fieldLabeled(S.notes), 'Typed here');
      await tester.pump();
      await qaTap(tester, find.text(S.saveChanges));
      final e = w.state.expense(pid)!;
      expect(e.notes, 'Typed here');
      expect(e.paymentMethod, PaymentMethod.bank);
      await w.shutdown(tester);
    });
  });
}
