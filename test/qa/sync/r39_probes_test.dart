// QA SYNC round 39: final regression sweep of multi-phone convergence on
// the integrated build. lib/sync is unchanged since round 29; what moved
// under the engine is the clock (DATA-R29-01, DATA-R29-02, DATA-R31-01,
// DATA-R32-01): an own op is never stamped more than 5 days ahead of the
// wall clock (the clock is set back to the newest stamp held within that
// lead), an own stamp ahead no longer sets the peer-ahead flag, and the
// Ledger publishes a clock notice (peerAhead / ownChangesAhead) that
// follows the wall clock. These probes run those paths through the real
// DefaultSyncEngine and Ledger: a phone whose clock ran 10 days ahead and
// came back, peers that hold its far-ahead ops back (a gap in the version
// vector), three-phone gossip around the gap, repeat syncs, an interrupted
// BLE sync with the gap mid-stream, and the gap closing once real time
// reaches the stamps.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/op_factory.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';

import 'qa_phone.dart';

const _day = Duration(days: 1);

/// Ids of a reopened phone, past every id an earlier run made.
final class _LaterIds implements IdGenerator {
  _LaterIds(this.letter, int run) : _next = 0x100000 * run;
  final String letter;
  int _next;

  @override
  String newId() =>
      '${letter * 8}-0000-7000-9000-${(_next++).toRadixString(16).padLeft(12, '0')}';
}

void main() {
  late MemoryTransportHub hub;
  final phones = <QaPhone>[];
  var restarts = 0;

  Future<QaPhone> phone(
    String letter,
    String name, {
    bool sqlite = false,
  }) async {
    final p = await QaPhone.create(hub, letter, name, sqlite: sqlite);
    phones.add(p);
    return p;
  }

  /// [p] restarted over what it stored, its wall clock at [offset].
  Future<QaPhone> restart(QaPhone p, {Duration offset = Duration.zero}) async {
    await p.engine.dispose();
    await p.ledger.close();
    phones.remove(p);
    final q = await QaPhone.create(
      hub,
      p.letter,
      p.deviceName,
      store: p.opStore,
      keys: p.keys,
      clock: SkewedClock(offset),
      idGenerator: _LaterIds(p.letter, ++restarts),
    );
    phones.add(q);
    return q;
  }

  setUp(() {
    hub = MemoryTransportHub();
    restarts = 0;
  });
  tearDown(() async {
    for (final p in phones) {
      await p.dispose();
    }
    phones.clear();
  });

  int unshared(QaPhone p, GroupId g) => p.snapshot.unsharedCounts[g] ?? 0;
  int now() => DateTime.now().millisecondsSinceEpoch;

  /// Moves every phone's wall clock by [by] (time passing on all of them).
  void advance(List<QaPhone> ps, Duration by) {
    for (final p in ps) {
      p.clock.offset += by;
    }
  }

  ExpenseId newest(QaPhone p, GroupId g, String description) => p
      .state
      .groups[g]!
      .expenses
      .values
      .firstWhere((x) => x.description == description)
      .id;

  group('a phone whose clock ran 10 days ahead and came back '
      '(DATA-R29-01) through the real engine', () {
    test(
      'peers hold back only the far-ahead op; later ops stamped from the '
      'corrected clock reach them; A shows ownChangesAhead and its '
      'changes unshared, B peerAhead; five repeat syncs move nothing new; '
      'C gossips via B; once real time reaches the stamp all converge',
      () async {
        final a = await phone('a', "Alex's Pixel");
        final b = await phone('b', "Priya's Pixel", sqlite: true);
        final c = await phone('c', "Sam's Galaxy");
        final s = await a.seedGroup(expenses: 2);
        await b.join(a, s.g);
        await c.join(a, s.g);
        await syncByLink(b, a);
        await syncByLink(c, b);
        expect(allEqual([a, b, c]), isTrue);
        final e0 = (a.state.groups[s.g]!.expenses.keys.toList()..sort()).first;

        // 10 days ahead: one expense. Back to the right time: two edits.
        a.clock.offset = _day * 10;
        await a.addExpense(
          s.g,
          payer: s.a,
          owers: [s.a, s.b],
          description: 'X',
        );
        final x = newest(a, s.g, 'X');
        a.clock.offset = Duration.zero;
        await a.ledger.recheckClock();
        expect(a.snapshot.clockNotice, ClockNotice.ownChangesAhead);
        expect(a.ledger.clockSkewDetected, isTrue);
        await a.addExpense(
          s.g,
          payer: s.a,
          owers: [s.a, s.b],
          description: 'Y',
        );
        await a.edit(e0, description: 'Cab ride');
        final y = newest(a, s.g, 'Y');
        for (final op in a.opsOf(s.g).where((o) => o.entityId == y)) {
          expect(op.hlc.millis, lessThanOrEqualTo(now() + OpFactory.maxLeadMs));
        }
        // The ops after the jump are not held back by a peer on time.
        final total = a.opCount(s.g);
        expect(unshared(a, s.g), 3);

        final ab = await syncByLink(b, a);
        // X came over the wire but is held back: got counts what B stored
        // (SYNC-R39-01).
        expect(ab.receivedOps, 2);
        expect(ab.receivedByGroup[s.g], 2);
        expect(b.state.expense(x), isNull, reason: 'X is held back');
        expect(b.state.expense(y), isNotNull);
        expect(b.state.expense(e0)!.description, 'Cab ride');
        expect(b.opCount(s.g), total - 1);
        expect(b.snapshot.clockNotice, ClockNotice.peerAhead);
        expect(b.ledger.clockSkewDetected, isTrue);
        // B's vector stops before the gap: A still counts all three unshared.
        expect(
          (await b.ledger.versionVector(s.g))[a.deviceId],
          (await a.ledger.versionVector(s.g))[a.deviceId] - 3,
        );
        expect(unshared(a, s.g), 3);
        expect(a.snapshot.clockNotice, ClockNotice.ownChangesAhead);

        // Five more syncs: the gap is re-offered, nothing applied twice.
        final before = (await b.records()).length;
        final shownOnB = b.canonical;
        for (var i = 0; i < 5; i++) {
          final again = await syncByLink(b, a);
          // Re-sent behind the gap, stored nothing: got 0 (SYNC-R39-01).
          expect(again.receivedOps, 0);
          expect(b.opCount(s.g), total - 1);
          expect(b.opsOf(s.g).map((o) => o.id).toSet(), hasLength(total - 1));
          expect(b.canonical, shownOnB);
        }
        expect((await b.records()).length, before + 5);
        expect((await b.records()).first.outcome, SyncOutcome.completed);

        // C meets only B: it gets what B holds, never X.
        await syncByLink(c, b);
        expect(c.canonical, shownOnB);
        expect(c.state.expense(x), isNull);
        // C meets A: C holds X back too.
        await syncByLink(c, a);
        expect(c.state.expense(x), isNull);
        expect(c.opCount(s.g), total - 1);
        expect(c.snapshot.clockNotice, ClockNotice.peerAhead);

        // Real time reaches the stamp on every phone (10 days on).
        advance([a, b, c], _day * 10);
        await a.ledger.recheckClock();
        expect(a.snapshot.clockNotice, ClockNotice.none);
        await syncByLink(b, a);
        await syncByLink(c, b);
        expect(allEqual([a, b, c]), isTrue);
        for (final p in [a, b, c]) {
          expect(p.opCount(s.g), total, reason: p.letter);
          expect(p.state.expense(x), isNotNull, reason: p.letter);
          expect(
            await p.ledger.versionVector(s.g),
            await a.ledger.versionVector(s.g),
            reason: p.letter,
          );
        }
        expect(unshared(a, s.g), 0);
        for (final p in [b, c]) {
          await waitFor(() => unshared(p, s.g) == 0);
          expect(unshared(p, s.g), 0, reason: p.letter);
        }
      },
    );

    test('edit made while 10 days ahead vs a peer edit after A came back, '
        'then A edits again: the later edits wait with the entity, B keeps '
        'its own value meanwhile, and once time catches up every phone '
        "shows A's last edit (deterministic LWW)", () async {
      final a = await phone('a', "Alex's Pixel");
      final b = await phone('b', "Priya's Pixel");
      final s = await a.seedGroup(expenses: 2);
      await b.join(a, s.g);
      await syncByLink(b, a);
      final e1 = (a.state.groups[s.g]!.expenses.keys.toList()..sort())[1];

      a.clock.offset = _day * 10;
      await a.edit(e1, description: 'Ahead');
      a.clock.offset = Duration.zero;
      await b.edit(e1, description: "Priya's taxi");
      await syncByLink(b, a);
      // A's far-ahead edit is held back on B; B's own edit loses on A.
      expect(b.state.expense(e1)!.description, "Priya's taxi");
      expect(a.state.expense(e1)!.description, 'Ahead');
      await a.edit(e1, description: 'Alex again');
      final last = a.opsOf(s.g).last;
      expect(last.entityId, e1);
      expect(last.hlc.millis, greaterThan(now() + Ledger.maxRemoteAheadMs));
      await syncByLink(b, a);
      expect(b.state.expense(e1)!.description, "Priya's taxi");
      expect(a.state.expense(e1)!.description, 'Alex again');

      advance([a, b], _day * 10);
      await syncByLink(b, a);
      expect(b.state.expense(e1)!.description, 'Alex again');
      expect(b.canonical, a.canonical);
      expect(unshared(a, s.g), 0);
      await waitFor(() => unshared(b, s.g) == 0);
      expect(unshared(b, s.g), 0);
    });

    test(
      'a 16 KiB BLE sync of 300 expenses behind a far-ahead op, dropped '
      'mid-batch: partial or failed, nothing applied twice, the next '
      'session completes everything B accepts, and the gap closes later',
      () async {
        final a = await phone('a', "Alex's Pixel");
        final b = await phone('b', "Priya's Pixel");
        final s = await a.seedGroup(expenses: 2);
        await b.join(a, s.g);
        await syncByLink(b, a);
        a.clock.offset = _day * 10;
        await a.addExpense(
          s.g,
          payer: s.a,
          owers: [s.a, s.b],
          description: 'X',
        );
        a.clock.offset = Duration.zero;
        await a.addExpenses(s, 300, base: 2000);
        final total = a.opCount(s.g);

        await b.engine.startHosting();
        final peer = await a.find(b, transports: 2);
        a.lan.failConnect = true; // the BLE route, 16 KiB frames
        a.ble.dropAfterFrames = 13;
        Object? outcome;
        try {
          outcome = await a.engine.syncWith(peer);
        } on SyncException catch (e) {
          outcome = e;
        }
        expect(outcome, isA<SyncException>());
        expect(
          (await a.records()).first.outcome,
          anyOf(SyncOutcome.partial, SyncOutcome.failed),
        );
        await waitFor(() => b.engine.status.session is! SessionActive);
        final got = b.opCount(s.g);
        expect(got, lessThan(total - 1));
        expect(b.opsOf(s.g).map((o) => o.id).toSet(), hasLength(got));

        a.ble.dropAfterFrames = null;
        await a.engine.syncWith(await a.find(b));
        expect(b.opCount(s.g), total - 1);
        expect(b.opsOf(s.g).map((o) => o.id).toSet(), hasLength(total - 1));
        expect(unshared(a, s.g), 301);

        advance([a, b], _day * 10);
        final last = await a.engine.syncWith(await a.find(b));
        expect(last.sentOps, 301);
        expect(b.opCount(s.g), total);
        expect(b.canonical, a.canonical);
        expect(unshared(a, s.g), 0);
      },
    );
  });

  group('restart and invite while own ops are far ahead (DATA-R29-01, '
      'DATA-R31-01)', () {
    test('A (SQLite) writes 10 days ahead, restarts on the right time: the '
        'notice is ownChangesAhead at open, the next ops are stamped within '
        'the lead and reach B; a restart once time passes clears the notice '
        'and the next sync converges', () async {
      var a = await phone('a', "Alex's Pixel", sqlite: true);
      final b = await phone('b', "Priya's Pixel");
      final s = await a.seedGroup(expenses: 1);
      await b.join(a, s.g);
      await syncByLink(b, a);

      a.clock.offset = _day * 10;
      await a.addExpense(s.g, payer: s.a, owers: [s.a, s.b], description: 'X');
      final x = newest(a, s.g, 'X');
      a = await restart(a);
      expect(a.snapshot.clockNotice, ClockNotice.ownChangesAhead);
      await a.addExpense(s.g, payer: s.a, owers: [s.a, s.b], description: 'Y');
      final y = newest(a, s.g, 'Y');
      final yOp = a.opsOf(s.g).firstWhere((o) => o.entityId == y);
      expect(yOp.hlc.millis, lessThanOrEqualTo(now() + OpFactory.maxLeadMs));

      await syncByLink(b, a);
      expect(b.state.expense(y), isNotNull);
      expect(b.state.expense(x), isNull);
      expect(unshared(a, s.g), 2);

      a = await restart(a, offset: _day * 10);
      b.clock.offset = _day * 10;
      expect(a.snapshot.clockNotice, ClockNotice.none);
      await syncByLink(b, a);
      expect(b.state.expense(x), isNotNull);
      expect(b.canonical, a.canonical);
      expect(unshared(a, s.g), 0);
    });

    test('a group created while the clock ran 10 days ahead, invited on the '
        'right time with h=: the first sync completes without the held-back '
        'group, no crash, B keeps it pending; once time passes the group '
        'arrives, B claims and the claim syncs back', () async {
      final a = await phone('a', "Alex's Pixel");
      final r = await phone('r', "Ravi's Phone");
      a.clock.offset = _day * 10;
      final s = await a.seedGroup(expenses: 1, others: const ['Ravi']);
      a.clock.offset = Duration.zero;
      final link = await a.engine.inviteLinkFor(s.g);
      expect(InviteLink.tryParse(link)!.host, isNotNull);

      final join = await r.engine.acceptInvite(link);
      expect(join.alreadyMember, isFalse);
      expect(join.firstSync, isNotNull);
      expect(r.state.groups[s.g]?.group, isNull);
      expect(r.opCount(s.g), 0);
      expect(r.snapshot.pendingJoins.keys, contains(s.g));
      expect(r.snapshot.clockNotice, ClockNotice.peerAhead);
      await waitFor(() => a.engine.status.session is! SessionActive);

      // Joining again changes nothing while the group is held back.
      final again = await r.engine.acceptInvite(link);
      expect(again.alreadyMember, isTrue);
      expect(r.opCount(s.g), 0);
      await waitFor(() => a.engine.status.session is! SessionActive);

      advance([a, r], _day * 10);
      await syncByLink(r, a);
      expect(r.canonical, a.canonical);
      expect(r.snapshot.pendingJoins, isEmpty);
      final ravi = r.state.groups[s.g]!.members.values.firstWhere(
        (m) => m.displayName == 'Ravi',
      );
      await r.ledger.claimMember(s.g, ravi.id);
      final back = await syncByLink(r, a);
      expect(back.sentOps, 1);
      expect(a.state.groups[s.g]!.members[ravi.id]!.deviceId, r.deviceId);
      expect(a.canonical, r.canonical);
    });
  });

  group('defects', () {
    test(
      'SYNC-R39-01: a repeat sync across a held-back op says "got 2 changes" '
      'while it stores nothing; the same screen lists the group with 0',
      () async {
        final a = await phone('a', "Alex's Pixel");
        final b = await phone('b', "Priya's Pixel");
        final s = await a.seedGroup(expenses: 1);
        await b.join(a, s.g);
        await syncByLink(b, a);
        a.clock.offset = _day * 10;
        await a.addExpense(
          s.g,
          payer: s.a,
          owers: [s.a, s.b],
          description: 'X',
        );
        a.clock.offset = Duration.zero;
        await a.addExpense(
          s.g,
          payer: s.a,
          owers: [s.a, s.b],
          description: 'Y',
        );
        await syncByLink(b, a);
        final held = b.opCount(s.g);
        final shown = b.canonical;

        // Nothing new reaches B: the same ops come again behind the gap.
        final again = await syncByLink(b, a);
        expect(b.opCount(s.g), held);
        expect(b.canonical, shown);
        expect(again.receivedByGroup[s.g] ?? 0, 0);
        // The session screen shows S.sentAndGot(sentOps, receivedOps) above
        // the per-group receivedByGroup lines, and Sync history and
        // Activity show the record's receivedOps.
        expect(
          again.receivedOps,
          again.receivedByGroup.values.fold(0, (x, y) => x + y),
          reason: '"got ${again.receivedOps} changes" but none stored',
        );
        expect((await b.records()).first.receivedOps, 0);
      },
    );
  });

  group('own stamps ahead are not a peer ahead (DATA-R29-02)', () {
    test('A edits, its clock 3 h ahead, then edits the same entity again on '
        'the right time: A shows no notice, B (who received ops 3 h ahead) '
        'shows peerAhead, both converge on the last edit', () async {
      final a = await phone('a', "Alex's Pixel");
      final b = await phone('b', "Priya's Pixel");
      final s = await a.seedGroup(expenses: 1);
      await b.join(a, s.g);
      await syncByLink(b, a);
      final e0 = a.state.groups[s.g]!.expenses.keys.single;

      a.clock.offset = const Duration(hours: 3);
      await a.edit(e0, description: 'Ahead');
      a.clock.offset = Duration.zero;
      await a.edit(e0, description: 'Right time');
      expect(a.ledger.clockSkewDetected, isFalse);
      expect(a.snapshot.clockNotice, ClockNotice.none);
      await syncByLink(b, a);
      expect(b.state.expense(e0)!.description, 'Right time');
      expect(b.snapshot.clockNotice, ClockNotice.peerAhead);
      expect(a.snapshot.clockNotice, ClockNotice.none);
      expect(b.canonical, a.canonical);
    });

    test(
      'clocks at -1 day (B), +2 h (C) and right (A): concurrent offline '
      'edits of one field converge on the highest HLC everywhere; '
      'only phones that saw a peer more than an hour ahead flag skew',
      () async {
        final a = await phone('a', "Alex's Pixel");
        final b = await phone('b', "Priya's Pixel", sqlite: true);
        final c = await phone('c', "Sam's Galaxy");
        b.clock.offset = -_day;
        c.clock.offset = const Duration(hours: 2);
        final s = await a.seedGroup(expenses: 1);
        await b.join(a, s.g);
        await c.join(a, s.g);
        await syncByLink(b, a);
        await syncByLink(c, a);
        final e0 = a.state.groups[s.g]!.expenses.keys.single;
        await a.edit(e0, description: 'by A');
        await b.edit(e0, description: 'by B');
        await c.edit(e0, description: 'by C');
        await syncByLink(b, a);
        await syncByLink(c, b);
        await syncByLink(a, c);
        await syncByLink(b, a);
        expect(allEqual([a, b, c]), isTrue);
        final winner = [a, b, c]
            .expand((p) => p.opsOf(s.g))
            .where((o) => o.entityId == e0)
            .map((o) => o.hlc)
            .reduce((x, y) => x > y ? x : y);
        expect(winner.deviceId, c.deviceId);
        expect(a.state.expense(e0)!.description, 'by C');
        expect(a.ledger.clockSkewDetected, isTrue); // C is 2 h ahead of A
        expect(b.ledger.clockSkewDetected, isTrue); // A and C ahead of B
        expect(c.snapshot.clockNotice, ClockNotice.none);
        for (final p in [a, b, c]) {
          expect(p.opCount(s.g), a.opCount(s.g));
        }
        expect(Hlc.zero(a.deviceId) < winner, isTrue);
      },
    );
  });
}
