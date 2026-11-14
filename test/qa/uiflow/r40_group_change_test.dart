// Regression tests for QA UIFLOW-R39-01 and UIFLOW-R39-02: moving Add
// expense to another group (the chip) or another currency (the symbol)
// starts the split from the new group's people only, and every amount the
// form holds keeps its face value in the new currency, or is cleared when
// that currency cannot hold it. Never rescaled.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/ui/format/face_value.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'real_harness.dart';

Future<void> _pickGroupNamed(WidgetTester tester, String name) async {
  await qaTap(tester, find.byType(DropdownChip));
  expect(find.text(S.pickGroup), findsOneWidget);
  await qaTap(tester, find.text(name).last);
}

Future<void> _pickCurrencyCode(WidgetTester tester, String code) async {
  final c = Currencies.of('INR');
  final symbol = find.descendant(
    of: find.byType(AmountField),
    matching: find.text(c.symbol),
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

String _amountText(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField).at(0)).controller!.text;

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

  group('UIFLOW-R39-02: amounts keep their face value', () {
    for (final (code, typed, shown, minor) in [
      ('JPY', '300', '300', 300),
      ('KWD', '300', '300', 300000),
      ('USD', '300.50', '300.50', 30050),
      ('KWD', '300.5', '300.50', 300500),
    ]) {
      testWidgets('group chip: ₹$typed in a $code group is $shown, and Save '
          'stores $minor $code', (tester) async {
        qaPhone(tester);
        final w = await RealWorld.create(name: 'Arjun');
        final goa = await w.seedGroup(name: 'Goa', people: const ['Priya']);
        final other = await w.seedGroup(
          name: 'Abroad',
          people: const ['Priya'],
          currency: code,
        );
        await pumpReal(tester, w, location: Routes.home);
        w.push(Routes.newExpense(groupId: goa));
        await qaSettle(tester);
        await tester.enterText(find.byType(TextField).at(0), typed);
        await tester.pump();
        await tester.enterText(fieldLabeled(S.description), 'Hotel');
        await tester.pump();
        await _pickGroupNamed(tester, 'Abroad');
        final text = _amountText(tester);
        expect(
          Money.parseMinor(text.replaceAll(',', ''), Currencies.of(code)),
          minor,
          reason: 'shown: $text',
        );
        await qaTap(tester, find.text(S.saveExpense));
        final e = w.group(other).liveExpenses.single;
        expect(e.money.currency, code);
        expect(e.money.total, minor);
        await w.shutdown(tester);
      });
    }

    testWidgets('group chip: ₹300.50 in a yen group holds no amount (yen '
        'have no decimals) and Save does not store one', (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final goa = await w.seedGroup(name: 'Goa', people: const ['Priya']);
      final tokyo = await w.seedGroup(
        name: 'Tokyo',
        people: const ['Priya'],
        currency: 'JPY',
      );
      await pumpReal(tester, w, location: Routes.home);
      w.push(Routes.newExpense(groupId: goa));
      await qaSettle(tester);
      await tester.enterText(find.byType(TextField).at(0), '300.50');
      await tester.pump();
      await tester.enterText(fieldLabeled(S.description), 'Hotel');
      await tester.pump();
      await _pickGroupNamed(tester, 'Tokyo');
      expect(_amountText(tester), isNot(contains('30,050')));
      expect(_amountText(tester), isNot('30050'));
      expect(_amountText(tester), isEmpty);
      await qaTap(tester, find.text(S.saveExpense));
      expect(w.group(tokyo).liveExpenses, isEmpty);
      expect(w.group(goa).liveExpenses, isEmpty);
      await w.shutdown(tester);
    });

    testWidgets('yen group -> rupee group: ¥300 is ₹300, not ₹3', (
      tester,
    ) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final tokyo = await w.seedGroup(
        name: 'Tokyo',
        people: const ['Priya'],
        currency: 'JPY',
      );
      final goa = await w.seedGroup(name: 'Goa', people: const ['Priya']);
      await pumpReal(tester, w, location: Routes.home);
      w.push(Routes.newExpense(groupId: tokyo));
      await qaSettle(tester);
      await tester.enterText(find.byType(TextField).at(0), '300');
      await tester.pump();
      await tester.enterText(fieldLabeled(S.description), 'Hotel');
      await tester.pump();
      await _pickGroupNamed(tester, 'Goa');
      expect(_amountText(tester), '300');
      expect(find.text(S.eachSummary('₹150', 2)), findsOneWidget);
      await qaTap(tester, find.text(S.saveExpense));
      final e = w.group(goa).liveExpenses.single;
      expect(e.money.total, 30000);
      expect(e.money.currency, 'INR');
      await w.shutdown(tester);
    });

    testWidgets('currency picker: ₹300 becomes ¥300 (the same path as the '
        'group chip), and Save stores 300 JPY', (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final goa = await w.seedGroup(name: 'Goa', people: const ['Priya']);
      await pumpReal(tester, w, location: Routes.home);
      w.push(Routes.newExpense(groupId: goa));
      await qaSettle(tester);
      await tester.enterText(find.byType(TextField).at(0), '300');
      await tester.pump();
      await tester.enterText(fieldLabeled(S.description), 'Hotel');
      await tester.pump();
      await _pickCurrencyCode(tester, 'JPY');
      expect(_amountText(tester), '300');
      await qaTap(tester, find.text(S.saveExpense));
      final e = w.group(goa).liveExpenses.single;
      expect(e.money.currency, 'JPY');
      expect(e.money.total, 300);
      await w.shutdown(tester);
    });

    testWidgets('currency picker with multiple payers: what each paid keeps '
        'its face value, so the payers still add up', (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final goa = await w.seedGroup(name: 'Goa', people: const ['Priya']);
      await pumpReal(tester, w, location: Routes.home);
      w.push(Routes.newExpense(groupId: goa));
      await qaSettle(tester);
      await tester.enterText(find.byType(TextField).at(0), '300');
      await tester.pump();
      await tester.enterText(fieldLabeled(S.description), 'Hotel');
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

      await _pickCurrencyCode(tester, 'KWD');
      expect(find.text(S.splitNotDone), findsNothing);
      await qaTap(tester, find.text(S.saveExpense));
      final e = w.group(goa).liveExpenses.single;
      expect(e.money.currency, 'KWD');
      expect(e.money.total, 300000);
      expect(e.money.paid, {
        w.member(goa, 'Arjun'): 100000,
        w.member(goa, 'Priya'): 200000,
      });
      await w.shutdown(tester);
    });

    testWidgets('currency picker with multiple payers, ₹150.50 + ₹149.50 to '
        'yen: the payers stay but are asked again, nothing rescaled', (
      tester,
    ) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final goa = await w.seedGroup(name: 'Goa', people: const ['Priya']);
      await pumpReal(tester, w, location: Routes.home);
      w.push(Routes.newExpense(groupId: goa));
      await qaSettle(tester);
      await tester.enterText(find.byType(TextField).at(0), '300');
      await tester.pump();
      await tester.enterText(fieldLabeled(S.description), 'Hotel');
      await tester.pump();
      await qaTap(tester, find.text(S.paidBy));
      await qaTap(tester, find.text(S.multiplePeople));
      final fields = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), '150.50');
      await tester.enterText(fields.at(1), '149.50');
      await tester.pump();
      await qaTap(tester, find.widgetWithText(FilledButton, S.done));

      await _pickCurrencyCode(tester, 'JPY');
      expect(_amountText(tester), '300');
      expect(find.text(S.multiplePeople), findsOneWidget);
      await qaTap(tester, find.text(S.saveExpense));
      expect(w.group(goa).liveExpenses, isEmpty);
      expect(find.text(S.splitNotDone), findsOneWidget);
      expect(find.textContaining('15,050'), findsNothing);
      await w.shutdown(tester);
    });
  });

  group('sameFaceValue', () {
    test('examples', () {
      final inr = Currencies.of('INR');
      final jpy = Currencies.of('JPY');
      final kwd = Currencies.of('KWD');
      expect(sameFaceValue(30000, inr, jpy), 300);
      expect(sameFaceValue(30000, inr, kwd), 300000);
      expect(sameFaceValue(30050, inr, jpy), isNull);
      expect(sameFaceValue(300, jpy, inr), 30000);
      expect(sameFaceValue(1234, kwd, inr), isNull);
      expect(sameFaceValue(1230, kwd, inr), 123);
      expect(sameFaceValue(Money.maxMinor, jpy, inr), isNull);
      expect(sameFaceValue(Money.maxMinor, inr, jpy), isNull);
      expect(sameFaceValue(Money.maxMinor - 99, inr, jpy), 999999999);
      expect(sameFaceValue(-30000, inr, jpy), -300);
    });

    test('property: seeded random amounts in every currency pair keep '
        'their face value or give null, and never pass Money.maxMinor', () {
      final rnd = Random(4039);
      final all = Currencies.all;
      for (var i = 0; i < 20000; i++) {
        final from = all[rnd.nextInt(all.length)];
        final to = all[rnd.nextInt(all.length)];
        final minor = switch (rnd.nextInt(4)) {
          0 => rnd.nextInt(1000),
          1 => rnd.nextInt(1 << 30),
          2 => Money.maxMinor - rnd.nextInt(1000),
          _ => rnd.nextInt(100000) * from.minorPerMajor,
        };
        final v = sameFaceValue(minor, from, to);
        // Face value as an exact fraction: minor / 10^digits.
        final face = BigInt.from(minor) * BigInt.from(to.minorPerMajor);
        final exact = face % BigInt.from(from.minorPerMajor) == BigInt.zero;
        final want = face ~/ BigInt.from(from.minorPerMajor);
        if (exact && want <= BigInt.from(Money.maxMinor)) {
          expect(v, want.toInt(), reason: '$minor ${from.code}->${to.code}');
        } else {
          expect(v, isNull, reason: '$minor ${from.code}->${to.code}');
        }
        if (v != null) {
          // Round trip back is the original value.
          expect(sameFaceValue(v, to, from), minor);
        }
      }
    });
  });
}
