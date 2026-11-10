// QA VISUAL: money formatting for the currencies the charter names, and
// what the screens actually render (real minus, signs, grouping).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/ui/format/money_format.dart';
import 'package:settle_up/ui/router.dart';

import 'visual_harness.dart';

void main() {
  configureVisualTests();

  group('MoneyFormat.format', () {
    test('JPY has no decimals', () {
      expect(MoneyFormat.format(500, 'JPY'), '¥500');
      expect(MoneyFormat.format(1234567, 'JPY'), '¥1,234,567');
      expect(MoneyFormat.format(-500, 'JPY'), '−¥500');
      expect(MoneyFormat.format(Money.maxMinor, 'JPY'), '¥99,999,999,999');
    });

    test('KWD has three decimals', () {
      expect(MoneyFormat.format(1250, 'KWD'), 'KD1.250');
      expect(MoneyFormat.format(1, 'KWD'), 'KD0.001');
      expect(MoneyFormat.format(-1250750, 'KWD'), '−KD1,250.750');
      expect(MoneyFormat.format(Money.maxMinor, 'KWD'), 'KD99,999,999.999');
    });

    test('USD and EUR use two decimals and western grouping', () {
      expect(MoneyFormat.format(1250, 'USD'), r'$12.50');
      expect(MoneyFormat.format(123456789, 'USD'), r'$1,234,567.89');
      expect(MoneyFormat.format(1250, 'EUR'), '€12.50');
      expect(MoneyFormat.format(-123456789, 'EUR'), '−€1,234,567.89');
    });

    test('INR uses lakh grouping and drops zero paise', () {
      expect(MoneyFormat.format(12000000, 'INR'), '₹1,20,000');
      expect(MoneyFormat.format(12000050, 'INR'), '₹1,20,000.50');
      expect(MoneyFormat.format(425050, 'INR'), '₹4,250.50');
      expect(MoneyFormat.format(Money.maxMinor, 'INR'), '₹99,99,99,999.99');
      expect(MoneyFormat.format(1000000000, 'INR'), '₹1,00,00,000');
    });

    test('negative uses U+2212, never a hyphen; signed adds +', () {
      for (final c in ['INR', 'USD', 'EUR', 'JPY', 'KWD']) {
        final neg = MoneyFormat.format(-1234, c);
        expect(neg.startsWith('−'), isTrue, reason: neg);
        expect(neg.contains('-'), isFalse, reason: neg);
        expect(MoneyFormat.format(1234, c, signed: true)[0], '+');
        expect(MoneyFormat.format(-1234, c, signed: true)[0], '−');
        expect(MoneyFormat.format(1234, c).contains('+'), isFalse);
        // Zero is never signed.
        final zero = MoneyFormat.format(0, c, signed: true);
        expect(zero.contains('+') || zero.contains('−'), isFalse);
      }
    });

    test('spoken text has digits and the code, no sign', () {
      expect(MoneyFormat.spoken(-500, 'JPY'), '500 JPY');
      expect(MoneyFormat.spoken(1250, 'KWD'), '1.250 KWD');
      expect(MoneyFormat.spoken(-12000050, 'INR'), '120000.50 INR');
      expect(MoneyFormat.spoken(5, 'USD'), '0.05 USD');
    });
  });

  testWidgets('screens render negatives with U+2212 and no hyphen-minus', (
    tester,
  ) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());
    final hyphen = RegExp(r'-\s?(?:[₹$€¥]|KD)\s?\d');
    final seen = <String>{};
    for (final s in ['home', 'group', 'group KWD', 'activity', 'person']) {
      await pumpVisual(
        tester,
        w.phone,
        v: (
          size: const Size(412, 915),
          scale: 1.0,
          brightness: Brightness.light,
        ),
        location: w.screens[s]!,
      );
      for (final t in visibleTexts(tester)) {
        expect(t, isNot(matches(hyphen)), reason: '$s: $t');
        if (t.contains('−')) seen.add(t);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
    // The world has negatives (I owe Sam ¥2,500 and Sam K KD1,250.750).
    expect(seen, contains('−¥2,500'));
    expect(seen, contains('−KD1,250.750'));
    await tester.runAsync(w.phone.dispose);
  });

  testWidgets('the add-expense field groups INR in lakhs as you type', (
    tester,
  ) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());
    await pumpVisual(
      tester,
      w.phone,
      v: (size: const Size(360, 640), scale: 1.0, brightness: Brightness.light),
      location: Routes.newExpense(groupId: w.group),
    );
    await tester.enterText(find.byType(TextField).first, '120000');
    await tester.pump();
    expect(find.text('1,20,000'), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(w.phone.dispose);
  });
}
