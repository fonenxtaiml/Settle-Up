// FROZEN CONTRACT (docs/SPEC.md sections 6.2 to 6.5). Owner: core.
import 'package:collection/collection.dart';
import 'package:meta/meta.dart';

import 'ids.dart';
import 'ledger_state.dart';
import 'models.dart';
import 'split.dart';

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
  static NetsByCurrency groupNets(GroupState group) {
    final nets = <String, Map<MemberId, int>>{};
    for (final e in group.liveExpenses) {
      final cur = nets.putIfAbsent(e.money.currency, () => {});
      e.money.paid.forEach((m, v) {
        final r = group.resolve(m);
        cur[r] = (cur[r] ?? 0) + v;
      });
      e.money.owed.forEach((m, v) {
        final r = group.resolve(m);
        cur[r] = (cur[r] ?? 0) - v;
      });
    }
    final out = <String, Map<MemberId, int>>{};
    for (final c in nets.keys.toList()..sort()) {
      final byMember = nets[c]!;
      final kept = {
        for (final m in byMember.keys.toList()..sort())
          if (byMember[m] != 0) m: byMember[m]!,
      };
      if (kept.isNotEmpty) out[c] = kept;
    }
    return out;
  }

  /// "Original" view: who owes whom from actual expenses, netted per pair
  /// and currency (SPEC 6.3). Sorted by currency, from, to.
  ///
  /// Each expense's owed amounts are spread over its payers in proportion
  /// to what they paid (largest remainder, owers in id order, each against
  /// the payers' remaining capacity). Unlike an independent allocation per
  /// ower, this keeps both sides exact: every ower's row sums to what they
  /// owe AND every payer's column sums to what they paid, so the pairwise
  /// debts settle [groupNets] to the minor unit even with several payers.
  static List<Transfer> pairwiseDebts(GroupState group) {
    // currency -> (from, to) -> amount, with from < to by id; the sign
    // carries the direction (positive: from owes to).
    final pairs = <String, Map<(MemberId, MemberId), int>>{};
    for (final e in group.liveExpenses) {
      final paid = _resolvedSums(group, e.money.paid);
      final owed = _resolvedSums(group, e.money.owed);
      final capacity = Map<MemberId, int>.of(paid);
      final cur = pairs.putIfAbsent(e.money.currency, () => {});
      for (final o in owed.keys.toList()..sort()) {
        final w = owed[o]!;
        final shares = SplitCalculator.allocate(w, capacity);
        for (final p in shares.keys) {
          final x = shares[p]!;
          capacity[p] = capacity[p]! - x;
          if (p == o) continue;
          final forward = o.compareTo(p) < 0;
          final key = forward ? (o, p) : (p, o);
          cur[key] = (cur[key] ?? 0) + (forward ? x : -x);
        }
      }
    }
    final out = <Transfer>[];
    pairs.forEach((currency, byPair) {
      byPair.forEach((key, v) {
        if (v == 0) return;
        out.add(
          v > 0
              ? Transfer(
                  from: key.$1,
                  to: key.$2,
                  amount: v,
                  currency: currency,
                )
              : Transfer(
                  from: key.$2,
                  to: key.$1,
                  amount: -v,
                  currency: currency,
                ),
        );
      });
    });
    out.sort(_byCurrencyFromTo);
    return out;
  }

  /// simplifyDebts ? DebtSimplifier over groupNets : pairwiseDebts.
  ///
  /// Per currency in ascending code order. A group without a create op
  /// uses the pairwise view.
  static List<Transfer> suggestedTransfers(GroupState group) {
    final simplify = group.group?.simplifyDebts ?? false;
    if (!simplify) return pairwiseDebts(group);
    final nets = groupNets(group);
    return [
      for (final c in nets.keys.toList()..sort())
        ...DebtSimplifier.simplify(nets[c]!, c),
    ];
  }

  static Map<MemberId, int> _resolvedSums(
    GroupState group,
    Map<MemberId, int> amounts,
  ) {
    final out = <MemberId, int>{};
    amounts.forEach((m, v) {
      final r = group.resolve(m);
      out[r] = (out[r] ?? 0) + v;
    });
    return out;
  }

  static int _byCurrencyFromTo(Transfer a, Transfer b) {
    var c = a.currency.compareTo(b.currency);
    if (c != 0) return c;
    c = a.from.compareTo(b.from);
    return c != 0 ? c : a.to.compareTo(b.to);
  }
}

abstract final class DebtSimplifier {
  /// Greedy min-cash-flow with two max-heaps (SPEC 6.4). [nets] must sum
  /// to 0. Deterministic: ties by member id ascending. <= n-1 transfers.
  static List<Transfer> simplify(Map<MemberId, int> nets, String currency) {
    final sum = nets.values.fold(0, (a, b) => a + b);
    if (sum != 0) {
      throw ArgumentError.value(nets, 'nets', 'must sum to 0 (got $sum)');
    }
    int order((int, MemberId) a, (int, MemberId) b) {
      final c = b.$1.compareTo(a.$1);
      return c != 0 ? c : a.$2.compareTo(b.$2);
    }

    final creditors = HeapPriorityQueue<(int, MemberId)>(order);
    final debtors = HeapPriorityQueue<(int, MemberId)>(order);
    nets.forEach((m, v) {
      if (v > 0) creditors.add((v, m));
      if (v < 0) debtors.add((-v, m));
    });
    final out = <Transfer>[];
    while (creditors.isNotEmpty && debtors.isNotEmpty) {
      final c = creditors.removeFirst();
      final d = debtors.removeFirst();
      final x = c.$1 < d.$1 ? c.$1 : d.$1;
      out.add(Transfer(from: d.$2, to: c.$2, amount: x, currency: currency));
      if (c.$1 - x > 0) creditors.add((c.$1 - x, c.$2));
      if (d.$1 - x > 0) debtors.add((d.$1 - x, d.$2));
    }
    return out;
  }
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
  final DateTime?
  lastActivityAt; // max expense createdAt/date, else group createdAt

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

  static const OverallBalance zero = OverallBalance(
    net: {},
    owedToMe: {},
    iOwe: {},
  );
}

abstract final class Summaries {
  /// One per visible, non-direct group, unsettled first, then by
  /// lastActivityAt desc.
  static List<GroupBalanceSummary> groups(LedgerState state, PersonId me) {
    final out = <GroupBalanceSummary>[];
    for (final g in state.visibleGroups) {
      if (g.group!.isDirect) continue;
      final mine = g.memberForPerson(me);
      DateTime? last;
      for (final e in g.liveExpenses) {
        for (final d in [e.createdAt, e.date]) {
          if (last == null || d.isAfter(last)) last = d;
        }
      }
      out.add(
        GroupBalanceSummary(
          group: g,
          myMemberId: mine == null ? null : g.resolve(mine.id),
          myNet: myNetInGroup(g, me),
          memberCount: g.activeMembers.length,
          lastActivityAt: last ?? g.group!.createdAt,
        ),
      );
    }
    out.sort((a, b) {
      if (a.isSettled != b.isSettled) return a.isSettled ? 1 : -1;
      final at = a.lastActivityAt!, bt = b.lastActivityAt!;
      final c = bt.compareTo(at);
      return c != 0 ? c : a.group.groupId.compareTo(b.group.groupId);
    });
    return out;
  }

  /// Per other person across ALL visible groups (direct included), from
  /// each group's suggestedTransfers between me and them (SPEC 6.5).
  /// Unsettled first, then by displayName.
  ///
  /// Transfers with a member the state does not hold (an expense synced
  /// before that member's create op) are keyed by the member id and carry an
  /// empty displayName until the member arrives.
  static List<PersonBalance> people(LedgerState state, PersonId me) {
    final nets = <PersonId, Map<String, int>>{};
    final groupsOf = <PersonId, Set<GroupId>>{};
    final names = <PersonId, Member>{};

    void touch(PersonId p, GroupId g) {
      nets.putIfAbsent(p, () => {});
      groupsOf.putIfAbsent(p, () => {}).add(g);
    }

    void name(Member m) {
      final best = names[m.personId];
      if (best == null ||
          m.createdAt.isAfter(best.createdAt) ||
          (m.createdAt == best.createdAt && m.id.compareTo(best.id) > 0)) {
        names[m.personId] = m;
      }
    }

    final groups = state.visibleGroups.toList()
      ..sort((a, b) => a.groupId.compareTo(b.groupId));
    for (final g in groups) {
      final mine = g.memberForPerson(me);
      if (mine == null) continue;
      final my = g.resolve(mine.id);
      PersonId personOf(MemberId id) {
        final r = g.resolve(id);
        return g.members[r]?.personId ?? r;
      }

      for (final m in g.members.values) {
        if (m.personId != me) name(m);
      }
      for (final m in g.activeMembers) {
        if (m.personId != me) touch(m.personId, g.groupId);
      }
      for (final t in BalanceCalculator.suggestedTransfers(g)) {
        final MemberId other;
        final int sign;
        if (t.to == my) {
          other = t.from;
          sign = 1;
        } else if (t.from == my) {
          other = t.to;
          sign = -1;
        } else {
          continue;
        }
        final p = personOf(other);
        if (p == me) continue;
        touch(p, g.groupId);
        final net = nets[p]!;
        net[t.currency] = (net[t.currency] ?? 0) + sign * t.amount;
      }
    }

    final out = <PersonBalance>[
      for (final p in nets.keys)
        PersonBalance(
          personId: p,
          displayName: names[p]?.displayName ?? '',
          net: Map.unmodifiable(_sortedNonZero(nets[p]!)),
          groupIds: List.unmodifiable(groupsOf[p]!.toList()..sort()),
        ),
    ];
    out.sort((a, b) {
      if (a.isSettled != b.isSettled) return a.isSettled ? 1 : -1;
      var c = a.displayName.toLowerCase().compareTo(
        b.displayName.toLowerCase(),
      );
      if (c != 0) return c;
      c = a.displayName.compareTo(b.displayName);
      return c != 0 ? c : a.personId.compareTo(b.personId);
    });
    return out;
  }

  static OverallBalance overall(LedgerState state, PersonId me) {
    final owedToMe = <String, int>{};
    final iOwe = <String, int>{};
    for (final p in people(state, me)) {
      p.net.forEach((c, v) {
        if (v > 0) owedToMe[c] = (owedToMe[c] ?? 0) + v;
        if (v < 0) iOwe[c] = (iOwe[c] ?? 0) - v;
      });
    }
    final net = <String, int>{
      for (final c in {...owedToMe.keys, ...iOwe.keys})
        c: (owedToMe[c] ?? 0) - (iOwe[c] ?? 0),
    };
    return OverallBalance(
      net: Map.unmodifiable(_sortedNonZero(net)),
      owedToMe: Map.unmodifiable(_sortedNonZero(owedToMe)),
      iOwe: Map.unmodifiable(_sortedNonZero(iOwe)),
    );
  }

  /// My net in one group (empty map if I am not a member).
  ///
  /// Settled currencies are omitted, so a settled member also gets `{}`.
  static Map<String, int> myNetInGroup(GroupState group, PersonId me) {
    final mine = group.memberForPerson(me);
    if (mine == null) return const {};
    final my = group.resolve(mine.id);
    final nets = BalanceCalculator.groupNets(group);
    return Map.unmodifiable({
      for (final c in nets.keys)
        if (nets[c]![my] != null) c: nets[c]![my]!,
    });
  }

  static Map<String, int> _sortedNonZero(Map<String, int> m) => {
    for (final k in m.keys.toList()..sort())
      if (m[k] != 0) k: m[k]!,
  };
}
