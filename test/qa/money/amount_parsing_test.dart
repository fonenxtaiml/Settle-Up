// QA MONEY: amount text -> minor units on every input path the app has:
// Money.parseMinor (core), AmountField (the big amount on Add expense and
// "Pay part of it"), and the per-member split fields (SplitDraft).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/core/split.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/format/money_format.dart';
import 'package:settle_up/ui/screens/expense/split_draft.dart';
import 'package:settle_up/ui/widgets/amount_field.dart';

final Currency inr = Currencies.of('INR');
final Currency usd = Currencies.of('USD');
final Currency eur = Currencies.of('EUR');
final Currency kwd = Currencies.of('KWD');
final Currency jpy = Currencies.of('JPY');

Future<int?> typeInto(
  WidgetTester tester,
  String currency,
  String text, {
  bool paste = false,
}) async {
  int? last;
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: AmountField(
          key: UniqueKey(),
          currency: currency,
          onChanged: (v) => last = v,
        ),
      ),
    ),
  );
  final field = find.byType(TextField);
  if (paste) {
    await tester.enterText(field, text);
  } else {
    // One keystroke at a time, as a phone keyboard delivers them.
    var current = '';
    for (final ch in text.split('')) {
      final state = tester.state<EditableTextState>(find.byType(EditableText));
      current = state.textEditingValue.text + ch;
      state.updateEditingValue(
        TextEditingValue(
          text: current,
          selection: TextSelection.collapsed(offset: current.length),
        ),
      );
      await tester.pump();
    }
  }
  await tester.pump();
  return last;
}

void main() {
  group('Money.parseMinor', () {
    test('plain and decimal-comma input', () {
      expect(Money.parseMinor('12', usd), 1200);
      expect(Money.parseMinor('12.5', usd), 1250);
      expect(Money.parseMinor('12,50', eur), 1250);
      expect(Money.parseMinor(' 1 234.50 ', usd), 123450);
      expect(Money.parseMinor('500', jpy), 500);
    });

    test('KWD has three decimals', () {
      expect(Money.parseMinor('12.345', kwd), 12345);
      expect(Money.parseMinor('12.3456', kwd), isNull);
      expect(Money.parseMinor('0.001', kwd), 1);
    });

    test('too many decimals, negatives, junk and overflow are rejected', () {
      expect(Money.parseMinor('12.345', usd), isNull);
      expect(Money.parseMinor('5.5', jpy), isNull);
      expect(Money.parseMinor('-5', usd), isNull);
      expect(Money.parseMinor('1e3', usd), isNull);
      expect(Money.parseMinor('', usd), isNull);
      expect(Money.parseMinor('.', usd), isNull);
      expect(Money.parseMinor('9999999.99', usd), Money.maxMinor);
      expect(Money.parseMinor('10000000', usd), isNull);
      expect(Money.parseMinor('99999999999999999999', usd), isNull);
    });

    test('grouped input is never misread as a smaller amount', () {
      // Core has no locale: it must reject rather than guess.
      expect(Money.parseMinor('1,234.50', usd), isNull);
      expect(Money.parseMinor('1.234,50', eur), isNull);
    });
  });

  group('AmountField', () {
    testWidgets('typing 1234.50 shows 1,234.50 and reports 123450', (
      tester,
    ) async {
      expect(await typeInto(tester, 'USD', '1234.50'), 123450);
      expect(find.text('1,234.50'), findsOneWidget);
    });

    testWidgets('pasting 1,234.50 reports 123450', (tester) async {
      expect(await typeInto(tester, 'USD', '1,234.50', paste: true), 123450);
    });

    testWidgets('decimal comma typed at the end works (12,5 -> 1250)', (
      tester,
    ) async {
      expect(await typeInto(tester, 'EUR', '12,5'), 1250);
    });

    testWidgets('INR lakh grouping', (tester) async {
      expect(await typeInto(tester, 'INR', '120000'), 12000000);
      expect(find.text('1,20,000'), findsOneWidget);
    });

    testWidgets('KWD 12.345 and JPY whole yen', (tester) async {
      expect(await typeInto(tester, 'KWD', '12.345'), 12345);
      expect(await typeInto(tester, 'JPY', '1500'), 1500);
    });

    testWidgets('a third decimal in USD is ignored, not rounded', (
      tester,
    ) async {
      expect(await typeInto(tester, 'USD', '12.345'), 1234);
    });

    testWidgets(
      'QA MONEY-R1-02: European "1.234,50" is never taken as 1.23',
      // testWidgets only takes a bool skip; the id is in the name.
      skip: true, // QA MONEY-R1-02: AmountField reads "1.234,50" as 1.23
      (tester) async {
        for (final paste in [false, true]) {
          final v = await typeInto(tester, 'EUR', '1.234,50', paste: paste);
          expect(
            v,
            anyOf(123450, isNull),
            reason: 'paste=$paste: either the intended 1,234.50 or rejected',
          );
        }
      },
    );
  });

  group('per-member split fields (SplitDraft)', () {
    SplitDraft draft(SplitMethod m) =>
        SplitDraft(members: const ['a', 'b', 'c'], method: m);

    test('exact values, decimal comma', () {
      final d = draft(SplitMethod.exact)
        ..exact.addAll({'a': '10,50', 'b': '9.50', 'c': '0'});
      expect(d.spec(eur).values, {'a': 1050, 'b': 950});
      expect(d.check(2000, eur).isValid, isTrue);
    });

    test('percent 33.33 / 33.33 / 33.34', () {
      final d = draft(SplitMethod.percent)
        ..percent.addAll({'a': '33.33', 'b': '33,33', 'c': '33.34'});
      expect(d.spec(inr).values, {'a': 3333, 'b': 3333, 'c': 3334});
      expect(d.check(1000, inr).shares, {'a': 333, 'b': 333, 'c': 334});
    });

    test('percent left-over reads as money, rounded up', () {
      final d = draft(SplitMethod.percent)
        ..percent.addAll({'a': '50', 'b': '49.99'});
      expect(d.leftMinor(1000, inr), 1, reason: '0.01% of 10.00 -> 0.01 up');
    });

    test('signed adjustments: + - and U+2212', () {
      expect(parseSignedMinor('+50', inr), 5000);
      expect(parseSignedMinor('-50', inr), -5000);
      expect(parseSignedMinor('−50', inr), -5000);
      expect(parseSignedMinor('', inr), 0);
    });

    test('switching method seeds a valid even split', () {
      final d = draft(SplitMethod.equal)
        ..switchTo(SplitMethod.exact, 1000, inr);
      expect(d.check(1000, inr).isValid, isTrue);
      d.switchTo(SplitMethod.percent, 1000, inr);
      expect(d.check(1000, inr).isValid, isTrue);
      expect(d.spec(inr).values, {'a': 3334, 'b': 3333, 'c': 3333});
    });

    test('reloading a saved spec reproduces the same shares', () {
      for (final s in [
        const SplitSpec(SplitMethod.exact, {'a': 1050, 'b': 950}),
        const SplitSpec(SplitMethod.percent, {'a': 1250, 'b': 8750}),
        const SplitSpec(SplitMethod.shares, {'a': 3, 'b': 1}),
        const SplitSpec(SplitMethod.adjustment, {'a': -150, 'b': 0, 'c': 275}),
      ]) {
        final d = SplitDraft(members: const ['a', 'b', 'c'])..load(s, inr);
        expect(
          SplitCalculator.compute(2000, d.spec(inr)),
          SplitCalculator.compute(2000, s),
          reason: '$s',
        );
      }
    });

    test(
      'a grouped amount in a split field is never silently dropped',
      skip:
          'QA MONEY-R1-04: "1,000" in a split field parses as null and '
          'counts as 0 (adjustment saves without it)',
      () {
        // INR: "1,000" is how the amount field itself shows a thousand.
        final adj = draft(SplitMethod.adjustment)..adjust['a'] = '1,000';
        final c = adj.check(300000, inr);
        expect(
          c.isValid ? adj.spec(inr).values['a'] : 100000,
          100000,
          reason: 'either the adjustment is 1,000 or the split is invalid',
        );
        // KWD: "1,000" must not become 1.000 KWD.
        final k = draft(SplitMethod.adjustment)..adjust['a'] = '1,000';
        expect(k.spec(kwd).values['a'], anyOf(1000000, isNull));
        // Exact: "1,234.50" must count.
        final e = draft(SplitMethod.exact)..exact['a'] = '1,234.50';
        expect(e.spec(usd).values['a'], 123450);
      },
    );
  });

  group('MoneyFormat', () {
    test('integer-exact for every amount the app can hold', () {
      expect(
        MoneyFormat.format(Money.maxMinor, 'USD', locale: 'en_US'),
        '\$9,999,999.99',
      );
      expect(
        MoneyFormat.format(Money.maxMinor, 'KWD', locale: 'en_US'),
        contains('999,999.999'),
      );
      expect(
        MoneyFormat.format(Money.maxMinor, 'JPY', locale: 'en_US'),
        contains('999,999,999'),
      );
      expect(MoneyFormat.format(-1, 'USD', locale: 'en_US'), '−\$0.01');
      expect(MoneyFormat.format(1, 'KWD', locale: 'en_US'), contains('0.001'));
      // A group net of 50 x maxMinor still prints to the unit.
      expect(
        MoneyFormat.format(50 * Money.maxMinor, 'USD', locale: 'en_US'),
        '\$499,999,999.50',
      );
    });

    test('INR: lakh grouping, whole rupees drop paise', () {
      expect(MoneyFormat.format(12000000, 'INR'), '₹1,20,000');
      expect(MoneyFormat.format(425050, 'INR'), '₹4,250.50');
      expect(MoneyFormat.format(-60000, 'INR', signed: true), '−₹600');
      expect(MoneyFormat.format(60000, 'INR', signed: true), '+₹600');
    });
  });
}
