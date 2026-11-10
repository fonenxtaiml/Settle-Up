// Reading amounts the way people type or paste them, with one strict
// grammar per currency that every amount input uses: the big amount field,
// the split fields, the payer sheet, the adjustments and a paste into any
// of them. A text either matches the grammar and is that amount, or it is
// no amount at all: nothing in it is dropped, joined or guessed.
import '../../core/currencies_data.dart';
import '../../core/money.dart';

/// Why a text is not an amount the app can save.
enum AmountIssue {
  /// It is not a number written the way the currency is written ("Rs 500
  /// paid at Cafe 21", "2.5k", "1,2,3", "(30)"), or not one yet ("1,").
  unreadable,

  /// It has more decimals than the currency ("12.345" in USD, "800.50" in
  /// JPY), or a dot that may be a decimal point with too many decimals as
  /// well as a thousands mark ("10.000" in EUR).
  decimals,

  /// It is larger than the largest amount the app holds.
  tooLarge,
}

/// What [readAmount] makes of a text.
final class AmountReading {
  const AmountReading._(
    this.minor,
    this.issue,
    this.canonical,
    this.number, {
    this.ambiguous = false,
  });

  static const AmountReading empty = AmountReading._(null, null, '', '');

  /// Minor units (signed where the field allows a sign), or null.
  final int? minor;

  /// Why there is no amount, or null (an amount, or an empty text).
  final AmountIssue? issue;

  /// The number as "1234.50": the digits, then the decimal point and the
  /// decimals as written, when the text is a number in the currency's
  /// grammar (also when it is too large or has too many decimals);
  /// otherwise null.
  final String? canonical;

  /// The number as written, without the currency mark, the sign and the
  /// spaces around it ("Rs. 1,200/-" is "1,200"), or null when the text is
  /// not of that form.
  final String? number;

  /// With [AmountIssue.decimals]: the text also reads as a whole number
  /// in another of the currency's conventions ("10.000" in EUR).
  final bool ambiguous;

  bool get isEmpty => minor == null && issue == null;
}

/// Reads [raw] as an amount in [c]. The grammar, the same for every
/// amount input, accepts exactly:
///
/// - optional spaces at either end (any Unicode space, tab or line break);
/// - with [signed], at most one sign, '-', '−' (U+2212) or '+', first or
///   right after a currency mark before the number ("-30", "₹-30");
///   without it, no sign at all ("-30" is no amount);
/// - at most one mark of [c], before or after the number, with or without
///   a space: its code, symbol or name and a few local spellings ("₹500",
///   "Rs. 500", "500 €", "1,250 DT", "50 kr"). A mark that is also a word
///   that multiplies or divides ("K", "M", "P") counts only before the
///   number. In the lakh currencies "/-" may close it ("Rs. 500/-");
/// - digits in one of the currency's conventions, each with a single group
///   separator and a single decimal separator:
///   - the app's own: comma groups (thin spaces where a comma before three
///     digits is a decimal comma, TND), a dot decimal, and in the lakh
///     currencies also Indian 2-2-3 groups ("12,34,567");
///   - space groups (space, no-break, narrow no-break or thin space) or
///     apostrophe groups, with a dot decimal ("1 234.50", "1'234.50");
///   - where people write a decimal comma, dot or space groups with a
///     comma decimal ("1.234,50", "1 234,50");
///   - elsewhere, a comma decimal with no groups ("12,5"), unless the
///     comma groups in the app's form ("1,250" in KWD is 1250);
///   - in a currency with no decimals, dot groups too ("50.000").
///   Groups are exact (a first group of 1 to 3 digits with no leading zero,
///   then groups of three), there is at most one decimal separator, and it
///   is followed by no more digits than the currency has. A dot that reads
///   both as a decimal point with too many decimals and as a thousands mark
///   ("10.000" in EUR) is not taken either way.
///
/// Anything else (words, multipliers, two numbers, brackets, dashes, other
/// spaces or marks between the digits, short or long groups) is no amount.
/// The same text always reads the same, typed or pasted, in any field.
AmountReading readAmount(String raw, Currency c, {bool signed = false}) {
  final t = raw.trim();
  if (t.isEmpty) return AmountReading.empty;
  final parts = _split(t, c, signed: signed);
  if (parts == null) return _unreadable;
  final (sign, number, whole) = parts;
  // "1.250,-" is "1.250," read with no decimals after the comma.
  final n = _readNumber(whole == null ? number : '$number$whole', c);
  if (n == null || (whole != null && (n.$2 || !n.$1.endsWith('.')))) {
    return AmountReading._(null, AmountIssue.unreadable, null, number);
  }
  final (canonical, over, ambiguous) = n;
  if (over) {
    return AmountReading._(
      null,
      AmountIssue.decimals,
      canonical,
      number,
      ambiguous: ambiguous,
    );
  }
  final digits = canonical.split('.').first;
  final v = digits.length > 12
      ? null
      : Money.parseMinor(digits.isEmpty ? '0$canonical' : canonical, c);
  if (v == null) {
    return AmountReading._(null, AmountIssue.tooLarge, canonical, number);
  }
  return AmountReading._(sign * v, null, canonical, number);
}

const AmountReading _unreadable = AmountReading._(
  null,
  AmountIssue.unreadable,
  null,
  null,
);

/// Minor units for [raw] read in [c] ([readAmount]), or null when it is no
/// amount (a sign never is one here).
int? parseAmountInput(String raw, Currency c) => readAmount(raw, c).minor;

/// Signed minor units for [raw] read in [c] ([readAmount] with a sign), or
/// null.
int? parseSignedAmountInput(String raw, Currency c) =>
    readAmount(raw, c, signed: true).minor;

/// The mark the amount field groups thousands of [c] with: a comma, or a
/// thin space where a comma before three digits is the decimal comma
/// people write (TND "1,250" is 1.250 DT).
String amountGroupMark(Currency c) =>
    c.minorDigits >= 3 && decimalCommaCurrencies.contains(c.code) ? ' ' : ',';

/// The spaces that may group digits: the space and the no-break, narrow
/// no-break and thin spaces. A tab, a line break or another space never
/// does.
const String _groupSpaces = '    ';

/// The apostrophes that may group digits ("1'234.50").
const String _apostrophes = "'’ʼ";

final RegExp _numberChars = RegExp('^[0-9.,$_groupSpaces$_apostrophes]+\$');

final RegExp _digits = RegExp(r'^[0-9]*$');

/// [t] (trimmed) as its sign, its number (the currency mark taken off) and
/// the separator of a ",-" that marks it whole, or null when it is not of
/// the form [readAmount] reads.
(int, String, String?)? _split(String t, Currency c, {required bool signed}) {
  var rest = t;
  var sign = 0;
  void takeSign() {
    if (rest.isEmpty || sign != 0) return;
    final ch = rest[0];
    if (ch != '-' && ch != '−' && ch != '+') return;
    sign = ch == '+' ? 1 : -1;
    rest = rest.substring(1);
  }

  takeSign();
  final marks = _marksOf(c);
  var marked = false;
  for (final m in marks) {
    if (_startsWith(rest, m.text)) {
      rest = _trimSpaces(rest.substring(m.text.length), start: true);
      marked = true;
      break;
    }
  }
  if (marked) takeSign();
  final lakh = lakhCurrencies.contains(c.code);
  if (lakh && rest.length > 2 && rest.endsWith('/-')) {
    rest = rest.substring(0, rest.length - 2);
  } else if (!marked) {
    for (final m in marks) {
      if (m.prefixOnly || !_endsWith(rest, m.text)) continue;
      rest = _trimSpaces(
        rest.substring(0, rest.length - m.text.length),
        start: false,
      );
      break;
    }
  }
  // ",-" closes a whole amount ("1.250,- €", "Fr. 30.–"): no decimals.
  String? whole;
  final dash = RegExp('(?<=[0-9])[.,][-\u2013]\$').firstMatch(rest);
  if (dash != null) {
    whole = rest[dash.start];
    rest = rest.substring(0, dash.start);
  }
  if (rest.isEmpty || !_numberChars.hasMatch(rest)) return null;
  // The number starts and ends with a digit or a decimal separator, never
  // with a group space or an apostrophe.
  for (final ch in [rest[0], rest[rest.length - 1]]) {
    if (_groupSpaces.contains(ch) || _apostrophes.contains(ch)) return null;
  }
  if (sign != 0 && !signed) return null;
  return (sign == 0 ? 1 : sign, rest, whole);
}

String _trimSpaces(String s, {required bool start}) {
  var a = 0;
  var b = s.length;
  if (start) {
    while (a < b && _groupSpaces.contains(s[a])) {
      a++;
    }
  } else {
    while (b > a && _groupSpaces.contains(s[b - 1])) {
      b--;
    }
  }
  return s.substring(a, b);
}

bool _startsWith(String s, String mark) =>
    s.length > mark.length &&
    s.substring(0, mark.length).toLowerCase() == mark.toLowerCase();

bool _endsWith(String s, String mark) =>
    s.length > mark.length &&
    s.substring(s.length - mark.length).toLowerCase() == mark.toLowerCase();

/// A way a currency is marked next to an amount.
final class _Mark {
  const _Mark(this.text, {this.prefixOnly = false});

  final String text;

  /// The mark is also a word that multiplies or divides a number it
  /// follows ("2.5K", "5M", "50p"): it is read only before the number.
  final bool prefixOnly;
}

/// Words that, after a number, multiply or divide it.
const Set<String> _scaleWords = {
  'k', 'kk', 'm', 'mm', 'mn', 'b', 'bn', 't', 'tn', 'l', 'lk', 'cr', 'e', //
  'c', 'p', 'g',
};

/// Local ways of writing a currency, besides its code, symbol and name.
const Map<String, List<String>> _localMarks = {
  'INR': ['Rs.', 'Rs', 'Re.', 'Re', '₹'],
  'NPR': ['Rs.', 'Rs', 'रू'],
  'PKR': ['Rs.', 'Rs', '₨'],
  'LKR': ['Rs.', 'Rs', '₨'],
  'BDT': ['Tk.', 'Tk', '৳'],
  'USD': [r'US$', r'$'],
  'EUR': ['€'],
  'GBP': ['£'],
  'JPY': ['¥', '円', '￥'],
  'CNY': ['¥', '元', 'RMB', '￥'],
  'KRW': ['₩', '원'],
  'RUB': ['₽', 'руб.', 'руб', 'р.'],
  'UAH': ['₴', 'грн.', 'грн'],
  'PLN': ['zł', 'zl'],
  'CZK': ['Kč', 'Kc'],
  'HUF': ['Ft'],
  'DKK': ['kr.', 'kr'],
  'NOK': ['kr.', 'kr'],
  'SEK': ['kr.', 'kr'],
  'ISK': ['kr.', 'kr'],
  'CHF': ['Fr.', 'Fr', 'SFr.'],
  'THB': ['฿', 'บาท'],
  'AED': ['د.إ', 'Dhs', 'Dh'],
  'SAR': ['ر.س', 'SR'],
  'TND': ['DT', 'د.ت'],
  'KWD': ['KD', 'د.ك'],
  'BHD': ['BD'],
  'OMR': ['RO'],
  'JOD': ['JD'],
  'TRY': ['₺', 'TL'],
  'ZAR': ['R'],
  'BRL': [r'R$'],
  'IDR': ['Rp'],
  'MYR': ['RM'],
  'PHP': ['₱'],
  'VND': ['₫', 'đ'],
  'ILS': ['₪'],
  'NGN': ['₦'],
};

final Map<String, List<_Mark>> _marksCache = {};

/// Every mark of [c], longest first (so "Rs." is tried before "Rs").
List<_Mark> _marksOf(Currency c) => _marksCache.putIfAbsent(c.code, () {
  final texts = <String>{...?_localMarks[c.code]};
  if (isoCurrencies.any((x) => x.code == c.code)) {
    texts
      ..add(c.code)
      ..add(c.symbol);
    // "CA$" and "CN¥" are written with the sign alone too.
    final sign = c.symbol.replaceAll(RegExp(r'\p{L}', unicode: true), '');
    if (sign.isNotEmpty && sign != c.symbol && !sign.contains('.')) {
      texts.add(sign);
    }
    final name = c.name.split(' ').last.toLowerCase();
    texts
      ..add(name)
      ..add('${name}s');
  }
  texts.removeWhere((m) => m.isEmpty || RegExp('[0-9.,]').hasMatch(m[0]));
  return [
    for (final m in texts)
      _Mark(m, prefixOnly: _scaleWords.contains(m.toLowerCase())),
  ]..sort((a, b) => b.text.length.compareTo(a.text.length));
});

/// One way of writing digits: a group separator ([group] null for none), a
/// decimal separator ([decimal] null for none) and whether Indian lakh
/// groups are allowed.
typedef _Convention = ({String? group, String? decimal, bool lakh});

/// [number] read in the conventions of [c] as (canonical, too many
/// decimals, also a whole number in another convention), or null.
(String, bool, bool)? _readNumber(String number, Currency c) {
  final minor = c.minorDigits;
  final commaCountry = decimalCommaCurrencies.contains(c.code);
  // The app's own form first: the field's own text always reads back as
  // itself.
  final own = _readIn(number, (
    group: amountGroupMark(c),
    decimal: '.',
    lakh: lakhCurrencies.contains(c.code),
  ), minor);
  if (own != null && !own.$2) return (own.$1, false, false);
  final others = <_Convention>[
    for (final s in _groupSpaces.split('')) ...[
      (group: s, decimal: '.', lakh: false),
      if (commaCountry) (group: s, decimal: ',', lakh: false),
    ],
    for (final a in _apostrophes.split(''))
      (group: a, decimal: '.', lakh: false),
    if (commaCountry) (group: '.', decimal: ',', lakh: false),
    if (!commaCountry) (group: null, decimal: ',', lakh: false),
    if (minor == 0) (group: '.', decimal: null, lakh: false),
  ];
  final ok = <String>{};
  var over = own;
  for (final conv in others) {
    final r = _readIn(number, conv, minor);
    if (r == null) continue;
    if (r.$2) {
      over ??= r;
    } else {
      ok.add(r.$1);
    }
  }
  if (ok.isEmpty) return over == null ? null : (over.$1, true, false);
  // "10.000" in EUR: ten thousand, or ten with three decimals typed by
  // mistake. Neither is taken. (In a currency with no decimals a dot never
  // is a decimal point: VND "50.000" is fifty thousand.)
  if (own != null && minor > 0) return (own.$1, true, true);
  if (ok.length > 1) return (ok.first, true, true);
  return (ok.single, false, false);
}

/// [number] read in [conv] as (canonical, too many decimals), or null.
(String, bool)? _readIn(String number, _Convention conv, int minor) {
  var whole = number;
  String? frac;
  final d = conv.decimal;
  if (d != null) {
    final at = number.indexOf(d);
    if (at >= 0) {
      if (number.indexOf(d, at + 1) >= 0) return null;
      whole = number.substring(0, at);
      frac = number.substring(at + 1);
      if (!_digits.hasMatch(frac)) return null;
    }
  }
  final String digits;
  if (_digits.hasMatch(whole)) {
    digits = whole;
  } else {
    final g = conv.group;
    if (g == null || !_grouped(whole, g, lakh: conv.lakh)) return null;
    digits = whole.replaceAll(g, '');
  }
  if (digits.isEmpty && (frac == null || frac.isEmpty)) return null;
  final w = digits.replaceFirst(RegExp(r'^0+(?=[0-9])'), '');
  final canonical = frac == null ? w : '$w.$frac';
  // A currency with no decimals has no decimal separator either.
  return (canonical, frac != null && (minor == 0 || frac.length > minor));
}

/// Whether [whole] is digits grouped by [g] exactly: 1 to 3 digits with no
/// leading zero, then groups of three ("1,234,567"), or with [lakh] also
/// the Indian 2-2-3 form ("12,34,567").
bool _grouped(String whole, String g, {required bool lakh}) {
  final e = RegExp.escape(g);
  if (RegExp('^[1-9][0-9]{0,2}(?:$e[0-9]{3})+\$').hasMatch(whole)) {
    return true;
  }
  return lakh &&
      RegExp('^[1-9][0-9]?(?:$e[0-9]{2})+$e[0-9]{3}\$').hasMatch(whole);
}

/// Currencies whose people write a decimal comma ("12,50 €", "0,250 DT").
const Set<String> decimalCommaCurrencies = {
  'ALL', 'AOA', 'ARS', 'AZN', 'BAM', 'BGN', 'BOB', 'BRL', 'BYN', 'CLP', //
  'COP', 'CRC', 'CVE', 'CZK', 'DKK', 'DZD', 'EUR', 'GEL', 'HUF', 'IDR', //
  'ISK', 'KZT', 'MAD', 'MDL', 'MKD', 'MZN', 'NOK', 'PLN', 'PYG', 'RON', //
  'RSD', 'RUB', 'SEK', 'TND', 'TRY', 'UAH', 'UYU', 'UZS', 'VES', 'VND', //
  'XAF', 'XOF',
};

/// Currencies whose people group digits in lakhs and crores ("1,00,000").
const Set<String> lakhCurrencies = {'INR', 'NPR', 'PKR', 'BDT', 'LKR'};
