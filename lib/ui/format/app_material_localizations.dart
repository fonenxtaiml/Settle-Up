// The Material strings the app runs with: the stock English ones, with every
// date written and read day first, the way the rest of the app writes dates
// ("Sat, 8 Nov", DESIGN 5.3) and the way its users write them (VISUAL-R11-01).
//
// The app ships no flutter_localizations, so Material widgets would otherwise
// take DefaultMaterialLocalizations, which is US English: the date picker's
// field showed 9 Nov as "11/09/2026" and read "05/11/2026" as 11 May. Here
// every date format and the one date parser Material uses are day first,
// and the field's label names the format, so it is on screen the whole time
// the field holds a date, not only while it is empty.
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// The format the date field shows and reads.
const String kCompactDateFormat = 'dd/mm/yyyy';

/// Day-first English [MaterialLocalizations].
class AppMaterialLocalizations extends DefaultMaterialLocalizations {
  const AppMaterialLocalizations();

  /// Installs [AppMaterialLocalizations] for every locale, ahead of
  /// [DefaultMaterialLocalizations.delegate].
  static const LocalizationsDelegate<MaterialLocalizations> delegate =
      _Delegate();

  /// A typed date: day, month and year, one or two digits for the day and
  /// the month, separated by the same one of '/', '-' or '.'. The year is
  /// four digits, or more with no leading zero: exactly the years
  /// [formatCompactDate] writes, so the field reads back every date it
  /// shows, 1 Jan 10000 included (a model date seen east of UTC,
  /// VISUAL-R12-01). Nothing else is a date: no spaces inside it, no other
  /// characters, no short years (a two-digit year would be read as the
  /// first century).
  static final RegExp _compact = RegExp(
    r'^([0-9]{1,2})([/.\-])([0-9]{1,2})\2([0-9]{4}|[1-9][0-9]{4,5})$',
  );

  /// The last whole year a [DateTime] holds (it ends in September
  /// 275760); a later year is no date.
  static const int maxCompactYear = 275759;

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _four(int n) => n.toString().padLeft(4, '0');

  @override
  String formatCompactDate(DateTime date) =>
      '${_two(date.day)}/${_two(date.month)}/${_four(date.year)}';

  @override
  String formatShortDate(DateTime date) =>
      DateFormat('d MMM y', 'en_US').format(date);

  @override
  String formatMediumDate(DateTime date) =>
      DateFormat('EEE, d MMM', 'en_US').format(date);

  @override
  String formatFullDate(DateTime date) =>
      DateFormat('EEEE, d MMMM y', 'en_US').format(date);

  @override
  String formatShortMonthDay(DateTime date) =>
      DateFormat('d MMM', 'en_US').format(date);

  @override
  DateTime? parseCompactDate(String? inputString) {
    if (inputString == null) return null;
    final m = _compact.firstMatch(inputString.trim());
    if (m == null) return null;
    final day = int.parse(m.group(1)!);
    final month = int.parse(m.group(3)!);
    final year = int.parse(m.group(4)!);
    if (year < 1 || year > maxCompactYear) return null;
    if (month < 1 || month > 12 || day < 1) return null;
    if (day > DateUtils.getDaysInMonth(year, month)) return null;
    return DateTime(year, month, day);
  }

  @override
  String get dateHelpText => kCompactDateFormat;

  @override
  String get dateInputLabel => 'Date ($kCompactDateFormat)';
}

class _Delegate extends LocalizationsDelegate<MaterialLocalizations> {
  const _Delegate();

  @override
  bool isSupported(Locale locale) => true;

  @override
  Future<MaterialLocalizations> load(Locale locale) =>
      SynchronousFuture<MaterialLocalizations>(
        const AppMaterialLocalizations(),
      );

  @override
  bool shouldReload(_Delegate old) => false;
}
