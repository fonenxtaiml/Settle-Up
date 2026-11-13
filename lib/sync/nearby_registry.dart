// Merges DiscoveredPeer events from every transport into NearbyPeer rows
// (SPEC 8.7.1): by advert id when known, else by (kind, address).
// Shared groups come from the advertised tokens (SPEC 8.3). Routes unseen
// for [ttl] are dropped, and a peer with no routes left disappears.
//
// Advert ids rotate every token window. When a route that belonged to a
// row shows up with a new id, the new id becomes an alias of that row, so
// the row keeps its key and its other transports.
//
// Anyone nearby can advertise, and every transport re-reports what it sees
// every few seconds, so a sighting only rebuilds the rows it touches and
// moves them within the sorted list: a stranger announcing thousands of
// services must not make each sighting rebuild every row
// (SECURITY-R15-01).
import '../core/ids.dart';
import '../core/models.dart';
import 'crypto/tokens.dart';
import 'peer_label.dart';
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

  /// The row last built for this entry (null if none) and its signature.
  NearbyPeer? row;
  String signature = '';
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

  /// advert id -> entry key, and entry key -> its advert ids.
  final Map<String, String> _aliases = {};
  final Map<String, Set<String>> _aliasesOf = {};
  Map<String, GroupId> _tokenIndex = const {};
  final Map<int, Map<String, GroupId>> _windowIndexes = {};
  int? _currentWindow;
  List<NearbyPeer> _peers = const [];

  /// Every entry's row, in [peers] order.
  final List<NearbyPeer> _sorted = [];

  /// Entries whose row may have changed; every entry if [_allDirty].
  final Set<String> _dirty = {};
  bool _allDirty = false;

  /// A row left [_sorted] since [peers] was last published.
  bool _rowsRemoved = false;

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
    if (self.isNotEmpty) _flush();
  }

  /// token -> group for adverts that do not say their window: the windows
  /// currently accepted (SPEC 8.3).
  set tokenIndex(Map<String, GroupId> index) {
    _tokenIndex = Map.unmodifiable(index);
    _rebuildAll();
  }

  /// The scanner's own token window, which advertised window tags are
  /// resolved against.
  set currentWindow(int window) {
    if (_currentWindow == window) return;
    _currentWindow = window;
    _windowIndexes.removeWhere(
      (w, _) => (w - window).abs() > DiscoveryTokens.maxSkewWindows,
    );
    _rebuildAll();
  }

  /// Sets token -> group for exactly [window] (adverts that say it).
  /// Returns true if the visible list changed.
  bool setWindowIndex(int window, Map<String, GroupId> index) {
    _windowIndexes[window] = Map.unmodifiable(index);
    return _rebuildAll();
  }

  bool hasWindowIndex(int window) => _windowIndexes.containsKey(window);

  /// Forgets every per-window index (the group keys changed).
  void clearWindowIndexes() {
    _windowIndexes.clear();
    _rebuildAll();
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
      if (alias == null) {
        _aliases[id] = key;
        _aliasesOf.putIfAbsent(key, () => {}).add(id);
      }
    }
    if (previous != null && previous != key) {
      final old = _entries[previous];
      old?.routes.remove(peer.kind);
      if (old != null && old.routes.isEmpty) {
        _remove(previous);
      } else if (old != null) {
        _dirty.add(previous);
      }
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
    _dirty.add(key);
    return _flush();
  }

  /// Drops routes unseen for [ttl]. Returns true if the list changed.
  bool sweep(DateTime now) {
    var removed = false;
    for (final entry in _entries.values.toList()) {
      var stale = false;
      entry.routes.removeWhere((kind, r) {
        final s = now.difference(r.seenAt) > ttl;
        if (s) _keyByRoute.remove((kind, r.peer.address));
        stale |= s;
        return s;
      });
      if (entry.routes.isEmpty) {
        _remove(entry.key);
      } else if (stale) {
        _dirty.add(entry.key);
      }
      removed |= stale;
    }
    return removed && _flush();
  }

  void clear() {
    _entries.clear();
    _keyByRoute.clear();
    _aliases.clear();
    _aliasesOf.clear();
    _rebuildAll();
  }

  void _remove(String key) {
    final entry = _entries.remove(key);
    if (entry != null) {
      for (final r in entry.routes.values) {
        _keyByRoute.remove((r.peer.kind, r.peer.address));
      }
      final row = entry.row;
      if (row != null) {
        _removeSorted(row);
        _rowsRemoved = true;
      }
    }
    _dirty.remove(key);
    for (final id in _aliasesOf.remove(key) ?? const <String>{}) {
      if (_aliases[id] == key) _aliases.remove(id);
    }
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

  /// The row [entry] shows (null if it has no routes).
  NearbyPeer? _rowOf(_Entry entry) {
    final routes = [
      for (final kind in kTransportPreference)
        ?entry.routes[kind],
    ];
    if (routes.isEmpty) return null;
    final shared = <GroupId>{};
    for (final r in routes) {
      final index = _indexFor(r.peer);
      for (final t in r.peer.groupTokens) {
        final g = index[t];
        if (g != null) shared.add(g);
      }
    }
    // Advertised names are the peer's word: cleaned before they show,
    // and a row is never blank (DATA-R6-01).
    final name = peerLabel([for (final r in routes) r.peer.name]);
    // The most recently seen advert id.
    final withId = [
      for (final r in routes)
        if (r.peer.advertId != null) r,
    ]..sort((a, b) => b.seenAt.compareTo(a.seenAt));
    return NearbyPeer(
      key: entry.key,
      name: name,
      advertId: withId.isEmpty ? null : withId.first.peer.advertId,
      transports: {for (final r in routes) r.peer.kind},
      sharedGroupIds: shared.toList()..sort(),
      moreGroups: routes.any((r) => r.peer.moreGroups),
    );
  }

  static String _signatureOf(NearbyPeer? p) => p == null
      ? ''
      : '${p.key}|${p.advertId}|${p.name}|'
          '${p.transports.map((t) => t.name)}|${p.sharedGroupIds}|'
          '${p.moreGroups}';

  /// [peers] order: shared groups first, then peers that may share some,
  /// then by name. Keys are unique, so this is a total order.
  static int _compare(NearbyPeer a, NearbyPeer b) {
    if (a.sharesGroups != b.sharesGroups) return a.sharesGroups ? -1 : 1;
    if (a.maySync != b.maySync) return a.maySync ? -1 : 1;
    final c = a.name.compareTo(b.name);
    return c != 0 ? c : a.key.compareTo(b.key);
  }

  /// Where [row] is, or belongs, in [_sorted].
  int _slotOf(NearbyPeer row) {
    var lo = 0;
    var hi = _sorted.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_compare(_sorted[mid], row) < 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  void _removeSorted(NearbyPeer row) {
    final i = _slotOf(row);
    if (i < _sorted.length && identical(_sorted[i], row)) {
      _sorted.removeAt(i);
    } else {
      _sorted.removeWhere((p) => identical(p, row));
    }
  }

  /// Rebuilds every row (the token indexes or the window changed).
  bool _rebuildAll() {
    _allDirty = true;
    return _flush();
  }

  /// Rebuilds the dirty rows and publishes [peers] if anything visible
  /// changed. Returns whether it did.
  bool _flush() {
    var changed = _rowsRemoved;
    _rowsRemoved = false;
    if (_allDirty) {
      _allDirty = false;
      _dirty.clear();
      _sorted.clear();
      for (final entry in _entries.values) {
        final row = _rowOf(entry);
        final signature = _signatureOf(row);
        if (signature != entry.signature) {
          changed = true;
          entry
            ..row = row
            ..signature = signature;
        }
        final kept = entry.row;
        if (kept != null) _sorted.add(kept);
      }
      _sorted.sort(_compare);
      // Every entry dropped at once (clear()).
      if (!changed && _sorted.length != _peers.length) changed = true;
    } else {
      for (final key in _dirty) {
        final entry = _entries[key];
        if (entry == null) continue;
        final row = _rowOf(entry);
        final signature = _signatureOf(row);
        if (signature == entry.signature) continue;
        final old = entry.row;
        if (old != null) _removeSorted(old);
        if (row != null) _sorted.insert(_slotOf(row), row);
        entry
          ..row = row
          ..signature = signature;
        changed = true;
      }
      _dirty.clear();
    }
    if (!changed) return false;
    _peers = List.unmodifiable(_sorted);
    return true;
  }
}
