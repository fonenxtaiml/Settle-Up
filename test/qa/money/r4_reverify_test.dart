// QA MONEY round 4: reverifies the round-3 amount reading fixes
// (MONEY-R2-05, MONEY-R3-01..06) with neighbouring inputs, on the amount
// field and on the real Add expense screen, and holds repro tests for the
// defects found in this round (skipped with their ids).
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
import 'amount_parsing_test.dart' show typeInto;

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

  /// Keys typed one at a time at the end of the text.
  Future<void> keys(String s) async {
    for (final ch in s.split('')) {
      await set(text + ch);
    }
  }

  /// The whole new text in one update: a select-all paste, or a paste over
  /// part of the text (the harness sends the text after the paste).
  Future<void> set(String s) async {
    _state.updateEditingValue(
      TextEditingValue(
        text: s,
        selection: TextSelection.collapsed(offset: s.length),
      ),
    );
    await t.pump();
  }

  bool get flagged => find.textContaining('decimal').evaluate().isNotEmpty;
}

Currency cur(String code) => Currencies.of(code);

void main() {
  // ------------------------------------------ round-3 fixes, verified --

  group('MONEY-R2-05 / R3-01 neighbours: paste over an amount', () {
    testWidgets('extra decimals pasted over any text are refused and said', (
      t,
    ) async {
      final f = _Field(t);
      for (final (c, before, paste) in [
        ('EUR', '1', '1.234'),
        ('EUR', '4', '1.234'),
        ('EUR', '1.2', '1.234'),
        ('INR', '12', '12.345'),
        ('USD', '5', '12.345'),
        ('KWD', '1', '1.2345'),
        ('JPY', '1', '1.5'),
      ]) {
        await f.pump(c);
        await f.keys(before);
        final shown = f.text;
        final held = f.reported;
        await f.set(paste);
        expect(f.text, shown, reason: '$c "$paste" over "$before"');
        expect(f.reported, held);
        expect(f.flagged, isTrue, reason: '$c "$paste" says why');
      }
      // One more digit than the shown text (a paste of "12.345" over
      // "12.34" looks like the key "5"): refused, the amount is unchanged.
      await f.pump('USD');
      await f.keys('12.34');
      await f.set('12.345');
      expect(f.text, '12.34');
      expect(f.reported, 1234);
      // Over an amount already saved (Edit expense, Settle part).
      await f.pump('USD', initial: 100);
      await f.set('1.234');
      expect(f.text, '1');
      expect(f.flagged, isTrue);
    });

    testWidgets('a grouped amount pasted over another is read as written', (
      t,
    ) async {
      final f = _Field(t);
      for (final (c, initial, paste, want) in [
        ('IDR', 150000000, '2,000,000', 200000000),
        ('IDR', 150000000, '2.000.000', 200000000),
        ('JPY', 1500000, '2,000,000', 2000000),
        ('VND', 1500000, '2.000.000', 2000000),
        ('USD', 120000, '1,250,000', 125000000),
        ('USD', 123456, '1,234,567', 123456700),
        ('USD', 123450, '1,234', 123400),
        ('EUR', 100000, '2,000', 200000),
        ('EUR', 150, '2,50', 250),
        ('INR', 1200, '1,00,000', 10000000),
        ('USD', 123400, '5', 500),
      ]) {
        await f.pump(c, initial: initial);
        await f.set(paste);
        expect(f.reported, want, reason: '$c "$paste" over $initial');
      }
      // Typed first, then a paste that shares its first characters.
      await f.pump('INR');
      await f.keys('12');
      await f.set('1234');
      expect(f.reported, 123400);
      expect(f.text, '1,234');
    });
  });

  group('MONEY-R3-02 neighbours: dot-grouped thousands typed', () {
    testWidgets('no decimals: the dot groups', (t) async {
      for (final c in ['VND', 'CLP', 'KRW', 'ISK', 'JPY', 'PYG']) {
        expect(await typeInto(t, c, '50.000'), 50000, reason: c);
        expect(await typeInto(t, c, '1.000.000'), 1000000, reason: c);
      }
    });

    testWidgets('a dot-grouping two-decimal currency flags the third digit', (
      t,
    ) async {
      final f = _Field(t);
      for (final c in ['EUR', 'IDR', 'HUF', 'COP', 'UZS']) {
        await f.pump(c);
        await f.keys('50.000');
        expect(f.text, '50.000', reason: c);
        expect(f.reported, isNull, reason: c);
        expect(f.flagged, isTrue, reason: c);
        // A decimal comma after it makes the dot a grouping.
        await f.keys(',5');
        expect(f.reported, 5000050, reason: c);
        expect(f.flagged, isFalse, reason: c);
      }
      // Elsewhere the third digit is refused.
      expect(await typeInto(t, 'USD', '10.000'), 1000);
      expect(await typeInto(t, 'INR', '12.345'), 1234);
    });
  });

  group('MONEY-R3-03 neighbours: one separator after the decimal point', () {
    testWidgets('three-decimal currencies and a typed decimal comma', (
      t,
    ) async {
      for (final c in ['TND', 'KWD', 'BHD', 'OMR', 'JOD']) {
        // A comma after "1,250" never makes it a thousand times larger
        // (QA MONEY-R3-03 reopened). Where "1,250," is on its way to
        // "1,250,000" (KWD) it holds no amount until then (round 7).
        expect(
          await typeInto(t, c, '1,250,'),
          anyOf(isNull, parseAmountInput('1,250', cur(c))),
          reason: c,
        );
        // "1,250" is read as every input reads it in that currency (1.250
        // DT, 1,250 KD: QA MONEY-R3-03 reopened); a point after it changes
        // nothing.
        expect(
          await typeInto(t, c, '1,250.'),
          parseAmountInput('1,250', cur(c)),
          reason: c,
        );
        expect(await typeInto(t, c, '1.250,'), 1250, reason: c);
        expect(await typeInto(t, c, '1.250.'), 1250, reason: c);
      }
      expect(await typeInto(t, 'USD', '1,23,'), 123);
      expect(await typeInto(t, 'EUR', '1,25,'), 125);
      expect(await typeInto(t, 'EUR', '1,25.'), 125);
      final f = _Field(t);
      for (final c in ['KWD', 'TND']) {
        await f.pump(c, initial: 1250);
        await f.keys(',');
        await f.keys('.');
        expect(f.text, '1.250', reason: c);
      }
    });

    testWidgets('INR lakh typed through a short comma group still works', (
      t,
    ) async {
      // "1,00" shows 1.00 until the next comma makes it a lakh on its way;
      // engineering kept this so "1,00,000" can be typed key by key.
      expect(await typeInto(t, 'INR', '1,00,000'), 10000000);
      expect(await typeInto(t, 'INR', '10,00,000'), 100000000);
    });
  });

  group('MONEY-R3-04 neighbours: a point right before the digits', () {
    test('after a currency word or symbol', () {
      expect(parseAmountInput('USD .50', cur('USD')), 50);
      expect(parseAmountInput(r'$.50', cur('USD')), 50);
      expect(parseAmountInput(r'$ .50', cur('USD')), 50);
      expect(parseAmountInput('Rs. .50', cur('INR')), 50);
      expect(parseAmountInput('EUR ,50', cur('EUR')), 50);
      expect(parseAmountInput('€ ,50', cur('EUR')), 50);
      expect(parseAmountInput('Rs.0.50', cur('INR')), 50);
      // Word dots are still dropped (R2-02).
      expect(parseAmountInput('Rs. 500', cur('INR')), 50000);
      expect(parseAmountInput('500 Rs.', cur('INR')), 50000);
      expect(parseSignedMinor('-USD .50', cur('USD')), -50);
    });

    testWidgets('pasted into the amount field', (t) async {
      expect(await typeInto(t, 'USD', 'USD .50', paste: true), 50);
      expect(await typeInto(t, 'EUR', 'EUR ,50', paste: true), 50);
      expect(await typeInto(t, 'INR', 'Rs. .50', paste: true), 50);
    });
  });

  group('MONEY-R3-05 neighbours: the reader refuses joined numbers', () {
    test('several numbers or a listed multiplier', () {
      for (final s in [
        'Rs 500 paid at Cafe 21',
        'Dinner for 4: 1,200',
        '2.5k',
        '2.5 K',
        '1.5 lakh',
        r'$1.2M',
        '1e3',
        '1E3',
        '3 crore',
        '2,5 Mio.',
        '10-12',
        '12/2',
      ]) {
        expect(parseAmountInput(s, cur('INR')), isNull, reason: s);
      }
      // Still read: decoration around one number.
      expect(parseAmountInput('Rs. 1,200/-', cur('INR')), 120000);
      expect(parseAmountInput('1.250,- €', cur('EUR')), 125000);
      expect(parseAmountInput('50 kr', cur('SEK')), 5000);
      expect(parseAmountInput("1'234.50", cur('CHF')), 123450);
      expect(parseAmountInput('1 234,50', cur('EUR')), 123450);
    });
  });

  group('MONEY-R3-06 neighbours: TND "1,250" in every reader', () {
    testWidgets('typed, pasted, split, signed and the payer sheet reader', (
      t,
    ) async {
      final tnd = cur('TND');
      expect(await typeInto(t, 'TND', '1,250'), 1250);
      expect(await typeInto(t, 'TND', '1,250 DT', paste: true), 1250);
      expect(await typeInto(t, 'TND', 'DT 0,500', paste: true), 500);
      expect(parseAmountInput('1,250', tnd), 1250);
      expect(parseAmountInput('1,25', tnd), 1250);
      expect(parseSignedMinor('-1,250', tnd), -1250);
      expect(parseSignedMinor('+1,250', tnd), 1250);
      // Both separators: the last one is the decimal point. TND groups
      // with dots or spaces, so its comma never groups (round 7).
      expect(parseAmountInput('1.250,500', tnd), 1250500);
      expect(parseAmountInput('1,250.500', tnd), isNull);
      // KWD writes a dot: its "1,250" is a thousand two hundred and fifty.
      expect(parseAmountInput('1,250', cur('KWD')), 1250000);
      expect(await typeInto(t, 'KWD', '1,250', paste: true), 1250000);
    });
  });

  // ------------------------------------------------ round-4 findings --

  group('QA MONEY-R3-03 (reopened)', () {
    testWidgets(
      'QA MONEY-R3-03: a "," typed after a three-digit decimal comma in KWD, '
      'BHD, OMR or JOD does not turn it into a thousand',
      (t) async {
        // The field shows typed "1,250" as 1.250 (the comma as decimal
        // point); one more "," makes it 1,250 dinars. TND is fixed; the
        // dot-decimal three-digit currencies take the second comma as a
        // grouping on its way.
        for (final c in ['KWD', 'BHD', 'OMR', 'JOD']) {
          final shown = await typeInto(t, c, '1,250');
          // Whatever the field reads "1,250" as, it is the reading every
          // other input on the screen uses (split fields, payer sheet,
          // paste): one meaning per currency (R3-06).
          expect(shown, parseAmountInput('1,250', cur(c)), reason: c);
          // And a "," after it never multiplies the amount by 1000.
          final after = await typeInto(t, c, '1,250,');
          expect(after, anyOf(isNull, shown), reason: '$c "1,250,"');
        }
      },
      // QA MONEY-R3-03 (reopened)
    );
  });

  group('QA MONEY-R3-05 (reopened)', () {
    testWidgets(
      'QA MONEY-R3-05: a split field does not join the numbers of a pasted '
      'text either',
      (tester) async {
        // The split fields keep only [0-9.,] (FilteringTextInputFormatter)
        // before parseAmountInput reads the text, so the R3-05 guards never
        // see the words: "Rs 100 at table 2" arrives as "1002".
        qaPhone(tester);
        final w = await RealWorld.create(name: 'Arjun');
        await openAddExpense(tester, w);
        await typeAmountAndDescription(tester, '1202', 'Dinner');
        await qaTap(tester, find.text(KitStrings.splitExact));
        await tester.enterText(splitInput(S.amountOf('You')), '100');
        await tester.enterText(splitInput(S.amountOf('Rahul')), '100');
        await tester.enterText(
          splitInput(S.amountOf('Priya')),
          'Rs 100 at table 2',
        );
        await tester.pump();
        // Priya's 100 (or nothing) never balances 1,202: Save stays off.
        expect(saveEnabled(tester), isFalse);
        await w.shutdown(tester);
      },
      // QA MONEY-R3-05 (reopened)
    );

    test(
      'QA MONEY-R3-05: space-apart numbers and unlisted multipliers are not '
      'read as one amount',
      () {
        for (final (s, c) in [
          // Digit runs apart by a space are joined: 4 and 1,200 -> 41,200.
          ('Dinner for 4 1,200', 'INR'),
          ('Rs 500 21', 'INR'),
          ('Table 12 340', 'USD'),
          // Multiplier words outside the list are dropped.
          ('1.5 mln', 'EUR'),
          ('1.2 bln', 'USD'),
          ('2,5 tys.', 'PLN'),
          ('1,5 тыс', 'RUB'),
          ('2 млн', 'RUB'),
          ('5万', 'JPY'),
          ('3千円', 'JPY'),
          ('5만원', 'KRW'),
        ]) {
          final v = parseAmountInput(s, cur(c));
          expect(v, isNull, reason: '"$s" in $c read as $v');
        }
      },
      // QA MONEY-R3-05 (reopened)
    );
  });

  group('QA MONEY-R4-01', () {
    testWidgets(
      'QA MONEY-R4-01: a short dot group typed in a no-decimal currency is not '
      'held as a 100x amount',
      (t) async {
        // Paste and the split fields refuse "800.50" in JPY; typed key by
        // key the field reads the dot as grouping on its way and holds
        // ¥80,050 with Save enabled.
        expect(await typeInto(t, 'JPY', '800.50'), anyOf(isNull, 800));
        expect(await typeInto(t, 'KRW', '5.00'), anyOf(isNull, 5));
        expect(await typeInto(t, 'VND', '50.00'), anyOf(isNull, 50));
        expect(await typeInto(t, 'JPY', '12.5'), anyOf(isNull, 12));
        expect(parseAmountInput('800.50', cur('JPY')), isNull);
      },
      // QA MONEY-R4-01
    );
  });

  group('QA MONEY-R4-02', () {
    testWidgets(
      'QA MONEY-R4-02: TND text the amount field shows is read back as the '
      'same amount',
      (t) async {
        final f = _Field(t);
        // The field writes 1,250 DT as "1,250" but reads a pasted "1,250"
        // as 1.250 DT.
        for (final (typed, minor) in [
          ('1250', 1250000),
          ('12500', 12500000),
          ('123456', 123456000),
        ]) {
          await f.pump('TND');
          await f.keys(typed);
          expect(f.reported, minor);
          final shown = f.text;
          await f.pump('TND');
          await f.set(shown);
          expect(
            f.reported,
            anyOf(isNull, minor),
            reason: 'TND "$shown" pasted back',
          );
        }
        // Edit expense 12,345 DT: select "34", paste "99". The field writes
        // TND thousands with a thin space (a comma there is the decimal
        // comma), so its own text reads back as written.
        await f.pump('TND', initial: 12345000);
        expect(f.text, '12\u2009345');
        await f.set('12\u2009995');
        expect(f.reported, anyOf(isNull, 12995000));
      },
      // QA MONEY-R4-02
    );
  });

  group('QA MONEY-R4-03', () {
    testWidgets(
      'QA MONEY-R4-03: "Rs. 50" pasted into a split field is not read as '
      '₹0.50',
      (tester) async {
        // The split field keeps only [0-9.,], so "Rs. 50" and "Rs.50" reach
        // the reader as ".50": the word dot becomes the decimal point.
        qaPhone(tester);
        final w = await RealWorld.create(name: 'Arjun');
        await openAddExpense(tester, w);
        await typeAmountAndDescription(tester, '200.50', 'Snacks');
        await qaTap(tester, find.text(KitStrings.splitExact));
        await tester.enterText(splitInput(S.amountOf('You')), '100');
        await tester.enterText(splitInput(S.amountOf('Rahul')), '100');
        await tester.enterText(splitInput(S.amountOf('Priya')), 'Rs. 50');
        await tester.pump();
        // Priya's ₹50 is ₹49.50 too much; ₹0.50 would balance.
        expect(saveEnabled(tester), isFalse);
        await tester.enterText(splitInput(S.amountOf('Priya')), 'Rs.50');
        await tester.pump();
        expect(saveEnabled(tester), isFalse);
        await w.shutdown(tester);
      },
      // QA MONEY-R4-03
    );
  });

  group('QA MONEY-R4-04', () {
    testWidgets(
      'QA MONEY-R4-04: a minus written as a dash, in brackets or after the '
      'number is not saved as a plus',
      (tester) async {
        qaPhone(tester);
        final w = await RealWorld.create(name: 'Arjun');
        final gid = await openAddExpense(tester, w);
        await typeAmountAndDescription(tester, '270', 'Drinks');
        await qaTap(tester, find.text(KitStrings.splitAdjust));
        for (final s in ['–30', '(30)', '30-']) {
          await tester.enterText(splitInput(S.adjustmentOf('Priya')), s);
          await tester.pump();
          // -30 for Priya: 70 / 100 / 100 of 270... a +30 makes Priya 110.
          if (saveEnabled(tester)) {
            expect(
              parseSignedMinor(
                tester
                    .widget<TextField>(splitInput(S.adjustmentOf('Priya')))
                    .controller!
                    .text,
                cur('INR'),
              ),
              -3000,
              reason: '"$s"',
            );
          }
        }
        expect(w.group(gid).liveExpenses, isEmpty);
        await w.shutdown(tester);
      },
      // QA MONEY-R4-04
    );
  });
}
