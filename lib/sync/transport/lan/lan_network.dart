// What the LAN transport asks of the network stack: our IPv4 interface
// addresses (for the connect QR and the "is this gateway me?" check), the
// Wi-Fi gateway (hotspot probe) and the Wi-Fi name (host screen).
import 'dart:developer' as developer;
import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';

void _log(String message, [Object? error, StackTrace? st]) => developer.log(
      message,
      name: 'settle_up.sync.lan',
      error: error,
      stackTrace: st,
    );

/// One IPv4 address of one network interface.
final class LanInterfaceAddress {
  const LanInterfaceAddress(this.interfaceName, this.address);

  final String interfaceName;
  final InternetAddress address;

  @override
  String toString() => '$interfaceName ${address.address}';
}

abstract interface class LanNetwork {
  /// Usable IPv4 addresses, best first (tethering interfaces first, SPEC
  /// 8.6), without loopback, link-local or cellular interfaces.
  Future<List<LanInterfaceAddress>> ipv4Addresses();

  /// The Wi-Fi gateway (the hotspot phone when we joined a hotspot), or
  /// null when unknown. Always read at runtime: Android hotspots move
  /// between subnets, and iOS Personal Hotspot is usually 172.20.10.1.
  Future<String?> gatewayIp();

  /// The Wi-Fi network name, or null when unknown (Android needs location
  /// permission for it on some API levels; we never ask just for that).
  Future<String?> wifiName();
}

/// Interface name prefixes that carry a hotspot or tether we host.
/// `ap*`, `swlan*`, `wlan1` (Android softAP), `bridge*` (iOS Personal
/// Hotspot is bridge100).
const List<String> _tetherPrefixes = ['ap', 'swlan', 'bridge'];

/// Interfaces a phone next to us can never reach: cellular, VPN, dummy.
const List<String> _skipPrefixes = [
  'rmnet',
  'v4-rmnet',
  'ccmni',
  'pdp_ip',
  'tun',
  'utun',
  'ppp',
  'dummy',
  'ipsec',
  'clat',
  'lo',
];

/// Sort rank: 0 = hosting a hotspot, 1 = Wi-Fi/Ethernet, 2 = anything
/// else. Null = never usable.
int? interfaceRank(String name) {
  final n = name.toLowerCase();
  for (final p in _skipPrefixes) {
    if (n.startsWith(p)) return null;
  }
  if (n == 'wlan1') return 0;
  for (final p in _tetherPrefixes) {
    if (n.startsWith(p)) return 0;
  }
  if (n.startsWith('wlan') ||
      n.startsWith('en') ||
      n.startsWith('eth') ||
      n.startsWith('wl')) {
    return 1;
  }
  return 2;
}

/// Filters and orders [all]: tethering first, then Wi-Fi/Ethernet, then
/// the rest; the input order is kept inside a rank. Drops loopback,
/// link-local (169.254/16), non-IPv4 and unreachable interfaces.
List<LanInterfaceAddress> orderAddresses(Iterable<LanInterfaceAddress> all) {
  final ranked = <(int, int, LanInterfaceAddress)>[];
  var i = 0;
  for (final a in all) {
    final index = i++;
    if (a.address.type != InternetAddressType.IPv4) continue;
    if (a.address.isLoopback || a.address.isLinkLocal) continue;
    final rank = interfaceRank(a.interfaceName);
    if (rank == null) continue;
    ranked.add((rank, index, a));
  }
  ranked.sort((x, y) {
    final c = x.$1.compareTo(y.$1);
    return c != 0 ? c : x.$2.compareTo(y.$2);
  });
  return [for (final r in ranked) r.$3];
}

/// Strips the quotes Android puts around SSIDs; maps placeholders to null.
String? cleanWifiName(String? raw) {
  if (raw == null) return null;
  var s = raw.trim();
  if (s.length >= 2 && s.startsWith('"') && s.endsWith('"')) {
    s = s.substring(1, s.length - 1);
  }
  if (s.isEmpty || s == '<unknown ssid>' || s == '0x') return null;
  return s;
}

/// [LanNetwork] backed by `dart:io` and `network_info_plus`.
final class SystemLanNetwork implements LanNetwork {
  SystemLanNetwork({this._info});

  NetworkInfo? _info;
  NetworkInfo get _networkInfo => _info ??= NetworkInfo();

  @override
  Future<List<LanInterfaceAddress>> ipv4Addresses() async {
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
    );
    return orderAddresses([
      for (final i in interfaces)
        for (final a in i.addresses) LanInterfaceAddress(i.name, a),
    ]);
  }

  @override
  Future<String?> gatewayIp() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return null;
    try {
      final gw = (await _networkInfo.getWifiGatewayIP())?.trim();
      if (gw == null || gw.isEmpty || gw == '0.0.0.0') return null;
      return gw;
    } catch (e, st) {
      _log('getWifiGatewayIP failed', e, st);
      return null;
    }
  }

  @override
  Future<String?> wifiName() async {
    if (!(Platform.isAndroid || Platform.isIOS)) return null;
    try {
      return cleanWifiName(await _networkInfo.getWifiName());
    } catch (e, st) {
      _log('getWifiName failed', e, st);
      return null;
    }
  }
}
