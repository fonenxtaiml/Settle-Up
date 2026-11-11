// QA UIFLOW round 21: reverification of UIFLOW-R19-01 after its second fix
// (2d7e2bc: the notes counter also counts the blanks at the start of the
// note as the cap holds them once a letter is typed before them), a probe
// of the whole defect class in the real Settle up screen (blanks at the
// start, at the end and at both edges, letters typed at every place a
// cursor can be, inside the blank runs too) and a regression sweep around
// the changed code (TextCapFormatter.counted, the notes prompt). Over the
// real Ledger(MemoryOpStore) + KvSettingsRepository.
//
// Tests named "UIFLOW-R21-NN" with `skip:` are failing repros for open
// findings; unskip to verify a fix.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/text_clean.dart';
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

String _held(WidgetTester tester) =>
    tester.widget<TextField>(_promptField).controller!.text;

/// Types one letter at [at] (code units) the way a keyboard sends it.
Future<void> _typeAt(WidgetTester tester, String ch, int at) async {
  final next = _held(tester).replaceRange(at, at, ch);
  tester.testTextInput.updateEditingValue(
    TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: at + ch.length),
    ),
  );
  await tester.pump();
}

int _shown(WidgetTester tester) {
  final d = tester.widget<TextField>(_promptField).decoration!;
  return int.parse(d.counterText!.split('/').first);
}

/// Every place a cursor can be: the grapheme boundaries of [s].
List<int> _cursorPlaces(String s) {
  final out = <int>[0];
  var off = 0;
  for (final g in s.characters) {
    off += g.length;
    out.add(off);
  }
  return out;
}

void _noRawText() {
  expect(find.textContaining('LedgerException'), findsNothing);
  expect(find.textContaining('longer than'), findsNothing);
  expect(find.textContaining('invalidInput'), findsNothing);
}

void main() {
  // ------------------------------------------------- UIFLOW-R19-01 --

  testWidgets('R21 probe UIFLOW-R19-01: Settle up notes, blanks at the '
      'start, the end or both: the counter shows room exactly when a letter '
      'goes in at both ends, and while it shows room a letter goes in at '
      'every cursor place, inside the blank runs too', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await _openSettle(tester, w);
    await qaTap(tester, find.text(S.notes));
    // (leading blanks, trailing blanks)
    const edges = <(String, String)>[
      ('\n\n', ''),
      ('', '\n\n'),
      ('\n\n', '\n'),
      ('\n', '\n\n'),
      ('\r\n\r\n', ''),
      (' \t', ''),
      ('\u200B\n\u200E', ''),
      ('\u00A0\n', ' '),
      ('\u2028 ', '\u3000'),
      ('\n \n', '\n \n'),
      ('\u200B\u200B', '\u200E'),
    ];
    var checkedFull = 0;
    var checkedRoom = 0;
    for (final (lead, trail) in edges) {
      final blanksTaken = TextClean.clean(lead + trail, multiline: true).isEmpty
          ? 0
          : [lead, trail]
                .map(
                  (e) => e
                      .replaceAll('\r\n', '\n')
                      .replaceAll(RegExp('[\u200B\u200E]'), '')
                      .characters
                      .length,
                )
                .reduce((a, b) => a > b ? a : b);
      // A note one short of full, and one full, by the counter's measure.
      for (final room in [1, 0]) {
        final letters = 1000 - blanksTaken - room;
        final text =
            '$lead${'a' * (letters ~/ 2)}x${'a' * (letters - letters ~/ 2 - 1)}$trail';
        final reason =
            'lead ${lead.runes.toList()} trail '
            '${trail.runes.toList()} room $room';
        final places = _cursorPlaces(text);
        // Each cursor place near the edges and one in the middle.
        final probe = {
          ...places.take(lead.length + 2),
          places[places.length ~/ 2],
          ...places.skip(places.length - trail.length - 2),
        }.toList()..sort();
        await tester.enterText(_promptField, text);
        await tester.pump();
        final shown = _shown(tester);
        expect(_promptTooLong, findsNothing, reason: reason);
        final went = <int, bool>{};
        for (final at in probe) {
          await tester.enterText(_promptField, text);
          await tester.pump();
          await _typeAt(tester, 'T', at);
          final now = _held(tester);
          went[at] = now == text.replaceRange(at, at, 'T');
          if (!went[at]!) expect(now, text, reason: '$reason at $at');
          expect(_promptTooLong, findsNothing, reason: '$reason at $at');
        }
        final ends = went[0]! && went[text.length]!;
        expect(ends, shown < 1000, reason: '$reason shown $shown');
        if (shown < 1000) {
          checkedRoom++;
          for (final e in went.entries) {
            expect(e.value, isTrue, reason: '$reason shown $shown at ${e.key}');
          }
        } else {
          checkedFull++;
        }
      }
    }
    // Both sides of the counter's edge were reached.
    expect(checkedRoom, greaterThan(0));
    expect(checkedFull, greaterThan(0));
    _noRawText();
    await w.shutdown(tester);
  });

  testWidgets('R21 probe UIFLOW-R19-01: with the counter full from line '
      'breaks at the start, Save is on, no "too long" shows, a letter typed '
      'after the breaks still goes in and the payment keeps the note trimmed', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _openSettle(tester, w);
    await qaTap(tester, find.text(S.notes));
    await tester.enterText(_promptField, '\n\n${'a' * 998}');
    await tester.pump();
    expect(_shown(tester), 1000);
    final sem = tester.widget<TextField>(_promptField).decoration!;
    expect(sem.semanticCounterText, isNotNull);
    expect(_promptTooLong, findsNothing);
    // Refused at the very start, with the counter saying no room.
    await _typeAt(tester, 'T', 0);
    expect(_held(tester), '\n\n${'a' * 998}');
    // After the breaks the letter goes in (999 stored).
    await _typeAt(tester, 'T', 2);
    expect(_held(tester), '\n\nT${'a' * 998}');
    expect(_shown(tester), 1000);
    expect(_promptTooLong, findsNothing);
    final save = tester.widget<FilledButton>(
      find.ancestor(of: _promptSave, matching: find.byType(FilledButton)),
    );
    expect(save.onPressed, isNotNull);
    await qaTap(tester, _promptSave);
    await _record(tester);
    final payments = w.group(gid).liveExpenses.where((e) => e.isPayment);
    expect(payments.single.notes, 'T${'a' * 998}');
    _noRawText();
    await w.shutdown(tester);
  });

  testWidgets('R21 sweep: the notes counter on an empty field, on blanks '
      'only and on a paste at the start goes by what is stored', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await _openSettle(tester, w);
    await qaTap(tester, find.text(S.notes));
    expect(_shown(tester), 0);
    // Blanks only take no room: a letter typed anywhere is the whole note.
    await tester.enterText(_promptField, '\n \n\n');
    await tester.pump();
    expect(_shown(tester), 0);
    await _typeAt(tester, 'T', 0);
    expect(_held(tester), 'T\n \n\n');
    // Now text goes before them, the breaks after it count as the cap
    // holds them once a letter follows (the R19 fix): 1 + 4.
    expect(_shown(tester), 5);
    // A paste at the start of a note starting with breaks keeps what fits:
    // with 3 shown free, 3 letters of a 5-letter paste go in.
    await tester.enterText(_promptField, '\n\n${'a' * 995}');
    await tester.pump();
    expect(_shown(tester), 997);
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: 'PQRST\n\n${'a' * 995}',
        selection: const TextSelection.collapsed(offset: 5),
      ),
    );
    await tester.pump();
    expect(_held(tester), 'PQR\n\n${'a' * 995}');
    expect(_shown(tester), 1000);
    expect(_promptTooLong, findsNothing);
    _noRawText();
    await w.shutdown(tester);
  });
}
