// QA UIFLOW: add expense with every split method through the editor, then
// group balances, settle up and the Home hero, on the real Ledger.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

import 'real_harness.dart';

/// The per-member input on Add expense, found by its spoken label.
Finder splitInput(String spokenLabel) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.semanticCounterText == spokenLabel,
);

Future<void> typeAmountAndDescription(
  WidgetTester tester,
  String amount,
  String description,
) async {
  await tester.enterText(find.byType(TextField).at(0), amount);
  await tester.pump();
  await tester.enterText(fieldLabeled(S.description), description);
  await tester.pump();
}

bool saveEnabled(WidgetTester tester) =>
    filledButton(tester, S.saveExpense).onPressed != null;

/// "₹50 left to split" / "₹50 too much" as rendered.
String summaryRight(WidgetTester tester) {
  final rich = find.byWidgetPredicate(
    (w) =>
        w is RichText &&
        (w.text.toPlainText().endsWith(' left to split') ||
            w.text.toPlainText().endsWith(' too much')),
  );
  return tester.widget<RichText>(rich.first).text.toPlainText();
}

Future<GroupId> openAddExpense(WidgetTester tester, RealWorld w) async {
  final gid = await w.seedGroup();
  await pumpReal(tester, w, location: Routes.home);
  w.push(Routes.group(gid));
  await qaSettle(tester);
  await qaTap(tester, find.byType(FloatingActionButton));
  expect(find.text(S.addExpenseTitle), findsOneWidget);
  return gid;
}

void main() {
  testWidgets('equal split: 300 between three, balances, settle up and the '
      'Home hero follow', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await openAddExpense(tester, w);

    // Save is disabled until an amount exists.
    expect(saveEnabled(tester), isFalse);
    await typeAmountAndDescription(tester, '300', 'Dinner at Thalassa');
    expect(saveEnabled(tester), isTrue);
    expect(find.text(S.eachSummary('₹100', 3)), findsOneWidget);
    await qaTap(tester, find.text(S.saveExpense));

    final e = w.group(gid).liveExpenses.single;
    expect(e.money.total, 30000);
    expect(e.money.owedBy.method, SplitMethod.equal);
    expect(e.money.owed.values.toSet(), {10000});
    expect(w.location, Routes.group(gid));
    expect(snackText(tester), S.expenseAdded);

    // Group: I paid 300, my share 100: Priya and Rahul each owe me 100.
    final nets = BalanceCalculator.groupNets(w.group(gid))['INR']!;
    final me = w.member(gid, 'Arjun');
    expect(nets[me], 20000);
    expect(find.text('Dinner at Thalassa'), findsOneWidget);

    // Settle: Priya pays me 100 via the suggested payment row.
    final priya = w.member(gid, 'Priya');
    w.push(Routes.settle(groupId: gid, from: priya, to: me));
    await qaSettle(tester);
    expect(find.text(S.paysYou('Priya')), findsWidgets);
    await qaTap(tester, find.text(S.recordPayment('₹100')));
    // The bubble animation closes the screen.
    await tester.pump(const Duration(seconds: 2));
    await qaSettle(tester);
    expect(w.location, Routes.group(gid));
    expect(snackText(tester), S.paymentRecorded);
    final after = BalanceCalculator.groupNets(w.group(gid))['INR']!;
    expect(after[me], 10000);
    expect(after[priya] ?? 0, 0);

    // Home hero: owed 100 overall.
    w.go(Routes.home);
    await qaSettle(tester);
    expect(find.text(KitStrings.heroOwed), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('exact split: prefilled evenly, live remainder, Save disabled '
      'while unbalanced', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await openAddExpense(tester, w);
    await typeAmountAndDescription(tester, '300', 'Groceries');
    await qaTap(tester, find.text(KitStrings.splitExact));

    expect(
      tester.widget<TextField>(splitInput(S.amountOf('Priya'))).controller!
          .text,
      '100',
    );
    expect(saveEnabled(tester), isTrue);

    await tester.enterText(splitInput(S.amountOf('Priya')), '150');
    await tester.pump();
    expect(summaryRight(tester), '₹50 too much');
    expect(saveEnabled(tester), isFalse);

    await tester.enterText(splitInput(S.amountOf('Rahul')), '20');
    await tester.pump();
    expect(summaryRight(tester), '₹30 left to split');
    expect(saveEnabled(tester), isFalse);

    await tester.enterText(splitInput(S.amountOf('Rahul')), '50');
    await tester.pump();
    expect(summaryRight(tester), '₹0 left to split');
    expect(saveEnabled(tester), isTrue);
    await qaTap(tester, find.text(S.saveExpense));

    final e = w.group(gid).liveExpenses.single;
    expect(e.money.owedBy.method, SplitMethod.exact);
    expect(e.money.owed[w.member(gid, 'Priya')], 15000);
    expect(e.money.owed[w.member(gid, 'Rahul')], 5000);
    expect(e.money.owed[w.member(gid, 'Arjun')], 10000);
    await w.shutdown(tester);
  });

  testWidgets('percent split: 50/25/25 and an unbalanced 50/25/20', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await openAddExpense(tester, w);
    await typeAmountAndDescription(tester, '400', 'Cab');
    await qaTap(tester, find.text(KitStrings.splitPercent));
    // 33.34 / 33.33 / 33.33 prefilled.
    expect(saveEnabled(tester), isTrue);
    await tester.enterText(splitInput(S.percentOf('You')), '50');
    await tester.enterText(splitInput(S.percentOf('Priya')), '25');
    await tester.enterText(splitInput(S.percentOf('Rahul')), '20');
    await tester.pump();
    expect(saveEnabled(tester), isFalse);
    expect(summaryRight(tester), '₹20 left to split');
    await tester.enterText(splitInput(S.percentOf('Rahul')), '25');
    await tester.pump();
    expect(saveEnabled(tester), isTrue);
    await qaTap(tester, find.text(S.saveExpense));
    final e = w.group(gid).liveExpenses.single;
    expect(e.money.owedBy.method, SplitMethod.percent);
    expect(e.money.owed[w.member(gid, 'Arjun')], 20000);
    expect(e.money.owed[w.member(gid, 'Rahul')], 10000);
    await w.shutdown(tester);
  });

  testWidgets('shares split: 2/1/1 with the stepper', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await openAddExpense(tester, w);
    await typeAmountAndDescription(tester, '400', 'Villa');
    await qaTap(tester, find.text(KitStrings.splitShares));
    await qaTap(tester, find.byTooltip(S.moreShares).first);
    expect(find.text(S.sharesSummary(4, 3)), findsOneWidget);
    await qaTap(tester, find.text(S.saveExpense));
    final e = w.group(gid).liveExpenses.single;
    expect(e.money.owedBy.method, SplitMethod.shares);
    expect(e.money.owed[w.member(gid, 'Arjun')], 20000);
    expect(e.money.owed[w.member(gid, 'Priya')], 10000);
    await w.shutdown(tester);
  });

  testWidgets('adjustment split: +30 for Priya, rest equal', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await openAddExpense(tester, w);
    await typeAmountAndDescription(tester, '330', 'Drinks');
    await qaTap(tester, find.text(KitStrings.splitAdjust));
    await tester.enterText(splitInput(S.adjustmentOf('Priya')), '+30');
    await tester.pump();
    expect(saveEnabled(tester), isTrue);
    await qaTap(tester, find.text(S.saveExpense));
    final e = w.group(gid).liveExpenses.single;
    expect(e.money.owedBy.method, SplitMethod.adjustment);
    expect(e.money.owed[w.member(gid, 'Priya')], 13000);
    expect(e.money.owed[w.member(gid, 'Rahul')], 10000);
    await w.shutdown(tester);
  });

  testWidgets('equal split excluding a member, and description required', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await openAddExpense(tester, w);
    await tester.enterText(find.byType(TextField).at(0), '200');
    await tester.pump();
    // Save with no description: copy shown, nothing written.
    await qaTap(tester, find.text(S.saveExpense));
    expect(find.text(S.descriptionNeeded), findsOneWidget);
    expect(w.group(gid).liveExpenses, isEmpty);

    await tester.enterText(fieldLabeled(S.description), 'Petrol');
    await qaTap(
      tester,
      find.byWidgetPredicate((w) => w is Checkbox).at(2),
    );
    expect(find.text(S.splitHeading('equal', 2, 3)), findsOneWidget);
    await qaTap(tester, find.text(S.saveExpense));
    final e = w.group(gid).liveExpenses.single;
    expect(e.money.owed.length, 2);
    expect(e.money.owed.values.toSet(), {10000});
    await w.shutdown(tester);
  });

  testWidgets('multiple payers: Done only when the amounts add up', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await openAddExpense(tester, w);
    await typeAmountAndDescription(tester, '300', 'Hotel');
    await qaTap(tester, find.text(S.paidBy));
    await qaTap(tester, find.text(S.multiplePeople));
    final sheet = find.byType(BottomSheet);
    final fields = find.descendant(of: sheet, matching: find.byType(TextField));
    FilledButton done() => tester.widget<FilledButton>(
      find.descendant(
        of: sheet,
        matching: find.widgetWithText(FilledButton, S.done),
      ),
    );
    // Prefilled with me paying all of it.
    expect(done().onPressed, isNotNull);
    await tester.enterText(fields.at(0), '100');
    await tester.pump();
    expect(done().onPressed, isNull);
    await tester.enterText(fields.at(1), '200');
    await tester.pump();
    expect(done().onPressed, isNotNull);
    await qaTap(tester, find.widgetWithText(FilledButton, S.done));
    expect(find.text(S.peoplePaid(2)), findsOneWidget);
    await qaTap(tester, find.text(S.saveExpense));
    final e = w.group(gid).liveExpenses.single;
    expect(e.money.paid.length, 2);
    expect(e.money.paid[w.member(gid, 'Arjun')], 10000);
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-04: equal split with nobody ticked reads "₹0 left '
      'to split" while Save is disabled', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await openAddExpense(tester, w);
    await typeAmountAndDescription(tester, '300', 'Dinner');
    for (var i = 0; i < 3; i++) {
      await qaTap(tester, find.byWidgetPredicate((w) => w is Checkbox).at(i));
    }
    expect(saveEnabled(tester), isFalse);
    // Expected: the bar explains why Save is off (nobody in the split), not
    // that nothing is left to split.
    expect(summaryRight(tester), isNot('₹0 left to split'));
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-04b: adjustments larger than the total read "₹0 '
      'left to split" while Save is disabled', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await openAddExpense(tester, w);
    await typeAmountAndDescription(tester, '100', 'Dinner');
    await qaTap(tester, find.text(KitStrings.splitAdjust));
    await tester.enterText(splitInput(S.adjustmentOf('Priya')), '500');
    await tester.pump();
    expect(saveEnabled(tester), isFalse);
    expect(summaryRight(tester), isNot('₹0 left to split'));
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-05: changing the amount after picking multiple '
      'payers disables Save with no explanation', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await openAddExpense(tester, w);
    await typeAmountAndDescription(tester, '300', 'Hotel');
    await qaTap(tester, find.text(S.paidBy));
    await qaTap(tester, find.text(S.multiplePeople));
    final fields = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), '100');
    await tester.enterText(fields.at(1), '200');
    await tester.pump();
    await qaTap(tester, find.widgetWithText(FilledButton, S.done));
    // The bill was 360, not 300.
    await tester.enterText(find.byType(TextField).at(0), '360');
    await tester.pump();
    // Expected: either the payers' mismatch is shown ("Finish the split
    // first" / remainder) or Save stays tappable and explains. Today Save
    // is silently disabled and the bar says the split is fine.
    final explained =
        find.text(S.splitNotDone).evaluate().isNotEmpty || saveEnabled(tester);
    expect(explained, isTrue);
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-20: Android back on a filled-in Add expense '
      'discards it without asking (S.discardAndClose is never used)', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await openAddExpense(tester, w);
    await typeAmountAndDescription(tester, '4200', 'Houseboat');
    await qaTap(tester, find.text(KitStrings.splitExact));
    await tester.binding.handlePopRoute();
    await qaSettle(tester);
    // Expected: a confirmation (Discard and close) and the draft kept.
    expect(find.text(S.discardAndClose), findsOneWidget);
    expect(w.location, isNot(Routes.group(gid)));
    await w.shutdown(tester);
  });
}
