import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/format/money_format.dart';

void main() {
  group('MoneyFormat.format', () {
    test('two-digit currencies', () {
      expect(MoneyFormat.format(1200, 'GBP'), '£12.00');
      expect(MoneyFormat.format(840, 'GBP'), '£8.40');
      expect(MoneyFormat.format(5, 'EUR'), '€0.05');
      expect(MoneyFormat.format(0, 'USD'), r'$0.00');
    });

    test('uses a real minus sign, never a hyphen', () {
      final s = MoneyFormat.format(-840, 'GBP');
      expect(s, '−£8.40');
      expect(s.codeUnitAt(0), 0x2212);
      expect(s.contains('-'), isFalse);
    });

    test('signed adds plus for positives only', () {
      expect(MoneyFormat.format(1200, 'GBP', signed: true), '+£12.00');
      expect(MoneyFormat.format(-1200, 'GBP', signed: true), '−£12.00');
      expect(MoneyFormat.format(0, 'GBP', signed: true), '£0.00');
    });

    test('zero-decimal JPY', () {
      expect(MoneyFormat.format(500, 'JPY'), '¥500');
      expect(MoneyFormat.format(-123456, 'JPY'), '−¥123,456');
    });

    test('grouping and the maximum amount stay exact', () {
      expect(MoneyFormat.format(999999999, 'GBP'), '£9,999,999.99');
      expect(
        MoneyFormat.format(123456789, 'INR', signed: true),
        '+₹1,234,567.89',
      );
    });

    test('unknown codes fall back to the code as symbol', () {
      expect(MoneyFormat.format(1250, 'XYZ'), contains('12.50'));
    });

    test('locale changes separators', () {
      final de = MoneyFormat.format(123456, 'EUR', locale: 'de');
      expect(de, contains('1.234,56'));
    });
  });

  group('MoneyFormat.spoken', () {
    test('no sign words, code instead of symbol', () {
      expect(MoneyFormat.spoken(1250, 'GBP'), '12.50 GBP');
      expect(MoneyFormat.spoken(-840, 'GBP'), '8.40 GBP');
      expect(MoneyFormat.spoken(500, 'JPY'), '500 JPY');
      expect(MoneyFormat.spoken(7, 'EUR'), '0.07 EUR');
    });
  });
}
