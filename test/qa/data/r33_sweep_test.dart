// QA DATA round 33: reverification sweep around the DATA-R32-01 fix (a
// command that fails to store publishes the clock notice it changed, so the
// snapshot carries the getter's value).
//
// The class probed here: every local command kind that stamps after an
// entity's newest op (rename, remove, merge and claim a member, delete and
// restore an expense, edit a payment, edit and delete a group) on an entity
// a peer stamped more than an hour ahead, refused by the store or landed
// with a lost reply, on the SQLite store the app uses. After each failure
// the snapshot notice equals the getter, nothing else moved in memory, the
// counter is not burned, the next command works, and after a restart own
// counters are contiguous and own stamps unique and ascending.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/sync/protocol/session.dart';

import '../../sync/support/harness.dart';
import 'qa_data_harness.dart';

const int _hour = 60 * 60 * 1000;
const int _day = 24 * _hour;

/// What B does with its clock ahead, and the command A then runs on it.
typedef Case = ({
  Future<String> Function(FilePhone b, Trip t) peer,
  Future<void> Function(FilePhone a, Trip t, String id, int n) local,
});

PaymentDraft _pay(Trip t, int amount) => PaymentDraft(
  groupId: t.g,
  from: t.sam,
  to: t.me,
  amount: amount,
  currency: 'INR',
  method: PaymentMethod.cash,
  date: utcFromMillis(kQaBaseMs),
);

final Map<String, Case> cases = {
  'renameMember': (
    peer: (b, t) => b.ledger.addMember(t.g, displayName: 'Kai'),
    local: (a, t, id, n) => a.ledger.renameMember(t.g, id, 'Kai $n'),
  ),
  'removeMember': (
    peer: (b, t) => b.ledger.addMember(t.g, displayName: 'Kai'),
    local: (a, t, id, n) async {
      if (n == 0) return a.ledger.removeMember(t.g, id);
      await a.ledger.renameMember(t.g, t.sam, 'Sam $n');
    },
  ),
  'mergeMembers': (
    peer: (b, t) => b.ledger.addMember(t.g, displayName: 'Kai'),
    local: (a, t, id, n) async {
      if (n == 0) return a.ledger.mergeMembers(t.g, from: id, into: t.sam);
      await a.ledger.renameMember(t.g, id, 'Kai $n');
    },
  ),
  'claimMember': (
    peer: (b, t) => b.ledger.addMember(t.g, displayName: 'Kai'),
    local: (a, t, id, n) async {
      if (n == 0) return a.ledger.claimMember(t.g, id);
      await a.ledger.renameMember(t.g, id, 'Kai $n');
    },
  ),
  'deleteExpense': (
    peer: (b, t) =>
        b.ledger.addExpense(qaDraft(t.g, [t.me, t.sam], description: 'Boat')),
    local: (a, t, id, n) async {
      if (n == 0) return a.ledger.deleteExpense(id);
      await a.ledger.updateExpense(
        id,
        qaDraft(t.g, [t.me, t.sam], description: 'Boat $n'),
      );
    },
  ),
  'restoreExpense': (
    peer: (b, t) async {
      final x = await b.ledger.addExpense(
        qaDraft(t.g, [t.me, t.sam], description: 'Boat'),
      );
      await b.ledger.deleteExpense(x);
      return x;
    },
    local: (a, t, id, n) async {
      if (n == 0) return a.ledger.restoreExpense(id);
      await a.ledger.updateExpense(
        id,
        qaDraft(t.g, [t.me, t.sam], description: 'Boat $n'),
      );
    },
  ),
  'updatePayment': (
    peer: (b, t) => b.ledger.recordPayment(_pay(t, 500)),
    local: (a, t, id, n) => a.ledger.updatePayment(id, _pay(t, 600 + n)),
  ),
  'updateGroup': (
    peer: (b, t) async {
      await b.ledger.updateGroup(t.g, const GroupPatch(name: 'Goa B'));
      return t.g;
    },
    local: (a, t, id, n) =>
        a.ledger.updateGroup(t.g, GroupPatch(name: 'Goa $n')),
  ),
  'deleteGroup': (
    peer: (b, t) async {
      await b.ledger.updateGroup(t.g, const GroupPatch(name: 'Goa B'));
      return t.g;
    },
    local: (a, t, id, n) async {
      if (n == 0) return a.ledger.deleteGroup(t.g);
      // The group is gone after a delete that landed; any later command
      // on another group still has to work.
      await a.ledger.createGroup(
        NewGroup(name: 'Next $n', type: GroupType.trip, currency: 'INR'),
      );
    },
  ),
};

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

  Future<void> sync(SyncStore initiator, SyncStore responder) async {
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
    expect(r[0].outcome, SyncOutcome.completed, reason: r[0].message);
  }

  /// B runs [c]'s peer step two days ahead, syncs to A, and A restarts
  /// (the flag is not persisted), so A's notice is none again.
  Future<String> peerAhead(Case c) async {
    await b.ledger.registerJoinedGroup(
      t.g,
      (await a.ledger.groupKeys())[t.g]!,
      'Goa trip',
    );
    await sync(a.ledger, b.ledger);
    b.clock.now = kQaBaseMs + 2 * _day;
    final id = await c.peer(b, t);
    await sync(b.ledger, a.ledger);
    expect(a.snap.clockNotice, ClockNotice.peerAhead);
    await a.restart();
    expect(a.snap.clockNotice, ClockNotice.none);
    return id;
  }

  void expectSame(String when) => expect(
    a.snap.clockSkewDetected,
    a.ledger.clockSkewDetected,
    reason:
        '$when: snapshot ${a.snap.clockNotice}, getter '
        '${a.ledger.clockSkewDetected}',
  );

  /// Own counters of every group are 1..n with no gap or reuse, and own
  /// stamps are unique and ascend with the counter.
  void expectOwnOpsSound(String when) {
    final byGroup = <GroupId, List<Operation>>{};
    for (final op in a.snap.ops) {
      if (op.deviceId == a.deviceId) (byGroup[op.groupId] ??= []).add(op);
    }
    for (final e in byGroup.entries) {
      final ops = e.value..sort((x, y) => x.counter.compareTo(y.counter));
      expect(
        [for (final o in ops) o.counter],
        [for (var i = 1; i <= ops.length; i++) i],
        reason: '$when: counters of ${e.key}',
      );
      for (var i = 1; i < ops.length; i++) {
        expect(
          ops[i].hlc > ops[i - 1].hlc,
          isTrue,
          reason: '$when: stamps ascend with the counter in ${e.key}',
        );
      }
    }
  }

  for (final e in cases.entries) {
    test('${e.key} of an entity a peer stamped 2 days ahead, refused by the '
        'store: the notice is published, nothing else moves, the counter is '
        'not burned, and the next command works', () async {
      final id = await peerAhead(e.value);
      final before = a.snap;
      final counter = a.mineIn(t.g).length;
      final seen = <ClockNotice>[];
      final sub = a.ledger
          .watch()
          .skip(1)
          .listen((s) => seen.add(s.clockNotice));
      faulty.failNextInsert = true;
      await expectLater(
        e.value.local(a, t, id, 0),
        throwsA(
          isA<LedgerException>().having(
            (x) => x.code,
            'code',
            LedgerErrorCode.storageFailed,
          ),
        ),
      );
      await pumpEventQueue();
      // ignore: avoid_print
      print(
        '[r33] ${e.key} refused: snapshot ${a.snap.clockNotice}, getter '
        '${a.ledger.clockSkewDetected}, published $seen',
      );
      expectSame('${e.key} refused');
      expect(a.ledger.clockSkewDetected, isTrue);
      expect(seen, [ClockNotice.peerAhead], reason: 'published once');
      expect(a.snap.ops.length, before.ops.length);
      expect(a.snap.state.toCanonicalJson(), before.state.toCanonicalJson());
      expect(a.snap.unsharedCounts, before.unsharedCounts);
      expect(a.mineIn(t.g).length, counter);
      await e.value.local(a, t, id, 0);
      expectSame('${e.key} retried');
      expect(a.mineIn(t.g).length, greaterThan(counter));
      await e.value.local(a, t, id, 1);
      expectSame('${e.key} then');
      expectOwnOpsSound('${e.key} before restart');
      final state = a.snap.state.toCanonicalJson();
      await a.restart();
      expect(a.snap.state.toCanonicalJson(), state);
      expectOwnOpsSound('${e.key} after restart');
      await e.value.local(a, t, id, 2);
      expectOwnOpsSound('${e.key} after restart and a command');
      expectSame('${e.key} after restart and a command');
      await sub.cancel();
    });

    test('${e.key} of an entity a peer stamped 2 days ahead, landed with a '
        'lost reply: the notice matches, and after a restart own ops are '
        'contiguous and unique', () async {
      final id = await peerAhead(e.value);
      faulty.failAfterNextInsert = true;
      await expectLater(
        e.value.local(a, t, id, 0),
        throwsA(isA<LedgerException>()),
      );
      expectSame('${e.key} lost reply');
      for (var n = 1; n <= 3; n++) {
        try {
          await e.value.local(a, t, id, n);
        } on LedgerException catch (x) {
          // The first may reuse the counter the lost write took.
          expect(n, 1, reason: '${e.key}: only the first may collide');
          expect(x.code, LedgerErrorCode.storageFailed);
        }
        expectSame('${e.key} command $n');
      }
      await a.restart();
      expectOwnOpsSound('${e.key} after restart');
      await e.value.local(a, t, id, 4);
      expectOwnOpsSound('${e.key} after restart and a command');
    });
  }
}
