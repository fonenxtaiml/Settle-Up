// FROZEN CONTRACT (docs/SPEC.md section 5.7). Owner: core.
// Materialized state = deterministic fold of the op SET (order independent).
import 'package:meta/meta.dart';

import 'hlc.dart';
import 'ids.dart';
import 'models.dart';
import 'member_order.dart';
import 'ops.dart';
import 'reducer/canonical.dart';
import 'reducer/reducer_engine.dart';

@immutable
final class GroupState {
  const GroupState({
    required this.groupId,
    required this.group,
    required this.members,
    required this.expenses,
  });

  final GroupId groupId;

  /// Null until the group's `create` op has been applied (e.g. right after
  /// joining by invite, before the first sync).
  final Group? group;
  final Map<MemberId, Member> members; // includes removed + merged
  final Map<ExpenseId, Expense> expenses; // includes deleted (tombstones)

  /// Not removed and not merged away. Sorted by displayName, then id.
  List<Member> get activeMembers {
    final out = [
      for (final m in members.values)
        if (!m.isRemoved && resolve(m.id) == m.id) m,
    ];
    out.sort(compareMembersByName);
    return out;
  }

  /// Non-deleted, consistent expenses AND payments, newest `date` first,
  /// ties by id descending.
  List<Expense> get liveExpenses {
    final out = [
      for (final e in expenses.values)
        if (!e.isDeleted && e.money.isConsistent) e,
    ];
    out.sort((a, b) {
      final c = b.date.compareTo(a.date);
      return c != 0 ? c : b.id.compareTo(a.id);
    });
    return out;
  }

  /// Follows mergedInto chains (cycle-safe: stops at the smallest id seen).
  ///
  /// SPEC 6.7: on a cycle, the smallest id IN the cycle is returned (so
  /// every member of the cycle and of any chain leading into it resolves to
  /// the same id). A missing target returns the last existing member.
  MemberId resolve(MemberId memberId) {
    final path = <MemberId>[];
    final seenAt = <MemberId, int>{};
    var current = memberId;
    while (true) {
      final member = members[current];
      if (member == null) {
        return path.isEmpty ? current : path.last;
      }
      seenAt[current] = path.length;
      path.add(current);
      final next = member.mergedInto;
      if (next == null) return current;
      final loopStart = seenAt[next];
      if (loopStart != null) {
        var smallest = path[loopStart];
        for (var i = loopStart + 1; i < path.length; i++) {
          if (path[i].compareTo(smallest) < 0) smallest = path[i];
        }
        return smallest;
      }
      current = next;
    }
  }

  /// The member whose personId == [personId] (active first), if any.
  ///
  /// Order of preference: active, then not removed, then lowest id.
  Member? memberForPerson(PersonId personId) {
    Member? best;
    int rank(Member m) => m.isRemoved ? 2 : (resolve(m.id) == m.id ? 0 : 1);
    for (final m in members.values) {
      if (m.personId != personId) continue;
      if (best == null) {
        best = m;
        continue;
      }
      final c = rank(m).compareTo(rank(best));
      if (c < 0 || (c == 0 && m.id.compareTo(best.id) < 0)) best = m;
    }
    return best;
  }

}

@immutable
final class LedgerState {
  const LedgerState(this.groups);

  static const LedgerState empty = LedgerState({});

  final Map<GroupId, GroupState> groups;

  /// Groups with a create op and not deleted (direct groups included).
  Iterable<GroupState> get visibleGroups => groups.values
      .where((g) => g.group != null && !g.group!.isDeleted);

  /// The expense [id] of [groupId]. Prefer this when the group is known:
  /// entity ids are scoped by group (SPEC 7.2), so hostile input can put the
  /// same id in two groups.
  Expense? expenseIn(GroupId groupId, ExpenseId id) =>
      groups[groupId]?.expenses[id];

  /// The expense [id] in any group. If hostile input put the id in several
  /// groups, the one in the lowest group id (the same on every replica).
  Expense? expense(ExpenseId id) {
    GroupId? best;
    Expense? found;
    for (final MapEntry(key: g, value: gs) in groups.entries) {
      final e = gs.expenses[id];
      if (e != null && (best == null || g.compareTo(best) < 0)) {
        best = g;
        found = e;
      }
    }
    return found;
  }

  /// Canonical, key-sorted JSON of everything materialized (including
  /// tombstones). Two replicas converge iff these are deeply equal.
  Map<String, Object?> toCanonicalJson() {
    final ids = groups.keys.toList()..sort();
    return {
      'groups': {for (final id in ids) id: groupStateToJson(groups[id]!)},
    };
  }
}

/// Incremental, idempotent, commutative reducer (SPEC 7).
/// Pure Dart. One instance owned by the data layer's Ledger.
final class LedgerReducer {
  LedgerReducer();

  final ReducerEngine _engine = ReducerEngine();

  static const int supportedSchemaVersion = kSchemaVersion;

  /// Applies [op]. Returns true if it changed materialized state. Re-applying
  /// the same op id is a no-op returning false. Ops with schemaVersion >
  /// supportedSchemaVersion are ignored (return false).
  bool apply(Operation op) => _engine.apply(op);

  /// Applies many; returns ids of entities whose state changed.
  Set<String> applyAll(Iterable<Operation> ops) => _engine.applyAll(ops);

  /// Immutable snapshot of the current state (safe to hand to the UI).
  LedgerState get state => _engine.state;

  /// Max HLC over the ops applied to entity [id] of [type] in [groupId]
  /// (null if none). A local write to it must be stamped later
  /// ([HlcClock.tickAfter]) so it wins last-writer-wins.
  Hlc? lastHlcOf(GroupId groupId, EntityType type, String id) =>
      _engine.lastHlcOf(groupId, type, id);
}
