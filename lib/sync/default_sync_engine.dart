// DefaultSyncEngine (SPEC 5.13, 8.7.1): hosting, discovery across
// transports, choosing a transport, one session at a time.
//
// One session at a time means one session that exchanges data. Inbound
// connections handshake in parallel, and the first to authenticate gets
// the slot, so a silent stranger cannot hold it. Connections that have not
// said HELLO yet are cheap and many may wait ([kMaxSilentInbound], at most
// [kMaxSilentPerSource] from one address); handshakes that are under way
// are bounded by [kMaxPendingInbound]. A new connection only ever evicts a
// silent one, so a stranger who keeps reconnecting cannot push out a
// friend whose handshake is progressing. Who gets the slot (SPEC 8.7.1):
// - nothing running: the session is admitted;
// - a new authenticated connection from the phone whose inbound session
//   holds the slot: it replaces that (dead or abandoned) session;
// - both phones tapped Sync on each other: the phone with the lower device
//   id gives way and serves the other one's connection; its own Sync call
//   resolves with that session's result. When one phone's own dial is still
//   connecting after a handshake timeout, it answers ERROR busy "Starting
//   its own sync" and the other phone, if it is hosting, waits for that
//   dial to arrive and serves it, whichever id is lower; Cancel ends that
//   wait. When the dial is known to be for some other phone (the link's
//   device id, or the advertised name), the answer is "Starting its own
//   sync with someone else" and the asking phone does not wait;
// - otherwise: ERROR busy.
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import '../core/ids.dart';
import '../core/models.dart';
import '../data/repositories.dart';
import 'crypto/tokens.dart';
import 'nearby_registry.dart';
import 'peer_name.dart';
import 'pairing/links.dart';
import 'protocol/codec.dart';
import 'protocol/messages.dart';
import 'protocol/session.dart';
import 'sync_clock.dart';
import 'sync_engine.dart';
import 'transport/hosting_details.dart';
import 'transport/lan/local_address.dart';
import 'transport/lan/tcp_framing.dart' show parseHostPort;
import 'transport/transport.dart';

export 'sync_clock.dart';

void _log(String message, [Object? error, StackTrace? st]) => developer.log(
      message,
      name: 'settle_up.sync',
      error: error,
      stackTrace: st,
    );

/// Inbound handshakes (HELLO received, not authenticated yet) that may run
/// at once. One more evicts the oldest of them.
const int kMaxPendingInbound = 4;

/// Inbound connections that have not said HELLO yet. A new connection
/// beyond this evicts the oldest of them, so a friend's fresh connection
/// outlives this many newer ones while its HELLO is on the way (one round
/// trip; in tests a tight reconnect loop gets about 17 in). A silent
/// connection costs a socket and a timer until its handshake timeout.
const int kMaxSilentInbound = 64;

/// Silent inbound connections from one source (the IP address on LAN). A
/// new one beyond this evicts that source's oldest, so one stranger's
/// reconnect loop only ever pushes out its own connections.
const int kMaxSilentPerSource = 4;

const String _tooMany = 'Too many phones connecting';

const String _busyOther = 'Syncing with another phone';
const String _busySame = 'Already syncing with you';

/// This phone's own Sync is still connecting and has not said whom it
/// reaches: it may well be the phone asking (both tapped Sync, one dial
/// slower than a handshake).
const String _busyDialing = 'Starting its own sync';

/// This phone's own Sync is still connecting, and not to the phone asking
/// (the link's device id or the advertised name says so): the asking phone
/// need not wait for a dial that is not coming (SYNC-R3-02). Must not end
/// with [_busyDialing].
const String _busyDialingElsewhere = 'Starting its own sync with someone else';

/// A Sync this phone started (syncWith, syncWithLink, an invite).
final class _Outbound {
  _Outbound({this.targetId, this.targetNames = const []});

  /// The phone being dialed, when the link says (connect link, invite).
  final DeviceId? targetId;

  /// The names it advertised (cut to fit the advert); empty when unknown.
  final List<String> targetNames;


  SyncSession? session;

  /// The user tapped Cancel: this attempt stops and never gives way to an
  /// inbound session (that would run the cancelled Sync after all).
  bool get cancelled => _cancel.isCompleted;
  final Completer<void> _cancel = Completer();

  /// Completes when the user taps Cancel: a connect attempt still under
  /// way is abandoned then, not when it gives up (SYNC-R4-01).
  Future<void> get whenCancelled => _cancel.future;

  void cancel() {
    if (!_cancel.isCompleted) _cancel.complete();
  }

  /// The inbound session from the same phone this attempt gave way to.
  _Run? yieldedTo;
  bool get yielded => yieldedTo != null;
}

/// A running session.
final class _Run {
  _Run(this.session, this.seq);
  final SyncSession session;

  /// Start order: a later connection from the same phone is the live one.
  final int seq;
  late final Future<SessionResult> result;

  /// Completes when the session goes LIVE.
  final Completer<SessionResult> live = Completer();

  /// Completes once the session ended and was recorded.
  final Completer<SessionResult> finished = Completer();

  /// Got the slot (SPEC 8.7.1) at some point.
  bool admitted = false;

  /// Lost the slot to a newer session from the same phone.
  bool superseded = false;
}

final class DefaultSyncEngine implements SyncEngine {
  DefaultSyncEngine({
    required this._store,
    required List<SyncTransport> transports,
    SyncClock? clock,
    this.timings = const SessionTimings(),
    this._ids = const UuidV7Generator(),
    Duration nearbyTtl = const Duration(seconds: 15),
    this.connectTimeout = const Duration(seconds: 10),
    this.linkConnectTimeout = const Duration(seconds: 4),
  })  : _transports = List.unmodifiable(transports),
        _clock = clock ?? const SystemSyncClock(),
        _registry = NearbyRegistry(ttl: nearbyTtl);

  final SyncStore _store;
  final List<SyncTransport> _transports;
  final SyncClock _clock;
  final IdGenerator _ids;
  final NearbyRegistry _registry;
  final SessionTimings timings;
  final Duration connectTimeout;
  final Duration linkConnectTimeout;

  /// Keys this phone's advert ids (SPEC 8.3). Random per launch and never
  /// sent, so nobody can link the ids of two windows.
  final Uint8List _advertSecret = DiscoveryTokens.newAdvertSecret();

  final StreamController<SyncStatus> _statusCtl = StreamController.broadcast();
  final StreamController<List<NearbyPeer>> _nearbyCtl =
      StreamController.broadcast();
  SyncStatus _status = SyncStatus.idle;
  bool _disposed = false;

  // hosting
  HostInfo? _host;
  final Map<SyncTransport, StreamSubscription<FrameChannel>> _inbound = {};
  final Set<SyncTransport> _advertising = {};
  Timer? _hostExpiry;
  Timer? _tokenRefresh;
  Future<HostInfo>? _hostStart;
  int _hostStartGen = -1;

  /// Bumped by stopHosting: a start begun before it must not take effect.
  int _hostGen = 0;

  // discovery
  final List<StreamSubscription<DiscoveredPeer>> _discoverySubs = [];
  Timer? _sweep;
  int _indexWindow = -1;
  String _keysSignature = '';
  Future<void>? _indexRefresh;

  /// Sightings are handled one at a time, each after its token index.
  Future<void> _sightings = Future.value();

  /// Bumped by every start/stop of discovery: an older start that is still
  /// awaiting must not add subscriptions afterwards.
  int _discoveryGen = 0;

  // sessions
  _Outbound? _outbound;
  SyncSession? _active;
  final List<SyncSession> _pendingInbound = [];
  final Map<SyncSession, _Run> _runs = {};
  Completer<void> _changed = Completer();
  int _runSeq = 0;
  bool _liveMode = false;

  bool get _busy => _outbound != null || _active != null;

  /// Wakes everyone waiting for the session slot to change.
  void _notify() {
    final c = _changed;
    _changed = Completer();
    c.complete();
  }

  // ------------------------------------------------------------ status --

  @override
  SyncStatus get status => _status;

  @override
  Stream<SyncStatus> watchStatus() => _currentThen(() => _status, _statusCtl);

  @override
  Stream<List<NearbyPeer>> watchNearby() =>
      _currentThen(() => _registry.peers, _nearbyCtl);

  static Stream<T> _currentThen<T>(T Function() current, StreamController<T> ctl) =>
      Stream.multi((c) {
        c.add(current());
        final sub = ctl.stream.listen(c.add, onDone: c.close);
        c.onCancel = sub.cancel;
      });

  void _setStatus({
    HostInfo? host,
    bool clearHost = false,
    bool? discovering,
    SessionStatus? session,
  }) {
    if (_disposed) return;
    _status = SyncStatus(
      host: clearHost ? null : (host ?? _status.host),
      discovering: discovering ?? _status.discovering,
      session: session ?? _status.session,
    );
    _statusCtl.add(_status);
  }

  // ------------------------------------------------------ availability --

  @override
  Future<Map<TransportKind, TransportAvailability>> availability() async => {
        for (final t in _transports) t.kind: await _availabilityOf(t),
      };

  Future<TransportAvailability> _availabilityOf(SyncTransport t) async {
    try {
      return await t.availability();
    } catch (e, st) {
      _log('availability(${t.kind.name}) failed', e, st);
      return TransportAvailability.unsupported;
    }
  }

  @override
  Future<Map<TransportKind, TransportAvailability>> requestPermissions(
    Set<TransportKind> kinds,
  ) async =>
      {
        for (final t in _transports)
          if (kinds.contains(t.kind)) t.kind: await t.requestPermissions(),
      };

  // ----------------------------------------------------------- hosting --

  Future<AdvertiseInfo> _advertiseInfo() async {
    final now = _clock.now();
    final w = DiscoveryTokens.windowAt(now);
    return AdvertiseInfo(
      deviceId: _store.localDeviceId,
      deviceName: _store.localDeviceName,
      groupTokens: await DiscoveryTokens.advertised(
        await _store.groupKeys(),
        now,
        priority: await _recentlySyncedGroups(),
      ),
      advertId: await DiscoveryTokens.advertId(_advertSecret, w),
      tokenWindow: w,
    );
  }

  /// Groups in Sync history, most recently synced first: when an advert
  /// cannot hold every token, these are the ones a nearby phone most
  /// likely shares (SPEC 8.3).
  Future<List<GroupId>> _recentlySyncedGroups() async {
    try {
      final records = await _firstOf(_store.watchSyncRecords());
      return {
        for (final r in records)
          if (r.outcome != SyncOutcome.failed) ...r.groupIds,
      }.toList();
    } catch (e, st) {
      _log('reading sync history for advert priority failed', e, st);
      return const [];
    }
  }

  /// The first event of [stream]. Unlike [Stream.first] it does not wait
  /// for the subscription's cancel to finish: that future may belong to
  /// another zone (the root zone's done future), which would make hosting
  /// wait on an unrelated event loop turn (and never finish under a fake
  /// clock).
  static Future<T> _firstOf<T>(Stream<T> stream) {
    final first = Completer<T>();
    late final StreamSubscription<T> sub;
    sub = stream.listen(
      (value) {
        if (first.isCompleted) return;
        first.complete(value);
        unawaited(sub.cancel());
      },
      onError: (Object e, StackTrace st) {
        if (first.isCompleted) return;
        first.completeError(e, st);
        unawaited(sub.cancel());
      },
      onDone: () {
        if (!first.isCompleted) first.completeError(StateError('No element'));
      },
      cancelOnError: true,
    );
    return first.future;
  }

  @override
  Future<HostInfo> startHosting({
    Duration duration = const Duration(minutes: 5),
  }) async {
    _checkAlive();
    final current = _host;
    if (current != null) return current;
    var pending = _hostStart;
    if (pending != null && _hostStartGen != _hostGen) {
      // A start that stopHosting overtook: let it unwind, then start anew.
      await pending.then((_) {}, onError: (Object _) {});
      final host = _host;
      if (host != null) return host;
      pending = _hostStartGen == _hostGen ? _hostStart : null;
    }
    // Concurrent callers (e.g. the host screen and an invite) share one start.
    if (pending == null) {
      _hostStartGen = _hostGen;
      pending = _hostStart = _startHosting(duration, _hostGen);
    }
    try {
      return await pending;
    } finally {
      if (identical(_hostStart, pending)) _hostStart = null;
    }
  }

  Future<HostInfo> _startHosting(Duration duration, int gen) async {
    final info = await _advertiseInfo();
    final availabilities = <TransportAvailability>[];
    for (final t in _transports) {
      final a = await _availabilityOf(t);
      availabilities.add(a);
      if (a != TransportAvailability.ready) continue;
      try {
        _inbound[t] ??= t.inbound.listen(_onInbound);
        await t.startAdvertising(info);
        _advertising.add(t);
      } catch (e, st) {
        _log('startAdvertising(${t.kind.name}) failed', e, st);
        await _inbound.remove(t)?.cancel();
      }
    }
    if (gen != _hostGen) {
      // stopHosting ran while we were starting: undo what we started.
      await _teardownHosting();
      throw const SyncException(SyncFailure.cancelled, 'Hosting stopped');
    }
    if (_advertising.isEmpty) {
      throw SyncException(_failureFor(availabilities), 'Nothing can advertise');
    }

    final addresses = <String>[];
    String? wifiName;
    for (final t in _advertising) {
      if (t is HostingDetails) {
        final details = t as HostingDetails;
        try {
          addresses.addAll(await details.hostAddresses());
          wifiName ??= await details.wifiName();
        } catch (e, st) {
          _log('hosting details (${t.kind.name}) failed', e, st);
        }
      }
    }
    final now = _clock.now();
    final host = HostInfo(
      connectLink: ConnectLink(
        hosts: addresses,
        deviceId: _store.localDeviceId,
        deviceName: _store.localDeviceName,
      ).encode(),
      addresses: List.unmodifiable(addresses),
      expiresAt: now.add(duration),
      transports: {for (final t in _advertising) t.kind},
      wifiName: wifiName,
    );
    _host = host;
    _hostExpiry = Timer(duration, () => unawaited(stopHosting()));
    _scheduleTokenRefresh();
    _setStatus(host: host);
    return host;
  }

  static SyncFailure _failureFor(List<TransportAvailability> all) {
    if (all.any((a) =>
        a == TransportAvailability.needsPermission ||
        a == TransportAvailability.permissionPermanentlyDenied)) {
      return SyncFailure.permissionDenied;
    }
    // Location off implies Bluetooth on: saying "Bluetooth or Wi-Fi is
    // off" would send the user to the wrong switch (PLATFORM-R3-01).
    if (all.contains(TransportAvailability.locationOff)) {
      return SyncFailure.locationOff;
    }
    if (all.contains(TransportAvailability.radioOff)) {
      return SyncFailure.radioOff;
    }
    return SyncFailure.internal;
  }

  void _scheduleTokenRefresh() {
    _tokenRefresh?.cancel();
    final now = _clock.now();
    final next = DiscoveryTokens.nextWindowStart(now);
    _tokenRefresh = Timer(next.difference(now) + const Duration(seconds: 1),
        () => unawaited(_refreshAdvertising()));
  }

  /// Re-announces with tokens for the current window and group set.
  Future<void> _refreshAdvertising() async {
    if (_host == null) return;
    final info = await _advertiseInfo();
    for (final t in _advertising.toList()) {
      try {
        await t.startAdvertising(info);
      } catch (e, st) {
        _log('re-advertise (${t.kind.name}) failed', e, st);
      }
    }
    _scheduleTokenRefresh();
  }

  @override
  Future<void> stopHosting() async {
    _hostGen++;
    final starting = _hostStart;
    if (starting != null) {
      await starting.then((_) {}, onError: (Object _) {});
    }
    await _teardownHosting();
  }

  Future<void> _teardownHosting() async {
    _hostExpiry?.cancel();
    _tokenRefresh?.cancel();
    _hostExpiry = null;
    _tokenRefresh = null;
    final advertising = _advertising.toList();
    _advertising.clear();
    for (final t in advertising) {
      try {
        await t.stopAdvertising();
      } catch (e, st) {
        _log('stopAdvertising(${t.kind.name}) failed', e, st);
      }
    }
    for (final sub in _inbound.values.toList()) {
      await sub.cancel();
    }
    _inbound.clear();
    // Anyone waiting for a connection to arrive here stops waiting.
    _notify();
    if (_host != null) {
      _host = null;
      _setStatus(clearHost: true);
    }
  }

  void _onInbound(FrameChannel channel) {
    if (_disposed) {
      unawaited(_rejectBusy(channel));
      return;
    }
    _makeRoomFor(channel);
    final run = _startSession(channel, SessionRole.responder, '');
    unawaited(run.result.then(
      (r) async {
        await _finishRun(run, r);
        run.finished.complete(r);
      },
      onError: (Object e, StackTrace st) => _log('inbound session', e, st),
    ));
  }

  /// Who opened [channel], for [kMaxSilentPerSource]: the IP address of a
  /// LAN connection (its port changes with every connection), else the
  /// transport address.
  static String _sourceOf(FrameChannel channel) {
    final address = channel.peerAddress;
    if (channel.kind != TransportKind.lan) return '${channel.kind.name}|$address';
    return 'lan|${parseHostPort(address)?.host ?? address}';
  }

  /// An inbound connection whose peer has not said HELLO yet.
  static bool _isSilent(SyncSession s) =>
      !s.isFinished && s.peerDeviceId == null;

  void _evict(SyncSession victim) {
    _pendingInbound.remove(victim);
    unawaited(victim.cancel(message: _tooMany));
  }

  /// Before a new inbound connection from [channel] starts: evicts the
  /// oldest silent connection from the same source, or the oldest silent
  /// one overall, when either limit is reached. Handshakes under way are
  /// never evicted for a new connection (the oldest silent connection has
  /// had the longest to speak).
  void _makeRoomFor(FrameChannel channel) {
    final source = _sourceOf(channel);
    final silent = _pendingInbound.where(_isSilent).toList();
    final mine = [
      for (final s in silent)
        if (_sourceOf(s.channel) == source) s,
    ];
    if (mine.length >= kMaxSilentPerSource) {
      _evict(mine.first);
    } else if (silent.length >= kMaxSilentInbound) {
      _evict(silent.first);
    }
  }

  /// [hello]'s peer has just said HELLO: if that makes more than
  /// [kMaxPendingInbound] handshakes under way, the oldest of them goes.
  void _limitHandshakes(SyncSession hello) {
    final handshaking = [
      for (final s in _pendingInbound)
        if (!s.isFinished &&
            s.peerDeviceId != null &&
            s.state.index < SessionState.authenticated.index)
          s,
    ];
    if (handshaking.length > kMaxPendingInbound) _evict(handshaking.first);
  }

  Future<void> _rejectBusy(FrameChannel channel) async {
    try {
      await channel.send(FrameCodec.plainFrame(
          const ErrorMessage(ErrorCodes.busy, 'Syncing with another phone')));
    } catch (_) {
      // Peer already gone.
    }
    try {
      await channel.close();
    } catch (_) {
      // Already closed.
    }
  }

  // --------------------------------------------------------- discovery --

  @override
  Future<void> startDiscovery({
    Set<TransportKind> kinds = const {
      TransportKind.lan,
      TransportKind.nearby,
      TransportKind.ble,
    },
  }) async {
    _checkAlive();
    final gen = ++_discoveryGen;
    await _cancelDiscovery();
    if (gen != _discoveryGen) return;
    await _refreshTokenIndex(force: true);
    for (final t in _transports) {
      if (!kinds.contains(t.kind)) continue;
      final ready = await _availabilityOf(t) == TransportAvailability.ready;
      // Stopped (or restarted) meanwhile: whoever did that owns the state.
      if (gen != _discoveryGen) return;
      if (!ready) continue;
      _discoverySubs.add(t.discover().listen(
        (peer) => _onSighting(peer, gen),
        onError: (Object e, StackTrace st) =>
            _log('discover(${t.kind.name}) error', e, st),
      ));
    }
    _sweep = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_registry.sweep(_clock.now())) _emitNearby();
      unawaited(_refreshTokenIndex());
    });
    _setStatus(discovering: true);
  }

  void _onSighting(DiscoveredPeer peer, int gen) {
    _sightings = _sightings.then((_) async {
      if (gen != _discoveryGen || _disposed) return;
      // Match the tokens against the window the advertiser says they are
      // for, so a phone with a skewed clock still shows its groups.
      final w = _registry.windowOf(peer);
      var changed = false;
      if (w != null && !_registry.hasWindowIndex(w)) {
        final index = DiscoveryTokens.indexForWindow(
          await _store.groupKeys(),
          w,
        );
        changed = _registry.setWindowIndex(w, await index);
      }
      if (gen != _discoveryGen || _disposed) return;
      if (_registry.update(peer, _clock.now()) || changed) _emitNearby();
    }).catchError((Object e, StackTrace st) => _log('sighting', e, st));
  }

  /// Re-reads the token index when the window or the group keys change.
  Future<void> _refreshTokenIndex({bool force = false}) {
    final running = _indexRefresh;
    if (running != null) {
      return force
          ? running.then((_) => _refreshTokenIndex(force: true))
          : running;
    }
    final f = _indexRefresh = _doRefreshTokenIndex(force);
    return f.whenComplete(() {
      if (identical(_indexRefresh, f)) _indexRefresh = null;
    });
  }

  Future<void> _doRefreshTokenIndex(bool force) async {
    final now = _clock.now();
    final w = DiscoveryTokens.windowAt(now);
    final keys = await _store.groupKeys();
    final signature = (keys.keys.toList()..sort()).join(',');
    final keysChanged = signature != _keysSignature;
    if (!force && w == _indexWindow && !keysChanged) return;
    _indexWindow = w;
    _keysSignature = signature;
    _registry
      ..currentWindow = w
      ..selfAdvertIds = {
        for (final d in const [-1, 0, 1])
          await DiscoveryTokens.advertId(_advertSecret, w + d),
      }
      ..tokenIndex = await DiscoveryTokens.index(keys, now);
    if (keysChanged || force) {
      final inUse = _registry.windowsInUse;
      _registry.clearWindowIndexes();
      for (final win in inUse) {
        _registry.setWindowIndex(
          win,
          await DiscoveryTokens.indexForWindow(keys, win),
        );
      }
    }
    _emitNearby();
  }

  void _emitNearby() {
    if (!_disposed) _nearbyCtl.add(_registry.peers);
  }

  Future<void> _cancelDiscovery() async {
    _sweep?.cancel();
    _sweep = null;
    final subs = _discoverySubs.toList();
    _discoverySubs.clear();
    for (final s in subs) {
      await s.cancel();
    }
  }

  @override
  Future<void> stopDiscovery() async {
    _discoveryGen++;
    await _cancelDiscovery();
    _registry.clear();
    _emitNearby();
    if (_status.discovering) _setStatus(discovering: false);
  }

  // ---------------------------------------------------------- sessions --

  SyncTransport? _transportOf(TransportKind kind) {
    for (final t in _transports) {
      if (t.kind == kind) return t;
    }
    return null;
  }

  _Outbound _claim({DeviceId? targetId, List<String> targetNames = const []}) {
    _checkAlive();
    if (_busy) {
      throw const SyncException(
          SyncFailure.internal, 'A sync is already running');
    }
    return _outbound = _Outbound(targetId: targetId, targetNames: targetNames);
  }

  /// Whether this phone can be dialed now (hosting): only then may another
  /// phone's Sync be on its way here.
  bool get _listening => _inbound.isNotEmpty;

  void _release(_Outbound out) {
    if (identical(_outbound, out)) {
      _outbound = null;
      _notify();
    }
  }

  @override
  Future<SyncSummary> syncWith(NearbyPeer peer) async {
    _checkAlive();
    final routes = [
      for (final r in _registry.routesFor(peer.key))
        if (peer.transports.contains(r.kind)) r,
    ];
    final out = _claim(
      targetNames: {peer.name, for (final r in routes) r.name}.toList(),
    );
    return _connectAndRun(out, peer.name, routes, connectTimeout);
  }

  @override
  Future<SyncSummary> syncWithLink(String link) async {
    final target = await _parseSyncTarget(link);
    final out = _claim(targetId: target.deviceId, targetNames: [target.name]);
    return _connectAndRun(out, target.name, target.routes, linkConnectTimeout);
  }

  /// Whether a link may make this phone dial [address] (SPEC 8.6): only
  /// local-network addresses, so a link from a web page cannot reach the
  /// internet.
  bool _isLinkHost(String address) {
    final t = _transportOf(TransportKind.lan);
    if (t is HostingDetails) return (t as HostingDetails).isLinkHost(address);
    return isLocalNetworkHostPort(address);
  }

  /// Hosts to try for a connect link, or an invite carrying `h`.
  Future<({String name, DeviceId? deviceId, List<DiscoveredPeer> routes})>
      _parseSyncTarget(
    String link,
  ) async {
    final connect = ConnectLink.tryParse(link);
    if (connect != null) {
      final hosts = connect.hosts.where(_isLinkHost).toList();
      if (hosts.isEmpty) {
        throw const SyncException(
          SyncFailure.invalidCode,
          'This code is not for a phone on your network',
        );
      }
      return (
        name: connect.deviceName,
        deviceId: connect.deviceId,
        routes: [
          for (final h in hosts)
            DiscoveredPeer(
              kind: TransportKind.lan,
              address: h,
              name: connect.deviceName,
            ),
        ],
      );
    }
    final invite = InviteLink.tryParse(link);
    final host = invite?.host;
    if (invite == null ||
        host == null ||
        !_validInvite(invite) ||
        !_isLinkHost(host)) {
      throw const SyncException(SyncFailure.invalidCode, 'Not a sync link');
    }
    await _registerInvite(invite);
    return (
      name: invite.fromName,
      deviceId: invite.deviceId,
      routes: [
        DiscoveredPeer(kind: TransportKind.lan, address: host, name: invite.fromName),
      ],
    );
  }

  Future<SyncSummary> _connectAndRun(
    _Outbound out,
    String advertisedName,
    List<DiscoveredPeer> routes,
    Duration timeout,
  ) async {
    final name = cleanPeerName(advertisedName);
    final started = _clock.now();
    FrameChannel? channel;
    Object? lastError;
    try {
      for (final route in routes) {
        final t = _transportOf(route.kind);
        if (t == null) continue;
        if (out.cancelled) break;
        if (!out.yielded) {
          _setStatus(
            session: SessionActive(SyncProgress(
              peerName: name,
              transport: route.kind,
              phase: SyncPhase.connecting,
            )),
          );
        }
        try {
          channel = await _connectUnlessCancelled(out, t, route, timeout);
          break;
        } catch (e) {
          lastError = e;
          _log('connect ${route.kind.name} ${route.address} failed', e);
        }
        if (out.cancelled || out.yielded) break;
      }
      if (out.yielded) {
        // The other phone's connection got here first (both tapped Sync).
        await channel?.close();
        channel = null;
      } else if (out.cancelled) {
        await channel?.close();
        throw const SyncException(SyncFailure.cancelled, 'Cancelled');
      } else if (channel == null) {
        throw SyncException(
          SyncFailure.peerUnreachable,
          lastError == null ? 'No way to reach $name' : '$lastError',
        );
      }
    } on SyncException catch (e) {
      _release(out);
      final transport = routes.isEmpty ? TransportKind.lan : routes.first.kind;
      await _record(SessionResult(
        outcome: e.failure == SyncFailure.cancelled
            ? SyncOutcome.cancelled
            : SyncOutcome.failed,
        failure: e.failure,
        message: e.message,
        peerName: name,
        transport: transport,
        startedAt: started,
        endedAt: _clock.now(),
        sentOps: 0,
        receivedOps: 0,
        receivedByGroup: const {},
        groupIds: const [],
      ));
      _setStatus(session: SessionFailed(e.failure, e.message));
      rethrow;
    }
    if (channel == null) return _follow(out);

    final run = _startSession(channel, SessionRole.initiator, name, out: out);
    final summary = Completer<SyncSummary>();
    unawaited(run.live.future.then((r) {
      // LIVE: the caller gets the summary now; the session keeps running.
      if (!summary.isCompleted) summary.complete(r.summary);
    }));
    unawaited(run.result.then((result) async {
      var r = result;
      final peer = r.peerDeviceId;
      if (!out.yielded &&
          !out.cancelled &&
          !r.isSuccess &&
          r.peerErrorCode == ErrorCodes.busy &&
          peer != null) {
        if (r.message.endsWith(_busyDialing)) {
          // The other phone is still dialing, maybe us: serve its
          // connection if it comes (whichever id is lower, since our own
          // attempt is over). Its dial may take a connect timeout more.
          // Not hosting, nobody can dial us: no need to wait (SYNC-R3-02).
          if (_listening) {
            await _awaitYield(
              out,
              peer,
              arriving: connectTimeout + timings.handshakeTimeout,
            );
          }
        } else if (_yieldsTo(peer) &&
            (r.message.endsWith(_busySame) || _inboundFrom(peer) != null)) {
          // The other phone is syncing with us the other way round: its
          // connection here is about to ask for the slot.
          await _awaitYield(out, peer);
        }
        // Cancel tapped while waiting for the other phone (SYNC-R3-01).
        if (!out.yielded && out.cancelled) r = _cancelledResult(r);
      }
      if (out.yielded) {
        try {
          final s = await _follow(out);
          if (!summary.isCompleted) summary.complete(s);
        } on SyncException catch (e) {
          if (!summary.isCompleted) summary.completeError(e);
        }
        return;
      }
      _release(out);
      await _finishRun(run, r);
      run.finished.complete(r);
      if (summary.isCompleted) return;
      if (r.isSuccess) {
        summary.complete(r.summary);
      } else {
        summary.completeError(SyncException(
          r.failure ?? SyncFailure.internal,
          r.message,
          r.outcome == SyncOutcome.partial ? r.summary : null,
        ));
      }
    }).catchError((Object e, StackTrace st) {
      _log('outbound session', e, st);
      _release(out);
      if (!summary.isCompleted) {
        summary.completeError(SyncException(SyncFailure.internal, '$e'));
      }
    }));
    return summary.future;
  }

  /// Connects over [route], or returns null as soon as the user taps
  /// Cancel: a route that hangs (a LAN address behind Wi-Fi client
  /// isolation answers nothing until the connect timeout) must not keep
  /// the Sync screen on Connecting, nor the engine busy (SYNC-R4-01). A
  /// channel the abandoned attempt opens later is closed at once.
  static Future<FrameChannel?> _connectUnlessCancelled(
    _Outbound out,
    SyncTransport t,
    DiscoveredPeer route,
    Duration timeout,
  ) async {
    final attempt = t.connect(route, timeout: timeout);
    final first = await Future.any<FrameChannel?>([
      attempt,
      out.whenCancelled.then((_) => null),
    ]);
    if (first == null) {
      unawaited(attempt.then(
        (c) => c.close().catchError((Object _) {}),
        onError: (Object _) {},
      ));
    }
    return first;
  }

  /// The result of the inbound session [out] gave way to.
  Future<SyncSummary> _follow(_Outbound out) async {
    final to = out.yieldedTo!;
    final r = await Future.any([to.live.future, to.finished.future]);
    if (r.isSuccess) return r.summary;
    throw SyncException(
      r.failure ?? SyncFailure.internal,
      r.message,
      r.outcome == SyncOutcome.partial ? r.summary : null,
    );
  }

  /// Whether [out], still dialing, may be dialing the phone of the inbound
  /// session [s] (authenticated, so its HELLO is known). By device id when
  /// a link gave one; else by name: adverts cut names (24 runes over Nearby
  /// and BLE, 40 over mDNS) and mDNS may add " (2)", so a name that is a
  /// prefix of the other counts as a match. Unknown counts as a match: the
  /// asking phone then waits for the dial, as for a mutual Sync.
  static bool _dialMayReach(_Outbound out, SyncSession s) {
    final id = out.targetId;
    if (id != null) return id == s.peerDeviceId;
    final hello = _nameKey(s.peerName);
    if (hello.isEmpty || out.targetNames.isEmpty) return true;
    for (final n in out.targetNames) {
      final advertised = _nameKey(n);
      if (advertised.isEmpty ||
          advertised == 'settle up' ||
          hello.startsWith(advertised) ||
          advertised.startsWith(hello)) {
        return true;
      }
    }
    return false;
  }

  static final RegExp _mdnsSuffix = RegExp(r'\s*\(\d+\)$');

  static String _nameKey(String name) =>
      cleanPeerName(name).replaceFirst(_mdnsSuffix, '').trim().toLowerCase();

  /// In a mutual Sync the phone with the lower device id gives way.
  bool _yieldsTo(DeviceId peer) => _store.localDeviceId.compareTo(peer) < 0;

  SyncSession? _inboundFrom(DeviceId peer) {
    for (final s in [..._pendingInbound, ?_active]) {
      if (s.role == SessionRole.responder &&
          !s.isFinished &&
          s.peerDeviceId == peer) {
        return s;
      }
    }
    return null;
  }

  /// [r], refused while the user tapped Cancel: a cancelled Sync.
  static SessionResult _cancelledResult(SessionResult r) => SessionResult(
        outcome: SyncOutcome.cancelled,
        failure: SyncFailure.cancelled,
        message: 'Cancelled',
        peerName: r.peerName,
        peerDeviceId: r.peerDeviceId,
        transport: r.transport,
        startedAt: r.startedAt,
        endedAt: r.endedAt,
        sentOps: r.sentOps,
        receivedOps: r.receivedOps,
        receivedByGroup: r.receivedByGroup,
        groupIds: r.groupIds,
        receivedAnyFrame: r.receivedAnyFrame,
        peerErrorCode: r.peerErrorCode,
      );

  /// Waits until [out] gives way to an inbound session from [peer]: soon
  /// if that session is here, for [arriving] if it has not said HELLO yet.
  /// Cancel ends the wait at once.
  Future<void> _awaitYield(
    _Outbound out,
    DeviceId peer, {
    Duration arriving = const Duration(seconds: 1),
  }) async {
    final waited = Stopwatch()..start();
    while (!out.yielded && !out.cancelled && !_disposed) {
      // Hosting stopped: nothing more can arrive.
      if (!_listening && _inboundFrom(peer) == null) return;
      final limit = _inboundFrom(peer) == null
          ? arriving
          : arriving + timings.handshakeTimeout;
      final left = limit - waited.elapsed;
      if (left <= Duration.zero) return;
      await _changed.future.timeout(left, onTimeout: () {});
    }
  }

  /// Gives [out] up for the inbound session [to] from the same phone.
  void _yield(_Outbound out, _Run to) {
    out.yieldedTo = to;
    final mine = out.session;
    if (identical(_active, mine)) _active = null;
    if (identical(_outbound, out)) _outbound = null;
    if (mine != null && !mine.isFinished) {
      unawaited(mine.cancel(message: 'Both phones tapped Sync'));
    }
  }

  void _admitRun(_Run run) {
    _pendingInbound.remove(run.session);
    run.admitted = true;
    _active = run.session;
    _notify();
  }

  /// Admission of an outbound session: it has the slot already, unless it
  /// gave way meanwhile.
  Future<String?> _admitOutbound(_Run run, _Outbound out) async {
    if (out.yielded || _disposed) return _busySame;
    final active = _active;
    if (active != null && !identical(active, run.session)) return _busyOther;
    _admitRun(run);
    return null;
  }

  /// Admission of an authenticated inbound session (SPEC 8.7.1).
  Future<String?> _admitInbound(_Run run) async {
    final s = run.session;
    final peer = s.peerDeviceId!;
    final waited = Stopwatch()..start();
    while (true) {
      if (_disposed) return _busyOther;
      if (!_pendingInbound.contains(s)) return _tooMany;
      final out = _outbound;
      if (out != null) {
        final target = out.session?.peerDeviceId;
        if (out.cancelled) {
          // Our own Sync was cancelled and is about to let the slot go:
          // then this is an ordinary inbound sync. Never serve it as the
          // cancelled Sync (SYNC-R3-01).
          final left = timings.handshakeTimeout - waited.elapsed;
          if (left <= Duration.zero) return _busyOther;
          await _changed.future.timeout(left, onTimeout: () {});
          continue;
        }
        if (target == null) {
          // Our own Sync is still connecting or waiting for HELLO: learn
          // whom it is for before deciding (at most one handshake timeout;
          // the session's own handshake timer pauses meanwhile).
          final left = timings.handshakeTimeout - waited.elapsed;
          // Not "another phone": the dial may be for this very phone, which
          // then waits for it (SYNC-R2-02).
          if (left <= Duration.zero) {
            return _dialMayReach(out, s) ? _busyDialing : _busyDialingElsewhere;
          }
          await _changed.future.timeout(left, onTimeout: () {});
          continue;
        }
        if (target != peer) return _busyOther;
        // Both phones tapped Sync on each other. Our own attempt may
        // already be over (refused while the other phone was still
        // dialing): then we serve this one whichever id is lower.
        if (!_yieldsTo(peer) && !(out.session?.isFinished ?? false)) {
          return _busySame;
        }
        _yield(out, run);
        _admitRun(run);
        return null;
      }
      final active = _active;
      if (active != null) {
        final old = _runs[active];
        if (active.role == SessionRole.responder &&
            active.peerDeviceId == peer &&
            old != null &&
            old.seq < run.seq) {
          // The same phone again: a phone runs one Sync at a time, so the
          // older session is dead (half-open link) or was given up.
          old.superseded = true;
          _admitRun(run);
          unawaited(active.cancel(message: 'Replaced by a new connection'));
          return null;
        }
        return active.peerDeviceId == peer ? _busySame : _busyOther;
      }
      _admitRun(run);
      return null;
    }
  }

  /// Creates and starts a session on [channel].
  _Run _startSession(
    FrameChannel channel,
    SessionRole role,
    String nameHint, {
    _Outbound? out,
  }) {
    late final _Run run;
    final session = SyncSession(
      channel: channel,
      store: _store,
      role: role,
      liveMode: _liveMode,
      timings: timings,
      now: _clock.now,
      peerNameHint: nameHint,
      onProgress: (p) {
        if (_mayShow(run, p)) _setStatus(session: SessionActive(p));
      },
      onLive: (r) {
        if (_mayShow(run, null)) _setStatus(session: SessionCompleted(r.summary));
        if (!run.live.isCompleted) run.live.complete(r);
      },
      onPeerHello: (s) {
        if (role == SessionRole.responder) _limitHandshakes(s);
        _notify();
      },
      admit: (_) => out == null ? _admitInbound(run) : _admitOutbound(run, out),
    );
    run = _Run(session, _runSeq++);
    _runs[session] = run;
    if (out != null) out.session = session;
    if (role == SessionRole.responder) _pendingInbound.add(session);
    run.result = session.run().whenComplete(() {
      _runs.remove(session);
      _pendingInbound.remove(session);
      if (identical(_active, session)) _active = null;
      _notify();
    });
    return run;
  }

  /// Whether [run] may drive the visible status.
  bool _mayShow(_Run run, SyncProgress? p) {
    final s = run.session;
    if (run.superseded) return false;
    if (identical(_active, s)) return true;
    if (run.admitted) return false;
    if (s.role == SessionRole.initiator) {
      return identical(_outbound?.session, s);
    }
    // An inbound handshake shows once it says HELLO, if nothing else runs
    // (probes such as the hotspot gateway check stay invisible).
    return !_busy && (p == null || p.peerDeviceId != null);
  }

  /// Records [result] and shows it, for sessions that count.
  Future<void> _finishRun(_Run run, SessionResult result) async {
    final s = run.session;
    if (!run.admitted) {
      // Refused (busy) or evicted before it got the slot: not a sync.
      if (result.failure == SyncFailure.peerUnreachable &&
          result.peerErrorCode == null) {
        return;
      }
      if (s.role == SessionRole.responder &&
          (!result.receivedAnyFrame ||
              result.failure == SyncFailure.cancelled)) {
        return;
      }
    }
    await _record(result);
    if (run.superseded) return;
    if (_busy && !identical(_active, s)) return;
    _setStatus(
      session: result.isSuccess
          ? SessionCompleted(result.summary)
          : SessionFailed(
              result.failure ?? SyncFailure.internal,
              result.message,
              result.outcome == SyncOutcome.partial ? result.summary : null,
            ),
    );
  }

  Future<void> _record(SessionResult result) async {
    try {
      await _store.addSyncRecord(result.toRecord(_ids.newId()));
    } catch (e, st) {
      _log('addSyncRecord failed', e, st);
    }
  }

  // ----------------------------------------------------------- invites --

  static bool _validInvite(InviteLink invite) =>
      invite.groupId.isNotEmpty && invite.groupId.length <= kMaxIdLength;

  Future<bool> _registerInvite(InviteLink invite) async {
    final added = await _store.registerJoinedGroup(
      invite.groupId,
      invite.groupKey,
      invite.groupName,
    );
    if (added && _host != null) unawaited(_refreshAdvertising());
    if (added && _status.discovering) unawaited(_refreshTokenIndex(force: true));
    return added;
  }

  @override
  Future<JoinResult> acceptInvite(String link) async {
    _checkAlive();
    final invite = InviteLink.tryParse(link);
    if (invite == null || !_validInvite(invite)) {
      throw const SyncException(SyncFailure.invalidCode, 'Not an invite link');
    }
    final added = await _registerInvite(invite);
    SyncSummary? first;
    final host = invite.host;
    if (host != null && !_busy && _isLinkHost(host)) {
      try {
        first = await _connectAndRun(
          _claim(targetId: invite.deviceId, targetNames: [invite.fromName]),
          invite.fromName,
          [
            DiscoveredPeer(
              kind: TransportKind.lan,
              address: host,
              name: invite.fromName,
            ),
          ],
          linkConnectTimeout,
        );
      } on SyncException catch (e) {
        _log('first sync after join failed: $e');
      }
    }
    return JoinResult(
      groupId: invite.groupId,
      groupName: invite.groupName,
      alreadyMember: !added,
      firstSync: first,
    );
  }

  @override
  Future<String> inviteLinkFor(
    GroupId groupId, {
    bool includeHost = true,
  }) async {
    _checkAlive();
    final key = (await _store.groupKeys())[groupId];
    if (key == null) {
      throw SyncException(SyncFailure.internal, 'No key for group $groupId');
    }
    String? host;
    if (includeHost) {
      try {
        final info = _host ?? await startHosting();
        host = info.addresses.isEmpty ? null : info.addresses.first;
      } on SyncException catch (e) {
        _log('invite without host: $e');
      }
    }
    final (name, currency) = _groupInfo(groupId);
    return InviteLink(
      groupId: groupId,
      groupKey: Uint8List.fromList(key),
      groupName: name,
      currency: currency,
      fromName: _store.localDeviceName,
      host: host,
      deviceId: _store.localDeviceId,
    ).encode();
  }

  /// Group name and currency. SyncStore does not expose them, but the real
  /// store (Ledger) is also the LedgerRepository.
  (String, String) _groupInfo(GroupId groupId) {
    final store = _store;
    if (store is LedgerRepository) {
      final snapshot = (store as LedgerRepository).current;
      final group = snapshot.state.groups[groupId]?.group;
      if (group != null) return (group.name, group.currency);
      final pending = snapshot.pendingJoins[groupId];
      if (pending != null) return (pending, '');
    }
    return ('', '');
  }

  // ------------------------------------------------------------ control --

  @override
  Future<void> cancel() async {
    // A Sync still connecting stops now (its connect attempt is
    // abandoned); one waiting for the other phone's dial stops now too.
    _outbound?.cancel();
    final sessions = {?_outbound?.session, ?_active};
    _notify();
    for (final s in sessions) {
      await s.cancel();
    }
  }

  @override
  set liveMode(bool enabled) {
    _liveMode = enabled;
    for (final s in _runs.keys.toList()) {
      s.liveMode = enabled;
    }
  }

  @override
  Stream<List<SyncRecord>> watchHistory() => _store.watchSyncRecords();

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await cancel();
    for (final s in _pendingInbound.toList()) {
      await s.cancel();
    }
    await stopDiscovery();
    await stopHosting();
    _disposed = true;
    for (final t in _transports) {
      try {
        await t.dispose();
      } catch (e, st) {
        _log('dispose(${t.kind.name}) failed', e, st);
      }
    }
    await _statusCtl.close();
    await _nearbyCtl.close();
  }

  void _checkAlive() {
    if (_disposed) throw StateError('DefaultSyncEngine disposed');
  }
}
