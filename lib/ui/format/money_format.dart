// FROZEN CONTRACT (docs/SPEC.md section 5.15). Owner: ui-kit.
import 'package:intl/intl.dart';

import '../../core/money.dart';

abstract final class MoneyFormat {
  static const String minusSign = '−'; // real minus, never '-'

  /// "£12.00", "¥500", "−£8.40" (signed: true adds '+' for positives).
  /// Uses intl NumberFormat.currency with the currency's minorDigits and
  /// Currencies symbol; [locale] null = Intl.defaultLocale.
  ///
  /// Indian rupees (Point to Point design): with no explicit [locale] they
  /// use the en_IN lakh grouping ("₹1,20,000"), and whole-rupee amounts drop
  /// the paise ("₹4,250"; "₹4,250.50" keeps them).
  static String format(
    int minor,
    String currency, {
    bool signed = false,
    String? locale,
  }) {
    final c = Currencies.of(currency);
    final isInr = c.code == 'INR';
    final wholeOnly = isInr && minor % c.minorPerMajor == 0;
    final f = NumberFormat.currency(
      locale: locale ?? (isInr ? 'en_IN' : null),
      name: c.code,
      symbol: c.symbol,
      decimalDigits: wholeOnly ? 0 : c.minorDigits,
    );
    final body = f.format(minor.abs() / c.minorPerMajor);
    if (minor < 0) return '$minusSign$body';
    if (signed && minor > 0) return '+$body';
    return body;
  }

  /// Screen-reader text: "12 pounds 50" style is out of scope for MVP;
  /// returns "12.50 GBP" with words supplied by the caller.
  static String spoken(int minor, String currency) {
    final c = Currencies.of(currency);
    final major = minor.abs() ~/ c.minorPerMajor;
    final rest = minor.abs() % c.minorPerMajor;
    final frac = c.minorDigits == 0
        ? ''
        : '.${rest.toString().padLeft(c.minorDigits, '0')}';
    return '$major$frac ${c.code}';
  }
}
