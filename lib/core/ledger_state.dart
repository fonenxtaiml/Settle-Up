// FROZEN CONTRACT (docs/SPEC.md section 5.7). Owner: core.
// Materialized state = deterministic fold of the op SET (order independent).
import 'package:meta/meta.dart';

import 'ids.dart';
import 'models.dart';
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

  /// Canonical JSON of this group (see [LedgerState.toCanonicalJson]).
  Map<String, Object?> toCanonicalJson() => canonicalize(<String, Object?>{
        'groupId': groupId,
        'group': group == null ? null : groupToJson(group!),
        'members': {
          for (final e in members.entries) e.key: memberToJson(e.value),
        },
        'expenses': {
          for (final e in expenses.entries) e.key: expenseToJson(e.value),
        },
      })! as Map<String, Object?>;
}

@immutable
final class LedgerState {
  const LedgerState(this.groups);

  static const LedgerState empty = LedgerState({});

  final Map<GroupId, GroupState> groups;

  /// Groups with a create op and not deleted (direct groups included).
  Iterable<GroupState> get visibleGroups => groups.values
      .where((g) => g.group != null && !g.group!.isDeleted);

  Expense? expense(ExpenseId id) {
    for (final g in groups.values) {
      final e = g.expenses[id];
      if (e != null) return e;
    }
    return null;
  }

  /// Canonical, key-sorted JSON of everything materialized (including
  /// tombstones). Two replicas converge iff these are deeply equal.
  Map<String, Object?> toCanonicalJson() => canonicalize(<String, Object?>{
        'groups': {
          for (final e in groups.entries) e.key: e.value.toCanonicalJson(),
        },
      })! as Map<String, Object?>;
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
}

/// Sort order of [GroupState.activeMembers]: display name (case-insensitive,
/// then exact), then id.
int compareMembersByName(Member a, Member b) {
  var c = a.displayName.toLowerCase().compareTo(b.displayName.toLowerCase());
  if (c != 0) return c;
  c = a.displayName.compareTo(b.displayName);
  return c != 0 ? c : a.id.compareTo(b.id);
}
