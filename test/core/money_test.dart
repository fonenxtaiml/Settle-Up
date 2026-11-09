import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/money.dart';

void main() {
  final gbp = Currencies.of('GBP');
  final jpy = Currencies.of('JPY');
  final kwd = Currencies.of('KWD');

  group('Currencies table', () {
    test('has the full active ISO list, sorted by unique code', () {
      expect(Currencies.all.length, greaterThanOrEqualTo(150));
      final codes = Currencies.all.map((c) => c.code).toList();
      expect(codes, orderedEquals([...codes]..sort()));
      expect(codes.toSet().length, codes.length);
      for (final c in Currencies.all) {
        expect(c.code, matches(RegExp(r'^[A-Z]{3}$')));
        expect(c.minorDigits, inInclusiveRange(0, 3));
        expect(c.symbol, isNotEmpty);
        expect(c.name, isNotEmpty);
      }
    });

    test('contains the codes and digits other packages rely on', () {
      expect(Currencies.tryOf('EUR')?.symbol, '€');
      expect(Currencies.tryOf('GBP')?.symbol, '£');
      expect(Currencies.tryOf('INR')?.symbol, '₹');
      expect(Currencies.tryOf('USD')?.symbol, r'$');
      expect(jpy.minorDigits, 0);
      expect(Currencies.of('KRW').minorDigits, 0);
      expect(Currencies.of('VND').minorDigits, 0);
      expect(kwd.minorDigits, 3);
      expect(Currencies.of('BHD').minorDigits, 3);
      expect(Currencies.of('TND').minorDigits, 3);
      expect(gbp.minorDigits, 2);
      expect(gbp.minorPerMajor, 100);
      expect(jpy.minorPerMajor, 1);
      expect(kwd.minorPerMajor, 1000);
    });

    test('lookup is case-insensitive', () {
      expect(Currencies.tryOf('gbp')?.code, 'GBP');
    });

    test('unknown codes fall back to 2 digits with the code as symbol', () {
      expect(Currencies.tryOf('XYZ'), isNull);
      final c = Currencies.of('XYZ');
      expect(c.code, 'XYZ');
      expect(c.minorDigits, 2);
      expect(c.symbol, 'XYZ');
      expect(c.name, 'XYZ');
    });
  });

  group('Money.parseMinor', () {
    test('dot and comma separators', () {
      expect(Money.parseMinor('12', gbp), 1200);
      expect(Money.parseMinor('12.5', gbp), 1250);
      expect(Money.parseMinor('12.50', gbp), 1250);
      expect(Money.parseMinor('12,50', gbp), 1250);
      expect(Money.parseMinor('12.', gbp), 1200);
      expect(Money.parseMinor(' 1 234.56 ', gbp), 123456);
      expect(Money.parseMinor('0.01', gbp), 1);
      expect(Money.parseMinor('0', gbp), 0);
    });

    test('too many decimals, garbage, negatives and empty are rejected', () {
      expect(Money.parseMinor('12.345', gbp), isNull);
      expect(Money.parseMinor('', gbp), isNull);
      expect(Money.parseMinor('   ', gbp), isNull);
      expect(Money.parseMinor('-5', gbp), isNull);
      expect(Money.parseMinor('abc', gbp), isNull);
      expect(Money.parseMinor('1.2.3', gbp), isNull);
      expect(Money.parseMinor('.5', gbp), isNull);
      expect(Money.parseMinor('1e3', gbp), isNull);
    });

    test('JPY has no fraction digits', () {
      expect(Money.parseMinor('500', jpy), 500);
      expect(Money.parseMinor('500.', jpy), 500);
      expect(Money.parseMinor('500.5', jpy), isNull);
    });

    test('KWD has three fraction digits', () {
      expect(Money.parseMinor('1.5', kwd), 1500);
      expect(Money.parseMinor('1.234', kwd), 1234);
      expect(Money.parseMinor('1.2345', kwd), isNull);
    });

    test('maximum amount', () {
      expect(Money.parseMinor('9999999.99', gbp), Money.maxMinor);
      expect(Money.parseMinor('10000000', gbp), isNull);
      expect(Money.parseMinor('999999999', jpy), Money.maxMinor);
      expect(Money.parseMinor('1000000000', jpy), isNull);
      expect(Money.parseMinor('9999999999999', gbp), isNull);
    });
  });

  group('Money arithmetic', () {
    const a = Money(1250, 'GBP');
    const b = Money(250, 'GBP');

    test('add, subtract, negate, abs, predicates', () {
      expect(a + b, const Money(1500, 'GBP'));
      expect(a - b, const Money(1000, 'GBP'));
      expect(b - a, const Money(-1000, 'GBP'));
      expect(-a, const Money(-1250, 'GBP'));
      expect((b - a).abs(), const Money(1000, 'GBP'));
      expect(Money.zero('GBP').isZero, isTrue);
      expect(a.isPositive, isTrue);
      expect((-a).isNegative, isTrue);
      expect(a.compareTo(b), greaterThan(0));
      expect(a, isNot(const Money(1250, 'EUR')));
      expect(a.hashCode, const Money(1250, 'GBP').hashCode);
    });

    test('currency mismatch throws', () {
      const eur = Money(1, 'EUR');
      expect(() => a + eur, throwsArgumentError);
      expect(() => a - eur, throwsArgumentError);
      expect(() => a.compareTo(eur), throwsArgumentError);
    });

    test('JSON round trip', () {
      final json = jsonDecode(jsonEncode(a.toJson())) as Map<String, Object?>;
      expect(json, {'minor': 1250, 'currency': 'GBP'});
      expect(Money.fromJson(json), a);
    });
  });
}
