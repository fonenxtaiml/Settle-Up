// FROZEN CONTRACT (docs/SPEC.md section 5.8). Owner: core.
import 'package:meta/meta.dart';

import 'ids.dart';
import 'ledger_state.dart';
import 'ops.dart';

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
  static List<ActivityEntry> build({
    required List<Operation> ops,
    required LedgerState state,
    required DeviceId localDeviceId,
    required Set<OpId> unsharedOpIds,
    GroupId? groupId,
  }) =>
      throw UnimplementedError();

  /// Edit history of one entity, oldest first.
  static List<ActivityEntry> historyOf({
    required List<Operation> ops,
    required LedgerState state,
    required DeviceId localDeviceId,
    required Set<OpId> unsharedOpIds,
    required String entityId,
  }) =>
      throw UnimplementedError();
}
