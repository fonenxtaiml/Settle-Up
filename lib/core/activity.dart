// FROZEN CONTRACT (docs/SPEC.md section 5.8). Owner: core.
import 'package:meta/meta.dart';

import 'ids.dart';
import 'ledger_state.dart';
import 'models.dart';
import 'ops.dart';
import 'reducer/canonical.dart';

enum ActivityKind {
  groupCreated,
  groupEdited,
  groupDeleted,
  memberAdded,
  memberEdited,
  memberRemoved,
  membersMerged,
  memberClaimed,
  expenseAdded,
  expenseEdited,
  expenseDeleted,
  expenseRestored,
  paymentAdded,
  paymentEdited,
  paymentDeleted,
  paymentRestored,
}

@immutable
final class FieldChange {
  const FieldChange(this.before, this.after);
  final Object? before; // JSON value before this op (null if unset)
  final Object? after;
}

@immutable
final class ActivityEntry {
  const ActivityEntry({
    required this.op,
    required this.kind,
    required this.actor,
    required this.changes,
    required this.isLocal,
    required this.isShared,
    required this.supersededBy,
  });

  final Operation op;
  final ActivityKind kind;

  /// Member in op.groupId whose deviceId == op.deviceId, else null
  /// ("Someone on `device name`").
  final MemberId? actor;

  /// Field -> before/after, computed by replaying the entity's earlier ops
  /// in HLC order. For create ops: before == null.
  final Map<String, FieldChange> changes;
  final bool isLocal; // authored on this device
  final bool isShared; // local op already acknowledged by some peer

  /// For `money` LWW conflicts: the op id that overwrote this op's money
  /// value although it was concurrent (UI: "Priya also edited ..."), else null.
  final OpId? supersededBy;

  GroupId get groupId => op.groupId;
  String get entityId => op.entityId;
  DateTime get at => DateTime.fromMillisecondsSinceEpoch(op.hlc.millis, isUtc: true);
}

abstract final class ActivityBuilder {
  /// Newest first. [ops] = every stored op (any order). Merge-only ops of
  /// newer schema are skipped. [groupId] null = all groups.
  ///
  /// Ops the reducer ignores (a group op whose entityId is not its groupId)
  /// are skipped too.
  static List<ActivityEntry> build({
    required List<Operation> ops,
    required LedgerState state,
    required DeviceId localDeviceId,
    required Set<OpId> unsharedOpIds,
    GroupId? groupId,
  }) {
    final entries = _entries(
      ops: ops,
      state: state,
      localDeviceId: localDeviceId,
      unsharedOpIds: unsharedOpIds,
      include: (op) => groupId == null || op.groupId == groupId,
    );
    return entries.reversed.toList();
  }

  /// Edit history of one entity, oldest first. Entity ids are scoped by
  /// group (SPEC 7.2): pass [groupId] to read one group's entity only;
  /// null = that id in every group.
  static List<ActivityEntry> historyOf({
    required List<Operation> ops,
    required LedgerState state,
    required DeviceId localDeviceId,
    required Set<OpId> unsharedOpIds,
    required String entityId,
    GroupId? groupId,
  }) =>
      _entries(
        ops: ops,
        state: state,
        localDeviceId: localDeviceId,
        unsharedOpIds: unsharedOpIds,
        include: (op) =>
            op.entityId == entityId &&
            (groupId == null || op.groupId == groupId),
      );

  /// Entries for the ops accepted by [include], oldest first (HLC order).
  static List<ActivityEntry> _entries({
    required List<Operation> ops,
    required LedgerState state,
    required DeviceId localDeviceId,
    required Set<OpId> unsharedOpIds,
    required bool Function(Operation op) include,
  }) {
    // Same filtering as the reducer: dedupe by id, skip newer schema and
    // ops the reducer would ignore.
    final seen = <OpId>{};
    final valid = <Operation>[];
    for (final op in ops) {
      if (!seen.add(op.id) || op.isFromNewerSchema) continue;
      if (op.entityType == EntityType.group && op.entityId != op.groupId) {
        continue;
      }
      valid.add(op);
    }
    valid.sort(_byHlc);

    // Only entities that have an included op need replaying. Entities are
    // keyed by group, as in the reducer.
    final wanted = <(GroupId, EntityType, String)>{
      for (final op in valid)
        if (include(op)) (op.groupId, op.entityType, op.entityId),
    };
    final byEntity = <(GroupId, EntityType, String), List<Operation>>{};
    for (final op in valid) {
      final key = (op.groupId, op.entityType, op.entityId);
      if (wanted.contains(key)) byEntity.putIfAbsent(key, () => []).add(op);
    }

    final out = <ActivityEntry>[];
    for (final entityOps in byEntity.values) {
      final superseded = _supersededMoney(entityOps);
      // Replay in HLC order. Ops are sorted, so the current value of a field
      // is simply the latest earlier write.
      final current = <String, Object?>{};
      for (final op in entityOps) {
        final changes = <String, FieldChange>{};
        op.payload.forEach((field, after) {
          if (op.kind == OpKind.create) {
            changes[field] = FieldChange(null, after);
          } else if (!jsonEquals(current[field], after)) {
            changes[field] = FieldChange(current[field], after);
          }
          current[field] = after;
        });
        if (!include(op)) continue;
        out.add(ActivityEntry(
          op: op,
          kind: _kindOf(op, current, state),
          actor: _actor(state.groups[op.groupId], op.deviceId),
          changes: Map.unmodifiable(changes),
          isLocal: op.deviceId == localDeviceId,
          isShared:
              op.deviceId == localDeviceId && !unsharedOpIds.contains(op.id),
          supersededBy: superseded[op.id],
        ));
      }
    }
    out.sort((a, b) => _byHlc(a.op, b.op));
    return out;
  }

  static int _byHlc(Operation a, Operation b) {
    final c = a.hlc.compareTo(b.hlc);
    return c != 0 ? c : a.id.compareTo(b.id);
  }

  /// Money conflicts. Ops carry no causal metadata, so "concurrent" is
  /// approximated as: the final winning `money` write came from another
  /// device than this op, and this op was that device's last `money` write
  /// for the entity (the version its author still expects to see). Earlier
  /// writes that the same device replaced itself are not conflicts.
  static Map<OpId, OpId> _supersededMoney(List<Operation> entityOps) {
    final writes = [
      for (final op in entityOps)
        if (op.entityType == EntityType.expense &&
            op.payload.containsKey(ExpenseFields.money))
          op,
    ];
    if (writes.length < 2) return const {};
    final winner = writes.last; // max HLC
    final lastByDevice = <DeviceId, Operation>{};
    for (final op in writes) {
      lastByDevice[op.deviceId] = op;
    }
    return {
      for (final op in lastByDevice.values)
        if (op.deviceId != winner.deviceId &&
            !jsonEquals(op.payload[ExpenseFields.money],
                winner.payload[ExpenseFields.money]))
          op.id: winner.id,
    };
  }

  static ActivityKind _kindOf(
      Operation op, Map<String, Object?> fields, LedgerState state) {
    switch (op.entityType) {
      case EntityType.group:
        return switch (op.kind) {
          OpKind.create => ActivityKind.groupCreated,
          OpKind.delete => ActivityKind.groupDeleted,
          OpKind.update || OpKind.restore => ActivityKind.groupEdited,
        };
      case EntityType.member:
        switch (op.kind) {
          case OpKind.create:
            return ActivityKind.memberAdded;
          case OpKind.delete:
            return ActivityKind.memberRemoved;
          case OpKind.restore:
            return ActivityKind.memberEdited;
          case OpKind.update:
            if (op.payload[MemberFields.mergedInto] is String) {
              return ActivityKind.membersMerged;
            }
            if (op.payload[MemberFields.deviceId] is String) {
              return ActivityKind.memberClaimed;
            }
            return ActivityKind.memberEdited;
        }
      case EntityType.expense:
        final kindName = fields[ExpenseFields.kind] ??
            state.groups[op.groupId]?.expenses[op.entityId]?.kind.name;
        final payment = kindName == ExpenseKind.payment.name;
        return switch (op.kind) {
          OpKind.create =>
            payment ? ActivityKind.paymentAdded : ActivityKind.expenseAdded,
          OpKind.update =>
            payment ? ActivityKind.paymentEdited : ActivityKind.expenseEdited,
          OpKind.delete =>
            payment ? ActivityKind.paymentDeleted : ActivityKind.expenseDeleted,
          OpKind.restore => payment
              ? ActivityKind.paymentRestored
              : ActivityKind.expenseRestored,
        };
    }
  }

  /// The member claimed by [deviceId] in [group] (active first, then lowest
  /// id), resolved through merges.
  static MemberId? _actor(GroupState? group, DeviceId deviceId) {
    if (group == null) return null;
    Member? best;
    var bestActive = false;
    for (final m in group.members.values) {
      if (m.deviceId != deviceId) continue;
      final active = !m.isRemoved && group.resolve(m.id) == m.id;
      if (best == null ||
          (active && !bestActive) ||
          (active == bestActive && m.id.compareTo(best.id) < 0)) {
        best = m;
        bestActive = active;
      }
    }
    return best == null ? null : group.resolve(best.id);
  }
}
