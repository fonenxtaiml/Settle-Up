// Hotspot gateway probe (SPEC 8.7.2). mDNS is unreliable on phone
// hotspots (many drop multicast), but a phone that joined a hotspot knows
// the hotspot phone's address: it is the Wi-Fi gateway. While discovery
// runs we read the gateway every 5 s and try a TCP connect to the sync
// port. If it answers, the hotspot phone is hosting and we list it. The
// probe connection closes before sending a frame, which the server ignores.
//
// The gateway is always read at runtime (never assume 192.168.43.1:
// Android picks random subnets since API 30, iOS uses 172.20.10.1).
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import '../../../core/models.dart';
import '../transport.dart';
import 'lan_network.dart';
import 'tcp_framing.dart';

/// Name shown for a peer found only through the gateway.
const String kGatewayPeerName = 'Phone sharing its hotspot';

typedef SocketConnector = Future<Socket> Function(
  String host,
  int port,
  Duration timeout,
);

Future<Socket> _connect(String host, int port, Duration timeout) =>
    Socket.connect(host, port, timeout: timeout);

void _log(String message, [Object? error, StackTrace? st]) => developer.log(
      message,
      name: 'settle_up.sync.lan.probe',
      error: error,
      stackTrace: st,
    );

final class GatewayProbe {
  GatewayProbe({
    required this.network,
    required this.port,
    this.interval = const Duration(seconds: 5),
    this.connectTimeout = const Duration(milliseconds: 1500),
    this.allowLoopbackGateway = false,
    SocketConnector? connector,
  }) : _connector = connector ?? _connect;

  final LanNetwork network;

  /// The sync port probed on the gateway (the default 52741: a host that
  /// had to fall back to another port is still found through mDNS or QR).
  final int port;
  final Duration interval;
  final Duration connectTimeout;
  final SocketConnector _connector;

  /// Accept a loopback gateway. Tests probe 127.0.0.1; on a phone the
  /// gateway is never loopback.
  final bool allowLoopbackGateway;

  /// Probes once: the gateway peer, or null when there is no gateway, it is
  /// one of our own addresses, or nothing answers on [port].
  Future<DiscoveredPeer?> probeOnce() async {
    final raw = await network.gatewayIp();
    if (raw == null) return null;
    final gw = InternetAddress.tryParse(raw);
    if (gw == null || (gw.isLoopback && !allowLoopbackGateway)) return null;
    if (gw.address == '0.0.0.0') return null;
    final mine = await network.ipv4Addresses();
    if (mine.any((a) => a.address.address == gw.address)) return null;
    Socket? socket;
    try {
      socket = await _connector(gw.address, port, connectTimeout)
          .timeout(connectTimeout + const Duration(milliseconds: 500));
    } on SocketException {
      return null;
    } on TimeoutException {
      return null;
    } catch (e, st) {
      _log('probe ${gw.address}:$port failed', e, st);
      return null;
    }
    socket.destroy();
    return DiscoveredPeer(
      kind: TransportKind.lan,
      address: formatHostPort(gw, port),
      name: kGatewayPeerName,
    );
  }

  /// Probes now and then every [interval] while listened to. Emits the
  /// gateway peer each time it answers (so it stays fresh in the engine's
  /// 15 s registry). [skip] returns true for an address already known
  /// through mDNS, which then wins (it carries the device id and tokens).
  Stream<DiscoveredPeer> watch({bool Function(String address)? skip}) {
    late StreamController<DiscoveredPeer> ctl;
    Timer? timer;
    var running = false;

    Future<void> tick() async {
      if (running || ctl.isClosed) return;
      running = true;
      try {
        final peer = await probeOnce();
        if (peer != null && !ctl.isClosed && !(skip?.call(peer.address) ?? false)) {
          ctl.add(peer);
        }
      } catch (e, st) {
        _log('gateway probe failed', e, st);
      } finally {
        running = false;
      }
    }

    ctl = StreamController(
      onListen: () {
        unawaited(tick());
        timer = Timer.periodic(interval, (_) => unawaited(tick()));
      },
      onCancel: () => timer?.cancel(),
    );
    return ctl.stream;
  }
}
