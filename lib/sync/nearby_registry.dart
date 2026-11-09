// Merges DiscoveredPeer events from every transport into NearbyPeer rows
// (SPEC 8.7.1): by deviceIdPrefix when known, else by (kind, address).
// Shared groups come from the advertised tokens (SPEC 8.3). Routes unseen
// for [ttl] are dropped, and a peer with no routes left disappears.
import '../core/ids.dart';
import '../core/models.dart';
import 'sync_engine.dart';
import 'transport/transport.dart';

/// Preferred transport order for a sync: lan > nearby > ble.
const List<TransportKind> kTransportPreference = [
  TransportKind.lan,
  TransportKind.nearby,
  TransportKind.ble,
];

final class _Route {
  _Route(this.peer, this.seenAt);
  DiscoveredPeer peer;
  DateTime seenAt;
}

final class _Entry {
  _Entry(this.key);
  final String key;
  final Map<TransportKind, _Route> routes = {};
}

final class NearbyRegistry {
  NearbyRegistry({
    required this.localDeviceIdPrefix,
    this.ttl = const Duration(seconds: 15),
  });

  /// Our own prefix: we never list ourselves (LAN can see its own mDNS).
  final String localDeviceIdPrefix;
  final Duration ttl;

  final Map<String, _Entry> _entries = {};
  final Map<(TransportKind, String), String> _keyByRoute = {};
  Map<String, GroupId> _tokenIndex = const {};
  List<NearbyPeer> _peers = const [];
  String _signature = '';

  /// token -> group, for the windows currently accepted.
  set tokenIndex(Map<String, GroupId> index) {
    _tokenIndex = Map.unmodifiable(index);
    _rebuild();
  }

  List<NearbyPeer> get peers => _peers;

  static String keyFor(DiscoveredPeer p) =>
      p.deviceIdPrefix ?? '${p.kind.name}|${p.address}';

  /// Records a sighting. Returns true if the visible list changed.
  bool update(DiscoveredPeer peer, DateTime now) {
    if (peer.deviceIdPrefix != null &&
        peer.deviceIdPrefix == localDeviceIdPrefix) {
      return false;
    }
    final key = keyFor(peer);
    final routeKey = (peer.kind, peer.address);
    final previous = _keyByRoute[routeKey];
    if (previous != null && previous != key) {
      final old = _entries[previous];
      old?.routes.remove(peer.kind);
      if (old != null && old.routes.isEmpty) _entries.remove(previous);
    }
    _keyByRoute[routeKey] = key;
    final entry = _entries.putIfAbsent(key, () => _Entry(key));
    final existing = entry.routes[peer.kind];
    if (existing != null && existing.peer.address != peer.address) {
      _keyByRoute.remove((peer.kind, existing.peer.address));
    }
    entry.routes[peer.kind] = _Route(peer, now);
    return _rebuild();
  }

  /// Drops routes unseen for [ttl]. Returns true if the list changed.
  bool sweep(DateTime now) {
    var removed = false;
    for (final entry in _entries.values.toList()) {
      entry.routes.removeWhere((kind, r) {
        final stale = now.difference(r.seenAt) > ttl;
        if (stale) _keyByRoute.remove((kind, r.peer.address));
        removed |= stale;
        return stale;
      });
      if (entry.routes.isEmpty) _entries.remove(entry.key);
    }
    return removed && _rebuild();
  }

  void clear() {
    _entries.clear();
    _keyByRoute.clear();
    _rebuild();
  }

  /// Connect handles for [key], best transport first.
  List<DiscoveredPeer> routesFor(String key) {
    final entry = _entries[key];
    if (entry == null) return const [];
    return [
      for (final kind in kTransportPreference)
        if (entry.routes[kind] case final r?) r.peer,
    ];
  }

  bool _rebuild() {
    final out = <NearbyPeer>[];
    for (final entry in _entries.values) {
      final routes = [
        for (final kind in kTransportPreference)
          if (entry.routes[kind] case final r?) r.peer,
      ];
      if (routes.isEmpty) continue;
      final shared = <GroupId>{};
      for (final r in routes) {
        for (final t in r.groupTokens) {
          final g = _tokenIndex[t];
          if (g != null) shared.add(g);
        }
      }
      final name = routes
          .map((r) => r.name)
          .firstWhere((n) => n.isNotEmpty, orElse: () => '');
      out.add(NearbyPeer(
        key: entry.key,
        name: name,
        deviceIdPrefix: routes
            .map((r) => r.deviceIdPrefix)
            .firstWhere((p) => p != null, orElse: () => null),
        transports: {for (final r in routes) r.kind},
        sharedGroupIds: shared.toList()..sort(),
      ));
    }
    out.sort((a, b) {
      if (a.sharesGroups != b.sharesGroups) return a.sharesGroups ? -1 : 1;
      final c = a.name.compareTo(b.name);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
    final signature = out
        .map((p) => '${p.key}|${p.name}|${p.transports.map((t) => t.name)}|'
            '${p.sharedGroupIds}')
        .join('\n');
    if (signature == _signature) return false;
    _signature = signature;
    _peers = List.unmodifiable(out);
    return true;
  }
}
