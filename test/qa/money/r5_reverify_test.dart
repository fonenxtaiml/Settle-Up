// QA MONEY round 5: reverifies the round-4 amount reading fixes
// (MONEY-R3-03, MONEY-R3-05, MONEY-R4-01..04) with neighbouring inputs, on
// the amount field, the split and payer fields and the real Add expense
// screen, and holds repro tests for the defects still open or found in
// this round (skipped with their ids).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/format/amount_input.dart';
import 'package:settle_up/ui/screens/expense/expense_edit_screen.dart';
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

  /// What the field reports after [s] is typed key by key in [currency].
  Future<int?> typed(String currency, String s, {int? initial}) async {
    await pump(currency, initial: initial);
    await keys(s);
    return reported;
  }

  /// What the field reports after [s] is pasted into it in [currency].
  Future<int?> pasted(String currency, String s, {int? initial}) async {
    await pump(currency, initial: initial);
    await set(s);
    return reported;
  }
}

Currency cur(String code) => Currencies.of(code);

String _shown(String s) => s
    .replaceAll('\n', r'\n')
    .replaceAll('\t', r'\t')
    .replaceAll('‐', r'‐')
    .replaceAll('‑', r'‑');

void main() {
  // ------------------------------------------ round-4 fixes, verified --

  group('MONEY-R3-03 neighbours: one reading per currency', () {
    testWidgets('three-decimal dot currencies read typed "1,250" as pasted', (
      t,
    ) async {
      final f = _Field(t);
      for (final c in ['KWD', 'BHD', 'OMR', 'JOD', 'IQD', 'LYD']) {
        final want = parseAmountInput('1,250', cur(c));
        expect(want, 1250000, reason: c);
        expect(await f.typed(c, '1,250'), want, reason: c);
        expect(await f.pasted(c, '1,250'), want, reason: '$c paste');
        // Neither separator after it multiplies it. "1,250," is on its way
        // to "1,250,000" and holds no amount until then (round 7: no
        // amount before the text matches the grammar).
        expect(await f.typed(c, '1,250,'), isNull, reason: '$c ","');
        expect(await f.typed(c, '1,250.'), want, reason: '$c "."');
        // A short decimal comma stays a decimal comma, and a comma after it
        // is refused.
        expect(await f.typed(c, '1,25'), 1250, reason: c);
        expect(await f.typed(c, '1,25,'), 1250, reason: c);
        expect(await f.typed(c, '1,2,'), 1200, reason: c);
        // A zero first group never groups.
        expect(await f.typed(c, '0,250'), 250, reason: c);
        expect(await f.pasted(c, '0,250'), 250, reason: c);
      }
      // TND keeps the decimal comma (1.250 DT) typed and pasted.
      expect(await f.typed('TND', '1,250'), 1250);
      expect(await f.typed('TND', '1,250,'), 1250);
      expect(await f.typed('TND', '1,250.'), 1250);
      expect(await f.pasted('TND', '1,250'), 1250);
    });

    testWidgets('an existing three-decimal amount keeps its decimal point', (
      t,
    ) async {
      final f = _Field(t);
      for (final c in ['KWD', 'BHD', 'TND']) {
        await f.pump(c, initial: 1250);
        expect(f.text, '1.250', reason: c);
        await f.keys(',');
        expect(f.text, '1.250', reason: c);
        await f.keys('.');
        expect(f.text, '1.250', reason: c);
      }
    });
  });

  group('MONEY-R4-02 neighbours: TND text reads back as shown', () {
    testWidgets('thin, no-break and plain spaces group TND thousands', (
      t,
    ) async {
      final f = _Field(t);
      for (final s in ['12 500', '12 500', '12 500', '12 500']) {
        expect(await f.pasted('TND', s), 12500000, reason: _shown(s));
      }
      // The field's own text for large amounts, pasted back.
      for (final minor in [1250000, 1234567890, 999999999, 1000]) {
        await f.pump('TND', initial: minor);
        final shown = f.text;
        expect(await f.pasted('TND', shown), minor, reason: shown);
      }
      // A currency switch regroups with the new currency's mark.
      int? last;
      Widget field(String c) => MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: AmountField(currency: c, onChanged: (v) => last = v),
        ),
      );
      await t.pumpWidget(field('USD'));
      await f.keys('12500');
      expect(f.text, '12,500');
      await t.pumpWidget(field('TND'));
      await t.pump();
      expect(f.text, '12 500');
      expect(last, 12500000);
      await t.pumpWidget(field('USD'));
      await t.pump();
      expect(f.text, '12,500');
      expect(last, 1250000);
    });
  });

  group(
    'MONEY-R4-01 neighbours: short dot groups with three digits or less',
    () {
      testWidgets('no amount is held while the group is short', (t) async {
        final f = _Field(t);
        for (final (c, s) in [
          ('JPY', '800.50'),
          ('JPY', '800.5'),
          ('JPY', '99.99'),
          ('JPY', '999.99'),
          ('KRW', '5.00'),
          ('VND', '50.00'),
          ('ISK', '1.5'),
          ('CLP', '1.50'),
          ('JPY', '1.000.5'),
        ]) {
          expect(await f.typed(c, s), isNull, reason: '$c "$s"');
        }
        // The group completed is a thousands group.
        expect(await f.typed('KRW', '5.000'), 5000);
        expect(await f.typed('VND', '50.000'), 50000);
        // A paste of the short text is refused.
        expect(await f.pasted('JPY', '800.50'), isNull);
      });
    },
  );

  group('MONEY-R4-03 neighbours: words in pasted split and payer text', () {
    testWidgets('the payer sheet reads "Rs. 50" as 50 and refuses joins', (
      t,
    ) async {
      const MemberId a = 'a', b = 'b';
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Scaffold(
            body: MultiPayerSheet(
              members: const [a, b],
              names: const {a: 'You', b: 'Rahul'},
              fullNames: const {a: 'You', b: 'Rahul'},
              me: a,
              total: 10000,
              currency: 'INR',
              initial: const {},
            ),
          ),
        ),
      );
      final rahul = splitInput('${S.paidBy}, Rahul');
      String text() => t.widget<TextField>(rahul).controller!.text;
      for (final (s, want) in [
        ('Rs. 50', 5000),
        ('Rs.50', 5000),
        ('₹ 50', 5000),
        ('Rs 100 at table 2', null),
        ('2.5k', null),
        ('1.5 lakh', null),
        ('', null),
      ]) {
        await t.enterText(rahul, '');
        await t.enterText(rahul, s);
        await t.pump();
        expect(
          parseAmountInput(text(), cur('INR')),
          want,
          reason: '"$s" -> "${text()}"',
        );
      }
    });
  });

  group('MONEY-R4-04 neighbours: minus forms', () {
    test('the reader keeps the sign in every listed form', () {
      final inr = cur('INR');
      for (final s in [
        '-30',
        '−30',
        '–30',
        '—30',
        '‒30',
        '﹣30',
        '－30',
        '- 30',
        '30 -',
        '₹-30',
        '-₹30',
        'Rs. -30',
        '-30/-',
        '(30/-)',
      ]) {
        // Round 7, one strict grammar: only '-' and U+2212, first or after
        // a leading currency mark, write a minus; every other form is no
        // amount, so its sign is never dropped either.
        final minus = RegExp(r'^[-\u2212](₹|Rs\.? ?)?[0-9]|^(₹|Rs\.? ?)[-\u2212][0-9]');
        expect(
          parseSignedMinor(s, inr),
          minus.hasMatch(s) ? -3000 : isNull,
          reason: s,
        );
        // An amount that cannot be negative refuses it.
        expect(parseAmountInput(s, inr), isNull, reason: s);
      }
      for (final s in ['+30', '30/-', 'Rs. 30', '30,-']) {
        expect(parseSignedMinor(s, inr), 3000, reason: s);
      }
      for (final s in ['+(30)', '(-30)', '--30', '-+30']) {
        expect(parseSignedMinor(s, inr), isNull, reason: s);
      }
    });
  });

  // ------------------------------------------------ round-5 findings --

  group('QA MONEY-R4-01 (reopened)', () {
    testWidgets(
      'QA MONEY-R4-01: a dot typed after four or more digits in a no-decimal '
      'currency is not swallowed into a 100x amount',
      (t) async {
        // The dot after "1200" cannot lead a thousands group, so the key is
        // refused without a word; the "50" typed next extends the whole
        // number: ¥1,200.50 is held as ¥120,050 and Save is enabled.
        final f = _Field(t);
        for (final (c, s, meant) in [
          ('JPY', '1200.50', 1200),
          ('JPY', '1200.5', 1200),
          ('KRW', '15000.00', 15000),
          ('VND', '50000.00', 50000),
          ('JPY', '0.50', 0),
        ]) {
          final v = await f.typed(c, s);
          expect(v, anyOf(isNull, meant), reason: '$c "$s" held $v');
        }
        // Edit expense: an existing ¥1,200 with ".50" typed at its end.
        final v = await f.typed('JPY', '.50', initial: 1200);
        expect(v, anyOf(isNull, 1200), reason: 'Edit ¥1,200 + ".50" held $v');
      },
    );
  });

  group('QA MONEY-R4-04 (reopened)', () {
    test(
      'QA MONEY-R4-04: a minus written as a hyphen or a word is not read as '
      'a plus',
      () {
        final inr = cur('INR');
        // U+2010 HYPHEN and U+2011 NON-BREAKING HYPHEN (as PDF and web text
        // often carry a minus), the word "minus", and a half bracket.
        for (final s in ['‐30', '30‐', '‐ 30', '‑30', 'minus 30', '(30']) {
          final v = parseSignedMinor(s, inr);
          expect(v, anyOf(isNull, -3000), reason: '"${_shown(s)}" -> $v');
          // The amount field refuses a negative; it never drops the sign.
          final p = parseAmountInput(s, inr);
          expect(p, isNull, reason: 'amount "${_shown(s)}" -> $p');
        }
      },
    );

    testWidgets(
      'QA MONEY-R4-04: a hyphen-minus pasted into an adjustment is not saved '
      'as a plus',
      (tester) async {
        qaPhone(tester);
        final w = await RealWorld.create(name: 'Arjun');
        final gid = await openAddExpense(tester, w);
        await typeAmountAndDescription(tester, '270', 'Drinks');
        await qaTap(tester, find.text(KitStrings.splitAdjust));
        final priya = splitInput(S.adjustmentOf('Priya'));
        for (final s in ['‐30', '‑30', 'minus 30']) {
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

  group('QA MONEY-R3-05 (reopened)', () {
    test(
      'QA MONEY-R3-05: numbers apart by a tab or a line break, or a count '
      'before an amount in a space-grouping currency, are not joined',
      () {
        for (final (s, c) in [
          // Two spreadsheet cells or two lines: 500 and 210, never 500,210.
          ('500\t210', 'USD'),
          ('500\n210', 'USD'),
          ('500\r\n210', 'INR'),
          ('1\t250', 'EUR'),
          // A count and an amount in words: 4 and 120, never 4,120.
          ('Dinner for 4 120 €', 'EUR'),
          ('Dîner pour 4 120 €', 'EUR'),
          ('Table 12 340', 'EUR'),
          ('for 4 120', 'CAD'),
          ('Tisch 4 500 CHF', 'CHF'),
        ]) {
          final v = parseAmountInput(s, cur(c));
          expect(v, isNull, reason: '"${_shown(s)}" in $c read as $v');
        }
      },
    );

    testWidgets(
      'QA MONEY-R3-05: a tab-separated paste is not joined in the split or '
      'amount field',
      (tester) async {
        qaPhone(tester);
        final w = await RealWorld.create(name: 'Arjun');
        await openAddExpense(tester, w);
        // Total 500,310 joined from "500<tab>310"? Save must stay off for a
        // paste that holds two numbers.
        await typeAmountAndDescription(tester, '500\t310', 'Dinner');
        final amount = tester
            .widget<TextField>(find.byType(TextField).at(0))
            .controller!
            .text;
        expect(
          parseAmountInput(amount, cur('INR')),
          isNot(50031000),
          reason: 'amount field "$amount"',
        );
        await w.shutdown(tester);
      },
    );
  });

  group('QA MONEY-R5-01', () {
    test(
      'QA MONEY-R5-01: a cent, pence, percent or fraction mark after the '
      'number is not dropped',
      () {
        for (final (s, c, dropped) in [
          ('99¢', 'USD', 9900),
          ('99 ¢', 'USD', 9900),
          ('50p', 'GBP', 5000),
          ('50 p', 'GBP', 5000),
          ('15%', 'INR', 1500),
          ('1½', 'USD', 100),
        ]) {
          final v = parseAmountInput(s, cur(c));
          expect(v, isNot(dropped), reason: '"$s" in $c read as $v');
        }
      },
    );

    testWidgets(
      'QA MONEY-R5-01: "99¢" pasted into the amount field is not \$99',
      (t) async {
        final f = _Field(t);
        expect(await f.pasted('USD', '99¢'), anyOf(isNull, 99));
        expect(await f.pasted('GBP', '50p'), anyOf(isNull, 50));
      },
    );
  });
}
