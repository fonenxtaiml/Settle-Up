// FROZEN CONTRACT (docs/SPEC.md sections 6.2 to 6.5). Owner: core.
import 'package:meta/meta.dart';

import 'ids.dart';
import 'ledger_state.dart';

/// [from] should pay [to] [amount] minor units of [currency].
@immutable
final class Transfer {
  const Transfer({
    required this.from,
    required this.to,
    required this.amount,
    required this.currency,
  });

  final MemberId from;
  final MemberId to;
  final int amount; // > 0
  final String currency;

  @override
  bool operator ==(Object other) =>
      other is Transfer &&
      other.from == from &&
      other.to == to &&
      other.amount == amount &&
      other.currency == currency;

  @override
  int get hashCode => Object.hash(from, to, amount, currency);

  @override
  String toString() => 'Transfer($from -> $to $amount $currency)';
}

/// currency -> member -> net minor (positive = gets back, negative = owes).
typedef NetsByCurrency = Map<String, Map<MemberId, int>>;

abstract final class BalanceCalculator {
  /// Sum of (paid - owed) over liveExpenses (payments included), members
  /// resolved through mergedInto, per currency. Zero entries omitted;
  /// currencies whose nets are all zero omitted. Each currency sums to 0.
  static NetsByCurrency groupNets(GroupState group) => throw UnimplementedError();

  /// "Original" view: who owes whom from actual expenses, netted per pair
  /// and currency (SPEC 6.3). Sorted by currency, from, to.
  static List<Transfer> pairwiseDebts(GroupState group) => throw UnimplementedError();

  /// simplifyDebts ? DebtSimplifier over groupNets : pairwiseDebts.
  static List<Transfer> suggestedTransfers(GroupState group) => throw UnimplementedError();
}

abstract final class DebtSimplifier {
  /// Greedy min-cash-flow with two max-heaps (SPEC 6.4). [nets] must sum
  /// to 0. Deterministic: ties by member id ascending. <= n-1 transfers.
  static List<Transfer> simplify(Map<MemberId, int> nets, String currency) => throw UnimplementedError();
}

@immutable
final class GroupBalanceSummary {
  const GroupBalanceSummary({
    required this.group,
    required this.myMemberId,
    required this.myNet,
    required this.memberCount,
    required this.lastActivityAt,
  });

  final GroupState group;
  final MemberId? myMemberId;
  final Map<String, int> myNet; // currency -> minor, + = I get back
  final int memberCount; // active members
  final DateTime? lastActivityAt; // max expense createdAt/date, else group createdAt

  bool get isSettled => myNet.values.every((v) => v == 0);
}

@immutable
final class PersonBalance {
  const PersonBalance({
    required this.personId,
    required this.displayName,
    required this.net,
    required this.groupIds,
  });

  final PersonId personId;
  final String displayName; // most recently created member's name
  final Map<String, int> net; // + = they owe me, - = I owe them
  final List<GroupId> groupIds; // shared non-deleted groups incl. direct

  bool get isSettled => net.values.every((v) => v == 0);
}

@immutable
final class OverallBalance {
  const OverallBalance({
    required this.net,
    required this.owedToMe,
    required this.iOwe,
  });

  final Map<String, int> net; // owedToMe - iOwe per currency
  final Map<String, int> owedToMe; // sum of positive person balances
  final Map<String, int> iOwe; // sum of |negative| person balances

  static const OverallBalance zero =
      OverallBalance(net: {}, owedToMe: {}, iOwe: {});
}

abstract final class Summaries {
  /// One per visible, non-direct group, unsettled first, then by
  /// lastActivityAt desc.
  static List<GroupBalanceSummary> groups(LedgerState state, PersonId me) => throw UnimplementedError();

  /// Per other person across ALL visible groups (direct included), from
  /// each group's suggestedTransfers between me and them (SPEC 6.5).
  /// Unsettled first, then by displayName.
  static List<PersonBalance> people(LedgerState state, PersonId me) => throw UnimplementedError();

  static OverallBalance overall(LedgerState state, PersonId me) => throw UnimplementedError();

  /// My net in one group (empty map if I am not a member).
  static Map<String, int> myNetInGroup(GroupState group, PersonId me) => throw UnimplementedError();
}
