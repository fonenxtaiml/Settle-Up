// Regression tests for the Add expense fixes from QA round 1
// (UIFLOW-R1-05, -14, -20, MONEY-R1-08), on the real Ledger.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

import '../../qa/uiflow/expense_flow_test.dart'
    show openAddExpense, typeAmountAndDescription, saveEnabled;
import '../../qa/uiflow/real_harness.dart';

void main() {
  testWidgets('UIFLOW-R1-20: Discard and close leaves; Keep editing stays', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await openAddExpense(tester, w);
    await typeAmountAndDescription(tester, '4200', 'Houseboat');
    await tester.binding.handlePopRoute();
    await qaSettle(tester);
    await qaTap(tester, find.text(S.keepEditing));
    expect(find.text(S.addExpenseTitle), findsOneWidget);
    expect(find.text('Houseboat'), findsOneWidget);
    // The close button asks too.
    await qaTap(tester, find.byTooltip(S.close));
    await qaTap(tester, find.text(S.discardAndClose));
    expect(w.location, Routes.group(gid));
    expect(w.group(gid).liveExpenses, isEmpty);
    await w.shutdown(tester);
  });

  testWidgets('an untouched Add expense closes without asking', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await openAddExpense(tester, w);
    await tester.binding.handlePopRoute();
    await qaSettle(tester);
    expect(find.text(S.discardAndClose), findsNothing);
    expect(w.location, Routes.group(gid));
    await w.shutdown(tester);
  });

  testWidgets('saving does not ask to discard', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await openAddExpense(tester, w);
    await typeAmountAndDescription(tester, '300', 'Dinner');
    await qaTap(tester, find.text(S.saveExpense));
    expect(find.text(S.discardAndClose), findsNothing);
    expect(w.location, Routes.group(gid));
    expect(w.group(gid).liveExpenses, hasLength(1));
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-14: a too-large amount says the maximum', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await openAddExpense(tester, w);
    await tester.enterText(find.byType(TextField).at(0), '12000000');
    await tester.pump();
    expect(find.textContaining('Enter an amount up to'), findsOneWidget);
    // A smaller amount clears the note.
    await tester.enterText(find.byType(TextField).at(0), '1200');
    await tester.pump();
    expect(find.textContaining('Enter an amount up to'), findsNothing);
    await w.shutdown(tester);
  });

  testWidgets('MONEY-R1-08: a shares weight can be typed, up to 1000', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await openAddExpense(tester, w);
    await typeAmountAndDescription(tester, '1210', 'Nights');
    await qaTap(tester, find.text(KitStrings.splitShares));
    await qaTap(tester, find.bySemanticsLabel(S.setSharesOf('You')));
    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(field, '1001');
    await tester.pump();
    final done = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.widgetWithText(FilledButton, S.done),
    );
    expect(tester.widget<FilledButton>(done).onPressed, isNull);
    await tester.enterText(field, '120');
    await tester.pump();
    await qaTap(tester, done);
    expect(saveEnabled(tester), isTrue);
    await qaTap(tester, find.text(S.saveExpense));
    final e = w.group(gid).liveExpenses.single;
    expect(e.money.owedBy.method, SplitMethod.shares);
    expect(e.money.owedBy.values[w.member(gid, 'Arjun')], 120);
    await w.shutdown(tester);
  });
}
