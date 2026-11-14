// QA DATA round 39: final regression sweep of the durability charter on the
// integrated build (no data-layer change since round 34).
//
// Probes the riskiest paths again in combinations the earlier rounds did
// not use: a burst of queued commands over several groups with a failed
// write in the middle, then an unclean relaunch; a deleted group across
// restarts while a peer acks it in two steps; and a newer file that is not in
// WAL mode.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/schema.dart';
import 'package:settle_up/data/sqlite_op_store.dart';
import 'package:sqlite3/sqlite3.dart';

import 'durability_restart_test.dart' show expectSameSnapshot;
import 'qa_data_harness.dart';

const DeviceId peerB = 'bbbbbbbb-0000-7000-8000-0000000000b9';

void main() {
  late Directory dir;
  setUp(() {
    resetKeystore();
    dir = qaTempDir();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  void expectContiguous(FilePhone p, GroupId g, String at) {
    final cs = [for (final o in p.mineIn(g)) o.counter];
    expect(cs, [for (var i = 1; i <= cs.length; i++) i], reason: at);
  }

  void expectHlcAscending(List<Hlc> stamps, String at) {
    for (var i = 1; i < stamps.length; i++) {
      expect(
        stamps[i] > stamps[i - 1],
        isTrue,
        reason: '$at: ${stamps[i - 1]} then ${stamps[i]}',
      );
    }
  }

  test('a burst of 40 queued commands over 4 groups with a failed write in '
      'the middle: one LedgerException, no burned counter, the rest land, '
      'and an unclean relaunch replays the same ledger', () async {
    _NthInsertFails? faulty;
    final a = FilePhone(dir)..wrap = (s) => faulty = _NthInsertFails(s);
    await a.launch();
    await a.settings.completeOnboarding(
      displayName: 'Alex',
      homeCurrency: 'INR',
    );
    final trips = [
      for (var i = 0; i < 4; i++) await qaTrip(a, name: 'Group $i'),
    ];
    final before = {for (final t in trips) t.g: a.mineIn(t.g).length};

    // Queue everything without awaiting; the 13th of them fails to store.
    faulty!.failAt = faulty!.insertCalls + 13;
    final results = <Future<Object?>>[];
    for (var i = 0; i < 40; i++) {
      final t = trips[i % 4];
      results.add(
        a.ledger
            .addExpense(
              qaDraft(
                t.g,
                [t.me, t.sam, t.priya],
                description: 'Item $i',
                total: 1000 + i,
              ),
            )
            .then<Object?>((id) => id, onError: (Object e) => e),
      );
    }
    final out = await Future.wait(results);
    final errors = [
      for (final r in out)
        if (r is LedgerException) r,
    ];
    expect(errors, hasLength(1), reason: 'exactly the one failed write');
    expect(errors.single.code, LedgerErrorCode.storageFailed);
    expect(out.indexOf(errors.single), 12, reason: 'the 13th command');
    expect(out.whereType<String>().length, 39);

    var total = 0;
    for (final t in trips) {
      expectContiguous(a, t.g, 'live');
      total += a.mineIn(t.g).length - before[t.g]!;
    }
    expect(total, 39);
    expectHlcAscending([
      for (final o in a.snap.ops)
        if (o.deviceId == a.deviceId) o.hlc,
    ], 'own stamps');
    final live = a.snap;
    final liveHlc = live.ops.last.hlc;

    // Unclean: drop the objects without closing anything.
    final b = FilePhone(dir);
    await b.launch();
    addTearDown(b.close);
    expectSameSnapshot(b.snap, live);
    expect(b.deviceId, a.deviceId);
    for (final t in trips) {
      expectContiguous(b, t.g, 'relaunched');
    }
    final e = await b.ledger.addExpense(
      qaDraft(trips[0].g, [trips[0].me, trips[0].sam], description: 'After'),
    );
    final op = b.snap.ops.lastWhere((o) => o.entityId == e);
    expect(op.hlc > liveHlc, isTrue, reason: 'clock never goes back');
    expect(op.counter, a.mineIn(trips[0].g).last.counter + 1);
    expectContiguous(b, trips[0].g, 'after relaunch edit');
  });

  test(
    'a deleted group with unshared edits: deleted, counted and '
    'contiguous across two restarts while a peer acks it in two steps',
    () async {
      final a = await FilePhone(dir).launch();
      await a.settings.completeOnboarding(
        displayName: 'Alex',
        homeCurrency: 'INR',
      );
      final t = await qaTrip(a);
      final other = await qaTrip(a, name: 'Flat');
      await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      final mine = a.mineIn(t.g).length;
      await a.ledger.recordPeerKnowledge(
        peerB,
        t.g,
        VersionVector({a.deviceId: mine}),
      );
      expect(a.snap.unsharedCounts[t.g], isNull);
      await a.ledger.deleteGroup(t.g);
      expect(a.snap.unsharedCounts[t.g], 1, reason: 'the delete is unshared');
      final live = a.snap;

      await a.restart();
      expectSameSnapshot(a.snap, live);
      expect(a.snap.state.groups[t.g]!.group!.isDeleted, isTrue);
      expectContiguous(a, t.g, 'after restart 1');

      // What sync would offer the peer, then the peer acks the delete.
      final peerOps = await a.store.missingFor(t.g, VersionVector({}));
      expect(peerOps.length, mine + 1);
      await a.ledger.recordPeerKnowledge(
        peerB,
        t.g,
        VersionVector({a.deviceId: mine + 1}),
      );
      expect(a.snap.unsharedCounts[t.g], isNull, reason: 'delete acked');
      await a.ledger.addExpense(qaDraft(other.g, [other.me, other.sam]));
      final live2 = a.snap;
      await a.restart();
      expectSameSnapshot(a.snap, live2);
      expect(a.snap.unsharedCounts, live2.unsharedCounts);
      expect(a.snap.unsharedCounts[t.g], isNull);
      expectContiguous(a, t.g, 'after restart 2');
      expectContiguous(a, other.g, 'other group');
      // The deleted group refuses new local edits instead of writing ops.
      await expectLater(
        a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam])),
        throwsA(isA<LedgerException>()),
      );
      expect(a.mineIn(t.g).length, mine + 1, reason: 'no counter burned');
    },
  );

  test(
    'a newer file (user_version 2) in rollback-journal mode is refused '
    'with its rows intact, and a second open attempt is refused the same '
    'way (printed: whether the failed open changed its journal mode)',
    () async {
      final path = '${dir.path}/settle_up.db';
      final s = SqliteOpStore(path);
      await s.open();
      await s.setKv(KvKeys.profile, '{"keep":1}');
      await s.close();
      final db = sqlite3.open(path)
        ..execute('PRAGMA journal_mode = DELETE')
        ..userVersion = 2;
      db.close();

      for (var attempt = 0; attempt < 2; attempt++) {
        final again = SqliteOpStore(path);
        await expectLater(again.open(), throwsA(isA<SchemaTooNewError>()));
      }
      final check = sqlite3.open(path);
      addTearDown(check.close);
      expect(check.userVersion, 2);
      expect(
        check
            .select("SELECT value FROM kv WHERE key = 'profile'")
            .single
            .columnAt(0),
        '{"keep":1}',
      );
      final mode = check.select('PRAGMA journal_mode').single.columnAt(0);
      // ignore: avoid_print
      print('[r39] journal mode of the refused newer file: $mode');
    },
  );
}

/// Delegates to SQLite and throws on the [failAt]-th insertAll (1-based,
/// before anything is written), like a full disk for one write.
final class _NthInsertFails implements OpStore {
  _NthInsertFails(this.inner);
  final OpStore inner;
  int insertCalls = 0;
  int failAt = -1;

  @override
  Future<List<Operation>> insertAll(List<Operation> ops) async {
    if (++insertCalls == failAt) {
      throw const FileSystemException('disk I/O error (SQLITE_FULL)');
    }
    return inner.insertAll(ops);
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
    DeviceId peer,
    GroupId groupId,
    VersionVector vv,
  ) => inner.recordPeerKnowledge(peer, groupId, vv);
  @override
  Future<String?> getKv(String key) => inner.getKv(key);
  @override
  Future<void> setKv(String key, String? value) => inner.setKv(key, value);
  @override
  Future<void> addSyncRecord(SyncRecord record) => inner.addSyncRecord(record);
  @override
  Future<List<SyncRecord>> syncRecords({int limit = 50}) =>
      inner.syncRecords(limit: limit);
}
