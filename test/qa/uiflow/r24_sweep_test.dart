// QA UIFLOW round 24: final regression sweep on the real Ledger. Probes of
// the charter's riskiest paths across the fixes of rounds 15 to 23: the
// expense description refused by the Ledger once cleaned, payment delete
// and undo, and an amount-only edit of an equal split.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'real_harness.dart';

bool _saveEnabled(WidgetTester tester) =>
    filledButton(tester, S.saveExpense).onPressed != null;

/// The error text the description field shows, or null.
String? _descriptionError(WidgetTester tester) => tester
    .widget<LabeledTextField>(
      find.byWidgetPredicate(
        (w) => w is LabeledTextField && w.label == S.description,
      ),
    )
    .errorText;

void main() {
  // A description of only characters the Ledger drops (TextClean.clean):
  // a zero-width space, a bidi mark, a word joiner, a lone surrogate. The editor
  // checks the raw text, so Save goes ahead, the Ledger refuses it as
  // empty, and the snack bar says "Check the highlighted fields." while
  // the description field shows no error.
  for (final (label, text) in [
    ('U+200B zero-width space', '\u200B'),
    ('U+200F right-to-left mark', '\u200F'),
    ('U+2060 word joiner', '\u2060'),
    ('U+200E and U+200F bidi marks', '\u200E \u200F'),
    ('a lone surrogate', '\uD83D'),
    // The same class: anything that shows nothing once cleaned.
    ('U+3164 Hangul filler', '\u3164'),
    ('U+2800 braille blank', '\u2800'),
    ('U+00AD soft hyphen and U+FE0F', '\u00AD\uFE0F'),
    ('a tag space and an ideographic space', '\u{E0020}\u3000'),
    ('a line break between bidi isolates', '\u2066\n\u2069'),
  ]) {
    testWidgets(
      'UIFLOW-R24-01 ($label): Add expense with a description that saves '
      'as nothing says to add a description, not "Check the highlighted '
      'fields." with nothing highlighted',
      (tester) async {
        qaPhone(tester);
        final w = await RealWorld.create(name: 'Arjun');
        final gid = await w.seedGroup();
        await pumpReal(tester, w, location: Routes.home);
        w.push(Routes.group(gid));
        await qaSettle(tester);
        await qaTap(tester, find.byType(FloatingActionButton));
        await tester.enterText(find.byType(TextField).at(0), '300');
        await tester.pump();
        await tester.enterText(fieldLabeled(S.description), text);
        await tester.pump();
        await qaTap(tester, find.text(S.saveExpense));

        // Nothing is saved either way.
        expect(w.group(gid).liveExpenses, isEmpty);
        expect(find.text(S.addExpenseTitle), findsOneWidget);
        // The field says what is missing, as it does for an empty one;
        // no snack bar points at highlighted fields that are not there.
        expect(_descriptionError(tester), S.descriptionNeeded);
        expect(snackText(tester), isNot(S.errInvalidInput));
        await w.shutdown(tester);
      },
    );
  }

  testWidgets('UIFLOW-R24-01 premise: an empty description is said under '
      'the field and Save sends nothing', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    await qaTap(tester, find.byType(FloatingActionButton));
    await tester.enterText(find.byType(TextField).at(0), '300');
    await tester.pump();
    expect(_saveEnabled(tester), isTrue);
    await qaTap(tester, find.text(S.saveExpense));
    expect(w.group(gid).liveExpenses, isEmpty);
    expect(_descriptionError(tester), S.descriptionNeeded);
    expect(snackText(tester), isNull);
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R24-01 editing: clearing a description and typing a '
      'zero-width space keeps the description on the Ledger', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final me = w.member(gid, 'Arjun');
    final eid = await w.ledger.addExpense(
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
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.editExpense(eid));
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.description), '\u200B');
    await tester.pump();
    await qaTap(tester, find.text(S.saveExpense));
    expect(w.state.expense(eid)!.description, 'Fuel');
    await w.shutdown(tester);
  });

  testWidgets('R24 probe: delete a payment from its detail, Undo brings it '
      'and the balance back', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final me = w.member(gid, 'Arjun');
    final priya = w.member(gid, 'Priya');
    await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Dinner',
        total: 30000,
        currency: 'INR',
        paidBy: SplitSpec(SplitMethod.exact, {me: 30000}),
        owedBy: SplitSpec(SplitMethod.equal, {
          for (final m in w.group(gid).activeMembers) m.id: 1,
        }),
        category: 'food.restaurants',
        date: DateTime.utc(2026, 11, 5),
      ),
    );
    final pid = await w.ledger.recordPayment(
      PaymentDraft(
        groupId: gid,
        from: priya,
        to: me,
        amount: 10000,
        currency: 'INR',
        method: PaymentMethod.cash,
        date: DateTime.utc(2026, 11, 6),
      ),
    );
    int myNet() => BalanceCalculator.groupNets(w.group(gid))['INR']![me]!;
    expect(myNet(), 10000);
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    w.push(Routes.expense(pid, groupId: gid));
    await qaSettle(tester);
    await qaTap(tester, find.byTooltip(S.moreOptions));
    // A payment's menu says "Delete payment" (UIFLOW-R29-01).
    await qaTap(tester, find.text(S.deletePayment));
    await qaTap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(S.delete),
      ),
    );
    expect(w.state.expense(pid)!.isDeleted, isTrue);
    expect(myNet(), 20000);
    expect(w.location, Routes.group(gid));
    await tester.tap(find.text(S.undo));
    await qaSettle(tester);
    expect(w.state.expense(pid)!.isDeleted, isFalse);
    expect(myNet(), 10000);
    await w.shutdown(tester);
  });

  testWidgets('R24 probe: an amount-only edit of an equal split re-splits '
      'the new amount and keeps the rest', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final me = w.member(gid, 'Arjun');
    final eid = await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Cab to airport',
        total: 30000,
        currency: 'INR',
        paidBy: SplitSpec(SplitMethod.exact, {me: 30000}),
        owedBy: SplitSpec(SplitMethod.equal, {
          for (final m in w.group(gid).activeMembers) m.id: 1,
        }),
        category: 'transport.taxi',
        date: DateTime.utc(2026, 11, 5),
        notes: 'Night fare',
      ),
    );
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.editExpense(eid));
    await qaSettle(tester);
    await tester.enterText(find.byType(TextField).at(0), '450');
    await tester.pump();
    await qaTap(tester, find.text(S.saveExpense));
    final e = w.state.expense(eid)!;
    expect(e.money.total, 45000);
    expect(e.money.owed.values.toSet(), {15000});
    expect(e.money.paid, {me: 45000});
    expect(e.description, 'Cab to airport');
    expect(e.notes, 'Night fare');
    expect(e.category, 'transport.taxi');
    final ops = w.ledger.current.ops;
    final last = ops.reduce((a, b) => a.hlc.compareTo(b.hlc) >= 0 ? a : b);
    expect(last.kind, OpKind.update);
    expect(last.payload.keys, isNot(contains(ExpenseFields.description)));
    await w.shutdown(tester);
  });
}
