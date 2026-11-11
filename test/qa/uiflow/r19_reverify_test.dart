// QA UIFLOW round 19: reverification of UIFLOW-R18-01 (hidden characters
// take room in the notes and description caps) in the real screens, and a
// regression sweep around the changed code (TextCapFormatter, the Settle up
// notes prompt). Over the real Ledger(MemoryOpStore) +
// KvSettingsRepository. The formatter itself is probed against the
// whole-text measure in r19_formatter_fuzz_test.dart.
//
// Tests named "UIFLOW-R19-NN" with `skip:` are failing repros for open
// findings; unskip to verify a fix.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import 'real_harness.dart';

Future<ExpenseId> _expense(RealWorld w, GroupId gid, {String notes = ''}) =>
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

Future<void> _openEditor(WidgetTester tester, RealWorld w, ExpenseId id) async {
  await pumpReal(tester, w, location: Routes.home);
  w.push(Routes.editExpense(id));
  await qaSettle(tester);
}

Finder get _saveExpense => find.byWidgetPredicate(
  (w) => w is Text && (w.data == S.saveExpense || w.data == S.saveChanges),
);

Finder get _promptField => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

Finder get _promptSave =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text(S.save));

Finder get _promptTooLong => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.text(S.errTooLong),
);

Future<GroupId> _openSettle(WidgetTester tester, RealWorld w) async {
  final gid = await w.seedGroup();
  final me = w.member(gid, 'Arjun');
  await w.ledger.addExpense(
    ExpenseDraft(
      groupId: gid,
      description: 'Dinner',
      total: 60000,
      currency: 'INR',
      paidBy: SplitSpec.single(me, 60000),
      owedBy: SplitSpec(SplitMethod.equal, {me: 1, w.member(gid, 'Priya'): 1}),
      category: 'food.dining',
      date: DateTime.utc(2026, 11, 5),
    ),
  );
  await pumpReal(tester, w, location: Routes.home);
  w.push(Routes.settle(groupId: gid, from: w.member(gid, 'Priya'), to: me));
  await qaSettle(tester);
  return gid;
}

Future<void> _record(WidgetTester tester) => qaTap(
  tester,
  find.byWidgetPredicate((x) => x is FilledButton && x.onPressed != null).last,
);

/// Types [s] at the end of the field the way a keyboard sends it: one
/// edit per code point, the cursor after it.
Future<void> _typeAtEnd(WidgetTester tester, Finder field, String s) async {
  for (final r in s.runes) {
    final now = tester.widget<TextField>(field).controller!.text;
    final next = now + String.fromCharCode(r);
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: next.length),
      ),
    );
    await tester.pump();
  }
}

String _held(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field).controller!.text;

void _noRawText() {
  expect(find.textContaining('LedgerException'), findsNothing);
  expect(find.textContaining('longer than'), findsNothing);
  expect(find.textContaining('invalidInput'), findsNothing);
}

void main() {
  // ------------------------------------------------- UIFLOW-R18-01 --

  testWidgets('R19 probe UIFLOW-R18-01: Settle up, a note with a bidi '
      'isolate around every word is kept whole, counts the letters only, '
      'takes typing and records the cleaned note', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _openSettle(tester, w);
    // 200 words of four letters, each wrapped in FSI ... PDI, a space
    // between them: 999 characters stored, 1399 as typed.
    final pasted = List.filled(200, '\u{2068}abcd\u{2069}').join(' ');
    await qaTap(tester, find.text(S.notes));
    await tester.enterText(_promptField, pasted);
    await tester.pump();
    expect(_held(tester, _promptField), pasted);
    expect(find.text('999/1000'), findsOneWidget);
    expect(_promptTooLong, findsNothing);
    await _typeAtEnd(tester, _promptField, 'z');
    expect(_held(tester, _promptField), '${pasted}z');
    expect(find.text('1000/1000'), findsOneWidget);
    await _typeAtEnd(tester, _promptField, 'y');
    expect(_held(tester, _promptField), '${pasted}z', reason: 'at the cap');
    await qaTap(tester, _promptSave);
    await _record(tester);
    final payments = w.group(gid).liveExpenses.where((e) => e.isPayment);
    expect(payments.single.notes, '${List.filled(200, 'abcd').join(' ')}z');
    _noRawText();
    await w.shutdown(tester);
  });

  testWidgets('R19 probe UIFLOW-R18-01: the expense description keeps a '
      'paste of 120 letters each after a zero-width space typed in the '
      'middle of the old description, and stores it', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final id = await _expense(w, gid);
    await _openEditor(tester, w, id);
    final field = fieldLabeled(S.description);
    // The old description is "Dinner"; paste between "Din" and "ner".
    final insert = List.filled(114, '\u{200B}q').join();
    await tester.showKeyboard(field);
    await tester.pump();
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: 'Din${insert}ner',
        selection: TextSelection.collapsed(offset: 3 + insert.length),
      ),
    );
    await tester.pump();
    expect(_held(tester, field), 'Din${insert}ner');
    expect(find.text(S.errTooLong), findsNothing);
    // One more letter does not fit (120 stored) and is refused.
    final now = _held(tester, field);
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: '${now}s',
        selection: TextSelection.collapsed(offset: now.length + 1),
      ),
    );
    await tester.pump();
    expect(_held(tester, field), now);
    await qaTap(tester, _saveExpense);
    expect(w.state.expense(id)!.description, 'Din${'q' * 114}ner');
    _noRawText();
    await w.shutdown(tester);
  });

  testWidgets('R19 probe UIFLOW-R18-01: the expense notes field keeps CRLF '
      'line breaks as one character each, as the Ledger stores them', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final id = await _expense(w, gid, notes: 'first note');
    await _openEditor(tester, w, id);
    await qaReveal(tester, fieldLabeled(S.notes));
    // 500 lines of "a" and CRLF: 1500 code units, 1000 characters as typed
    // (CRLF is one character) and 999 stored once the last break is
    // trimmed. One more line fits as a letter and nothing after it.
    final pasted = List.filled(500, 'a\r\n').join();
    await tester.enterText(fieldLabeled(S.notes), pasted);
    await tester.pump();
    expect(_held(tester, fieldLabeled(S.notes)), pasted);
    await qaTap(tester, _saveExpense);
    expect(w.state.expense(id)!.notes, List.filled(500, 'a').join('\n'));
    await w.shutdown(tester);
  });

  // --------------------------------------------- regression sweep --

  testWidgets('R19 sweep: Settle up, the notes prompt opens again with a '
      'note of 1000 letters and hidden marks whole and Save is on', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _openSettle(tester, w);
    final pasted = List.filled(1000, 'a\u{200E}').join();
    await qaTap(tester, find.text(S.notes));
    await tester.enterText(_promptField, pasted);
    await tester.pump();
    await qaTap(tester, _promptSave);
    await qaTap(tester, find.text(S.notes).first);
    expect(_held(tester, _promptField), pasted);
    expect(find.text('1000/1000'), findsOneWidget);
    await qaTap(tester, _promptSave);
    await _record(tester);
    final payments = w.group(gid).liveExpenses.where((e) => e.isPayment);
    expect(payments.single.notes, 'a' * 1000);
    await w.shutdown(tester);
  });

  // ------------------------------------------------- UIFLOW-R19-01 --

  // The counter measures the note as the Ledger stores it now, with its
  // end trimmed. Line breaks and spaces typed at the end take no room in
  // it, but they do once a letter follows them, so the field refuses the
  // next letter while the counter still says there is room.
  testWidgets(
    'UIFLOW-R19-01: Settle up notes, after line breaks typed at the end of '
    'a note near the cap the counter shows room but the next letter is '
    'refused with no message',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      await _openSettle(tester, w);
      await qaTap(tester, find.text(S.notes));
      await tester.enterText(_promptField, 'a' * 998);
      await tester.pump();
      // Two line breaks to start a new paragraph.
      await _typeAtEnd(tester, _promptField, '\n\n');
      expect(_held(tester, _promptField), '${'a' * 998}\n\n');
      final full = find.text('1000/1000').evaluate().isNotEmpty;
      await _typeAtEnd(tester, _promptField, 'b');
      final typed = _held(tester, _promptField) == '${'a' * 998}\n\nb';
      // Either the counter counts the breaks once they hold room for what
      // follows them (1000/1000, and the letter is refused), or the letter
      // goes in. Today the counter shows 998/1000 and refuses the letter.
      expect(
        typed || full,
        isTrue,
        reason: 'the counter shows room but the letter is refused',
      );
      await w.shutdown(tester);
    },
  );

  testWidgets('R19 probe (around UIFLOW-R19-01): the counter counts the '
      'line breaks at the end and shows room exactly when a letter fits', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await _openSettle(tester, w);
    await qaTap(tester, find.text(S.notes));
    await tester.enterText(_promptField, 'a' * 998);
    await tester.pump();
    await _typeAtEnd(tester, _promptField, '\n\n');
    expect(find.text('1000/1000'), findsOneWidget);
    expect(_promptTooLong, findsNothing);
    await _typeAtEnd(tester, _promptField, 'b');
    expect(_held(tester, _promptField), '${'a' * 998}\n\n');
    expect(find.text('1000/1000'), findsOneWidget);
    expect(_promptTooLong, findsNothing);
    // With a single trailing break the counter shows the one character
    // left, and the letter fits (1000 stored).
    await tester.enterText(_promptField, '${'a' * 998}\n');
    await tester.pump();
    expect(find.text('999/1000'), findsOneWidget);
    await _typeAtEnd(tester, _promptField, 'b');
    expect(_held(tester, _promptField), '${'a' * 998}\nb');
    expect(find.text('1000/1000'), findsOneWidget);
    await w.shutdown(tester);
  });
}
