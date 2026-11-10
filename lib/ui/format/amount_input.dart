// Reading amounts the way people type or paste them. The amount field shows
// "1,234.50" (comma groups, dot decimal), but people also type "12,50" or
// paste "1.234,50" (dot groups, comma decimal), "1 234,50" or "1'234.50".
// One reader for every amount input, so no field turns a thousand into one.
import '../../core/currencies_data.dart';
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
///   "Dinner for 4: 1,200", "Dinner for 4 1,200", "1e3") is refused: it is
///   never joined into a different amount. A space or apostrophe between
///   digits groups them only when every run after it has three digits
///   ("1 234,50", "1'234.50"), and a space only in a currency written that
///   way or in a bare number ("Table 12 340" is two numbers in USD);
/// - a word after the number that is not a currency ("2.5k", "1.5 lakh",
///   "$1.2M", "1.5 mln", "5万", "50 cents") is refused: it may multiply or
///   divide the number, so it is never dropped. "50 kr", "500 Rs." and
///   "1,250 DT" are read;
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
/// A minus ("-30", "–30", "30-", "(30)"; see [amountSign]) is refused
/// unless [allowSign]: an amount that cannot be negative never drops it
/// and reads the number as positive. With [allowSign] the sign is left to
/// the caller and the number is read without it.
///
/// The fraction is not cut to the currency here; callers decide.
String? normalizeAmountInput(
  String raw, {
  bool typing = false,
  Currency? currency,
  bool allowSign = false,
}) {
  if (_joinsNumbers(raw, currency) || _hasUnknownWordAfter(raw)) return null;
  final sign = amountSign(raw);
  if (sign == null || (sign < 0 && !allowSign)) return null;
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
/// and 21, never 50,021; "1e3" is not 13), or apart by a space or an
/// apostrophe that cannot be a thousands mark ("Dinner for 4 1,200",
/// "Rs 500 21"). A space groups only in a currency written with space
/// groups ("1 234,50 €"), or in a bare number with no words around it.
bool _joinsNumbers(String raw, Currency? currency) {
  final first = raw.indexOf(RegExp('[0-9]'));
  if (first < 0) return false;
  final last = raw.lastIndexOf(RegExp('[0-9]'));
  final span = raw.substring(first, last + 1);
  if (!RegExp(r"^[0-9.,'’ʼ\s   ]*$").hasMatch(span)) {
    return true;
  }
  final marks = RegExp(r"[\s   '’ʼ]+");
  final runs = span.split(marks);
  if (runs.length == 1) return false;
  // Thousands marks: "1", then runs of three ("234"), the last of which
  // may carry the decimals ("234,50").
  if (!RegExp(r'^[1-9][0-9]{0,2}$').hasMatch(runs.first)) return true;
  for (var i = 1; i < runs.length; i++) {
    final isLast = i == runs.length - 1;
    final ok = isLast
        ? RegExp(r'^[0-9]{3}(?:[.,][0-9]*)?$').hasMatch(runs[i])
        : RegExp(r'^[0-9]{3}$').hasMatch(runs[i]);
    if (!ok) return true;
  }
  final spaced = RegExp(r'[\s   ]').hasMatch(span);
  if (spaced &&
      currency != null &&
      !spaceGroupCurrencies.contains(currency.code) &&
      RegExp(r'\p{L}', unicode: true).hasMatch(raw)) {
    return true;
  }
  return false;
}

/// Every way a minus is written: hyphen-minus, the minus sign, the en and
/// em dashes and the figure dash (as text editors and chat apps turn "-"
/// into one), and the small and full-width hyphen-minus.
const String _minusChars = '-−–—‒﹣－';

/// The sign written around the number in [raw]: -1 for a minus right
/// before it or at the start ("-30", "–30", "USD -50", "-USD .50"), right
/// after it ("30-", as accounting writes it) or for brackets around it
/// ("(30)"); 1 otherwise ("+30", "Rs. 1,200/-", "1.250,- €", "Fr. 30.–"
/// are not negative). Null when the text holds more than one sign
/// ("-(30)", "+30-"): it cannot be read without guessing.
int? amountSign(String raw) {
  final first = raw.indexOf(RegExp('[0-9]'));
  if (first < 0) return 1;
  final last = raw.lastIndexOf(RegExp('[0-9]'));
  final lead = raw.substring(0, first);
  final trail = raw.substring(last + 1);
  const m = '[$_minusChars]';
  final atStart = RegExp('^\\s*$m').hasMatch(lead);
  final beforeDigits = RegExp('$m\\s*[.,]?\$').hasMatch(lead);
  final leadMinus = atStart || beforeDigits;
  final doubleLead =
      atStart && beforeDigits && RegExp(m).allMatches(lead).length > 1;
  final trailMinus = RegExp('^[\\s\\u00A0]*$m').hasMatch(trail);
  final brackets = lead.contains('(') && trail.contains(')');
  final marks = [leadMinus, trailMinus, brackets].where((b) => b).length;
  if (doubleLead || marks > 1) return null;
  if (marks == 1 && lead.contains('+')) return null;
  return marks == 1 ? -1 : 1;
}

/// Currencies written with a space between thousands ("1 234,50 €",
/// "12 500 DT"). Elsewhere a space between digits groups them only in a
/// bare number.
const Set<String> spaceGroupCurrencies = {
  ...decimalCommaCurrencies,
  'CAD', 'CHF', 'ZAR', //
};

/// Words that multiply a number, or divide it, when they follow it
/// ("2.5k", "1.5 lakh", "$1.2M", "2 млн", "50 cents"). Some are also
/// currency symbols ("K", "m"); a number followed by one is still refused,
/// since dropping it could read a different amount.
const Set<String> _multipliers = {
  'k', 'kk', 'm', 'mm', 'mn', 'mln', 'mio', 'mil', 'mill', 'b', 'bn', //
  'bln', 'bil', 'mrd', 'mld', 'mlrd', 'md', 't', 'tn', 'tr', 'trn', //
  'l', 'lk', 'lac', 'lacs', 'lakh', 'lakhs', 'cr', 'crs', 'crore', //
  'crores', 'thousand', 'thousands', 'million', 'millions', 'billion', //
  'billions', 'trillion', 'grand', 'tsd', 'tys', 'tyś', 'tysięcy', //
  'mille', 'mila', 'miljoen', 'miljon', 'millones', 'millón', 'milhões', //
  'тыс', 'тысяч', 'тысячи', 'тис', 'млн', 'млрд', 'хил', 'e', //
  'cent', 'cents', 'paise', 'paisa', 'ct', 'cts', 'c',
};

/// Numerals that open a CJK word after a number ("5万", "3千円", "5만원"):
/// ten thousand, thousand, hundred, hundred million and so on.
final RegExp _cjkMultiplier = RegExp('^[十百千万萬亿億兆천만억조백십]');

/// Words that may follow a number because they name its currency: every
/// ISO code, the letters of every symbol, each currency's own name ("50
/// rupees", "20 euro") and a few local spellings ("Rs", "DT", "kr", "円").
final Set<String> _currencyWords = () {
  final letters = RegExp(r'\p{L}+', unicode: true);
  final words = <String>{
    'rs', 'rp', 'dt', 'kd', 'bd', 'ro', 'jd', 'kr', 'zł', 'zl', 'ft', //
    'kč', 'kc', 'lei', 'лв', 'грн', 'руб', 'р', 'тг', 'сум', 'tl', 'dh', //
    'dhs', 'sar', 'eur', 'euro', 'euros', 'rupees', 'rupaye', 'only', //
    '円', '元', '원', '圓', '块', 'บาท', 'ريال', 'دينار', 'درهم', 'جنيه', //
  };
  for (final c in isoCurrencies) {
    words.add(c.code.toLowerCase());
    final symbol = letters.firstMatch(c.symbol)?.group(0);
    if (symbol != null) words.add(symbol.toLowerCase());
    final name = c.name.split(' ').last.toLowerCase();
    words
      ..add(name)
      ..add('${name}s');
  }
  return words;
}();

/// Whether a word that is not a currency follows the number: it may be a
/// multiplier ("2.5k", "1.5 mln", "5万") or start another phrase, and the
/// number without it could be a different amount.
bool _hasUnknownWordAfter(String raw) {
  final last = raw.lastIndexOf(RegExp('[0-9]'));
  if (last < 0) return false;
  final word = RegExp(
    r'^[\s   ]*(\p{L}+)',
    unicode: true,
  ).firstMatch(raw.substring(last + 1));
  if (word == null) return false;
  final w = word.group(1)!.toLowerCase();
  if (_multipliers.contains(w) || _cjkMultiplier.hasMatch(w)) return true;
  return !_currencyWords.contains(w);
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

/// Signed minor units for an amount typed in any of the forms above, with
/// its minus written in any of the forms [amountSign] reads, or null.
int? parseSignedAmountInput(String raw, Currency c) {
  final sign = amountSign(raw);
  if (sign == null) return null;
  final t = normalizeAmountInput(raw.trim(), currency: c, allowSign: true);
  if (t == null || t.isEmpty) return null;
  final v = Money.parseMinor(t.startsWith('.') ? '0$t' : t, c);
  return v == null ? null : sign * v;
}
