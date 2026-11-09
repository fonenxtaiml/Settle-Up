// SQLite schema of the op store (docs/SPEC.md section 7.5). Owner: data.
//
// The op log is append-only; everything the UI shows is folded from it in
// memory by the core reducer, so these few tables are all the app stores.
// `PRAGMA user_version` holds the schema version and [migrate] walks a
// `switch` ladder from whatever version the file is at up to
// [kStoreSchemaVersion], inside one transaction.
import 'package:sqlite3/sqlite3.dart';

/// Version written to `PRAGMA user_version` once [migrate] has run.
const int kStoreSchemaVersion = 1;

/// Keys of the `kv` table (SPEC 7.5).
abstract final class KvKeys {
  static const device = 'device'; // JSON {deviceId, deviceName}
  static const profile = 'profile'; // JSON {personId, displayName, homeCurrency}
  static const settings = 'settings'; // JSON AppSettings
  static const hlcLast = 'hlc.last'; // encoded Hlc
  static const pendingPrefix = 'pending.'; // + groupId -> name hint

  static String pending(String groupId) => '$pendingPrefix$groupId';
}

/// Version 1 tables, exactly as in SPEC 7.5 (journal mode is set by [migrate]
/// because it cannot run inside a transaction). `IF NOT EXISTS`: a file that
/// already holds them but lost its `user_version` (reads 0) is adopted with
/// its data instead of failing to open.
const List<String> _v1 = [
  '''
CREATE TABLE IF NOT EXISTS ops(
  op_id       TEXT PRIMARY KEY,
  group_id    TEXT NOT NULL,
  device_id   TEXT NOT NULL,
  counter     INTEGER NOT NULL,
  hlc         TEXT NOT NULL,
  schema_ver  INTEGER NOT NULL,
  json        TEXT NOT NULL,
  received_at INTEGER NOT NULL,
  UNIQUE(group_id, device_id, counter)
) STRICT''',
  'CREATE INDEX IF NOT EXISTS ops_group_hlc ON ops(group_id, hlc)',
  '''
CREATE TABLE IF NOT EXISTS vv(
  group_id    TEXT NOT NULL,
  device_id   TEXT NOT NULL,
  max_counter INTEGER NOT NULL,
  PRIMARY KEY(group_id, device_id)
) STRICT''',
  '''
CREATE TABLE IF NOT EXISTS peer_vv(
  peer_id     TEXT NOT NULL,
  group_id    TEXT NOT NULL,
  device_id   TEXT NOT NULL,
  max_counter INTEGER NOT NULL,
  PRIMARY KEY(peer_id, group_id, device_id)
) STRICT''',
  'CREATE TABLE IF NOT EXISTS kv(key TEXT PRIMARY KEY, value TEXT NOT NULL) '
      'STRICT',
  '''
CREATE TABLE IF NOT EXISTS sync_records(
  id         TEXT PRIMARY KEY,
  started_at INTEGER NOT NULL,
  json       TEXT NOT NULL
) STRICT''',
];

/// Brings [db] to [kStoreSchemaVersion]. Throws [StateError] when the file
/// was written by a newer app (its schema cannot be downgraded safely).
void migrate(Database db) {
  db.execute('PRAGMA journal_mode = WAL');
  final from = db.userVersion;
  if (from == kStoreSchemaVersion) return;
  if (from > kStoreSchemaVersion) {
    throw StateError(
      'Database schema $from is newer than this app ($kStoreSchemaVersion)',
    );
  }
  db.execute('BEGIN IMMEDIATE');
  try {
    for (var v = from; v < kStoreSchemaVersion; v++) {
      switch (v) {
        case 0:
          _v1.forEach(db.execute);
      }
    }
    db.userVersion = kStoreSchemaVersion;
    db.execute('COMMIT');
  } catch (_) {
    db.execute('ROLLBACK');
    rethrow;
  }
}
