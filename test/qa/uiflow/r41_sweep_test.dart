// QA UIFLOW round 41: reverification of UIFLOW-R39-01 (a new group on Add
// expense starts a new split) and UIFLOW-R39-02 (amounts keep their face
// value when the group or currency changes), probing the defect class on
// the real Ledger: every split method's typed values, the default split
// setting, round trips through currencies with other decimals, amounts
// near the largest the app holds, Home's + into another group and the
// Home hero after Save, and edits that keep removed members listed.
// Tests named "QA UIFLOW-R41-NN" with `skip: true` are failing repros of an
// open finding.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'real_harness.dart';

Finder _splitInput(String spokenLabel) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.semanticCounterText == spokenLabel,
);

String _text(WidgetTester tester, Finder f) =>
    tester.widget<TextField>(f).controller!.text;

String _amountText(WidgetTester tester) =>
    _text(tester, find.byType(TextField).at(0));

Future<void> _pickGroupNamed(WidgetTester tester, String name) async {
  await qaTap(tester, find.byType(DropdownChip));
  expect(find.text(S.pickGroup), findsOneWidget);
  await qaTap(tester, find.text(name).last);
}

Future<void> _pickCurrencyCode(
  WidgetTester tester,
  String from,
  String code,
) async {
  final symbol = find.descendant(
    of: find.byType(AmountField),
    matching: find.text(Currencies.of(from).symbol),
  );
  await qaTap(tester, symbol.first);
  await tester.enterText(
    find.descendant(
      of: find.byType(BottomSheet),
      matching: find.byType(TextField),
    ),
    code,
  );
  await qaSettle(tester);
  await qaTap(tester, find.widgetWithText(ListTile, code).first);
}

Future<void> _type(WidgetTester tester, String amount, String what) async {
  await tester.enterText(find.byType(TextField).at(0), amount);
  await tester.pump();
  await tester.enterText(fieldLabeled(S.description), what);
  await tester.pump();
}

Future<void> _defaultSplit(RealWorld w, SplitMethod m) async {
  final s = w.container.read(appSettingsProvider).value!;
  await w.settings.updateSettings(s.copyWith(defaultSplit: m));
}

void main() {
  testWidgets('R41: Home + opens the first group; the chip moves it to '
      'another, Save adds it there and the Home hero follows', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final flat = await w.seedGroup(name: 'Flat', people: const ['Meera']);
    final goa = await w.seedGroup(
      name: 'Goa',
      people: const ['Priya', 'Rahul'],
    );
    await pumpReal(tester, w, location: Routes.home);
    await qaTap(tester, find.byType(FloatingActionButton));
    expect(find.text(S.addExpenseTitle), findsOneWidget);
    await _type(tester, '300', 'Houseboat');
    final first = find
        .descendant(of: find.byType(DropdownChip), matching: find.byType(Text))
        .evaluate()
        .map((e) => (e.widget as Text).data)
        .first;
    final other = first == 'Goa' ? 'Flat' : 'Goa';
    await _pickGroupNamed(tester, other);
    expect(find.text(S.someone), findsNothing);
    final n = other == 'Goa' ? 3 : 2;
    expect(
      find.text(S.eachSummary(n == 3 ? '₹100' : '₹150', n)),
      findsOneWidget,
    );
    await qaTap(tester, find.text(S.saveExpense));
    expect(snackText(tester), S.expenseAdded);
    final into = other == 'Goa' ? goa : flat;
    final left = other == 'Goa' ? flat : goa;
    expect(w.group(left).liveExpenses, isEmpty);
    final e = w.group(into).liveExpenses.single;
    expect(e.money.owed.length, n);
    w.go(Routes.home);
    await qaSettle(tester);
    expect(find.text(KitStrings.heroOwed), findsOneWidget);
    await w.shutdown(tester);
  });

  for (final method in [
    SplitMethod.exact,
    SplitMethod.percent,
    SplitMethod.shares,
    SplitMethod.adjustment,
  ]) {
    testWidgets('R41: default split ${method.name}: rupee group (3 people) '
        '-> yen group (2 people) by the chip: only the new people, ¥300, '
        'and Save stores 300 JPY split between them', (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final goa = await w.seedGroup(
        name: 'Goa',
        people: const ['Priya', 'Rahul'],
      );
      final tokyo = await w.seedGroup(
        name: 'Tokyo',
        people: const ['Kenji'],
        currency: 'JPY',
      );
      await pumpReal(tester, w, location: Routes.home);
      await _defaultSplit(w, method);
      await qaSettle(tester);
      w.push(Routes.newExpense(groupId: goa));
      await qaSettle(tester);
      await _type(tester, '300', 'Hotel');
      // A value typed for Rahul in Goa's split, where the method has one.
      final rahul = switch (method) {
        SplitMethod.exact => _splitInput(S.amountOf('Rahul')),
        SplitMethod.percent => _splitInput(S.percentOf('Rahul')),
        SplitMethod.adjustment => _splitInput(S.adjustmentOf('Rahul')),
        _ => null,
      };
      if (rahul != null) {
        await qaReveal(tester, rahul);
        await tester.enterText(
          rahul,
          method == SplitMethod.percent ? '50' : '200',
        );
        await tester.pump();
      }
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
      await qaSettle(tester);
      await _pickGroupNamed(tester, 'Tokyo');
      expect(_amountText(tester), '300');
      expect(find.text(S.someone), findsNothing);
      expect(find.text('Rahul'), findsNothing);
      expect(find.text('Priya'), findsNothing);
      if (method == SplitMethod.exact) {
        await qaReveal(tester, _splitInput(S.amountOf('Kenji')));
        expect(_text(tester, _splitInput(S.amountOf('Kenji'))), '150');
      }
      await qaTap(tester, find.text(S.saveExpense));
      expect(snackText(tester), S.expenseAdded);
      expect(w.group(goa).liveExpenses, isEmpty);
      final e = w.group(tokyo).liveExpenses.single;
      expect(e.money.currency, 'JPY');
      expect(e.money.total, 300);
      expect(e.money.owed.keys.toSet(), {
        for (final m in w.group(tokyo).activeMembers) m.id,
      });
      expect(e.money.owed.values.toSet(), {150});
      await w.shutdown(tester);
    });
  }

  testWidgets('R41: exact split ₹150 + ₹150, currency picker to yen: the '
      'typed shares read ¥150 each, and Save stores 300 JPY 150/150', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final goa = await w.seedGroup(name: 'Goa', people: const ['Priya']);
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.newExpense(groupId: goa));
    await qaSettle(tester);
    await _type(tester, '300', 'Hotel');
    await qaTap(tester, find.text(KitStrings.splitExact));
    expect(_text(tester, _splitInput(S.amountOf('Priya'))), '150');
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await qaSettle(tester);
    await _pickCurrencyCode(tester, 'INR', 'JPY');
    expect(_amountText(tester), '300');
    await qaTap(tester, find.text(S.saveExpense));
    final e = w.group(goa).liveExpenses.single;
    expect(e.money.currency, 'JPY');
    expect(e.money.total, 300);
    expect(e.money.owed.values.toSet(), {150});
    await w.shutdown(tester);
  });

  testWidgets('R41: exact split ₹150.50 + ₹149.50, currency picker to yen: '
      'nothing is rounded into yen, Save stores nothing until fixed', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final goa = await w.seedGroup(name: 'Goa', people: const ['Priya']);
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.newExpense(groupId: goa));
    await qaSettle(tester);
    await _type(tester, '300', 'Hotel');
    await qaTap(tester, find.text(KitStrings.splitExact));
    await tester.enterText(_splitInput(S.amountOf('You')), '150.50');
    await tester.pump();
    await tester.enterText(_splitInput(S.amountOf('Priya')), '149.50');
    await tester.pump();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await qaSettle(tester);
    await _pickCurrencyCode(tester, 'INR', 'JPY');
    expect(_amountText(tester), '300');
    await qaTap(tester, find.text(S.saveExpense));
    expect(w.group(goa).liveExpenses, isEmpty);
    // Fixing the shares in yen saves exactly what is shown.
    await tester.enterText(_splitInput(S.amountOf('You')), '151');
    await tester.pump();
    await tester.enterText(_splitInput(S.amountOf('Priya')), '149');
    await tester.pump();
    await qaTap(tester, find.text(S.saveExpense));
    final e = w.group(goa).liveExpenses.single;
    expect(e.money.currency, 'JPY');
    expect(e.money.total, 300);
    expect(e.money.owed.values.toSet(), {151, 149});
    await w.shutdown(tester);
  });

  testWidgets('R41: round trip ₹300.50 -> dinar group -> rupee group keeps '
      '₹300.50, and Save stores 30050 INR', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final goa = await w.seedGroup(name: 'Goa', people: const ['Priya']);
    await w.seedGroup(name: 'Kuwait', people: const ['Priya'], currency: 'KWD');
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.newExpense(groupId: goa));
    await qaSettle(tester);
    await _type(tester, '300.50', 'Hotel');
    await _pickGroupNamed(tester, 'Kuwait');
    expect(
      Money.parseMinor(
        _amountText(tester).replaceAll(',', ''),
        Currencies.of('KWD'),
      ),
      300500,
    );
    await _pickGroupNamed(tester, 'Goa');
    expect(_amountText(tester), '300.50');
    await qaTap(tester, find.text(S.saveExpense));
    final e = w.group(goa).liveExpenses.single;
    expect(e.money.total, 30050);
    expect(e.money.currency, 'INR');
    await w.shutdown(tester);
  });

  testWidgets('R41: the largest rupee amount -> dinar group: the field is '
      'cleared (it would pass the largest amount), Save stores nothing, and '
      'a new amount saves', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final goa = await w.seedGroup(name: 'Goa', people: const ['Priya']);
    final kw = await w.seedGroup(
      name: 'Kuwait',
      people: const ['Priya'],
      currency: 'KWD',
    );
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.newExpense(groupId: goa));
    await qaSettle(tester);
    await _type(tester, '999999999.99', 'Big');
    await _pickGroupNamed(tester, 'Kuwait');
    expect(_amountText(tester), isEmpty);
    await qaTap(tester, find.text(S.saveExpense));
    expect(w.group(kw).liveExpenses, isEmpty);
    expect(w.group(goa).liveExpenses, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.enterText(find.byType(TextField).at(0), '5');
    await tester.pump();
    await qaTap(tester, find.text(S.saveExpense));
    final e = w.group(kw).liveExpenses.single;
    expect(e.money.total, 5000);
    await w.shutdown(tester);
  });

  testWidgets('R41: Add expense from Goa\'s FAB moved to Flat by the chip: '
      'Save adds it to Flat, and Undo on the snack bar removes it from '
      'Flat', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final goa = await w.seedGroup(
      name: 'Goa',
      people: const ['Priya', 'Rahul'],
    );
    final flat = await w.seedGroup(name: 'Flat', people: const ['Meera']);
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(goa));
    await qaSettle(tester);
    await qaTap(tester, find.byType(FloatingActionButton));
    await _type(tester, '300', 'Rent');
    await _pickGroupNamed(tester, 'Flat');
    await qaTap(tester, find.text(S.saveExpense));
    expect(snackText(tester), S.expenseAdded);
    expect(w.group(flat).liveExpenses.single.money.total, 30000);
    expect(w.group(goa).liveExpenses, isEmpty);
    await tester.tap(find.text(S.undo));
    await qaSettle(tester);
    expect(w.group(flat).liveExpenses, isEmpty);
    expect(w.group(goa).liveExpenses, isEmpty);
    await w.shutdown(tester);
  });
}
