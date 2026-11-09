// The Nearby Connections endpoint name (SPEC 8.7.2): the only thing a
// scanner learns about an advertiser before connecting.
//
//   "1|<deviceId[0..8]>|<deviceName <= 24>|<up to 4 tokens comma-joined>"
//
// The device name sits between the fixed fields, so a '|' inside it still
// parses (everything between the second and the last '|' is the name).
// Nearby carries the name as endpoint info bytes, which must stay small:
// the whole name is kept within [NearbyEndpointName.maxBytes] UTF-8 bytes
// by cutting the device name further.
import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../core/models.dart';
import '../transport.dart';

final RegExp _token = RegExp(r'^[0-9a-f]{16}$');

@immutable
final class NearbyEndpointName {
  const NearbyEndpointName({
    required this.deviceIdPrefix,
    required this.deviceName,
    required this.groupTokens,
    this.version = 1,
  });

  factory NearbyEndpointName.of(AdvertiseInfo info) => NearbyEndpointName(
        deviceIdPrefix: info.deviceId.length > 8
            ? info.deviceId.substring(0, 8)
            : info.deviceId,
        deviceName: info.deviceName,
        groupTokens: info.groupTokens,
      );

  /// Most tokens that fit next to the name.
  static const int maxTokens = 4;

  /// Device names are cut to this many Unicode code points.
  static const int maxNameRunes = 24;

  /// Upper bound for the encoded endpoint info (Nearby allows 131 bytes).
  static const int maxBytes = 131;

  final int version;
  final String deviceIdPrefix;
  final String deviceName;
  final List<String> groupTokens;

  String encode() {
    final tokens = [
      for (final t in groupTokens)
        if (_token.hasMatch(t)) t,
    ].take(maxTokens).join(',');
    final prefix = deviceIdPrefix.replaceAll('|', '');
    var runes = deviceName.runes.take(maxNameRunes).toList();
    while (true) {
      final s = '$version|$prefix|${String.fromCharCodes(runes)}|$tokens';
      if (runes.isEmpty || utf8.encode(s).length <= maxBytes) return s;
      runes = runes.sublist(0, runes.length - 1);
    }
  }

  /// Null when [name] is not a Settle Up endpoint name.
  static NearbyEndpointName? tryParse(String name) {
    final parts = name.split('|');
    if (parts.length < 4) return null;
    final version = int.tryParse(parts.first);
    if (version == null || version < 1) return null;
    final tokens = parts.last.isEmpty
        ? const <String>[]
        : [
            for (final t in parts.last.split(','))
              if (_token.hasMatch(t)) t,
          ].take(maxTokens).toList();
    return NearbyEndpointName(
      version: version,
      deviceIdPrefix: parts[1],
      deviceName: parts.sublist(2, parts.length - 1).join('|'),
      groupTokens: tokens,
    );
  }

  /// What discovery reports for the endpoint [endpointId].
  DiscoveredPeer toPeer(String endpointId) => DiscoveredPeer(
        kind: TransportKind.nearby,
        address: endpointId,
        name: deviceName,
        deviceIdPrefix: deviceIdPrefix.isEmpty ? null : deviceIdPrefix,
        groupTokens: groupTokens.toSet(),
      );

  @override
  bool operator ==(Object other) =>
      other is NearbyEndpointName &&
      other.version == version &&
      other.deviceIdPrefix == deviceIdPrefix &&
      other.deviceName == deviceName &&
      _listEq(other.groupTokens, groupTokens);

  @override
  int get hashCode =>
      Object.hash(version, deviceIdPrefix, deviceName, Object.hashAll(groupTokens));

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
