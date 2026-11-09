// OpStore on SQLite through package:sqlite3, no ORM (docs/SPEC.md 2.1,
// 7.4, 7.5). Owner: data.
//
// SQLite runs synchronously on the calling isolate; the expected sizes
// (<= 20k ops) make that fine. Every multi-row write is one transaction.
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:sqlite3/sqlite3.dart';

import '../core/ids.dart';
import '../core/models.dart';
import '../core/ops.dart';
import '../core/version_vector.dart';
import 'codecs.dart';
import 'repositories.dart';
import 'schema.dart';

final class SqliteOpStore implements OpStore {
  /// [path] is a file path, or `':memory:'` for a private in-memory database.
  SqliteOpStore(this.path, {int Function()? nowMillis})
      : _now = nowMillis ?? _wallClock;

  static int _wallClock() => DateTime.now().millisecondsSinceEpoch;

  final String path;
  final int Function() _now;
  Database? _db;

  Database get _open {
    final db = _db;
    if (db == null) throw StateError('SqliteOpStore is not open');
    return db;
  }

  @override
  Future<void> open() async {
    if (_db != null) return;
    final db = path == ':memory:' ? sqlite3.openInMemory() : sqlite3.open(path);
    try {
      migrate(db);
    } catch (_) {
      db.close();
      rethrow;
    }
    _db = db;
  }

  @override
  Future<void> close() async {
    _db?.close();
    _db = null;
  }

  T _transaction<T>(T Function(Database db) body) {
    final db = _open;
    db.execute('BEGIN IMMEDIATE');
    try {
      final out = body(db);
      db.execute('COMMIT');
      return out;
    } catch (_) {
      if (!db.autocommit) db.execute('ROLLBACK');
      rethrow;
    }
  }

  // ------------------------------------------------------------------ ops --

  @override
  Future<List<Operation>> insertAll(List<Operation> ops) async {
    if (ops.isEmpty) return const [];
    // Encode first so a bad payload fails before anything is written.
    final encoded = [for (final op in ops) jsonEncode(op.toJson())];
    final receivedAt = _now();
    return _transaction((db) {
      final added = <Operation>[];
      final touched = <(GroupId, DeviceId)>{};
      final insert = db.prepare(
        'INSERT OR IGNORE INTO ops(op_id, group_id, device_id, counter, hlc, '
        'schema_ver, json, received_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
      );
      final exists = db.prepare('SELECT 1 FROM ops WHERE op_id = ?');
      try {
        for (var i = 0; i < ops.length; i++) {
          final op = ops[i];
          insert.execute([
            op.id,
            op.groupId,
            op.deviceId,
            op.counter,
            op.hlc.encode(),
            op.schemaVersion,
            encoded[i],
            receivedAt,
          ]);
          if (db.updatedRows == 0) {
            if (exists.select([op.id]).isEmpty) {
              developer.log(
                'Ignored forked op ${op.id}: counter ${op.counter} of '
                '${op.deviceId} in ${op.groupId} is already taken',
                name: 'settle_up.data',
              );
            }
            continue;
          }
          added.add(op);
          touched.add((op.groupId, op.deviceId));
        }
      } finally {
        insert.close();
        exists.close();
      }
      for (final (g, d) in touched) {
        _advance(db, g, d);
      }
      return added;
    });
  }

  /// `while exists(counter = vv + 1) vv++` (SPEC 7.4).
  void _advance(Database db, GroupId groupId, DeviceId deviceId) {
    final rows = db.select(
      'SELECT max_counter FROM vv WHERE group_id = ? AND device_id = ?',
      [groupId, deviceId],
    );
    final start = rows.isEmpty ? 0 : rows.first.columnAt(0) as int;
    final next = db.select(
      'SELECT counter FROM ops WHERE group_id = ? AND device_id = ? '
      'AND counter > ? ORDER BY counter',
      [groupId, deviceId, start],
    );
    var n = start;
    for (final row in next) {
      final c = row.columnAt(0) as int;
      if (c != n + 1) break;
      n = c;
    }
    if (n == start) return;
    db.execute(
      'INSERT INTO vv(group_id, device_id, max_counter) VALUES (?, ?, ?) '
      'ON CONFLICT(group_id, device_id) DO UPDATE SET max_counter = '
      'excluded.max_counter',
      [groupId, deviceId, n],
    );
  }

  /// Null (and logged) for a row that no longer parses, so one corrupt row
  /// cannot stop the app from starting.
  static Operation? _decode(String json) {
    try {
      return Operation.fromJson(
        Map<String, Object?>.from(jsonDecode(json) as Map),
      );
    } catch (e) {
      developer.log('Skipped unreadable stored op: $e',
          name: 'settle_up.data');
      return null;
    }
  }

  @override
  Future<List<Operation>> loadAll() async => [
        for (final row in _open.select('SELECT json FROM ops'))
          ?_decode(row.columnAt(0) as String),
      ];

  @override
  Future<VersionVector> versionVector(GroupId groupId) async =>
      _vector(_open.select(
        'SELECT device_id, max_counter FROM vv WHERE group_id = ?',
        [groupId],
      ));

  VersionVector _vector(ResultSet rows) => VersionVector({
        for (final row in rows) row.columnAt(0) as String: row.columnAt(1) as int,
      });

  @override
  Future<List<Operation>> missingFor(
    GroupId groupId,
    VersionVector peer,
  ) async {
    final rows = _open.select(
      'SELECT json, device_id, counter FROM ops WHERE group_id = ? '
      'ORDER BY device_id, counter',
      [groupId],
    );
    return [
      for (final row in rows)
        if ((row.columnAt(2) as int) > peer[row.columnAt(1) as String])
          ?_decode(row.columnAt(0) as String),
    ];
  }

  @override
  Future<int> maxCounter(GroupId groupId, DeviceId deviceId) async {
    final rows = _open.select(
      'SELECT MAX(counter) FROM ops WHERE group_id = ? AND device_id = ?',
      [groupId, deviceId],
    );
    return rows.first.columnAt(0) as int? ?? 0;
  }

  @override
  Future<void> purgeGroup(GroupId groupId) async {
    _transaction((db) {
      db.execute('DELETE FROM ops WHERE group_id = ?', [groupId]);
      db.execute('DELETE FROM vv WHERE group_id = ?', [groupId]);
      db.execute('DELETE FROM peer_vv WHERE group_id = ?', [groupId]);
      db.execute('DELETE FROM kv WHERE key = ?', [KvKeys.pending(groupId)]);
    });
  }

  // --------------------------------------------------------- peer vectors --

  @override
  Future<VersionVector> peerKnowledge(GroupId groupId) async =>
      _vector(_open.select(
        'SELECT device_id, MAX(max_counter) FROM peer_vv WHERE group_id = ? '
        'GROUP BY device_id',
        [groupId],
      ));

  /// Merges (pointwise max) into what [peer] is known to hold: knowledge
  /// only grows, so a stale or reordered report never makes ops unshared.
  @override
  Future<void> recordPeerKnowledge(
    DeviceId peer,
    GroupId groupId,
    VersionVector vv,
  ) async {
    if (vv.entries.isEmpty) return;
    _transaction((db) {
      final stmt = db.prepare(
        'INSERT INTO peer_vv(peer_id, group_id, device_id, max_counter) '
        'VALUES (?, ?, ?, ?) ON CONFLICT(peer_id, group_id, device_id) '
        'DO UPDATE SET max_counter = MAX(max_counter, excluded.max_counter)',
      );
      try {
        for (final e in vv.entries.entries) {
          stmt.execute([peer, groupId, e.key, e.value]);
        }
      } finally {
        stmt.close();
      }
    });
  }

  // ------------------------------------------------------------------- kv --

  @override
  Future<String?> getKv(String key) async {
    final rows = _open.select('SELECT value FROM kv WHERE key = ?', [key]);
    return rows.isEmpty ? null : rows.first.columnAt(0) as String;
  }

  @override
  Future<void> setKv(String key, String? value) async {
    if (value == null) {
      _open.execute('DELETE FROM kv WHERE key = ?', [key]);
    } else {
      _open.execute(
        'INSERT INTO kv(key, value) VALUES (?, ?) '
        'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
        [key, value],
      );
    }
  }

  // --------------------------------------------------------- sync records --

  @override
  Future<void> addSyncRecord(SyncRecord record) async {
    _open.execute(
      'INSERT OR REPLACE INTO sync_records(id, started_at, json) '
      'VALUES (?, ?, ?)',
      [
        record.id,
        record.startedAt.millisecondsSinceEpoch,
        jsonEncode(syncRecordToJson(record)),
      ],
    );
  }

  @override
  Future<List<SyncRecord>> syncRecords({int limit = 50}) async {
    if (limit <= 0) return const [];
    final rows = _open.select(
      'SELECT json FROM sync_records ORDER BY started_at DESC, id DESC '
      'LIMIT ?',
      [limit],
    );
    return [
      for (final row in rows)
        ?_record(row.columnAt(0) as String),
    ];
  }

  static SyncRecord? _record(String json) {
    try {
      return syncRecordFromJson(jsonDecode(json));
    } catch (_) {
      return null;
    }
  }
}
