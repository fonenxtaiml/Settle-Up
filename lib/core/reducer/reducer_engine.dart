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

/// One group's claim on an entity id: its earliest op and, if any, its
/// earliest create op.
final class _Claim {
  _Claim(this.first);
  Hlc first;
  Hlc? firstCreate;

  void add(Operation op) {
    if (op.hlc < first) first = op.hlc;
    if (op.kind == OpKind.create) {
      final c = firstCreate;
      if (c == null || op.hlc < c) firstCreate = op.hlc;
    }
  }

  /// Negative when this claim beats [other]: a group holding a create op
  /// beats one holding only later edits (whatever their HLC), then the
  /// earliest create (or, with no create anywhere, the earliest op).
  int compareTo(_Claim other) {
    final a = firstCreate, b = other.firstCreate;
    if (a != null && b == null) return -1;
    if (a == null && b != null) return 1;
    return a != null ? a.compareTo(b!) : first.compareTo(other.first);
  }
}

/// Decides which group owns a member/expense id when the same id shows up
/// in several groups (only possible with malicious input). A group that
/// holds a create op for the id wins over groups that only hold updates,
/// deletes or restores for it, so an op in another group can never take
/// an entity away from the group it was created in (QA SECURITY-R1-04).
/// Among groups with a create, the earliest create HLC wins; with no create
/// anywhere, the earliest op. Ties by group id. The result depends only on
/// the op set, so every replica picks the same owner whatever the arrival
/// order.
final class EntityOwnership {
  final Map<_ClaimKey, Map<GroupId, _Claim>> _claims = {};

  /// Records [op]; returns the owner before and after.
  (GroupId?, GroupId) record(Operation op) {
    final key = (op.entityType, op.entityId);
    final byGroup = _claims.putIfAbsent(key, () => {});
    final before = byGroup.isEmpty ? null : _ownerOf(byGroup);
    (byGroup[op.groupId] ??= _Claim(op.hlc)).add(op);
    return (before, _ownerOf(byGroup));
  }

  GroupId? ownerOf(EntityType type, String id) {
    final byGroup = _claims[(type, id)];
    return byGroup == null || byGroup.isEmpty ? null : _ownerOf(byGroup);
  }

  static GroupId _ownerOf(Map<GroupId, _Claim> byGroup) {
    GroupId? best;
    _Claim? bestClaim;
    for (final e in byGroup.entries) {
      final c = bestClaim == null ? -1 : e.value.compareTo(bestClaim);
      if (c < 0 || (c == 0 && e.key.compareTo(best!) < 0)) {
        best = e.key;
        bestClaim = e.value;
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
      if (current == null || current.losesTo(op.hlc, op.id)) {
        s.fields[e.key] = FieldValue(op.hlc, op.id, e.value);
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
    final owned =
        type == EntityType.group || _owners.ownerOf(type, id) == groupId;
    final bool changed;
    switch (type) {
      case EntityType.group:
        final next = s == null ? null : buildGroup(id, s);
        changed = !_same(m.group, next, sameGroup);
        m.group = next;
      case EntityType.member:
        final next = s == null || !owned ? null : buildMember(groupId, id, s);
        changed = !_same(m.members[id], next, sameMember);
        if (next == null) {
          m.members.remove(id);
        } else {
          m.members[id] = next;
        }
      case EntityType.expense:
        final next =
            s == null || !owned ? null : buildExpense(groupId, id, s);
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
