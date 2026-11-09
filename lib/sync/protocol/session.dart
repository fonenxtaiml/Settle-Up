// SyncSession: the transport-agnostic session state machine (SPEC 8.7).
//
// OPEN -> HELLO_SENT -> AUTH_SENT -> AUTHENTICATED -> EXCHANGING
//      -> (LIVE) -> CLOSING -> CLOSED, and FAILED from any state.
//
// Every inbound frame is handled by one serialized task queue, so state is
// only touched by one handler at a time. Every outbound frame goes through
// one send lock, so AEAD counters match the order frames hit the channel.
import 'dart:async';
import 'dart:collection';
import 'dart:developer' as developer;
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../core/ids.dart';
import '../../core/models.dart';
import '../../core/ops.dart';
import '../../data/repositories.dart';
import '../crypto/aead.dart';
import '../crypto/handshake.dart';
import '../sync_engine.dart';
import '../transport/transport.dart';
import 'batching.dart';
import 'codec.dart';
import 'messages.dart';

enum SessionRole { initiator, responder }

enum SessionState {
  open,
  helloSent,
  authSent,
  authenticated,
  exchanging,
  live,
  closing,
  closed,
  failed,
}

/// Session timers (SPEC 8.7). Tests shorten them.
@immutable
final class SessionTimings {
  const SessionTimings({
    this.handshakeTimeout = const Duration(seconds: 10),
    this.idleTimeout = const Duration(seconds: 20),
    this.pingAfter = const Duration(seconds: 5),
    this.liveIdleTimeout = const Duration(seconds: 30),
    this.livePingEvery = const Duration(seconds: 10),
    this.closeTimeout = const Duration(seconds: 2),
    this.progressInterval = const Duration(milliseconds: 100),
    this.liveFlushDelay = const Duration(milliseconds: 150),
    this.tick = const Duration(milliseconds: 250),
  });

  /// Channel open -> AUTHENTICATED.
  final Duration handshakeTimeout;

  /// EXCHANGING: no frame received for this long -> timeout.
  final Duration idleTimeout;

  /// EXCHANGING: send PING after this long without sending.
  final Duration pingAfter;

  /// LIVE: no frame received for this long -> timeout.
  final Duration liveIdleTimeout;

  /// LIVE: PING interval.
  final Duration livePingEvery;

  /// CLOSING: wait this long for the peer's BYE.
  final Duration closeTimeout;

  /// Progress is emitted at most this often.
  final Duration progressInterval;

  /// LIVE: local ops are collected for this long before one OPS push.
  final Duration liveFlushDelay;

  /// Granularity of the timer checks.
  final Duration tick;
}

/// What a session did (also the source of SyncSummary and SyncRecord).
@immutable
final class SessionResult {
  const SessionResult({
    required this.outcome,
    required this.peerName,
    required this.transport,
    required this.startedAt,
    required this.endedAt,
    required this.sentOps,
    required this.receivedOps,
    required this.receivedByGroup,
    required this.groupIds,
    this.failure,
    this.message = '',
    this.peerDeviceId,
    this.verificationCode,
    this.receivedAnyFrame = true,
  });

  final SyncOutcome outcome;
  final SyncFailure? failure; // null when completed
  final String message;
  final String peerName;
  final DeviceId? peerDeviceId;
  final TransportKind transport;
  final DateTime startedAt;
  final DateTime endedAt;

  /// Ops the peer acknowledged (committed on its side).
  final int sentOps;

  /// Ops received in batches we committed.
  final int receivedOps;

  /// Newly stored ops per group.
  final Map<GroupId, int> receivedByGroup;
  final List<GroupId> groupIds;
  final String? verificationCode;

  /// False when the channel ended before the peer sent anything (probe
  /// connections; the engine does not record those).
  final bool receivedAnyFrame;

  bool get isSuccess => outcome == SyncOutcome.completed;

  SyncSummary get summary => SyncSummary(
        peerName: peerName,
        peerDeviceId: peerDeviceId,
        transport: transport,
        startedAt: startedAt,
        endedAt: endedAt,
        sentOps: sentOps,
        receivedOps: receivedOps,
        receivedByGroup: receivedByGroup,
        groupIds: groupIds,
      );

  SyncRecord toRecord(String id) => SyncRecord(
        id: id,
        peerDeviceId: peerDeviceId,
        peerName: peerName,
        transport: transport,
        startedAt: startedAt,
        endedAt: endedAt,
        sentOps: sentOps,
        receivedOps: receivedOps,
        groupIds: groupIds,
        outcome: outcome,
        error: failure == null
            ? null
            : (message.isEmpty ? failure!.name : '${failure!.name}: $message'),
      );
}

/// Maps an `ERROR.code` (ours or the peer's) to the UI-facing failure.
SyncFailure failureForErrorCode(String code) => switch (code) {
      ErrorCodes.noSharedGroups => SyncFailure.noSharedGroups,
      ErrorCodes.authFailed => SyncFailure.authFailed,
      ErrorCodes.busy => SyncFailure.peerUnreachable,
      ErrorCodes.cancelled => SyncFailure.cancelled,
      ErrorCodes.internal => SyncFailure.internal,
      _ => SyncFailure.protocolMismatch, // proto, bad_frame, bad_op, too_large
    };

final class _SendFailed implements Exception {
  const _SendFailed(this.cause);
  final Object cause;
  @override
  String toString() => 'send failed: $cause';
}

final class SyncSession {
  SyncSession({
    required this.channel,
    required this.store,
    required this.role,
    this._liveMode = false,
    this.timings = const SessionTimings(),
    DateTime Function()? now,
    this.onProgress,
    this.onLive,
    this.peerNameHint = '',
  }) : _now = now ?? DateTime.now;

  final FrameChannel channel;
  final SyncStore store;
  final SessionRole role;
  final SessionTimings timings;
  final DateTime Function() _now;

  /// Throttled to [SessionTimings.progressInterval].
  final void Function(SyncProgress progress)? onProgress;

  /// Called once when the session enters LIVE, with the result so far.
  final void Function(SessionResult soFar)? onLive;

  /// Shown until the peer's HELLO arrives (e.g. the discovered name).
  final String peerNameHint;

  // ---- lifecycle
  final Completer<SessionResult> _result = Completer();
  final Stopwatch _clock = Stopwatch();
  SessionState _state = SessionState.open;
  bool _started = false;
  bool _finished = false;
  late DateTime _startedAt;
  StreamSubscription<Uint8List>? _frames;
  StreamSubscription<Operation>? _localOps;
  Timer? _ticker;
  Timer? _progressTimer;
  Timer? _liveFlushTimer;
  Timer? _sendFailedTimer;
  Future<void> _tasks = Future.value();
  Future<void> _sends = Future.value();
  Duration _lastReceived = Duration.zero;
  Duration _lastSent = Duration.zero;
  Duration _closingSince = Duration.zero;
  Duration _lastProgress = const Duration(days: -1);
  bool _progressDirty = false;

  // ---- handshake
  Handshake? _handshake;
  HandshakeKeys? _keys;
  bool _authenticated = false;
  bool _receivedAnyFrame = false;
  HelloMessage? _peerHello;
  int _maxFrame = 0;

  // ---- exchange
  bool _liveMode;
  final Set<GroupId> _vvReceived = {};
  final Set<GroupId> _myDone = {};
  final Set<GroupId> _peerDone = {};
  final Queue<PendingBatch> _pending = Queue();
  final Map<(GroupId, int), int> _inFlight = {};
  final Map<GroupId, int> _lastBatchSent = {};
  final Map<GroupId, int> _lastBatchReceived = {};
  final Map<GroupId, int> _sendTotal = {};
  final Map<GroupId, int> _peerTotal = {};
  final Map<GroupId, int> _receivedNew = {};
  final Set<OpId> _offered = {};
  final List<Operation> _liveBuffer = [];
  int _sentOps = 0;
  int _receivedOps = 0;
  int _bytesSent = 0;
  int _bytesReceived = 0;
  SyncPhase _phase = SyncPhase.handshaking;

  SessionState get state => _state;
  bool get isFinished => _finished;
  String? get verificationCode => _authenticated ? _keys?.verificationCode : null;
  List<GroupId> get sharedGroups => _keys?.sharedGroups ?? const [];
  DeviceId? get peerDeviceId => _peerHello?.deviceId;
  String get peerName => _peerHello?.deviceName ?? peerNameHint;
  bool get liveMode => _liveMode;

  /// Keeps the session open after the exchange and pushes new local ops
  /// (SPEC 8.8). Turning it off while LIVE closes the session gracefully.
  set liveMode(bool enabled) {
    _liveMode = enabled;
    if (!enabled) _enqueue(_checkComplete);
  }

  /// Runs the session to its end. Never throws: failures are reported in
  /// the result. Call once.
  Future<SessionResult> run() {
    if (_started) throw StateError('SyncSession.run called twice');
    _started = true;
    _startedAt = _now();
    _clock.start();
    _enqueue(_sendHello);
    _frames = channel.frames.listen(
      (frame) {
        _bytesReceived += frame.length;
        _lastReceived = _clock.elapsed;
        _receivedAnyFrame = true;
        _enqueue(() => _onFrame(frame));
      },
      onError: (Object e) => _enqueue(
        () => _fail(SyncFailure.connectionLost, 'Connection lost: $e'),
      ),
      onDone: () => _enqueue(_onChannelDone),
      cancelOnError: true,
    );
    _ticker = Timer.periodic(timings.tick, (_) => _onTick());
    _emitProgress(force: true);
    return _result.future;
  }

  /// Sends `ERROR cancelled` and closes (outcome cancelled).
  Future<void> cancel() async {
    if (!_started) {
      _started = true;
      _startedAt = _now();
    }
    await _fail(
      SyncFailure.cancelled,
      'Cancelled',
      sendCode: ErrorCodes.cancelled,
    );
  }

  // ------------------------------------------------------------- tasks --

  void _enqueue(FutureOr<void> Function() task) {
    _tasks = _tasks.then((_) async {
      if (_finished) return;
      try {
        await task();
      } catch (e, st) {
        await _onError(e, st);
      }
    });
  }

  Future<void> _onError(Object e, StackTrace st) async {
    if (_finished) return; // e.g. a send racing a cancel
    switch (e) {
      case ProtocolException(:final code, :final message):
        await _fail(failureForErrorCode(code), message, sendCode: code);
      case HandshakeException(:final code, :final message):
        await _fail(failureForErrorCode(code), message, sendCode: code);
      case FrameAuthException(:final message):
        await _fail(SyncFailure.authFailed, message);
      case FormatException(:final message):
        // applyRemote rejected the batch.
        await _fail(
          SyncFailure.protocolMismatch,
          'Bad op: $message',
          sendCode: ErrorCodes.badOp,
        );
      case _SendFailed(:final cause):
        // Frames the peer sent before it closed (an ERROR saying why, for
        // instance) may still be queued: let them and the end of the
        // stream decide, with a fallback in case the stream never ends.
        _sendFailedTimer ??= Timer(const Duration(seconds: 1), () {
          unawaited(_fail(SyncFailure.connectionLost, 'Connection lost: $cause'));
        });
      default:
        developer.log('Sync session error', error: e, stackTrace: st,
            name: 'settle_up.sync');
        await _fail(SyncFailure.internal, '$e', sendCode: ErrorCodes.internal);
    }
  }

  // ------------------------------------------------------------- sends --

  Future<void> _sendFrame(Uint8List Function() build) async {
    await _sendRaw(() async => build());
  }

  /// Serialized: builds (and seals) inside the lock, so AEAD counters are
  /// assigned in the order frames reach the channel.
  Future<void> _sendRaw(Future<Uint8List> Function() build) {
    final done = Completer<void>();
    _sends = _sends.then((_) async {
      try {
        final frame = await build();
        await channel.send(frame);
        _bytesSent += frame.length;
        _lastSent = _clock.elapsed;
        done.complete();
      } catch (e) {
        done.completeError(_SendFailed(e));
      }
    });
    return done.future;
  }

  Future<void> _sendPlain(SyncMessage m) =>
      _sendFrame(() => FrameCodec.plainFrame(m));

  Future<void> _sendSealed(SyncMessage m) =>
      _sendSealedBytes(FrameCodec.encodePlain(m));

  Future<void> _sendSealedBytes(Uint8List plain) {
    final cipher = _keys!.cipher;
    return _sendRaw(() => cipher.seal(plain));
  }

  Future<void> _sendHello() async {
    final keys = await store.groupKeys();
    final hs = await Handshake.start(
      initiator: role == SessionRole.initiator,
      groupKeys: keys,
      deviceId: store.localDeviceId,
      deviceName: store.localDeviceName,
      maxFrame: channel.maxFrameBytes,
      transport: channel.kind,
    );
    _handshake = hs;
    _state = SessionState.helloSent;
    await _sendFrame(() => hs.helloFrame);
  }

  // ------------------------------------------------------------ frames --

  Future<void> _onFrame(Uint8List frame) async {
    if (frame.isEmpty) {
      throw const ProtocolException(ErrorCodes.badFrame, 'empty frame');
    }
    if (frame.length > channel.maxFrameBytes) {
      throw const ProtocolException(ErrorCodes.tooLarge, 'frame too large');
    }
    if (!_authenticated) {
      if (frame[0] != FrameKind.plain) {
        throw const ProtocolException(
            ErrorCodes.badFrame, 'sealed frame before AUTH');
      }
      final msg = FrameCodec.decodePlainFrame(frame);
      switch (msg) {
        case ErrorMessage():
          await _onPeerError(msg);
        case HelloMessage() when _state == SessionState.helloSent:
          await _onHello(msg, frame);
        case AuthMessage() when _state == SessionState.authSent:
          await _onAuth(msg);
        default:
          throw ProtocolException(
              ErrorCodes.badFrame, 'unexpected ${msg.type.name} before AUTH');
      }
      return;
    }

    if (frame[0] == FrameKind.plain) {
      // Only an ERROR may still arrive in clear (the peer may have failed
      // to verify our AUTH). It can only end the session.
      final msg = FrameCodec.decodePlainFrame(frame);
      if (msg is ErrorMessage) return _onPeerError(msg);
      throw const ProtocolException(
          ErrorCodes.badFrame, 'plain frame after AUTH');
    }
    final plain = await _keys!.cipher.open(frame);
    final msg = FrameCodec.decodePlain(plain);
    switch (msg) {
      case VvMessage():
        await _onVv(msg);
      case OpsMessage():
        await _onOps(msg);
      case AckMessage():
        await _onAck(msg);
      case DoneMessage():
        await _onDone(msg);
      case PingMessage(:final t):
        await _sendSealed(PongMessage(t));
      case PongMessage():
        break;
      case ErrorMessage():
        await _onPeerError(msg);
      case ByeMessage():
        await _onBye();
      case HelloMessage() || AuthMessage():
        throw ProtocolException(
            ErrorCodes.badFrame, 'unexpected ${msg.type.name}');
    }
  }

  Future<void> _onHello(HelloMessage peer, Uint8List frame) async {
    _peerHello = peer;
    if (peer.deviceId == store.localDeviceId) {
      throw const ProtocolException(
          ErrorCodes.internal, 'Connected to this phone itself');
    }
    final keys = await _handshake!.onPeerHello(
      peer,
      frame,
      localMaxFrame: channel.maxFrameBytes,
    );
    _keys = keys;
    _maxFrame = keys.maxFrame;
    _state = SessionState.authSent;
    await _sendPlain(AuthMessage(mac: keys.myMac));
    _emitProgress();
  }

  Future<void> _onAuth(AuthMessage msg) async {
    final keys = _keys!;
    if (!keys.verifyPeerMac(msg.mac)) {
      throw const HandshakeException(ErrorCodes.authFailed, 'Bad AUTH mac');
    }
    _authenticated = true;
    _state = SessionState.authenticated;
    _phase = SyncPhase.comparing;
    // Buffer local ops from now on (pushed only in LIVE).
    _localOps = store.localOps.listen(_onLocalOp);
    for (final g in keys.sharedGroups) {
      final vv = await store.versionVector(g);
      await _sendSealed(VvMessage(groupId: g, vv: vv));
    }
    _state = SessionState.exchanging;
    _lastReceived = _clock.elapsed;
    _emitProgress(force: true);
  }

  void _requireShared(GroupId g) {
    if (!_keys!.sharedGroups.contains(g)) {
      throw const ProtocolException(ErrorCodes.badFrame, 'group not shared');
    }
  }

  Future<void> _onVv(VvMessage msg) async {
    final g = msg.groupId;
    _requireShared(g);
    if (!_vvReceived.add(g)) {
      throw const ProtocolException(ErrorCodes.badFrame, 'duplicate VV');
    }
    final peer = _peerHello!.deviceId;
    await store.recordPeerKnowledge(peer, g, msg.vv);
    final missing = [
      for (final op in await store.opsMissingFor(g, msg.vv))
        if (op.groupId == g) op,
    ];
    _sendTotal[g] = missing.length;
    for (final op in missing) {
      _offered.add(op.id);
    }
    if (missing.isEmpty) {
      _myDone.add(g);
      await _sendSealed(DoneMessage(groupId: g));
    } else {
      for (final b in planBatches(missing, _maxFrame)) {
        _pending.add(PendingBatch(g, b));
      }
      await _pump();
    }
    _emitProgress();
    await _checkComplete();
  }

  /// Sends pending batches while fewer than [kBatchWindow] are un-ACKed.
  Future<void> _pump() async {
    while (_inFlight.length < kBatchWindow && _pending.isNotEmpty) {
      final next = _pending.first;
      final g = next.groupId;
      final more = _pending.skip(1).any((b) => b.groupId == g);
      final batch = (_lastBatchSent[g] ?? 0) + 1;
      final plain = FrameCodec.encodePlain(OpsMessage(
        groupId: g,
        batch: batch,
        total: _sendTotal[g] ?? next.ops.length,
        ops: next.ops,
        more: more,
      ));
      if (plain.length + kSealOverhead > _maxFrame) {
        if (next.ops.length == 1) {
          throw ProtocolException(
              ErrorCodes.tooLarge, 'op ${next.ops.single.id} is too large');
        }
        final (a, b) = next.split();
        _pending
          ..removeFirst()
          ..addFirst(b)
          ..addFirst(a);
        continue;
      }
      _pending.removeFirst();
      _lastBatchSent[g] = batch;
      _inFlight[(g, batch)] = next.ops.length;
      _phase = SyncPhase.transferring;
      await _sendSealedBytes(plain);
      if (!more && !_myDone.contains(g)) {
        _myDone.add(g);
        await _sendSealed(DoneMessage(groupId: g));
      }
    }
  }

  Future<void> _onOps(OpsMessage msg) async {
    final g = msg.groupId;
    _requireShared(g);
    final expected = (_lastBatchReceived[g] ?? 0) + 1;
    if (msg.batch != expected) {
      throw ProtocolException(
          ErrorCodes.badFrame, 'batch ${msg.batch}, expected $expected');
    }
    for (final op in msg.ops) {
      if (op.groupId != g) {
        throw const ProtocolException(ErrorCodes.badOp, 'op of another group');
      }
    }
    _lastBatchReceived[g] = msg.batch;
    final prevTotal = _peerTotal[g] ?? 0;
    if (msg.total > prevTotal) _peerTotal[g] = msg.total;
    _phase = SyncPhase.transferring;
    final stored = msg.ops.isEmpty
        ? const <Operation>[]
        : await store.applyRemote(g, msg.ops);
    _receivedOps += msg.ops.length;
    _receivedNew[g] = (_receivedNew[g] ?? 0) + stored.length;
    final vv = await store.versionVector(g);
    await _sendSealed(AckMessage(groupId: g, batch: msg.batch, vv: vv));
    _emitProgress();
  }

  Future<void> _onAck(AckMessage msg) async {
    final g = msg.groupId;
    _requireShared(g);
    final n = _inFlight.remove((g, msg.batch));
    if (n == null) {
      throw const ProtocolException(ErrorCodes.badFrame, 'ACK for no batch');
    }
    _sentOps += n;
    await store.recordPeerKnowledge(_peerHello!.deviceId, g, msg.vv);
    await _pump();
    _emitProgress();
    await _checkComplete();
  }

  Future<void> _onDone(DoneMessage msg) async {
    _requireShared(msg.groupId);
    _peerDone.add(msg.groupId);
    await _checkComplete();
  }

  Future<void> _onPeerError(ErrorMessage msg) => _fail(
        failureForErrorCode(msg.code),
        msg.msg.isEmpty ? 'Peer error: ${msg.code}' : '${msg.code}: ${msg.msg}',
      );

  Future<void> _onBye() async {
    if (_state == SessionState.closing) return _finishSuccess();
    if (_exchangeComplete) {
      await _sendSealed(const ByeMessage());
      return _finishSuccess();
    }
    await _fail(SyncFailure.connectionLost, 'Peer closed before finishing');
  }

  Future<void> _onChannelDone() async {
    if (_state == SessionState.closing) return _finishSuccess();
    await _fail(SyncFailure.connectionLost, 'Channel closed');
  }

  bool get _exchangeComplete {
    final shared = _keys?.sharedGroups;
    if (shared == null || !_authenticated) return false;
    return _inFlight.isEmpty &&
        _pending.isEmpty &&
        shared.every((g) => _myDone.contains(g) && _peerDone.contains(g));
  }

  Future<void> _checkComplete() async {
    if (_finished) return;
    final inExchange = _state == SessionState.exchanging;
    final inLive = _state == SessionState.live;
    if (!(inExchange || inLive) || !_exchangeComplete) return;
    if (_liveMode) {
      if (inExchange) _enterLive();
      return;
    }
    _state = SessionState.closing;
    _phase = SyncPhase.finishing;
    _closingSince = _clock.elapsed;
    _emitProgress(force: true);
    await _sendSealed(const ByeMessage());
  }

  // -------------------------------------------------------------- live --

  void _enterLive() {
    _state = SessionState.live;
    _phase = SyncPhase.transferring;
    _emitProgress(force: true);
    onLive?.call(_snapshot(SyncOutcome.completed));
    _scheduleLiveFlush();
  }

  void _onLocalOp(Operation op) {
    if (_finished || !(_keys?.sharedGroups.contains(op.groupId) ?? false)) {
      return;
    }
    if (_offered.contains(op.id)) return;
    _liveBuffer.add(op);
    if (_state == SessionState.live) _scheduleLiveFlush();
  }

  void _scheduleLiveFlush() {
    if (_liveBuffer.isEmpty || _liveFlushTimer != null) return;
    _liveFlushTimer = Timer(timings.liveFlushDelay, () {
      _liveFlushTimer = null;
      _enqueue(_flushLive);
    });
  }

  Future<void> _flushLive() async {
    if (_state != SessionState.live || _liveBuffer.isEmpty) return;
    final byGroup = <GroupId, List<Operation>>{};
    for (final op in _liveBuffer) {
      if (_offered.add(op.id)) (byGroup[op.groupId] ??= []).add(op);
    }
    _liveBuffer.clear();
    for (final e in byGroup.entries) {
      final ops = e.value
        ..sort((a, b) {
          final c = a.deviceId.compareTo(b.deviceId);
          return c != 0 ? c : a.counter.compareTo(b.counter);
        });
      _sendTotal[e.key] = (_sendTotal[e.key] ?? 0) + ops.length;
      for (final b in planBatches(ops, _maxFrame)) {
        _pending.add(PendingBatch(e.key, b));
      }
    }
    await _pump();
    _emitProgress();
  }

  // ------------------------------------------------------------ timers --

  void _onTick() {
    if (_finished) return;
    final now = _clock.elapsed;
    switch (_state) {
      case SessionState.open ||
            SessionState.helloSent ||
            SessionState.authSent ||
            SessionState.authenticated:
        if (now > timings.handshakeTimeout) {
          _timeout('No answer from the other phone');
        }
      case SessionState.exchanging:
        if (now - _lastReceived > timings.idleTimeout) {
          _timeout('The other phone stopped answering');
        } else if (now - _lastSent > timings.pingAfter) {
          _ping();
        }
      case SessionState.live:
        if (now - _lastReceived > timings.liveIdleTimeout) {
          _timeout('The other phone stopped answering');
        } else if (now - _lastSent > timings.livePingEvery) {
          _ping();
        }
      case SessionState.closing:
        if (now - _closingSince > timings.closeTimeout) {
          unawaited(_finishSuccess());
        }
      case SessionState.closed || SessionState.failed:
        break;
    }
    if (_progressDirty) _emitProgress();
  }

  void _timeout(String message) {
    unawaited(_fail(SyncFailure.timeout, message));
  }

  void _ping() {
    _lastSent = _clock.elapsed; // one PING per interval
    unawaited(_sendSealed(PingMessage(_now().millisecondsSinceEpoch))
        .catchError((Object _) {}));
  }

  // ---------------------------------------------------------- progress --

  void _emitProgress({bool force = false}) {
    final cb = onProgress;
    if (cb == null || _finished) return;
    final now = _clock.elapsed;
    if (!force && now - _lastProgress < timings.progressInterval) {
      _progressDirty = true;
      _progressTimer ??= Timer(timings.progressInterval - (now - _lastProgress),
          () {
        _progressTimer = null;
        if (_progressDirty) _emitProgress();
      });
      return;
    }
    _progressDirty = false;
    _lastProgress = now;
    cb(progress);
  }

  /// The current progress (unthrottled).
  SyncProgress get progress => SyncProgress(
        peerName: peerName,
        peerDeviceId: peerDeviceId,
        transport: channel.kind,
        phase: _phase,
        groupIds: sharedGroups,
        sentOps: _sentOps,
        toSendOps: _sendTotal.values.fold(0, (a, b) => a + b),
        receivedOps: _receivedOps,
        toReceiveOps: _peerTotal.values.fold(0, (a, b) => a + b),
        bytesSent: _bytesSent,
        bytesReceived: _bytesReceived,
        verificationCode: verificationCode,
      );

  // ------------------------------------------------------------ ending --

  SessionResult _snapshot(
    SyncOutcome outcome, {
    SyncFailure? failure,
    String message = '',
  }) =>
      SessionResult(
        outcome: outcome,
        failure: failure,
        message: message,
        peerName: peerName,
        peerDeviceId: peerDeviceId,
        transport: channel.kind,
        startedAt: _startedAt,
        endedAt: _now(),
        sentOps: _sentOps,
        receivedOps: _receivedOps,
        receivedByGroup: Map.unmodifiable(_receivedNew),
        groupIds: sharedGroups,
        verificationCode: verificationCode,
        receivedAnyFrame: _receivedAnyFrame,
      );

  Future<void> _finishSuccess() async {
    if (_finished) return;
    _finished = true;
    _state = SessionState.closed;
    await _teardown();
    _result.complete(_snapshot(SyncOutcome.completed));
  }

  Future<void> _fail(
    SyncFailure failure,
    String message, {
    String? sendCode,
  }) async {
    if (_finished) return;
    _finished = true;
    _state = SessionState.failed;
    if (sendCode != null) {
      final error = ErrorMessage(sendCode, message);
      try {
        final send = _authenticated ? _sendSealed(error) : _sendPlain(error);
        await send.timeout(const Duration(seconds: 1));
      } catch (_) {
        // Best effort: the channel may already be gone.
      }
    }
    await _teardown();
    final outcome = failure == SyncFailure.cancelled
        ? SyncOutcome.cancelled
        : (_sentOps > 0 || _receivedOps > 0
            ? SyncOutcome.partial
            : SyncOutcome.failed);
    _result.complete(_snapshot(outcome, failure: failure, message: message));
  }

  Future<void> _teardown() async {
    _ticker?.cancel();
    _progressTimer?.cancel();
    _liveFlushTimer?.cancel();
    _sendFailedTimer?.cancel();
    final local = _localOps;
    _localOps = null;
    await local?.cancel();
    final frames = _frames;
    _frames = null;
    // Let queued sends drain briefly, then close the channel.
    await _sends.timeout(const Duration(seconds: 1), onTimeout: () {});
    try {
      await channel.close();
    } catch (_) {
      // Already closed.
    }
    await frames?.cancel();
  }
}
