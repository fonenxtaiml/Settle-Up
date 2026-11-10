// Amount reading, round 5 regressions: tabs, line breaks and words around
// space-grouped digits (MONEY-R3-05 reopened), a separator typed after four
// digits or more in a no-decimal currency (MONEY-R4-01 reopened), a minus
// written as a hyphen, a word or a half bracket (MONEY-R4-04 reopened), and
// cent, pence, percent and fraction marks (MONEY-R5-01).
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

int? read(String s, String c) => parseAmountInput(s, cur(c));

void main() {
  group('MONEY-R3-05: tabs, line breaks and words never group digits', () {
    test('a tab or a line break between digits is two numbers', () {
      for (final c in ['USD', 'INR', 'EUR', 'CHF', 'JPY', 'TND']) {
        for (final gap in ['\t', '\n', '\r\n', '\r', '\u000B', ' ']) {
          expect(read('500${gap}210', c), isNull, reason: '$c $gap');
          expect(read('1${gap}250', c), isNull, reason: '$c $gap');
        }
      }
      // Around the number they are only white space.
      expect(read('\t500\n', 'USD'), 50000);
    });

    test('space groups are read only next to currency words', () {
      for (final (s, c) in [
        ('Dinner for 4 120 €', 'EUR'),
        ('Dîner pour 4 120 €', 'EUR'),
        ('Table 12 340', 'EUR'),
        ('for 4 120', 'CAD'),
        ('Tisch 4 500 CHF', 'CHF'),
        ('Table 12 340', 'USD'),
        ('approx 1 234', 'EUR'),
        ('1 234 k', 'EUR'),
      ]) {
        expect(read(s, c), isNull, reason: '"$s" in $c');
      }
      for (final (s, c, want) in [
        ('1 234,50 €', 'EUR', 123450),
        ('1 234,50 EUR', 'EUR', 123450),
        ('EUR 1 234,50', 'EUR', 123450),
        ('CHF 4 500', 'CHF', 450000),
        ('4 500 CHF', 'CHF', 450000),
        ('12 500 DT', 'TND', 12500000),
        ('1 234,50 zł', 'PLN', 123450),
        ('1 234,50', 'EUR', 123450),
        ('1 234', 'USD', 123400),
      ]) {
        expect(read(s, c), want, reason: '"$s" in $c');
      }
    });

    test('a split field keeps a tab-separated paste unreadable', () {
      final inr = cur('INR');
      final f = UnitInputFormatter(
        read: (t) => parseAmountInput(t, inr),
        write: (v) => minorToInput(v, inr),
      );
      final v = f.formatEditUpdate(
        TextEditingValue.empty,
        const TextEditingValue(text: '500\t210'),
      );
      expect(v.text, '500\t210');
      expect(parseAmountInput(v.text, inr), isNull);
    });

    testWidgets('the amount field refuses a tab-separated paste', (t) async {
      final f = _Field(t);
      await f.pump('INR');
      await f.set('500\t310');
      expect(f.reported, isNull);
      expect(f.text, isEmpty);
    });
  });

  group('MONEY-R4-01: a separator that cannot group in a no-decimal '
      'currency holds no amount', () {
    testWidgets('typed after four digits or more, or after a zero', (t) async {
      final f = _Field(t);
      for (final (c, s) in [
        ('JPY', '1200.50'),
        ('JPY', '1200.5'),
        ('JPY', '1200,50'),
        ('KRW', '15000.00'),
        ('VND', '50000.00'),
        ('JPY', '0.50'),
        ('JPY', '1200.500'),
      ]) {
        await f.pump(c);
        await f.keys(s);
        expect(f.reported, isNull, reason: '$c "$s"');
        expect(f.text, s, reason: '$c "$s" is shown as typed');
        expect(find.text(KitStrings.amountDecimals(0)), findsOneWidget);
      }
      // Nothing more after three digits, and no second separator.
      await f.pump('JPY');
      await f.keys('1200.5005.');
      expect((f.text, f.reported), ('1200.500', null));
    });

    testWidgets('deleting the separator gives the amount back', (t) async {
      final f = _Field(t);
      await f.pump('JPY');
      await f.keys('1200.5');
      expect(f.reported, isNull);
      await f.backspace();
      expect((f.text, f.reported), ('1200.', null));
      expect(find.text(KitStrings.amountDecimals(0)), findsNothing);
      await f.backspace();
      expect((f.text, f.reported), ('1,200', 1200));
      await f.keys('5');
      expect((f.text, f.reported), ('12,005', 12005));
    });

    testWidgets('on Edit, a dot after the amount is never dropped', (t) async {
      final f = _Field(t);
      await f.pump('JPY', initial: 1200);
      expect(f.text, '1,200');
      await f.keys('.50');
      expect(f.reported, isNull);
      expect(f.text, '1200.50');
      // A digit still extends the amount, and a comma still groups.
      await f.pump('JPY', initial: 1200);
      await f.keys('5');
      expect((f.text, f.reported), ('12,005', 12005));
      await f.pump('JPY', initial: 1200);
      await f.keys(',000');
      expect((f.text, f.reported), ('1,200,000', 1200000));
    });
  });

  group('MONEY-R4-04: a minus written as a hyphen, a word or in brackets', () {
    test('reads as negative, or is refused', () {
      final inr = cur('INR');
      for (final s in [
        '‐30',
        '30‐',
        '‐ 30',
        '‑30',
        'minus 30',
        'Minus 30',
        'Rs minus 30',
        '(30)',
        '(Rs 30)',
      ]) {
        expect(parseSignedMinor(s, inr), -3000, reason: s);
        expect(parseAmountInput(s, inr), isNull, reason: s);
      }
      for (final s in [
        '(30',
        '30)',
        'Rs 500 (approx)',
        '((30))',
        'minus -30',
      ]) {
        expect(parseSignedMinor(s, inr), isNull, reason: s);
        expect(parseAmountInput(s, inr), isNull, reason: s);
      }
      // A hyphen between words is no minus.
      expect(parseAmountInput('Rs. 1,200/-', inr), 120000);
    });

    test('an adjustment paste keeps its sign', () {
      final inr = cur('INR');
      final f = UnitInputFormatter(
        read: (t) => parseSignedMinor(t, inr),
        write: (v) => minorToInput(v, inr),
        signed: true,
      );
      for (final s in ['‐30', '‑30', 'minus 30']) {
        final v = f.formatEditUpdate(
          TextEditingValue.empty,
          TextEditingValue(text: s),
        );
        expect(parseSignedMinor(v.text, inr), -3000, reason: s);
      }
    });
  });

  group('MONEY-R5-01: a mark that divides the number is never dropped', () {
    test('cent, pence, percent and fraction marks are refused', () {
      for (final (s, c) in [
        ('99¢', 'USD'),
        ('99 ¢', 'USD'),
        ('99￠', 'USD'),
        ('50p', 'GBP'),
        ('50 p', 'GBP'),
        ('50 pence', 'GBP'),
        ('15%', 'INR'),
        ('15 ٪', 'INR'),
        ('15‰', 'INR'),
        ('1½', 'USD'),
        ('1 ¾', 'USD'),
        ('1⅓', 'USD'),
        ('10²', 'USD'),
        ('50 kop', 'UAH'),
        ('20 centavos', 'BRL'),
      ]) {
        expect(read(s, c), isNull, reason: '"$s" in $c');
      }
      // Currency marks and words are still read.
      expect(read('£50', 'GBP'), 5000);
      expect(read('50 €', 'EUR'), 5000);
      expect(read('Rs. 50', 'INR'), 5000);
    });

    test('a percent field takes one percent sign after the number', () {
      expect(parsePercent('15%'), 1500);
      expect(parsePercent('12.5 %'), 1250);
      expect(parsePercent('15'), 1500);
      expect(parsePercent('%15'), isNull);
      expect(parsePercent('15%%'), isNull);
      expect(parsePercent('1½%'), isNull);
    });

    testWidgets('the amount field refuses "99¢" and "50p"', (t) async {
      final f = _Field(t);
      await f.pump('USD');
      await f.set('99¢');
      expect((f.text, f.reported), ('', null));
      await f.pump('GBP');
      await f.set('50p');
      expect((f.text, f.reported), ('', null));
    });
  });
}
