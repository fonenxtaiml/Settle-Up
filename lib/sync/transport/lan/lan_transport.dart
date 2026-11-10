// LanTransport (SPEC 8.7.2, kind lan, maxFrame 1 MiB): a TCP server on
// port 52741 (falling back to a free port when busy), length-prefixed
// frames, mDNS advertise/browse (`_settleup._tcp`) and the hotspot gateway
// probe. Implements HostingDetails so host mode can show the addresses
// that go in the connect QR.
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:typed_data';

import '../../../core/models.dart';
import '../../platform/permissions.dart';
import '../hosting_details.dart';
import '../sighting_cache.dart';
import '../transport.dart';
import 'gateway_probe.dart';
import 'lan_network.dart';
import 'local_address.dart';
import 'mdns.dart';
import 'tcp_framing.dart';

export 'tcp_framing.dart' show kLanMaxFrameBytes;

/// The default sync port.
const int kLanDefaultPort = 52741;

void _log(String message, [Object? error, StackTrace? st]) => developer.log(
      message,
      name: 'settle_up.sync.lan',
      error: error,
      stackTrace: st,
    );

final class LanTransport implements SyncTransport, HostingDetails {
  /// [port] is the preferred server port (0 = any free port) and the port
  /// the gateway probe tries. The other parameters are test hooks: on a
  /// phone they default to Bonsoir, `dart:io` + `network_info_plus` and
  /// the system permission wrapper.
  LanTransport({
    this.port = kLanDefaultPort,
    this._permissions,
    this._mdns,
    LanNetwork? network,
    this._bindAddress,
    this.rediscoverInterval = const Duration(seconds: 5),
    this.probeInterval = const Duration(seconds: 5),
    this.firstFrameTimeout = const Duration(seconds: 10),
    this.maxFrameBytes = kLanMaxFrameBytes,
    this._allowLoopbackGateway = false,
  }) : _network = network ?? SystemLanNetwork();

  /// Preferred server port; also the port probed on the hotspot gateway.
  final int port;

  /// How often [discover] re-emits peers that are still visible (the
  /// engine drops a peer unseen for 15 s).
  final Duration rediscoverInterval;

  /// How often the gateway is probed while discovering.
  final Duration probeInterval;

  /// An inbound connection that sends no complete frame in this time is
  /// dropped without ever reaching [inbound].
  final Duration firstFrameTimeout;

  /// Largest frame on channels from this transport (SPEC: 1 MiB).
  final int maxFrameBytes;

  NearbyPermissions? _permissions;
  NearbyPermissions get _perms =>
      _permissions ??= NearbyPermissions(
        platform: SystemPermissionPlatform(network: _network),
      );

  MdnsBackend? _mdns;
  MdnsBackend get _mdnsBackend => _mdns ??= BonsoirMdns();

  final LanNetwork _network;
  final InternetAddress? _bindAddress;
  final bool _allowLoopbackGateway;

  final StreamController<FrameChannel> _inbound = StreamController.broadcast();
  final Set<_PendingInbound> _pending = {};

  ServerSocket? _server;
  StreamSubscription<Socket>? _serverSub;
  AdvertiseInfo? _info;

  /// Advert ids this phone announced lately (the current one and the one
  /// before it), so our own mDNS answer is not listed while it rotates.
  final List<String> _ownAdvertIds = [];
  bool _disposed = false;

  /// Serializes start/stop advertising.
  Future<void> _adQueue = Future.value();

  /// Addresses currently seen through mDNS -> when last seen (so the
  /// gateway probe does not list the same phone twice).
  final Map<String, DateTime> _mdnsSeen = {};

  @override
  TransportKind get kind => TransportKind.lan;

  /// The bound server port while advertising, else null.
  int? get boundPort => _server?.port;

  bool get isAdvertising => _info != null;

  // ------------------------------------------------------ availability --

  @override
  Future<TransportAvailability> availability() => _perms.check(kind);

  @override
  Future<TransportAvailability> requestPermissions() => _perms.request(kind);

  // ------------------------------------------------------- advertising --

  @override
  Future<void> startAdvertising(AdvertiseInfo info) => _serialAd(() async {
        _checkAlive();
        // A repeated call (new token window, new group) updates in place:
        // the server and its open connections stay, only mDNS changes.
        final server = _server ?? await _bind();
        _info = info;
        final id = info.advertId;
        if (id != null && !_ownAdvertIds.contains(id)) {
          _ownAdvertIds.add(id);
          if (_ownAdvertIds.length > 2) _ownAdvertIds.removeAt(0);
        }
        try {
          await _mdnsBackend.advertise(MdnsAdvert.of(info, server.port));
        } catch (e, st) {
          // The QR and the gateway probe still work without mDNS.
          _log('mDNS advertise failed', e, st);
        }
      });

  @override
  Future<void> stopAdvertising() => _serialAd(_stopAdvertising);

  Future<void> _stopAdvertising() async {
    final wasAdvertising = _info != null || _server != null;
    _info = null;
    if (wasAdvertising) {
      try {
        await _mdnsBackend.stopAdvertising();
      } catch (e, st) {
        _log('mDNS stop failed', e, st);
      }
    }
    final sub = _serverSub;
    final server = _server;
    _serverSub = null;
    _server = null;
    await sub?.cancel();
    await server?.close();
    // Connections that never sent a frame die with the server. Established
    // channels (a running session) keep going.
    for (final p in _pending.toList()) {
      p.abort();
    }
  }

  Future<void> _serialAd(Future<void> Function() action) {
    final next = _adQueue.then((_) => action());
    _adQueue = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  Future<ServerSocket> _bind() async {
    final address = _bindAddress ?? InternetAddress.anyIPv4;
    ServerSocket server;
    try {
      server = await ServerSocket.bind(address, port);
    } on SocketException catch (e) {
      if (port == 0) rethrow;
      _log('port $port busy, using a free port', e);
      server = await ServerSocket.bind(address, 0);
    }
    _server = server;
    _serverSub = server.listen(
      _onConnection,
      onError: (Object e, StackTrace st) => _log('server error', e, st),
    );
    return server;
  }

  void _onConnection(Socket socket) {
    if (_disposed) {
      socket.destroy();
      return;
    }
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {
      // Not every socket type supports it.
    }
    final peer = _remoteOf(socket);
    late final _PendingInbound pending;
    pending = _PendingInbound(
      socket: socket,
      peerAddress: peer,
      maxFrameBytes: maxFrameBytes,
      timeout: firstFrameTimeout,
      onReady: (channel) {
        _pending.remove(pending);
        if (_disposed || _inbound.isClosed) {
          unawaited(channel.close());
          return;
        }
        _inbound.add(channel);
      },
      onDropped: () => _pending.remove(pending),
    );
    _pending.add(pending);
  }

  static String _remoteOf(Socket socket) {
    try {
      return formatHostPort(socket.remoteAddress, socket.remotePort);
    } catch (_) {
      return '';
    }
  }

  @override
  Stream<FrameChannel> get inbound => _inbound.stream;

  // ------------------------------------------------------ hosting info --

  @override
  Future<List<String>> hostAddresses() async {
    final server = _server;
    if (server == null || _info == null) return const [];
    final bound = _bindAddress;
    if (bound != null && !_isAny(bound)) {
      return [formatHostPort(bound, server.port)];
    }
    final addresses = await _network.ipv4Addresses();
    final seen = <String>{};
    return [
      for (final a in addresses)
        if (seen.add(a.address.address)) formatHostPort(a.address, server.port),
    ];
  }

  static bool _isAny(InternetAddress a) =>
      a.address == InternetAddress.anyIPv4.address ||
      a.address == InternetAddress.anyIPv6.address;

  @override
  Future<String?> wifiName() => _network.wifiName();

  @override
  bool isLinkHost(String address) => isLocalNetworkHostPort(address);

  // --------------------------------------------------------- discovery --

  @override
  Stream<DiscoveredPeer> discover() {
    late StreamController<DiscoveredPeer> ctl;
    // Service name -> sighting; only the newest per phone is emitted.
    final cache = SightingCache();
    StreamSubscription<(String, MdnsSighting?)>? browse;
    StreamSubscription<DiscoveredPeer>? probe;
    Timer? refresh;

    // Advert ids are random per phone and window (SPEC 8.3), so a match
    // is our own answer; a prefix of the device id would also match phones
    // set up in the same minute.
    bool isSelf(DiscoveredPeer p) =>
        p.advertId != null && _ownAdvertIds.contains(p.advertId);

    void emit(DiscoveredPeer p) {
      if (ctl.isClosed || isSelf(p)) return;
      _mdnsSeen[p.address] = DateTime.now();
      ctl.add(p);
    }

    // An address no longer shown through mDNS goes back to the probe.
    void forget(Iterable<DiscoveredPeer> peers) {
      final shown = {for (final p in cache.visible) p.address};
      for (final p in peers) {
        if (!shown.contains(p.address)) _mdnsSeen.remove(p.address);
      }
    }

    void onSighting((String, MdnsSighting?) event) {
      final (name, sighting) = event;
      final peer = sighting?.toPeer();
      if (peer == null) {
        // A goodbye withdraws this service only. If it was its phone's
        // newest sighting, the phone's next newest one that had no goodbye
        // is shown again: a stale replay of an old name may have resolved
        // after the live one (SYNC-R8-01).
        final (:removed, :shown) = cache.remove(name);
        if (removed != null) forget([removed]);
        shown.forEach(emit);
        return;
      }
      // One phone runs one service at a time: this sighting hides the
      // service's earlier one and any other cached service of the same
      // phone (same address or advert id), such as its name before a
      // rename whose goodbye was missed (SYNC-R6-01). The hidden ones stay
      // cached until their own goodbye.
      forget(cache.put(name, peer));
      emit(peer);
    }

    bool knownViaMdns(String address) {
      final seen = _mdnsSeen[address];
      return seen != null &&
          DateTime.now().difference(seen) < const Duration(seconds: 15);
    }

    ctl = StreamController<DiscoveredPeer>(
      onListen: () {
        browse = _mdnsBackend.browse().listen(
              onSighting,
              onError: (Object e, StackTrace st) =>
                  _log('mDNS browse error', e, st),
            );
        probe = GatewayProbe(
          network: _network,
          port: port == 0 ? kLanDefaultPort : port,
          interval: probeInterval,
          allowLoopbackGateway: _allowLoopbackGateway,
        ).watch(skip: knownViaMdns).listen((p) {
          if (!ctl.isClosed) ctl.add(p);
        });
        // Re-emit what mDNS still sees: resolve events come only on change.
        refresh = Timer.periodic(rediscoverInterval, (_) {
          cache.visible.forEach(emit);
        });
      },
      onCancel: () async {
        refresh?.cancel();
        await probe?.cancel();
        await browse?.cancel();
        for (final p in cache.all) {
          _mdnsSeen.remove(p.address);
        }
        cache.clear();
      },
    );
    return ctl.stream;
  }

  // ----------------------------------------------------------- connect --

  @override
  Future<FrameChannel> connect(
    DiscoveredPeer peer, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _checkAlive();
    if (peer.kind != TransportKind.lan) {
      throw ArgumentError.value(peer.kind, 'peer.kind', 'Not a LAN peer');
    }
    final target = parseHostPort(peer.address, defaultPort: kLanDefaultPort);
    if (target == null) {
      throw SocketException('Bad LAN address "${peer.address}"');
    }
    final Socket socket;
    try {
      socket = await Socket.connect(target.host, target.port, timeout: timeout)
          .timeout(timeout + const Duration(milliseconds: 500));
    } on SocketException catch (e) {
      if (Platform.isIOS && _isTimeout(e)) {
        // iOS blocks local-network traffic silently until the user allows
        // it, which looks like a timeout.
        throw SocketException(
          'Allow Local Network for Settle Up in Settings',
          osError: e.osError,
          address: e.address,
          port: e.port,
        );
      }
      rethrow;
    }
    try {
      socket.setOption(SocketOption.tcpNoDelay, true);
    } catch (_) {
      // Not every socket type supports it.
    }
    if (_disposed) {
      socket.destroy();
      throw StateError('LanTransport disposed');
    }
    return SocketFrameChannel(
      socket,
      peerAddress: peer.address,
      maxFrameBytes: maxFrameBytes,
    );
  }

  static bool _isTimeout(SocketException e) =>
      e.message.toLowerCase().contains('timed out') ||
      e.osError?.errorCode == 60 || // ETIMEDOUT on Darwin
      e.osError?.errorCode == 65; // EHOSTUNREACH on Darwin

  // ----------------------------------------------------------- dispose --

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _serialAd(_stopAdvertising);
    await _inbound.close();
  }

  void _checkAlive() {
    if (_disposed) throw StateError('LanTransport disposed');
  }
}

/// An accepted socket waiting for its first complete frame. Probes (the
/// hotspot gateway check) and port scanners close before that and never
/// reach the engine, so they cannot make it "busy".
final class _PendingInbound {
  _PendingInbound({
    required this.socket,
    required this.peerAddress,
    required this.maxFrameBytes,
    required Duration timeout,
    required this.onReady,
    required this.onDropped,
  }) : _decoder = LanFrameDecoder(maxFrameBytes: maxFrameBytes) {
    _timer = Timer(timeout, abort);
    _sub = socket.listen(
      _onData,
      onError: (Object _) => abort(),
      onDone: abort,
      cancelOnError: true,
    );
  }

  final Socket socket;
  final String peerAddress;
  final int maxFrameBytes;
  final void Function(SocketFrameChannel channel) onReady;
  final void Function() onDropped;
  final LanFrameDecoder _decoder;
  late final Timer _timer;
  late final StreamSubscription<Uint8List> _sub;
  bool _finished = false;

  void _onData(Uint8List data) {
    if (_finished) return;
    final List<Uint8List> frames;
    try {
      frames = _decoder.add(data);
    } on FrameLengthException {
      abort();
      return;
    }
    if (frames.isEmpty) return;
    _finished = true;
    _timer.cancel();
    _sub.pause();
    onReady(SocketFrameChannel(
      socket,
      peerAddress: peerAddress,
      maxFrameBytes: maxFrameBytes,
      decoder: _decoder,
      pendingFrames: frames,
      subscription: _sub,
    ));
  }

  void abort() {
    if (_finished) return;
    _finished = true;
    _timer.cancel();
    unawaited(_sub.cancel());
    socket.destroy();
    onDropped();
  }
}
