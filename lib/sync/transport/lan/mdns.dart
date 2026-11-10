// mDNS / DNS-SD for the LAN transport (SPEC 8.7.2): service type
// `_settleup._tcp`, service name = device name (<= 40 units, 63 bytes), TXT
// `v=2`, `d=<advertId>`, `w=<windowTag>`, `t`, `t1`, `t2`, `t3` = up to 60
// sorted tokens each, back to back, and `m=1` when the phone is in more
// groups than that (the first 240 in priority order are kept, SPEC 8.3).
//
// A DNS TXT string holds at most 255 bytes ("t1=" + 240 = 243), and
// Android keeps a whole TXT record under 1300 bytes (about 1000 here).
// Readers also accept tokens separated by commas.
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:bonsoir/bonsoir.dart';

import '../../../core/models.dart';
import '../../crypto/tokens.dart';
import '../../name_cut.dart';
import '../transport.dart';
import 'tcp_framing.dart';

/// DNS-SD service type.
const String kLanServiceType = '_settleup._tcp';

/// Longest advertised service name, in UTF-16 units.
const int kLanServiceNameMax = 40;

/// Longest advertised service name in UTF-8 bytes: one DNS label (RFC 6763
/// 4.1.1). Android would cut a longer one itself, by bytes.
const int kLanServiceNameMaxBytes = 63;

/// Tokens in one TXT attribute.
const int kLanTokensPerKey = 60;

/// TXT keys that carry tokens, in order.
const List<String> kLanTokenKeys = ['t', 't1', 't2', 't3'];

/// Most tokens advertised (SPEC 5.12 AdvertiseInfo).
const int kLanMaxTokens = kLanTokensPerKey * 4;

/// The TXT `v` this file writes. Older services are not read.
const int kLanTxtVersion = 2;

void _log(String message, [Object? error, StackTrace? st]) => developer.log(
      message,
      name: 'settle_up.sync.lan.mdns',
      error: error,
      stackTrace: st,
    );

/// What one phone announces over mDNS.
final class MdnsAdvert {
  const MdnsAdvert({
    required this.name,
    required this.port,
    required this.attributes,
  });

  /// Builds the advert for [info] on [port].
  factory MdnsAdvert.of(AdvertiseInfo info, int port) => MdnsAdvert(
        name: serviceNameFor(info.deviceName),
        port: port,
        attributes: txtFor(info),
      );

  final String name;
  final int port;
  final Map<String, String> attributes;

  bool sameAs(MdnsAdvert other) =>
      other.name == name &&
      other.port == port &&
      other.attributes.length == attributes.length &&
      attributes.entries.every((e) => other.attributes[e.key] == e.value);

  /// Device name cut to [kLanServiceNameMax] UTF-16 units and
  /// [kLanServiceNameMaxBytes] UTF-8 bytes (a DNS label) on a character
  /// boundary (DATA-R5-01).
  static String serviceNameFor(String deviceName) {
    final trimmed = deviceName.trim();
    final name = trimmed.isEmpty ? 'Settle Up' : trimmed;
    return cutName(
      name,
      (s) =>
          s.length <= kLanServiceNameMax &&
          utf8.encode(s).length <= kLanServiceNameMaxBytes,
    );
  }

  /// TXT attributes for [info]: the first [kLanMaxTokens] of its tokens
  /// (priority order), sorted.
  static Map<String, String> txtFor(AdvertiseInfo info) {
    final kept = DiscoveryTokens.forAdvert(info.groupTokens, kLanMaxTokens);
    final tokens = kept.tokens;
    final id = info.advertId;
    final window = info.tokenWindow;
    return {
      'v': '$kLanTxtVersion',
      if (id != null && DiscoveryTokens.isAdvertId(id)) 'd': id,
      if (window != null) 'w': DiscoveryTokens.windowTag(window),
      't': tokens.take(kLanTokensPerKey).join(),
      for (var k = 1; k < kLanTokenKeys.length; k++)
        if (tokens.length > k * kLanTokensPerKey)
          kLanTokenKeys[k]: tokens
              .skip(k * kLanTokensPerKey)
              .take(kLanTokensPerKey)
              .join(),
      if (kept.cut) 'm': '1',
    };
  }

  /// Tokens in TXT [value]: packed back to back, or separated by commas.
  static Iterable<String> tokensIn(String value) sync* {
    for (final part in value.split(',')) {
      if (part.length % DiscoveryTokens.tokenLength != 0) continue;
      for (var i = 0; i < part.length; i += DiscoveryTokens.tokenLength) {
        final t = part.substring(i, i + DiscoveryTokens.tokenLength);
        if (DiscoveryTokens.isToken(t)) yield t;
      }
    }
  }
}

/// Lower is better: IPv4, then routable IPv6, then link-local (an IPv6 one
/// needs a scope we do not carry), then loopback (on a phone, only ever
/// ourselves).
int _addressRank(InternetAddress a) {
  if (a.isLoopback) return 3;
  if (a.isLinkLocal) return 2;
  return a.type == InternetAddressType.IPv4 ? 0 : 1;
}

/// A resolved service seen on the network.
final class MdnsSighting {
  const MdnsSighting({
    required this.name,
    required this.addresses,
    required this.port,
    required this.attributes,
  });

  final String name;
  final List<String> addresses;
  final int port;
  final Map<String, String> attributes;

  /// The peer this sighting describes, or null when it is not a Settle Up
  /// service of this version (or later) or has no usable address. Prefers
  /// IPv4; IPv6 is bracketed.
  DiscoveredPeer? toPeer() {
    final v = int.tryParse(attributes['v'] ?? '');
    if (v == null || v < kLanTxtVersion) return null;
    if (port < 1 || port > 65535) return null;
    InternetAddress? best;
    var bestRank = 99;
    for (final a in addresses) {
      final parsed = InternetAddress.tryParse(a.split('%').first);
      if (parsed == null) continue;
      final rank = _addressRank(parsed);
      if (rank < bestRank) {
        best = parsed;
        bestRank = rank;
      }
    }
    if (best == null) return null;
    final d = attributes['d'];
    final tokens = <String>{
      for (final key in kLanTokenKeys)
        ...MdnsAdvert.tokensIn(attributes[key] ?? ''),
    };
    return DiscoveredPeer(
      kind: TransportKind.lan,
      address: formatHostPort(best, port),
      name: name,
      advertId: d != null && DiscoveryTokens.isAdvertId(d) ? d : null,
      groupTokens: tokens.take(kLanMaxTokens).toSet(),
      windowTag: DiscoveryTokens.parseWindowTag(attributes['w']),
      moreGroups: attributes['m'] == '1' || tokens.length > kLanMaxTokens,
    );
  }
}

/// The mDNS operations LanTransport needs (Bonsoir on device, a fake in
/// tests, where platform channels are unavailable).
abstract interface class MdnsBackend {
  /// Announces [advert], replacing any previous announcement.
  Future<void> advertise(MdnsAdvert advert);

  Future<void> stopAdvertising();

  /// Browses while listened to. Emits a sighting each time a service
  /// resolves or changes, and `(name, null)` when it is lost.
  Stream<(String, MdnsSighting?)> browse();
}

/// [MdnsBackend] on top of `bonsoir`.
final class BonsoirMdns implements MdnsBackend {
  BonsoirMdns();

  BonsoirBroadcast? _broadcast;
  MdnsAdvert? _advert;

  /// Serializes advertise/stop so a quick re-advertise never interleaves.
  Future<void> _queue = Future.value();

  @override
  Future<void> advertise(MdnsAdvert advert) => _serial(() async {
        final current = _advert;
        if (current != null && current.sameAs(advert) && _broadcast != null) {
          return;
        }
        await _stop();
        final broadcast = BonsoirBroadcast(
          printLogs: false,
          service: BonsoirService(
            name: advert.name,
            type: kLanServiceType,
            port: advert.port,
            attributes: advert.attributes,
          ),
        );
        await broadcast.initialize();
        await broadcast.start();
        _broadcast = broadcast;
        _advert = advert;
      });

  @override
  Future<void> stopAdvertising() => _serial(_stop);

  Future<void> _stop() async {
    final b = _broadcast;
    _broadcast = null;
    _advert = null;
    if (b == null) return;
    try {
      await b.stop();
    } catch (e, st) {
      _log('stop broadcast failed', e, st);
    }
  }

  Future<void> _serial(Future<void> Function() action) {
    final next = _queue.then((_) => action());
    _queue = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  @override
  Stream<(String, MdnsSighting?)> browse() {
    late StreamController<(String, MdnsSighting?)> ctl;
    BonsoirDiscovery? discovery;
    StreamSubscription<BonsoirDiscoveryEvent>? sub;
    var cancelled = false;

    Future<void> start() async {
      try {
        final d = BonsoirDiscovery(printLogs: false, type: kLanServiceType);
        await d.initialize();
        if (cancelled) {
          await d.stop();
          return;
        }
        discovery = d;
        sub = d.eventStream?.listen(
          (event) {
            switch (event) {
              case BonsoirDiscoveryServiceFoundEvent(:final service):
                unawaited(service.resolve(d.serviceResolver).then((_) {},
                    onError: (Object e, StackTrace st) =>
                        _log('resolve ${service.name} failed', e, st)));
              case BonsoirDiscoveryServiceResolvedEvent(:final service):
              case BonsoirDiscoveryServiceUpdatedEvent(:final service):
                if (!ctl.isClosed) ctl.add((service.name, _sighting(service)));
              case BonsoirDiscoveryServiceLostEvent(:final service):
                if (!ctl.isClosed) ctl.add((service.name, null));
              default:
                break;
            }
          },
          onError: (Object e, StackTrace st) {
            if (!ctl.isClosed) ctl.addError(e, st);
          },
        );
        await d.start();
      } catch (e, st) {
        _log('mDNS browse failed to start', e, st);
        if (!ctl.isClosed) ctl.addError(e, st);
      }
    }

    ctl = StreamController(
      onListen: () => unawaited(start()),
      onCancel: () async {
        cancelled = true;
        await sub?.cancel();
        try {
          await discovery?.stop();
        } catch (e, st) {
          _log('stop discovery failed', e, st);
        }
      },
    );
    return ctl.stream;
  }

  static MdnsSighting _sighting(BonsoirService s) => MdnsSighting(
        name: s.name,
        addresses: s.hostAddresses,
        port: s.port,
        attributes: s.attributes,
      );
}
