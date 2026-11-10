// QA MONEY round 8: reverifies the round-7 strict amount grammar
// (MONEY-R3-05, MONEY-R4-01, MONEY-R4-04, MONEY-R6-01) over whole classes
// of text, in every ISO currency where it matters, on the reader, the
// amount field and the real Add expense screen; and checks that amounts
// people really write still read as before.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/currencies_data.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/format/amount_input.dart';
import 'package:settle_up/ui/screens/expense/split_draft.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/amount_field.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

import '../uiflow/expense_flow_test.dart'
    show openAddExpense, saveEnabled, splitInput, typeAmountAndDescription;
import '../uiflow/real_harness.dart';

/// One AmountField on screen, driven the way a phone keyboard drives it.
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

  Future<void> set(String s) async {
    _state.updateEditingValue(
      TextEditingValue(
        text: s,
        selection: TextSelection.collapsed(offset: s.length),
      ),
    );
    await t.pump();
  }

  Future<int?> typed(String currency, String s, {int? initial}) async {
    await pump(currency, initial: initial);
    for (final ch in s.split('')) {
      await set(text + ch);
    }
    return reported;
  }

  Future<int?> pasted(String currency, String s) async {
    await pump(currency);
    await set(s);
    return reported;
  }
}

Currency cur(String code) => Currencies.of(code);

String _shown(String s) => s.runes
    .map(
      (r) => r < 0x20 || r > 0x7E
          ? '\\u{${r.toRadixString(16)}}'
          : String.fromCharCode(r),
    )
    .join();

void main() {
  group('MONEY-R3-05 class: multipliers and joined numbers', () {
    test('no scale word in any language is read past a mark, in any ISO '
        'currency', () {
      const words = [
        'k', 'K', 'm', 'M', 'mn', 'mln', 'Mio', 'Mio.', 'mil', 'mil.', //
        'mille', 'bn', 'bln', 'Mrd', 'Mrd.', 'mld', 'md', 'tys', 'tys.', //
        'тыс', 'тыс.', 'млн', 'млрд', 'l', 'L', 'lac', 'lakh', 'crore', //
        'cr', 'cr.', 'e', 'E', 'ribu', 'rb', 'jt', 'juta', 'ngàn', 'nghìn', //
        'tr', 'triệu', 'Tsd.', 'tusen', 'ezer', 'bin', 'milyon', 'ألف', //
        'مليون', 'हज़ार', 'लाख', 'करोड़', 'ล้าน', 'พัน', '万', '千', '億', //
        '亿', '만', '천', '억', 'thousand', 'grand', 'x', '%', '‰', '½',
      ];
      final read = <String>[];
      for (final c in isoCurrencies) {
        for (final w in words) {
          for (final s in [
            '5 $w',
            '5$w',
            '2.5 ${c.symbol} $w',
            '2,5${c.symbol}$w',
            '${c.symbol}5$w',
            '${c.symbol} 5 $w',
            '5 ${c.code} $w',
            '5\u200B$w',
            '5\u2060$w',
            '5\u00AD$w',
            '5\u200E$w',
            '5\u202C$w',
          ]) {
            final v = readAmount(s, c).minor;
            if (v != null) read.add('${c.code} "${_shown(s)}" -> $v');
          }
        }
      }
      expect(read, isEmpty);
    });

    test('numbers apart by words, tabs, breaks or short groups never join', () {
      for (final (s, c) in [
        ('Rs 500 paid at Cafe 21', 'INR'),
        ('Dinner for 4: 1,200', 'INR'),
        ('Dinner for 4 1,200', 'USD'),
        ('Dinner for 4 120 €', 'EUR'),
        ('Tisch 4 500 CHF', 'CHF'),
        ('Rs 500 21', 'INR'),
        ('500\t210', 'USD'),
        ('500\n210', 'INR'),
        ('500\r\n210', 'EUR'),
        ('1 2', 'USD'),
        ('12 34', 'EUR'),
        ('1e3', 'USD'),
        ('5 € 5', 'EUR'),
        ('Rs 100 at table 2', 'INR'),
      ]) {
        expect(parseAmountInput(s, cur(c)), isNull, reason: _shown(s));
        expect(parseSignedMinor(s, cur(c)), isNull, reason: _shown(s));
      }
    });

    testWidgets('a multiplier pasted after a mark is refused in the amount '
        'field', (t) async {
      final f = _Field(t);
      for (final (c, s) in [
        ('EUR', '1.5 € million'),
        ('INR', '5 Rs lakh'),
        ('USD', '2.5\$k'),
        ('IDR', 'Rp 50rb'),
        ('VND', '50 ngàn'),
      ]) {
        expect(await f.pasted(c, s), isNull, reason: '$c $s');
        expect(f.text, isEmpty, reason: '$c $s');
      }
    });
  });

  group('MONEY-R4-04 class: a sign is "-" or U+2212, or the text is none', () {
    test('every other minus notation is no amount, in a signed field and in '
        'the amount field', () {
      const minusLike = [
        '\u2010', '\u2011', '\u2012', '\u2013', '\u2014', '\u2015', //
        '\uFE58', '\uFE63', '\uFF0D', '\u2796', '\u02D7', '\u2E3A', //
        '\u25B2', '\u25B3', '\u25BC', '\u2BC5', '~', '_', 'minus ', //
        'less ', 'neg ', 'Dr ', 'CR ',
      ];
      for (final code in ['INR', 'JPY', 'EUR', 'USD', 'KWD']) {
        final c = cur(code);
        for (final m in minusLike) {
          for (final s in ['${m}30', '30$m', '$m 30', '${c.symbol}${m}30']) {
            expect(
              parseSignedMinor(s, c),
              isNull,
              reason: '$code ${_shown(s)}',
            );
            expect(
              parseAmountInput(s, c),
              isNull,
              reason: '$code ${_shown(s)}',
            );
          }
        }
        for (final s in [
          '(30)', '（30）', '[30]', '{30}', '<30>', '«30»', '(30', '30)', //
          '30-', '30 -', '30−', '--30', '+-30', '- 30',
        ]) {
          expect(parseSignedMinor(s, c), isNull, reason: '$code ${_shown(s)}');
        }
        expect(parseSignedMinor('-30', c), -30 * c.minorPerMajor);
        expect(parseSignedMinor('−30', c), -30 * c.minorPerMajor);
        expect(parseSignedMinor('${c.symbol}-30', c), -30 * c.minorPerMajor);
        expect(parseSignedMinor('-${c.symbol}30', c), -30 * c.minorPerMajor);
        expect(parseAmountInput('-30', c), isNull);
      }
    });

    testWidgets('on Add expense, a pasted minus form is never saved as a '
        'plus', (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await openAddExpense(tester, w);
      await typeAmountAndDescription(tester, '270', 'Drinks');
      await qaTap(tester, find.text(KitStrings.splitAdjust));
      final priya = splitInput(S.adjustmentOf('Priya'));
      for (final s in [
        '\u25B230',
        '\u201330',
        '(30)',
        '30-',
        'less 30',
        '\u201030',
      ]) {
        await tester.enterText(priya, '');
        await tester.enterText(priya, s);
        await tester.pump();
        final text = tester.widget<TextField>(priya).controller!.text;
        expect(parseSignedMinor(text, cur('INR')), isNull, reason: _shown(s));
        expect(saveEnabled(tester), isFalse, reason: _shown(s));
      }
      expect(w.group(gid).liveExpenses, isEmpty);
      await w.shutdown(tester);
    });
  });

  group('MONEY-R4-01 class: a separator in a no-decimal currency', () {
    testWidgets('typed or pasted, a decimal part never becomes digits of the '
        'amount', (t) async {
      final f = _Field(t);
      for (final c in ['JPY', 'KRW', 'VND', 'ISK', 'CLP', 'PYG', 'UGX']) {
        for (final s in [
          '.50', ',50', '.5', '0.50', '00.5', '0,5', '800.50', '1200.50', //
          '1200,50', '15000.00', '1.200.5', '.', ',',
        ]) {
          final typed = await f.typed(c, s);
          final pasted = await f.pasted(c, s);
          expect(typed, isNull, reason: '$c "$s" typed -> $typed');
          expect(pasted, isNull, reason: '$c "$s" pasted -> $pasted');
        }
        // On Edit, after an existing ¥1,200.
        for (final s in ['.50', ',50', '.5', ',00']) {
          expect(
            await f.typed(c, s, initial: 1200),
            isNull,
            reason: '$c 1,200 then "$s"',
          );
        }
      }
    });
  });

  group('MONEY-R6-01 class: a short last dot or comma group', () {
    test('is no amount in any currency, with any mark', () {
      for (final c in isoCurrencies) {
        for (final n in [
          '1.200.50', '1.200.5', '12.345.6', '1.234.56', //
          '1,200,50', '1,200,5', '1 200 50', "1'200'5",
        ]) {
          for (final s in [
            n,
            '${c.symbol}$n',
            '$n ${c.symbol}',
            '$n ${c.code}',
          ]) {
            expect(readAmount(s, c).minor, isNull, reason: '${c.code} $s');
          }
        }
      }
    });

    testWidgets('typed, pasted, or carried over a currency change, it holds '
        'no amount', (t) async {
      final f = _Field(t);
      for (final c in ['EUR', 'USD', 'INR', 'JPY', 'GBP', 'KWD', 'IDR']) {
        for (final s in ['1.200.50', '1.200.5', '12.345.6']) {
          // Typed, the key that cannot fit is refused (USD "1.20" stays
          // $1.20) or the text holds none; it never reads as a grouping.
          final typed = await f.typed(c, s);
          expect(typed, parseAmountInput(f.text, cur(c)), reason: f.text);
          final joined = s.replaceAll('.', '');
          if (typed != null) {
            expect(typed, isNot(parseAmountInput(joined, cur(c))), reason: c);
          }
          expect(await f.pasted(c, s), isNull, reason: '$c "$s" pasted');
        }
      }
    });
  });

  group('round-7 grammar: amounts people write still read', () {
    test('the common forms in each convention', () {
      for (final (s, c, want) in [
        ('1,234.50', 'USD', 123450),
        ('1.234,50', 'EUR', 123450),
        ('1 234,50', 'EUR', 123450),
        ('1 234,50 €', 'EUR', 123450),
        ('€ 12,50', 'EUR', 1250),
        ('12,50 EUR', 'EUR', 1250),
        ('1.250,- €', 'EUR', 125000),
        ('12.345', 'KWD', 12345),
        ('1,000.555', 'KWD', 1000555),
        ('12.345', 'USD', null),
        ('1,23,456.50', 'INR', 12345650),
        ('₹ 1,00,000', 'INR', 10000000),
        ('Rs. 500/-', 'INR', 50000),
        ('Rs.500', 'INR', 50000),
        ('500 rupees', 'INR', 50000),
        ("1'234.50", 'CHF', 123450),
        ('Fr. 30.–', 'CHF', 3000),
        ('1.200', 'JPY', 1200),
        ('¥1,200', 'JPY', 1200),
        ('5円', 'JPY', 5),
        ('₩15,000', 'KRW', 15000),
        ('50.000 ₫', 'VND', 50000),
        (r'$1,200.00', 'USD', 120000),
        ('US\$ 5', 'USD', 500),
        ('.5', 'USD', 50),
        ('12,5', 'USD', 1250),
        ('1 000 000', 'USD', 100000000),
        ('R\$ 5,00', 'BRL', 500),
        ('Rp50.000,00', 'IDR', 5000000),
        ('5 kr', 'SEK', 500),
        ('5 zł', 'PLN', 500),
        ('1.250', 'TND', 1250),
        ('9,999,999.99', 'USD', 999999999),
      ]) {
        expect(parseAmountInput(s, cur(c)), want, reason: '$c "${_shown(s)}"');
      }
      expect(parsePercent('33,33'), 3333);
      expect(parsePercent('12.5 %'), 1250);
      expect(parsePercent('33.333'), isNull);
    });

    testWidgets('typing the common forms key by key in the amount field', (
      t,
    ) async {
      final f = _Field(t);
      for (final (c, s, want) in [
        ('USD', '1,234.50', 123450),
        ('USD', '1234.5', 123450),
        ('EUR', '1.234,50', 123450),
        ('EUR', '1234,5', 123450),
        ('INR', '1,00,000', 10000000),
        ('INR', '100000.75', 10000075),
        ('JPY', '1.200', 1200),
        ('JPY', '15000', 15000),
        ('KWD', '12.345', 12345),
        ('TND', '1,250', 1250),
        ('IDR', '50.000,00', 5000000),
      ]) {
        expect(await f.typed(c, s), want, reason: '$c "$s" -> "${f.text}"');
      }
      // On Edit, a key after the amount it was given.
      expect(await f.typed('USD', '5', initial: 1200), 12500);
      expect(await f.typed('USD', '.5', initial: 1200), 1250);
      expect(await f.typed('EUR', ',5', initial: 120000), 120050);
    });
  });
}
