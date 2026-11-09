// QA DATA-R2: reverification of the round-1 data fixes, the cases next to
// them, and a regression sweep of the code they changed.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
// Transitive dependency of path_provider; test-only mock of the platform.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:settle_up/bootstrap.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/schema.dart';
import 'package:settle_up/data/secure_group_key_store.dart';
import 'package:settle_up/data/sqlite_op_store.dart';
import 'package:settle_up/ui/screens/common.dart' show errorMessage;
import 'package:settle_up/ui/screens/startup/startup_error_screen.dart';
import 'package:settle_up/ui/startup.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:sqlite3/sqlite3.dart';

import 'qa_data_harness.dart';

const DeviceId peerB = 'bbbbbbbb-0000-7000-8000-0000000000b1';

Operation remoteRename(GroupId g, MemberId m, int counter, String name,
        {int at = kQaBaseMs + 60000}) =>
    Operation(
      id: 'r2-remote-$counter',
      groupId: g,
      deviceId: peerB,
      counter: counter,
      hlc: Hlc(at + counter, 0, peerB),
      entityType: EntityType.member,
      entityId: m,
      kind: OpKind.update,
      payload: {MemberFields.displayName: name},
    );

final class _FakePaths extends PathProviderPlatform {
  _FakePaths(this.dir);
  final String dir;
  @override
  Future<String?> getApplicationSupportPath() async => dir;
  @override
  Future<String?> getApplicationDocumentsPath() async => dir;
  @override
  Future<String?> getTemporaryPath() async => dir;
}

void main() {
  late FilePhone a;
  late Trip t;

  setUp(() async {
    resetKeystore();
    a = FilePhone(qaTempDir());
    await a.launch();
    await a.settings
        .completeOnboarding(displayName: 'Alex', homeCurrency: 'INR');
    t = await qaTrip(a);
  });

  tearDown(() async {
    try {
      await a.close();
    } catch (_) {}
    a.dir.deleteSync(recursive: true);
  });

  /// Edits the file directly while the app is "not running".
  Future<void> tamper(void Function(Database db) edit,
      {bool relaunch = true}) async {
    await a.close();
    final db = sqlite3.open(a.path);
    try {
      edit(db);
    } finally {
      db.close();
    }
    if (relaunch) await a.launch();
  }

  List<int> myCounters(GroupId g) =>
      a.mineIn(g).map((o) => o.counter).toList();

  group('DATA-R1-01 neighbours (counters after corrupt own rows)', () {
    test('my two newest rows corrupt: the next op takes counter 7 and lands',
        () async {
      await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam], total: 100));
      final mine = a.mineIn(t.g);
      expect(mine.last.counter, 6);
      await tamper((db) {
        for (final op in mine.sublist(4)) {
          db.execute("UPDATE ops SET json = '{x' WHERE op_id = ?", [op.id]);
        }
      });
      expect(myCounters(t.g).last, 4);
      final e = await a.ledger
          .addExpense(qaDraft(t.g, [t.me], description: 'Taxi', total: 700));
      expect(a.snap.state.expense(e), isNotNull);
      expect(myCounters(t.g).last, 7);
      await a.restart();
      expect(a.snap.state.expense(e), isNotNull);
      expect(myCounters(t.g).last, 7);
    });

    test('an update command (rename) after a corrupt newest row lands',
        () async {
      await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      final last = a.mineIn(t.g).last;
      await tamper((db) => db.execute(
          "UPDATE ops SET json = '{x' WHERE op_id = ?", [last.id]));
      await a.ledger.renameMember(t.g, t.sam, 'Samir');
      expect(a.group(t.g).members[t.sam]!.displayName, 'Samir');
      await a.restart();
      expect(a.group(t.g).members[t.sam]!.displayName, 'Samir');
      expect(myCounters(t.g).last, 6);
    });

    test('every row of a group corrupt, key present: startup survives, the '
        'key is kept (vv still knows the group) and other groups work',
        () async {
      final g2 = (await qaTrip(a, name: 'Flat')).g;
      final ids = a.opsOf(g2).map((o) => o.id).toList();
      await tamper((db) {
        for (final id in ids) {
          db.execute("UPDATE ops SET json = '{x' WHERE op_id = ?", [id]);
        }
      });
      expect(a.snap.state.groups[g2]?.group, isNull);
      expect(await a.keys.keyFor(g2), isNotNull,
          reason: 'the key of a group with stored rows must not be dropped');
      final e = await a.ledger.addExpense(qaDraft(t.g, [t.me]));
      expect(a.snap.state.expense(e), isNotNull);
    });

    test('a counter taken on disk behind the ledger\'s back: the command '
        'throws storageFailed (no phantom id) and the next one lands',
        () async {
      // Another writer (e.g. a restored copy) takes my next counter while
      // the app runs.
      final next = myCounters(t.g).last + 1;
      final other = sqlite3.open(a.path);
      try {
        other.execute(
          'INSERT INTO ops(op_id, group_id, device_id, counter, hlc, '
          'schema_ver, json, received_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          [
            'intruder',
            t.g,
            a.deviceId,
            next,
            Hlc(kQaBaseMs, 0, a.deviceId).encode(),
            1,
            '{x',
            kQaBaseMs,
          ],
        );
      } finally {
        other.close();
      }
      final before = a.snap;
      await expectLater(
        a.ledger.addExpense(qaDraft(t.g, [t.me])),
        throwsA(isA<LedgerException>()
            .having((e) => e.code, 'code', LedgerErrorCode.storageFailed)),
      );
      expect(a.snap.state.groups[t.g]!.expenses.length,
          before.state.groups[t.g]!.expenses.length);
      final e = await a.ledger.addExpense(qaDraft(t.g, [t.me], total: 300));
      expect(a.snap.state.expense(e), isNotNull);
      expect(myCounters(t.g).last, next + 1);
    });
  });

  group('DATA-R1-04 neighbours (bookkeeping after a stored op)', () {
    test('hlc.last save failing after applyRemote stored ops does not throw',
        () async {
      a.wrap = (s) => FaultyStore(s);
      await a.restart();
      (a.store as FaultyStore).failNextSetKvKey = KvKeys.hlcLast;
      final added = await a.ledger
          .applyRemote(t.g, [remoteRename(t.g, t.sam, 1, 'Sam B')]);
      expect(added, hasLength(1));
      expect(a.group(t.g).members[t.sam]!.displayName, 'Sam B');
    });

    test('after a failed clock save and a restart the clock does not go '
        'backwards behind my own ops', () async {
      a.wrap = (s) => FaultyStore(s);
      await a.restart();
      (a.store as FaultyStore).failNextSetKvKey = KvKeys.hlcLast;
      a.clock.advance(3600 * 1000);
      await a.ledger.addExpense(qaDraft(t.g, [t.me]));
      final newest = a.mineIn(t.g).last.hlc;
      a.clock.now = kQaBaseMs; // phone clock jumps back
      await a.restart();
      await a.ledger.addExpense(qaDraft(t.g, [t.me], total: 200));
      expect(a.mineIn(t.g).last.hlc.compareTo(newest), greaterThan(0));
    });
  });

  group('DATA-R1-07 neighbours (storage failures are LedgerExceptions)', () {
    test('a SqliteException from insertAll is storageFailed and maps to the '
        'storage copy', () async {
      a.wrap = (s) => FaultyStore(s)
        ..error = SqliteException(
            extendedResultCode: 13, message: 'database or disk is full');
      await a.restart();
      (a.store as FaultyStore).failNextInsert = true;
      Object? caught;
      try {
        await a.ledger.addExpense(qaDraft(t.g, [t.me]));
      } catch (e) {
        caught = e;
      }
      expect(caught, isA<LedgerException>());
      expect(errorMessage(caught!), S.errStorage);
      final e = await a.ledger.addExpense(qaDraft(t.g, [t.me]));
      expect(a.snap.state.expense(e), isNotNull);
      expect(myCounters(t.g), [1, 2, 3, 4, 5]);
    });

    test('createGroup: insertAll failure is storageFailed and leaves no key '
        'and no group', () async {
      a.wrap = (s) => FaultyStore(s);
      await a.restart();
      final keysBefore = (await a.keys.all()).keys.toSet();
      (a.store as FaultyStore).failNextInsert = true;
      await expectLater(
        a.ledger.createGroup(const NewGroup(
            name: 'Cabin', type: GroupType.trip, currency: 'INR')),
        throwsA(isA<LedgerException>()
            .having((e) => e.code, 'code', LedgerErrorCode.storageFailed)),
      );
      expect((await a.keys.all()).keys.toSet(), keysBefore);
      await a.restart();
      expect(a.snap.pendingJoins, isEmpty);
    });
  });

  group('DATA-R1-03 neighbours (user_version 0)', () {
    test('user_version 0 with only the ops table: the rest is created and '
        'the ops are kept', () async {
      final n = a.snap.ops.length;
      await tamper((db) {
        db.execute('DROP TABLE sync_records');
        db.execute('DROP TABLE peer_vv');
        db.execute('PRAGMA user_version = 0');
      });
      expect(a.snap.ops, hasLength(n));
      final db = sqlite3.open(a.path);
      try {
        expect(db.userVersion, 1);
      } finally {
        db.close();
      }
    });
  });

  group('DATA-R1-05 / R1-06 neighbours (kv recovery)', () {
    test('profile row deleted (not corrupt): re-onboarding keeps my personId',
        () async {
      final old = a.settings.profile!.personId;
      await tamper((db) =>
          db.execute('DELETE FROM kv WHERE key = ?', [KvKeys.profile]));
      expect(a.settings.profile, isNull);
      final p = await a.settings
          .completeOnboarding(displayName: 'Alex', homeCurrency: 'INR');
      expect(p.personId, old);
    });

    test('profile AND device rows corrupt: device id from hlc.last, then the '
        'personId from my members', () async {
      final oldDevice = a.deviceId;
      final oldPerson = a.settings.profile!.personId;
      await tamper((db) {
        db.execute("UPDATE kv SET value = '{x' WHERE key = ?", [KvKeys.device]);
        db.execute(
            "UPDATE kv SET value = '{x' WHERE key = ?", [KvKeys.profile]);
      });
      expect(a.deviceId, oldDevice);
      final p = await a.settings
          .completeOnboarding(displayName: 'Alex', homeCurrency: 'INR');
      expect(p.personId, oldPerson);
      expect(a.snap.totalUnshared, 4);
    });

    test('device row with an empty deviceId keeps the old id', () async {
      final old = a.deviceId;
      await tamper((db) => db.execute(
          'UPDATE kv SET value = ? WHERE key = ?',
          ['{"deviceId": "", "deviceName": "Phone 1"}', KvKeys.device]));
      expect(a.deviceId, old);
      expect(a.settings.device.deviceName, 'Phone 1');
    });
  });

  group('DATA-R1-08 neighbours (which keys are orphans)', () {
    Future<void> relaunchWithKeys(Map<String, List<int>> extra,
        {Map<String, String> kv = const {}}) async {
      await a.close();
      final keys = await SecureGroupKeyStore().all();
      resetKeystore({
        for (final e in keys.entries) 'gk.${e.key}': base64Url.encode(e.value),
        for (final e in extra.entries) 'gk.${e.key}': base64Url.encode(e.value),
      });
      if (kv.isNotEmpty) {
        final db = sqlite3.open(a.path);
        try {
          kv.forEach((k, v) => db.execute(
              'INSERT INTO kv(key, value) VALUES (?, ?)', [k, v]));
        } finally {
          db.close();
        }
      }
      await a.launch();
    }

    const ghost = '00000000-0000-7000-9000-00000000r2g1';

    test('an invite join with an empty name hint stays a pending join',
        () async {
      await relaunchWithKeys({ghost: List.filled(32, 2)},
          kv: {KvKeys.pending(ghost): ''});
      expect(a.snap.pendingJoins, {ghost: ''});
      expect(await a.keys.keyFor(ghost), isNotNull);
    });

    test('a key whose group was purged (purged mark) is kept', () async {
      await relaunchWithKeys({ghost: List.filled(32, 3)},
          kv: {KvKeys.purged(ghost): '{"$peerB": 3}'});
      expect(await a.keys.keyFor(ghost), isNotNull);
    });

    test('the keys of real groups are never dropped across restarts',
        () async {
      final g2 = (await qaTrip(a, name: 'Flat')).g;
      await a.restart();
      await a.restart();
      expect(await a.keys.keyFor(t.g), isNotNull);
      expect(await a.keys.keyFor(g2), isNotNull);
      expect(a.snap.groupsWithoutKey, isEmpty);
    });
  });

  group('DATA-R1-02 neighbours (startup)', () {
    late Directory dir;
    late String path;

    setUp(() {
      dir = qaTempDir();
      path = '${dir.path}/settle_up.db';
      PathProviderPlatform.instance = _FakePaths(dir.path);
      FlutterSecureStorage.setMockInitialValues({});
    });
    tearDown(() => dir.deleteSync(recursive: true));

    StartupFailure? failureOf(List<Override> overrides) {
      final c = ProviderContainer(overrides: overrides);
      try {
        return c.read(startupFailureProvider);
      } finally {
        c.dispose();
      }
    }

    test('a newer file is reported, kept, and a retry after an update '
        'opens it (the failed attempt closed the store)', () async {
      final s = SqliteOpStore(path);
      await s.open();
      await s.setKv('marker', 'keep me');
      await s.close();
      final db = sqlite3.open(path);
      db.execute('PRAGMA user_version = 2');
      db.close();

      final first = await realOverrides();
      expect(first, hasLength(1));
      expect(failureOf(first), StartupFailure.tooNew);
      // Second attempt on the same file: still a failure, no lock error.
      expect(failureOf(await realOverrides()), StartupFailure.tooNew);

      // "The app was updated": the file is now readable by this schema.
      final db2 = sqlite3.open(path);
      db2.execute('PRAGMA user_version = 1');
      db2.close();
      final ok = await realOverrides();
      expect(ok, hasLength(3));
      final check = sqlite3.open(path);
      try {
        expect(
            check.select("SELECT value FROM kv WHERE key = 'marker'").single
                .columnAt(0),
            'keep me');
      } finally {
        check.close();
      }
    });

    test('a directory where the database file should be: failure screen, '
        'not a throw', () async {
      Directory(path).createSync();
      final overrides = await realOverrides();
      expect(overrides, hasLength(1));
      expect(failureOf(overrides), StartupFailure.database);
    });
  });

  group('regression sweep', () {
    test('DATA-R1-09 cache: unsharedEntityIds follows each new snapshot '
        '(no stale set after a command or a peer ack)', () async {
      final before = a.snap.unsharedEntityIds;
      expect(before, contains(t.g));
      final e = await a.ledger.addExpense(qaDraft(t.g, [t.me]));
      expect(a.snap.unsharedEntityIds, contains(e));
      expect(identical(a.snap.unsharedEntityIds, a.snap.unsharedEntityIds),
          isTrue);
      await a.ledger.recordPeerKnowledge(
          peerB, t.g, VersionVector({a.deviceId: myCounters(t.g).last}));
      expect(a.snap.unsharedEntityIds, isEmpty);
      expect(a.snap.totalUnshared, 0);
      await a.restart();
      expect(a.snap.unsharedEntityIds, isEmpty);
      expect(a.snap.totalUnshared, 0);
    });

    test(
      'a stale invite hint that cannot be cleared at open (full disk) does '
      'not stop the app from starting',
      () async {
        // The hint of a joined group outlived its arrival (clearing it after
        // the sync failed: "harmless, the next open drops it").
        await a.close();
        final db = sqlite3.open(a.path);
        try {
          db.execute('INSERT INTO kv(key, value) VALUES (?, ?)',
              [KvKeys.pending(t.g), 'Goa trip']);
        } finally {
          db.close();
        }
        a.wrap = (s) => FaultyStore(s)..failNextSetKvKey = KvKeys.pending(t.g);
        // Expected: Ledger.open logs and carries on (the hint is cleared on a
        // later open). Today the unguarded setKv in _load fails the whole
        // open, so the phone lands on the startup error screen.
        await expectLater(a.launch(), completes);
        expect(a.snap.state.groups[t.g]?.group, isNotNull);
      },
      skip: 'QA DATA-R2-01: Ledger._load clears a stale pending hint with an '
          'unguarded setKv, so a full disk fails startup',
    );
  });
}
