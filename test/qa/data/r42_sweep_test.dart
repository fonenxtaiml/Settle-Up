// QA DATA round 42: final regression sweep of the durability charter on the
// integrated build. The only data-layer change since round 39 is the
// MONEY-R39-01 stamping in OpFactory (follow any far-ahead floor, and move
// each stamp past the newest held stamp at its millisecond), plus the
// SECURITY-R39-01 bound on recorded phone names in sync history.
//
// Probes those paths against the charter: failed and half-failed writes
// while a far-ahead floor is followed, a lost clock save then an unclean
// relaunch, unshared counts across all of it, a stored sync record with an
// oversized or malformed name, and per-command cost with 20,000 stored ops.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/schema.dart';
import 'package:settle_up/data/op_factory.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:sqlite3/sqlite3.dart';

import 'durability_restart_test.dart' show expectSameSnapshot;
import 'qa_data_harness.dart';

const int _day = 24 * 60 * 60 * 1000;
const DeviceId peerB = 'bbbbbbbb-0000-7000-8000-0000000000c2';

void main() {
  late Directory dir;
  setUp(() {
    resetKeystore();
    dir = qaTempDir();
  });
  tearDown(() => dir.deleteSync(recursive: true));

  Future<(FilePhone, FaultyStore, Trip)> phone() async {
    late FaultyStore faulty;
    final a = FilePhone(dir)..wrap = (s) => faulty = FaultyStore(s);
    await a.launch();
    await a.settings.completeOnboarding(
      displayName: 'Alex',
      homeCurrency: 'INR',
    );
    return (a, faulty, await qaTrip(a));
  }

  Operation newestOpOf(FilePhone p, String entityId) => p.snap.ops
      .where((o) => o.entityId == entityId)
      .reduce((x, y) => x.hlc > y.hlc ? x : y);

  void expectOwnInvariants(FilePhone p, String at) {
    final own = [
      for (final o in p.snap.ops)
        if (o.deviceId == p.deviceId) o,
    ];
    expect(
      own.map((o) => o.hlc).toSet().length,
      own.length,
      reason: '$at: own stamps unique',
    );
    for (final g in {for (final o in own) o.groupId}) {
      final cs = [for (final o in p.mineIn(g)) o.counter];
      expect(cs, [
        for (var i = 1; i <= cs.length; i++) i,
      ], reason: '$at: counters of $g contiguous');
    }
  }

  test('a failed write while following a far-ahead floor: LedgerException, '
      'nothing applied, no burned counter; the retry wins, stamps stay '
      'unique and a relaunch replays the same ledger', () async {
    final (a, faulty, t) = await phone();
    a.clock.now = kQaBaseMs + 30 * _day;
    final taxi = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Taxi'),
    );
    final bus = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Bus'),
    );
    a.clock.now = kQaBaseMs + 60000;
    final before = a.snap;
    final floor = newestOpOf(a, taxi).hlc;
    expect(floor.millis, greaterThan(a.clock.now + HlcClock.maxAdoptDriftMs));

    faulty.failNextInsert = true;
    await expectLater(
      a.ledger.updateExpense(
        taxi,
        qaDraft(t.g, [t.me, t.sam], description: 'Taxi, fixed'),
      ),
      throwsA(
        isA<LedgerException>().having(
          (e) => e.code,
          'code',
          LedgerErrorCode.storageFailed,
        ),
      ),
    );
    expectSameSnapshot(a.snap, before);
    expect(a.snap.state.expense(taxi)!.description, 'Taxi');

    await a.ledger.updateExpense(
      taxi,
      qaDraft(t.g, [t.me, t.sam], description: 'Taxi, fixed'),
    );
    await a.ledger.updateExpense(
      bus,
      qaDraft(t.g, [t.me, t.sam], description: 'Bus, fixed'),
    );
    final lunch = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Lunch'),
    );
    expect(a.snap.state.expense(taxi)!.description, 'Taxi, fixed');
    expect(a.snap.state.expense(bus)!.description, 'Bus, fixed');
    expect(
      newestOpOf(a, lunch).hlc.millis,
      lessThanOrEqualTo(a.clock.now + OpFactory.maxLeadMs),
    );
    expectOwnInvariants(a, 'after retry');
    expect(a.snap.unsharedCounts[t.g], a.mineIn(t.g).length);

    final live = a.snap;
    await a.restart();
    expectSameSnapshot(a.snap, live);
    await a.ledger.updateExpense(
      taxi,
      qaDraft(t.g, [t.me, t.sam], description: 'Taxi, again'),
    );
    expect(a.snap.state.expense(taxi)!.description, 'Taxi, again');
    expectOwnInvariants(a, 'after relaunch');
    await a.close();
  });

  test('a write that landed but reported an error while following a '
      'far-ahead floor: the counters are re-read, the next edits of both '
      'far-ahead entities never reuse a stamp, across a relaunch', () async {
    final (a, faulty, t) = await phone();
    a.clock.now = kQaBaseMs + 30 * _day;
    final taxi = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Taxi'),
    );
    final bus = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Bus'),
    );
    a.clock.now = kQaBaseMs + 60000;

    faulty.failAfterNextInsert = true;
    await expectLater(
      a.ledger.updateExpense(
        taxi,
        qaDraft(t.g, [t.me, t.sam], description: 'Taxi, fixed'),
      ),
      throwsA(isA<LedgerException>()),
    );
    // Relaunch without a clean close: the landed op is replayed from disk.
    await a.launch();
    expect(a.snap.state.expense(taxi)!.description, 'Taxi, fixed');
    await a.ledger.updateExpense(
      bus,
      qaDraft(t.g, [t.me, t.sam], description: 'Bus, fixed'),
    );
    await a.ledger.updateExpense(
      taxi,
      qaDraft(t.g, [t.me, t.sam], description: 'Taxi, again'),
    );
    expect(a.snap.state.expense(bus)!.description, 'Bus, fixed');
    expect(a.snap.state.expense(taxi)!.description, 'Taxi, again');
    expectOwnInvariants(a, 'after landed-but-failed write');
    final live = a.snap;
    await a.restart();
    expectSameSnapshot(a.snap, live);
    await a.close();
  });

  test('a lost clock save after a far-ahead edit, then an unclean '
      'relaunch: the clock is rebuilt from the stored ops and the next '
      'edits and new ops keep every own stamp unique', () async {
    final (a, faulty, t) = await phone();
    a.clock.now = kQaBaseMs + 30 * _day;
    final ids = [
      for (var i = 0; i < 4; i++)
        await a.ledger.addExpense(
          qaDraft(t.g, [t.me, t.sam], description: 'E$i'),
        ),
    ];
    a.clock.now = kQaBaseMs + 60000;
    faulty.failNextSetKvKey = KvKeys.hlcLast;
    await a.ledger.updateExpense(
      ids[0],
      qaDraft(t.g, [t.me, t.sam], description: 'E0 fixed'),
    );
    // No close: the stored hlc.last is older than the newest own op.
    await a.launch();
    for (var i = 0; i < 4; i++) {
      await a.ledger.updateExpense(
        ids[i],
        qaDraft(t.g, [t.me, t.sam], description: 'E$i again'),
      );
      await a.ledger.addExpense(
        qaDraft(t.g, [t.me, t.sam], description: 'New $i'),
      );
    }
    for (var i = 0; i < 4; i++) {
      expect(a.snap.state.expense(ids[i])!.description, 'E$i again');
    }
    expectOwnInvariants(a, 'after unclean relaunch');
    final live = a.snap;
    await a.restart();
    expectSameSnapshot(a.snap, live);
    await a.close();
  });

  test(
    'unshared counts with far-ahead edits: a peer ack covers them, a '
    'later edit is counted again, and the counts survive a relaunch',
    () async {
      final (a, _, t) = await phone();
      final t2 = await qaTrip(a, name: 'Flat 4B');
      a.clock.now = kQaBaseMs + 30 * _day;
      final taxi = await a.ledger.addExpense(
        qaDraft(t.g, [t.me, t.sam], description: 'Taxi'),
      );
      await a.ledger.addExpense(
        qaDraft(t2.g, [t2.me, t2.sam], description: 'Rent'),
      );
      a.clock.now = kQaBaseMs + 60000;
      await a.ledger.updateExpense(
        taxi,
        qaDraft(t.g, [t.me, t.sam], description: 'Taxi, fixed'),
      );
      final n1 = a.mineIn(t.g).length;
      final n2 = a.mineIn(t2.g).length;
      expect(a.snap.unsharedCounts, {t.g: n1, t2.g: n2});

      await a.ledger.recordPeerKnowledge(
        peerB,
        t.g,
        VersionVector({a.deviceId: n1}),
      );
      expect(a.snap.unsharedCounts, {t2.g: n2});
      await a.ledger.updateExpense(
        taxi,
        qaDraft(t.g, [t.me, t.sam], description: 'Taxi, later'),
      );
      expect(a.snap.unsharedCounts, {t.g: 1, t2.g: n2});
      expect(a.snap.unsharedOpIds.length, 1 + n2);

      final live = a.snap;
      await a.restart();
      expectSameSnapshot(a.snap, live);
      expect(a.snap.unsharedCounts, {t.g: 1, t2.g: n2});
      await a.close();
    },
  );

  test('a stored sync record with an oversized name is bounded on read; '
      'one with a non-string name is skipped; startup survives', () async {
    final (a, _, _) = await phone();
    final now = DateTime.fromMillisecondsSinceEpoch(kQaBaseMs, isUtc: true);
    SyncRecord rec(String id, String name) => SyncRecord(
      id: id,
      peerDeviceId: peerB,
      peerName: name,
      transport: TransportKind.lan,
      startedAt: now,
      endedAt: now,
      sentOps: 1,
      receivedOps: 2,
      groupIds: const [],
      outcome: SyncOutcome.completed,
      error: null,
    );
    await a.store.addSyncRecord(rec('r1', 'Priya ${'x' * 5000}'));
    await a.store.addSyncRecord(rec('r2', 'Sam'));
    await a.close();

    // Damage r2's name in the file the way an older build might not have.
    final db = sqlite3.open(a.path);
    final rows = db.select('SELECT rowid, * FROM sync_records');
    expect(rows, hasLength(2));
    for (final r in rows) {
      final m = jsonDecode(r['json'] as String) as Map<String, Object?>;
      if (m['id'] == 'r2') {
        m['peerName'] = 42;
        db.execute('UPDATE sync_records SET json = ? WHERE rowid = ?', [
          jsonEncode(m),
          r['rowid'],
        ]);
      }
    }
    db.close();

    await a.launch();
    final records = await a.store.syncRecords();
    final r1 = records.firstWhere((r) => r.id == 'r1');
    expect(r1.peerName.length, lessThanOrEqualTo(40));
    expect(r1.peerName, startsWith('Priya'));
    expect(records.map((r) => r.id), isNot(contains('r2')));
    expect(a.snap.state.groups, isNotEmpty);
    await a.close();
  });

  test('per-command cost with 20,000 stored ops and a far-ahead floor: '
      'open stays within 2 s and an edit stays well under 100 ms', () async {
    final (a, _, t) = await phone();
    a.clock.now = kQaBaseMs + 30 * _day;
    final far = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Far'),
    );
    a.clock.now = kQaBaseMs;
    await a.close();

    // 20,000 peer ops across 10 groups, stored through the store itself.
    await a.launch();
    final ops = <Operation>[];
    var c = 0;
    for (var g = 0; g < 10; g++) {
      final gid = 'aaaaaaaa-0000-7000-8000-${g.toString().padLeft(12, '0')}';
      for (var i = 0; i < 2000; i++) {
        c++;
        ops.add(
          Operation(
            id:
                'cccccccc-0000-7000-8${g.toString().padLeft(3, '0')}-'
                '${i.toString().padLeft(12, '0')}',
            groupId: gid,
            deviceId: peerB,
            counter: i + 1,
            hlc: Hlc(kQaBaseMs - 100000 + c, 0, peerB),
            entityType: i == 0 ? EntityType.group : EntityType.member,
            entityId: i == 0
                ? gid
                : 'dddddddd-0000-7000-8${g}00-'
                      '${i.toString().padLeft(12, '0')}',
            kind: OpKind.create,
            payload: i == 0
                ? {
                    'name': 'G$g',
                    'type': 'trip',
                    'currency': 'INR',
                    'simplifyDebts': false,
                    'archived': false,
                    'createdAt': kQaBaseMs,
                  }
                : {
                    'displayName': 'M$i',
                    'personId':
                        'eeeeeeee-0000-7000-8${g}00-'
                        '${i.toString().padLeft(12, '0')}',
                    'createdAt': kQaBaseMs,
                  },
          ),
        );
      }
    }
    await a.store.insertAll(ops);
    await a.close();

    final sw = Stopwatch()..start();
    await a.launch();
    final openMs = sw.elapsedMilliseconds;
    expect(a.snap.ops.length, greaterThan(20000));
    expect(openMs, lessThan(2000), reason: 'open+replay $openMs ms');

    final times = <int>[];
    for (var i = 0; i < 20; i++) {
      a.clock.advance();
      final s = Stopwatch()..start();
      await a.ledger.updateExpense(
        far,
        qaDraft(t.g, [t.me, t.sam], description: 'Far $i'),
      );
      times.add(s.elapsedMicroseconds);
    }
    times.sort();
    final median = times[times.length ~/ 2] / 1000;
    // ignore: avoid_print
    print(
      'DATA-R42 perf: open $openMs ms, far-ahead edit median '
      '${median.toStringAsFixed(1)} ms',
    );
    expect(median, lessThan(100));
    expect(a.snap.state.expense(far)!.description, 'Far 19');
    expectOwnInvariants(a, 'perf');
    await a.close();
  });
}
