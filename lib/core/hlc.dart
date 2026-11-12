// FROZEN CONTRACT (docs/SPEC.md section 5.3). Owner: core.
import 'dart:math' as math;

import 'package:meta/meta.dart';

import 'ids.dart';

/// Hybrid Logical Clock timestamp. Total order: (millis, counter, deviceId).
/// Encoded form sorts lexicographically in the same order:
///   `000001762700000-001a-{deviceId}` (15 digits, '-', 4 hex, '-', id)
@immutable
final class Hlc implements Comparable<Hlc> {
  const Hlc(this.millis, this.counter, this.deviceId);

  factory Hlc.zero(DeviceId deviceId) => Hlc(0, 0, deviceId);

  /// Throws FormatException on malformed input.
  ///
  /// Only the exact form [encode] produces is accepted (15 decimal digits,
  /// 4 lower-case hex digits). int.parse alone would also take a sign,
  /// whitespace, a 0x prefix or upper-case hex, whose text does not sort
  /// like [compareTo].
  factory Hlc.parse(String encoded) {
    final m = _encoded.firstMatch(encoded);
    if (m == null) throw FormatException('Bad HLC', encoded);
    return Hlc(
      int.parse(m.group(1)!),
      int.parse(m.group(2)!, radix: 16),
      m.group(3)!,
    );
  }

  static final RegExp _encoded =
      RegExp(r'^([0-9]{15})-([0-9a-f]{4})-([\s\S]+)$');

  static const int maxCounter = 0xFFFF;

  final int millis; // Unix epoch milliseconds (physical component)
  final int counter; // logical component, 0..0xFFFF
  final DeviceId deviceId; // tiebreak

  String encode() => '${millis.toString().padLeft(15, '0')}-'
      '${counter.toRadixString(16).padLeft(4, '0')}-$deviceId';

  @override
  int compareTo(Hlc other) {
    final c1 = millis.compareTo(other.millis);
    if (c1 != 0) return c1;
    final c2 = counter.compareTo(other.counter);
    if (c2 != 0) return c2;
    return deviceId.compareTo(other.deviceId);
  }

  bool operator <(Hlc other) => compareTo(other) < 0;
  bool operator >(Hlc other) => compareTo(other) > 0;

  @override
  bool operator ==(Object other) =>
      other is Hlc &&
      other.millis == millis &&
      other.counter == counter &&
      other.deviceId == deviceId;

  @override
  int get hashCode => Object.hash(millis, counter, deviceId);

  @override
  String toString() => encode();
}

/// One per device. Not thread-safe; owned by the data layer's Ledger.
final class HlcClock {
  HlcClock({required this.deviceId, Hlc? last, int Function()? nowMillis})
      : _last = last ?? Hlc.zero(deviceId),
        _now = nowMillis ?? _wallClock;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  /// Remote timestamps further ahead of our wall clock than this are
  /// accepted as data but never adopted by our clock (skew guard).
  static const int maxForwardDriftMs = 60 * 60 * 1000; // 1 hour

  final DeviceId deviceId;
  final int Function() _now;
  Hlc _last;

  /// True once a remote op beyond [maxForwardDriftMs] was observed.
  bool skewDetected = false;

  Hlc get last => _last;

  /// Timestamp for a new local event.
  Hlc tick() {
    final now = _now();
    final l = math.max(_last.millis, now);
    final c = l == _last.millis ? _last.counter + 1 : 0;
    return _last = _normalize(l, c);
  }

  /// Remote timestamps up to this far ahead of our wall clock are adopted
  /// by [tickAfter] when a local write replaces a value stamped with them.
  /// Beyond it the stamp is treated as broken or hostile and not adopted.
  static const int maxAdoptDriftMs = 7 * 24 * 60 * 60 * 1000; // 7 days

  /// Timestamp for a new local event that replaces state last written at
  /// [floor] (an edit, delete or restore of an entity): greater than [floor]
  /// as well as everything [tick] would give, so last-writer-wins keeps
  /// what the user just saved even when [floor] came from a phone whose
  /// clock is ahead of ours (beyond the [receive] skew guard). [floor] is
  /// adopted only within [maxAdoptDriftMs] of our wall clock; past that
  /// this is a plain [tick].
  Hlc tickAfter(Hlc floor) {
    final now = _now();
    final adopt = floor.millis <= now + maxAdoptDriftMs &&
        (floor.millis > _last.millis ||
            (floor.millis == _last.millis && floor.counter >= _last.counter));
    if (adopt) {
      // Only another phone's stamp says a peer clock is ahead. This phone's
      // own stamp ahead was written while its clock ran ahead; within
      // [maxAdoptDriftMs] peers accept it, so there is nothing to explain
      // (and "a phone you synced with is ahead" would be wrong).
      if (floor.millis > now + maxForwardDriftMs &&
          floor.deviceId != deviceId) {
        skewDetected = true;
      }
      // Re-home the floor on this device; tick() then moves past it.
      _last = Hlc(floor.millis, floor.counter, deviceId);
    }
    return tick();
  }

  /// Merge a remote timestamp (call once per received batch with its max).
  Hlc receive(Hlc remote) {
    final now = _now();
    if (remote.millis > now + maxForwardDriftMs) {
      skewDetected = true;
      return tick();
    }
    final l = math.max(math.max(_last.millis, remote.millis), now);
    final int c;
    if (l == _last.millis && l == remote.millis) {
      c = math.max(_last.counter, remote.counter) + 1;
    } else if (l == _last.millis) {
      c = _last.counter + 1;
    } else if (l == remote.millis) {
      c = remote.counter + 1;
    } else {
      c = 0;
    }
    return _last = _normalize(l, c);
  }

  Hlc _normalize(int l, int c) =>
      c > Hlc.maxCounter ? Hlc(l + 1, 0, deviceId) : Hlc(l, c, deviceId);
}
