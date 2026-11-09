// FROZEN CONTRACT (docs/SPEC.md section 6.1). Owner: core.
import 'package:meta/meta.dart';

import 'ids.dart';
import 'models.dart';
import 'money.dart';

enum SplitError {
  nonPositiveTotal, // total <= 0 or > Money.maxMinor
  noParticipants,
  sumMismatch, // exact: sum(values) != total
  percentNot100, // percent: sum(bp) != 10000
  zeroWeight, // shares: a weight < 1, or sum == 0
  negativeShare, // any computed share < 0 (adjustment too large, negative exact)
}

final class SplitException implements Exception {
  const SplitException(this.error, [this.message = '']);
  final SplitError error;
  final String message;
  @override
  String toString() => 'SplitException(${error.name}: $message)';
}

/// Live editor feedback. Units: minor for exact/adjustment, basis points for
/// percent, weights for shares, 1 per head for equal.
@immutable
final class SplitCheck {
  const SplitCheck({
    required this.targetUnits,
    required this.assignedUnits,
    required this.error,
    required this.shares,
  });

  final int targetUnits; // exact: total; percent: 10000; others: assigned
  final int assignedUnits;
  final SplitError? error;
  final Map<MemberId, int>? shares; // computed minor amounts when valid

  int get remainingUnits => targetUnits - assignedUnits; // < 0 = too much
  bool get isValid => error == null;
}

abstract final class SplitCalculator {
  /// Per-member minor amounts (zero entries omitted) summing EXACTLY to
  /// [total]. Deterministic on every device. Throws [SplitException].
  static Map<MemberId, int> compute(int total, SplitSpec spec) {
    _checkTotal(total);
    final values = spec.values;
    if (values.isEmpty) {
      throw SplitException(
        spec.method == SplitMethod.shares
            ? SplitError.zeroWeight
            : SplitError.noParticipants,
        'no participants',
      );
    }
    final Map<MemberId, int> shares;
    switch (spec.method) {
      case SplitMethod.equal:
        shares = allocate(total, {for (final m in values.keys) m: 1});
      case SplitMethod.exact:
        if (values.values.any((v) => v < 0)) {
          throw const SplitException(
            SplitError.negativeShare,
            'negative exact amount',
          );
        }
        // Summed as BigInt: values that only reach total through 64-bit
        // wrap-around must not pass.
        final sum = _bigSum(values.values);
        if (sum != BigInt.from(total)) {
          throw SplitException(
            SplitError.sumMismatch,
            'assigned $sum of $total',
          );
        }
        shares = {
          for (final m in _sortedKeys(values))
            if (values[m] != 0) m: values[m]!,
        };
      case SplitMethod.percent:
        if (values.values.any((v) => v < 0)) {
          throw const SplitException(
            SplitError.negativeShare,
            'negative percentage',
          );
        }
        final sum = _bigSum(values.values);
        if (sum != BigInt.from(10000)) {
          throw SplitException(
            SplitError.percentNot100,
            'basis points sum to $sum',
          );
        }
        shares = allocate(total, values);
      case SplitMethod.shares:
        if (values.values.any((v) => v < 1)) {
          throw const SplitException(
            SplitError.zeroWeight,
            'every weight must be >= 1',
          );
        }
        shares = allocate(total, values);
      case SplitMethod.adjustment:
        // base = allocate(rest, all 1): rest ~/ n each, +1 for the first
        // rest % n ids (equal remainders tie by id ascending). Done in
        // BigInt so huge adjustments cannot wrap around 64 bits.
        final ids = _sortedKeys(values);
        final rest = BigInt.from(total) - _bigSum(values.values);
        if (rest < BigInt.zero) {
          throw SplitException(
            SplitError.negativeShare,
            'adjustments exceed total by ${-rest}',
          );
        }
        final n = BigInt.from(ids.length);
        final q = rest ~/ n;
        final r = (rest % n).toInt();
        final out = <MemberId, int>{};
        for (var i = 0; i < ids.length; i++) {
          final m = ids[i];
          final share =
              q + (i < r ? BigInt.one : BigInt.zero) + BigInt.from(values[m]!);
          if (share < BigInt.zero) {
            throw SplitException(
              SplitError.negativeShare,
              'share of $m would be $share',
            );
          }
          // Every share is >= 0 and they sum to total, so each fits an int.
          if (share != BigInt.zero) out[m] = share.toInt();
        }
        shares = out;
    }
    final sum = _sum(shares.values);
    if (sum != total || shares.values.any((v) => v <= 0)) {
      // A bug, never a user error: every method must apportion exactly.
      throw StateError('Split of $total produced $shares');
    }
    return shares;
  }

  /// Never throws; for the live remainder bar.
  static SplitCheck check(int total, SplitSpec spec) {
    final values = spec.values;
    final int target;
    final int assigned;
    switch (spec.method) {
      case SplitMethod.exact:
      case SplitMethod.adjustment:
        target = total;
        assigned = _sum(values.values);
      case SplitMethod.percent:
        target = 10000;
        assigned = _sum(values.values);
      case SplitMethod.equal:
        target = values.length;
        assigned = values.length;
      case SplitMethod.shares:
        target = _sum(values.values);
        assigned = target;
    }
    SplitError? error;
    Map<MemberId, int>? shares;
    try {
      shares = compute(total, spec);
    } on SplitException catch (e) {
      error = e.error;
    }
    return SplitCheck(
      targetUnits: target,
      assignedUnits: assigned,
      error: error,
      shares: shares == null ? null : Map.unmodifiable(shares),
    );
  }

  /// Largest-remainder apportionment of [total] by non-negative [weights].
  /// floor(total*w/W) each, then +1 to the largest fractional remainders,
  /// ties broken by member id ascending (String.compareTo).
  static Map<MemberId, int> allocate(int total, Map<MemberId, int> weights) {
    if (total < 0) {
      throw ArgumentError.value(total, 'total', 'must be >= 0');
    }
    if (weights.values.any((w) => w < 0)) {
      throw const SplitException(SplitError.negativeShare, 'negative weight');
    }
    final ids = _sortedKeys(weights);
    // Fast path while every product total * w_i and the sum W stay far
    // below 2^63; otherwise the same arithmetic in BigInt.
    const small = 1 << 31;
    if (total >= small ||
        ids.length >= small ||
        weights.values.any((w) => w >= small)) {
      return _allocateBig(total, weights, ids);
    }
    final w = _sum(weights.values);
    if (w == 0) {
      throw const SplitException(SplitError.zeroWeight, 'weights sum to 0');
    }
    final base = <MemberId, int>{};
    final rem = <MemberId, int>{};
    var assigned = 0;
    for (final id in ids) {
      final product = total * weights[id]!;
      base[id] = product ~/ w;
      rem[id] = product % w;
      assigned += base[id]!;
    }
    var leftover = total - assigned;
    if (leftover > 0) {
      final order = List<MemberId>.of(ids)
        ..sort((a, b) {
          final c = rem[b]!.compareTo(rem[a]!);
          return c != 0 ? c : a.compareTo(b);
        });
      for (final id in order) {
        if (leftover == 0) break;
        base[id] = base[id]! + 1;
        leftover--;
      }
    }
    return {
      for (final id in ids)
        if (base[id]! != 0) id: base[id]!,
    };
  }

  static Map<MemberId, int> _allocateBig(
    int total,
    Map<MemberId, int> weights,
    List<MemberId> ids,
  ) {
    final w = _bigSum(weights.values);
    if (w == BigInt.zero) {
      throw const SplitException(SplitError.zeroWeight, 'weights sum to 0');
    }
    final t = BigInt.from(total);
    final base = <MemberId, int>{};
    final rem = <MemberId, BigInt>{};
    var assigned = 0;
    for (final id in ids) {
      final product = t * BigInt.from(weights[id]!);
      // base_i <= total, so it fits an int.
      base[id] = (product ~/ w).toInt();
      rem[id] = product % w;
      assigned += base[id]!;
    }
    var leftover = total - assigned;
    if (leftover > 0) {
      final order = List<MemberId>.of(ids)
        ..sort((a, b) {
          final c = rem[b]!.compareTo(rem[a]!);
          return c != 0 ? c : a.compareTo(b);
        });
      for (final id in order) {
        if (leftover == 0) break;
        base[id] = base[id]! + 1;
        leftover--;
      }
    }
    return {
      for (final id in ids)
        if (base[id]! != 0) id: base[id]!,
    };
  }

  /// Builds the atomic money block: computes paid (from [paidBy]) and owed
  /// (from [owedBy]). Throws [SplitException].
  static MoneyBlock buildMoneyBlock({
    required int total,
    required String currency,
    required SplitSpec paidBy,
    required SplitSpec owedBy,
  }) {
    final paid = compute(total, paidBy);
    final owed = compute(total, owedBy);
    return MoneyBlock(
      total: total,
      currency: currency,
      paidBy: SplitSpec(paidBy.method, _sortedCopy(paidBy.values)),
      owedBy: SplitSpec(owedBy.method, _sortedCopy(owedBy.values)),
      paid: Map.unmodifiable(paid),
      owed: Map.unmodifiable(owed),
    );
  }

  /// Money block for a payment: [from] paid [amount] to [to].
  static MoneyBlock paymentBlock({
    required MemberId from,
    required MemberId to,
    required int amount,
    required String currency,
  }) => buildMoneyBlock(
    total: amount,
    currency: currency,
    paidBy: SplitSpec.single(from, amount),
    owedBy: SplitSpec.single(to, amount),
  );

  static void _checkTotal(int total) {
    if (total <= 0 || total > Money.maxMinor) {
      throw SplitException(SplitError.nonPositiveTotal, 'total $total');
    }
  }

  static int _sum(Iterable<int> values) => values.fold(0, (a, b) => a + b);

  static BigInt _bigSum(Iterable<int> values) =>
      values.fold(BigInt.zero, (a, b) => a + BigInt.from(b));

  static List<MemberId> _sortedKeys(Map<MemberId, int> m) =>
      m.keys.toList()..sort();

  static Map<MemberId, int> _sortedCopy(Map<MemberId, int> m) =>
      Map.unmodifiable({for (final k in _sortedKeys(m)) k: m[k]!});
}
