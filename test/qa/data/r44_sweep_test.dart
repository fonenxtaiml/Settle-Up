// QA DATA round 44: final full regression sweep of the durability charter on
// the integrated build. No data-layer code changed since the round 42 sweep
// (only the New group form), so this round re-runs every DATA suite and adds
// two probes that combine the charter's paths instead of taking them one at
// a time:
//
// 1. A seeded soak on two phones on real SQLite files: local commands of
//    every kind, writes refused by the store, lost clock saves, wall clock
//    jumps forward and back (within the adopt window), syncs both ways,
//    clean and unclean relaunches. After every step: own counters are
//    contiguous, own stamps unique and strictly rising in write order (the
//    HLC never goes backwards, also across relaunches), a clean relaunch
//    replays the same snapshot, profile, settings and device id, a refused
//    write changes nothing, and a completed sync converges both phones and
//    leaves nothing unshared.
// 2. A real SQLite write lock held by another connection (SQLITE_BUSY, not an
//    injected exception): local commands, settings writes and a sync are
//    refused without advancing anything, a cold open under the lock still
//    starts, and everything works once the lock is gone.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/codecs.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/schema.dart';
import 'package:settle_up/sync/protocol/session.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../sync/support/harness.dart';
import 'durability_restart_test.dart' show expectSameSnapshot;
import 'qa_data_harness.dart';

const int _hour = 60 * 60 * 1000;
const int _day = 24 * _hour;

void main() {
  late FilePhone a;
  late FilePhone b;
  late FaultyStore faulty;
  late Trip t;

  setUp(() async {
    resetKeystore();
    a = FilePhone(qaTempDir())..wrap = (s) => faulty = FaultyStore(s);
    b = FilePhone(qaTempDir(), seed: 2);
    await a.launch();
    await b.launch();
    await a.settings.completeOnboarding(
      displayName: 'Alex',
      homeCurrency: 'INR',
    );
    await b.settings.completeOnboarding(
      displayName: 'Priya',
      homeCurrency: 'INR',
    );
    t = await qaTrip(a);
  });

  tearDown(() async {
    for (final p in [a, b]) {
      try {
        await p.close();
      } catch (_) {}
      p.dir.deleteSync(recursive: true);
    }
  });

  Future<(SessionResult, SessionResult)> sync(
    SyncStore initiator,
    SyncStore responder,
  ) async {
    final (ci, cr) = await channelPair();
    final r = await Future.wait([
      SyncSession(
        channel: ci,
        store: initiator,
        role: SessionRole.initiator,
        timings: fastTimings,
      ).run(),
      SyncSession(
        channel: cr,
        store: responder,
        role: SessionRole.responder,
        timings: fastTimings,
      ).run(),
    ]);
    return (r[0], r[1]);
  }

  Future<void> join() async {
    await b.ledger.registerJoinedGroup(
      t.g,
      (await a.ledger.groupKeys())[t.g]!,
      'Goa trip',
    );
    final r = await sync(a.ledger, b.ledger);
    expect(r.$1.outcome, SyncOutcome.completed, reason: r.$1.message);
  }

  /// Own ops per group: counters 1..n, stamps unique and rising with the
  /// counter (write order).
  void expectOwn(FilePhone p, String at) {
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
      final mine = p.mineIn(g);
      expect(
        [for (final o in mine) o.counter],
        [for (var i = 1; i <= mine.length; i++) i],
        reason: '$at: counters of $g contiguous',
      );
      for (var i = 1; i < mine.length; i++) {
        expect(
          mine[i].hlc > mine[i - 1].hlc,
          isTrue,
          reason:
              '$at: stamp of counter ${mine[i].counter} '
              '(${mine[i].hlc}) after counter ${mine[i - 1].counter} '
              '(${mine[i - 1].hlc})',
        );
      }
    }
  }

  GroupState? gsOf(FilePhone p) => p.snap.state.groups[t.g];

  List<ExpenseId> expensesOf(FilePhone p) =>
      [...?gsOf(p)?.expenses.keys]..sort();

  for (final seed in [44, 4401, 4402, 4403]) {
    test('seeded soak (seed $seed) on two file-backed phones: commands, '
        'refused writes, lost clock saves, clock jumps, syncs and relaunches '
        'keep every durability invariant', () async {
      await join();
      final rnd = Random(seed);
      var refused = 0, lostSaves = 0, clean = 0, unclean = 0, syncs = 0;
      var cmds = 0;
      Hlc? newestOwnA;

      Future<bool> command(FilePhone p) async {
        final gs = gsOf(p);
        if (gs == null || gs.group == null) return false;
        final members =
            gs.members.values
                .where((m) => !m.isRemoved)
                .map((m) => m.id)
                .toList()
              ..sort();
        final ids = expensesOf(p);
        final pick = rnd.nextInt(7);
        final n = cmds++;
        switch (pick) {
          case 0 || 1:
            await p.ledger.addExpense(
              qaDraft(
                t.g,
                members,
                description: 'E$n',
                total: 100 + rnd.nextInt(90000),
              ),
            );
          case 2 when ids.isNotEmpty:
            final id = ids[rnd.nextInt(ids.length)];
            final e = p.snap.state.expense(id)!;
            if (e.isDeleted) {
              await p.ledger.restoreExpense(id, groupId: t.g);
            } else if (e.isPayment) {
              return false;
            } else {
              await p.ledger.updateExpense(
                id,
                qaDraft(
                  t.g,
                  members,
                  description: 'U$n',
                  total: 100 + rnd.nextInt(90000),
                ),
              );
            }
          case 3 when ids.isNotEmpty:
            final id = ids[rnd.nextInt(ids.length)];
            if (p.snap.state.expense(id)!.isDeleted) return false;
            await p.ledger.deleteExpense(id, groupId: t.g);
          case 4:
            await p.ledger.recordPayment(
              PaymentDraft(
                groupId: t.g,
                from: members[rnd.nextInt(members.length)],
                to: members.first == members.last
                    ? members.first
                    : members.last,
                amount: 1 + rnd.nextInt(5000),
                currency: 'INR',
                method: PaymentMethod.cash,
                date: utcFromMillis(p.clock.now),
              ),
            );
          case 5:
            final m = members[rnd.nextInt(members.length)];
            await p.ledger.renameMember(t.g, m, 'Name $n');
          case 6:
            await p.ledger.addMember(t.g, displayName: 'Guest $n');
          default:
            return false;
        }
        return true;
      }

      for (var step = 0; step < 220; step++) {
        final at = 'step $step';
        // Clocks: mostly forward, sometimes set back up to 3 h or jumped a
        // day ahead; both stay within the 7-day adopt window of each other.
        for (final p in [a, b]) {
          final r = rnd.nextInt(20);
          if (r == 0) {
            p.clock.now -= rnd.nextInt(3 * _hour);
          } else if (r == 1) {
            p.clock.now += _day;
          } else {
            p.clock.now += 1 + rnd.nextInt(60000);
          }
          if (p.clock.now > kQaBaseMs + 4 * _day) {
            p.clock.now = kQaBaseMs + rnd.nextInt(_day);
          }
        }
        final action = rnd.nextInt(100);
        if (action < 40) {
          try {
            await command(a);
          } on LedgerException catch (e) {
            // Name or split rules can refuse a random command; never storage.
            expect(e.code, isNot(LedgerErrorCode.storageFailed), reason: at);
          }
        } else if (action < 55) {
          try {
            await command(b);
          } on LedgerException catch (e) {
            expect(e.code, isNot(LedgerErrorCode.storageFailed), reason: at);
          }
        } else if (action < 63) {
          // A write the store refuses: nothing changes, no counter burned.
          final before = a.snap;
          faulty.failNextInsert = true;
          var threw = false;
          try {
            if (!await command(a)) {
              faulty.failNextInsert = false;
              continue;
            }
          } on LedgerException catch (e) {
            threw = true;
            if (e.code == LedgerErrorCode.storageFailed) {
              refused++;
              expectSameSnapshot(a.snap, before);
            }
          }
          expect(threw, isTrue, reason: '$at: refused write surfaced');
          faulty.failNextInsert = false;
        } else if (action < 68) {
          // The ops land, the clock save is lost.
          faulty.failNextSetKvKey = KvKeys.hlcLast;
          try {
            if (await command(a)) lostSaves++;
          } on LedgerException catch (e) {
            expect(e.code, isNot(LedgerErrorCode.storageFailed), reason: at);
          }
          faulty.failNextSetKvKey = null;
        } else if (action < 82) {
          final (r1, r2) = rnd.nextBool()
              ? await sync(a.ledger, b.ledger)
              : await sync(b.ledger, a.ledger);
          expect(
            r1.outcome,
            SyncOutcome.completed,
            reason: '$at ${r1.message}',
          );
          expect(
            r2.outcome,
            SyncOutcome.completed,
            reason: '$at ${r2.message}',
          );
          syncs++;
          expect(
            a.snap.state.toCanonicalJson(),
            b.snap.state.toCanonicalJson(),
            reason: '$at: converged',
          );
          expect(a.snap.totalUnshared, 0, reason: '$at: A all shared');
          expect(b.snap.totalUnshared, 0, reason: '$at: B all shared');
        } else if (action < 92) {
          final live = a.snap;
          final profile = profileToJson(a.settings.profile!);
          final settings = settingsToJson(a.settings.settings);
          final device = a.settings.device;
          await a.restart();
          clean++;
          expectSameSnapshot(a.snap, live);
          expect(
            profileToJson(a.settings.profile!),
            profile,
            reason: '$at: profile',
          );
          expect(
            settingsToJson(a.settings.settings),
            settings,
            reason: '$at: settings',
          );
          expect(
            a.settings.device.deviceId,
            device.deviceId,
            reason: '$at: device id',
          );
          expect(
            a.settings.device.deviceName,
            device.deviceName,
            reason: '$at: device name',
          );
        } else {
          // Unclean: drop everything, relaunch from the file.
          final live = a.snap;
          await a.launch();
          unclean++;
          expect(
            a.snap.state.toCanonicalJson(),
            live.state.toCanonicalJson(),
            reason: '$at: unclean relaunch state',
          );
          expect(
            a.snap.unsharedCounts,
            live.unsharedCounts,
            reason: '$at: unclean relaunch unshared',
          );
        }
        expectOwn(a, '$at A');
        expectOwn(b, '$at B');
        final mine = a.mineIn(t.g);
        if (mine.isNotEmpty) {
          final top = mine.last.hlc;
          if (newestOwnA != null) {
            expect(
              !(top < newestOwnA),
              isTrue,
              reason:
                  '$at: newest own stamp went back from $newestOwnA '
                  'to $top',
            );
          }
          newestOwnA = top;
        }
      }
      final (r1, _) = await sync(a.ledger, b.ledger);
      expect(r1.outcome, SyncOutcome.completed);
      expect(a.snap.state.toCanonicalJson(), b.snap.state.toCanonicalJson());
      final live = b.snap;
      await b.restart();
      expectSameSnapshot(b.snap, live);
      // ignore: avoid_print
      print(
        '[r44] soak $seed: ${a.mineIn(t.g).length} own ops on A, '
        '${b.mineIn(t.g).length} on B, ${a.snap.ops.length} ops; '
        'refused $refused, lost clock saves $lostSaves, syncs $syncs, '
        'clean relaunches $clean, unclean $unclean',
      );
      expect(refused, greaterThan(5));
      expect(syncs, greaterThan(10));
      expect(clean + unclean, greaterThan(10));
    });
  }

  test('a real SQLite write lock held by another connection: commands, '
      'settings and a sync are refused without advancing anything; a cold '
      'open under the lock starts; all works once it is released', () async {
    await join();
    final e1 = await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
    await b.ledger.addExpense(qaDraft(t.g, [t.me, t.sam], description: 'B'));
    final before = a.snap;
    final settingsBefore = a.settings.settings;
    final counter = a.mineIn(t.g).length;

    final other = sqlite3.open(a.path);
    other.execute('BEGIN IMMEDIATE');
    Object? lockedError;
    try {
      await a.ledger.updateExpense(
        e1,
        qaDraft(t.g, [t.me, t.sam], description: 'Locked'),
      );
    } catch (e) {
      lockedError = e;
    }
    // ignore: avoid_print
    print(
      '[r44] command under lock: ${lockedError.runtimeType} '
      '$lockedError',
    );
    expect(lockedError, isA<LedgerException>());
    expect(
      (lockedError! as LedgerException).code,
      LedgerErrorCode.storageFailed,
    );
    expectSameSnapshot(a.snap, before);

    Object? settingsError;
    try {
      await a.settings.updateSettings(
        settingsBefore.copyWith(
          themeMode: settingsBefore.themeMode == AppThemeMode.dark
              ? AppThemeMode.light
              : AppThemeMode.dark,
        ),
      );
    } catch (e) {
      settingsError = e;
    }
    // ignore: avoid_print
    print('[r44] settings under lock: ${settingsError.runtimeType}');
    expect(settingsError, isNotNull);
    expect(
      settingsToJson(a.settings.settings),
      settingsToJson(settingsBefore),
      reason: 'settings not advanced in memory',
    );

    final (r1, r2) = await sync(b.ledger, a.ledger);
    // ignore: avoid_print
    print(
      '[r44] sync under lock: ${r1.outcome}/${r1.message} | '
      '${r2.outcome}/${r2.message}',
    );
    expect(
      a.snap.state.toCanonicalJson(),
      before.state.toCanonicalJson(),
      reason: 'nothing applied',
    );
    expect(a.mineIn(t.g).length, counter);

    // A cold open while the lock is still held.
    Object? openError;
    try {
      await a.launch();
    } catch (e) {
      openError = e;
    }
    // ignore: avoid_print
    print('[r44] cold open under lock: ${openError ?? 'ok'}');
    expect(openError, isNull, reason: 'startup survives a held lock');
    expect(a.snap.state.toCanonicalJson(), before.state.toCanonicalJson());

    other.execute('ROLLBACK');
    other.close();

    await a.ledger.updateExpense(
      e1,
      qaDraft(t.g, [t.me, t.sam], description: 'Unlocked'),
    );
    expect(a.mineIn(t.g).length, counter + 1, reason: 'no counter burned');
    expect(a.mineIn(t.g).last.counter, counter + 1);
    final (s1, s2) = await sync(b.ledger, a.ledger);
    expect(s1.outcome, SyncOutcome.completed, reason: s1.message);
    expect(s2.outcome, SyncOutcome.completed, reason: s2.message);
    expect(a.snap.state.toCanonicalJson(), b.snap.state.toCanonicalJson());
    expect(a.snap.totalUnshared, 0);
    expectOwn(a, 'after lock');
    final live = a.snap;
    await a.restart();
    expectSameSnapshot(a.snap, live);
    expect(a.snap.state.expense(e1)!.description, 'Unlocked');
  });
}
