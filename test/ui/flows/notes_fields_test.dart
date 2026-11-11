// Notes fields (UIFLOW-R15-02, UIFLOW-R15-03): one cap everywhere, the
// SPEC's 1000 characters (Settle up, Edit payment, the expense editor); a
// note the field already holds is never cut or joined into one line; and
// a note is optional everywhere, so clearing it takes it out.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/strings.dart';

import '../../qa/uiflow/r2_regression_test.dart' show promptAndSave;
import '../../qa/uiflow/real_harness.dart';

String _note(int n) => List.generate(n, (i) => 'abcdefghij'[i % 10]).join();

Finder get _promptField => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

String _text(WidgetTester tester, Finder f) =>
    tester.widget<TextField>(f).controller!.text;

Future<ExpenseId> _expenseWithNote(RealWorld w, GroupId gid, String notes) =>
    w.ledger.addExpense(
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
        notes: notes,
      ),
    );

Future<ExpenseId> _paymentWithNote(RealWorld w, GroupId gid, String notes) =>
    w.ledger.recordPayment(
      PaymentDraft(
        groupId: gid,
        from: w.member(gid, 'Priya'),
        to: w.member(gid, 'Arjun'),
        amount: 50000,
        currency: 'INR',
        method: PaymentMethod.upi,
        date: DateTime.utc(2026, 11, 8),
        notes: notes,
      ),
    );

Future<void> _openEdit(WidgetTester tester, RealWorld w, ExpenseId id) async {
  await pumpReal(tester, w, location: Routes.home);
  w.push(Routes.editExpense(id));
  await qaSettle(tester);
  await qaReveal(tester, fieldLabeled(S.notes));
}

/// Save on the expense editor or Edit payment.
Finder get _save => find.byWidgetPredicate(
  (w) => w is Text && (w.data == S.saveExpense || w.data == S.saveChanges),
);

Future<GroupId> _openSettle(WidgetTester tester, RealWorld w) async {
  final gid = await w.seedGroup();
  await _expenseWithNote(w, gid, '');
  await pumpReal(tester, w, location: Routes.home);
  w.push(
    Routes.settle(
      groupId: gid,
      from: w.member(gid, 'Priya'),
      to: w.member(gid, 'Arjun'),
    ),
  );
  await qaSettle(tester);
  return gid;
}

Future<void> _record(WidgetTester tester) => qaTap(
  tester,
  find.byWidgetPredicate((x) => x is FilledButton && x.onPressed != null).last,
);

void main() {
  test('one notes cap, the Ledger\'s', () {
    expect(kNotesMax, TextRules.notes);
    expect(kNotesMax, 1000);
  });

  testWidgets('the expense editor keeps an 800-character note when a word '
      'is added', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final note = _note(800);
    final id = await _expenseWithNote(w, gid, note);
    await _openEdit(tester, w, id);
    final f = fieldLabeled(S.notes);
    expect(_text(tester, f), note);
    await tester.enterText(f, '$note ok');
    await tester.pump();
    expect(_text(tester, f), '$note ok');
    await qaTap(tester, _save);
    expect(w.state.expense(id)!.notes, '$note ok');
    await w.shutdown(tester);
  });

  for (final screen in ['expense', 'payment']) {
    testWidgets('the $screen editor takes 1000 characters and refuses the '
        '1001st', (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup();
      final id = screen == 'expense'
          ? await _expenseWithNote(w, gid, '')
          : await _paymentWithNote(w, gid, '');
      await _openEdit(tester, w, id);
      final f = fieldLabeled(S.notes);
      await tester.enterText(f, _note(1001));
      await tester.pump();
      expect(_text(tester, f), _note(1000));
      expect(find.text(S.errTooLong), findsNothing);
      await qaTap(tester, _save);
      expect(w.state.expense(id)!.notes, _note(1000));
      await w.shutdown(tester);
    });

    testWidgets('the $screen editor keeps the line breaks of a note it holds '
        'when a word is added', (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup();
      const note = 'Paid at the counter\nReceipt in the bag';
      final id = screen == 'expense'
          ? await _expenseWithNote(w, gid, note)
          : await _paymentWithNote(w, gid, note);
      expect(w.state.expense(id)!.notes, note);
      await _openEdit(tester, w, id);
      final f = fieldLabeled(S.notes);
      expect(_text(tester, f), note);
      await tester.enterText(f, '$note ok');
      await tester.pump();
      expect(_text(tester, f), '$note ok');
      await qaTap(tester, _save);
      expect(w.state.expense(id)!.notes, '$note ok');
      await w.shutdown(tester);
    });
  }

  for (final screen in ['expense', 'payment']) {
    testWidgets('the $screen editor never cuts a held note longer than 1000 '
        'characters: it says so, refuses more text and takes a shortening', (
      tester,
    ) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup();
      final id = screen == 'expense'
          ? await _expenseWithNote(w, gid, 'short')
          : await _paymentWithNote(w, gid, 'short');
      await _heldLongNote(w, gid, id);
      await _openEdit(tester, w, id);
      final f = fieldLabeled(S.notes);
      expect(_text(tester, f), _note(1500));
      expect(find.text(S.errTooLong), findsOneWidget);
      await tester.enterText(f, '${_note(1500)} ok');
      await tester.pump();
      expect(_text(tester, f), _note(1500), reason: 'cut or grown');
      await tester.enterText(f, _note(990));
      await tester.pump();
      expect(_text(tester, f), _note(990));
      expect(find.text(S.errTooLong), findsNothing);
      await qaTap(tester, _save);
      expect(w.state.expense(id)!.notes, _note(990));
      await w.shutdown(tester);
    });
  }

  testWidgets('Settle up: the notes prompt caps a paste at 1000 characters '
      'and the payment records them', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _openSettle(tester, w);
    await qaTap(tester, find.text(S.notes));
    await tester.enterText(_promptField, _note(1200));
    await tester.pump();
    expect(_text(tester, _promptField), _note(1000));
    await qaTap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(S.save),
      ),
    );
    await _record(tester);
    final pay = w.group(gid).liveExpenses.singleWhere((e) => e.isPayment);
    expect(pay.notes, _note(1000));
    await w.shutdown(tester);
  });

  testWidgets('Settle up: a note of only spaces is no note', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _openSettle(tester, w);
    await qaTap(tester, find.text(S.notes));
    await promptAndSave(tester, 'GPay');
    await qaTap(tester, find.text('GPay'));
    await promptAndSave(tester, '   ');
    expect(find.text('GPay'), findsNothing);
    expect(find.text(S.optional), findsOneWidget);
    await _record(tester);
    final pay = w.group(gid).liveExpenses.singleWhere((e) => e.isPayment);
    expect(pay.notes, isEmpty);
    await w.shutdown(tester);
  });

  testWidgets('Settle up: an empty notes prompt saved at once leaves no '
      'note', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _openSettle(tester, w);
    await qaTap(tester, find.text(S.notes));
    await qaTap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(S.save),
      ),
    );
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(S.optional), findsOneWidget);
    await _record(tester);
    final pay = w.group(gid).liveExpenses.singleWhere((e) => e.isPayment);
    expect(pay.notes, isEmpty);
    await w.shutdown(tester);
  });

  testWidgets('a name prompt still keeps Save off while empty', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text('Arjun'));
    await tester.enterText(_promptField, '');
    await tester.pump();
    final save = tester.widget<FilledButton>(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(FilledButton),
      ),
    );
    expect(save.onPressed, isNull);
    await w.shutdown(tester);
  });
}

const _olderPhone = 'dddddddd-0000-7000-8000-000000000003';

/// [id]'s note as an older phone wrote it: the remote check allows up to
/// 4 code units per allowed character, so 1500 ASCII characters pass.
Future<void> _heldLongNote(RealWorld w, GroupId gid, ExpenseId id) async {
  final added = await w.ledger.applyRemote(gid, [
    Operation(
      id: '$gid/$_olderPhone/1',
      groupId: gid,
      deviceId: _olderPhone,
      counter: 1,
      hlc: Hlc(qaNow.millisecondsSinceEpoch + 60000, 0, _olderPhone),
      entityType: EntityType.expense,
      entityId: id,
      kind: OpKind.update,
      payload: {ExpenseFields.notes: _note(1500)},
    ),
  ]);
  expect(added, hasLength(1));
  expect(w.state.expense(id)!.notes, _note(1500));
}
