// QA UIFLOW round 18: reverification of UIFLOW-R17-01 (an edit form sends
// a field the user never touched when another phone changed it while the
// form was open) and UIFLOW-R17-02 (the Settle up notes prompt takes a note
// the Ledger refuses as too long), with probes of each defect class, and a
// regression sweep around the changed code. Over the real
// Ledger(MemoryOpStore) + KvSettingsRepository.
//
// Tests named "UIFLOW-R18-NN" with `skip:` are failing repros for open
// findings; unskip to verify a fix.
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

import 'real_harness.dart';

const _otherPhone = 'dddddddd-0000-7000-8000-000000000018';

var _counter = 0;

/// One op from another phone, applied as sync would.
Future<void> _remote(
  RealWorld w,
  GroupId gid,
  EntityType type,
  String entityId,
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
      entityType: type,
      entityId: entityId,
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

Future<ExpenseId> _payment(RealWorld w, GroupId gid) => w.ledger.recordPayment(
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

bool _promptSaveOn(WidgetTester tester) =>
    tester
        .widget<FilledButton>(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byType(FilledButton),
          ),
        )
        .onPressed !=
    null;

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

/// A family emoji: one character, 11 UTF-16 code units.
const _family = '\u{1F468}‍\u{1F469}‍\u{1F467}‍\u{1F466}';

void _noRawText() {
  expect(find.textContaining('LedgerException'), findsNothing);
  expect(find.textContaining('longer than'), findsNothing);
  expect(find.textContaining('invalidInput'), findsNothing);
}

void main() {
  // ------------------------------------------------- UIFLOW-R17-01 --

  testWidgets('R18 probe UIFLOW-R17-01: the expense editor, another phone '
      'changes the category, the date and the note at once; saving a new '
      'amount keeps all three and the amount is the one typed', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final id = await _expense(w, gid);
    await _openEditor(tester, w, id);
    await _remote(w, gid, EntityType.expense, id, {
      ExpenseFields.category: 'food.groceries',
      ExpenseFields.date: DateTime.utc(2026, 11, 3).millisecondsSinceEpoch,
      ExpenseFields.notes: 'Priya added this',
    });
    await qaSettle(tester);
    await tester.enterText(find.byType(TextField).at(0), '800');
    await tester.pump();
    await qaTap(tester, _saveExpense);
    final e = w.state.expense(id)!;
    expect(e.money.total, 80000);
    expect(e.money.owed.values.toSet(), {40000});
    expect(e.category, 'food.groceries');
    expect(e.date, DateTime.utc(2026, 11, 3));
    expect(e.notes, 'Priya added this');
    expect(e.description, 'Dinner');
    _noRawText();
    await w.shutdown(tester);
  });

  testWidgets('R18 probe UIFLOW-R17-01: the expense editor saved with '
      'nothing changed after another phone changed the description and the '
      'money undoes neither', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final id = await _expense(w, gid);
    await _openEditor(tester, w, id);
    await _remote(w, gid, EntityType.expense, id, {
      ExpenseFields.description: 'Dinner at Thalassa',
      ExpenseFields.money: SplitCalculator.buildMoneyBlock(
        total: 90000,
        currency: 'INR',
        paidBy: SplitSpec.single(w.member(gid, 'Priya'), 90000),
        owedBy: SplitSpec(SplitMethod.equal, {
          w.member(gid, 'Arjun'): 1,
          w.member(gid, 'Priya'): 1,
          w.member(gid, 'Rahul'): 1,
        }),
      ).toJson(),
    });
    await qaSettle(tester);
    await qaTap(tester, _saveExpense);
    final e = w.state.expense(id)!;
    expect(e.description, 'Dinner at Thalassa');
    expect(e.money.total, 90000);
    expect(e.money.paid, {w.member(gid, 'Priya'): 90000});
    expect(e.money.owed, hasLength(3));
    expect(e.notes, 'first note');
    _noRawText();
    await w.shutdown(tester);
  });

  testWidgets('R18 probe UIFLOW-R17-01: Edit payment, another phone changes '
      'the date; saving a new amount keeps the date and records the amount '
      'typed', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final pid = await _payment(w, gid);
    await _openEditor(tester, w, pid);
    await _remote(w, gid, EntityType.expense, pid, {
      ExpenseFields.date: DateTime.utc(2026, 11, 2).millisecondsSinceEpoch,
    });
    await qaSettle(tester);
    await tester.enterText(find.byType(TextField).at(0), '300');
    await tester.pump();
    await qaTap(tester, find.text(S.saveChanges));
    final e = w.state.expense(pid)!;
    expect(e.money.total, 30000);
    expect(e.date, DateTime.utc(2026, 11, 2));
    expect(e.paymentMethod, PaymentMethod.upi);
    expect(e.notes, 'first note');
    _noRawText();
    await w.shutdown(tester);
  });

  testWidgets('R18 probe UIFLOW-R17-01: Edit group, another phone renames '
      'the group and changes its currency; picking an emoji keeps both', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    w.push(Routes.editGroup(gid));
    await qaSettle(tester);
    final before = w.group(gid).group!.emoji;
    await _remote(w, gid, EntityType.group, gid, {
      GroupFields.name: 'Goa 2026',
      GroupFields.currency: 'EUR',
    });
    await qaSettle(tester);
    await qaTap(tester, find.text(S.emoji));
    // The first emoji of the picker that is not the one the group has.
    final options = find.descendant(
      of: find.byType(Dialog).hitTestable().evaluate().isNotEmpty
          ? find.byType(Dialog)
          : find.byType(BottomSheet),
      matching: find.byType(Text),
    );
    String? picked;
    for (final el in options.evaluate()) {
      final t = (el.widget as Text).data;
      if (t == null || t == S.emoji || t == S.noEmoji || t == before) continue;
      if (t.runes.length > 3 || t.codeUnitAt(0) < 0x2000) continue;
      picked = t;
      break;
    }
    expect(picked, isNotNull);
    await qaTap(tester, find.text(picked!).last);
    await qaTap(tester, find.text(S.saveChanges));
    final g = w.group(gid).group!;
    expect(g.emoji, picked);
    expect(g.name, 'Goa 2026');
    expect(g.currency, 'EUR');
    await w.shutdown(tester);
  });

  testWidgets('R18 probe UIFLOW-R17-01: Members, a rename the user typed '
      'wins over one another phone made while the prompt was open', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final rahul = w.member(gid, 'Rahul');
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.members(gid));
    await qaSettle(tester);
    await qaTap(tester, find.text('Rahul'));
    final rename = find.text(S.rename);
    if (rename.evaluate().isNotEmpty) await qaTap(tester, rename.first);
    expect(_promptField, findsOneWidget);
    await _remote(w, gid, EntityType.member, rahul, {
      MemberFields.displayName: 'Rahul K',
    });
    await tester.pump();
    await tester.enterText(_promptField, 'Rahul Sharma');
    await tester.pump();
    await qaTap(tester, _promptSave);
    expect(w.group(gid).members[rahul]!.displayName, 'Rahul Sharma');
    await w.shutdown(tester);
  });

  // ------------------------------------------------- UIFLOW-R17-02 --

  // Combining marks: "e" with three marks is one character of four code
  // units, the most the Ledger lets one character take.
  testWidgets('R18 probe UIFLOW-R17-02: Settle up, a note of 1000 '
      'characters of four code units each is taken and recorded whole; one '
      'more mark makes it too long and Save goes off', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _openSettle(tester, w);
    const ch = 'e\u0301\u0302\u0303'; // 1 character, 4 code units
    final atCap = List.filled(1000, ch).join(); // 4000 code units
    await qaTap(tester, find.text(S.notes));
    await tester.enterText(_promptField, '$atCap\u0304');
    await tester.pump();
    expect(_promptTooLong, findsOneWidget);
    expect(_promptSaveOn(tester), isFalse);
    expect(find.text('1001/1000'), findsOneWidget);
    await tester.enterText(_promptField, atCap);
    await tester.pump();
    expect(_promptTooLong, findsNothing);
    expect(_promptSaveOn(tester), isTrue);
    expect(find.text('1000/1000'), findsOneWidget);
    await qaTap(tester, _promptSave);
    expect(find.byType(AlertDialog), findsNothing);
    await _record(tester);
    final payments = w.group(gid).liveExpenses.where((e) => e.isPayment);
    expect(payments, hasLength(1));
    expect(payments.single.notes, atCap);
    _noRawText();
    await w.shutdown(tester);
  });

  testWidgets('R18 probe UIFLOW-R17-02: Settle up, one character of many '
      'code units at the end of 999 letters is measured by its code units '
      'too', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _openSettle(tester, w);
    final note = 'a' * 999 + 'e${'\u0301' * 3001}'; // 4001 code units
    await qaTap(tester, find.text(S.notes));
    await tester.enterText(_promptField, note);
    await tester.pump();
    expect(_promptTooLong, findsOneWidget);
    expect(_promptSaveOn(tester), isFalse);
    await tester.enterText(_promptField, 'a' * 999 + 'e${'\u0301' * 3000}');
    await tester.pump();
    expect(_promptTooLong, findsNothing);
    await qaTap(tester, _promptSave);
    await _record(tester);
    expect(w.group(gid).liveExpenses.where((e) => e.isPayment), hasLength(1));
    await w.shutdown(tester);
  });

  testWidgets('R18 probe UIFLOW-R17-02: Settle up, line breaks and spaces '
      'around a note at the cap are not counted (the Ledger trims them)', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _openSettle(tester, w);
    final body = List.filled(250, _family).join(); // 2750 code units
    await qaTap(tester, find.text(S.notes));
    await tester.enterText(_promptField, '\n  $body  \n');
    await tester.pump();
    expect(_promptTooLong, findsNothing);
    expect(_promptSaveOn(tester), isTrue);
    await qaTap(tester, _promptSave);
    await _record(tester);
    final payments = w.group(gid).liveExpenses.where((e) => e.isPayment);
    expect(payments.single.notes, body);
    await w.shutdown(tester);
  });

  testWidgets('R18 probe UIFLOW-R17-02: the expense editor, a description '
      'of 120 family emoji says too long under the field and Save records '
      'nothing, with no raw text', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final id = await _expense(w, gid);
    await _openEditor(tester, w, id);
    await tester.enterText(
      fieldLabeled(S.description),
      List.filled(120, _family).join(),
    );
    await tester.pump();
    expect(find.text(S.errTooLong), findsWidgets);
    await qaTap(tester, _saveExpense);
    expect(w.state.expense(id)!.description, 'Dinner');
    _noRawText();
    await w.shutdown(tester);
  });

  testWidgets('R18 probe UIFLOW-R17-02: Edit payment, a note of 400 family '
      'emoji says too long and Save keeps the old note, with no raw text', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final pid = await _payment(w, gid);
    await _openEditor(tester, w, pid);
    await qaReveal(tester, fieldLabeled(S.notes));
    await tester.enterText(
      fieldLabeled(S.notes),
      List.filled(400, _family).join(),
    );
    await tester.pump();
    expect(find.text(S.errTooLong), findsWidgets);
    await qaTap(tester, find.text(KitStrings.cash));
    await qaTap(tester, find.text(S.saveChanges));
    expect(w.state.expense(pid)!.notes, 'first note');
    _noRawText();
    await w.shutdown(tester);
  });

  // Hidden characters (a zero-width space, which TextClean drops and the
  // Ledger never stores or counts) take room in the field's cap: the
  // TextCapFormatter counts the raw text, the counter and the Ledger the
  // cleaned one.
  testWidgets(
    'UIFLOW-R18-01: a note pasted with zero-width spaces is cut at 1000 raw '
    'characters, and the field refuses typing while its counter shows room',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await _openSettle(tester, w);
      // 600 letters, each followed by a zero-width space: 1200 characters
      // as typed, 600 as stored.
      final pasted = List.filled(600, 'a\u200B').join();
      await qaTap(tester, find.text(S.notes));
      await tester.enterText(_promptField, pasted);
      await tester.pump();
      String held() => tester.widget<TextField>(_promptField).controller!.text;
      // Today: 500 letters and 500 zero-width spaces are kept, the counter
      // shows 500/1000.
      expect(
        held().replaceAll('\u200B', ''),
        'a' * 600,
        reason: 'the paste is cut although the Ledger would store all of it',
      );
      final before = held();
      tester.testTextInput.updateEditingValue(
        TextEditingValue(
          text: '${before}b',
          selection: TextSelection.collapsed(offset: before.length + 1),
        ),
      );
      await tester.pump();
      expect(
        held(),
        '${before}b',
        reason: 'the counter shows room but the field refuses the letter',
      );
      await qaTap(tester, _promptSave);
      await _record(tester);
      final payments = w.group(gid).liveExpenses.where((e) => e.isPayment);
      expect(payments.single.notes, '${'a' * 600}b');
      await w.shutdown(tester);
    },
    skip: true, // QA UIFLOW-R18-01: hidden characters take room in the notes and description caps, so a paste is cut and typing refused while the counter shows room
  );

  testWidgets('R18 probe (premise of UIFLOW-R18-01): the paste is cut to '
      '1000 raw characters, the counter shows 500/1000 and a letter typed '
      'at the end is refused', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await _openSettle(tester, w);
    final pasted = List.filled(600, 'a\u200B').join();
    await qaTap(tester, find.text(S.notes));
    await tester.enterText(_promptField, pasted);
    await tester.pump();
    String held() => tester.widget<TextField>(_promptField).controller!.text;
    expect(held().length, 1000);
    expect(held().replaceAll('\u200B', ''), 'a' * 500);
    expect(find.text('500/1000'), findsOneWidget);
    expect(_promptTooLong, findsNothing);
    final before = held();
    tester.testTextInput.updateEditingValue(
      TextEditingValue(
        text: '${before}b',
        selection: TextSelection.collapsed(offset: before.length + 1),
      ),
    );
    await tester.pump();
    expect(held(), before);
    expect(find.text('500/1000'), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('R18 probe (UIFLOW-R18-01 in the editor): the expense notes '
      'field cuts the same paste to 500 stored letters', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final id = await _expense(w, gid);
    await _openEditor(tester, w, id);
    await qaReveal(tester, fieldLabeled(S.notes));
    await tester.enterText(
      fieldLabeled(S.notes),
      List.filled(600, 'a\u200B').join(),
    );
    await tester.pump();
    final held = tester
        .widget<TextField>(fieldLabeled(S.notes))
        .controller!
        .text;
    expect(held.replaceAll('\u200B', ''), 'a' * 500);
    await qaTap(tester, _saveExpense);
    expect(w.state.expense(id)!.notes, 'a' * 500);
    await w.shutdown(tester);
  });
}
