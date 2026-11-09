// In-memory OpStore with the same observable behaviour as SqliteOpStore
// (docs/SPEC.md 5.11, 7.4). Used by tests and by the sync package's
// end-to-end tests. Owner: data.
import 'dart:convert';
import 'dart:developer' as developer;

import '../core/ids.dart';
import '../core/models.dart';
import '../core/ops.dart';
import '../core/version_vector.dart';
import 'codecs.dart';
import 'repositories.dart';
import 'schema.dart';

final class MemoryOpStore implements OpStore {
  MemoryOpStore();

  // group -> device -> counter -> op
  final Map<GroupId, Map<DeviceId, Map<int, Operation>>> _ops = {};
  final Map<OpId, Operation> _byId = {};
  final Map<GroupId, Map<DeviceId, int>> _vv = {};
  // group -> peer -> device -> counter
  final Map<GroupId, Map<DeviceId, Map<DeviceId, int>>> _peers = {};
  final Map<String, String> _kv = {};
  final Map<String, SyncRecord> _records = {};

  @override
  Future<void> open() async {}

  /// Keeps the data, like closing and reopening a database file.
  @override
  Future<void> close() async {}

  @override
  Future<List<Operation>> insertAll(List<Operation> ops) async {
    final added = <Operation>[];
    final touched = <(GroupId, DeviceId)>{};
    for (final op in ops) {
      if (_byId.containsKey(op.id)) continue;
      final byCounter =
          (_ops[op.groupId] ??= {})[op.deviceId] ??= <int, Operation>{};
      if (byCounter.containsKey(op.counter)) {
        developer.log(
          'Ignored forked op ${op.id}: counter ${op.counter} of '
          '${op.deviceId} in ${op.groupId} is already taken',
          name: 'settle_up.data',
        );
        continue;
      }
      byCounter[op.counter] = op;
      _byId[op.id] = op;
      added.add(op);
      touched.add((op.groupId, op.deviceId));
    }
    for (final (g, d) in touched) {
      final byCounter = _ops[g]![d]!;
      final vv = _vv[g] ??= {};
      var n = vv[d] ?? 0;
      while (byCounter.containsKey(n + 1)) {
        n++;
      }
      if (n > 0) vv[d] = n;
    }
    return added;
  }

  @override
  Future<List<Operation>> loadAll() async => _byId.values.toList();

  @override
  Future<VersionVector> versionVector(GroupId groupId) async =>
      VersionVector(_vv[groupId] ?? const {});

  @override
  Future<List<Operation>> missingFor(
    GroupId groupId,
    VersionVector peer,
  ) async {
    final byDevice = _ops[groupId];
    if (byDevice == null) return const [];
    final devices = byDevice.keys.toList()..sort();
    final out = <Operation>[];
    for (final d in devices) {
      final byCounter = byDevice[d]!;
      final counters = byCounter.keys.where((c) => c > peer[d]).toList()
        ..sort();
      for (final c in counters) {
        out.add(byCounter[c]!);
      }
    }
    return out;
  }

  @override
  Future<int> maxCounter(GroupId groupId, DeviceId deviceId) async {
    final counters = _ops[groupId]?[deviceId]?.keys;
    if (counters == null || counters.isEmpty) return 0;
    return counters.reduce((a, b) => a > b ? a : b);
  }

  @override
  Future<void> purgeGroup(GroupId groupId) async {
    final byDevice = _ops.remove(groupId);
    if (byDevice != null) {
      final mark = purgedMark(_kv[KvKeys.purged(groupId)]);
      byDevice.forEach((d, byCounter) {
        for (final c in byCounter.keys) {
          if (c > (mark[d] ?? 0)) mark[d] = c;
        }
      });
      if (mark.isNotEmpty) _kv[KvKeys.purged(groupId)] = jsonEncode(mark);
      for (final byCounter in byDevice.values) {
        for (final op in byCounter.values) {
          _byId.remove(op.id);
        }
      }
    }
    _vv.remove(groupId);
    _peers.remove(groupId);
    _kv.remove(KvKeys.pending(groupId));
  }

  @override
  Future<VersionVector> peerKnowledge(GroupId groupId) async {
    var out = VersionVector.empty;
    for (final known in (_peers[groupId] ?? const {}).values) {
      out = out.merge(VersionVector(known));
    }
    return out;
  }

  @override
  Future<void> recordPeerKnowledge(
    DeviceId peer,
    GroupId groupId,
    VersionVector vv,
  ) async {
    if (vv.entries.isEmpty) return;
    final known = (_peers[groupId] ??= {})[peer] ??= {};
    vv.entries.forEach((device, counter) {
      if (counter > (known[device] ?? 0)) known[device] = counter;
    });
  }

  @override
  Future<String?> getKv(String key) async => _kv[key];

  @override
  Future<void> setKv(String key, String? value) async {
    if (value == null) {
      _kv.remove(key);
    } else {
      _kv[key] = value;
    }
  }

  @override
  Future<void> addSyncRecord(SyncRecord record) async {
    _records[record.id] = record;
  }

  @override
  Future<List<SyncRecord>> syncRecords({int limit = 50}) async {
    if (limit <= 0) return const [];
    final all = _records.values.toList()..sort(compareSyncRecordsNewestFirst);
    return all.take(limit).toList();
  }
}
