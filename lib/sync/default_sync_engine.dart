// DefaultSyncEngine (SPEC 5.13, 8.7.1): hosting, discovery across
// transports, choosing a transport, one session at a time.
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:typed_data';

import '../core/ids.dart';
import '../core/models.dart';
import '../data/repositories.dart';
import 'crypto/tokens.dart';
import 'nearby_registry.dart';
import 'pairing/links.dart';
import 'protocol/codec.dart';
import 'protocol/messages.dart';
import 'protocol/session.dart';
import 'sync_clock.dart';
import 'sync_engine.dart';
import 'transport/hosting_details.dart';
import 'transport/transport.dart';

export 'sync_clock.dart';

void _log(String message, [Object? error, StackTrace? st]) => developer.log(
      message,
      name: 'settle_up.sync',
      error: error,
      stackTrace: st,
    );

final class DefaultSyncEngine implements SyncEngine {
  DefaultSyncEngine({
    required SyncStore store,
    required List<SyncTransport> transports,
    SyncClock? clock,
    this.timings = const SessionTimings(),
    this._ids = const UuidV7Generator(),
    Duration nearbyTtl = const Duration(seconds: 15),
    this.connectTimeout = const Duration(seconds: 10),
    this.linkConnectTimeout = const Duration(seconds: 4),
  })  : _store = store,
        _transports = List.unmodifiable(transports),
        _clock = clock ?? const SystemSyncClock(),
        _registry = NearbyRegistry(
          localDeviceIdPrefix: _prefix(store.localDeviceId),
          ttl: nearbyTtl,
        );

  static String _prefix(String id) => id.length >= 8 ? id.substring(0, 8) : id;

  final SyncStore _store;
  final List<SyncTransport> _transports;
  final SyncClock _clock;
  final IdGenerator _ids;
  final NearbyRegistry _registry;
  final SessionTimings timings;
  final Duration connectTimeout;
  final Duration linkConnectTimeout;

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

  // discovery
  final List<StreamSubscription<DiscoveredPeer>> _discoverySubs = [];
  Timer? _sweep;
  int _indexWindow = -1;

  // sessions
  bool _busy = false;
  SyncSession? _session;
  bool _cancelRequested = false;
  bool _liveMode = false;

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

  Future<AdvertiseInfo> _advertiseInfo() async => AdvertiseInfo(
        deviceId: _store.localDeviceId,
        deviceName: _store.localDeviceName,
        groupTokens: await DiscoveryTokens.advertised(
          await _store.groupKeys(),
          _clock.now(),
        ),
      );

  @override
  Future<HostInfo> startHosting({
    Duration duration = const Duration(minutes: 5),
  }) async {
    _checkAlive();
    final current = _host;
    if (current != null) return current;
    // Concurrent callers (e.g. the host screen and an invite) share one start.
    final pending = _hostStart ??= _startHosting(duration);
    try {
      return await pending;
    } finally {
      _hostStart = null;
    }
  }

  Future<HostInfo> _startHosting(Duration duration) async {

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
    if (all.contains(TransportAvailability.radioOff)) return SyncFailure.radioOff;
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
    if (_host != null) {
      _host = null;
      _setStatus(clearHost: true);
    }
  }

  void _onInbound(FrameChannel channel) {
    if (_disposed || _busy) {
      unawaited(_rejectBusy(channel));
      return;
    }
    _busy = true;
    _cancelRequested = false;
    unawaited(_runSession(channel, SessionRole.responder, '').then((_) {},
        onError: (Object e, StackTrace st) => _log('inbound session', e, st)));
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
    await _cancelDiscovery();
    await _refreshTokenIndex(force: true);
    for (final t in _transports) {
      if (!kinds.contains(t.kind)) continue;
      if (await _availabilityOf(t) != TransportAvailability.ready) continue;
      _discoverySubs.add(t.discover().listen(
        (peer) {
          if (_registry.update(peer, _clock.now())) _emitNearby();
        },
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

  Future<void> _refreshTokenIndex({bool force = false}) async {
    final now = _clock.now();
    final w = DiscoveryTokens.windowAt(now);
    if (!force && w == _indexWindow) return;
    _indexWindow = w;
    _registry.tokenIndex = await DiscoveryTokens.index(
      await _store.groupKeys(),
      now,
    );
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

  void _claim() {
    _checkAlive();
    if (_busy) {
      throw const SyncException(
          SyncFailure.internal, 'A sync is already running');
    }
    _busy = true;
    _cancelRequested = false;
  }

  @override
  Future<SyncSummary> syncWith(NearbyPeer peer) async {
    _claim();
    final routes = [
      for (final r in _registry.routesFor(peer.key))
        if (peer.transports.contains(r.kind)) r,
    ];
    return _connectAndRun(peer.name, routes, connectTimeout);
  }

  @override
  Future<SyncSummary> syncWithLink(String link) async {
    final target = await _parseSyncTarget(link);
    _claim();
    return _connectAndRun(target.name, target.routes, linkConnectTimeout);
  }

  /// Hosts to try for a connect link, or an invite carrying `h`.
  Future<({String name, List<DiscoveredPeer> routes})> _parseSyncTarget(
    String link,
  ) async {
    final connect = ConnectLink.tryParse(link);
    if (connect != null) {
      return (
        name: connect.deviceName,
        routes: [
          for (final h in connect.hosts)
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
    if (invite == null || host == null || !_validInvite(invite)) {
      throw const SyncException(SyncFailure.invalidCode, 'Not a sync link');
    }
    await _registerInvite(invite);
    return (
      name: invite.fromName,
      routes: [
        DiscoveredPeer(kind: TransportKind.lan, address: host, name: invite.fromName),
      ],
    );
  }

  Future<SyncSummary> _connectAndRun(
    String name,
    List<DiscoveredPeer> routes,
    Duration timeout,
  ) async {
    final started = _clock.now();
    FrameChannel? channel;
    Object? lastError;
    try {
      for (final route in routes) {
        final t = _transportOf(route.kind);
        if (t == null) continue;
        _setStatus(
          session: SessionActive(SyncProgress(
            peerName: name,
            transport: route.kind,
            phase: SyncPhase.connecting,
          )),
        );
        try {
          channel = await t.connect(route, timeout: timeout);
          break;
        } catch (e) {
          lastError = e;
          _log('connect ${route.kind.name} ${route.address} failed', e);
        }
        if (_cancelRequested) break;
      }
      if (_cancelRequested) {
        await channel?.close();
        throw const SyncException(SyncFailure.cancelled, 'Cancelled');
      }
      if (channel == null) {
        throw SyncException(
          SyncFailure.peerUnreachable,
          lastError == null ? 'No way to reach $name' : '$lastError',
        );
      }
    } on SyncException catch (e) {
      _busy = false;
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

    final summary = Completer<SyncSummary>();
    unawaited(_runSession(
      channel,
      SessionRole.initiator,
      name,
      onLive: (r) {
        if (!summary.isCompleted) summary.complete(r.summary);
      },
    ).then((r) {
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
    }, onError: (Object e, StackTrace st) {
      if (!summary.isCompleted) {
        summary.completeError(SyncException(SyncFailure.internal, '$e'));
      }
    }));
    return summary.future;
  }

  Future<SessionResult> _runSession(
    FrameChannel channel,
    SessionRole role,
    String nameHint, {
    void Function(SessionResult)? onLive,
  }) async {
    final session = SyncSession(
      channel: channel,
      store: _store,
      role: role,
      liveMode: _liveMode,
      timings: timings,
      now: _clock.now,
      peerNameHint: nameHint,
      onProgress: (p) {
        // Inbound probes (e.g. the hotspot gateway check) stay invisible
        // until the peer says HELLO.
        if (role == SessionRole.responder && p.peerDeviceId == null) return;
        if (_session != null) _setStatus(session: SessionActive(p));
      },
      onLive: (r) {
        _setStatus(session: SessionCompleted(r.summary));
        onLive?.call(r);
      },
    );
    _session = session;
    final SessionResult result;
    try {
      result = await session.run();
    } finally {
      _session = null;
      _busy = false;
    }
    if (role == SessionRole.responder && !result.receivedAnyFrame) {
      return result;
    }
    await _record(result);
    _setStatus(
      session: result.isSuccess
          ? SessionCompleted(result.summary)
          : SessionFailed(
              result.failure ?? SyncFailure.internal,
              result.message,
              result.outcome == SyncOutcome.partial ? result.summary : null,
            ),
    );
    return result;
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
    if (host != null && !_busy) {
      try {
        _claim();
        first = await _connectAndRun(
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
    final session = _session;
    if (session != null) {
      await session.cancel();
    } else if (_busy) {
      _cancelRequested = true;
    }
  }

  @override
  set liveMode(bool enabled) {
    _liveMode = enabled;
    _session?.liveMode = enabled;
  }

  @override
  Stream<List<SyncRecord>> watchHistory() => _store.watchSyncRecords();

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await cancel();
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
