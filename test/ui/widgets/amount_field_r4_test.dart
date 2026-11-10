// Amount reading, round 4 regressions: one reading per currency for a
// typed comma (MONEY-R3-03 reopened), joined numbers and words after the
// number (MONEY-R3-05 reopened), short groups in no-decimal currencies
// (MONEY-R4-01), TND grouping (MONEY-R4-02), the small split and payer
// fields (MONEY-R4-03) and the ways a minus is written (MONEY-R4-04).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/format/amount_input.dart';
import 'package:settle_up/ui/format/unit_input_formatter.dart';
import 'package:settle_up/ui/screens/expense/split_draft.dart';
import 'package:settle_up/ui/widgets/amount_field.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

final class _Field {
  _Field(this.t);

  final WidgetTester t;
  int? reported;

  Future<void> pump(String currency, {int? initial}) async {
    reported = null;
    await t.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: AmountField(
            key: UniqueKey(),
            currency: currency,
            initialMinor: initial,
            onChanged: (v) => reported = v,
          ),
        ),
      ),
    );
  }

  EditableTextState get _state =>
      t.state<EditableTextState>(find.byType(EditableText));

  String get text => _state.textEditingValue.text;

  Future<void> keys(String s) async {
    for (final ch in s.split('')) {
      await set(text + ch);
    }
  }

  Future<void> backspace() => set(text.substring(0, text.length - 1));

  Future<void> set(String s) async {
    _state.updateEditingValue(
      TextEditingValue(
        text: s,
        selection: TextSelection.collapsed(offset: s.length),
      ),
    );
    await t.pump();
  }
}

Currency cur(String code) => Currencies.of(code);

void main() {
  group('a typed comma has one reading per currency (MONEY-R3-03)', () {
    testWidgets('three-decimal dot currencies group "1,250" as the reader '
        'does, and later separators never multiply it', (t) async {
      final f = _Field(t);
      for (final c in ['KWD', 'BHD', 'OMR', 'JOD', 'IQD', 'LYD']) {
        final want = parseAmountInput('1,250', cur(c));
        expect(want, 1250000, reason: c);
        await f.pump(c);
        await f.keys('1,25');
        expect((f.text, f.reported), ('1.25', 1250), reason: c);
        await f.keys('0');
        expect((f.text, f.reported), ('1,250', want), reason: c);
        await f.keys(',');
        expect(f.reported, want, reason: '$c "1,250,"');
        await f.keys('000');
        expect(f.reported, 1250000000, reason: '$c "1,250,000"');
      }
      // A dot typed as the decimal point stays one.
      await f.pump('KWD');
      await f.keys('1.250,');
      expect((f.text, f.reported), ('1.250', 1250));
      // TND writes a decimal comma: "1,250" is 1.250 DT there, typed or not.
      await f.pump('TND');
      await f.keys('1,250,');
      expect((f.text, f.reported), ('1.250', 1250));
    });
  });

  group('short groups in a no-decimal currency (MONEY-R4-01)', () {
    testWidgets('hold no amount and say why until the group is complete', (
      t,
    ) async {
      final f = _Field(t);
      await f.pump('JPY');
      await f.keys('800.');
      expect((f.text, f.reported), ('800.', null));
      expect(find.text(KitStrings.amountDecimals(0)), findsNothing);
      await f.keys('50');
      expect((f.text, f.reported), ('800.50', null));
      expect(find.text(KitStrings.amountDecimals(0)), findsOneWidget);
      // Taking the decimals back out gives the yen again.
      await f.backspace();
      expect((f.text, f.reported), ('800.5', null));
      await f.backspace();
      await f.backspace();
      expect((f.text, f.reported), ('800', 800));
      expect(find.text(KitStrings.amountDecimals(0)), findsNothing);
      // A complete group is a thousand, as before (MONEY-R3-02).
      await f.pump('VND');
      await f.keys('50.000');
      expect((f.text, f.reported), ('50,000', 50000));
      await f.keys('.0');
      expect(f.reported, isNull);
      await f.keys('00');
      expect((f.text, f.reported), ('50,000,000', 50000000));
      // Commas too: "12,5" in KRW is not 125 won.
      await f.pump('KRW');
      await f.keys('12,5');
      expect((f.text, f.reported), ('12,5', null));
      await f.keys('00');
      expect((f.text, f.reported), ('12,500', 12500));
    });
  });

  group('TND grouping (MONEY-R4-02)', () {
    testWidgets('thousands are shown with a thin space and read back', (
      t,
    ) async {
      final tnd = cur('TND');
      expect(AmountField.groupForDisplay('12500', tnd), '12\u2009500');
      expect(AmountField.textFor(1234567890, tnd), '1\u2009234\u2009567.890');
      expect(AmountField.parse('12\u2009500.250', tnd), 12500250);
      expect(parseAmountInput('12\u2009500', tnd), 12500000);
      // Other currencies keep the comma.
      expect(AmountField.groupForDisplay('12500', cur('KWD')), '12,500');
      expect(AmountField.groupForDisplay('12500', cur('EUR')), '12,500');
      final f = _Field(t);
      await f.pump('TND', initial: 12345000);
      expect(f.text, '12\u2009345');
      // Deleting a digit in the middle keeps the grouping reading.
      await f.set('12\u200945');
      expect((f.text, f.reported), ('1\u2009245', 1245000));
    });
  });

  group('the reader (MONEY-R3-05, MONEY-R4-04)', () {
    test('space-apart numbers are not joined', () {
      for (final (s, c) in [
        ('Dinner for 4 1,200', 'INR'),
        ('Rs 500 21', 'INR'),
        ('Table 12 340', 'USD'),
        ('1 23', 'USD'),
        ("12'34", 'CHF'),
      ]) {
        expect(parseAmountInput(s, cur(c)), isNull, reason: s);
      }
      expect(parseAmountInput('1 234,50 €', cur('EUR')), 123450);
      expect(parseAmountInput('EUR 1 234,50', cur('EUR')), 123450);
      expect(parseAmountInput('1 234.50', cur('USD')), 123450);
      expect(parseAmountInput("CHF 1'234.50", cur('CHF')), 123450);
    });

    test('a word after the number must name a currency', () {
      for (final (s, c) in [
        ('1.5 mln', 'EUR'),
        ('2 млн', 'RUB'),
        ('5万', 'JPY'),
        ('5만원', 'KRW'),
        ('50 cents', 'USD'),
        ('500 for lunch', 'INR'),
        ('2.5 K', 'PGK'),
      ]) {
        expect(parseAmountInput(s, cur(c)), isNull, reason: s);
      }
      for (final (s, c, v) in [
        ('50 kr', 'SEK', 5000),
        ('500 Rs.', 'INR', 50000),
        ('500 rupees', 'INR', 50000),
        ('Rs 500 only', 'INR', 50000),
        ('1,250 DT', 'TND', 1250),
        ('20 euro', 'EUR', 2000),
        ('3000円', 'JPY', 3000),
        ('5000원', 'KRW', 5000),
        ('12 zł', 'PLN', 1200),
        ('100 USD', 'USD', 10000),
      ]) {
        expect(parseAmountInput(s, cur(c)), v, reason: s);
      }
    });

    test('every common minus is read, and refused where no minus fits', () {
      final inr = cur('INR');
      for (final s in [
        '-30',
        '\u221230',
        '\u201330',
        '\u201430',
        '(30)',
        '30-',
        '30 -',
        'Rs -30',
        '-Rs 30',
        '(Rs 30)',
      ]) {
        expect(parseSignedMinor(s, inr), -3000, reason: s);
        expect(parseAmountInput(s, inr), isNull, reason: s);
      }
      for (final s in ['-(30)', '+30-', '--30', '-30-']) {
        expect(parseSignedMinor(s, inr), isNull, reason: s);
      }
      expect(parseSignedMinor('+30', inr), 3000);
      expect(parseSignedMinor('Rs. 1,200/-', inr), 120000);
      expect(parseSignedMinor('1.250,- €', cur('EUR')), 125000);
      expect(parseSignedMinor('Fr. 30.\u2013', cur('CHF')), 3000);
      expect(parseSignedMinor('-', inr), 0);
      expect(parseSignedMinor('', inr), 0);
    });
  });

  group('small amount fields (MONEY-R3-05, MONEY-R4-03, MONEY-R4-04)', () {
    final inr = cur('INR');
    TextEditingValue apply(UnitInputFormatter f, String old, String next) =>
        f.formatEditUpdate(
          TextEditingValue(text: old),
          TextEditingValue(text: next),
        );

    test('a paste is read by the reader, not filtered', () {
      final f = UnitInputFormatter(
        read: (t) => parseAmountInput(t, inr),
        write: (v) => minorToInput(v, inr),
      );
      expect(apply(f, '', 'Rs. 50').text, '50');
      expect(apply(f, '', 'Rs.50').text, '50');
      expect(apply(f, '', '₹1,200.50').text, '1200.50');
      expect(apply(f, '', '1,20,000').text, '1,20,000');
      // Unreadable pastes stay as they are, so the screen says so.
      expect(apply(f, '', 'Rs 100 at table 2').text, 'Rs 100 at table 2');
      expect(parseAmountInput('Rs 100 at table 2', inr), isNull);
      expect(apply(f, '', '2.5k').text, '2.5k');
      // Keys are still filtered.
      expect(apply(f, '12', '12a').text, '12');
      expect(apply(f, '12', '12.').text, '12.');
      expect(apply(f, '12', '1').text, '1');
    });

    test('a signed paste keeps its minus', () {
      final f = UnitInputFormatter(
        read: (t) => parseSignedMinor(t, inr),
        write: (v) => minorToInput(v, inr),
        signed: true,
      );
      expect(apply(f, '', '\u201330').text, '-30');
      expect(apply(f, '', '(30)').text, '-30');
      expect(apply(f, '', '30-').text, '30-');
      expect(parseSignedMinor('30-', inr), -3000);
      expect(apply(f, '', '-30').text, '-30');
      expect(apply(f, '3', '3-').text, '3-');
      expect(apply(f, '3', '3(').text, '3');
    });

    test('percent fields read pastes too', () {
      final f = UnitInputFormatter(read: parsePercent, write: formatPercent);
      expect(apply(f, '', '12.5 %').text, '12.5');
      expect(apply(f, '', '12.5%').text, '12.5');
      expect(parsePercent('12.5 %'), 1250);
    });
  });
}
