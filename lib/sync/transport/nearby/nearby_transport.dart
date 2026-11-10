// NearbyTransport (SPEC 8.7.2, kind nearby, maxFrame 32 KiB): Google Nearby
// Connections through `nearby_connections`, Android only.
//
// - serviceId 'app.settleup.sync', Strategy.P2P_CLUSTER (every phone may
//   advertise and discover at once).
// - The endpoint name carries the rotating advert id (never the device
//   id), the window tag, the device name and up to 24 discovery tokens
//   (NearbyEndpointName). Discovery parses it into a DiscoveredPeer
//   without connecting.
// - Every connection is accepted automatically; authentication happens in
//   the session layer (SPEC 8.4).
// - One channel frame = one BYTES payload. Nearby delivers BYTES payloads
//   whole and in order; the session's strict frame counters would catch
//   anything else and fail the session safely.
//
// - Nearby Connections is part of Google Play services. On a phone without
//   it (Huawei / HarmonyOS, Fire tablets, de-Googled ROMs) every call fails
//   with API_UNAVAILABLE. The first such failure is remembered: from then
//   on availability() reports unsupported, so the engine hosts and scans
//   over BLE / LAN only, and every Nearby call fails at once with a
//   NearbyUnavailableException that names the reason, without calling the
//   plugin again. It is remembered until the app restarts.
//
// All plugin calls go through NearbyApi, so this file is unit tested with
// a fake radio (test/sync/bluetooth).
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show Platform, SocketException;
import 'dart:typed_data';

import '../../../core/models.dart';
import '../../platform/permissions.dart';
import '../transport.dart';
import 'nearby_api.dart';
import 'nearby_endpoint_name.dart';

export 'nearby_api.dart' show isNearbyApiUnavailable, kNearbyServiceId;

/// Largest frame on a Nearby channel: one BYTES payload
/// (ConnectionsClient.MAX_BYTES_DATA_SIZE).
const int kNearbyMaxFrameBytes = 32 * 1024;

void _log(String message, [Object? error, StackTrace? st]) => developer.log(
      message,
      name: 'settle_up.sync.nearby',
      error: error,
      stackTrace: st,
    );

/// Nearby Connections cannot run on this phone (no usable Google Play
/// services). Thrown by every [NearbyTransport] call once the plugin has
/// said so, instead of calling it again.
final class NearbyUnavailableException implements Exception {
  const NearbyUnavailableException(this.cause);

  /// The plugin error that showed it.
  final Object cause;

  String get message =>
      'Nearby Connections is not available on this phone: it needs '
      'Google Play services, which is missing, disabled or out of date '
      '(sync uses Bluetooth and Wi-Fi instead)';

  @override
  String toString() => 'NearbyUnavailableException: $message. Cause: $cause';
}

final class NearbyTransport implements SyncTransport {
  /// [permissions] defaults to the system wrapper. The other parameters are
  /// test hooks: [api] defaults to the plugin, [isAndroid] to the platform.
  NearbyTransport({
    this._permissions,
    NearbyApi? api,
    bool? isAndroid,
    this.rediscoverInterval = const Duration(seconds: 5),
    this.maxFrameBytes = kNearbyMaxFrameBytes,
  })  : _apiOverride = api,
        _isAndroid = isAndroid ?? Platform.isAndroid;

  /// How often [discover] re-emits endpoints that are still found (the
  /// engine drops a peer unseen for 15 s; Nearby reports an endpoint once).
  final Duration rediscoverInterval;

  /// Largest frame on channels from this transport.
  final int maxFrameBytes;

  final bool _isAndroid;
  NearbyPermissions? _permissions;
  NearbyPermissions get _perms => _permissions ??= NearbyPermissions();

  final NearbyApi? _apiOverride;
  NearbyApi? _apiInstance;
  StreamSubscription<NearbyEvent>? _events;

  NearbyApi get _api {
    final api = _apiInstance ??= _apiOverride ?? PluginNearbyApi();
    _events ??= api.events.listen(
      _onEvent,
      onError: (Object e, StackTrace st) => _log('event stream error', e, st),
    );
    return api;
  }

  final StreamController<FrameChannel> _inbound = StreamController.broadcast();
  final Map<String, _Link> _links = {};

  AdvertiseInfo? _info;
  String? _advertisedName;

  /// Serializes start/stop of advertising and discovery.
  Future<void> _queue = Future.value();

  final Set<StreamController<DiscoveredPeer>> _listeners = {};
  final Map<String, DiscoveredPeer> _found = {};
  bool _discovering = false;
  Timer? _rediscover;
  bool _disposed = false;

  /// Set once the plugin reported that Nearby cannot run on this phone.
  NearbyUnavailableException? _unavailable;

  @override
  TransportKind get kind => TransportKind.nearby;

  /// Whether a plugin call showed that Nearby Connections cannot run on
  /// this phone (no usable Google Play services).
  bool get isApiUnavailable => _unavailable != null;

  /// The endpoint name currently advertised, if any.
  String? get advertisedName => _advertisedName;

  bool get isAdvertising => _advertisedName != null;

  /// Whether the plugin is discovering right now.
  bool get isDiscovering => _discovering;

  /// Open channels (tests).
  int get openChannels =>
      _links.values.where((l) => l.channel != null).length;

  // ------------------------------------------------------ availability --

  @override
  Future<TransportAvailability> availability() async {
    if (!_isAndroid || _unavailable != null) {
      return TransportAvailability.unsupported;
    }
    return _perms.check(kind);
  }

  @override
  Future<TransportAvailability> requestPermissions() async {
    if (!_isAndroid || _unavailable != null) {
      return TransportAvailability.unsupported;
    }
    return _perms.request(kind);
  }

  /// Runs one plugin call that can show Nearby is unavailable. Once one
  /// has, fails with the remembered [NearbyUnavailableException] instead
  /// of calling the plugin.
  Future<T> _call<T>(Future<T> Function(NearbyApi api) body) async {
    final known = _unavailable;
    if (known != null) throw known;
    try {
      return await body(_api);
    } catch (e, st) {
      if (!isNearbyApiUnavailable(e)) rethrow;
      final unavailable = _unavailable ??= NearbyUnavailableException(e);
      _log('Nearby is unavailable on this phone', e, st);
      throw unavailable;
    }
  }

  // ------------------------------------------------------- advertising --

  @override
  Future<void> startAdvertising(AdvertiseInfo info) => _serial(() async {
        _checkAlive();
        final name = NearbyEndpointName.of(info).encode();
        _info = info;
        // A repeated call (new token window, new group) updates in place.
        // Nearby cannot rename an advertisement, so a changed name restarts
        // it; open connections are not touched by that.
        if (name == _advertisedName) return;
        if (_advertisedName != null) {
          _advertisedName = null;
          try {
            await _api.stopAdvertising();
          } catch (e, st) {
            _log('stopAdvertising before re-advertise failed', e, st);
          }
        }
        try {
          await _call((api) => api.startAdvertising(name));
          _advertisedName = name;
        } catch (e) {
          _info = null;
          rethrow;
        }
      });

  @override
  Future<void> stopAdvertising() => _serial(() async {
        _info = null;
        if (_advertisedName == null) return;
        _advertisedName = null;
        try {
          await _api.stopAdvertising();
        } catch (e, st) {
          _log('stopAdvertising failed', e, st);
        }
      });

  @override
  Stream<FrameChannel> get inbound => _inbound.stream;

  // --------------------------------------------------------- discovery --

  @override
  Stream<DiscoveredPeer> discover() {
    late final StreamController<DiscoveredPeer> ctl;
    ctl = StreamController<DiscoveredPeer>(
      onListen: () {
        if (_disposed) {
          unawaited(ctl.close());
          return;
        }
        _listeners.add(ctl);
        for (final p in _found.values) {
          ctl.add(p);
        }
        unawaited(_updateDiscovery());
      },
      onCancel: () {
        _listeners.remove(ctl);
        return _updateDiscovery();
      },
    );
    return ctl.stream;
  }

  Future<void> _updateDiscovery() => _serial(() async {
        final want = _listeners.isNotEmpty && !_disposed;
        if (want == _discovering) return;
        if (want) {
          // Set first: Nearby may report endpoints before the call returns.
          _discovering = true;
          try {
            await _call((api) => api.startDiscovery(_ownName()));
          } catch (e, st) {
            _discovering = false;
            _found.clear();
            _log('startDiscovery failed', e, st);
            for (final l in _listeners.toList()) {
              l.addError(e, st);
            }
            return;
          }
          _rediscover = Timer.periodic(rediscoverInterval, (_) => _emitAll());
        } else {
          _discovering = false;
          _rediscover?.cancel();
          _rediscover = null;
          _found.clear();
          try {
            await _api.stopDiscovery();
          } catch (e, st) {
            _log('stopDiscovery failed', e, st);
          }
        }
      });

  void _emit(DiscoveredPeer peer) {
    for (final l in _listeners) {
      l.add(peer);
    }
  }

  void _emitAll() {
    for (final p in _found.values) {
      _emit(p);
    }
  }

  // ----------------------------------------------------------- connect --

  @override
  Future<FrameChannel> connect(
    DiscoveredPeer peer, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _checkAlive();
    if (peer.kind != kind) {
      throw ArgumentError.value(peer.kind, 'peer.kind', 'not nearby');
    }
    final id = peer.address;
    if (_links.containsKey(id)) {
      throw SocketException('Already connecting or connected to $id');
    }
    final known = _unavailable;
    if (known != null) {
      throw SocketException('Nearby connection to $id failed: $known');
    }
    final link = _Link(id, outbound: true);
    _links[id] = link;
    try {
      await _call((api) => api.requestConnection(_ownName(), id))
          .timeout(timeout);
      return await link.connected!.future.timeout(timeout);
    } on TimeoutException {
      _abandon(link);
      rethrow;
    } catch (e) {
      _abandon(link);
      if (e is SocketException) rethrow;
      throw SocketException('Nearby connection to $id failed: $e');
    }
  }

  /// Gives up on a pending outbound [link].
  void _abandon(_Link link) {
    if (!identical(_links[link.endpointId], link)) return;
    _links.remove(link.endpointId);
    unawaited(_disconnect(link.endpointId));
  }

  /// The name we give Nearby for discovery and connection requests.
  String _ownName() {
    final advertised = _advertisedName;
    if (advertised != null) return advertised;
    final info = _info;
    if (info != null) return NearbyEndpointName.of(info).encode();
    return const NearbyEndpointName(
      advertId: '',
      deviceName: '',
      groupTokens: [],
    ).encode();
  }

  // ------------------------------------------------------------ events --

  void _onEvent(NearbyEvent e) {
    if (_disposed) return;
    switch (e) {
      case NearbyEndpointFound(:final endpointId, :final endpointName):
        final parsed = NearbyEndpointName.tryParse(endpointName);
        if (parsed == null) {
          _log('ignoring endpoint $endpointId with name "$endpointName"');
          return;
        }
        if (!_discovering) return;
        final peer = parsed.toPeer(endpointId);
        _found[endpointId] = peer;
        _emit(peer);
      case NearbyEndpointLost(:final endpointId):
        _found.remove(endpointId);
      case NearbyConnectionInitiated(:final endpointId, :final incoming):
        unawaited(_onInitiated(endpointId, incoming: incoming));
      case NearbyConnectionResult(:final endpointId, :final connected):
        _onResult(endpointId, connected: connected);
      case NearbyDisconnected(:final endpointId):
        final link = _links.remove(endpointId);
        link?.connected?.completeErrorOnce(
          SocketException('Nearby endpoint $endpointId disconnected'),
        );
        link?.channel?._remoteClosed();
      case NearbyBytesReceived(:final endpointId, :final bytes):
        final channel = _links[endpointId]?.channel;
        if (channel == null) {
          _log('dropping ${bytes.length} bytes from unconnected $endpointId');
          return;
        }
        channel._receive(bytes);
      case NearbyPayloadFailed(:final endpointId, :final payloadId):
        _links[endpointId]?.channel?._fail(
          SocketException('Nearby payload $payloadId to/from $endpointId failed'),
        );
    }
  }

  Future<void> _onInitiated(String id, {required bool incoming}) async {
    final api = _api;
    var existing = _links[id];
    if (incoming &&
        existing != null &&
        !existing.outbound &&
        existing.channel == null) {
      // An earlier inbound attempt that never got a result: start over.
      _links.remove(id);
      existing = null;
    }
    final ours = existing != null && existing.outbound && !incoming;
    final accept = ours ||
        (incoming && existing == null && _info != null && !_disposed);
    if (!accept) {
      try {
        await api.rejectConnection(id);
      } catch (e, st) {
        _log('rejectConnection($id) failed', e, st);
      }
      return;
    }
    final link = existing ?? (_links[id] = _Link(id, outbound: false));
    try {
      await _call((api) => api.acceptConnection(id));
    } catch (e, st) {
      _log('acceptConnection($id) failed', e, st);
      if (identical(_links[id], link)) _links.remove(id);
      link.connected?.completeErrorOnce(
        SocketException('Nearby accept for $id failed: $e'),
      );
      unawaited(_disconnect(id));
    }
  }

  void _onResult(String id, {required bool connected}) {
    final link = _links[id];
    if (link == null || link.channel != null) {
      // Nobody waits for it (timed out, or a stray result): hang up.
      if (connected && link == null) unawaited(_disconnect(id));
      return;
    }
    if (!connected) {
      _links.remove(id);
      link.connected?.completeErrorOnce(
        SocketException('Nearby connection to $id was rejected'),
      );
      return;
    }
    final channel = _NearbyChannel(this, id, maxFrameBytes);
    link.channel = channel;
    if (link.outbound) {
      final completer = link.connected!;
      if (completer.isCompleted) {
        // connect() already gave up.
        unawaited(channel.close());
      } else {
        completer.complete(channel);
      }
    } else {
      _inbound.add(channel);
    }
  }

  // ---------------------------------------------------------- channels --

  void _released(_NearbyChannel channel) {
    final link = _links[channel.peerAddress];
    if (link != null && identical(link.channel, channel)) {
      _links.remove(channel.peerAddress);
    }
  }

  Future<void> _disconnect(String id) async {
    try {
      await _api.disconnect(id);
    } catch (e, st) {
      _log('disconnect($id) failed', e, st);
    }
  }

  // ------------------------------------------------------------ dispose --

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await stopAdvertising();
    _disposed = true;
    for (final l in _listeners.toList()) {
      await l.close();
    }
    _listeners.clear();
    await _updateDiscovery();
    for (final link in _links.values.toList()) {
      link.connected?.completeErrorOnce(StateError('NearbyTransport disposed'));
      await link.channel?.close();
    }
    _links.clear();
    if (_apiInstance != null) {
      try {
        await _api.stopAllEndpoints();
      } catch (e, st) {
        _log('stopAllEndpoints failed', e, st);
      }
    }
    await _events?.cancel();
    _events = null;
    await _inbound.close();
  }

  Future<void> _serial(Future<void> Function() body) {
    final next = _queue.then((_) => body());
    _queue = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  void _checkAlive() {
    if (_disposed) throw StateError('NearbyTransport disposed');
  }
}

final class _Link {
  _Link(this.endpointId, {required this.outbound})
      : connected = outbound ? Completer<FrameChannel>() : null;

  final String endpointId;
  final bool outbound;

  /// Outbound only: completes with the channel once Nearby connects.
  final Completer<FrameChannel>? connected;
  _NearbyChannel? channel;
}

extension on Completer<FrameChannel> {
  void completeErrorOnce(Object error) {
    if (!isCompleted) completeError(error);
  }
}

final class _NearbyChannel implements FrameChannel {
  _NearbyChannel(this._transport, this.peerAddress, this.maxFrameBytes);

  final NearbyTransport _transport;
  @override
  final String peerAddress;
  @override
  final int maxFrameBytes;

  final StreamController<Uint8List> _frames = StreamController();
  Future<void> _tail = Future.value();

  /// No more sends accepted (local close, failure or hang-up).
  bool _closed = false;

  /// The connection is gone: queued sends fail instead of going out.
  bool _dead = false;

  @override
  TransportKind get kind => TransportKind.nearby;

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Future<void> send(Uint8List frame) {
    if (_closed) return Future.error(StateError('Channel closed'));
    if (frame.length > maxFrameBytes) {
      return Future.error(
        ArgumentError('Frame of ${frame.length} bytes > $maxFrameBytes'),
      );
    }
    final copy = Uint8List.fromList(frame);
    final sent = _tail.then((_) async {
      if (_dead) throw StateError('Channel closed');
      try {
        await _transport._call((api) => api.sendBytes(peerAddress, copy));
      } catch (e) {
        final error = SocketException('Nearby send to $peerAddress failed: $e');
        _fail(error);
        throw error;
      }
    });
    _tail = sent.then((_) {}, onError: (Object _) {});
    return sent;
  }

  void _receive(Uint8List bytes) {
    if (_closed) return;
    if (bytes.length > maxFrameBytes) {
      _fail(SocketException(
        'Nearby frame of ${bytes.length} bytes > $maxFrameBytes',
      ));
      return;
    }
    _frames.add(bytes);
  }

  /// Transport failure: error, then done; the connection is dropped.
  void _fail(Object error) {
    if (_dead) return;
    _closed = _dead = true;
    _frames.addError(error);
    unawaited(_frames.close());
    _transport._released(this);
    unawaited(_transport._disconnect(peerAddress));
  }

  /// The peer (or Nearby) hung up.
  void _remoteClosed() {
    if (_dead) return;
    _closed = _dead = true;
    unawaited(_frames.close());
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _transport._released(this);
    // Frames queued before close still go out first.
    await _tail;
    _dead = true;
    await _transport._disconnect(peerAddress);
    // Nobody may drain it after a local close; do not wait.
    unawaited(_frames.close());
  }
}
