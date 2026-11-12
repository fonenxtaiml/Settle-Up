// QA UIFLOW round 26: reverification of UIFLOW-R24-01 (a description that
// saves as nothing) over its whole class on the real Ledger, plus a
// regression sweep of the code the fix touched: the formatter every text
// field now runs first (lone surrogates dropped), the expense editor's
// blank test on add and edit, and peer expenses whose description is
// blank. Tests named "UIFLOW-R26-NN" with `skip:` are failing repros for
// open findings; unskip to verify a fix.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/ui/format/well_formed_formatter.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'real_harness.dart';

String? _descriptionError(WidgetTester tester) => tester
    .widget<LabeledTextField>(
      find.byWidgetPredicate(
        (w) => w is LabeledTextField && w.label == S.description,
      ),
    )
    .errorText;

String _descriptionText(WidgetTester tester) =>
    tester.widget<TextField>(fieldLabeled(S.description)).controller!.text;

Future<(RealWorld, GroupId)> _openAdd(WidgetTester tester) async {
  qaPhone(tester);
  final w = await RealWorld.create(name: 'Arjun');
  final gid = await w.seedGroup();
  await pumpReal(tester, w, location: Routes.home);
  w.push(Routes.group(gid));
  await qaSettle(tester);
  await qaTap(tester, find.byType(FloatingActionButton));
  await tester.enterText(find.byType(TextField).at(0), '300');
  await tester.pump();
  return (w, gid);
}

void main() {
  // The class, wider than the reported characters: blank-on-screen marks
  // from the supplementary planes, mixes with every space kind, a long run
  // of hidden characters (they take no room, so the cap lets them in), and
  // a paste of half an emoji next to spaces.
  for (final (label, text) in [
    ('U+115F and U+1160 Hangul fillers', 'ᅟᅠ'),
    ('U+FFA0 halfwidth Hangul filler', 'ﾠ'),
    ('U+180E Mongolian vowel separator', '᠎'),
    ('U+034F combining grapheme joiner', '͏'),
    ('U+E0100 variation selector supplement', '\u{E0100}'),
    ('U+1D173 musical format control', '\u{1D173}'),
    ('U+1BCA0 shorthand format control', '\u{1BCA0}'),
    ('U+FDD0 noncharacter', '﷐'),
    ('ZWJ and ZWNJ only', '‍‌'),
    ('every space kind', '     　 \t'),
    ('300 zero-width spaces', '​' * 300),
    ('half an emoji between spaces', '  \uD83D  '),
    ('the low half of an emoji', '\uDE00'),
  ]) {
    testWidgets('R26 probe ($label): a description that shows nothing is '
        '"Add a short description" under the field, never the generic snack', (
      tester,
    ) async {
      final (w, gid) = await _openAdd(tester);
      await tester.enterText(fieldLabeled(S.description), text);
      await tester.pump();
      await qaTap(tester, find.text(S.saveExpense));
      expect(w.group(gid).liveExpenses, isEmpty);
      expect(find.text(S.addExpenseTitle), findsOneWidget);
      expect(_descriptionError(tester), S.descriptionNeeded);
      expect(snackText(tester), isNull);
      await w.shutdown(tester);
    });
  }

  // No false refusals: text that does show something is saved, cleaned the
  // Ledger's way.
  for (final (label, text, saved) in [
    ('hidden around a word', '​‏Cab⁠', 'Cab'),
    ('a lone surrogate after a word', 'Taxi\uD83D', 'Taxi'),
    ('a whole emoji', '\u{1F695}', '\u{1F695}'),
    ('a Hangul filler before a letter', 'ㅤa', 'ㅤa'),
    ('one digit', '7', '7'),
    ('a lone combining accent', '́', '́'),
  ]) {
    testWidgets('R26 probe ($label): a description that shows something '
        'saves', (tester) async {
      final (w, gid) = await _openAdd(tester);
      await tester.enterText(fieldLabeled(S.description), text);
      await tester.pump();
      await qaTap(tester, find.text(S.saveExpense));
      expect(snackText(tester), S.expenseAdded);
      expect(w.group(gid).liveExpenses.single.description, saved);
      await w.shutdown(tester);
    });
  }

  testWidgets('R26 probe: the error under a blank description clears once '
      'a word is typed and the expense then saves', (tester) async {
    final (w, gid) = await _openAdd(tester);
    await tester.enterText(fieldLabeled(S.description), '‏ㅤ');
    await tester.pump();
    await qaTap(tester, find.text(S.saveExpense));
    expect(_descriptionError(tester), S.descriptionNeeded);
    await tester.enterText(fieldLabeled(S.description), 'Dinner');
    await tester.pump();
    expect(_descriptionError(tester), isNull);
    await qaTap(tester, find.text(S.saveExpense));
    expect(w.group(gid).liveExpenses.single.description, 'Dinner');
    await w.shutdown(tester);
  });

  testWidgets('R26 probe: editing a peer expense whose description is '
      'blank asks for a description under the field, and saves once one is '
      'typed', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final me = w.member(gid, 'Arjun');
    final mine = await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Fuel',
        total: 30000,
        currency: 'INR',
        paidBy: SplitSpec(SplitMethod.exact, {me: 30000}),
        owedBy: SplitSpec(SplitMethod.equal, {
          for (final m in w.group(gid).activeMembers) m.id: 1,
        }),
        category: 'transport.fuel',
        date: DateTime.utc(2026, 11, 5),
      ),
    );
    final create = (await w.store.loadAll()).firstWhere(
      (o) => o.entityId == mine && o.kind == OpKind.create,
    );
    const peer = 'eeee0000-0000-7000-8000-000000000002';
    const id = 'eeee0000-0000-7000-8000-0000000000e9';
    final added = await w.ledger.applyRemote(gid, [
      Operation(
        id: 'eeee0000-0000-7000-8000-000000000291',
        groupId: gid,
        deviceId: peer,
        counter: 1,
        hlc: Hlc(create.hlc.millis + 60000, 0, peer),
        entityType: EntityType.expense,
        entityId: id,
        kind: OpKind.create,
        payload: {...create.payload, ExpenseFields.description: 'ㅤ⠀'},
      ),
    ]);
    expect(added, hasLength(1));
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.editExpense(id));
    await qaSettle(tester);
    expect(find.text(S.editExpenseTitle), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), '450');
    await tester.pump();
    await qaTap(tester, find.text(S.saveExpense));
    expect(w.state.expense(id)!.money.total, 30000);
    expect(_descriptionError(tester), S.descriptionNeeded);
    expect(snackText(tester), isNull);
    await tester.enterText(fieldLabeled(S.description), 'Snacks');
    await tester.pump();
    await qaTap(tester, find.text(S.saveExpense));
    expect(w.state.expense(id)!.description, 'Snacks');
    expect(w.state.expense(id)!.money.total, 45000);
    await w.shutdown(tester);
  });

  testWidgets('R26 probe: a lone surrogate typed into the description '
      'never reaches the field, and the caret stays at the end', (
    tester,
  ) async {
    final (w, _) = await _openAdd(tester);
    await tester.enterText(fieldLabeled(S.description), 'Tea\uD83D');
    await tester.pump();
    expect(_descriptionText(tester), 'Tea');
    final sel = tester
        .widget<TextField>(fieldLabeled(S.description))
        .controller!
        .selection;
    expect(sel.isValid, isTrue);
    expect(sel.baseOffset, lessThanOrEqualTo(3));
    expect(sel.extentOffset, lessThanOrEqualTo(3));
    await w.shutdown(tester);
  });

  test('R26 probe: WellFormedTextFormatter keeps offsets inside the cleaned '
      'text for every caret and composing position', () {
    const f = WellFormedTextFormatter();
    const texts = [
      '\uD83D',
      'a\uD83Db',
      '\uDE00😀\uD83D',
      'x\u{1F600}\uD83Dy\uDE00z',
    ];
    for (final t in texts) {
      for (var a = 0; a <= t.length; a++) {
        for (var b = a; b <= t.length; b++) {
          final out = f.formatEditUpdate(
            TextEditingValue.empty,
            TextEditingValue(
              text: t,
              selection: TextSelection(baseOffset: a, extentOffset: b),
              composing: TextRange(start: a, end: b),
            ),
          );
          final n = out.text.length;
          final s = out.selection;
          expect(s.baseOffset, inInclusiveRange(0, n), reason: '$t $a $b');
          expect(s.extentOffset, inInclusiveRange(0, n), reason: '$t $a $b');
          final c = out.composing;
          if (c.isValid) {
            expect(c.start, inInclusiveRange(0, n));
            expect(c.end, inInclusiveRange(c.start, n));
          }
          // The kept text is well formed: no half of a pair is left.
          expect(
            out.text.runes.every((r) => r < 0xD800 || r > 0xDFFF),
            isTrue,
            reason: t,
          );
        }
      }
    }
  });

  testWidgets('R26 probe: Search drops a lone surrogate and still finds the '
      'expense by its description', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final me = w.member(gid, 'Arjun');
    await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Ferry tickets',
        total: 30000,
        currency: 'INR',
        paidBy: SplitSpec(SplitMethod.exact, {me: 30000}),
        owedBy: SplitSpec(SplitMethod.equal, {
          for (final m in w.group(gid).activeMembers) m.id: 1,
        }),
        category: 'transport.general',
        date: DateTime.utc(2026, 11, 5),
      ),
    );
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.search);
    await qaSettle(tester);
    await tester.enterText(find.byType(TextField).first, 'ferry\uD83D');
    await qaSettle(tester);
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      'ferry',
    );
    expect(find.text('Ferry tickets'), findsWidgets);
    await w.shutdown(tester);
  });

  test('R26 probe: isBlankDescription agrees with the Ledger for every BMP '
      'code point alone and between spaces', () {
    // Pure check against the data layer's own rule on the same input the
    // Ledger cleans (multiline, as descriptions keep line breaks).
    var blanks = 0;
    for (var r = 0; r <= 0xFFFF; r++) {
      final s = String.fromCharCode(r);
      final alone = isBlankDescription(s);
      // Ledger._line: TextRules.clean(multiline) then TextRules.isBlank.
      final ledger = TextRules.isBlank(TextRules.clean(s, multiline: true));
      expect(alone, ledger, reason: r.toRadixString(16));
      expect(isBlankDescription(' $s\n'), alone, reason: r.toRadixString(16));
      if (alone) blanks++;
    }
    expect(blanks, greaterThan(100));
  });
}
