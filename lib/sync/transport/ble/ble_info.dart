// The INFO characteristic value (SPEC 8.7.2): who this peripheral is.
//
//   {"v":1,"d":"<deviceId[0..8]>","n":"<deviceName>","t":[tokens <= 16]}
//
// It must fit one ATT attribute (512 bytes), so long names are cut and,
// if it still does not fit, the last tokens are left out. Parsing is
// lenient: unknown keys are ignored and bad tokens are dropped, because a
// newer app version may add fields.
import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../../core/models.dart';
import '../transport.dart';
import 'ble_chunker.dart';

/// Advertised tokens are 16 lowercase hex characters (SPEC 8.3).
final RegExp _token = RegExp(r'^[0-9a-f]{16}$');

@immutable
final class BleInfo {
  const BleInfo({
    required this.deviceIdPrefix,
    required this.deviceName,
    required this.groupTokens,
    this.version = 1,
  });

  /// Built from what the engine advertises.
  factory BleInfo.of(AdvertiseInfo info) => BleInfo(
        deviceIdPrefix: info.deviceId.length > 8
            ? info.deviceId.substring(0, 8)
            : info.deviceId,
        deviceName: info.deviceName,
        groupTokens: info.groupTokens,
      );

  /// Most tokens INFO carries.
  static const int maxTokens = 16;

  /// Device names longer than this (in Unicode code points) are cut.
  static const int maxNameRunes = 40;

  final int version;
  final String deviceIdPrefix;
  final String deviceName;
  final List<String> groupTokens;

  /// UTF-8 JSON, at most [kBleMaxAttPayload] bytes.
  Uint8List encode() {
    final name = String.fromCharCodes(deviceName.runes.take(maxNameRunes));
    final tokens = [
      for (final t in groupTokens)
        if (_token.hasMatch(t)) t,
    ].take(maxTokens).toList();
    while (true) {
      final bytes = utf8.encode(jsonEncode({
        'v': version,
        'd': deviceIdPrefix,
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
    if (v is! int || v < 1) return null;
    final d = json['d'];
    final n = json['n'];
    final t = json['t'];
    return BleInfo(
      version: v,
      deviceIdPrefix: d is String ? d : '',
      deviceName: n is String ? n : '',
      groupTokens: [
        if (t is List<Object?>)
          for (final x in t)
            if (x is String && _token.hasMatch(x)) x,
      ].take(maxTokens).toList(),
    );
  }

  /// What a scanner reports for the peripheral at [address].
  DiscoveredPeer toPeer(String address) => DiscoveredPeer(
        kind: TransportKind.ble,
        address: address,
        name: deviceName,
        deviceIdPrefix: deviceIdPrefix.isEmpty ? null : deviceIdPrefix,
        groupTokens: groupTokens.toSet(),
      );
}
