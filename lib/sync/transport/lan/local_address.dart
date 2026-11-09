// Which addresses a connect link may make this phone dial (SPEC 8.6).
//
// Links come from QR codes and from settleup:// URLs that any web page or
// chat can open, so the engine only dials addresses on a local network:
// the hotspot or Wi-Fi the two phones share. A public address or a DNS
// name is refused before anything is sent, so a link cannot make the
// phone announce itself to a server or probe hosts on the internet.
import 'dart:io';

import 'tcp_framing.dart';

/// Whether [hostPort] ('ip:port', IPv6 bracketed) is an IP literal on a
/// local network: private IPv4 (10/8, 172.16/12, 192.168/16), IPv4
/// link-local (169.254/16), IPv6 unique-local (fc00::/7) or link-local
/// (fe80::/10), or loopback. Host names are never local here.
bool isLocalNetworkHostPort(String hostPort) {
  // Only the host matters here; a bare host gets the LAN port on dialing.
  final parsed = parseHostPort(hostPort, defaultPort: 1);
  if (parsed == null) return false;
  final address = InternetAddress.tryParse(parsed.host.split('%').first);
  if (address == null) return false;
  return isLocalNetworkAddress(address);
}

/// See [isLocalNetworkHostPort].
bool isLocalNetworkAddress(InternetAddress address) {
  if (address.isLoopback) return true;
  final b = address.rawAddress;
  if (address.type == InternetAddressType.IPv4) {
    return b[0] == 10 ||
        (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
        (b[0] == 192 && b[1] == 168) ||
        (b[0] == 169 && b[1] == 254);
  }
  if (address.type == InternetAddressType.IPv6) {
    // An IPv4-mapped address (::ffff:a.b.c.d) is judged as IPv4.
    final mapped = b.sublist(0, 10).every((x) => x == 0) &&
        b[10] == 0xff &&
        b[11] == 0xff;
    if (mapped) {
      return isLocalNetworkAddress(InternetAddress.fromRawAddress(
        b.sublist(12),
        type: InternetAddressType.IPv4,
      ));
    }
    return (b[0] & 0xfe) == 0xfc || (b[0] == 0xfe && (b[1] & 0xc0) == 0x80);
  }
  return false;
}
