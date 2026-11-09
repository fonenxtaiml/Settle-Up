// Merges DiscoveredPeer events from every transport into NearbyPeer rows
// (SPEC 8.7.1): by advert id when known, else by (kind, address).
// Shared groups come from the advertised tokens (SPEC 8.3). Routes unseen
// for [ttl] are dropped, and a peer with no routes left disappears.
//
// Advert ids rotate every token window. When a route that belonged to a
// row shows up with a new id, the new id becomes an alias of that row, so
// the row keeps its key and its other transports.
import '../core/ids.dart';
import '../core/models.dart';
import 'crypto/tokens.dart';
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
  _Entry(this.key, {required this.byAdvertId});
  final String key;

  /// Keyed by an advert id (else by a route, for peers that advertise none).
  final bool byAdvertId;
  final Map<TransportKind, _Route> routes = {};
}

final class NearbyRegistry {
  NearbyRegistry({
    Set<String> selfAdvertIds = const {},
    this.ttl = const Duration(seconds: 15),
  }) : _selfAdvertIds = Set.of(selfAdvertIds);

  final Duration ttl;

  Set<String> _selfAdvertIds;
  final Map<String, _Entry> _entries = {};
  final Map<(TransportKind, String), String> _keyByRoute = {};

  /// advert id -> entry key.
  final Map<String, String> _aliases = {};
  Map<String, GroupId> _tokenIndex = const {};
  final Map<int, Map<String, GroupId>> _windowIndexes = {};
  int? _currentWindow;
  List<NearbyPeer> _peers = const [];
  String _signature = '';

  /// Our own advert ids: we never list ourselves (LAN can see its own
  /// mDNS). Advert ids are random per phone, so unlike a device id prefix
  /// they never match another phone.
  set selfAdvertIds(Set<String> ids) {
    _selfAdvertIds = Set.of(ids);
    final self = {
      for (final e in _aliases.entries)
        if (_selfAdvertIds.contains(e.key)) e.value,
    };
    for (final key in self) {
      _remove(key);
    }
    if (self.isNotEmpty) _rebuild();
  }

  /// token -> group for adverts that do not say their window: the windows
  /// currently accepted (SPEC 8.3).
  set tokenIndex(Map<String, GroupId> index) {
    _tokenIndex = Map.unmodifiable(index);
    _rebuild();
  }

  /// The scanner's own token window, which advertised window tags are
  /// resolved against.
  set currentWindow(int window) {
    if (_currentWindow == window) return;
    _currentWindow = window;
    _windowIndexes.removeWhere(
      (w, _) => (w - window).abs() > DiscoveryTokens.maxSkewWindows,
    );
    _rebuild();
  }

  /// Sets token -> group for exactly [window] (adverts that say it).
  /// Returns true if the visible list changed.
  bool setWindowIndex(int window, Map<String, GroupId> index) {
    _windowIndexes[window] = Map.unmodifiable(index);
    return _rebuild();
  }

  bool hasWindowIndex(int window) => _windowIndexes.containsKey(window);

  /// Forgets every per-window index (the group keys changed).
  void clearWindowIndexes() {
    _windowIndexes.clear();
    _rebuild();
  }

  /// The token window [peer] advertised, resolved against ours. Null when
  /// it says none, or it is too far from our clock to accept.
  int? windowOf(DiscoveredPeer peer) {
    final tag = peer.windowTag;
    final local = _currentWindow;
    if (tag == null || local == null) return null;
    return DiscoveryTokens.resolveWindowTag(tag, local);
  }

  /// Windows that listed routes advertise.
  Set<int> get windowsInUse => {
        for (final e in _entries.values)
          for (final r in e.routes.values)
            ?windowOf(r.peer),
      };

  List<NearbyPeer> get peers => _peers;

  static String _routeKey(DiscoveredPeer p) => '${p.kind.name}|${p.address}';

  /// Records a sighting. Returns true if the visible list changed.
  bool update(DiscoveredPeer peer, DateTime now) {
    final id = peer.advertId;
    if (id != null && _selfAdvertIds.contains(id)) return false;
    final routeKey = (peer.kind, peer.address);
    final previous = _keyByRoute[routeKey];
    final String key;
    if (id == null) {
      key = _routeKey(peer);
    } else {
      final alias = _aliases[id];
      final prior = previous == null ? null : _entries[previous];
      // Same route, new id: the same phone in a new window.
      key = alias ?? (prior != null && prior.byAdvertId ? prior.key : id);
      _aliases[id] = key;
    }
    if (previous != null && previous != key) {
      final old = _entries[previous];
      old?.routes.remove(peer.kind);
      if (old != null && old.routes.isEmpty) _remove(previous);
    }
    _keyByRoute[routeKey] = key;
    final entry = _entries.putIfAbsent(
      key,
      () => _Entry(key, byAdvertId: id != null),
    );
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
      if (entry.routes.isEmpty) _remove(entry.key);
    }
    return removed && _rebuild();
  }

  void clear() {
    _entries.clear();
    _keyByRoute.clear();
    _aliases.clear();
    _rebuild();
  }

  void _remove(String key) {
    final entry = _entries.remove(key);
    if (entry != null) {
      for (final r in entry.routes.values) {
        _keyByRoute.remove((r.peer.kind, r.peer.address));
      }
    }
    _aliases.removeWhere((_, k) => k == key);
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

  Map<String, GroupId> _indexFor(DiscoveredPeer peer) {
    if (peer.windowTag == null || _currentWindow == null) return _tokenIndex;
    final w = windowOf(peer);
    if (w == null) return const {};
    return _windowIndexes[w] ?? const {};
  }

  bool _rebuild() {
    final out = <NearbyPeer>[];
    for (final entry in _entries.values) {
      final routes = [
        for (final kind in kTransportPreference)
          ?entry.routes[kind],
      ];
      if (routes.isEmpty) continue;
      final shared = <GroupId>{};
      for (final r in routes) {
        final index = _indexFor(r.peer);
        for (final t in r.peer.groupTokens) {
          final g = index[t];
          if (g != null) shared.add(g);
        }
      }
      final name = routes
          .map((r) => r.peer.name)
          .firstWhere((n) => n.isNotEmpty, orElse: () => '');
      // The most recently seen advert id.
      final withId = [
        for (final r in routes)
          if (r.peer.advertId != null) r,
      ]..sort((a, b) => b.seenAt.compareTo(a.seenAt));
      out.add(NearbyPeer(
        key: entry.key,
        name: name,
        advertId: withId.isEmpty ? null : withId.first.peer.advertId,
        transports: {for (final r in routes) r.peer.kind},
        sharedGroupIds: shared.toList()..sort(),
      ));
    }
    out.sort((a, b) {
      if (a.sharesGroups != b.sharesGroups) return a.sharesGroups ? -1 : 1;
      final c = a.name.compareTo(b.name);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
    final signature = out
        .map((p) => '${p.key}|${p.advertId}|${p.name}|'
            '${p.transports.map((t) => t.name)}|${p.sharedGroupIds}')
        .join('\n');
    if (signature == _signature) return false;
    _signature = signature;
    _peers = List.unmodifiable(out);
    return true;
  }
}
