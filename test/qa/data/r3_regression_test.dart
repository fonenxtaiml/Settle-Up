// QA DATA-R3: reverification of the round-2 data fixes, the cases next to
// them, and a regression sweep of the code changed in round 2 (the clamp
// of peer knowledge of my own ops, SECURITY-R2-01).
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/schema.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/ui/screens/csv_share.dart';
import 'package:sqlite3/sqlite3.dart';

import 'qa_data_harness.dart';

const DeviceId peerB = 'bbbbbbbb-0000-7000-8000-0000000000b1';

/// A store on a full disk: every write throws, every read works. [full]
/// can be turned off to model the user freeing space.
final class FullDiskStore implements OpStore {
  FullDiskStore(this.inner);

  final OpStore inner;
  bool full = true;
  int refusedWrites = 0;

  static const Object error = FileSystemException(
    'database or disk is full (SQLITE_FULL)',
  );

  Never _refuse() {
    refusedWrites++;
    throw error;
  }

  @override
  Future<List<Operation>> insertAll(List<Operation> ops) async {
    if (full) _refuse();
    return inner.insertAll(ops);
  }

  @override
  Future<void> setKv(String key, String? value) async {
    if (full) _refuse();
    return inner.setKv(key, value);
  }

  @override
  Future<void> recordPeerKnowledge(
    DeviceId peer,
    GroupId groupId,
    VersionVector vv,
  ) async {
    if (full) _refuse();
    return inner.recordPeerKnowledge(peer, groupId, vv);
  }

  @override
  Future<void> addSyncRecord(SyncRecord record) async {
    if (full) _refuse();
    return inner.addSyncRecord(record);
  }

  @override
  Future<void> purgeGroup(GroupId groupId) async {
    if (full) _refuse();
    return inner.purgeGroup(groupId);
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
  Future<VersionVector> peerKnowledge(GroupId groupId) =>
      inner.peerKnowledge(groupId);
  @override
  Future<String?> getKv(String key) => inner.getKv(key);
  @override
  Future<List<SyncRecord>> syncRecords({int limit = 50}) =>
      inner.syncRecords(limit: limit);
}

/// True when [s] has no lone UTF-16 surrogate.
bool wellFormed(String s) => utf8.decode(utf8.encode(s)) == s;

void main() {
  late FilePhone a;
  late Trip t;

  setUp(() async {
    resetKeystore();
    a = FilePhone(qaTempDir());
    await a.launch();
    await a.settings.completeOnboarding(
      displayName: 'Alex',
      homeCurrency: 'INR',
    );
    t = await qaTrip(a);
  });

  tearDown(() async {
    try {
      await a.close();
    } catch (_) {}
    a.dir.deleteSync(recursive: true);
  });

  /// Edits the file directly while the app is "not running".
  Future<void> offline(void Function(Database db) edit) async {
    await a.close();
    final db = sqlite3.open(a.path);
    try {
      edit(db);
    } finally {
      db.close();
    }
  }

  String? kvOnDisk(String key) {
    final db = sqlite3.open(a.path);
    try {
      final rows = db.select('SELECT value FROM kv WHERE key = ?', [key]);
      return rows.isEmpty ? null : rows.first.columnAt(0) as String?;
    } finally {
      db.close();
    }
  }

  void plantHint(Database db, GroupId g, String hint) => db.execute(
    'INSERT INTO kv(key, value) VALUES (?, ?) '
    'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
    [KvKeys.pending(g), hint],
  );

  List<int> myCounters(GroupId g) => a.mineIn(g).map((o) => o.counter).toList();

  group('DATA-R2-01 reverify (stale hint at open on a full disk)', () {
    test('open survives, nothing is shown as a join, data is intact, and a '
        'later open clears the hint', () async {
      await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam, t.priya]));
      final before = a.snap.state.toCanonicalJson();
      await offline((db) => plantHint(db, t.g, 'Goa trip'));
      a.wrap = (s) => FaultyStore(s)..failNextSetKvKey = KvKeys.pending(t.g);
      await a.launch();
      expect(a.snap.state.toCanonicalJson(), before);
      expect(a.snap.pendingJoins, isEmpty);
      expect(a.snap.groupsWithoutKey, isEmpty);
      await a.close();
      expect(
        kvOnDisk(KvKeys.pending(t.g)),
        'Goa trip',
        reason: 'the failed clear left the hint',
      );
      a.wrap = null;
      await a.launch();
      await a.close();
      expect(
        kvOnDisk(KvKeys.pending(t.g)),
        isNull,
        reason: 'the next healthy open drops it',
      );
      await a.launch();
    });

    test('two stale hints, the first clear fails: the second is still '
        'cleared and both groups open normally', () async {
      final t2 = await qaTrip(a, name: 'Flat 4B');
      await offline((db) {
        plantHint(db, t.g, 'Goa trip');
        plantHint(db, t2.g, 'Flat 4B');
      });
      a.wrap = (s) => FaultyStore(s)..failNextSetKvKey = KvKeys.pending(t.g);
      await a.launch();
      expect(a.snap.pendingJoins, isEmpty);
      expect(a.group(t.g).group, isNotNull);
      expect(a.group(t2.g).group, isNotNull);
      await a.close();
      expect(kvOnDisk(KvKeys.pending(t2.g)), isNull);
      expect(kvOnDisk(KvKeys.pending(t.g)), 'Goa trip');
      a.wrap = null;
      await a.launch();
    });

    test('full disk (every write fails): the whole start works read-only, '
        'commands fail cleanly, and work again once space is freed', () async {
      await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      await a.ledger.recordPeerKnowledge(
        peerB,
        t.g,
        VersionVector({a.deviceId: 1}),
      );
      final orphan = await qaTrip(a, name: 'Flat 4B');
      final before = a.snap;
      final counters = myCounters(t.g);
      await offline((db) => plantHint(db, t.g, 'Goa trip'));
      late FullDiskStore disk;
      a.wrap = (s) => disk = FullDiskStore(s);
      await expectLater(a.launch(), completes);
      expect(a.snap.state.toCanonicalJson(), before.state.toCanonicalJson());
      expect(a.snap.unsharedCounts, before.unsharedCounts);
      expect(a.snap.pendingJoins, isEmpty);
      expect(a.deviceId, before.localDeviceId);
      expect(a.group(orphan.g).group, isNotNull);

      await expectLater(
        a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam], description: 'Taxi')),
        throwsA(
          isA<LedgerException>().having(
            (e) => e.code,
            'code',
            LedgerErrorCode.storageFailed,
          ),
        ),
      );
      expect(a.snap.state.toCanonicalJson(), before.state.toCanonicalJson());
      expect(myCounters(t.g), counters);

      disk.full = false;
      await a.ledger.addExpense(
        qaDraft(t.g, [t.me, t.sam], description: 'Taxi'),
      );
      expect(myCounters(t.g), [
        ...counters,
        counters.last + 1,
      ], reason: 'no counter burned by the refused write');
      await a.restart();
      expect(myCounters(t.g), [...counters, counters.last + 1]);
    });
  });

  group('SECURITY-R2-01 clamp, regression sweep (unshared counts)', () {
    test(
      'honest ack, edit, restart: unshared counts survive exactly',
      () async {
        await a.ledger.recordPeerKnowledge(
          peerB,
          t.g,
          VersionVector({a.deviceId: myCounters(t.g).last}),
        );
        expect(a.snap.unsharedCounts[t.g], isNull);
        await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
        expect(a.snap.unsharedCounts[t.g], 1);
        expect(a.snap.totalUnshared, 1);
        await a.restart();
        expect(a.snap.unsharedCounts[t.g], 1);
        expect(a.snap.totalUnshared, 1);
      },
    );

    test('a report up to my corrupt newest row counts it as written', () async {
      await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      final last = myCounters(t.g).last;
      await offline(
        (db) => db.execute(
          'UPDATE ops SET json = ? WHERE group_id = ? AND device_id = ? '
          'AND counter = ?',
          ['{not json', t.g, a.deviceId, last],
        ),
      );
      await a.launch();
      await a.ledger.recordPeerKnowledge(
        peerB,
        t.g,
        VersionVector({a.deviceId: last}),
      );
      expect(a.snap.unsharedCounts[t.g], isNull);
      expect((await a.store.peerKnowledge(t.g))[a.deviceId], last);
      await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      expect(myCounters(t.g).last, last + 1);
      expect(a.snap.unsharedCounts[t.g], 1);
    });

    test(
      'DATA-R3-01: a forged peer row already on disk hides edits made after '
      'the open once the app restarts',
      () async {
        final written = myCounters(t.g).last;
        // A row stored before the SECURITY-R2-01 clamp (an earlier build on
        // the test phone, or a hostile peer then).
        await offline(
          (db) => db.execute(
            'INSERT INTO peer_vv(peer_id, group_id, device_id, max_counter) '
            'VALUES (?, ?, ?, ?)',
            [peerB, t.g, a.deviceId, TextRules.maxCounter],
          ),
        );
        await a.launch();
        expect(a.snap.unsharedCounts[t.g], isNull);
        await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
        expect(a.snap.unsharedCounts[t.g], 1, reason: 'clamped in memory');
        expect(myCounters(t.g).last, written + 1);
        await a.restart();
        // Expected: still 1 (no phone holds the new expense). Actual: the
        // open clamps the stored row to what I have written NOW
        // (written + 1), so the new expense shows as shared and the
        // "not shared yet" marker and count disappear.
        expect(a.snap.unsharedCounts[t.g], 1);
        expect(a.snap.totalUnshared, 1);
      },
      skip:
          'DATA-R3-01: the forged row on disk is clamped in memory only; '
          'every later open re-clamps it to the current own counter',
    );
  });

  group('DATA-R2-02 neighbours (other text cut by UTF-16 units)', () {
    test(
      'DATA-R3-02: the CSV file name cut at 80 units keeps whole characters',
      () {
        // 60 characters, the group name limit; the CJK Extension B letters
        // are 2 UTF-16 units each, so the name is 101 units.
        final name = 'a${'\u{20000}' * 50}${'b' * 9}';
        expect(TextRules.length(name), 60);
        final file = csvFileName(name);
        // Expected: a well-formed name ending on a character boundary.
        // Actual: base.substring(0, 80) ends in a lone high surrogate, which
        // the platform channel turns into U+FFFD in the shared file's name.
        expect(wellFormed(file), isTrue, reason: file);
      },
    );

    test('CSV file names of BMP scripts (<= 60 units) are never cut', () {
      final hindi = 'क्ष' * 20;
      expect(TextRules.length(hindi), 20);
      expect(csvFileName(hindi), '$hindi.csv');
    });
  });
}
