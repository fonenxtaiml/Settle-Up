// QA MONEY round 3: reverifies the round-2 amount reading fixes
// (MONEY-R2-01..05) with neighbouring inputs, and holds repro tests for the
// defects found in this round (skipped with their ids).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/format/amount_input.dart';
import 'package:settle_up/ui/screens/expense/split_draft.dart';
import 'package:settle_up/ui/widgets/amount_field.dart';

import 'amount_parsing_test.dart' show typeInto;
import 'money_harness.dart';

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
      await _set(text + ch);
    }
  }

  /// Select all, then paste [s] (or type over the selection).
  Future<void> replaceAll(String s) => _set(s);

  Future<void> _set(String s) async {
    _state.updateEditingValue(
      TextEditingValue(
        text: s,
        selection: TextSelection.collapsed(offset: s.length),
      ),
    );
    await t.pump();
  }
}

void main() {
  // ------------------------------------------ round-2 fixes, verified --

  group('MONEY-R2-01 neighbours: comma groups typed key by key', () {
    testWidgets('USD, INR lakh and crore, JPY and KWD with decimals', (
      t,
    ) async {
      expect(await typeInto(t, 'USD', '1,234,567.89'), 123456789);
      expect(await typeInto(t, 'INR', '12,34,567'), 123456700);
      expect(await typeInto(t, 'INR', '1,00,00,000'), 1000000000);
      expect(await typeInto(t, 'INR', '1,00,000.50'), 10000050);
      expect(await typeInto(t, 'KWD', '1,234,567.125'), 1234567125);
      expect(await typeInto(t, 'JPY', '99,999,999,999'), Money.maxMinor);
      expect(await typeInto(t, 'EUR', '1.234.567,89'), 123456789);
    });

    testWidgets('a group of the wrong length is refused, never re-read', (
      t,
    ) async {
      // The fourth digit after the second comma is refused.
      expect(await typeInto(t, 'USD', '1,234,5678'), 123456700);
      // "1,2," cannot be a grouping: the second comma is refused.
      expect(await typeInto(t, 'INR', '1,2,3'), 123);
    });

    testWidgets('backspace into a group and retype', (t) async {
      final f = _Field(t);
      await f.pump('USD');
      await f.keys('1,234,567');
      for (var i = 0; i < 3; i++) {
        await f.replaceAll(f.text.substring(0, f.text.length - 1));
      }
      expect(f.reported, 123400);
      await f.keys('890');
      expect(f.text, '1,234,890');
      expect(f.reported, 123489000);
    });

    testWidgets('over the cap stays on screen and reports nothing', (t) async {
      expect(await typeInto(t, 'USD', '1,000,000,000'), isNull);
      expect(await typeInto(t, 'USD', '999,999,999.99'), Money.maxMinor);
      expect(await typeInto(t, 'KWD', '99,999,999.999'), Money.maxMinor);
      expect(await typeInto(t, 'INR', '99,99,99,999.99'), Money.maxMinor);
    });
  });

  group('MONEY-R2-02 neighbours: word dots', () {
    test('lead-in and trailing words', () {
      final inr = Currencies.of('INR');
      for (final s in [
        'Rs. 500',
        'Rs.500',
        '500 Rs.',
        'INR 500',
        '₹ 500.',
      ]) {
        expect(parseAmountInput(s, inr), 50000, reason: s);
      }
      expect(parseAmountInput('Rs. 1,234.50', inr), 123450);
      expect(parseAmountInput('Rs.1,00,000', inr), 10000000);
      // Round 7, one strict grammar: a dot apart from the mark, and a word
      // that is no currency mark, are no amount.
      expect(parseAmountInput('Rs . 500', inr), isNull);
      expect(parseAmountInput('approx. 300', inr), isNull);
    });
  });

  group('MONEY-R2-03 neighbours: a zero first group never groups', () {
    test('parse and signed parse', () {
      final kwd = Currencies.of('KWD');
      final usd = Currencies.of('USD');
      expect(parseAmountInput('0,5', kwd), 500);
      expect(parseSignedMinor('-0,500', kwd), -500);
      expect(parseAmountInput('01,500', usd), isNull);
      expect(parseAmountInput('0,500,000', usd), isNull);
    });

    testWidgets('typed in a two-decimal currency the third digit is refused', (
      t,
    ) async {
      expect(await typeInto(t, 'USD', '0,500'), 50);
      expect(await typeInto(t, 'EUR', '0,500'), 50);
      expect(await typeInto(t, 'TND', ',250'), 250);
    });
  });

  group('MONEY-R2-04 neighbours: the shown decimal comma stays one', () {
    testWidgets('three-decimal currencies and the fourth digit', (t) async {
      // BHD writes a dot: "1,250" is read as every other input reads it
      // (1,250 BD, QA MONEY-R3-03 reopened), and a fourth digit after the
      // comma is refused.
      final bhd = parseAmountInput('1,250', Currencies.of('BHD'));
      expect(bhd, 1250000);
      expect(await typeInto(t, 'BHD', '1,250'), bhd);
      expect(await typeInto(t, 'BHD', '1,2500'), bhd);
      expect(await typeInto(t, 'TND', '1,2505'), 1250);
      // EUR: neither a third digit nor a second comma is taken.
      expect(await typeInto(t, 'EUR', '12,50,'), 1250);
    });
  });

  group('MONEY-R2-05 neighbours: paste into an empty field', () {
    testWidgets('extra decimals are refused in every currency kind', (t) async {
      expect(await typeInto(t, 'USD', '1,234.567', paste: true), isNull);
      expect(await typeInto(t, 'KWD', '1.2345', paste: true), isNull);
      expect(await typeInto(t, 'JPY', '1.5', paste: true), isNull);
      expect(find.text('Enter a whole amount, with no decimals'), findsOne);
    });
  });

  group('Money.maxMinor lift (UIFLOW-R2-04) through the ledger', () {
    test(
      'multi-payer, pairwise, settle and two currencies at the cap',
      () async {
        for (final simplify in [true, false]) {
          final p = await QaPhone.create();
          final t = await p.group(['Sam', 'Priya', 'Dev'], simplify: simplify);
          final g = t.g;
          final ids = t.m.values.toList()..sort();
          const max = Money.maxMinor;
          // Two payers by percent, owers by shares 1000:1:1:1.
          await p.add(
            g,
            total: max,
            currency: 'IDR',
            paidBy: spec(SplitMethod.percent, {ids[0]: 3333, ids[1]: 6667}),
            owedBy: spec(SplitMethod.shares, {
              ids[0]: 1000,
              ids[1]: 1,
              ids[2]: 1,
              ids[3]: 1,
            }),
          );
          // Same in KWD and JPY, equal among payers, adjustment owers.
          for (final cur in ['KWD', 'JPY']) {
            await p.add(
              g,
              total: max,
              currency: cur,
              paidBy: eq([ids[2], ids[3]]),
              owedBy: spec(SplitMethod.adjustment, {
                ids[0]: -(max ~/ 4),
                ids[1]: max ~/ 4,
                ids[2]: 0,
                ids[3]: 0,
              }),
            );
          }
          expectMoneyInvariants(p, reason: 'cap, simplify $simplify');
          for (final tr in p.transfers(g)) {
            expect(tr.amount, inInclusiveRange(1, max));
          }
          // Settle every suggested transfer: everything goes to zero.
          for (final tr in List.of(p.transfers(g))) {
            await p.pay(
              g,
              from: tr.from,
              to: tr.to,
              amount: tr.amount,
              currency: tr.currency,
            );
          }
          expectMoneyInvariants(p, reason: 'settled, simplify $simplify');
          expect(p.transfers(g), isEmpty);
          for (final byMember in p.nets(g).values) {
            expect(byMember.values.every((v) => v == 0), isTrue);
          }
          await p.dispose();
        }
      },
    );
  });

  // ------------------------------------------------ round-3 findings --

  group('QA MONEY-R2-05 (reopened)', () {
    testWidgets(
      'QA MONEY-R2-05: a paste over text already in the field is not '
      'silently cut either',
      (t) async {
        final f = _Field(t);
        // The field shows "1" (or "4", or "12"); the user selects it all
        // and pastes. Old and new text share a first or last character, so
        // the paste is taken for an edit and cut to the currency.
        for (final (cur, before, paste, cut) in [
          ('EUR', '1', '1.234', 123),
          ('EUR', '4', '1.234', 123),
          ('INR', '12', '12.345', 1234),
          ('USD', '5', '12.345', 1234),
        ]) {
          await f.pump(cur);
          await f.keys(before);
          await f.replaceAll(paste);
          expect(f.reported, isNot(cut), reason: '$cur "$paste" over $before');
          expect(f.text, isNot(AmountField.textFor(cut, Currencies.of(cur))));
        }
        // An existing amount (Edit expense, Settle part, Edit payment).
        await f.pump('USD', initial: 100);
        await f.replaceAll('1.234');
        expect(f.reported, isNot(123));
      },
    );
  });

  group('QA MONEY-R3-01', () {
    testWidgets(
      'QA MONEY-R3-01: pasting a grouped amount over an existing one is never '
      'read as a 1000x smaller amount',
      (t) async {
        final f = _Field(t);
        for (final (cur, initial, paste, want) in [
          ('IDR', 150000000, '2,000,000', 200000000),
          ('JPY', 1500000, '2,000,000', 2000000),
          ('USD', 120000, '1,250,000', 125000000),
          ('USD', 123456, '1,234,567', 123456700),
        ]) {
          await f.pump(cur, initial: initial);
          await f.replaceAll(paste);
          expect(
            f.reported,
            anyOf(isNull, want),
            reason: '$cur "$paste" over ${f.text}',
          );
        }
        // Same with an amount the user typed first.
        await f.pump('IDR');
        await f.keys('1500000');
        await f.replaceAll('2,000,000');
        expect(f.reported, anyOf(isNull, 200000000));
      },
    );
  });

  group('QA MONEY-R3-02', () {
    testWidgets(
      'QA MONEY-R3-02: a dot-grouped thousand typed key by key is never kept '
      'as a 1000x smaller amount',
      (t) async {
        // Vietnamese, Chileans, Indonesians and most of Europe write a
        // thousand as "50.000". A zero-decimal currency can never read the
        // dot as a decimal point; a two-decimal one must not hide the third
        // digit and keep 50.00.
        expect(await typeInto(t, 'VND', '50.000'), anyOf(isNull, 50000));
        expect(await typeInto(t, 'CLP', '50.000'), anyOf(isNull, 50000));
        expect(await typeInto(t, 'IDR', '50.000'), anyOf(isNull, 5000000));
        expect(await typeInto(t, 'EUR', '10.000'), anyOf(isNull, 1000000));
      },
    );
  });

  group('QA MONEY-R3-03', () {
    testWidgets(
      'QA MONEY-R3-03: a "," or "." typed after a three-digit decimal comma '
      'does not turn it into a thousand',
      (t) async {
        // After "1,250" the field shows "1.250" (R2-04); one more separator
        // must not make it 1,250 dinars.
        expect(await typeInto(t, 'TND', '1,250,'), anyOf(isNull, 1250));
        expect(await typeInto(t, 'TND', '1,250.'), anyOf(isNull, 1250));
        // KWD "1,250" is 1,250 KD as typed (QA MONEY-R3-03 reopened); the
        // point after it is its decimal point and changes nothing.
        expect(
          await typeInto(t, 'KWD', '1,250.'),
          await typeInto(t, 'KWD', '1,250'),
        );
        // An existing KWD 1.250 with a comma typed at its end.
        final f = _Field(t);
        await f.pump('KWD', initial: 1250);
        await f.keys(',');
        expect(f.reported, anyOf(isNull, 1250));
      },
    );
  });

  group('QA MONEY-R3-04', () {
    test(
      'QA MONEY-R3-04: a decimal point after a currency word is still the '
      'decimal point',
      () {
        // Before the R2-02 fix these read as 0.50 (or were refused); the
        // lead-in rule now drops the point and reads 50.
        expect(
          parseAmountInput('USD .50', Currencies.of('USD')),
          anyOf(isNull, 50),
        );
        expect(
          parseAmountInput('Rs. .50', Currencies.of('INR')),
          anyOf(isNull, 50),
        );
        expect(
          parseAmountInput('EUR ,50', Currencies.of('EUR')),
          anyOf(isNull, 50),
        );
      },
    );
    testWidgets(
      'QA MONEY-R3-04: the amount field reads a pasted "USD .50" as 0.50',
      (t) async {
        expect(
          await typeInto(t, 'USD', 'USD .50', paste: true),
          anyOf(isNull, 50),
        );
      },
    );
  });

  group('QA MONEY-R3-05', () {
    test(
      'QA MONEY-R3-05: digits of separate numbers are not joined into one '
      'amount, and a multiplier suffix is not dropped',
      () {
        final inr = Currencies.of('INR');
        // Joined: 500 and 21 -> 50,021; 4 and 1,200 -> 41,200.
        expect(
          parseAmountInput('Rs 500 paid at Cafe 21', inr),
          anyOf(isNull, 50000),
        );
        expect(
          parseAmountInput('Dinner for 4: 1,200', inr),
          anyOf(isNull, 120000),
        );
        // Dropped multiplier: 2.5k -> 2.50.
        expect(parseAmountInput('2.5k', inr), anyOf(isNull, 250000));
        expect(
          parseAmountInput('1e3', Currencies.of('USD')),
          anyOf(isNull, 100000),
        );
      },
    );
  });

  group('QA MONEY-R3-06', () {
    testWidgets(
      'QA MONEY-R3-06: TND "1,250" has one meaning on Add expense',
      (t) async {
        final tnd = Currencies.of('TND');
        // Typed in the amount field it is 1.250 DT (R2-04)...
        expect(await typeInto(t, 'TND', '1,250'), 1250);
        // ...so a split field, the multi-payer sheet and a paste must not
        // read the same text as 1,250 DT.
        expect(parseAmountInput('1,250', tnd), anyOf(isNull, 1250));
        expect(parseSignedMinor('+1,250', tnd), anyOf(isNull, 1250));
        expect(
          await typeInto(t, 'TND', '1,250 DT', paste: true),
          anyOf(isNull, 1250),
        );
      },
    );
  });
}
