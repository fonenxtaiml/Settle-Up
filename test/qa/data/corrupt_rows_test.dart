// QA DATA-R1: corrupted rows in the SQLite file. Startup must survive, the
// bad row is skipped (and logged), every other row stays intact, and later
// commands still behave.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/schema.dart';
import 'package:sqlite3/sqlite3.dart';

import 'qa_data_harness.dart';

const DeviceId peerB = 'bbbbbbbb-0000-7000-8000-0000000000b1';

Operation remoteRename(GroupId g, MemberId m, int counter, String name) =>
    Operation(
      id: 'remote-$counter',
      groupId: g,
      deviceId: peerB,
      counter: counter,
      hlc: Hlc(kQaBaseMs + 60000 + counter, 0, peerB),
      entityType: EntityType.member,
      entityId: m,
      kind: OpKind.update,
      payload: {MemberFields.displayName: name},
    );

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
  Future<void> tamper(void Function(Database db) edit) async {
    await a.close();
    final db = sqlite3.open(a.path);
    try {
      edit(db);
    } finally {
      db.close();
    }
    await a.launch();
  }

  Map<String, Object?> jsonOf(Database db, String opId) => Map.of(jsonDecode(
          db.select('SELECT json FROM ops WHERE op_id = ?', [opId]).single
              .columnAt(0) as String)
      as Map<String, Object?>);

  group('ops.json', () {
    late List<Operation> remote;

    setUp(() async {
      remote = [
        remoteRename(t.g, t.sam, 1, 'Sam 1'),
        remoteRename(t.g, t.priya, 2, 'Priya 2'),
        remoteRename(t.g, t.sam, 3, 'Sam 3'),
      ];
      expect(await a.ledger.applyRemote(t.g, remote), hasLength(3));
      await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
    });

    test('invalid JSON: row skipped, startup survives, others intact',
        () async {
      await tamper((db) => db.execute(
          "UPDATE ops SET json = '{not json' WHERE op_id = 'remote-3'"));
      expect(a.snap.ops.map((o) => o.id), isNot(contains('remote-3')));
      expect(a.snap.ops, hasLength(4 + 1 + 2));
      expect(a.group(t.g).members[t.sam]!.displayName, 'Sam 1');
      expect(a.group(t.g).members[t.priya]!.displayName, 'Priya 2');
      expect(a.group(t.g).liveExpenses, hasLength(1));
      // The app still writes.
      await a.ledger.renameMember(t.g, t.priya, 'P');
      expect(a.group(t.g).members[t.priya]!.displayName, 'P');
    });

    test('unknown entity type in a current-schema op is skipped', () async {
      await tamper((db) {
        final j = jsonOf(db, 'remote-2')..['entityType'] = 'spaceship';
        db.execute("UPDATE ops SET json = ? WHERE op_id = 'remote-2'",
            [jsonEncode(j)]);
      });
      expect(a.snap.ops.map((o) => o.id), isNot(contains('remote-2')));
      expect(a.group(t.g).members[t.priya]!.displayName, 'Priya');
      expect(a.group(t.g).members[t.sam]!.displayName, 'Sam 3');
    });

    test('unknown entity type in a newer-schema op is kept for relay, '
        'not applied', () async {
      await tamper((db) {
        final j = jsonOf(db, 'remote-2')
          ..['entityType'] = 'spaceship'
          ..['schemaVersion'] = 2;
        db.execute("UPDATE ops SET json = ? WHERE op_id = 'remote-2'",
            [jsonEncode(j)]);
      });
      final op = a.snap.ops.firstWhere((o) => o.id == 'remote-2');
      expect(op.isFromNewerSchema, isTrue);
      expect(a.group(t.g).members[t.priya]!.displayName, 'Priya');
    });

    for (final field in [
      'id',
      'groupId',
      'deviceId',
      'counter',
      'hlc',
      'entityId',
      'payload',
      'kind',
    ]) {
      test('missing "$field" in a stored op is skipped', () async {
        await tamper((db) {
          final j = jsonOf(db, 'remote-3')..remove(field);
          db.execute("UPDATE ops SET json = ? WHERE op_id = 'remote-3'",
              [jsonEncode(j)]);
        });
        expect(a.snap.ops.map((o) => o.id), isNot(contains('remote-3')));
        expect(a.group(t.g).members[t.sam]!.displayName, 'Sam 1');
        expect(a.snap.ops, hasLength(7));
      });
    }

    test('wrong JSON types (counter as string, payload as list) skipped',
        () async {
      await tamper((db) {
        final j1 = jsonOf(db, 'remote-1')..['counter'] = '1';
        final j3 = jsonOf(db, 'remote-3')..['payload'] = [1, 2];
        db.execute("UPDATE ops SET json = ? WHERE op_id = 'remote-1'",
            [jsonEncode(j1)]);
        db.execute("UPDATE ops SET json = ? WHERE op_id = 'remote-3'",
            [jsonEncode(j3)]);
      });
      expect(a.snap.ops, hasLength(6));
      expect(a.group(t.g).members[t.sam]!.displayName, 'Sam');
    });

    test('JSON that is valid but not an object (array, null, number)',
        () async {
      await tamper((db) {
        db.execute("UPDATE ops SET json = '[]' WHERE op_id = 'remote-1'");
        db.execute("UPDATE ops SET json = 'null' WHERE op_id = 'remote-2'");
        db.execute("UPDATE ops SET json = '42' WHERE op_id = 'remote-3'");
      });
      expect(a.snap.ops, hasLength(5));
      expect(a.group(t.g).members[t.sam]!.displayName, 'Sam');
    });

    test('an expense whose money block is garbage is hidden, balances of '
        'the rest are intact', () async {
      final good = a.group(t.g).liveExpenses.single;
      final bad = Operation(
        id: 'remote-bad-money',
        groupId: t.g,
        deviceId: peerB,
        counter: 4,
        hlc: Hlc(kQaBaseMs + 90000, 0, peerB),
        entityType: EntityType.expense,
        entityId: 'exp-bad',
        kind: OpKind.create,
        payload: {
          ExpenseFields.kind: 'expense',
          ExpenseFields.description: 'Broken',
          ExpenseFields.category: 'general',
          ExpenseFields.date: kQaBaseMs,
          ExpenseFields.notes: '',
          ExpenseFields.money: {'total': 'lots', 'paid': 3},
          ExpenseFields.createdBy: t.sam,
          ExpenseFields.createdAt: kQaBaseMs,
        },
      );
      // A peer's op like this is refused at the door (SECURITY-R3-01)...
      await expectLater(
          a.ledger.applyRemote(t.g, [bad]), throwsFormatException);
      expect(a.snap.ops.map((o) => o.id), isNot(contains('remote-bad-money')));
      // ...but a row an older build already stored must still be survived.
      await a.sqlite.insertAll([bad]);
      await a.restart();
      expect(a.group(t.g).liveExpenses.map((e) => e.id), [good.id]);
      expect(a.snap.ops.map((o) => o.id), contains('remote-bad-money'));
    });

    test(
      'a corrupt row holding MY latest op does not make the next command '
      'reuse its counter and silently drop the new expense',
      () async {
        final mine = a.mineIn(t.g);
        expect(mine.last.counter, 5); // the expense
        await tamper((db) => db.execute(
            "UPDATE ops SET json = '{broken' WHERE op_id = ?",
            [mine.last.id]));
        final e = await a.ledger.addExpense(
            qaDraft(t.g, [t.me, t.sam], description: 'Taxi', total: 700));
        // Expected: the command either lands or throws. Today it returns
        // an id for an expense that does not exist anywhere.
        expect(a.snap.state.expense(e), isNotNull,
            reason: 'addExpense returned $e but the expense was not stored');
        final counters = a.mineIn(t.g).map((o) => o.counter).toList();
        expect(counters.toSet().length, counters.length);
        await a.restart();
        expect(a.snap.state.expense(e), isNotNull);
      },
    );

    test('a corrupt row in the middle of my ops does not cause reuse',
        () async {
      final mine = a.mineIn(t.g);
      await tamper((db) => db.execute(
          "UPDATE ops SET json = '{broken' WHERE op_id = ?", [mine[2].id]));
      final e = await a.ledger.addExpense(qaDraft(t.g, [t.me]));
      expect(a.snap.state.expense(e), isNotNull);
      expect(a.mineIn(t.g).last.counter, 6);
    });

    test('version vector after a corrupt row still claims it (documented '
        'behaviour: missingFor cannot serve it)', () async {
      await tamper((db) => db.execute(
          "UPDATE ops SET json = '{broken' WHERE op_id = 'remote-2'"));
      expect((await a.ledger.versionVector(t.g))[peerB], 3);
      final served = await a.ledger.opsMissingFor(t.g, VersionVector.empty);
      expect(served.map((o) => o.id), isNot(contains('remote-2')));
    });
  });

  group('kv values', () {
    test('profile: invalid JSON -> null profile, ops intact', () async {
      final ops = a.snap.ops.length;
      await tamper((db) => db.execute(
          "UPDATE kv SET value = '{oops' WHERE key = ?", [KvKeys.profile]));
      expect(a.settings.profile, isNull);
      expect(a.snap.ops, hasLength(ops));
      expect(a.snap.state.groups[t.g]!.group, isNotNull);
    });

    test('profile: wrong types -> null profile (no crash)', () async {
      await tamper((db) => db.execute(
          'UPDATE kv SET value = ? WHERE key = ?',
          ['{"personId": 7, "displayName": null}', KvKeys.profile]));
      expect(a.settings.profile, isNull);
    });

    test(
      'profile lost to corruption: re-onboarding keeps my personId so my '
      'balances in existing groups are still mine',
      () async {
        final personId = a.settings.profile!.personId;
        await tamper((db) => db.execute(
            "UPDATE kv SET value = '{oops' WHERE key = ?", [KvKeys.profile]));
        final p = await a.settings
            .completeOnboarding(displayName: 'Alex', homeCurrency: 'INR');
        expect(p.personId, personId);
      },
    );

    test('settings: garbage and partial values fall back per field',
        () async {
      await a.settings.updateSettings(const AppSettings(
          themeMode: AppThemeMode.dark, vibration: false));
      await tamper((db) => db.execute(
          'UPDATE kv SET value = ? WHERE key = ?', [
        '{"themeMode": "neon", "vibration": false, "defaultSplit": 3}',
        KvKeys.settings
      ]));
      expect(a.settings.settings.themeMode, AppThemeMode.system);
      expect(a.settings.settings.vibration, isFalse);
      expect(a.settings.settings.defaultSplit, SplitMethod.equal);
      await tamper((db) => db.execute(
          "UPDATE kv SET value = 'nope' WHERE key = ?", [KvKeys.settings]));
      expect(a.settings.settings.themeMode, AppThemeMode.system);
    });

    test(
      'device: a corrupt device row keeps this phone\'s device id '
      '(recoverable from hlc.last / own ops)',
      () async {
        final id = a.deviceId;
        expect(a.snap.totalUnshared, 4);
        await tamper((db) => db.execute(
            "UPDATE kv SET value = '{\"deviceId\": 5}' WHERE key = ?",
            [KvKeys.device]));
        expect(a.deviceId, id);
        expect(a.snap.totalUnshared, 4);
      },
    );

    test('device: corrupt row -> startup survives with a usable identity',
        () async {
      await tamper((db) => db.execute(
          "UPDATE kv SET value = '][' WHERE key = ?", [KvKeys.device]));
      expect(a.deviceId, isNotEmpty);
      // The app still writes, with contiguous counters for the identity.
      await a.ledger.renameMember(t.g, t.sam, 'S');
      expect(a.group(t.g).members[t.sam]!.displayName, 'S');
    });

    test('hlc.last garbage / foreign device / negative -> clock rebuilt '
        'from own ops, never behind them', () async {
      a.clock.advance(3 * 3600 * 1000);
      await a.ledger.addExpense(qaDraft(t.g, [t.me]));
      final last = a.mineIn(t.g).last.hlc;
      for (final bad in [
        'garbage',
        Hlc(kQaBaseMs, 0, peerB).encode(),
        '-5:0:x',
        '',
      ]) {
        await tamper((db) => db.execute(
            'UPDATE kv SET value = ? WHERE key = ?', [bad, KvKeys.hlcLast]));
        a.clock.now = kQaBaseMs;
        // A distinct short name each time (member names are 1..40).
        await a.ledger.renameMember(t.g, t.sam, 'S ${bad.length}');
        expect(a.mineIn(t.g).last.hlc > last, isTrue, reason: bad);
      }
    });

    test('corrupt sync_records row is skipped', () async {
      await a.ledger.addSyncRecord(SyncRecord(
        id: 'r1',
        peerName: 'Pixel',
        transport: TransportKind.lan,
        startedAt: utcFromMillis(kQaBaseMs),
        endedAt: utcFromMillis(kQaBaseMs + 1),
        sentOps: 1,
        receivedOps: 1,
        groupIds: const [],
        outcome: SyncOutcome.completed,
      ));
      await a.ledger.addSyncRecord(SyncRecord(
        id: 'r2',
        peerName: 'Pixel',
        transport: TransportKind.ble,
        startedAt: utcFromMillis(kQaBaseMs + 5),
        endedAt: utcFromMillis(kQaBaseMs + 6),
        sentOps: 1,
        receivedOps: 1,
        groupIds: const [],
        outcome: SyncOutcome.completed,
      ));
      await tamper((db) => db.execute(
          "UPDATE sync_records SET json = '{x' WHERE id = 'r2'"));
      final records = await a.ledger.watchSyncRecords().first;
      expect(records.map((r) => r.id), ['r1']);
    });
  });
}
