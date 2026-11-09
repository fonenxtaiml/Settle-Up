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
  factory Hlc.parse(String encoded) {
    final a = encoded.indexOf('-');
    final b = a < 0 ? -1 : encoded.indexOf('-', a + 1);
    if (a != 15 || b != 20 || encoded.length <= 21) {
      throw FormatException('Bad HLC', encoded);
    }
    return Hlc(
      int.parse(encoded.substring(0, a)),
      int.parse(encoded.substring(a + 1, b), radix: 16),
      encoded.substring(b + 1),
    );
  }

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
