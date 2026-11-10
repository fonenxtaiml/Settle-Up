// One OpStore contract suite (SPEC 5.11, 7.4, 11.2), run against both
// MemoryOpStore and SqliteOpStore(':memory:').
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/schema.dart';
import 'package:settle_up/data/sqlite_op_store.dart';
import 'package:sqlite3/sqlite3.dart';

import 'helpers.dart';

void main() {
  runOpStoreContract('MemoryOpStore', MemoryOpStore.new);
  runOpStoreContract('SqliteOpStore(:memory:)', () => SqliteOpStore(':memory:'));
  sqliteOnly();
}

void runOpStoreContract(String name, OpStore Function() create) {
  group('$name contract', () {
    late OpStore store;

    setUp(() async {
      store = create();
      await store.open();
    });

    tearDown(() => store.close());

    List<String> ids(Iterable<Operation> ops) => [for (final o in ops) o.id];

    test('insertAll is insert-or-ignore by op id, new ops in input order',
        () async {
      final a1 = rawOp(gA, dA, 1);
      final a2 = rawOp(gA, dA, 2);
      final b1 = rawOp(gA, dB, 1);
      expect(ids(await store.insertAll([a2, a1])), ids([a2, a1]));
      expect(ids(await store.insertAll([a1, b1, a2, b1])), ids([b1]));
      expect(await store.insertAll(const []), isEmpty);
      expect((await store.loadAll()).toSet(), {a1, a2, b1});
    });

    test('ops round trip through storage unchanged', () async {
      final op = Operation(
        id: 'op-1',
        groupId: gA,
        deviceId: dA,
        counter: 1,
        hlc: const Hlc(kBaseMs, 7, dA),
        entityType: EntityType.expense,
        entityId: 'e-1',
        kind: OpKind.create,
        payload: {
          ExpenseFields.description: 'Dinner, "late"',
          ExpenseFields.date: kBaseMs,
          ExpenseFields.notes: null,
          ExpenseFields.money: {
            'total': 6000,
            'nested': {'a': 1},
          },
          'unknownFutureField': [1, 'x', true],
        },
      );
      await store.insertAll([op]);
      final loaded = (await store.loadAll()).single;
      expect(loaded.toJson(), op.toJson());
      expect(loaded.hlc, op.hlc);
    });

    test('newer-schema ops are stored and returned byte for byte', () async {
      final json = <String, Object?>{
        'id': 'future-1',
        'groupId': gA,
        'deviceId': dB,
        'counter': 1,
        'hlc': const Hlc(kBaseMs, 0, dB).encode(),
        'entityType': 'receipt',
        'entityId': 'r-1',
        'kind': 'attach',
        'payload': {'sha256': 'abc'},
        'schemaVersion': 2,
        'sig': 'zzz',
      };
      final op = Operation.fromJson(json);
      expect(await store.insertAll([op]), [op]);
      final out = (await store.missingFor(gA, VersionVector.empty)).single;
      expect(out.isFromNewerSchema, isTrue);
      expect(jsonEncode(out.toJson()), jsonEncode(json));
      expect(await store.versionVector(gA), VersionVector({dB: 1}));
    });

    test('version vector is the contiguous prefix: 1,2,4 -> 2; then 3 -> 4',
        () async {
      await store.insertAll([rawOp(gA, dA, 1), rawOp(gA, dA, 2), rawOp(gA, dA, 4)]);
      expect(await store.versionVector(gA), VersionVector({dA: 2}));
      expect(await store.maxCounter(gA, dA), 4);
      await store.insertAll([rawOp(gA, dA, 3)]);
      expect(await store.versionVector(gA), VersionVector({dA: 4}));
    });

    test('a gap from counter 1 leaves the device out of the vector', () async {
      await store.insertAll([rawOp(gA, dB, 2), rawOp(gA, dB, 3)]);
      expect(await store.versionVector(gA), VersionVector.empty);
      expect(await store.maxCounter(gA, dB), 3);
      await store.insertAll([rawOp(gA, dB, 1)]);
      expect(await store.versionVector(gA), VersionVector({dB: 3}));
    });

    test('vectors and counters are per group and per device', () async {
      await store.insertAll([
        rawOp(gA, dA, 1),
        rawOp(gA, dB, 1),
        rawOp(gA, dB, 2),
        rawOp(gB, dA, 1),
      ]);
      expect(await store.versionVector(gA), VersionVector({dA: 1, dB: 2}));
      expect(await store.versionVector(gB), VersionVector({dA: 1}));
      expect(await store.maxCounter(gB, dB), 0);
      expect(await store.maxCounter('unknown', dA), 0);
      expect(await store.versionVector('unknown'), VersionVector.empty);
    });

    test('missingFor: counter > peer, sorted by (device, counter), '
        'third-party ops included', () async {
      await store.insertAll([
        rawOp(gA, dC, 2),
        rawOp(gA, dA, 3),
        rawOp(gA, dB, 1),
        rawOp(gA, dA, 1),
        rawOp(gA, dC, 1),
        rawOp(gA, dA, 2),
        rawOp(gB, dA, 9),
      ]);
      final out = await store.missingFor(gA, VersionVector({dA: 1, dB: 5}));
      expect([for (final o in out) (o.deviceId, o.counter)], [
        (dA, 2),
        (dA, 3),
        (dC, 1),
        (dC, 2),
      ]);
      expect(await store.missingFor(gA, VersionVector({dA: 3, dB: 1, dC: 2})),
          isEmpty);
      expect(await store.missingFor('unknown', VersionVector.empty), isEmpty);
    });

    test('missingFor includes ops beyond a gap', () async {
      await store.insertAll([rawOp(gA, dA, 1), rawOp(gA, dA, 3)]);
      final out = await store.missingFor(gA, VersionVector.empty);
      expect([for (final o in out) o.counter], [1, 3]);
    });

    test('fork: same (group, device, counter), new id -> first kept', () async {
      final first = rawOp(gA, dA, 1, id: 'first');
      final fork = rawOp(gA, dA, 1, id: 'fork');
      expect(await store.insertAll([first]), [first]);
      expect(await store.insertAll([fork]), isEmpty);
      expect(ids(await store.loadAll()), ['first']);
      // Also within one batch.
      final x = rawOp(gB, dA, 1, id: 'x');
      final y = rawOp(gB, dA, 1, id: 'y');
      expect(ids(await store.insertAll([x, y])), ['x']);
      expect(await store.versionVector(gB), VersionVector({dA: 1}));
    });

    test('peer knowledge is the pointwise max over peers and only grows',
        () async {
      expect(await store.peerKnowledge(gA), VersionVector.empty);
      await store.recordPeerKnowledge(dB, gA, VersionVector({dA: 3, dB: 1}));
      await store.recordPeerKnowledge(dC, gA, VersionVector({dA: 1, dC: 4}));
      await store.recordPeerKnowledge(dB, gB, VersionVector({dA: 9}));
      expect(await store.peerKnowledge(gA),
          VersionVector({dA: 3, dB: 1, dC: 4}));
      // A stale report from the same peer does not lower it.
      await store.recordPeerKnowledge(dB, gA, VersionVector({dA: 2}));
      expect((await store.peerKnowledge(gA))[dA], 3);
      await store.recordPeerKnowledge(dB, gA, VersionVector.empty);
      expect(await store.peerKnowledge(gB), VersionVector({dA: 9}));
    });

    test('capPeerKnowledge lowers only that device in that group, in every '
        'peer row (DATA-R3-01)', () async {
      await store.recordPeerKnowledge(dB, gA, VersionVector({dA: 90, dB: 5}));
      await store.recordPeerKnowledge(dC, gA, VersionVector({dA: 70, dC: 4}));
      await store.recordPeerKnowledge(dB, gB, VersionVector({dA: 80}));
      expect(await store.capPeerKnowledge(gA, dA, 6), isTrue);
      expect(await store.peerKnowledge(gA),
          VersionVector({dA: 6, dB: 5, dC: 4}));
      expect(await store.peerKnowledge(gB), VersionVector({dA: 80}));
      // Never raises, and reports no change when nothing is above the cap.
      expect(await store.capPeerKnowledge(gA, dA, 50), isFalse);
      expect((await store.peerKnowledge(gA))[dA], 6);
      expect(await store.capPeerKnowledge(gA, dC, 1), isTrue);
      expect((await store.peerKnowledge(gA))[dC], 1);
      // Later honest reports merge as before.
      await store.recordPeerKnowledge(dC, gA, VersionVector({dA: 7}));
      expect((await store.peerKnowledge(gA))[dA], 7);
    });

    test('kv: get, overwrite, null deletes', () async {
      expect(await store.getKv('k'), isNull);
      await store.setKv('k', 'v1');
      await store.setKv('k', 'v2');
      await store.setKv('other', '');
      expect(await store.getKv('k'), 'v2');
      expect(await store.getKv('other'), '');
      await store.setKv('k', null);
      await store.setKv('never', null);
      expect(await store.getKv('k'), isNull);
    });

    test('sync records: newest first, limit, replace by id, fields kept',
        () async {
      await store.addSyncRecord(record('r1', kBaseMs, groups: [gA, gB]));
      await store.addSyncRecord(record('r3', kBaseMs + 2000));
      await store.addSyncRecord(record('r2', kBaseMs + 1000));
      expect([for (final r in await store.syncRecords()) r.id],
          ['r3', 'r2', 'r1']);
      expect([for (final r in await store.syncRecords(limit: 2)) r.id],
          ['r3', 'r2']);
      expect(await store.syncRecords(limit: 0), isEmpty);
      await store.addSyncRecord(record('r1', kBaseMs + 3000));
      final all = await store.syncRecords();
      expect([for (final r in all) r.id], ['r1', 'r3', 'r2']);
      final r = (await store.syncRecords()).last;
      expect(r.peerDeviceId, dB);
      expect(r.peerName, 'Pixel 8');
      expect(r.transport, TransportKind.ble);
      expect(r.startedAt, utcFromMillis(kBaseMs + 1000));
      expect(r.endedAt, utcFromMillis(kBaseMs + 2500));
      expect(r.sentOps, 3);
      expect(r.receivedOps, 4);
      expect(r.outcome, SyncOutcome.partial);
      expect(r.error, 'dropped');
      expect(all.first.groupIds, isEmpty);
    });

    test('purgeGroup removes only that group', () async {
      await store.insertAll([rawOp(gA, dA, 1), rawOp(gA, dB, 1), rawOp(gB, dA, 1)]);
      await store.recordPeerKnowledge(dB, gA, VersionVector({dA: 1}));
      await store.recordPeerKnowledge(dB, gB, VersionVector({dA: 1}));
      await store.setKv(KvKeys.pending(gA), 'Goa');
      await store.setKv('profile', '{}');
      await store.purgeGroup(gA);
      expect([for (final o in await store.loadAll()) o.groupId], [gB]);
      expect(await store.versionVector(gA), VersionVector.empty);
      expect(await store.maxCounter(gA, dA), 0);
      expect(await store.peerKnowledge(gA), VersionVector.empty);
      expect(await store.peerKnowledge(gB), VersionVector({dA: 1}));
      expect(await store.getKv(KvKeys.pending(gA)), isNull);
      expect(await store.getKv('profile'), '{}');
      // The group can be re-received from scratch.
      expect(await store.insertAll([rawOp(gA, dA, 1)]), hasLength(1));
      expect(await store.versionVector(gA), VersionVector({dA: 1}));
    });
  });
}

void sqliteOnly() {
  group('SqliteOpStore file', () {
    late Directory dir;
    late String path;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('settle_up_store_');
      path = p.join(dir.path, 'settle_up.db');
    });

    tearDown(() => dir.deleteSync(recursive: true));

    test('data survives close and reopen', () async {
      final a = SqliteOpStore(path);
      await a.open();
      await a.insertAll([rawOp(gA, dA, 1), rawOp(gA, dA, 3)]);
      await a.setKv('k', 'v');
      await a.recordPeerKnowledge(dB, gA, VersionVector({dA: 1}));
      await a.addSyncRecord(record('r1', kBaseMs));
      await a.close();

      final b = SqliteOpStore(path);
      await b.open();
      expect(await b.loadAll(), hasLength(2));
      expect(await b.versionVector(gA), VersionVector({dA: 1}));
      expect(await b.getKv('k'), 'v');
      expect(await b.peerKnowledge(gA), VersionVector({dA: 1}));
      expect(await b.syncRecords(), hasLength(1));
      await b.close();
    });

    test('schema: user_version 1, WAL, the SPEC 7.5 tables', () async {
      final s = SqliteOpStore(path);
      await s.open();
      await s.close();
      final db = sqlite3.open(path);
      addTearDown(db.close);
      expect(db.userVersion, kStoreSchemaVersion);
      expect(db.select('PRAGMA journal_mode').first.columnAt(0), 'wal');
      final tables = {
        for (final r in db.select(
            "SELECT name FROM sqlite_master WHERE type IN ('table', 'index')"))
          r.columnAt(0) as String,
      };
      expect(tables,
          containsAll(['ops', 'ops_group_hlc', 'vv', 'peer_vv', 'kv', 'sync_records']));
      final row = db.select("PRAGMA table_info('ops')");
      expect([for (final r in row) r['name']], [
        'op_id',
        'group_id',
        'device_id',
        'counter',
        'hlc',
        'schema_ver',
        'json',
        'received_at',
      ]);
    });

    test('stores the verbatim op JSON and local received_at', () async {
      final s = SqliteOpStore(path, nowMillis: () => 42);
      await s.open();
      final op = rawOp(gA, dA, 1);
      await s.insertAll([op]);
      await s.close();
      final db = sqlite3.open(path);
      addTearDown(db.close);
      final r = db.select('SELECT * FROM ops').single;
      expect(r['json'], jsonEncode(op.toJson()));
      expect(r['received_at'], 42);
      expect(r['hlc'], op.hlc.encode());
      expect(r['schema_ver'], 1);
    });

    test('a file from a newer app version is refused', () async {
      final db = sqlite3.open(path)..userVersion = kStoreSchemaVersion + 1;
      db.close();
      final s = SqliteOpStore(path);
      await expectLater(s.open(), throwsStateError);
    });

    test('an unreadable stored row is skipped, not fatal', () async {
      final s = SqliteOpStore(path);
      await s.open();
      await s.insertAll([rawOp(gA, dA, 1), rawOp(gA, dA, 2)]);
      await s.close();
      final db = sqlite3.open(path);
      db.execute("UPDATE ops SET json = '{broken' WHERE counter = 2");
      db.close();
      await s.open();
      expect(await s.loadAll(), hasLength(1));
      expect(await s.missingFor(gA, VersionVector.empty), hasLength(1));
      await s.close();
    });

    test('a failed batch rolls back completely', () async {
      final s = SqliteOpStore(path);
      await s.open();
      await s.insertAll([rawOp(gA, dA, 1)]);
      final bad = Operation(
        id: 'bad',
        groupId: gA,
        deviceId: dA,
        counter: 3,
        hlc: const Hlc(kBaseMs, 0, dA),
        entityType: EntityType.member,
        entityId: 'm',
        kind: OpKind.update,
        payload: {'x': Object()},
      );
      await expectLater(
          s.insertAll([rawOp(gA, dA, 2), bad]), throwsA(anything));
      expect(await s.loadAll(), hasLength(1));
      expect(await s.versionVector(gA), VersionVector({dA: 1}));
      await s.close();
    });

    test('calls before open throw StateError', () async {
      final s = SqliteOpStore(path);
      await expectLater(s.loadAll(), throwsStateError);
    });
  });
}
