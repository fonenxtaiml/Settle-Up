// Discovery tokens and blinded group ids (SPEC 8.3).
//
//   token(g, w) = hex(HMAC-SHA256(key_g, "settleup-adv-v1:" + w))[0..16]
//                 w = unixSeconds ~/ 600
//   blind(g, n) = b64url(HMAC-SHA256(key_g, "settleup-gid-v1" || n)[0..16])
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../core/ids.dart';

abstract final class DiscoveryTokens {
  /// Token rotation window.
  static const int windowSeconds = 600;

  static final Hmac _hmac = Hmac.sha256();

  /// The window index for [time].
  static int windowAt(DateTime time) =>
      time.millisecondsSinceEpoch ~/ 1000 ~/ windowSeconds;

  /// When the window after the one containing [time] starts.
  static DateTime nextWindowStart(DateTime time) =>
      DateTime.fromMillisecondsSinceEpoch(
        (windowAt(time) + 1) * windowSeconds * 1000,
        isUtc: true,
      );

  static Future<Uint8List> _mac(List<int> key, List<int> data) async {
    final mac = await _hmac.calculateMac(data, secretKey: SecretKeyData(key));
    return Uint8List.fromList(mac.bytes);
  }

  static String _hex(List<int> bytes) =>
      bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();

  /// The advertisement token of [groupKey] for [window] (16 hex chars).
  static Future<String> token(List<int> groupKey, int window) async {
    final mac = await _mac(groupKey, utf8.encode('settleup-adv-v1:$window'));
    return _hex(mac).substring(0, 16);
  }

  /// Tokens to advertise at [now]: one per group, sorted so the order does
  /// not reveal which group is which.
  static Future<List<String>> advertised(
    Map<GroupId, Uint8List> keys,
    DateTime now,
  ) async {
    final w = windowAt(now);
    final out = [for (final key in keys.values) await token(key, w)];
    out.sort();
    return out;
  }

  /// token -> group for the windows a scanner accepts at [now]: the current
  /// one and the previous one.
  static Future<Map<String, GroupId>> index(
    Map<GroupId, Uint8List> keys,
    DateTime now,
  ) async {
    final w = windowAt(now);
    final out = <String, GroupId>{};
    for (final e in keys.entries) {
      out[await token(e.value, w - 1)] = e.key;
      out[await token(e.value, w)] = e.key;
    }
    return out;
  }

  /// Blinded group id for HELLO, keyed by the HELLO sender's [nonce].
  static Future<Uint8List> blind(List<int> groupKey, List<int> nonce) async {
    final mac = await _mac(groupKey, [...utf8.encode('settleup-gid-v1'), ...nonce]);
    return Uint8List.sublistView(mac, 0, 16);
  }
}
