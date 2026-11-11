// QA DATA round 21: final regression sweep of the durability charter.
//
// A seeded soak over ten groups: local edits of every common kind, failed
// writes, peer edits, peer knowledge reports, wall clock jumps both ways,
// graceful restarts and unclean ones (a second connection on the same WAL
// file while the first is still open). After every relaunch the snapshot,
// identity, settings, counters, HLC order and unshared counts are checked
// against what was there before and against a model. A second test opens a
// file with every kind of damage the charter lists at once.
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/schema.dart';
import 'package:sqlite3/sqlite3.dart';

import 'durability_restart_test.dart' show expectSameSnapshot;
import 'qa_data_harness.dart';

const DeviceId peerB = 'bbbbbbbb-0000-7000-8000-0000000000b1';
const DeviceId peerC = 'cccccccc-0000-7000-8000-0000000000c1';

void main() {
  test('soak: 10 groups, 6 relaunches (graceful and unclean), failed '
      'writes, peer edits and reports, clock jumps: nothing drifts', () async {
    resetKeystore();
    final rnd = Random(21);
    final dir = qaTempDir();
    addTearDown(() => dir.deleteSync(recursive: true));
    FaultyStore? faulty;
    var phone = FilePhone(dir)..wrap = (s) => faulty = FaultyStore(s);
    await phone.launch();
    await phone.settings.completeOnboarding(
      displayName: 'Alex',
      homeCurrency: 'INR',
    );
    await phone.settings.updateSettings(
      const AppSettings(
        themeMode: AppThemeMode.dark,
        vibration: false,
        defaultSplit: SplitMethod.shares,
        simplifyByDefault: false,
      ),
    );
    final stale = <FilePhone>[];
    addTearDown(() async {
      for (final p in [...stale, phone]) {
        try {
          await p.close();
        } catch (_) {}
      }
    });

    final trips = <Trip>[];
    for (var i = 0; i < 10; i++) {
      trips.add(await qaTrip(phone, name: 'Group $i'));
    }
    final device = phone.settings.device;
    final profile = phone.settings.profile!;
    final acked = <GroupId, int>{};
    final peerCounter = <GroupId, int>{};
    final expenses = <GroupId, List<ExpenseId>>{};
    var failures = 0;
    var launches = 1;

    void checkInvariants(String at) {
      final s = phone.snap;
      expect(phone.settings.device.deviceId, device.deviceId, reason: at);
      expect(phone.settings.device.deviceName, device.deviceName, reason: at);
      expect(phone.settings.profile!.personId, profile.personId, reason: at);
      expect(phone.settings.profile!.displayName, 'Alex', reason: at);
      expect(phone.settings.settings.themeMode, AppThemeMode.dark, reason: at);
      expect(
        phone.settings.settings.defaultSplit,
        SplitMethod.shares,
        reason: at,
      );
      expect(s.groupsWithoutKey, isEmpty, reason: at);
      var total = 0;
      for (final t in trips) {
        final mine = phone.mineIn(t.g);
        expect(
          [for (final o in mine) o.counter],
          List.generate(mine.length, (i) => i + 1),
          reason: '$at: own counters of ${t.g} not contiguous',
        );
        for (var i = 1; i < mine.length; i++) {
          expect(
            mine[i].hlc > mine[i - 1].hlc,
            isTrue,
            reason: '$at: HLC of ${t.g} #${mine[i].counter} went back',
          );
        }
        final int want = mine.length - min(acked[t.g] ?? 0, mine.length);
        expect(
          s.unsharedCounts[t.g] ?? 0,
          want,
          reason: '$at: unshared count of ${t.g}',
        );
        total += want;
      }
      expect(s.totalUnshared, total, reason: at);
    }

    Future<void> localStep(Trip t) async {
      final list = expenses[t.g] ??= [];
      final pick = rnd.nextInt(6);
      phone.clock.advance(rnd.nextInt(5000));
      switch (pick) {
        case 0 || 1:
          list.add(
            await phone.ledger.addExpense(
              qaDraft(t.g, [
                t.me,
                t.sam,
                t.priya,
              ], total: 100 + rnd.nextInt(90000)),
            ),
          );
        case 2 when list.isNotEmpty:
          await phone.ledger.updateExpense(
            list.last,
            qaDraft(
              t.g,
              [t.me, t.sam],
              total: 100 + rnd.nextInt(5000),
              description: 'Edited',
            ),
          );
        case 3 when list.isNotEmpty:
          await phone.ledger.deleteExpense(list.removeLast());
        case 4:
          await phone.ledger.recordPayment(
            PaymentDraft(
              groupId: t.g,
              from: t.sam,
              to: t.me,
              amount: 1 + rnd.nextInt(3000),
              currency: 'INR',
              method: PaymentMethod.cash,
              date: utcFromMillis(kQaBaseMs),
            ),
          );
        default:
          await phone.ledger.renameMember(
            t.g,
            t.priya,
            'Priya ${rnd.nextInt(999)}',
          );
      }
    }

    Future<void> peerStep(Trip t) async {
      final c = (peerCounter[t.g] ?? 0) + 1;
      peerCounter[t.g] = c;
      final op = Operation(
        id: 'b-${t.g}-$c',
        groupId: t.g,
        deviceId: peerB,
        counter: c,
        hlc: Hlc(phone.clock.now + rnd.nextInt(60000), 0, peerB),
        entityType: EntityType.member,
        entityId: t.sam,
        kind: OpKind.update,
        payload: {MemberFields.displayName: 'Sam $c'},
      );
      expect(await phone.ledger.applyRemote(t.g, [op]), [op]);
    }

    for (var round = 0; round < 6; round++) {
      for (var step = 0; step < 60; step++) {
        final t = trips[rnd.nextInt(trips.length)];
        final r = rnd.nextInt(10);
        if (r == 0) {
          // A failed write: nothing moves, the counter is not burned.
          final before = phone.snap;
          final counters = phone.mineIn(t.g).length;
          faulty!.failNextInsert = true;
          await expectLater(
            phone.ledger.addExpense(qaDraft(t.g, [t.me, t.sam])),
            throwsA(
              isA<LedgerException>().having(
                (e) => e.code,
                'code',
                LedgerErrorCode.storageFailed,
              ),
            ),
          );
          failures++;
          expect(
            phone.snap.state.toCanonicalJson(),
            before.state.toCanonicalJson(),
          );
          expect(phone.mineIn(t.g).length, counters);
        } else if (r == 1) {
          await peerStep(t);
        } else if (r == 2) {
          // A peer reports what it holds; sometimes stale, sometimes all.
          final n = phone.mineIn(t.g).length;
          final report = rnd.nextBool() ? n : rnd.nextInt(n + 1);
          await phone.ledger.recordPeerKnowledge(
            rnd.nextBool() ? peerB : peerC,
            t.g,
            VersionVector({device.deviceId: report}),
          );
          acked[t.g] = max(acked[t.g] ?? 0, report);
        } else {
          await localStep(t);
        }
      }
      checkInvariants('round $round before relaunch');
      final live = phone.snap;
      final vvs = {
        for (final t in trips) t.g: await phone.ledger.versionVector(t.g),
      };
      final now = phone.clock.now;
      if (round.isEven) {
        await phone.restart();
      } else {
        // Unclean: the old process never closes; a new one opens the file.
        stale.add(phone);
        phone = FilePhone(dir, seed: 1 + 16 * ++launches)
          ..wrap = (s) => faulty = FaultyStore(s);
        await phone.launch();
      }
      // The wall clock jumps a day back or an hour forward.
      phone.clock.now = round % 3 == 0 ? now - 86400000 : now + 3600000;
      expectSameSnapshot(phone.snap, live);
      for (final t in trips) {
        expect(
          await phone.ledger.versionVector(t.g),
          vvs[t.g],
          reason: 'round $round: version vector of ${t.g}',
        );
      }
      checkInvariants('round $round after relaunch');
      // The first command after the relaunch takes the next counter and
      // an HLC above every own op written before it.
      final t = trips[round];
      final lastHlc = phone.mineIn(t.g).last.hlc;
      final n = phone.mineIn(t.g).length;
      await phone.ledger.renameMember(t.g, t.sam, 'Sam after $round');
      expect(phone.mineIn(t.g).last.counter, n + 1);
      expect(phone.mineIn(t.g).last.hlc > lastHlc, isTrue);
    }
    expect(failures, greaterThan(0));
    // The raw table agrees with the ledger: one row per op, no forks.
    final db = sqlite3.open(phone.path);
    addTearDown(db.close);
    expect(
      db.select('SELECT COUNT(*) FROM ops').first.columnAt(0),
      phone.snap.ops.length,
    );
  }, timeout: const Timeout(Duration(minutes: 3)));

  test('every charter damage at once: user_version 0 over v1 tables, bad '
      'JSON, unknown entity, missing fields, bad kv rows, a lost key: the '
      'app starts, skips only the bad rows and keeps working', () async {
    resetKeystore();
    final dir = qaTempDir();
    addTearDown(() => dir.deleteSync(recursive: true));
    var phone = FilePhone(dir);
    addTearDown(() async {
      try {
        await phone.close();
      } catch (_) {}
    });
    await phone.launch();
    await phone.settings.completeOnboarding(
      displayName: 'Alex',
      homeCurrency: 'INR',
    );
    final keep = await qaTrip(phone, name: 'Keep');
    final keyless = await qaTrip(phone, name: 'Keyless');
    final e = await phone.ledger.addExpense(
      qaDraft(keep.g, [keep.me, keep.sam], total: 9000),
    );
    final device = phone.settings.device;
    final personId = phone.settings.profile!.personId;
    final keepCounters = phone.mineIn(keep.g).length;
    final keylessCounters = phone.mineIn(keyless.g).length;
    final state = phone.snap.state.toCanonicalJson();
    await phone.close();

    final db = sqlite3.open(phone.path);
    db.userVersion = 0;
    final now = kQaBaseMs + 10;
    void row(String id, String json, {int counter = 1}) => db.execute(
      'INSERT INTO ops VALUES (?, ?, ?, ?, ?, 1, ?, ?)',
      [id, keep.g, peerB, counter, Hlc(now, 0, peerB).encode(), json, now],
    );
    row('bad-json', '{not json', counter: 1);
    row(
      'unknown',
      jsonEncode({
        'id': 'unknown',
        'groupId': keep.g,
        'deviceId': peerB,
        'counter': 2,
        'hlc': Hlc(now, 1, peerB).encode(),
        'schemaVersion': 1,
        'entityType': 'spaceship',
        'entityId': 'x',
        'kind': 'create',
        'payload': <String, Object?>{},
      }),
      counter: 2,
    );
    row('no-fields', jsonEncode({'id': 'no-fields'}), counter: 3);
    db.execute(
      "UPDATE kv SET value = '{\"personId\": 5}' WHERE key = 'profile'",
    );
    db.execute("UPDATE kv SET value = '[1,2' WHERE key = 'settings'");
    db.execute("UPDATE kv SET value = 'null' WHERE key = 'device'");
    db.close();
    // The keystore lost the key of one group that has ops.
    await phone.keys.remove(keyless.g);

    phone = FilePhone(dir, seed: 7);
    await phone.launch();
    // Startup survived, the schema was adopted, identity was kept.
    final check = sqlite3.open(phone.path);
    expect(check.userVersion, kStoreSchemaVersion);
    check.close();
    expect(phone.settings.device.deviceId, device.deviceId);
    expect(phone.settings.settings, const AppSettings());
    // The profile row is unreadable: the app asks to onboard again, and
    // onboarding keeps the person id the groups know (DATA-R1-05).
    expect(phone.settings.profile, isNull);
    await phone.settings.completeOnboarding(
      displayName: 'Alex',
      homeCurrency: 'INR',
    );
    expect(phone.settings.profile!.personId, personId);
    // Other data intact; the keyless group is flagged, not lost.
    expect(phone.snap.state.toCanonicalJson(), state);
    expect(phone.group(keep.g).expenses.containsKey(e), isTrue);
    expect(phone.group(keyless.g).group, isNotNull);
    expect(phone.snap.groupsWithoutKey, {keyless.g});
    expect(
      phone.snap.ops.map((o) => o.id),
      isNot(anyOf(contains('bad-json'), contains('no-fields'))),
    );
    // Commands still work and take fresh counters in both groups.
    await phone.ledger.addExpense(qaDraft(keep.g, [keep.me, keep.sam]));
    await phone.ledger.renameMember(keyless.g, keyless.sam, 'Sam K');
    expect(phone.mineIn(keep.g).last.counter, keepCounters + 1);
    expect(phone.mineIn(keyless.g).last.counter, keylessCounters + 1);
    // The bad rows are still skipped after one more restart, and nothing
    // the session wrote is lost.
    final live = phone.snap;
    await phone.restart();
    expectSameSnapshot(phone.snap, live);
    expect(phone.snap.groupsWithoutKey, {keyless.g});
  });
}
