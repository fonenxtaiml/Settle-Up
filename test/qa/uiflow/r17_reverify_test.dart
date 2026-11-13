// QA UIFLOW round 17: reverification of UIFLOW-R15-01 (Edit group and a
// held group name with no letter or number), UIFLOW-R15-02 (one notes cap,
// a held note never cut) and UIFLOW-R15-03 (a Settle up note can be taken
// out), with probes of each defect class, and a regression sweep around
// the changed code. Over the real Ledger(MemoryOpStore) +
// KvSettingsRepository.
//
// Tests named "UIFLOW-R17-NN" with `skip:` are failing repros for open
// findings; unskip to verify a fix.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

import 'r2_regression_test.dart' show promptAndSave;
import 'real_harness.dart';

const _olderPhone = 'dddddddd-0000-7000-8000-000000000017';

var _counter = 0;

/// One op from another phone, applied as sync would.
Future<void> _remote(
  RealWorld w,
  GroupId gid,
  EntityType type,
  String entityId,
  Map<String, Object?> payload, {
  int afterMs = 60000,
}) async {
  _counter++;
  final added = await w.ledger.applyRemote(gid, [
    Operation(
      id: '$gid/$_olderPhone/$_counter',
      groupId: gid,
      deviceId: _olderPhone,
      counter: _counter,
      hlc: Hlc(qaNow.millisecondsSinceEpoch + afterMs, _counter, _olderPhone),
      entityType: type,
      entityId: entityId,
      kind: OpKind.update,
      payload: payload,
    ),
  ]);
  expect(added, hasLength(1));
}

Future<void> _openEditGroup(
  WidgetTester tester,
  RealWorld w,
  GroupId gid,
) async {
  await pumpReal(tester, w, location: Routes.home);
  w.push(Routes.group(gid));
  await qaSettle(tester);
  w.push(Routes.editGroup(gid));
  await qaSettle(tester);
  expect(find.text(S.editGroupTitle), findsOneWidget);
}

Finder get _promptField => find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

Finder get _promptSave =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text(S.save));

String _text(WidgetTester tester, Finder f) =>
    tester.widget<TextField>(f).controller!.text;

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

/// A family emoji: one character, 11 UTF-16 code units.
const _family = '\u{1F468}‍\u{1F469}‍\u{1F467}‍\u{1F466}';

void main() {
  // ------------------------------------------------- UIFLOW-R15-01 --

  testWidgets('R17 probe UIFLOW-R15-01: a group name an older phone sent '
      'longer than 60 characters is held fitted to 60, blocks no other '
      'change and is kept', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final long = List.filled(9, 'Goa trip ').join().trim(); // 80 characters
    await _remote(w, gid, EntityType.group, gid, {GroupFields.name: long});
    // The Ledger holds it fitted to the 60-character limit.
    final held = w.group(gid).group!.name;
    expect(held, long.substring(0, 60));
    await _openEditGroup(tester, w, gid);
    expect(find.text(S.errTooLong), findsNothing);
    expect(find.text(S.nameNeedsLetter), findsNothing);
    await qaTap(tester, find.text(S.typeHome));
    await qaTap(tester, find.byType(Switch).first);
    await qaTap(tester, find.text(S.saveChanges));
    final g = w.group(gid).group!;
    expect(g.type, GroupType.home);
    expect(g.simplifyDebts, isFalse);
    expect(g.name, held);
    expect(w.location, Routes.group(gid));
    await w.shutdown(tester);
  });

  testWidgets('R17 probe UIFLOW-R15-01: a held name with no letter, edited '
      'with spaces around it only, is still the held name and saves', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await _remote(w, gid, EntityType.group, gid, {GroupFields.name: '★★'});
    await _openEditGroup(tester, w, gid);
    await tester.enterText(fieldLabeled(S.groupName), ' ★★ ');
    await tester.pump();
    expect(find.text(S.nameNeedsLetter), findsNothing);
    await qaTap(tester, find.byType(Switch).first);
    await qaTap(tester, find.text(S.saveChanges));
    expect(w.group(gid).group!.simplifyDebts, isFalse);
    expect(w.group(gid).group!.name, '★★');
    await w.shutdown(tester);
  });

  testWidgets('R17 probe UIFLOW-R15-01: New group still refuses a name with '
      'no letter or number', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.newGroup);
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), '★★');
    await tester.pump();
    expect(find.text(S.nameNeedsLetter), findsOneWidget);
    await qaTap(tester, find.text(S.createGroupAction));
    expect(w.state.visibleGroups, isEmpty);
    await w.shutdown(tester);
  });

  // Edit group sends only what the user changed (GroupPatch, null for an
  // untouched field), so a rename that another phone made while the form
  // was open must survive a Save that changes only Simplify.
  testWidgets(
    'UIFLOW-R17-01: Edit group open while another phone renames the group: '
    'saving a Simplify change keeps the new name',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup();
      final before = w.group(gid).group!.name;
      await _openEditGroup(tester, w, gid);
      // Sync brings Priya's rename while the form is open. Its clock is
      // ahead of this phone's (an op older than the group's own create op
      // would lose and never reach the screen).
      await _remote(w, gid, EntityType.group, gid, {
        GroupFields.name: 'Goa 2026',
      });
      await qaSettle(tester);
      expect(w.group(gid).group!.name, 'Goa 2026');
      // The name field was never touched; only Simplify is switched off.
      expect(_text(tester, fieldLabeled(S.groupName)), before);
      await qaTap(tester, find.byType(Switch).first);
      await qaTap(tester, find.text(S.saveChanges));
      expect(w.group(gid).group!.simplifyDebts, isFalse);
      expect(
        w.group(gid).group!.name,
        'Goa 2026',
        reason: 'the untouched, stale name in the form was sent as a rename',
      );
      await w.shutdown(tester);
    },
  );

  testWidgets('UIFLOW-R17-01: Edit group open while another phone changes the '
      'currency: saving a Simplify change keeps the new currency', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    expect(w.group(gid).group!.currency, 'INR');
    await _openEditGroup(tester, w, gid);
    await _remote(w, gid, EntityType.group, gid, {GroupFields.currency: 'EUR'});
    await qaSettle(tester);
    expect(w.group(gid).group!.currency, 'EUR');
    await qaTap(tester, find.byType(Switch).first);
    await qaTap(tester, find.text(S.saveChanges));
    expect(w.group(gid).group!.simplifyDebts, isFalse);
    expect(
      w.group(gid).group!.currency,
      'EUR',
      reason: 'the untouched, stale currency in the form was sent',
    );
    await w.shutdown(tester);
  });

  // ------------------------------------------------- UIFLOW-R15-02 --

  testWidgets('R17 probe UIFLOW-R15-02: Edit payment, a word typed in the '
      'middle of an 800-character note keeps the whole note', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final note = List.filled(80, 'abcdefghi ').join(); // 800
    final pid = await w.ledger.recordPayment(
      PaymentDraft(
        groupId: gid,
        from: w.member(gid, 'Priya'),
        to: w.member(gid, 'Arjun'),
        amount: 50000,
        currency: 'INR',
        method: PaymentMethod.upi,
        date: DateTime.utc(2026, 11, 8),
        notes: note,
      ),
    );
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.editExpense(pid));
    await qaSettle(tester);
    final f = fieldLabeled(S.notes);
    final field = tester.widget<TextField>(f);
    // A word inserted at 400, the cursor after it, as the keyboard sends it.
    final edited = '${note.substring(0, 400)}GPay ${note.substring(400)}';
    await tester.showKeyboard(f);
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: edited,
        selection: const TextSelection.collapsed(offset: 405),
      ),
    );
    await tester.pump();
    expect(field.controller!.text, edited);
    await qaTap(tester, find.text(S.saveChanges));
    expect(w.state.expense(pid)!.notes, edited.trim());
    await w.shutdown(tester);
  });

  testWidgets('R17 probe UIFLOW-R15-02: Settle up, a 1000-character note '
      'reopened in the prompt is shown whole and recorded whole', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _openSettle(tester, w);
    final note = List.filled(100, 'Paid cash ').join(); // 1000
    await qaTap(tester, find.text(S.notes));
    await promptAndSave(tester, note);
    await qaTap(tester, find.text(note.trim()));
    expect(_text(tester, _promptField), note.trim());
    await qaTap(tester, _promptSave);
    await _record(tester);
    final pay = w.group(gid).liveExpenses.singleWhere((e) => e.isPayment);
    expect(pay.notes, note.trim());
    await w.shutdown(tester);
  });

  testWidgets('R17 probe UIFLOW-R15-02: Edit payment with a held note over '
      '1000 characters: an amount change is refused with copy, never raw '
      'text, and the note is not cut', (tester) async {
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
        notes: 'short',
      ),
    );
    final long = List.filled(120, 'abcdefghi ').join().trim(); // 1199
    await _remote(w, gid, EntityType.expense, pid, {ExpenseFields.notes: long});
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.editExpense(pid));
    await qaSettle(tester);
    expect(find.text(S.errTooLong), findsOneWidget);
    await qaTap(tester, find.text(KitStrings.cash));
    await qaTap(tester, find.text(S.saveChanges));
    expect(w.state.expense(pid)!.notes, long);
    expect(w.state.expense(pid)!.paymentMethod, PaymentMethod.upi);
    expect(find.textContaining('LedgerException'), findsNothing);
    expect(find.textContaining('longer than'), findsNothing);
    expect(find.text(S.paymentTitle), findsOneWidget);
    await w.shutdown(tester);
  });

  // The Ledger measures a note in characters and at most 4 code units for
  // each (TextRules.tooLong); the notes fields of the editors say "too
  // long" by the same measure (notesInputError). The Settle up prompt has
  // no such message and its TextCapFormatter counts characters only.
  testWidgets(
    'UIFLOW-R17-02: Settle up, a note of 400 family emoji (400 characters) '
    'that the Ledger refuses is said to be too long in the notes prompt',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await _openSettle(tester, w);
      final note = List.filled(400, _family).join(); // 4400 code units
      await qaTap(tester, find.text(S.notes));
      await tester.enterText(_promptField, note);
      await tester.pump();
      // Expected: the prompt says so (as Edit payment does for the same
      // note) or keeps Save off, before the note is taken.
      final said = find
          .descendant(
            of: find.byType(AlertDialog),
            matching: find.text(S.errTooLong),
          )
          .evaluate()
          .isNotEmpty;
      final save = tester.widget<FilledButton>(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(FilledButton),
        ),
      );
      expect(
        said || save.onPressed == null,
        isTrue,
        reason: 'the prompt takes a note the Ledger will refuse',
      );
      if (save.onPressed != null) await qaTap(tester, _promptSave);
      expect(w.group(gid).liveExpenses.where((e) => e.isPayment), isEmpty);
      await w.shutdown(tester);
    },
  );

  // Was the premise of UIFLOW-R17-02 (the prompt took the note and only
  // Record refused it). Since the fix the prompt measures the note as the
  // Ledger does: it says "too long", keeps Save off and counts 1100/1000;
  // a note shortened to fit is recorded whole.
  testWidgets('UIFLOW-R17-02: the Settle up notes prompt says a note the '
      'Ledger refuses is too long, and one shortened to fit is recorded', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _openSettle(tester, w);
    final note = List.filled(400, _family).join();
    await qaTap(tester, find.text(S.notes));
    await tester.enterText(_promptField, note);
    await tester.pump();
    // Nothing of the note is cut inside an emoji.
    expect(_text(tester, _promptField), note);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(S.errTooLong),
      ),
      findsOneWidget,
    );
    expect(find.text('1100/1000'), findsOneWidget);
    final save = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(FilledButton),
    );
    expect(tester.widget<FilledButton>(save).onPressed, isNull);
    // 363 family emoji are 3993 code units: within the Ledger's 4000.
    final fits = List.filled(363, _family).join();
    await tester.enterText(_promptField, fits);
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(S.errTooLong),
      ),
      findsNothing,
    );
    expect(find.text('999/1000'), findsOneWidget);
    await qaTap(tester, _promptSave);
    expect(find.byType(AlertDialog), findsNothing);
    await _record(tester);
    final payments = w.group(gid).liveExpenses.where((e) => e.isPayment);
    expect(payments, hasLength(1));
    expect(payments.single.notes, fits);
    expect(find.text(S.errTooLong), findsNothing);
    await w.shutdown(tester);
  });

  // ------------------------------------------------- UIFLOW-R15-03 --

  testWidgets('R17 probe UIFLOW-R15-03: a note cleared, then a new one '
      'added, then cleared again leaves no note and Back on the empty '
      'prompt keeps the note', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _openSettle(tester, w);
    await qaTap(tester, find.text(S.notes));
    await promptAndSave(tester, 'First');
    await qaTap(tester, find.text('First'));
    await promptAndSave(tester, '');
    expect(find.text(S.optional), findsOneWidget);
    await qaTap(tester, find.text(S.notes));
    await promptAndSave(tester, 'Second\nline');
    expect(find.text('First'), findsNothing);
    // Cleared, then dismissed with Cancel: the note stays.
    await qaTap(tester, find.text('Second\nline'));
    await tester.enterText(_promptField, '');
    await tester.pump();
    await qaTap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(S.cancel),
      ),
    );
    expect(find.text('Second\nline'), findsOneWidget);
    await qaTap(tester, find.text('Second\nline'));
    await promptAndSave(tester, '\n\n  ');
    expect(find.text(S.optional), findsOneWidget);
    await _record(tester);
    final pay = w.group(gid).liveExpenses.singleWhere((e) => e.isPayment);
    expect(pay.notes, isEmpty);
    await w.shutdown(tester);
  });

  testWidgets('R17 probe UIFLOW-R15-03: the member rename prompt still keeps '
      'Save off while empty', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.members(gid));
    await qaSettle(tester);
    await qaTap(tester, find.text('Priya'));
    final rename = find.text(S.rename);
    if (rename.evaluate().isNotEmpty) await qaTap(tester, rename);
    expect(find.byType(AlertDialog), findsOneWidget);
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
