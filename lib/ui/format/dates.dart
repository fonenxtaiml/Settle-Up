// Date and time labels for rows, headers and the sync chip (DESIGN 5.3, 5.8,
// 6.7). Model DateTimes are UTC; everything here displays local time.
//
// Copy follows DESIGN 7: "Today", "Yesterday", "Mon 4 Mar", "5 min ago".
import 'package:intl/intl.dart';

abstract final class DateLabels {
  static DateTime _day(DateTime t) => DateTime(t.year, t.month, t.day);

  /// Whole calendar days from [date] to [now] in local time (0 = same day).
  static int daysBetween(DateTime date, DateTime now) {
    final a = _day(date.toLocal());
    final b = _day(now.toLocal());
    // Use UTC midnights so DST changes do not produce 23 h days.
    final ua = DateTime.utc(a.year, a.month, a.day);
    final ub = DateTime.utc(b.year, b.month, b.day);
    return ub.difference(ua).inDays;
  }

  static bool isSameDay(DateTime a, DateTime b) => daysBetween(a, b) == 0;

  /// Date group header: "Today", "Yesterday", "Mon 4 Mar", and the year
  /// when it is not the current one ("Mon 4 Mar 2025").
  static String dayHeader(DateTime date, {DateTime? now, String? locale}) {
    final n = now ?? DateTime.now();
    final days = daysBetween(date, n);
    if (days == 0) return 'Today';
    if (days == 1) return 'Yesterday';
    final local = date.toLocal();
    final pattern = local.year == n.toLocal().year
        ? 'EEE d MMM'
        : 'EEE d MMM y';
    return DateFormat(pattern, locale).format(local);
  }

  /// Short date for meta phrases: "4 Mar" ("4 Mar 2025" in another year).
  static String shortDate(DateTime date, {DateTime? now, String? locale}) {
    final n = now ?? DateTime.now();
    final local = date.toLocal();
    final pattern = local.year == n.toLocal().year ? 'd MMM' : 'd MMM y';
    return DateFormat(pattern, locale).format(local);
  }

  /// 24 h clock: "14:02".
  static String time(DateTime date, {String? locale}) =>
      DateFormat('HH:mm', locale).format(date.toLocal());

  /// Relative time for the sync chip and recent syncs: "just now",
  /// "5 min ago", "2 h ago", "yesterday", "Sun", then "4 Mar".
  static String ago(DateTime date, {DateTime? now, String? locale}) {
    final n = now ?? DateTime.now();
    final diff = n.difference(date);
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes} min ago';
    if (diff.inHours < 24) return '${diff.inHours} h ago';
    final days = daysBetween(date, n);
    if (days <= 1) return 'yesterday';
    if (days < 7) return DateFormat('EEE', locale).format(date.toLocal());
    return shortDate(date, now: n, locale: locale);
  }

  /// Countdown for host mode: "4:32", "0:05".
  static String countdown(Duration remaining) {
    final d = remaining.isNegative ? Duration.zero : remaining;
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }
}
