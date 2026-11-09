// The incremental fold behind LedgerReducer (SPEC 7.2). Owner: core.
//
// State per entity key (groupId, entityType, entityId): `created` and one
// LWW register per field. A materialized model is rebuilt from that state
// whenever an op touches the entity. Every visible value is "the max-HLC
// write per field over the op set", so the result does not depend on the
// order ops arrive in, or on duplicates.
import '../hlc.dart';
import '../ids.dart';
import '../ledger_state.dart';
import '../models.dart';
import '../ops.dart';
import 'canonical.dart';
import 'materialize.dart';

typedef _ClaimKey = (EntityType, String);

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

/// Decides which group owns a member/expense id when the same id shows up
/// in several groups (only possible with malicious input). The owner is the
/// group holding the lowest-HLC op for that id, ties by group id, so every
/// replica picks the same one whatever the arrival order.
final class EntityOwnership {
  final Map<_ClaimKey, Map<GroupId, Hlc>> _claims = {};

  /// Records [op]; returns the owner before and after.
  (GroupId?, GroupId) record(Operation op) {
    final key = (op.entityType, op.entityId);
    final byGroup = _claims.putIfAbsent(key, () => {});
    final before = byGroup.isEmpty ? null : _ownerOf(byGroup);
    final current = byGroup[op.groupId];
    if (current == null || op.hlc < current) byGroup[op.groupId] = op.hlc;
    return (before, _ownerOf(byGroup));
  }

  GroupId? ownerOf(EntityType type, String id) {
    final byGroup = _claims[(type, id)];
    return byGroup == null || byGroup.isEmpty ? null : _ownerOf(byGroup);
  }

  static GroupId _ownerOf(Map<GroupId, Hlc> byGroup) {
    GroupId? best;
    Hlc? bestHlc;
    for (final e in byGroup.entries) {
      final c = bestHlc == null ? -1 : e.value.compareTo(bestHlc);
      if (c < 0 || (c == 0 && e.key.compareTo(best!) < 0)) {
        best = e.key;
        bestHlc = e.value;
      }
    }
    return best!;
  }
}

final class ReducerEngine {
  final Set<OpId> _applied = {};
  final Map<_EntityKey, EntityState> _entities = {};
  final EntityOwnership _owners = EntityOwnership();
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
    final GroupId? ownerBefore;
    final GroupId ownerAfter;
    if (material == null) {
      _groups[op.groupId] = _GroupMaterial();
      _dirty.add(op.groupId);
      _snapshot = null;
      changed = true; // a new GroupState appears
    }
    if (op.entityType == EntityType.group) {
      ownerBefore = op.groupId;
      ownerAfter = op.groupId;
    } else {
      (ownerBefore, ownerAfter) = _owners.record(op);
    }

    final key = _EntityKey(op.groupId, op.entityType, op.entityId);
    final s = _entities.putIfAbsent(key, EntityState.new);
    for (final e in op.payload.entries) {
      final current = s.fields[e.key];
      if (current == null || op.hlc > current.hlc) {
        s.fields[e.key] = FieldValue(op.hlc, e.value);
      }
    }
    if (op.kind == OpKind.create) s.created = true;
    final maxHlc = s.maxHlc;
    if (maxHlc == null || op.hlc > maxHlc) s.maxHlc = op.hlc;

    changed |= _rematerialize(op.groupId, op.entityType, op.entityId);
    if (ownerBefore != null && ownerBefore != ownerAfter) {
      changed |= _rematerialize(ownerBefore, op.entityType, op.entityId);
    }
    return changed;
  }

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
    final owned =
        type == EntityType.group || _owners.ownerOf(type, id) == groupId;
    final bool changed;
    switch (type) {
      case EntityType.group:
        final next = s == null ? null : buildGroup(id, s);
        changed = !_same(m.group, next, groupToJson);
        m.group = next;
      case EntityType.member:
        final next = s == null || !owned ? null : buildMember(groupId, id, s);
        changed = !_same(m.members[id], next, memberToJson);
        if (next == null) {
          m.members.remove(id);
        } else {
          m.members[id] = next;
        }
      case EntityType.expense:
        final next =
            s == null || !owned ? null : buildExpense(groupId, id, s);
        changed = !_same(m.expenses[id], next, expenseToJson);
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

  static bool _same<T>(T? a, T? b, Map<String, Object?> Function(T) toJson) {
    if (a == null || b == null) return a == null && b == null;
    return jsonEquals(toJson(a), toJson(b));
  }
}
