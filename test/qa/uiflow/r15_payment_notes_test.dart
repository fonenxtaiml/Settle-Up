// QA UIFLOW round 15: payment notes. Settle up takes a note of any length
// the Ledger accepts (SPEC 5.16: notes up to 1000 characters), but Edit
// payment caps its notes field at 500, so the first key typed in a longer
// note cuts it to 500 characters (UIFLOW-R15-02). And a note added on
// Settle up cannot be taken out again: the notes prompt keeps Save off
// while it is empty (UIFLOW-R15-03). Over the real Ledger(MemoryOpStore) +
// KvSettingsRepository.
//
// Tests named "UIFLOW-R15-NN" with `skip:` are failing repros for open
// findings; unskip to verify a fix.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import 'r2_regression_test.dart' show promptAndSave;
import 'real_harness.dart';

/// 800 characters in sentences, as a long note is written.
final String _longNote = List.generate(
  40,
  (i) => 'Line $i of the bill. ',
).join().padRight(800, 'x').substring(0, 800);

/// Settle up from Priya to me in a group where Priya owes me 200.
Future<GroupId> _openSettle(WidgetTester tester, RealWorld w) async {
  final gid = await w.seedGroup();
  final me = w.member(gid, 'Arjun');
  final priya = w.member(gid, 'Priya');
  await w.ledger.addExpense(
    ExpenseDraft(
      groupId: gid,
      description: 'Dinner',
      total: 60000,
      currency: 'INR',
      paidBy: SplitSpec.single(me, 60000),
      owedBy: SplitSpec(SplitMethod.exact, {
        me: 20000,
        priya: 20000,
        w.member(gid, 'Rahul'): 20000,
      }),
      category: 'food.dining',
      date: DateTime.utc(2026, 11, 5),
    ),
  );
  await pumpReal(tester, w, location: Routes.home);
  w.push(Routes.settle(groupId: gid, from: priya, to: me));
  await qaSettle(tester);
  return gid;
}

Future<void> _record(WidgetTester tester) => qaTap(
  tester,
  find.byWidgetPredicate((x) => x is FilledButton && x.onPressed != null).last,
);

void main() {
  testWidgets('R15 probe (premise of UIFLOW-R15-02): Settle up records a '
      'payment note of 800 characters', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _openSettle(tester, w);
    await qaTap(tester, find.text(S.notes));
    await promptAndSave(tester, _longNote);
    await _record(tester);
    final pay = w.group(gid).liveExpenses.singleWhere((e) => e.isPayment);
    expect(pay.notes.length, 800);
    await w.shutdown(tester);
  });

  testWidgets(
    'UIFLOW-R15-02: Edit payment keeps a note longer than 500 characters '
    'when a word is added to it',
    (tester) async {
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
          method: PaymentMethod.upi,
          date: DateTime.utc(2026, 11, 8),
          notes: _longNote,
        ),
      );
      await pumpReal(tester, w, location: Routes.home);
      w.push(Routes.editExpense(pid));
      await qaSettle(tester);
      final notes = fieldLabeled(S.notes);
      expect(tester.widget<TextField>(notes).controller!.text, _longNote);
      // One word added at the end of the note.
      await tester.enterText(notes, '$_longNote ok');
      await tester.pump();
      expect(
        tester.widget<TextField>(notes).controller!.text,
        '$_longNote ok',
        reason: 'the field cut the note to its 500 cap',
      );
      await qaTap(tester, find.text(S.saveChanges));
      expect(w.state.expense(pid)!.notes, '$_longNote ok');
      await w.shutdown(tester);
    },
    skip: true, // QA UIFLOW-R15-02: Edit payment cuts a Settle up note longer than 500 characters to 500 on the first key typed in it
  );

  testWidgets(
    'UIFLOW-R15-03: Settle up, a note added by mistake is taken out again by '
    'clearing it in the notes prompt',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await _openSettle(tester, w);
      await qaTap(tester, find.text(S.notes));
      await promptAndSave(tester, 'Oops, wrong note');
      expect(find.text('Oops, wrong note'), findsOneWidget);
      await qaTap(tester, find.text('Oops, wrong note'));
      await tester.enterText(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(TextField),
        ),
        '',
      );
      await tester.pump();
      final save = tester.widget<FilledButton>(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FilledButton),
        ),
      );
      expect(save.onPressed, isNotNull, reason: 'Save is off on an empty note');
      await qaTap(
        tester,
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text(S.save),
        ),
      );
      expect(find.text('Oops, wrong note'), findsNothing);
      expect(find.text(S.optional), findsOneWidget);
      await _record(tester);
      final pay = w.group(gid).liveExpenses.singleWhere((e) => e.isPayment);
      expect(pay.notes, isEmpty);
      await w.shutdown(tester);
    },
    skip: true, // QA UIFLOW-R15-03: a note added on Settle up cannot be removed: the notes prompt keeps Save off while empty
  );

  testWidgets('R15 probe (premise of UIFLOW-R15-03): Cancel on the notes '
      'prompt keeps the note; Save with a new note replaces it', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _openSettle(tester, w);
    await qaTap(tester, find.text(S.notes));
    await promptAndSave(tester, 'Oops');
    await qaTap(tester, find.text('Oops'));
    await qaTap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(S.cancel),
      ),
    );
    expect(find.text('Oops'), findsOneWidget);
    await qaTap(tester, find.text('Oops'));
    await promptAndSave(tester, 'GPay');
    await _record(tester);
    final pay = w.group(gid).liveExpenses.singleWhere((e) => e.isPayment);
    expect(pay.notes, 'GPay');
    await w.shutdown(tester);
  });
}
