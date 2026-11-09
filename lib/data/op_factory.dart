// Builds this device's ops (docs/SPEC.md 7.1): one HLC tick and the next
// contiguous counter per op. Owner: data.
import '../core/hlc.dart';
import '../core/ids.dart';
import '../core/ops.dart';

/// Owns the HLC clock and the per-group counters of the local device.
///
/// Ops are built in an [OpBatch]; its counters only become "used" when the
/// batch is [OpBatch.commit]ted after the store accepted it, so a failed
/// write never leaves a gap in this device's counters.
final class OpFactory {
  OpFactory({
    required this.deviceId,
    required this.clock,
    this.ids = const UuidV7Generator(),
  });

  final DeviceId deviceId;
  final HlcClock clock;
  final IdGenerator ids;
  final Map<GroupId, int> _maxCounter = {};

  /// Highest counter this device has used in [groupId] (0 if none).
  int maxCounter(GroupId groupId) => _maxCounter[groupId] ?? 0;

  /// Raises the counter of [groupId] to at least [counter] (startup replay,
  /// or our own ops relayed back by a peer).
  void observe(GroupId groupId, int counter) {
    if (counter > maxCounter(groupId)) _maxCounter[groupId] = counter;
  }

  /// Forgets [groupId]'s counter (after its ops were purged locally).
  void forget(GroupId groupId) => _maxCounter.remove(groupId);

  OpBatch batch() => OpBatch._(this);
}

/// The ops of one command, inserted together in one `insertAll`.
final class OpBatch {
  OpBatch._(this._factory);

  final OpFactory _factory;
  final List<Operation> _ops = [];
  final Map<GroupId, int> _used = {};
  bool _committed = false;

  List<Operation> get ops => List.unmodifiable(_ops);
  bool get isEmpty => _ops.isEmpty;

  /// A `create` op. [payload] receives the op's HLC millis (for createdAt)
  /// and must carry every field in [required].
  Operation create(
    GroupId groupId,
    EntityType type,
    String entityId,
    List<String> required,
    Map<String, Object?> Function(int nowMs) payload,
  ) =>
      _add(groupId, type, entityId, OpKind.create, (hlc) {
        final p = payload(hlc.millis);
        final missing = required.where((f) => !p.containsKey(f));
        if (missing.isNotEmpty) {
          throw StateError('create ${type.name} misses $missing');
        }
        return p;
      });

  /// An `update` op carrying only [fields].
  Operation update(
    GroupId groupId,
    EntityType type,
    String entityId,
    Map<String, Object?> fields,
  ) {
    if (fields.isEmpty) throw StateError('empty update');
    return _add(groupId, type, entityId, OpKind.update, (_) => fields);
  }

  /// `{deletedAt: hlc.millis}`.
  Operation delete(GroupId groupId, EntityType type, String entityId) =>
      _add(groupId, type, entityId, OpKind.delete,
          (hlc) => {_deletedAt: hlc.millis});

  /// `{deletedAt: null}`.
  Operation restore(GroupId groupId, EntityType type, String entityId) =>
      _add(groupId, type, entityId, OpKind.restore, (_) => {_deletedAt: null});

  // Same key for groups, members and expenses.
  static const String _deletedAt = GroupFields.deletedAt;

  Operation _add(
    GroupId groupId,
    EntityType type,
    String entityId,
    OpKind kind,
    Map<String, Object?> Function(Hlc hlc) payload,
  ) {
    if (_committed) throw StateError('batch already committed');
    final counter =
        (_used[groupId] ?? _factory.maxCounter(groupId)) + 1;
    final hlc = _factory.clock.tick();
    final op = Operation(
      id: _factory.ids.newId(),
      groupId: groupId,
      deviceId: _factory.deviceId,
      counter: counter,
      hlc: hlc,
      entityType: type,
      entityId: entityId,
      kind: kind,
      payload: Map.unmodifiable(payload(hlc)),
    );
    _used[groupId] = counter;
    _ops.add(op);
    return op;
  }

  /// Marks the counters as used. Call after the store accepted the ops.
  void commit() {
    _committed = true;
    _used.forEach(_factory.observe);
  }
}
