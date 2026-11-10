// Amount reading, round 3 regressions (MONEY-R2-05 reopened,
// MONEY-R3-01..06): pastes over an amount, dot-grouped thousands, a second
// separator after a decimal comma, currency words and several numbers.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/format/amount_input.dart';
import 'package:settle_up/ui/screens/expense/split_draft.dart';
import 'package:settle_up/ui/widgets/amount_field.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

/// One AmountField whose currency can change, driven like a keyboard.
final class _Field {
  _Field(this.t);

  final WidgetTester t;
  int? reported;
  late StateSetter _setCurrency;
  late String _currency;

  Future<void> pump(String currency, {int? initial}) async {
    reported = null;
    _currency = currency;
    final key = UniqueKey();
    await t.pumpWidget(
      MaterialApp(
        theme: AppTheme.light(),
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              _setCurrency = setState;
              return AmountField(
                key: key,
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

  Future<void> switchTo(String currency) async {
    _setCurrency(() => _currency = currency);
    await t.pump();
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

  /// [s] replaces the text (typed over, or pasted over a selection).
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

void main() {
  group('paste over an amount (MONEY-R2-05, MONEY-R3-01)', () {
    testWidgets('a select-all paste is read as written', (t) async {
      final f = _Field(t);
      await f.pump('IDR', initial: 150000000);
      await f.set('2,000,000');
      expect(f.reported, 200000000);
      expect(f.text, '2,000,000');
      // Over one shared digit, without the selection either.
      await f.pump('EUR');
      await f.keys('1');
      await f.set('1.234,50');
      expect(f.reported, 123450);
    });

    testWidgets('extra decimals pasted over an amount are refused and said', (
      t,
    ) async {
      final f = _Field(t);
      await f.pump('INR');
      await f.keys('12');
      await f.set('12.345');
      expect(f.text, '12');
      expect(f.reported, 1200);
      expect(find.text(KitStrings.amountDecimals(2)), findsOneWidget);
    });
  });

  group('dot-grouped thousands typed (MONEY-R3-02)', () {
    testWidgets('no decimals: the dot groups', (t) async {
      final f = _Field(t);
      await f.pump('VND');
      await f.keys('50.000');
      expect((f.text, f.reported), ('50,000', 50000));
      await f.pump('JPY');
      await f.keys('1.500.000');
      expect((f.text, f.reported), ('1,500,000', 1500000));
    });

    testWidgets('where a dot groups thousands, a third decimal is flagged', (
      t,
    ) async {
      final f = _Field(t);
      await f.pump('EUR');
      await f.keys('10.000');
      expect((f.text, f.reported), ('10.000', null));
      expect(find.text(KitStrings.amountDecimals(2)), findsOneWidget);
      // Backspace gives back the amount and clears the message.
      await f.backspace();
      expect((f.text, f.reported), ('10.00', 1000));
      expect(find.text(KitStrings.amountDecimals(2)), findsNothing);
      // A second dot makes the grouping clear.
      await f.pump('IDR');
      await f.keys('1.000.000');
      expect((f.text, f.reported), ('1,000,000', 100000000));
    });

    testWidgets('a dot-decimal currency refuses the third decimal key', (
      t,
    ) async {
      final f = _Field(t);
      await f.pump('USD');
      await f.keys('12.345');
      expect((f.text, f.reported), ('12.34', 1234));
    });
  });

  group('a separator after the shown decimal point (MONEY-R3-03)', () {
    testWidgets('is refused, except a grouping comma on its way', (t) async {
      final f = _Field(t);
      for (final (cur, keys, shown, minor) in [
        ('TND', '1,250,', '1.250', 1250),
        // BHD writes a dot: "1,250" is 1,250 BD there, as the reader reads
        // it (MONEY-R3-03 reopened), and the point after it is its decimal
        // point.
        ('BHD', '1,250.', '1,250.', 1250000),
        // On its way to "1,250,000": no amount yet (round 7).
        ('BHD', '1,250,', '1,250,', null),
        ('USD', '1,23,', '1.23', 123),
        ('EUR', '12,5.', '12.5', 1250),
        ('KWD', '1.250,', '1.250', 1250),
        // A second comma in a dot-decimal currency groups (KWD and INR
        // lakh), as before.
        ('KWD', '1,234,567', '1,234,567', 1234567000),
        ('INR', '1,00,000', '1,00,000', 10000000),
      ]) {
        await f.pump(cur);
        await f.keys(keys);
        expect((f.text, f.reported), (shown, minor), reason: '$cur $keys');
      }
    });

    testWidgets('typed into an amount already there', (t) async {
      final f = _Field(t);
      await f.pump('KWD', initial: 1250);
      await f.keys('.');
      expect(f.text, '1.250');
      await f.keys(',');
      expect(f.text, '1.250');
      expect(f.reported, isNull); // nothing changed
    });
  });

  group('switching currency', () {
    testWidgets('never cuts decimals silently', (t) async {
      final f = _Field(t);
      await f.pump('KWD', initial: 1250);
      await f.switchTo('USD');
      expect((f.text, f.reported), ('1.250', null));
      expect(find.text(KitStrings.amountDecimals(2)), findsOneWidget);
      await f.switchTo('KWD');
      expect((f.text, f.reported), ('1.250', 1250));
      expect(find.text(KitStrings.amountDecimals(2)), findsNothing);
    });

    testWidgets('the shown text is edited, not re-read', (t) async {
      final f = _Field(t);
      await f.pump('USD');
      await f.keys('1,250');
      await f.switchTo('TND');
      expect(f.reported, 1250000);
      await f.keys('5');
      // TND thousands are grouped with a thin space (MONEY-R4-02).
      expect((f.text, f.reported), ('12\u2009505', 12505000));
    });
  });

  group('reading text (MONEY-R3-04..06)', () {
    final inr = Currencies.of('INR');
    final usd = Currencies.of('USD');
    final tnd = Currencies.of('TND');
    test('a decimal point after a currency word', () {
      expect(parseAmountInput('USD .50', usd), 50);
      expect(parseAmountInput('Rs. .50', inr), 50);
      expect(parseAmountInput('EUR ,50', Currencies.of('EUR')), 50);
      expect(parseAmountInput('.5', usd), 50);
      // The mark's own dot still goes; a dot apart from it and the digits
      // is no amount (round 7, one strict grammar).
      expect(parseAmountInput('Rs . 500', inr), isNull);
      expect(parseAmountInput('Rs.500', inr), 50000);
    });

    test('several numbers or a multiplier are refused', () {
      for (final s in [
        'Rs 500 paid at Cafe 21',
        'Dinner for 4: 1,200',
        '₹1,200 - ₹1,500',
        '2.5k',
        '1.5 lakh',
        '3 Cr',
        r'$1.2M',
        '1e3',
        '2 million',
      ]) {
        expect(parseAmountInput(s, inr), isNull, reason: s);
      }
      // One number with words and marks around it still reads.
      expect(parseAmountInput('Rs. 500/-', inr), 50000);
      expect(parseAmountInput('100 kr', Currencies.of('SEK')), 10000);
      expect(parseAmountInput("1'234.50", usd), 123450);
      expect(parseAmountInput('1 234,50', Currencies.of('EUR')), 123450);
      expect(parseAmountInput('500 Rs.', inr), 50000);
    });

    test('TND "1,250" is 1.250 everywhere; KWD keeps the comma grouping', () {
      expect(parseAmountInput('1,250', tnd), 1250);
      expect(parseSignedMinor('-1,250', tnd), -1250);
      // TND groups with dots or spaces; its comma is only ever the
      // decimal comma (round 7).
      expect(parseAmountInput('1,250,000', tnd), isNull);
      expect(parseAmountInput('1.250.000', tnd), 1250000000);
      expect(parseAmountInput('1.250,500', tnd), 1250500);
      expect(parseAmountInput('1,250', Currencies.of('KWD')), 1250000);
      // No decimals: a dot and three digits is a thousand.
      expect(parseAmountInput('50.000', Currencies.of('VND')), 50000);
      expect(parseAmountInput('1.5', Currencies.of('JPY')), isNull);
    });

    testWidgets('the field reads the same pastes', (t) async {
      final f = _Field(t);
      await f.pump('USD');
      await f.set('USD .50');
      expect((f.text, f.reported), ('0.50', 50));
      await f.pump('TND');
      await f.set('1,250 DT');
      expect((f.text, f.reported), ('1.250', 1250));
      await f.pump('INR');
      await f.set('Rs 500 paid at Cafe 21');
      expect((f.text, f.reported), ('', null));
    });
  });
}
