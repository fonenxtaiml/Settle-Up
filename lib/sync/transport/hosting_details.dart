// Optional extra a transport can implement so host mode can show where it is
// reachable (HostInfo.addresses / wifiName and the connect link, SPEC 8.6).
// The frozen SyncTransport contract has no such call, so DefaultSyncEngine
// checks `transport is HostingDetails`. LanTransport is expected to
// implement it (actual server port, tethering interfaces first).

/// Implemented by transports that can be reached at an address the user can
/// type or scan (LAN, the in-memory test transport).
abstract interface class HostingDetails {
  /// 'ip:port' (IPv6 bracketed) on every usable interface, best first.
  /// Only meaningful while advertising.
  Future<List<String>> hostAddresses();

  /// The Wi-Fi network name, if known.
  Future<String?> wifiName();

  /// Whether a connect link (or an invite's `h`) naming [address] may be
  /// dialed. LAN allows only local-network IP addresses
  /// (`isLocalNetworkHostPort`), so a link from a web page cannot make the
  /// phone reach the internet.
  bool isLinkHost(String address);
}
