// The INFO characteristic value (SPEC 8.7.2): who this peripheral is.
//
//   {"v":2,"d":"<advertId>","w":"<windowTag>","n":"<deviceName>",
//    "t":"<tokens <= 96, back to back>","m":1}
//
// Tokens are fixed width (4 chars, SPEC 8.3), sorted and packed into one
// string. "m":1 (only when true) says the phone is in more groups than INFO
// lists: the first ones in priority order are kept (SPEC 8.3), so a
// scanner may offer Sync even when no token matches. It must fit one ATT
// attribute (512 bytes), so long names are cut and, if it still does not
// fit, the least important tokens are left out (at least 57 always fit).
// Parsing is lenient: unknown keys are ignored, bad tokens are dropped and
// "t" may also be a list of tokens, because other app versions may differ.
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../../core/models.dart';
import '../../crypto/tokens.dart';
import '../../name_cut.dart';
import '../transport.dart';
import 'ble_chunker.dart';

@immutable
final class BleInfo {
  const BleInfo({
    required this.advertId,
    required this.deviceName,
    required this.groupTokens,
    this.windowTag,
    this.moreGroups = false,
    this.version = currentVersion,
  });

  /// Built from what the engine advertises ([AdvertiseInfo.groupTokens] in
  /// priority order: [encode] keeps the first ones that fit).
  factory BleInfo.of(AdvertiseInfo info) => BleInfo(
        advertId: info.advertId ?? '',
        deviceName: info.deviceName,
        groupTokens: info.groupTokens,
        windowTag: switch (info.tokenWindow) {
          final w? => w % DiscoveryTokens.windowTagModulus,
          null => null,
        },
      );

  /// The format this file writes. Older INFO values are not read.
  static const int currentVersion = 2;

  /// Most tokens INFO carries.
  static const int maxTokens = 96;

  /// Device names longer than this (in Unicode code points) are cut, on a
  /// character boundary (DATA-R5-01).
  static const int maxNameRunes = 40;

  final int version;

  /// '' when none is advertised.
  final String advertId;
  final String deviceName;
  /// For a parsed value, in advert (sorted) order; for one being built,
  /// most important first.
  final List<String> groupTokens;
  final int? windowTag;

  /// The phone is in more groups than [groupTokens] lists.
  final bool moreGroups;

  /// UTF-8 JSON, at most [kBleMaxAttPayload] bytes.
  Uint8List encode() {
    final name = cutName(deviceName, (s) => s.runes.length <= maxNameRunes);
    var max = maxTokens;
    while (true) {
      final kept = DiscoveryTokens.forAdvert(groupTokens, max);
      final bytes = utf8.encode(jsonEncode({
        'v': version,
        'd': DiscoveryTokens.isAdvertId(advertId) ? advertId : '',
        if (windowTag != null) 'w': DiscoveryTokens.windowTag(windowTag!),
        'n': name,
        't': kept.tokens.join(),
        if (moreGroups || kept.cut) 'm': 1,
      }));
      if (bytes.length <= kBleMaxAttPayload || kept.tokens.isEmpty) {
        return Uint8List.fromList(bytes);
      }
      max = kept.tokens.length - 1;
    }
  }

  /// Null if [bytes] is not an INFO value.
  static BleInfo? tryParse(Uint8List bytes) {
    final Object? json;
    try {
      json = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
    if (json is! Map<String, Object?>) return null;
    final v = json['v'];
    if (v is! int || v < currentVersion) return null;
    final d = json['d'];
    final w = json['w'];
    final n = json['n'];
    final t = json['t'];
    final tokens = switch (t) {
      final String packed => [
          for (var i = 0;
              i + DiscoveryTokens.tokenLength <= packed.length;
              i += DiscoveryTokens.tokenLength)
            packed.substring(i, i + DiscoveryTokens.tokenLength),
        ],
      final List<Object?> list => list,
      _ => const <Object?>[],
    };
    final valid = [
      for (final x in tokens)
        if (x is String && DiscoveryTokens.isToken(x)) x,
    ];
    return BleInfo(
      version: v,
      advertId: d is String && DiscoveryTokens.isAdvertId(d) ? d : '',
      windowTag: DiscoveryTokens.parseWindowTag(w is String ? w : null),
      deviceName: n is String ? n : '',
      groupTokens: valid.take(maxTokens).toList(),
      moreGroups: json['m'] == 1 || valid.length > maxTokens,
    );
  }

  /// What a scanner reports for the peripheral at [address].
  DiscoveredPeer toPeer(String address) => DiscoveredPeer(
        kind: TransportKind.ble,
        address: address,
        name: deviceName,
        advertId: advertId.isEmpty ? null : advertId,
        groupTokens: groupTokens.toSet(),
        windowTag: windowTag,
        moreGroups: moreGroups,
      );
}
