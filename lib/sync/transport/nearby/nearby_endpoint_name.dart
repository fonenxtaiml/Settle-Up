// The Nearby Connections endpoint name (SPEC 8.7.2): the only thing a
// scanner learns about an advertiser before connecting.
//
//   "2|<advertId>|<windowTag>|<deviceName <= 24>|<up to 24 tokens>[+]"
//
// Tokens are fixed width (4 chars, SPEC 8.3), sorted and written back to
// back. A trailing '+' says the phone is in more groups than the name
// holds (the first 24 in priority order are kept, SPEC 8.3), so a scanner
// may offer Sync even when no token matches. The device name sits between
// the fixed fields, so a '|' inside it still parses (everything between
// the third and the last '|' is the name). Nearby carries the name as
// endpoint info bytes, which must stay small: the whole name is kept
// within [NearbyEndpointName.maxBytes] UTF-8 bytes by cutting the device
// name further. All 24 tokens and the '+' always fit.
import 'dart:convert';

import 'package:meta/meta.dart';

import '../../../core/models.dart';
import '../../crypto/tokens.dart';
import '../../name_cut.dart';
import '../transport.dart';

@immutable
final class NearbyEndpointName {
  const NearbyEndpointName({
    required this.advertId,
    required this.deviceName,
    required this.groupTokens,
    this.windowTag,
    this.moreGroups = false,
    this.version = currentVersion,
  });

  /// The first [maxTokens] of [AdvertiseInfo.groupTokens] (priority
  /// order), sorted; [moreGroups] when some were left out.
  factory NearbyEndpointName.of(AdvertiseInfo info) {
    final kept = DiscoveryTokens.forAdvert(info.groupTokens, maxTokens);
    return NearbyEndpointName(
      advertId: info.advertId ?? '',
      deviceName: info.deviceName,
      groupTokens: kept.tokens,
      moreGroups: kept.cut,
      windowTag: switch (info.tokenWindow) {
        final w? => w % DiscoveryTokens.windowTagModulus,
        null => null,
      },
    );
  }

  /// The layout this file writes. Older layouts are not read.
  static const int currentVersion = 2;

  /// Most tokens advertised.
  static const int maxTokens = 24;

  /// Device names are cut to this many Unicode code points (and to fit
  /// [maxBytes]), on a character boundary (DATA-R5-01).
  static const int maxNameRunes = 24;

  /// Upper bound for the encoded endpoint info (Nearby allows 131 bytes).
  static const int maxBytes = 131;

  final int version;

  /// '' when none is advertised.
  final String advertId;
  final String deviceName;
  final List<String> groupTokens;
  final int? windowTag;

  /// The phone is in more groups than [groupTokens] lists.
  final bool moreGroups;

  /// Marks a cut token list.
  static const String moreMark = '+';

  String encode() {
    final kept = DiscoveryTokens.forAdvert(groupTokens, maxTokens);
    final more = moreGroups || kept.cut ? moreMark : '';
    final tokens = '${kept.tokens.join()}$more';
    final id = DiscoveryTokens.isAdvertId(advertId) ? advertId : '';
    final tag = windowTag == null ? '' : DiscoveryTokens.windowTag(windowTag!);
    String layout(String name) => '$version|$id|$tag|$name|$tokens';
    final name = cutName(
      deviceName,
      (s) =>
          s.runes.length <= maxNameRunes &&
          utf8.encode(layout(s)).length <= maxBytes,
    );
    return layout(name);
  }

  /// Null when [name] is not a Settle Up endpoint name of this layout.
  static NearbyEndpointName? tryParse(String name) {
    final parts = name.split('|');
    if (parts.length < 5) return null;
    final version = int.tryParse(parts.first);
    if (version == null || version < currentVersion) return null;
    final last = parts.last;
    final more = last.endsWith(moreMark);
    final packed = more ? last.substring(0, last.length - 1) : last;
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
      moreGroups: more,
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
        moreGroups: moreGroups,
      );

  @override
  bool operator ==(Object other) =>
      other is NearbyEndpointName &&
      other.version == version &&
      other.advertId == advertId &&
      other.windowTag == windowTag &&
      other.deviceName == deviceName &&
      other.moreGroups == moreGroups &&
      _listEq(other.groupTokens, groupTokens);

  @override
  int get hashCode => Object.hash(
        version,
        advertId,
        windowTag,
        deviceName,
        moreGroups,
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
