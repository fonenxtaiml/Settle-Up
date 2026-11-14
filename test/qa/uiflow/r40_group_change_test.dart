// Regression tests for QA UIFLOW-R39-01 and UIFLOW-R39-02: moving Add
// expense to another group (the chip) or another currency (the symbol)
// starts the split from the new group's people only, and every amount the
// form holds keeps its face value in the new currency, or is cleared when
// that currency cannot hold it. Never rescaled.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/app_chrome.dart';

import 'real_harness.dart';

Future<void> _pickGroupNamed(WidgetTester tester, String name) async {
  await qaTap(tester, find.byType(DropdownChip));
  expect(find.text(S.pickGroup), findsOneWidget);
  await qaTap(tester, find.text(name).last);
}

void main() {
  group('UIFLOW-R39-01: a new group starts a new split', () {
    testWidgets('Goa -> Flat -> Goa: each time only that group\'s people, '
        'and Save adds the expense to the group picked last', (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final goa = await w.seedGroup(
        name: 'Goa',
        people: const ['Priya', 'Rahul'],
      );
      final flat = await w.seedGroup(name: 'Flat', people: const ['Meera']);
      await pumpReal(tester, w, location: Routes.home);
      w.push(Routes.newExpense(groupId: goa));
      await qaSettle(tester);
      await tester.enterText(find.byType(TextField).at(0), '300');
      await tester.pump();
      await tester.enterText(fieldLabeled(S.description), 'Rent');
      await tester.pump();
      expect(find.text(S.eachSummary('₹100', 3)), findsOneWidget);

      await _pickGroupNamed(tester, 'Flat');
      expect(find.text(S.someone), findsNothing);
      expect(find.text(S.eachSummary('₹150', 2)), findsOneWidget);
      await _pickGroupNamed(tester, 'Goa');
      expect(find.text(S.someone), findsNothing);
      expect(find.text('Meera'), findsNothing);
      expect(find.text(S.eachSummary('₹100', 3)), findsOneWidget);
      await _pickGroupNamed(tester, 'Flat');
      expect(find.text(S.eachSummary('₹150', 2)), findsOneWidget);

      await qaTap(tester, find.text(S.saveExpense));
      expect(snackText(tester), S.expenseAdded);
      expect(w.group(goa).liveExpenses, isEmpty);
      final e = w.group(flat).liveExpenses.single;
      expect(e.money.owed.keys.toSet(), {
        for (final m in w.group(flat).activeMembers) m.id,
      });
      expect(e.money.owed.values.toSet(), {15000});
      expect(e.money.paid, {w.member(flat, 'Arjun'): 30000});
      await w.shutdown(tester);
    });

    testWidgets('someone unticked in the old group: the new group starts '
        'with everyone ticked, and Save adds it there', (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final goa = await w.seedGroup(
        name: 'Goa',
        people: const ['Priya', 'Rahul'],
      );
      final flat = await w.seedGroup(
        name: 'Flat',
        people: const ['Meera', 'Kabir'],
      );
      await pumpReal(tester, w, location: Routes.home);
      w.push(Routes.newExpense(groupId: goa));
      await qaSettle(tester);
      await tester.enterText(find.byType(TextField).at(0), '300');
      await tester.pump();
      await tester.enterText(fieldLabeled(S.description), 'Rent');
      await tester.pump();
      await qaTap(tester, find.text('Rahul').last);
      expect(find.text(S.eachSummary('₹150', 2)), findsOneWidget);

      await _pickGroupNamed(tester, 'Flat');
      expect(find.text(S.someone), findsNothing);
      expect(find.text('Rahul'), findsNothing);
      expect(find.text(S.eachSummary('₹100', 3)), findsOneWidget);
      await qaTap(tester, find.text(S.saveExpense));
      expect(snackText(tester), S.expenseAdded);
      final e = w.group(flat).liveExpenses.single;
      expect(e.money.owed.length, 3);
      expect(e.money.owed.values.toSet(), {10000});
      await w.shutdown(tester);
    });

    testWidgets('multiple payers in the old group: the new group is paid '
        'by you alone, and Save adds it there', (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final goa = await w.seedGroup(name: 'Goa', people: const ['Priya']);
      final flat = await w.seedGroup(name: 'Flat', people: const ['Meera']);
      await pumpReal(tester, w, location: Routes.home);
      w.push(Routes.newExpense(groupId: goa));
      await qaSettle(tester);
      await tester.enterText(find.byType(TextField).at(0), '300');
      await tester.pump();
      await tester.enterText(fieldLabeled(S.description), 'Rent');
      await tester.pump();
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
      expect(find.text(S.peoplePaid(2)), findsOneWidget);

      await _pickGroupNamed(tester, 'Flat');
      expect(find.text(S.someone), findsNothing);
      expect(find.text('Priya'), findsNothing);
      await qaTap(tester, find.text(S.saveExpense));
      expect(snackText(tester), S.expenseAdded);
      final e = w.group(flat).liveExpenses.single;
      expect(e.money.paid, {w.member(flat, 'Arjun'): 30000});
      expect(e.money.owed.values.toSet(), {15000});
      await w.shutdown(tester);
    });
  });
}
