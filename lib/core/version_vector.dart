// FROZEN CONTRACT (docs/SPEC.md section 5.4). Owner: core.
import 'package:meta/meta.dart';

import 'ids.dart';

/// Per group: for each author device, the highest counter N such that this
/// replica holds ALL ops 1..N from that device (contiguous prefix only).
@immutable
final class VersionVector {
  VersionVector([Map<DeviceId, int> entries = const {}])
    : entries = Map.unmodifiable({
        for (final e in entries.entries)
          if (e.value > 0) e.key: e.value,
      });

  static final VersionVector empty = VersionVector();

  final Map<DeviceId, int> entries;

  int operator [](DeviceId deviceId) => entries[deviceId] ?? 0;

  bool includes(DeviceId deviceId, int counter) => this[deviceId] >= counter;

  VersionVector withEntry(DeviceId deviceId, int counter) =>
      VersionVector({...entries, deviceId: counter});

  /// Pointwise max.
  VersionVector merge(VersionVector other) {
    final out = Map<DeviceId, int>.of(entries);
    other.entries.forEach((k, v) {
      if (v > (out[k] ?? 0)) out[k] = v;
    });
    return VersionVector(out);
  }

  /// True if this >= other pointwise.
  bool dominates(VersionVector other) =>
      other.entries.entries.every((e) => this[e.key] >= e.value);

  Map<String, int> toJson() => Map.of(entries);

  factory VersionVector.fromJson(Map<String, Object?> json) =>
      VersionVector({for (final e in json.entries) e.key: e.value! as int});

  @override
  bool operator ==(Object other) =>
      other is VersionVector && dominates(other) && other.dominates(this);

  @override
  int get hashCode => Object.hashAllUnordered(
    entries.entries.map((e) => Object.hash(e.key, e.value)),
  );

  @override
  String toString() => 'VV($entries)';
}
