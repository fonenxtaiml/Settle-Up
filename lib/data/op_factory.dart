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
    required this._clock,
    this.ids = const UuidV7Generator(),
    this.lastHlcOf,
    this.newestStamp,
    int Function()? nowMillis,
  }) : _now = nowMillis ?? _wallClock;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// A plain local op is never stamped more than this ahead of the wall
  /// clock (the drift [HlcClock.receive] still adopts from a peer).
  ///
  /// The clock only moves forward, so one edit made while this phone's
  /// wall clock ran days ahead would otherwise stamp every later op just as
  /// far ahead, and peers hold back ops stamped more than
  /// `Ledger.maxRemoteAheadMs` ahead of theirs (DATA-R29-01). When the
  /// clock is further ahead than this, it is first set back to the newest
  /// stamp this phone holds within the lead ([newestStamp]): later ops are
  /// still stamped after everything the user saw within it, and a local
  /// edit still beats the entity's newest op ([lastHlcOf], see
  /// [HlcClock.tickAfter]; one of this phone's own stamps beyond the
  /// adopt window is followed, so the edit waits with the entity).
  static const int maxLeadMs = HlcClock.maxForwardDriftMs;

  final DeviceId deviceId;
  final IdGenerator ids;
  final int Function() _now;
  HlcClock _clock;

  /// This device's clock. Replaced (keeping [HlcClock.skewDetected]) when
  /// it has to be set back, see [maxLeadMs].
  HlcClock get clock => _clock;

  /// The newest stamp of a stored op (any device) whose millis are at most
  /// the given value, or of any stored op when it is null.
  final Hlc? Function(int? maxMillis)? newestStamp;

  /// The newest HLC already applied to an entity (the reducer's view). Each
  /// op is stamped after it, so a local edit always beats the value the
  /// user saw, even one written by a phone whose clock is ahead.
  final Hlc? Function(GroupId groupId, EntityType type, String entityId)?
      lastHlcOf;
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

  /// The stamp of a new op on an entity whose newest op is [floor] (null
  /// for a create), [pending] being the ops of the batch built so far.
  Hlc _stamp(Hlc? floor, List<Operation> pending) {
    final now = _now();
    if (floor != null &&
        floor.deviceId == deviceId &&
        floor.millis > now + HlcClock.maxAdoptDriftMs) {
      // This phone wrote the entity's newest op while its clock was far
      // ahead: stamp after it (and after every stamp held, so no two own
      // ops share one) rather than let the edit lose to it.
      final top = _newest([
        _clock.last,
        newestStamp?.call(null),
        for (final op in pending) op.hlc,
      ]);
      if (top > _clock.last) _setClock(top);
      return _clock.tickAfter(floor);
    }
    final limit = now + maxLeadMs;
    if (_clock.last.millis > limit) {
      _setClock(_newest([
        Hlc.zero(deviceId),
        newestStamp?.call(limit),
        for (final op in pending)
          if (op.hlc.millis <= limit) op.hlc,
      ]));
    }
    return floor == null ? _clock.tick() : _clock.tickAfter(floor);
  }

  static Hlc _newest(List<Hlc?> stamps) =>
      stamps.nonNulls.reduce((a, b) => a > b ? a : b);

  void _setClock(Hlc last) {
    _clock = HlcClock(
      deviceId: deviceId,
      last: Hlc(last.millis, last.counter, deviceId),
      nowMillis: _now,
    )..skewDetected = _clock.skewDetected;
  }

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
    final floor = _factory.lastHlcOf?.call(groupId, type, entityId);
    final hlc = _factory._stamp(floor, _ops);
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
