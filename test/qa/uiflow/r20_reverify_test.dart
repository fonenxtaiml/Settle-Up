// QA UIFLOW round 20: reverification of UIFLOW-R19-01 (the Settle up notes
// counter leaves out spaces and line breaks at the end of the note while
// the cap counts them once a letter follows) in the real Settle up screen,
// a probe of the whole defect class (blanks at either edge of the note,
// letters typed anywhere in it) and a regression sweep around the changed
// code (TextCapFormatter.counted, the notes prompt). Over the real
// Ledger(MemoryOpStore) + KvSettingsRepository.
//
// Tests named "UIFLOW-R19-NN" / "UIFLOW-R20-NN" with `skip:` are failing
// repros for open findings; unskip to verify a fix.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import 'real_harness.dart';

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

String _held(WidgetTester tester, Finder field) =>
    tester.widget<TextField>(field).controller!.text;

/// Types [s] at [offset] (code units) the way a keyboard sends it: one
/// edit per code point, the cursor after it. Null types at the end.
Future<void> _typeAt(
  WidgetTester tester,
  Finder field,
  String s, {
  int? offset,
}) async {
  var at = offset ?? _held(tester, field).length;
  for (final r in s.runes) {
    final now = _held(tester, field);
    final ch = String.fromCharCode(r);
    final next = now.replaceRange(at, at, ch);
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: next,
        selection: TextSelection.collapsed(offset: at + ch.length),
      ),
    );
    await tester.pump();
    if (_held(tester, field) == next) at += ch.length;
  }
}

String _counter(WidgetTester tester) {
  final d = tester.widget<TextField>(_promptField).decoration!;
  return d.counterText!;
}

void _noRawText() {
  expect(find.textContaining('LedgerException'), findsNothing);
  expect(find.textContaining('longer than'), findsNothing);
  expect(find.textContaining('invalidInput'), findsNothing);
}

void main() {
  // ------------------------------------------------- UIFLOW-R19-01 --

  testWidgets('R20 probe UIFLOW-R19-01: Settle up notes, every blank typed '
      'at the end (spaces, a tab, CRLF, hidden marks) counts as the cap '
      'holds it, and the counter shows room exactly when the next letter '
      'goes in', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await _openSettle(tester, w);
    await qaTap(tester, find.text(S.notes));
    // (blanks typed after 997 letters, counter shown, whether a letter
    // typed after them fits)
    const cases = <(String, int, bool)>[
      ('', 997, true),
      (' ', 998, true),
      ('  ', 999, true),
      ('   ', 1000, false),
      ('\t\n', 999, true),
      ('\r\n', 998, true),
      ('\r\n\r\n', 999, true),
      ('​‎', 997, true),
      ('​ ‎\n', 999, true),
      ('\n\n\n\n\n', 1000, false),
    ];
    for (final (blanks, shown, fits) in cases) {
      await tester.enterText(_promptField, 'a' * 997);
      await tester.pump();
      await _typeAt(tester, _promptField, blanks);
      final text = '${'a' * 997}$blanks';
      final reason = 'blanks ${blanks.runes.toList()}';
      expect(_held(tester, _promptField), text, reason: reason);
      expect(_counter(tester), '$shown/1000', reason: reason);
      expect(_promptTooLong, findsNothing, reason: reason);
      await _typeAt(tester, _promptField, 'b');
      expect(
        _held(tester, _promptField),
        fits ? '${text}b' : text,
        reason: reason,
      );
      expect(shown < 1000, fits, reason: reason);
      if (fits) expect(_counter(tester), '${shown + 1}/1000', reason: reason);
    }
    _noRawText();
    await w.shutdown(tester);
  });

  testWidgets('R20 probe UIFLOW-R19-01: with the counter full from line '
      'breaks at the end, a letter typed in the middle still goes in, no '
      '"too long" shows, Save is on and the note is stored trimmed', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _openSettle(tester, w);
    await qaTap(tester, find.text(S.notes));
    await tester.enterText(_promptField, 'a' * 998);
    await tester.pump();
    await _typeAt(tester, _promptField, '\n\n');
    expect(_counter(tester), '1000/1000');
    // The counter says no room at the end; the middle has room left
    // (998 stored) and takes the letter. The counter is conservative here,
    // which is what the R19-01 fix chose.
    await _typeAt(tester, _promptField, 'm', offset: 499);
    expect(_held(tester, _promptField), '${'a' * 499}m${'a' * 499}\n\n');
    expect(_counter(tester), '1000/1000');
    expect(_promptTooLong, findsNothing);
    // Removing the breaks gives the counter back the stored length.
    final now = _held(tester, _promptField);
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: now.substring(0, now.length - 2),
        selection: const TextSelection.collapsed(offset: 999),
      ),
    );
    await tester.pump();
    expect(_counter(tester), '999/1000');
    await _typeAt(tester, _promptField, '\n\n');
    await qaTap(tester, _promptSave);
    await _record(tester);
    final payments = w.group(gid).liveExpenses.where((e) => e.isPayment);
    expect(payments.single.notes, '${'a' * 499}m${'a' * 499}');
    _noRawText();
    await w.shutdown(tester);
  });

  // The R19-01 fix counts the blanks at the end of the note, which the
  // counter trims but the cap holds once a letter follows them. The blanks
  // at the start are the same class: the counter trims them too, and the
  // cap holds them as soon as a letter is typed before them, so a letter
  // typed at the start of a note that begins with a blank line is refused
  // with no message while the counter shows room.
  testWidgets(
    'UIFLOW-R19-01: Settle up notes, with line breaks at the start of a '
    'note near the cap the counter shows room but a letter typed at the '
    'start is refused with no message',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      await _openSettle(tester, w);
      await qaTap(tester, find.text(S.notes));
      // A blank line first, then the note.
      await _typeAt(tester, _promptField, '\n\n');
      await tester.enterText(_promptField, '\n\n${'a' * 998}');
      await tester.pump();
      expect(_counter(tester), '998/1000');
      expect(_promptTooLong, findsNothing);
      // Back to the start to add a title letter.
      await _typeAt(tester, _promptField, 'T', offset: 0);
      final typed = _held(tester, _promptField) == 'T\n\n${'a' * 998}';
      final full = _counter(tester) == '1000/1000';
      expect(
        typed || full,
        isTrue,
        reason:
            'the counter shows ${_counter(tester)} but the letter is refused',
      );
      await w.shutdown(tester);
    },
    skip: true, // QA UIFLOW-R19-01: Settle up notes counter shows room while a letter typed before line breaks at the start is refused
  );

  testWidgets('R20 probe (premise of the reopened UIFLOW-R19-01): a letter '
      'typed between the two leading breaks, or anywhere after them, goes '
      'in; only the very start is refused', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await _openSettle(tester, w);
    await qaTap(tester, find.text(S.notes));
    final base = '\n\n${'a' * 998}';
    for (final (at, went) in const [(0, false), (1, true), (2, true)]) {
      await tester.enterText(_promptField, base);
      await tester.pump();
      expect(_counter(tester), '998/1000');
      await _typeAt(tester, _promptField, 'T', offset: at);
      expect(
        _held(tester, _promptField),
        went ? base.replaceRange(at, at, 'T') : base,
        reason: 'at $at',
      );
    }
    await w.shutdown(tester);
  });
}
