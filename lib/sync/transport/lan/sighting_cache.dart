// The sightings of one discovery run, keyed by what the platform reports
// them under (an mDNS service name, a Nearby endpoint id).
import '../transport.dart';

/// Every sighting that was reported and not yet withdrawn (an mDNS goodbye
/// or TTL expiry, a Nearby "lost"), of which only the newest per
/// advertiser ([DiscoveredPeer.sameAdvertiserAs]) is [visible].
///
/// A phone runs one service at a time, so an older sighting of the same
/// phone is usually its name before a rename whose goodbye was missed
/// (SYNC-R6-01) and is hidden. It is not dropped, though: the platform may
/// also replay a stale cached record after the live one (a fresh mDNS
/// browse resolves cached services in no defined order). When the newest
/// sighting is then withdrawn, the newest remaining one of that phone is
/// shown again, so a withdrawal of one key never hides another key of the
/// same phone that has not been withdrawn (SYNC-R8-01).
final class SightingCache {
  final Map<String, ({DiscoveredPeer peer, int seq})> _all = {};
  int _seq = 0;

  bool get isEmpty => _all.isEmpty;

  /// Every sighting not yet withdrawn, hidden ones included.
  Iterable<DiscoveredPeer> get all => _all.values.map((e) => e.peer);

  /// The newest sighting of each advertiser, at most one per phone.
  List<DiscoveredPeer> get visible => [
    for (final e in _all.values)
      if (!_hidden(e)) e.peer,
  ];

  /// Whether [key] is cached and is its phone's newest sighting.
  bool isVisible(String key) {
    final e = _all[key];
    return e != null && !_hidden(e);
  }

  bool _hidden(({DiscoveredPeer peer, int seq}) e) =>
      _all.values.any((o) => o.seq > e.seq && o.peer.sameAdvertiserAs(e.peer));

  /// Records [peer] under [key] as the newest sighting of its phone and
  /// returns the sightings it hides (that were visible before).
  List<DiscoveredPeer> put(String key, DiscoveredPeer peer) {
    final before = visible;
    _all[key] = (peer: peer, seq: ++_seq);
    final now = visible;
    return [
      for (final p in before)
        if (!now.any((q) => identical(q, p))) p,
    ];
  }

  /// Withdraws [key]. Returns the withdrawn sighting (null if [key] was not
  /// cached) and the sightings that became visible because of it.
  ({DiscoveredPeer? removed, List<DiscoveredPeer> shown}) remove(String key) {
    final before = visible;
    final gone = _all.remove(key);
    if (gone == null) return (removed: null, shown: const []);
    return (
      removed: gone.peer,
      shown: [
        for (final p in visible)
          if (!before.any((q) => identical(q, p))) p,
      ],
    );
  }

  void clear() => _all.clear();
}
