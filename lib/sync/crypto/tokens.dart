// Discovery tokens, advert ids and blinded group ids (SPEC 8.3).
//
//   token(g, w)   = b64url(HMAC-SHA256(key_g, "settleup-adv-v2:" + w)[0..3])
//                   4 chars, w = unixSeconds ~/ 600
//   windowTag(w)  = hex(w mod 4096), 3 chars, advertised next to the tokens
//   advertId(s,w) = hex(HMAC-SHA256(s, "settleup-aid-v1:" + w))[0..8]
//                   s = a random per-launch secret that never leaves the phone
//   blind(g, n)   = b64url(HMAC-SHA256(key_g, "settleup-gid-v1" || n)[0..16])
//
// Tokens are short so a phone in many groups fits many of them in an
// advert. A false match only labels a phone "shares Goa trip" by mistake;
// the HELLO (blind) is what decides whether a session starts.
//
// An advert holds a bounded number of tokens (Nearby 24, BLE 96, LAN 240).
// [DiscoveryTokens.advertised] lists them by priority (groups synced
// recently, then the newest groups), so a transport that has to cut the
// list keeps the same groups in every window; it sorts what it keeps, so
// the order reveals nothing, and says that it cut the list, so a scanner
// may still offer Sync and let the HELLO decide (QA SYNC-R2-01).
//
// The advertiser says which window its tokens are for, so a scanner whose
// clock is minutes, hours or a day off still matches them
// ([maxSkewWindows]). The advert id replaces a device id prefix: it
// changes every window and cannot be linked to the device id or to the
// previous window's id.
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../../core/ids.dart';

abstract final class DiscoveryTokens {
  /// Token rotation window.
  static const int windowSeconds = 600;

  /// Characters in one token (3 MAC bytes, base64url).
  static const int tokenLength = 4;

  /// A window tag is the window index modulo this.
  static const int windowTagModulus = 4096;

  /// Characters in a window tag.
  static const int windowTagLength = 3;

  /// Characters in an advert id.
  static const int advertIdLength = 8;

  /// Scanners accept tokens for windows at most this far from their own
  /// (2 days, both ways): realistic clock skew, but old adverts cannot be
  /// replayed for long.
  static const int maxSkewWindows = 288;

  static final Hmac _hmac = Hmac.sha256();
  static final RegExp _tokenPattern = RegExp(r'^[A-Za-z0-9_-]{4}$');
  static final RegExp _tagPattern = RegExp(r'^[0-9a-f]{3}$');
  static final RegExp _advertIdPattern = RegExp(r'^[0-9a-f]{8}$');

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

  /// Whether [t] has the shape of a token.
  static bool isToken(String t) => _tokenPattern.hasMatch(t);

  /// Whether [id] has the shape of an advert id.
  static bool isAdvertId(String id) => _advertIdPattern.hasMatch(id);

  /// The advertisement token of [groupKey] for [window].
  static Future<String> token(List<int> groupKey, int window) async {
    final mac = await _mac(groupKey, utf8.encode('settleup-adv-v2:$window'));
    return base64Url.encode(mac.sublist(0, 3));
  }

  /// The tag advertised with tokens for [window].
  static String windowTag(int window) =>
      (window % windowTagModulus).toRadixString(16).padLeft(windowTagLength, '0');

  /// Parses an advertised window tag, or null.
  static int? parseWindowTag(String? tag) {
    if (tag == null || !_tagPattern.hasMatch(tag)) return null;
    return int.parse(tag, radix: 16);
  }

  /// The window an advertiser meant by [tag], seen from [localWindow]: the
  /// one with that tag nearest to ours. Null when it is more than
  /// [maxSkewWindows] away.
  static int? resolveWindowTag(int tag, int localWindow) {
    var delta = (tag - localWindow) % windowTagModulus;
    if (delta >= windowTagModulus ~/ 2) delta -= windowTagModulus;
    if (delta.abs() > maxSkewWindows) return null;
    return localWindow + delta;
  }

  /// A fresh secret for [advertId].
  static Uint8List newAdvertSecret() {
    final r = Random.secure();
    return Uint8List.fromList(List.generate(32, (_) => r.nextInt(256)));
  }

  /// This phone's advert id for [window] under its [secret].
  static Future<String> advertId(List<int> secret, int window) async {
    final mac = await _mac(secret, utf8.encode('settleup-aid-v1:$window'));
    return _hex(mac).substring(0, advertIdLength);
  }

  /// Tokens to advertise at [now]: one per group, most important first:
  /// the groups in [priority] in that order (e.g. synced most recently),
  /// then the rest newest first (ids are UUIDv7, so by creation time).
  /// The order is stable across windows. Transports keep a prefix and must
  /// sort it ([forAdvert]) so the order does not reveal which group is
  /// which.
  static Future<List<String>> advertised(
    Map<GroupId, Uint8List> keys,
    DateTime now, {
    Iterable<GroupId> priority = const [],
  }) async {
    final w = windowAt(now);
    final order = <GroupId>[
      for (final g in priority)
        if (keys.containsKey(g)) g,
    ];
    final first = order.toSet();
    order.addAll(
      keys.keys.where((g) => !first.contains(g)).toList()
        ..sort((a, b) => b.compareTo(a)),
    );
    return [for (final g in order.toSet()) await token(keys[g]!, w)];
  }

  /// What an advert carries of [tokens] (in [advertised] order) when it
  /// holds at most [max]: the first valid ones, sorted, and whether some
  /// were left out.
  static ({List<String> tokens, bool cut}) forAdvert(
    Iterable<String> tokens,
    int max,
  ) {
    final valid = [
      for (final t in tokens)
        if (isToken(t)) t,
    ];
    final kept = valid.take(max).toList()..sort();
    return (tokens: kept, cut: valid.length > kept.length);
  }

  /// token -> group for the windows a scanner accepts at [now] from an
  /// advertiser that does not say its window: the current one and the
  /// previous one.
  static Future<Map<String, GroupId>> index(
    Map<GroupId, Uint8List> keys,
    DateTime now,
  ) async {
    final w = windowAt(now);
    return {
      ...await indexForWindow(keys, w - 1),
      ...await indexForWindow(keys, w),
    };
  }

  /// token -> group for exactly [window].
  static Future<Map<String, GroupId>> indexForWindow(
    Map<GroupId, Uint8List> keys,
    int window,
  ) async =>
      {
        for (final e in keys.entries) await token(e.value, window): e.key,
      };

  /// Blinded group id for HELLO, keyed by the HELLO sender's [nonce].
  static Future<Uint8List> blind(List<int> groupKey, List<int> nonce) async {
    final mac = await _mac(groupKey, [...utf8.encode('settleup-gid-v1'), ...nonce]);
    return Uint8List.sublistView(mac, 0, 16);
  }
}
