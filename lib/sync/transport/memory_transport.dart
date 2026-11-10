// In-process transport for tests and UI development (SPEC 8.7.2): a hub
// pairs channels, with configurable maxFrameBytes, optional latency and
// fault injection (dropAfterFrames).
import 'dart:async';
import 'dart:io' show SocketException;
import 'dart:typed_data';

import '../../core/models.dart';
import '../crypto/tokens.dart';
import 'hosting_details.dart';
import 'transport.dart';

/// Shared "air" for [MemoryTransport]s: who is advertising, and the links
/// between them.
final class MemoryTransportHub {
  MemoryTransportHub({this.latency = Duration.zero});

  /// One-way delay applied to every frame (order is preserved).
  Duration latency;

  /// Number of channels opened so far (for tests).
  int connections = 0;

  final Map<(TransportKind, String), MemoryTransport> _transports = {};
  final Map<(TransportKind, String), AdvertiseInfo> _advertising = {};
  final StreamController<void> _changes = StreamController.broadcast();

  void _register(MemoryTransport t) {
    final key = (t.kind, t.address);
    if (_transports.containsKey(key)) {
      throw StateError('Address ${t.address} already used for ${t.kind.name}');
    }
    _transports[key] = t;
  }

  void _unregister(MemoryTransport t) {
    _transports.remove((t.kind, t.address));
    _setAdvertising(t, null);
  }

  void _setAdvertising(MemoryTransport t, AdvertiseInfo? info) {
    final key = (t.kind, t.address);
    if (info == null) {
      if (_advertising.remove(key) == null) return;
    } else {
      _advertising[key] = info;
    }
    _changes.add(null);
  }

  List<DiscoveredPeer> _visibleTo(MemoryTransport scanner) => [
        for (final e in _advertising.entries)
          if (e.key.$1 == scanner.kind && e.key.$2 != scanner.address)
            DiscoveredPeer(
              kind: scanner.kind,
              address: e.key.$2,
              name: e.value.deviceName,
              advertId: e.value.advertId,
              // Sorted, as real transports advertise them (SPEC 8.3).
              groupTokens: (e.value.groupTokens.toList()..sort()).toSet(),
              windowTag: switch (e.value.tokenWindow) {
                final w? => w % DiscoveryTokens.windowTagModulus,
                null => null,
              },
            ),
      ];
}

final class MemoryTransport implements SyncTransport, HostingDetails {
  MemoryTransport(
    this.hub, {
    required this.kind,
    required this.address,
    this.maxFrameBytes = 1 << 20,
  }) {
    hub._register(this);
  }

  final MemoryTransportHub hub;
  @override
  final TransportKind kind;
  final String address;
  final int maxFrameBytes;

  /// What [availability] reports (tests flip it).
  TransportAvailability availabilityState = TransportAvailability.ready;

  /// What [requestPermissions] turns the availability into.
  TransportAvailability afterPermissionRequest = TransportAvailability.ready;

  /// If set, every channel opened by [connect] from this transport drops
  /// (both ends error with a SocketException) after this many frames have
  /// been delivered in total, counting both directions.
  int? dropAfterFrames;

  /// If set, [connect] fails with a SocketException.
  bool failConnect = false;

  /// How often [discover] re-emits peers that are still advertising.
  Duration rediscoverInterval = const Duration(seconds: 5);

  final StreamController<FrameChannel> _inbound =
      StreamController.broadcast();
  AdvertiseInfo? _info;
  bool _disposed = false;

  bool get isAdvertising => _info != null;

  /// Open [discover] subscriptions (leak checks in tests).
  int get activeDiscoveries => _activeDiscoveries;
  int _activeDiscoveries = 0;

  @override
  Future<TransportAvailability> availability() async => availabilityState;

  @override
  Future<TransportAvailability> requestPermissions() async {
    if (availabilityState == TransportAvailability.needsPermission) {
      availabilityState = afterPermissionRequest;
    }
    return availabilityState;
  }

  @override
  Future<void> startAdvertising(AdvertiseInfo info) async {
    _checkAlive();
    _info = info;
    hub._setAdvertising(this, info);
  }

  @override
  Future<void> stopAdvertising() async {
    _info = null;
    hub._setAdvertising(this, null);
  }

  @override
  Stream<FrameChannel> get inbound => _inbound.stream;

  @override
  Stream<DiscoveredPeer> discover() {
    late StreamController<DiscoveredPeer> ctl;
    StreamSubscription<void>? changes;
    Timer? timer;
    void emitAll() {
      if (ctl.isClosed) return;
      for (final p in hub._visibleTo(this)) {
        ctl.add(p);
      }
    }

    ctl = StreamController<DiscoveredPeer>(
      onListen: () {
        _activeDiscoveries++;
        changes = hub._changes.stream.listen((_) => emitAll());
        timer = Timer.periodic(rediscoverInterval, (_) => emitAll());
        scheduleMicrotask(emitAll);
      },
      onCancel: () async {
        _activeDiscoveries--;
        timer?.cancel();
        await changes?.cancel();
      },
    );
    return ctl.stream;
  }

  @override
  Future<FrameChannel> connect(
    DiscoveredPeer peer, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _checkAlive();
    final remote = hub._transports[(kind, peer.address)];
    if (failConnect ||
        remote == null ||
        remote._info == null ||
        remote._disposed ||
        peer.kind != kind) {
      throw SocketException('Cannot reach ${peer.address}');
    }
    hub.connections++;
    final link = _MemoryLink(
      hub: hub,
      maxFrameBytes:
          maxFrameBytes < remote.maxFrameBytes ? maxFrameBytes : remote.maxFrameBytes,
      dropAfterFrames: dropAfterFrames,
    );
    final local = MemoryFrameChannel._(link, kind, peer.address);
    final other = MemoryFrameChannel._(link, kind, address);
    link.a = local;
    link.b = other;
    remote._inbound.add(other);
    return local;
  }

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    hub._unregister(this);
    await _inbound.close();
  }

  @override
  Future<List<String>> hostAddresses() async =>
      _info == null ? const [] : [address];

  @override
  Future<String?> wifiName() async => null;

  /// Hub addresses are names, not IP addresses: every one is in-process.
  @override
  bool isLinkHost(String address) => true;

  void _checkAlive() {
    if (_disposed) throw StateError('MemoryTransport disposed');
  }
}

/// Both ends of one in-memory connection.
final class _MemoryLink {
  _MemoryLink({
    required this.hub,
    required this.maxFrameBytes,
    required this.dropAfterFrames,
  });

  final MemoryTransportHub hub;
  final int maxFrameBytes;
  final int? dropAfterFrames;
  late final MemoryFrameChannel a;
  late final MemoryFrameChannel b;
  int delivered = 0;
  bool closed = false;

  MemoryFrameChannel peerOf(MemoryFrameChannel c) => identical(c, a) ? b : a;

  void close({Object? error}) {
    if (closed) return;
    closed = true;
    a._finish(error);
    b._finish(error);
  }
}

final class MemoryFrameChannel implements FrameChannel {
  MemoryFrameChannel._(this._link, this.kind, this.peerAddress);

  final _MemoryLink _link;
  @override
  final TransportKind kind;
  @override
  final String peerAddress;

  final StreamController<Uint8List> _incoming = StreamController();

  /// Serializes deliveries INTO this channel, so latency keeps order.
  Future<void> _tail = Future.value();

  @override
  int get maxFrameBytes => _link.maxFrameBytes;

  @override
  Stream<Uint8List> get frames => _incoming.stream;

  @override
  Future<void> send(Uint8List frame) async {
    if (_link.closed) throw StateError('Channel closed');
    if (frame.length > maxFrameBytes) {
      throw ArgumentError('Frame of ${frame.length} bytes > $maxFrameBytes');
    }
    final copy = Uint8List.fromList(frame);
    final peer = _link.peerOf(this);
    final latency = _link.hub.latency;
    peer._tail = peer._tail.then((_) async {
      await Future<void>.delayed(latency);
      if (!peer._incoming.isClosed) peer._incoming.add(copy);
    });
    _link.delivered++;
    final limit = _link.dropAfterFrames;
    if (limit != null && _link.delivered >= limit) {
      _link.close(error: const SocketException('Connection dropped'));
    }
  }

  @override
  Future<void> close() async => _link.close();

  void _finish(Object? error) {
    _tail = _tail.then((_) async {
      if (_incoming.isClosed) return;
      if (error != null) _incoming.addError(error);
      // Completes only once a listener drained it; do not wait for that.
      unawaited(_incoming.close());
    });
  }
}
