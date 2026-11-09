// The Nearby Connections endpoint name (SPEC 8.7.2): the only thing a
// scanner learns about an advertiser before connecting.
//
//   "2|<advertId>|<windowTag>|<deviceName <= 24>|<up to 24 tokens>"
//
// Tokens are fixed width (4 chars, SPEC 8.3) and written back to back. The
// device name sits between the fixed fields, so a '|' inside it still
// parses (everything between the third and the last '|' is the name).
// Nearby carries the name as endpoint info bytes, which must stay small:
// the whole name is kept within [NearbyEndpointName.maxBytes] UTF-8 bytes
// by cutting the device name further. All 24 tokens always fit.
import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../core/models.dart';
import '../../crypto/tokens.dart';
import '../transport.dart';

@immutable
final class NearbyEndpointName {
  const NearbyEndpointName({
    required this.advertId,
    required this.deviceName,
    required this.groupTokens,
    this.windowTag,
    this.version = currentVersion,
  });

  factory NearbyEndpointName.of(AdvertiseInfo info) => NearbyEndpointName(
        advertId: info.advertId ?? '',
        deviceName: info.deviceName,
        groupTokens: info.groupTokens,
        windowTag: switch (info.tokenWindow) {
          final w? => w % DiscoveryTokens.windowTagModulus,
          null => null,
        },
      );

  /// The layout this file writes. Older layouts are not read.
  static const int currentVersion = 2;

  /// Most tokens advertised.
  static const int maxTokens = 24;

  /// Device names are cut to this many Unicode code points.
  static const int maxNameRunes = 24;

  /// Upper bound for the encoded endpoint info (Nearby allows 131 bytes).
  static const int maxBytes = 131;

  final int version;

  /// '' when none is advertised.
  final String advertId;
  final String deviceName;
  final List<String> groupTokens;
  final int? windowTag;

  String encode() {
    final tokens = [
      for (final t in groupTokens)
        if (DiscoveryTokens.isToken(t)) t,
    ].take(maxTokens).join();
    final id = DiscoveryTokens.isAdvertId(advertId) ? advertId : '';
    final tag = windowTag == null ? '' : DiscoveryTokens.windowTag(windowTag!);
    var runes = deviceName.runes.take(maxNameRunes).toList();
    while (true) {
      final s = '$version|$id|$tag|${String.fromCharCodes(runes)}|$tokens';
      if (runes.isEmpty || utf8.encode(s).length <= maxBytes) return s;
      runes = runes.sublist(0, runes.length - 1);
    }
  }

  /// Null when [name] is not a Settle Up endpoint name of this layout.
  static NearbyEndpointName? tryParse(String name) {
    final parts = name.split('|');
    if (parts.length < 5) return null;
    final version = int.tryParse(parts.first);
    if (version == null || version < currentVersion) return null;
    final packed = parts.last;
    final tokens = <String>[];
    for (var i = 0;
        i + DiscoveryTokens.tokenLength <= packed.length &&
            tokens.length < maxTokens;
        i += DiscoveryTokens.tokenLength) {
      final t = packed.substring(i, i + DiscoveryTokens.tokenLength);
      if (DiscoveryTokens.isToken(t)) tokens.add(t);
    }
    return NearbyEndpointName(
      version: version,
      advertId: DiscoveryTokens.isAdvertId(parts[1]) ? parts[1] : '',
      windowTag: DiscoveryTokens.parseWindowTag(parts[2]),
      deviceName: parts.sublist(3, parts.length - 1).join('|'),
      groupTokens: tokens,
    );
  }

  /// What discovery reports for the endpoint [endpointId].
  DiscoveredPeer toPeer(String endpointId) => DiscoveredPeer(
        kind: TransportKind.nearby,
        address: endpointId,
        name: deviceName,
        advertId: advertId.isEmpty ? null : advertId,
        groupTokens: groupTokens.toSet(),
        windowTag: windowTag,
      );

  @override
  bool operator ==(Object other) =>
      other is NearbyEndpointName &&
      other.version == version &&
      other.advertId == advertId &&
      other.windowTag == windowTag &&
      other.deviceName == deviceName &&
      _listEq(other.groupTokens, groupTokens);

  @override
  int get hashCode => Object.hash(
        version,
        advertId,
        windowTag,
        deviceName,
        Object.hashAll(groupTokens),
      );

  @override
  String toString() => 'NearbyEndpointName(${encode()})';
}

bool _listEq(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
