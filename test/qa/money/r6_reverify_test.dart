// QA MONEY round 6: reverifies the round-5 amount reading fixes
// (MONEY-R3-05, MONEY-R4-01, MONEY-R4-04, MONEY-R5-01) with neighbouring
// inputs, on the amount field, the split fields and the real Add expense
// screen, and holds repro tests for the defects still open or found in
// this round (skipped with their ids).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
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
/// Its currency can change while text is in it, as on Add expense.
final class _Field {
  _Field(this.t);

  final WidgetTester t;
  int? reported;
  String _currency = 'USD';
  Key _key = UniqueKey();
  late StateSetter _setState;

  Future<void> pump(String currency, {int? initial}) async {
    reported = null;
    _currency = currency;
    _key = UniqueKey();
    await t.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              _setState = setState;
              return AmountField(
                key: _key,
                currency: _currency,
                initialMinor: initial,
                onChanged: (v) => reported = v,
              );
            },
          ),
        ),
      ),
    );
  }

  /// The currency picked again while the text stays.
  Future<void> switchTo(String currency) async {
    _setState(() => _currency = currency);
    await t.pump();
  }

  EditableTextState get _state =>
      t.state<EditableTextState>(find.byType(EditableText));

  String get text => _state.textEditingValue.text;

  /// Keys typed one at a time at the end of the text.
  Future<void> keys(String s) async {
    for (final ch in s.split('')) {
      await set(text + ch);
    }
  }

  /// The whole new text in one update (a paste).
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
    await keys(s);
    return reported;
  }

  Future<int?> pasted(String currency, String s, {int? initial}) async {
    await pump(currency, initial: initial);
    await set(s);
    return reported;
  }
}

Currency cur(String code) => Currencies.of(code);

/// [s] with every character outside printable ASCII as \u{...}, so a
/// failure message shows which mark was pasted.
String _shown(String s) => s.runes
    .map(
      (r) => r < 0x20 || r > 0x7E
          ? '\\u{${r.toRadixString(16)}}'
          : String.fromCharCode(r),
    )
    .join();

void main() {
  // ------------------------------------------ round-5 fixes, verified --

  group('MONEY-R3-05 neighbours: what lies between two numbers', () {
    test('other spaces, invisible marks and signs between digits never '
        'join two numbers', () {
      for (final (s, c) in [
        ('500\u2003210', 'USD'), // em space
        ('500\u3000210', 'JPY'), // ideographic space
        ('500\u205F210', 'USD'), // medium mathematical space
        ('500\u200B210', 'USD'), // zero-width space
        ('500\u000B210', 'USD'), // vertical tab
        ('500\u000C210', 'USD'), // form feed
        ('500\u2028210', 'USD'), // line separator
        ('500;210', 'EUR'),
        ('4, 120', 'USD'),
        ('4: 120', 'EUR'),
        ('4 - 120', 'EUR'),
        ('4 x 120 €', 'EUR'),
        ('4 × 120 €', 'EUR'),
        ('2 * 340', 'USD'),
        ('No. 4 120', 'EUR'),
        ('4 people 120', 'EUR'),
        ('Room 4 120 rand', 'ZAR'),
        ('for 4\u00A0120 €', 'EUR'),
        ('for 4\u202F120 €', 'EUR'),
        ('Dinner for 4 120\u00A0€', 'EUR'),
      ]) {
        final v = parseAmountInput(s, cur(c));
        expect(v, isNull, reason: '"${_shown(s)}" in $c read as $v');
      }
    });

    test('real space groups next to currency words still read', () {
      for (final (s, c, want) in [
        ('4 120 €', 'EUR', 412000),
        ('€ 4 120', 'EUR', 412000),
        ('4 120,50 €', 'EUR', 412050),
        ('4\u202F120 €', 'EUR', 412000),
        ('1\u00A0234\u00A0567,89', 'EUR', 123456789),
        ('4 120 kr', 'SEK', 412000),
        ('kr 4 120', 'SEK', 412000),
        ('4 120 zł', 'PLN', 412000),
        ('4 120 Kč', 'CZK', 412000),
        ('R 4 120', 'ZAR', 412000),
        // A word that is no currency mark is no amount (round 7).
        ("Tisch 4'500 CHF", 'CHF', null),
        ("4'500 CHF", 'CHF', 450000),
      ]) {
        expect(
          parseAmountInput(s, cur(c)),
          want,
          reason: '"${_shown(s)}" in $c',
        );
      }
    });

    test('unknown words after the number, and smaller units, are refused', () {
      for (final (s, c) in [
        ('50 bucks', 'USD'),
        ('5 hundred', 'USD'),
        ('5 dozen', 'USD'),
        ('50 kopecks', 'RUB'),
        ('50 tetri', 'GEL'),
        ('50 agorot', 'ILS'),
        ('50 piastres', 'EGP'),
        ('50 millimes', 'TND'),
        ('50 kuruş', 'TRY'),
        ('50 jiao', 'CNY'),
        ('50 角', 'CNY'),
        ('50 銭', 'JPY'),
        ('50 전', 'KRW'),
        ('50 fils', 'AED'),
        ('1.5 Lakhs', 'INR'),
        ('1.5L', 'INR'),
        ('1,5 Mrd. €', 'EUR'),
        ('2.5k€', 'EUR'),
        ('\u202A2.5k', 'USD'),
      ]) {
        final v = parseAmountInput(s, cur(c));
        expect(v, isNull, reason: '"${_shown(s)}" in $c read as $v');
      }
    });
  });

  group('MONEY-R5-01 neighbours: marks that divide the number', () {
    test('cent, mill, percent, fraction and power marks are refused '
        'wherever they stand', () {
      for (final (s, c) in [
        ('99¢', 'USD'),
        ('¢99', 'USD'),
        ('99 ￠', 'USD'),
        ('99c', 'USD'),
        ('99 c.', 'USD'),
        ('99 cent', 'EUR'),
        ('50 pence', 'GBP'),
        ('50P', 'GBP'),
        ('1/2', 'USD'),
        ('1⁄ 2', 'USD'),
        ('10²', 'USD'),
        ('½', 'USD'),
        ('0.5‰', 'USD'),
        ('15 ٪', 'INR'),
        ('15％', 'INR'),
        ('15 pct', 'INR'),
        ('15 percent', 'INR'),
        ('15 per cent', 'INR'),
        ('15 Prozent', 'EUR'),
        ('15 pour cent', 'EUR'),
      ]) {
        final v = parseAmountInput(s, cur(c));
        expect(v, isNull, reason: '"${_shown(s)}" in $c read as $v');
      }
    });

    test('a percent field takes one sign after the number only', () {
      expect(parsePercent('15%'), 1500);
      expect(parsePercent('15 %'), 1500);
      expect(parsePercent('12.5％'), 1250);
      expect(parsePercent('%15'), isNull);
      expect(parsePercent('15%%'), isNull);
      expect(parsePercent('15‰'), isNull);
      expect(parsePercent('1½'), isNull);
    });

    testWidgets('the amount field refuses unit marks typed or pasted', (
      t,
    ) async {
      final f = _Field(t);
      for (final (c, s) in [
        ('USD', '99 ¢'),
        ('USD', '½'),
        ('GBP', '50 pence'),
        ('INR', '15%'),
        ('EUR', '0,5‰'),
      ]) {
        final v = await f.pasted(c, s);
        expect(v, isNull, reason: '$c "${_shown(s)}" -> $v');
      }
    });
  });

  group('MONEY-R4-04 neighbours: minus forms', () {
    test('hyphens, words, brackets and bidi marks keep the sign', () {
      final inr = cur('INR');
      // Round 7, one strict grammar: only '-' and U+2212 write a minus,
      // first or after a leading currency mark. Every other form is no
      // amount at all, so its sign is never dropped either.
      final minus = RegExp(r'^[-\u2212](₹|Rs\.? ?)?[0-9]|^(₹|Rs\.? ?)[-\u2212][0-9]');
      for (final (s, read) in [
        ('\u201030', -3000),
        ('30\u2010', -3000),
        ('\u201130', -3000),
        ('Minus30', -3000),
        ('MINUS 30', -3000),
        ('minus: 30', -3000),
        ('minus ₹30', -3000),
        ('₹ minus 30', -3000),
        ('Rs minus 30', -3000),
        ('negative 30', -3000),
        ('(₹30)', -3000),
        ('₹(30)', -3000),
        ('( 30 )', -3000),
        ('(1,234.50)', -123450),
        ('\u200E-30', -3000),
        ('\u200F-30', -3000),
        ('−\u200B30', -3000),
        ('+30', 3000),
        ('Rs. 1,200/-', 120000),
      ]) {
        final want = read > 0 || minus.hasMatch(s) ? read : null;
        expect(parseSignedMinor(s, inr), want, reason: '"${_shown(s)}"');
      }
      // Two signs, or a bracket that does not close around the number,
      // cannot be read without guessing.
      for (final s in [
        '- minus 30',
        'minus -30',
        'minus +30',
        '+minus 30',
        '((30))',
        '30 (approx)',
        '(30',
        '30)',
      ]) {
        expect(parseSignedMinor(s, inr), isNull, reason: '"${_shown(s)}"');
      }
      // The amount field never drops a sign it reads.
      for (final s in [
        '\u201030',
        'minus 30',
        '(30)',
        '30\u2010',
        '\u200F-30',
      ]) {
        expect(parseAmountInput(s, inr), isNull, reason: '"${_shown(s)}"');
      }
    });
  });

  group('MONEY-R4-01 neighbours: a separator in a no-decimal currency', () {
    testWidgets('a separator after the whole number holds no amount, with a '
        'comma, in decimal-comma currencies and near the digit limit', (
      t,
    ) async {
      final f = _Field(t);
      for (final (c, s) in [
        ('JPY', '1200.50'),
        ('JPY', '1200,50'),
        ('VND', '50000,00'),
        ('ISK', '1500,5'),
        ('CLP', '15000,50'),
        ('PYG', '15000,50'),
        ('XAF', '1200,50'),
        ('UGX', '1200.50'),
        ('BIF', '1200.50'),
        ('KRW', '15000.000'),
        ('KRW', '15000.0000'),
        ('JPY', '1.200.50'),
        ('JPY', '1,200,5'),
        ('JPY', '12345678901.5'),
        ('JPY', '123456789012.5'),
        ('JPY', '0.5'),
        ('JPY', '00.5'),
        ('JPY', '1200.5.'),
      ]) {
        final v = await f.typed(c, s);
        expect(v, isNull, reason: '$c "$s" held $v');
      }
      // Edit expense: a separator typed after an existing amount.
      for (final (c, s, init) in [
        ('JPY', '.50', 1200),
        ('JPY', ',50', 1200),
        ('JPY', '.5', 1234567),
        ('KRW', '.00', 15000),
      ]) {
        final v = await f.typed(c, s, initial: init);
        expect(v, isNull, reason: '$c $init + "$s" held $v');
      }
    });

    testWidgets('a held amount switched to a currency with decimals reads '
        'as typed, and back again is refused', (t) async {
      final f = _Field(t);
      for (final (c, s, to, want) in [
        ('JPY', '1200.50', 'USD', 120050),
        ('JPY', '1200.50', 'EUR', 120050),
        ('JPY', '1200.5', 'KWD', 1200500),
        ('JPY', '1200.50', 'KRW', null),
        ('USD', '1,200.50', 'JPY', null),
        ('EUR', '1200,50', 'JPY', null),
        ('KWD', '1.250', 'JPY', null),
        ('TND', '1,250', 'USD', null),
      ]) {
        await f.pump(c);
        await f.keys(s);
        await f.switchTo(to);
        expect(f.reported, want, reason: '$c "$s" -> $to "${f.text}"');
      }
    });
  });

  // ------------------------------------- still open (skipped repros) --

  group('QA MONEY-R3-05 (reopened)', () {
    test(
      'QA MONEY-R3-05: a multiplier after a currency symbol, a currency '
      'word or an invisible mark is not dropped',
      () {
        // _hasUnknownWordAfter looks only at the first word right after the
        // last digit. A symbol or currency word in between ("€", "EUR",
        // "Rs") or an invisible mark (zero-width space, word joiner, soft
        // hyphen, the bidi marks PDFs carry) hides the multiplier, and the
        // number is read without it.
        for (final (s, c, dropped) in [
          ('1.5 € million', 'EUR', 150),
          ('1.5 EUR million', 'EUR', 150),
          ('2,5 € Mio', 'EUR', 250),
          ('2,5€ Mio.', 'EUR', 250),
          ('2,5 € Mrd.', 'EUR', 250),
          ('1.2 \$M', 'USD', 120),
          ('2.5\$k', 'USD', 250),
          ('2.5 USD m', 'USD', 250),
          ('5 Rs lakh', 'INR', 500),
          ('5 rupees lakh', 'INR', 500),
          ('5₹ lakh', 'INR', 500),
          ('5 원 만', 'KRW', 5),
          ('2.5\u200Bk', 'USD', 250),
          ('2.5\u2060k', 'USD', 250),
          ('2.5\u00ADk', 'USD', 250),
          ('2.5\u200Ek', 'USD', 250),
          ('2.5\u202Ck', 'USD', 250),
        ]) {
          final v = parseAmountInput(s, cur(c));
          expect(v, isNot(dropped), reason: '"${_shown(s)}" in $c read as $v');
        }
      },
    );

    testWidgets(
      'QA MONEY-R3-05: "1.5 € million" pasted into the amount field is not '
      '€1.50',
      (t) async {
        final f = _Field(t);
        expect(await f.pasted('EUR', '1.5 € million'), isNot(150));
        expect(await f.pasted('INR', '5 Rs lakh'), isNot(500));
      },
    );
  });

  group('QA MONEY-R4-04 (reopened)', () {
    test(
      'QA MONEY-R4-04: a minus written in full-width brackets, as a heavy '
      'or modifier minus, as a Japanese triangle or as "less" is not read '
      'as a plus',
      () {
        // _minusChars and the bracket check know only ASCII "(" ")" and a
        // list of dashes; anything else before the number is decoration.
        // Japanese accounting writes a negative as ▲ or △; a CJK keyboard
        // types full-width brackets; emoji keyboards offer \u2796.
        for (final (s, c, plus) in [
          ('（30）', 'JPY', 30),
          ('（1,200）', 'JPY', 1200),
          ('▲30', 'JPY', 30),
          ('▲ 1,200', 'JPY', 1200),
          ('△30', 'JPY', 30),
          ('\u279630', 'INR', 3000),
          ('\u02D730', 'INR', 3000),
          ('\uFE5830', 'INR', 3000),
          ('less 30', 'INR', 3000),
          ('Less: 30', 'INR', 3000),
        ]) {
          final v = parseSignedMinor(s, cur(c));
          expect(v, isNot(plus), reason: '"${_shown(s)}" in $c -> $v');
          // The amount field never drops a sign, so it refuses them too.
          final p = parseAmountInput(s, cur(c));
          expect(p, isNot(plus), reason: 'amount "${_shown(s)}" -> $p');
        }
      },
    );

    testWidgets(
      'QA MONEY-R4-04: a full-width bracket or heavy minus pasted into an '
      'adjustment is not saved as a plus',
      (tester) async {
        qaPhone(tester);
        final w = await RealWorld.create(name: 'Arjun');
        final gid = await openAddExpense(tester, w);
        await typeAmountAndDescription(tester, '270', 'Drinks');
        await qaTap(tester, find.text(KitStrings.splitAdjust));
        final priya = splitInput(S.adjustmentOf('Priya'));
        for (final s in ['（30）', '\u279630', 'less 30']) {
          await tester.enterText(priya, '');
          await tester.enterText(priya, s);
          await tester.pump();
          final text = tester.widget<TextField>(priya).controller!.text;
          if (saveEnabled(tester)) {
            expect(
              parseSignedMinor(text, cur('INR')),
              -3000,
              reason: '"${_shown(s)}" became "$text"',
            );
          }
        }
        expect(w.group(gid).liveExpenses, isEmpty);
        await w.shutdown(tester);
      },
    );
  });

  group('QA MONEY-R4-01 (reopened)', () {
    testWidgets(
      'QA MONEY-R4-01: a separator typed first in a no-decimal currency is '
      'not dropped before the digits after it',
      (t) async {
        // "0.50" now holds no amount, but ".50" (the same text without the
        // zero, as "$.50" is written) drops the '.', and the "50" typed
        // next is ¥50. Pasting ".50" is refused.
        final f = _Field(t);
        for (final (c, s) in [
          ('JPY', '.50'),
          ('JPY', ',50'),
          ('JPY', '.5'),
          ('KRW', '.50'),
          ('VND', ',50'),
        ]) {
          final pasted = await f.pasted(c, s);
          final typed = await f.typed(c, s);
          expect(typed, pasted, reason: '$c "$s" typed $typed, pasted $pasted');
        }
      },
    );
  });

  group('QA MONEY-R6-01', () {
    test(
      'QA MONEY-R6-01: a dot-grouped number whose last group is short is '
      'not read as a grouping',
      () {
        // normalizeAmountInput, dots only: with two dots or more, the last
        // group may have one to three digits (the "being typed" rule), even
        // for a paste and without [typing]. Commas refuse the same text
        // ("1,200,50" is null). "1.200.50" is 1.200,50 typed with a dot for
        // the comma; it reads as 120,050.
        for (final (s, c, joined) in [
          ('1.200.50', 'EUR', 12005000),
          ('1.200.50 €', 'EUR', 12005000),
          ('€1.200.50', 'EUR', 12005000),
          ('1.200.5', 'EUR', 1200500),
          ('1.200.50', 'USD', 12005000),
          ('1.234.56', 'GBP', 12345600),
          ('12.345.6', 'INR', 12345600),
          ('1.200.5', 'JPY', 12005),
        ]) {
          final v = parseAmountInput(s, cur(c));
          expect(v, isNot(joined), reason: '"$s" in $c read as $v');
        }
        // As commas already are.
        expect(parseAmountInput('1,200,50', cur('USD')), isNull);
      },
    );

    testWidgets(
      'QA MONEY-R6-01: a short last dot group typed, pasted or carried over '
      'a currency change holds no amount',
      (t) async {
        final f = _Field(t);
        // EUR typed key by key: "1.200" holds no amount (like "10.000"),
        // then "1.200.5" is held as €12,005 and "1.200.50" as €120,050.
        expect(await f.typed('EUR', '1.200.50'), anyOf(isNull, 120050));
        expect(await f.pasted('EUR', '1.200.50'), anyOf(isNull, 120050));
        expect(await f.pasted('USD', '1.200.50'), anyOf(isNull, 120050));
        // JPY typed "1.200.5" holds no amount; pasted it is ¥12,005.
        expect(await f.pasted('JPY', '1.200.5'), isNull);
        // Held as typed in JPY, then the currency is changed to USD:
        // $12,005.
        await f.pump('JPY');
        await f.keys('1.200.5');
        expect(f.reported, isNull);
        await f.switchTo('USD');
        expect(f.reported, anyOf(isNull, 120050), reason: f.text);
      },
    );

    testWidgets(
      'QA MONEY-R6-01: on Add expense, a pasted "1.200.50" is not a total of '
      '1,20,050',
      (tester) async {
        qaPhone(tester);
        final w = await RealWorld.create(name: 'Arjun');
        await openAddExpense(tester, w);
        await typeAmountAndDescription(tester, '1.200.50', 'Dinner');
        if (saveEnabled(tester)) {
          final amount = tester
              .widget<TextField>(find.byType(TextField).at(0))
              .controller!
              .text;
          expect(
            parseAmountInput(amount, cur('INR')),
            isNot(12005000),
            reason: 'amount field "$amount"',
          );
        }
        await w.shutdown(tester);
      },
    );
  });
}
