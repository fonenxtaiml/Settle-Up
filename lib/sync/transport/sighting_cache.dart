// The sightings of one discovery run, keyed by what the platform reports
// them under (an mDNS service name, a Nearby endpoint id).
import 'dart:collection';

import '../../core/models.dart';
import 'transport.dart';

typedef _Sighting = ({DiscoveredPeer peer, int seq, int order});

typedef _Index = Map<(TransportKind, String), SplayTreeMap<int, String>>;

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
///
/// Anyone on the network can announce sightings, and hidden ones stay
/// cached until their own withdrawal, so the cache can grow large under a
/// flood of forged adverts (SECURITY-R15-01). A sighting is hidden exactly
/// when a newer one shares its (kind, address) or its (kind, advert id),
/// so both are indexed by sequence number: [put], [remove], [isVisible]
/// and [showsAddress] cost O(log n) and never scan the other sightings;
/// [visible] and [all] are O(n log n) and O(n).
final class SightingCache {
  /// Key -> sighting, in first-put order (a re-put keeps its place).
  final Map<String, _Sighting> _all = {};

  /// (kind, address) and (kind, advert id) -> sequence number -> key. The
  /// last entry of a bucket is its newest sighting.
  final _Index _byAddress = {};
  final _Index _byAdvertId = {};
  int _seq = 0;
  int _order = 0;

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

  /// Whether a [visible] sighting (of any kind) has [address].
  bool showsAddress(String address) {
    for (final kind in TransportKind.values) {
      final key = _newest(_byAddress[(kind, address)]);
      if (key != null && isVisible(key)) return true;
    }
    return false;
  }

  static String? _newest(SplayTreeMap<int, String>? bucket) =>
      bucket == null || bucket.isEmpty ? null : bucket[bucket.lastKey()];

  static (TransportKind, String) _addressOf(DiscoveredPeer p) =>
      (p.kind, p.address);

  static (TransportKind, String)? _advertIdOf(DiscoveredPeer p) {
    final id = p.advertId;
    return id == null ? null : (p.kind, id);
  }

  static bool _hasNewer(SplayTreeMap<int, String>? bucket, int seq) =>
      bucket != null && bucket.isNotEmpty && bucket.lastKey()! > seq;

  bool _hidden(_Sighting e) {
    if (_hasNewer(_byAddress[_addressOf(e.peer)], e.seq)) return true;
    final id = _advertIdOf(e.peer);
    return id != null && _hasNewer(_byAdvertId[id], e.seq);
  }

  void _index(String key, _Sighting e) {
    _byAddress.putIfAbsent(_addressOf(e.peer), SplayTreeMap.new)[e.seq] = key;
    final id = _advertIdOf(e.peer);
    if (id != null) _byAdvertId.putIfAbsent(id, SplayTreeMap.new)[e.seq] = key;
  }

  static void _drop(_Index index, (TransportKind, String)? bucketKey, int seq) {
    if (bucketKey == null) return;
    final bucket = index[bucketKey];
    if (bucket == null) return;
    bucket.remove(seq);
    if (bucket.isEmpty) index.remove(bucketKey);
  }

  void _unindex(_Sighting e) {
    _drop(_byAddress, _addressOf(e.peer), e.seq);
    _drop(_byAdvertId, _advertIdOf(e.peer), e.seq);
  }

  /// The peers of [entries] (at most three) in [visible] order.
  static List<DiscoveredPeer> _inOrder(Iterable<_Sighting> entries) => [
    for (final e in entries.toList()..sort((a, b) => a.order - b.order)) e.peer,
  ];

  /// Records [peer] under [key] as the newest sighting of its phone and
  /// returns the sightings it hides (that were visible before). A peer
  /// object is cached under one key at a time (the transports build one
  /// per event); re-putting it under the same key is a refresh.
  List<DiscoveredPeer> put(String key, DiscoveredPeer peer) {
    // Only the sighting replaced under [key] and the newest sightings that
    // share the new one's address or advert id can lose visibility: any
    // other visible sighting shares no bucket with the new one.
    final hidden = <String, _Sighting>{};
    final old = _all[key];
    if (old != null && !_hidden(old) && !identical(old.peer, peer)) {
      hidden[key] = old;
    }
    for (final k in [
      _newest(_byAddress[_addressOf(peer)]),
      if (_advertIdOf(peer) case final id?) _newest(_byAdvertId[id]),
    ]) {
      if (k == null || k == key || hidden.containsKey(k)) continue;
      final e = _all[k]!;
      if (!_hidden(e) && !identical(e.peer, peer)) hidden[k] = e;
    }
    if (old != null) _unindex(old);
    final e = (peer: peer, seq: ++_seq, order: old?.order ?? ++_order);
    _all[key] = e;
    _index(key, e);
    return _inOrder(hidden.values);
  }

  /// Withdraws [key]. Returns the withdrawn sighting (null if [key] was not
  /// cached) and the sightings that became visible because of it.
  ({DiscoveredPeer? removed, List<DiscoveredPeer> shown}) remove(String key) {
    final gone = _all.remove(key);
    if (gone == null) return (removed: null, shown: const []);
    final wasVisible = !_hidden(gone);
    _unindex(gone);
    // Only a sighting that [gone] hid can be shown: the newest remaining
    // one of a bucket that [gone] was the newest of.
    final shown = <String, _Sighting>{};
    for (final (index, bucketKey) in [
      (_byAddress, _addressOf(gone.peer)),
      if (_advertIdOf(gone.peer) case final id?) (_byAdvertId, id),
    ]) {
      final bucket = index[bucketKey];
      if (bucket == null || _hasNewer(bucket, gone.seq)) continue;
      final k = bucket[bucket.lastKey()]!;
      final e = _all[k]!;
      if (_hidden(e) || (wasVisible && identical(e.peer, gone.peer))) {
        continue;
      }
      shown[k] = e;
    }
    return (removed: gone.peer, shown: _inOrder(shown.values));
  }

  void clear() {
    _all.clear();
    _byAddress.clear();
    _byAdvertId.clear();
  }
}
