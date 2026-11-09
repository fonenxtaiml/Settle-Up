// Reading amounts the way people type or paste them. The amount field shows
// "1,234.50" (comma groups, dot decimal), but people also type "12,50" or
// paste "1.234,50" (dot groups, comma decimal), "1 234,50" or "1'234.50".
// One reader for every amount input, so no field turns a thousand into one.
import '../../core/money.dart';

/// [raw] as canonical "1234.50" (digits, at most one '.' decimal point, no
/// grouping), or null when it cannot be read without guessing.
///
/// Rules:
/// - spaces, NBSP, apostrophes and other non-digit marks are grouping or
///   decoration and are dropped; so is a '.' or ',' that belongs to a word
///   ("Rs. 500", "approx. 300"): one right after a letter, or anywhere in
///   a lead-in with letters before the first digit;
/// - with both '.' and ',', the last one is the decimal separator and the
///   other may only group digits before it ("1.234,50", "1,234.50");
/// - commas only: several commas group ("1,20,000"); a single comma groups
///   when exactly three digits follow it ("1,000", as the field shows a
///   thousand), otherwise it is a decimal comma ("12,5", "12,");
/// - dots only: a single dot is the decimal point ("12.345" in KWD);
///   several dots group, as long as every group after the first has three
///   digits (the last may still be being typed: "1.234.5");
/// - a first group of 0 ("0,500", "00,123") or with a leading zero never
///   groups thousands: "0,500" is a decimal comma.
///
/// With [typing], the text is still being typed at its end, so the last
/// comma group may be short too ("1,234," and "1,234,5" on the way to
/// "1,234,567").
///
/// The fraction is not cut to the currency here; callers decide.
String? normalizeAmountInput(String raw, {bool typing = false}) {
  final kept = _dropWordMarks(raw).replaceAll(RegExp(r'[^0-9.,]'), '');
  if (kept.isEmpty) return '';
  final lastDot = kept.lastIndexOf('.');
  final lastComma = kept.lastIndexOf(',');

  if (lastDot >= 0 && lastComma >= 0) {
    final decimal = lastDot > lastComma ? '.' : ',';
    final group = decimal == '.' ? ',' : '.';
    final at = kept.lastIndexOf(decimal);
    final whole = kept.substring(0, at);
    final frac = kept.substring(at + 1);
    // One decimal separator, grouping only before it.
    if (whole.contains(decimal) || frac.contains(group)) return null;
    if (!_validGroups(whole.split(group), allowLakh: true)) return null;
    return '${whole.replaceAll(group, '')}.$frac';
  }

  if (lastComma >= 0) {
    final parts = kept.split(',');
    if (parts.length > 2) {
      return _validGroups(parts, allowLakh: true, partialLast: typing)
          ? parts.join()
          : null;
    }
    final after = parts[1];
    if (after.length == 3 && _canLeadGroups(parts[0])) return parts.join();
    return '${parts[0]}.$after';
  }

  if (lastDot >= 0) {
    final parts = kept.split('.');
    if (parts.length == 2) return kept;
    for (var i = 1; i < parts.length; i++) {
      final last = i == parts.length - 1;
      final n = parts[i].length;
      if (last ? n > 3 : n != 3) return null;
    }
    if (!_canLeadGroups(parts.first)) return null;
    return parts.join();
  }
  return kept;
}

/// The digits of [raw] when its commas group them as typed so far (the last
/// group may be short: "1,0" on the way to "1,000"), or null.
String? typedCommaGroups(String raw) {
  final kept = _dropWordMarks(raw).replaceAll(RegExp(r'[^0-9,]'), '');
  final parts = kept.split(',');
  return _validGroups(parts, allowLakh: true, partialLast: true)
      ? parts.join()
      : null;
}

/// [raw] without the '.' and ',' that belong to words rather than to the
/// number: one right after a letter ("Rs.500", "approx. 300", "500 Rs."),
/// and every one in a lead-in that holds letters ("Rs . 500").
String _dropWordMarks(String raw) {
  final letter = RegExp(r'\p{L}', unicode: true);
  final firstDigit = raw.indexOf(RegExp('[0-9]'));
  final out = StringBuffer();
  final leadHasLetter =
      firstDigit > 0 && letter.hasMatch(raw.substring(0, firstDigit));
  for (var i = 0; i < raw.length; i++) {
    final ch = raw[i];
    if (ch == '.' || ch == ',') {
      if (leadHasLetter && i < firstDigit) continue;
      if (i > 0 && letter.hasMatch(raw[i - 1])) continue;
    }
    out.write(ch);
  }
  return out.toString();
}

/// Whether [first] can be the first group of a grouped number: 1..3 digits
/// and no leading zero ("0,500" and "05,000" are not thousands).
bool _canLeadGroups(String first) =>
    first.isNotEmpty && first.length <= 3 && !first.startsWith('0');

/// Groups after the first have three digits (or two, Indian lakh/crore
/// style, before a final group of three); the first is 1..3 digits with no
/// leading zero. With [partialLast], the last group may be short (still
/// being typed).
bool _validGroups(
  List<String> groups, {
  bool allowLakh = false,
  bool partialLast = false,
}) {
  if (groups.length < 2) return true;
  if (!_canLeadGroups(groups.first)) return false;
  for (var i = 1; i < groups.length; i++) {
    final n = groups[i].length;
    final last = i == groups.length - 1;
    if (n == 3) continue;
    if (last && partialLast && n < 3) continue;
    if (allowLakh && !last && n == 2) continue;
    return false;
  }
  return true;
}

/// Currencies whose people write a decimal comma ("12,50 €", "0,250 DT").
/// A comma the amount field has shown as the decimal point stays one there,
/// so a third digit after it is refused rather than read as a thousand.
const Set<String> decimalCommaCurrencies = {
  'ALL', 'AOA', 'ARS', 'AZN', 'BAM', 'BGN', 'BOB', 'BRL', 'BYN', 'CLP', //
  'COP', 'CRC', 'CVE', 'CZK', 'DKK', 'DZD', 'EUR', 'GEL', 'HUF', 'IDR', //
  'ISK', 'KZT', 'MAD', 'MDL', 'MKD', 'MZN', 'NOK', 'PLN', 'PYG', 'RON', //
  'RSD', 'RUB', 'SEK', 'TND', 'TRY', 'UAH', 'UYU', 'UZS', 'VES', 'VND', //
  'XAF', 'XOF',
};

/// Minor units for an amount typed in any of the forms above, or null when
/// it cannot be read, has more decimals than [c] allows, or is too large.
int? parseAmountInput(String raw, Currency c) {
  final t = normalizeAmountInput(raw.trim());
  if (t == null || t.isEmpty) return null;
  return Money.parseMinor(t, c);
}
