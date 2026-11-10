// FROZEN CONTRACT (docs/SPEC.md section 5.2). Owner: core.
// Money is ALWAYS integer minor units + ISO 4217 code. No doubles anywhere.
import 'package:meta/meta.dart';

import 'currencies_data.dart';

@immutable
final class Currency {
  const Currency({
    required this.code,
    required this.minorDigits,
    required this.symbol,
    required this.name,
  });

  final String code; // ISO 4217, upper case
  final int minorDigits; // 2 for GBP, 0 for JPY, 3 for KWD
  final String symbol; // display symbol, e.g. '£'
  final String name; // English name, e.g. 'British pound'

  int get minorPerMajor {
    var f = 1;
    for (var i = 0; i < minorDigits; i++) {
      f *= 10;
    }
    return f;
  }
}

abstract final class Currencies {
  /// Owner (core) fills in the full ISO 4217 active list (>= 150 entries),
  /// sorted by code. These four are the minimum the tests rely on.
  static const List<Currency> all = isoCurrencies;

  static final Map<String, Currency> _byCode = {
    for (final c in all) c.code: c,
  };

  static Currency? tryOf(String code) => _byCode[code.toUpperCase()];

  /// Unknown codes fall back to 2 minor digits with the code as symbol, so
  /// ops from a newer app version never crash an older one.
  static Currency of(String code) =>
      tryOf(code) ??
      Currency(code: code, minorDigits: 2, symbol: code, name: code);
}

@immutable
final class Money implements Comparable<Money> {
  const Money(this.minor, this.currency);

  final int minor;
  final String currency;

  static Money zero(String currency) => Money(0, currency);

  /// Largest amount the ledger holds, in minor units of any currency:
  /// 999,999,999.99 with 2 digits (99,999,999,999 JPY, 99,999,999.999 KWD).
  /// One cap for every currency, set by the overflow budget (SPEC 6.1:
  /// total x 10,000 basis points stays below 2^53), so low-value currencies
  /// still hold everyday amounts: Rp 999,999,999.99 is about 60,000 USD
  /// (QA UIFLOW-R2-04; it was 9,999,999.99, about 630 USD in IDR).
  static const int maxMinor = 99999999999;

  bool get isZero => minor == 0;
  bool get isPositive => minor > 0;
  bool get isNegative => minor < 0;
  Money abs() => Money(minor.abs(), currency);

  Money operator +(Money other) {
    _check(other);
    return Money(minor + other.minor, currency);
  }

  Money operator -(Money other) {
    _check(other);
    return Money(minor - other.minor, currency);
  }

  Money operator -() => Money(-minor, currency);

  void _check(Money other) {
    if (other.currency != currency) {
      throw ArgumentError('Currency mismatch: $currency vs ${other.currency}');
    }
  }

  @override
  int compareTo(Money other) {
    _check(other);
    return minor.compareTo(other.minor);
  }

  @override
  bool operator ==(Object other) =>
      other is Money && other.minor == minor && other.currency == currency;

  @override
  int get hashCode => Object.hash(minor, currency);

  @override
  String toString() => '$currency $minor';

  Map<String, Object?> toJson() => {'minor': minor, 'currency': currency};

  factory Money.fromJson(Map<String, Object?> json) =>
      Money(json['minor']! as int, json['currency']! as String);

  /// Parses user text ("12", "12.5", "12,50") into minor units of
  /// [currency]. Returns null for empty/invalid input, more fraction digits
  /// than the currency allows, negative values, or values above [maxMinor].
  static int? parseMinor(String text, Currency currency) {
    final t = text.trim().replaceAll(' ', '').replaceAll(',', '.');
    if (t.isEmpty) return null;
    final m = RegExp(r'^(\d+)(?:\.(\d*))?$').firstMatch(t);
    if (m == null) return null;
    final whole = m.group(1)!;
    final frac = m.group(2) ?? '';
    if (frac.length > currency.minorDigits) return null;
    if (whole.length > 12) return null;
    final value = int.parse(whole) * currency.minorPerMajor +
        (frac.isEmpty
            ? 0
            : int.parse(frac.padRight(currency.minorDigits, '0')));
    if (value > maxMinor) return null;
    return value;
  }
}
