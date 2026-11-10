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
///   ("Rs. 500", "approx. 300"): one right after a letter, or one in a
///   lead-in with letters before the first digit, unless it sits right
///   before that digit ("USD .50" is half a dollar);
/// - text with more than one number in it ("Rs 500 paid at Cafe 21",
///   "Dinner for 4: 1,200", "1e3") or with a multiplier after the number
///   ("2.5k", "1.5 lakh", "$1.2M") is refused: it is never joined or
///   shortened into a different amount;
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
/// With [currency], the text is read the way that currency is written, the
/// same in every amount input (the big field, split fields, the payer
/// sheet, a paste):
/// - a single comma followed by no more digits than the currency has is
///   its decimal comma where people write one: TND "1,250" is 1.250, as
///   the amount field shows it when typed (KWD writes a dot, and "1,250"
///   there is a thousand two hundred and fifty);
/// - in a currency with no decimals, a single dot followed by three digits
///   groups: VND "50.000" is fifty thousand (a dot cannot be a decimal
///   point there);
/// - lakh grouping ("1,00,000") is read only for currencies written that
///   way; "1,23," in USD is not a number.
///
/// With [typing], the text is still being typed at its end, so the last
/// comma group may be short too ("1,234," and "1,234,5" on the way to
/// "1,234,567").
///
/// The fraction is not cut to the currency here; callers decide.
String? normalizeAmountInput(
  String raw, {
  bool typing = false,
  Currency? currency,
}) {
  if (_joinsNumbers(raw) || _hasMultiplier(raw)) return null;
  final kept = _dropWordMarks(raw).replaceAll(RegExp(r'[^0-9.,]'), '');
  if (kept.isEmpty) return '';
  final lakh = currency == null || lakhCurrencies.contains(currency.code);
  final digits = currency?.minorDigits;
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
    if (!_validGroups(whole.split(group), allowLakh: lakh)) return null;
    return '${whole.replaceAll(group, '')}.$frac';
  }

  if (lastComma >= 0) {
    final parts = kept.split(',');
    if (parts.length > 2) {
      return _validGroups(parts, allowLakh: lakh, partialLast: typing)
          ? parts.join()
          : null;
    }
    final after = parts[1];
    final groups = after.length == 3 && _canLeadGroups(parts[0]);
    // Room for the digits as decimals where people write a decimal comma:
    // TND "1,250" is 1.250, as typed in the amount field.
    if (currency != null &&
        after.length <= digits! &&
        decimalCommaCurrencies.contains(currency.code)) {
      return '${parts[0]}.$after';
    }
    if (groups) return parts.join();
    return '${parts[0]}.$after';
  }

  if (lastDot >= 0) {
    final parts = kept.split('.');
    if (parts.length == 2) {
      if (digits == 0 && parts[1].length == 3 && _canLeadGroups(parts[0])) {
        return parts.join();
      }
      return kept;
    }
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

/// The digits of [raw] when its [separator]s group them as typed so far
/// (the last group may be short: "1,0" on the way to "1,000"), or null.
String? typedGroups(String raw, {String separator = ','}) {
  final kept = _dropWordMarks(raw)
      .replaceAll(RegExp('[^0-9${RegExp.escape(separator)}]'), '');
  final parts = kept.split(separator);
  return _validGroups(parts, allowLakh: separator == ',', partialLast: true)
      ? parts.join()
      : null;
}

/// Whether [raw] holds more than one number: digit runs apart by anything
/// but separators, spaces and apostrophes ("Rs 500 paid at Cafe 21" is 500
/// and 21, never 50,021; "1e3" is not 13).
bool _joinsNumbers(String raw) {
  final first = raw.indexOf(RegExp('[0-9]'));
  if (first < 0) return false;
  final last = raw.lastIndexOf(RegExp('[0-9]'));
  return !RegExp(r"^[0-9.,'\u2019\u02BC\s\u00A0\u2009\u202F]*$")
      .hasMatch(raw.substring(first, last + 1));
}

/// Words and letters after a number that multiply it ("2.5k", "1.5 lakh",
/// "$1.2M", "3 crore"): dropping them would read a different amount.
const Set<String> _multipliers = {
  'k', 'kk', 'm', 'mm', 'mn', 'mio', 'mil', 'b', 'bn', 'mrd', 't', 'tn', //
  'l', 'lac', 'lacs', 'lakh', 'lakhs', 'cr', 'crs', 'crore', 'crores', //
  'thousand', 'thousands', 'million', 'millions', 'billion', 'billions', //
  'tsd', 'e',
};

bool _hasMultiplier(String raw) {
  final last = raw.lastIndexOf(RegExp('[0-9]'));
  if (last < 0) return false;
  final word = RegExp(
    r'^[\s\u00A0]*(\p{L}+)',
    unicode: true,
  ).firstMatch(raw.substring(last + 1));
  return word != null && _multipliers.contains(word.group(1)!.toLowerCase());
}

/// [raw] without the '.' and ',' that belong to words rather than to the
/// number: one right after a letter ("Rs.500", "approx. 300", "500 Rs."),
/// and one in a lead-in that holds letters ("Rs . 500"), unless it sits
/// right before the first digit, apart from the word ("USD .50", "Rs. .50"):
/// that one is the decimal point.
String _dropWordMarks(String raw) {
  final letter = RegExp(r'\p{L}', unicode: true);
  final firstDigit = raw.indexOf(RegExp('[0-9]'));
  final out = StringBuffer();
  final leadHasLetter =
      firstDigit > 0 && letter.hasMatch(raw.substring(0, firstDigit));
  for (var i = 0; i < raw.length; i++) {
    final ch = raw[i];
    if (ch == '.' || ch == ',') {
      if (i > 0 && letter.hasMatch(raw[i - 1])) continue;
      if (leadHasLetter && i < firstDigit - 1) continue;
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

/// Currencies whose people group digits in lakhs and crores ("1,00,000").
const Set<String> lakhCurrencies = {'INR', 'NPR', 'PKR', 'BDT', 'LKR'};

/// Minor units for an amount typed in any of the forms above, read the way
/// [c] is written, or null when it cannot be read, has more decimals than
/// [c] allows, or is too large.
int? parseAmountInput(String raw, Currency c) {
  final t = normalizeAmountInput(raw.trim(), currency: c);
  if (t == null || t.isEmpty) return null;
  return Money.parseMinor(t.startsWith('.') ? '0$t' : t, c);
}
