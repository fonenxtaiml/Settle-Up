// FROZEN CONTRACT (docs/SPEC.md section 5.7). Owner: core.
// Materialized state = deterministic fold of the op SET (order independent).
import 'package:meta/meta.dart';

import 'ids.dart';
import 'models.dart';
import 'ops.dart';

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
  List<Member> get activeMembers => throw UnimplementedError();

  /// Non-deleted, consistent expenses AND payments, newest `date` first,
  /// ties by id descending.
  List<Expense> get liveExpenses => throw UnimplementedError();

  /// Follows mergedInto chains (cycle-safe: stops at the smallest id seen).
  MemberId resolve(MemberId memberId) => throw UnimplementedError();

  /// The member whose personId == [personId] (active first), if any.
  Member? memberForPerson(PersonId personId) => throw UnimplementedError();
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
  Map<String, Object?> toCanonicalJson() => throw UnimplementedError();
}

/// Incremental, idempotent, commutative reducer (SPEC 7).
/// Pure Dart. One instance owned by the data layer's Ledger.
final class LedgerReducer {
  LedgerReducer();

  static const int supportedSchemaVersion = kSchemaVersion;

  /// Applies [op]. Returns true if it changed materialized state. Re-applying
  /// the same op id is a no-op returning false. Ops with schemaVersion >
  /// supportedSchemaVersion are ignored (return false).
  bool apply(Operation op) => throw UnimplementedError();

  /// Applies many; returns ids of entities whose state changed.
  Set<String> applyAll(Iterable<Operation> ops) => throw UnimplementedError();

  /// Immutable snapshot of the current state (safe to hand to the UI).
  LedgerState get state => throw UnimplementedError();
}
