// The INFO characteristic value (SPEC 8.7.2): who this peripheral is.
//
//   {"v":2,"d":"<advertId>","w":"<windowTag>","n":"<deviceName>",
//    "t":[tokens <= 48]}
//
// It must fit one ATT attribute (512 bytes), so long names are cut and,
// if it still does not fit, the last tokens are left out. Parsing is
// lenient: unknown keys are ignored and bad tokens are dropped, because a
// newer app version may add fields.
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../../core/models.dart';
import '../../crypto/tokens.dart';
import '../transport.dart';
import 'ble_chunker.dart';

@immutable
final class BleInfo {
  const BleInfo({
    required this.advertId,
    required this.deviceName,
    required this.groupTokens,
    this.windowTag,
    this.version = currentVersion,
  });

  /// Built from what the engine advertises.
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
  static const int maxTokens = 48;

  /// Device names longer than this (in Unicode code points) are cut.
  static const int maxNameRunes = 40;

  final int version;

  /// '' when none is advertised.
  final String advertId;
  final String deviceName;
  final List<String> groupTokens;
  final int? windowTag;

  /// UTF-8 JSON, at most [kBleMaxAttPayload] bytes.
  Uint8List encode() {
    final name = String.fromCharCodes(deviceName.runes.take(maxNameRunes));
    final tokens = [
      for (final t in groupTokens)
        if (DiscoveryTokens.isToken(t)) t,
    ].take(maxTokens).toList();
    while (true) {
      final bytes = utf8.encode(jsonEncode({
        'v': version,
        'd': DiscoveryTokens.isAdvertId(advertId) ? advertId : '',
        if (windowTag != null) 'w': DiscoveryTokens.windowTag(windowTag!),
        'n': name,
        't': tokens,
      }));
      if (bytes.length <= kBleMaxAttPayload || tokens.isEmpty) {
        return Uint8List.fromList(bytes);
      }
      tokens.removeLast();
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
    return BleInfo(
      version: v,
      advertId: d is String && DiscoveryTokens.isAdvertId(d) ? d : '',
      windowTag: DiscoveryTokens.parseWindowTag(w is String ? w : null),
      deviceName: n is String ? n : '',
      groupTokens: [
        if (t is List<Object?>)
          for (final x in t)
            if (x is String && DiscoveryTokens.isToken(x)) x,
      ].take(maxTokens).toList(),
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
      );
}
