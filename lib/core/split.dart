// FROZEN CONTRACT (docs/SPEC.md section 6.1). Owner: core.
import 'package:meta/meta.dart';

import 'ids.dart';
import 'models.dart';

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
  static Map<MemberId, int> compute(int total, SplitSpec spec) => throw UnimplementedError();

  /// Never throws; for the live remainder bar.
  static SplitCheck check(int total, SplitSpec spec) => throw UnimplementedError();

  /// Largest-remainder apportionment of [total] by non-negative [weights].
  /// floor(total*w/W) each, then +1 to the largest fractional remainders,
  /// ties broken by member id ascending (String.compareTo).
  static Map<MemberId, int> allocate(int total, Map<MemberId, int> weights) => throw UnimplementedError();

  /// Builds the atomic money block: computes paid (from [paidBy]) and owed
  /// (from [owedBy]). Throws [SplitException].
  static MoneyBlock buildMoneyBlock({
    required int total,
    required String currency,
    required SplitSpec paidBy,
    required SplitSpec owedBy,
  }) =>
      throw UnimplementedError();

  /// Money block for a payment: [from] paid [amount] to [to].
  static MoneyBlock paymentBlock({
    required MemberId from,
    required MemberId to,
    required int amount,
    required String currency,
  }) =>
      throw UnimplementedError();
}
