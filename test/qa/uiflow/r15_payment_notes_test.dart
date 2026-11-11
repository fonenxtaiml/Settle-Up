// QA UIFLOW round 15: payment notes. Settle up takes a note of any length
// the Ledger accepts (SPEC 5.16: notes up to 1000 characters), but Edit
// payment caps its notes field at 500, so the first key typed in a longer
// note cuts it to 500 characters. Over the real Ledger(MemoryOpStore) +
// KvSettingsRepository.
//
// Tests named "UIFLOW-R15-NN" with `skip:` are failing repros for open
// findings; unskip to verify a fix.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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

void main() {
  testWidgets('R15 probe (premise of UIFLOW-R15-02): Settle up records a '
      'payment note of 800 characters', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
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
    await qaTap(tester, find.text(S.notes));
    await promptAndSave(tester, _longNote);
    final record = find.byWidgetPredicate(
      (x) => x is FilledButton && x.onPressed != null,
    );
    await qaTap(tester, record.last);
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
}
