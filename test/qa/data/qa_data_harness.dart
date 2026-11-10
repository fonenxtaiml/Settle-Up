// QA DATA harness: a "phone" on a real SQLite file that can be killed and
// relaunched, plus a fault-injecting OpStore wrapper.
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path/path.dart' as p;
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/secure_group_key_store.dart';
import 'package:settle_up/data/sqlite_op_store.dart';

/// 2026-11-09T00:00:00Z
const int kQaBaseMs = 1794182400000;

/// A wall clock that only moves when told to.
final class QaClock {
  QaClock([this.now = kQaBaseMs]);
  int now;
  int call() => now;
  void advance([int ms = 1000]) => now += ms;
}

/// Wraps any OpStore and fails chosen calls once, like a full disk.
final class FaultyStore implements OpStore {
  FaultyStore(this.inner);

  final OpStore inner;

  /// Throw on the next insertAll (before anything is written).
  bool failNextInsert = false;

  /// Throw on the next insertAll AFTER the inner store committed (the
  /// write landed, the caller sees an error, as with a lost reply).
  bool failAfterNextInsert = false;

  /// Throw on the next setKv whose key equals this.
  String? failNextSetKvKey;

  Object error = const FileSystemException('disk I/O error (SQLITE_FULL)');

  int insertCalls = 0;

  @override
  Future<List<Operation>> insertAll(List<Operation> ops) async {
    insertCalls++;
    if (failNextInsert) {
      failNextInsert = false;
      throw error;
    }
    final out = await inner.insertAll(ops);
    if (failAfterNextInsert) {
      failAfterNextInsert = false;
      throw error;
    }
    return out;
  }

  @override
  Future<void> setKv(String key, String? value) async {
    if (failNextSetKvKey == key) {
      failNextSetKvKey = null;
      throw error;
    }
    return inner.setKv(key, value);
  }

  @override
  Future<void> open() => inner.open();
  @override
  Future<void> close() => inner.close();
  @override
  Future<List<Operation>> loadAll() => inner.loadAll();
  @override
  Future<VersionVector> versionVector(GroupId groupId) =>
      inner.versionVector(groupId);
  @override
  Future<List<Operation>> missingFor(GroupId groupId, VersionVector peer) =>
      inner.missingFor(groupId, peer);
  @override
  Future<int> maxCounter(GroupId groupId, DeviceId deviceId) =>
      inner.maxCounter(groupId, deviceId);
  @override
  Future<void> purgeGroup(GroupId groupId) => inner.purgeGroup(groupId);
  @override
  Future<VersionVector> peerKnowledge(GroupId groupId) =>
      inner.peerKnowledge(groupId);
  @override
  Future<bool> capPeerKnowledge(GroupId groupId, DeviceId deviceId, int max) =>
      inner.capPeerKnowledge(groupId, deviceId, max);
  @override
  Future<void> recordPeerKnowledge(
          DeviceId peer, GroupId groupId, VersionVector vv) =>
      inner.recordPeerKnowledge(peer, groupId, vv);
  @override
  Future<String?> getKv(String key) => inner.getKv(key);
  @override
  Future<void> addSyncRecord(SyncRecord record) => inner.addSyncRecord(record);
  @override
  Future<List<SyncRecord>> syncRecords({int limit = 50}) =>
      inner.syncRecords(limit: limit);
}

/// A phone whose op log lives in a SQLite file under [dir]. [kill] drops
/// every object (no graceful close of the database beyond what the OS
/// would do); [launch] builds everything again from the file, exactly as
/// bootstrap.dart does.
final class FilePhone {
  FilePhone(this.dir, {this.seed = 1, String? fileName})
      : path = p.join(dir.path, fileName ?? 'settle_up.db');

  final Directory dir;
  final String path;
  final int seed;
  final QaClock clock = QaClock();

  /// Optional wrapper around the SQLite store (fault injection).
  OpStore Function(SqliteOpStore)? wrap;

  late SqliteOpStore sqlite;
  late OpStore store;
  late KvSettingsRepository settings;
  late Ledger ledger;
  int _launches = 0;

  /// Keys live in the (mocked) platform keystore, which survives restarts.
  final SecureGroupKeyStore keys = SecureGroupKeyStore();

  Future<FilePhone> launch() async {
    _launches++;
    sqlite = SqliteOpStore(path, nowMillis: clock.call);
    store = wrap?.call(sqlite) ?? sqlite;
    await store.open();
    settings = await KvSettingsRepository.open(
      store,
      defaultDeviceName: 'Phone $seed',
      // A fresh id range per launch so ids never collide across restarts
      // (UUIDv7 in production).
      ids: SequentialIdGenerator((seed << 44) + (_launches << 32)),
      localeName: 'en_IN',
    );
    ledger = await Ledger.open(
      store: store,
      keys: keys,
      settings: settings,
      ids: SequentialIdGenerator((seed << 44) + (_launches << 32) + 0x100000),
      nowMillis: clock.call,
    );
    return this;
  }

  /// Graceful shutdown (what happens when the process is torn down cleanly).
  Future<void> close() async {
    await ledger.close();
    await settings.close();
    await store.close();
  }

  Future<FilePhone> restart() async {
    await close();
    return launch();
  }

  DeviceId get deviceId => settings.device.deviceId;
  LedgerSnapshot get snap => ledger.current;
  GroupState group(GroupId g) => snap.state.groups[g]!;

  List<Operation> opsOf(GroupId g) =>
      [for (final o in snap.ops) if (o.groupId == g) o];

  List<Operation> mineIn(GroupId g) => [
        for (final o in snap.ops)
          if (o.groupId == g && o.deviceId == deviceId) o
      ]..sort((a, b) => a.counter.compareTo(b.counter));
}

/// Resets the mocked platform keystore.
void resetKeystore([Map<String, String> values = const {}]) =>
    FlutterSecureStorage.setMockInitialValues(Map.of(values));

Directory qaTempDir() => Directory.systemTemp.createTempSync('qa_data_');

ExpenseDraft qaDraft(
  GroupId g,
  List<MemberId> members, {
  String description = 'Dinner',
  int total = 6000,
  String currency = 'INR',
  DateTime? date,
}) =>
    ExpenseDraft(
      groupId: g,
      description: description,
      total: total,
      currency: currency,
      paidBy: SplitSpec.single(members.first, total),
      owedBy: SplitSpec.equal(members),
      category: 'food.dining',
      date: date ?? utcFromMillis(kQaBaseMs),
      notes: '',
    );

typedef Trip = ({GroupId g, MemberId me, MemberId sam, MemberId priya});

Future<Trip> qaTrip(FilePhone phone, {String name = 'Goa trip'}) async {
  final g = await phone.ledger.createGroup(NewGroup(
    name: name,
    type: GroupType.trip,
    currency: 'INR',
    newMemberNames: const ['Sam', 'Priya'],
  ));
  final gs = phone.group(g);
  MemberId named(String n) =>
      gs.members.values.firstWhere((m) => m.displayName == n).id;
  return (
    g: g,
    me: named(phone.settings.profile!.displayName),
    sam: named('Sam'),
    priya: named('Priya'),
  );
}
