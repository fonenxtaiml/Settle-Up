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
  /// clock: 5 days, so it is within the 7 days peers accept
  /// (`Ledger.maxRemoteAheadMs`) even on a peer whose clock is 2 days
  /// behind this one's, the most nearby discovery still tolerates.
  ///
  /// The clock only moves forward, so one edit made while this phone's
  /// wall clock ran more days ahead than that would otherwise stamp every
  /// later op just as far ahead, and peers would hold all of them back
  /// until real time caught up (DATA-R29-01). Within the lead the clock
  /// stays monotonic, as SPEC 5.3 has it (a wall clock set back hours or
  /// a few days changes nothing). Past it, the clock is first set back to
  /// the newest stamp this phone holds within the lead ([newestStamp]):
  /// later ops are still stamped after everything within it, and a local
  /// edit still beats the entity's newest op ([lastHlcOf], see
  /// [HlcClock.tickAfter]; a stored stamp beyond the adopt window, this
  /// phone's own or a peer's, is followed, so the edit waits with the
  /// entity).
  static const int maxLeadMs = 5 * 24 * 60 * 60 * 1000;

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
    final limit = now + maxLeadMs;
    if (_clock.last.millis > limit) {
      _setClock(_newest([
        Hlc.zero(deviceId),
        newestStamp?.call(limit),
        for (final op in pending)
          if (op.hlc.millis <= limit) op.hlc,
      ]));
    }
    final Hlc hlc;
    if (floor == null) {
      hlc = _clock.tick();
    } else if (floor.millis > now + HlcClock.maxAdoptDriftMs) {
      // The entity's newest op is stamped further ahead of the wall clock
      // than [HlcClock.tickAfter] adopts. Every stored op was within
      // `Ledger.maxRemoteAheadMs` of this phone's clock when it was written
      // or received, so the wall clock was set back since: this phone
      // wrote it while its date ran ahead, or a peer edited on top of such
      // a stamp, adopting it (MONEY-R39-01). Whoever wrote it, stamp after
      // it rather than let the edit lose to it.
      if (floor > _clock.last) _setClock(floor);
      hlc = _clock.tick();
    } else {
      hlc = _clock.tickAfter(floor);
    }
    return _pastHeld(hlc, pending);
  }

  /// [hlc], or the next stamp after every stamp held at its millis.
  ///
  /// Once the clock was set back (see [maxLeadMs]) it no longer knows the
  /// own stamps it wrote further ahead. Following a floor up there, or the
  /// wall clock reaching one, could then give a stamp this phone already
  /// used on another entity: own stamps would no longer be unique and the
  /// order of the two ops would rest on their ids.
  Hlc _pastHeld(Hlc hlc, List<Operation> pending) {
    var next = hlc;
    while (true) {
      final held = _newestOrNull([
        newestStamp?.call(next.millis),
        for (final op in pending)
          if (op.hlc.millis <= next.millis) op.hlc,
      ]);
      if (held == null || held < next) return next;
      _setClock(held);
      next = _clock.tick();
    }
  }

  static Hlc? _newestOrNull(List<Hlc?> stamps) {
    final held = stamps.nonNulls;
    return held.isEmpty ? null : held.reduce((a, b) => a > b ? a : b);
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
