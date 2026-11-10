// The incremental fold behind LedgerReducer (SPEC 7.2). Owner: core.
//
// State per entity key (groupId, entityType, entityId): `created` and one
// LWW register per field. A materialized model is rebuilt from that state
// whenever an op touches the entity. Every visible value is "the max-HLC
// write per field over the op set", so the result does not depend on the
// order ops arrive in, or on duplicates.
//
// Member and expense ids are scoped by group: an op only ever touches the
// entity of its own group. When the same id has ops in several groups (ids
// are UUIDs, so only hostile input does this), each group materializes its
// own entity from its own ops, and nothing written in one group can hide or
// change the entity of another (QA SECURITY-R1-04). No rule over HLCs or op
// kinds could do that, since a member of one group can forge any of them.
import '../hlc.dart';
import '../ids.dart';
import '../ledger_state.dart';
import '../models.dart';
import '../ops.dart';
import 'canonical.dart';
import 'materialize.dart';

final class _EntityKey {
  const _EntityKey(this.groupId, this.type, this.id);
  final GroupId groupId;
  final EntityType type;
  final String id;

  @override
  bool operator ==(Object other) =>
      other is _EntityKey &&
      other.groupId == groupId &&
      other.type == type &&
      other.id == id;

  @override
  int get hashCode => Object.hash(groupId, type, id);
}

final class _GroupMaterial {
  Group? group;
  final Map<MemberId, Member> members = {};
  final Map<ExpenseId, Expense> expenses = {};
}

final class ReducerEngine {
  final Set<OpId> _applied = {};
  final Map<_EntityKey, EntityState> _entities = {};
  final Map<GroupId, _GroupMaterial> _groups = {};

  final Set<GroupId> _dirty = {};
  final Map<GroupId, GroupState> _cache = {};
  LedgerState? _snapshot;

  bool apply(Operation op) {
    if (!_applied.add(op.id)) return false;
    if (op.isFromNewerSchema) return false;
    if (op.entityType == EntityType.group && op.entityId != op.groupId) {
      return false;
    }

    var changed = false;
    final material = _groups[op.groupId];
    if (material == null) {
      _groups[op.groupId] = _GroupMaterial();
      _dirty.add(op.groupId);
      _snapshot = null;
      changed = true; // a new GroupState appears
    }

    final key = _EntityKey(op.groupId, op.entityType, op.entityId);
    final s = _entities.putIfAbsent(key, EntityState.new);
    for (final e in op.payload.entries) {
      final current = s.fields[e.key];
      if (current == null || current.losesTo(op.hlc, op.id)) {
        s.fields[e.key] = FieldValue(op.hlc, op.id, e.value);
      }
    }
    if (op.kind == OpKind.create) s.created = true;
    final maxHlc = s.maxHlc;
    if (maxHlc == null || op.hlc > maxHlc) s.maxHlc = op.hlc;

    changed |= _rematerialize(op.groupId, op.entityType, op.entityId);
    return changed;
  }

  /// Max HLC over the ops applied to one entity of [groupId], or null when
  /// none was.
  Hlc? lastHlcOf(GroupId groupId, EntityType type, String id) =>
      _entities[_EntityKey(groupId, type, id)]?.maxHlc;

  Set<String> applyAll(Iterable<Operation> ops) => {
        for (final op in ops)
          if (apply(op)) op.entityId,
      };

  LedgerState get state {
    final cached = _snapshot;
    if (cached != null) return cached;
    for (final id in _dirty) {
      final m = _groups[id]!;
      _cache[id] = GroupState(
        groupId: id,
        group: m.group,
        members: Map.unmodifiable(m.members),
        expenses: Map.unmodifiable(m.expenses),
      );
    }
    _dirty.clear();
    return _snapshot = LedgerState(Map.unmodifiable(_cache));
  }

  /// Rebuilds one entity's model inside [groupId]; true if it changed.
  bool _rematerialize(GroupId groupId, EntityType type, String id) {
    final m = _groups[groupId]!;
    final s = _entities[_EntityKey(groupId, type, id)];
    final bool changed;
    switch (type) {
      case EntityType.group:
        final next = s == null ? null : buildGroup(id, s);
        changed = !_same(m.group, next, sameGroup);
        m.group = next;
      case EntityType.member:
        final next = s == null ? null : buildMember(groupId, id, s);
        changed = !_same(m.members[id], next, sameMember);
        if (next == null) {
          m.members.remove(id);
        } else {
          m.members[id] = next;
        }
      case EntityType.expense:
        final next = s == null ? null : buildExpense(groupId, id, s);
        changed = !_same(m.expenses[id], next, sameExpense);
        if (next == null) {
          m.expenses.remove(id);
        } else {
          m.expenses[id] = next;
        }
    }
    if (changed) {
      _dirty.add(groupId);
      _snapshot = null;
    }
    return changed;
  }

  static bool _same<T>(T? a, T? b, bool Function(T, T) same) {
    if (a == null || b == null) return a == null && b == null;
    return same(a, b);
  }
}
