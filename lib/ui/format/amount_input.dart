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
///   decoration and are dropped;
/// - with both '.' and ',', the last one is the decimal separator and the
///   other may only group digits before it ("1.234,50", "1,234.50");
/// - commas only: several commas group ("1,20,000"); a single comma groups
///   when exactly three digits follow it ("1,000", as the field shows a
///   thousand), otherwise it is a decimal comma ("12,5", "12,");
/// - dots only: a single dot is the decimal point ("12.345" in KWD);
///   several dots group, as long as every group after the first has three
///   digits (the last may still be being typed: "1.234.5").
///
/// The fraction is not cut to the currency here; callers decide.
String? normalizeAmountInput(String raw) {
  final kept = raw.replaceAll(RegExp(r'[^0-9.,]'), '');
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
      return _validGroups(parts, allowLakh: true) ? parts.join() : null;
    }
    final after = parts[1];
    if (after.length == 3 && parts[0].isNotEmpty) return parts.join();
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
    if (parts.first.isEmpty) return null;
    return parts.join();
  }
  return kept;
}

/// Groups after the first have three digits (or two, Indian lakh/crore
/// style, before a final group of three); the first is 1..3 digits.
bool _validGroups(List<String> groups, {bool allowLakh = false}) {
  if (groups.length < 2) return true;
  final first = groups.first.length;
  if (first < 1 || first > 3) return false;
  for (var i = 1; i < groups.length; i++) {
    final n = groups[i].length;
    final last = i == groups.length - 1;
    if (n == 3) continue;
    if (allowLakh && !last && n == 2) continue;
    return false;
  }
  return true;
}

/// Minor units for an amount typed in any of the forms above, or null when
/// it cannot be read, has more decimals than [c] allows, or is too large.
int? parseAmountInput(String raw, Currency c) {
  final t = normalizeAmountInput(raw.trim());
  if (t == null || t.isEmpty) return null;
  return Money.parseMinor(t, c);
}
