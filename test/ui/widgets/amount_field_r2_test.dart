// Amount reading, round 2 regressions (MONEY-R2-01..05, UIFLOW-R2-02):
// typing and pasting into the big amount field never gives an amount other
// than the one written.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/format/amount_input.dart';
import 'package:settle_up/ui/widgets/amount_field.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

/// Types [text] one key at a time (or pastes it) and returns the last
/// reported amount and the shown text.
Future<(int?, String)> _type(
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
  if (paste) {
    await tester.enterText(find.byType(TextField), text);
  } else {
    for (final ch in text.split('')) {
      final state = tester.state<EditableTextState>(find.byType(EditableText));
      final next = state.textEditingValue.text + ch;
      state.updateEditingValue(
        TextEditingValue(
          text: next,
          selection: TextSelection.collapsed(offset: next.length),
        ),
      );
      await tester.pump();
    }
  }
  await tester.pump();
  final shown = tester
      .state<EditableTextState>(find.byType(EditableText))
      .textEditingValue
      .text;
  return (last, shown);
}

void main() {
  group('normalizeAmountInput', () {
    test('a dot or comma that belongs to a word is not a separator', () {
      final inr = Currencies.of('INR');
      expect(parseAmountInput('Rs. 500', inr), 50000);
      expect(parseAmountInput('Rs.500', inr), 50000);
      // A dot apart from the mark, and a word, are not the grammar.
      expect(parseAmountInput('Rs . 500', inr), isNull);
      expect(parseAmountInput('approx. 300', inr), isNull);
      expect(parseAmountInput('500 Rs.', inr), 50000);
      expect(parseAmountInput('Rs. 1,234.50', inr), 123450);
      // A point after a digit is still a decimal point.
      expect(parseAmountInput('0.5', inr), 50);
    });

    test('a first group of zero never groups thousands', () {
      final kwd = Currencies.of('KWD');
      final eur = Currencies.of('EUR');
      expect(parseAmountInput('0,500', kwd), 500);
      expect(parseAmountInput('0,500', eur), isNull);
      expect(parseAmountInput('05,000', eur), isNull);
      expect(parseAmountInput('0,500,000', eur), isNull);
      expect(parseAmountInput('0.500.000', eur), isNull);
      // Real grouping still works.
      expect(parseAmountInput('1,000', eur), 100000);
      expect(parseAmountInput('10,500', kwd), 10500000);
    });

    test('a short last comma group is no amount, typed or pasted', () {
      // One grammar for typing and pasting: "1,234,5" is on its way to
      // "1,234,567" and holds no amount until it gets there.
      final usd = Currencies.of('USD');
      expect(parseAmountInput('1,234,5', usd), isNull);
      expect(parseAmountInput('1,234,', usd), isNull);
      expect(parseAmountInput('1,2,3', usd), isNull);
      expect(parseAmountInput('1,234,567', usd), 123456700);
    });
  });

  group('typing commas key by key', () {
    testWidgets('dot-decimal currencies group on the third digit and on a '
        'second comma', (t) async {
      expect(await _type(t, 'USD', '1,234,567'), (123456700, '1,234,567'));
      expect(await _type(t, 'INR', '12,34,567'), (123456700, '12,34,567'));
      expect(await _type(t, 'JPY', '1,000,000'), (1000000, '1,000,000'));
      expect(await _type(t, 'USD', '12,5'), (1250, '12.5'));
    });

    testWidgets('a decimal comma stays the decimal point', (t) async {
      expect(await _type(t, 'TND', '1,250'), (1250, '1.250'));
      expect(await _type(t, 'EUR', '12,500'), (1250, '12.50'));
      // A second decimal comma is refused in a decimal-comma currency.
      expect(await _type(t, 'EUR', '12,5,0'), (1250, '12.50'));
      // KWD writes a dot; a second comma groups there: "1,250,75" is on
      // its way to 1,250,750 and holds no amount until then (round 7).
      expect(await _type(t, 'KWD', '1,250,75'), (null, '1,250,75'));
      expect(await _type(t, 'KWD', '1,250,750'), (1250750000, '1,250,750'));
    });

    testWidgets('a single comma with four digits after it is refused, not '
        'cut', (t) async {
      // "1,2345" would show 1.23: the fourth digit is refused instead.
      expect(await _type(t, 'USD', '1,2345'), (123400, '1,234'));
      expect(await _type(t, 'JPY', '1,0000'), (1000, '1,000'));
    });
  });

  group('pasting', () {
    testWidgets('more decimals than the currency has is refused and said', (
      t,
    ) async {
      expect(await _type(t, 'EUR', '1.234', paste: true), (null, ''));
      expect(find.text(KitStrings.amountDecimals(2)), findsOneWidget);
      expect(await _type(t, 'JPY', '500.5', paste: true), (null, ''));
      expect(find.text(KitStrings.amountDecimals(0)), findsOneWidget);
      expect(await _type(t, 'KWD', '0,500', paste: true), (500, '0.500'));
      expect(find.textContaining('decimal'), findsNothing);
    });

    testWidgets('"Rs. 500" pastes as 500', (t) async {
      expect(await _type(t, 'INR', 'Rs. 500', paste: true), (50000, '500'));
    });
  });

  testWidgets('UIFLOW-R2-02: an amount over the cap stays on screen as typed '
      'and reports no amount', (t) async {
    // UIFLOW-R2-04 lifted the cap to Rp 999,999,999.99, so 1200000000 is
    // the over-cap amount.
    final (v, shown) = await _type(t, 'IDR', '1200000000');
    expect(shown, '1,200,000,000');
    expect(v, isNull);
    expect(find.textContaining('Enter an amount up to'), findsOneWidget);
    // Deleting the extra digit makes it an amount again.
    final state = t.state<EditableTextState>(find.byType(EditableText));
    state.updateEditingValue(
      const TextEditingValue(
        text: '1,200,000,00',
        selection: TextSelection.collapsed(offset: 12),
      ),
    );
    await t.pump();
    expect(find.textContaining('Enter an amount up to'), findsNothing);
  });
}
