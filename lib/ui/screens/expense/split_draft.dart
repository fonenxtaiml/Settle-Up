// The editable state behind the split list on Add expense: which members
// are in, the method, and the raw values typed for each. Turns into a
// SplitSpec and a live SplitCheck (SPEC 6.1) without touching widgets.
import '../../../core/ids.dart';
import '../../../core/models.dart';
import '../../../core/money.dart';
import '../../../core/split.dart';

/// Basis points have two decimals: "33.33" % -> 3333.
const Currency _percentUnits = Currency(
  code: 'PCT',
  minorDigits: 2,
  symbol: '%',
  name: 'percent',
);

/// "12.5" -> 1250 basis points; null for bad input.
int? parsePercent(String text) => Money.parseMinor(text, _percentUnits);

/// "1250" basis points -> "12.5".
String formatPercent(int bp) {
  final whole = bp ~/ 100;
  final frac = bp % 100;
  if (frac == 0) return '$whole';
  final f = frac.toString().padLeft(2, '0');
  return '$whole.${f.endsWith('0') ? f.substring(0, 1) : f}';
}

/// Signed minor units: "+50", "-50", "−50", "50".
int? parseSignedMinor(String text, Currency c) {
  var t = text.trim();
  var sign = 1;
  if (t.startsWith('-') || t.startsWith('−')) {
    sign = -1;
    t = t.substring(1);
  } else if (t.startsWith('+')) {
    t = t.substring(1);
  }
  if (t.trim().isEmpty) return 0;
  final v = Money.parseMinor(t, c);
  return v == null ? null : sign * v;
}

/// Minor units as plain input text: 60000 INR -> "600", 1250 -> "12.50".
String minorToInput(int minor, Currency c) {
  final major = minor.abs() ~/ c.minorPerMajor;
  final frac = minor.abs() % c.minorPerMajor;
  final sign = minor < 0 ? '-' : '';
  if (frac == 0) return '$sign$major';
  return '$sign$major.${frac.toString().padLeft(c.minorDigits, '0')}';
}

final class SplitDraft {
  SplitDraft({
    required this.members,
    this.method = SplitMethod.equal,
    Set<MemberId>? included,
  }) : included = included ?? members.toSet();

  /// Everyone who can take part, in display order.
  List<MemberId> members;
  SplitMethod method;
  Set<MemberId> included;

  /// Raw text per member for exact, percent and adjustment.
  final Map<MemberId, String> exact = {};
  final Map<MemberId, String> percent = {};
  final Map<MemberId, String> adjust = {};

  /// Weights for shares (>= 1).
  final Map<MemberId, int> shares = {};

  List<MemberId> get participants => [
    for (final m in members)
      if (included.contains(m)) m,
  ];

  /// The spec for [total] in [currency]; values that do not parse count as
  /// zero (the check then reports what is left).
  SplitSpec spec(Currency currency) {
    final p = participants;
    switch (method) {
      case SplitMethod.equal:
        return SplitSpec.equal(p);
      case SplitMethod.exact:
        return SplitSpec(SplitMethod.exact, {
          for (final m in p)
            if ((Money.parseMinor(exact[m] ?? '', currency) ?? 0) > 0)
              m: Money.parseMinor(exact[m]!, currency)!,
        });
      case SplitMethod.percent:
        return SplitSpec(SplitMethod.percent, {
          for (final m in p)
            if ((parsePercent(percent[m] ?? '') ?? 0) > 0)
              m: parsePercent(percent[m]!)!,
        });
      case SplitMethod.shares:
        return SplitSpec(SplitMethod.shares, {
          for (final m in p) m: shares[m] ?? 1,
        });
      case SplitMethod.adjustment:
        return SplitSpec(SplitMethod.adjustment, {
          for (final m in p)
            m: parseSignedMinor(adjust[m] ?? '', currency) ?? 0,
        });
    }
  }

  SplitCheck check(int total, Currency currency) =>
      SplitCalculator.check(total <= 0 ? 0 : total, spec(currency));

  /// Money still to assign: positive = left, negative = too much.
  int leftMinor(int total, Currency currency) {
    if (total <= 0) return 0;
    final c = check(total, currency);
    switch (method) {
      case SplitMethod.exact:
        return c.remainingUnits;
      case SplitMethod.percent:
        final rem = c.remainingUnits;
        final money = (total * rem.abs() + 9999) ~/ 10000;
        return rem < 0 ? -money : money;
      case SplitMethod.equal:
      case SplitMethod.shares:
      case SplitMethod.adjustment:
        return 0;
    }
  }

  /// Fills the values of [next] from an even split of [total], so a new
  /// method starts from a valid state.
  void switchTo(SplitMethod next, int total, Currency currency) {
    final p = participants;
    if (p.isNotEmpty && total > 0) {
      final even = SplitCalculator.allocate(total, {for (final m in p) m: 1});
      final evenPct = SplitCalculator.allocate(10000, {
        for (final m in p) m: 1,
      });
      if (next == SplitMethod.exact) {
        exact
          ..clear()
          ..addAll({
            for (final m in p) m: minorToInput(even[m] ?? 0, currency),
          });
      }
      if (next == SplitMethod.percent) {
        percent
          ..clear()
          ..addAll({for (final m in p) m: formatPercent(evenPct[m] ?? 0)});
      }
    }
    if (next == SplitMethod.shares) {
      for (final m in members) {
        shares.putIfAbsent(m, () => 1);
      }
    }
    method = next;
  }

  /// Restores a saved spec (editing an expense).
  void load(SplitSpec spec, Currency currency) {
    method = spec.method;
    included = spec.values.keys.toSet();
    switch (spec.method) {
      case SplitMethod.equal:
        break;
      case SplitMethod.exact:
        exact.addAll({
          for (final e in spec.values.entries)
            e.key: minorToInput(e.value, currency),
        });
      case SplitMethod.percent:
        percent.addAll({
          for (final e in spec.values.entries) e.key: formatPercent(e.value),
        });
      case SplitMethod.shares:
        shares.addAll(spec.values);
      case SplitMethod.adjustment:
        adjust.addAll({
          for (final e in spec.values.entries)
            if (e.value != 0) e.key: minorToInput(e.value, currency),
        });
    }
  }
}
