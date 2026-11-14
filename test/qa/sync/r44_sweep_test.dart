// QA SYNC round 44, final regression sweep: a two-way, two-group sync over
// BLE (16 KiB frames) cut after every frame count from 1 until it
// completes. At every cut point, on both phones: no op stored twice, the
// record's outcome is partial exactly when something was shared or
// stored, "sent" equals the drop in the phone's own unshared badge (less,
// at the next sync, the ops the peer stored without its ACK arriving), "got"
// equals the ops newly stored, and a second sync completes the rest with
// canonical snapshots equal and both badges at zero. A second group runs
// three phones that gossip with a cut on every hop.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';

import 'qa_phone.dart';

const _v2Device = 'dddddddd-0000-7000-8000-000000000001';

/// What a newer app wrote: [count] ops on unknown entities, every 10th a
/// change to [expense] under the new schema (never applied here).
List<String> _newerOps(String groupId, String expense, int count) => [
  for (var c = 1; c <= count; c++)
    jsonEncode({
      'id': 'dddddddd-0000-7000-9000-${c.toRadixString(16).padLeft(12, '0')}',
      'groupId': groupId,
      'deviceId': _v2Device,
      'counter': c,
      'hlc': Hlc(DateTime.now().millisecondsSinceEpoch, c, _v2Device).encode(),
      'entityType': c % 10 == 0 ? 'expense' : 'receipt',
      'entityId': c % 10 == 0 ? expense : 'r$c',
      'kind': c % 10 == 0 ? 'update' : 'attach',
      'payload': c % 10 == 0
          ? {
              'description': 'Changed by v2',
              'splitV2': {'x': c},
            }
          : {'expenseId': expense, 'note': 'snap ✓ ' * 40},
      'schemaVersion': kSchemaVersion + 1,
      'attachments': [
        {'sha256': 'abc$c', 'bytes': c},
      ],
    }),
];

void main() {
  late MemoryTransportHub hub;
  final phones = <QaPhone>[];

  Future<QaPhone> phone(
    String letter,
    String name, {
    bool sqlite = false,
    int lanFrame = 1 << 20,
    SkewedClock? clock,
  }) async {
    final p = await QaPhone.create(
      hub,
      letter,
      name,
      sqlite: sqlite,
      clock: clock,
      maxFrameBytes: {TransportKind.lan: lanFrame, TransportKind.ble: 16384},
    );
    phones.add(p);
    return p;
  }

  setUp(() => hub = MemoryTransportHub());
  tearDown(() async {
    for (final p in phones) {
      await p.dispose();
    }
    phones.clear();
  });

  int badge(QaPhone p) =>
      p.snapshot.unsharedCounts.values.fold(0, (a, b) => a + b);

  Future<SyncRecord?> nextRecord(QaPhone p, int before) async {
    final ok = await waitFor(
      () async => (await p.records()).length > before,
      timeout: const Duration(seconds: 3),
    );
    return ok ? (await p.records()).first : null;
  }

  /// Dials [b] over BLE only (16 KiB frames), the link cut after [cut]
  /// frames (null: no cut). Returns both records.
  Future<(SyncRecord, SyncRecord?)> bleSync(
    QaPhone a,
    QaPhone b, {
    int? cut,
  }) async {
    final aBefore = (await a.records()).length;
    final bBefore = (await b.records()).length;
    await b.engine.startHosting();
    final peer = await a.find(b, transports: 2);
    a.lan.failConnect = true;
    a.ble.dropAfterFrames = cut;
    try {
      await a.engine.syncWith(peer);
    } on SyncException {
      // An interrupted session; the records say how it ended.
    }
    a.ble.dropAfterFrames = null;
    a.lan.failConnect = false;
    await waitFor(() => b.engine.status.session is! SessionActive);
    final ra = await nextRecord(a, aBefore);
    expect(ra, isNotNull, reason: '${a.deviceName} wrote no sync record');
    // The responder keeps no record of a link cut before the handshake.
    final rb = await nextRecord(b, bBefore);
    await b.engine.stopHosting();
    return (ra!, rb);
  }

  void expectNoDuplicates(QaPhone p) {
    final ids = [for (final op in p.snapshot.ops) op.id];
    expect(ids.toSet(), hasLength(ids.length), reason: p.deviceName);
  }

  void expectCounts(
    QaPhone p,
    SyncRecord? r, {
    required int badgeBefore,
    required int opsBefore,
    required String at,
    int unconfirmed = 0,
  }) {
    if (r == null) {
      expect(badge(p), badgeBefore, reason: '${p.deviceName} $at: no record');
      expect(p.totalOps, opsBefore, reason: '${p.deviceName} $at: no record');
      return;
    }
    // Ops the peer stored in an interrupted session whose ACK never came
    // back leave the badge at the next sync without being sent again.
    expect(
      r.sentOps,
      badgeBefore - badge(p) - unconfirmed,
      reason: '${p.deviceName} $at: sent vs badge drop',
    );
    expect(
      r.receivedOps,
      p.totalOps - opsBefore,
      reason: '${p.deviceName} $at: got vs ops newly stored',
    );
    if (r.outcome != SyncOutcome.completed) {
      final something = r.sentOps > 0 || r.receivedOps > 0;
      expect(
        r.outcome,
        something ? SyncOutcome.partial : SyncOutcome.failed,
        reason: '${p.deviceName} $at: outcome',
      );
    }
  }

  for (final (sqlite, step) in const [(false, 1), (true, 4)]) {
    test(
      'two-way, two-group BLE sync cut after ${step == 1 ? 'every' : 'every 4th'} frame count '
      '(${sqlite ? 'sqlite' : 'memory'} stores): counts, '
      'outcome and no double apply hold on both phones; the next sync '
      'converges',
      () async {
        var completedAt = 0;
        for (var cut = 1; cut <= 160; cut += step) {
          hub = MemoryTransportHub();
          final a = await phone('a', "Alex's Pixel", sqlite: sqlite);
          final b = await phone('b', "Priya's Pixel", sqlite: sqlite);
          final s1 = await a.seedGroup(expenses: 2);
          final s2 = await a.seedGroup(expenses: 1, name: 'Flat');
          await b.join(a, s1.g);
          await b.join(a, s2.g);
          await bleSync(b, a);
          expect(allEqual([a, b]), isTrue);

          // Offline on both phones: bulk adds, a same-field edit on both, an
          // edit on one against a delete on the other.
          final e0 = a.state.groups[s1.g]!.expenses.keys.first;
          final e1 = a.state.groups[s1.g]!.expenses.keys.last;
          await a.addExpenses(s1, 260, base: 3000);
          await a.addExpenses(s2, 40, base: 5000);
          await b.addExpenses(s1, 150, base: 7000);
          await a.edit(e0, description: 'Alex dinner');
          await b.edit(e0, description: 'Priya dinner');
          await a.edit(e1, total: 999);
          await b.ledger.deleteExpense(e1);

          final aBadge = badge(a), bBadge = badge(b);
          final aOps = a.totalOps, bOps = b.totalOps;
          final (ra, rb) = await bleSync(a, b, cut: cut);
          final at = 'cut $cut';
          expectNoDuplicates(a);
          expectNoDuplicates(b);
          expectCounts(a, ra, badgeBefore: aBadge, opsBefore: aOps, at: at);
          expectCounts(b, rb, badgeBefore: bBadge, opsBefore: bOps, at: at);
          if (cut > 1) expect(rb, isNotNull, reason: '$at: responder record');
          expect(
            ra.sentOps,
            lessThanOrEqualTo(rb?.receivedOps ?? 0),
            reason: at,
          );
          expect(
            rb?.sentOps ?? 0,
            lessThanOrEqualTo(ra.receivedOps),
            reason: at,
          );

          final done = ra.outcome == SyncOutcome.completed;
          if (!done) {
            final aBadge2 = badge(a), bBadge2 = badge(b);
            final aOps2 = a.totalOps, bOps2 = b.totalOps;
            final (ra2, rb2) = await bleSync(a, b);
            expect(ra2.outcome, SyncOutcome.completed, reason: '$at second');
            expect(rb2?.outcome, SyncOutcome.completed, reason: '$at second');
            expectCounts(
              a,
              ra2,
              badgeBefore: aBadge2,
              opsBefore: aOps2,
              at: at,
              unconfirmed: (rb?.receivedOps ?? 0) - ra.sentOps,
            );
            expectCounts(
              b,
              rb2,
              badgeBefore: bBadge2,
              opsBefore: bOps2,
              at: at,
              unconfirmed: ra.receivedOps - (rb?.sentOps ?? 0),
            );
            expectNoDuplicates(a);
            expectNoDuplicates(b);
          }
          expect(badge(a), 0, reason: at);
          expect(badge(b), 0, reason: at);
          expect(a.totalOps, b.totalOps, reason: at);
          expect(allEqual([a, b]), isTrue, reason: at);
          final x = a.state.expense(e0)!.description;
          expect(x, anyOf('Alex dinner', 'Priya dinner'), reason: at);
          expect(a.state.expense(e1)?.isDeleted ?? true, isTrue, reason: at);

          // Repeat syncs change nothing.
          final snap = a.canonical.toString();
          final ops = a.totalOps;
          final (ra3, rb3) = await bleSync(a, b);
          expect((ra3.sentOps, ra3.receivedOps), (0, 0), reason: at);
          expect((rb3?.sentOps, rb3?.receivedOps), (0, 0), reason: at);
          expect(a.canonical.toString(), snap, reason: at);
          expect(a.totalOps, ops, reason: at);

          for (final p in phones) {
            await p.dispose();
          }
          phones.clear();
          if (done) {
            completedAt = cut;
            break;
          }
        }
        expect(
          completedAt,
          greaterThan(50),
          reason: 'the sweep cut real points',
        );
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );
  }

  test('three phones gossip A-B, B-C, C-A with every hop cut once at a '
      'different point, then once clean: all three converge and every '
      'own badge reaches zero', () async {
    for (final cuts in const [
      [3, 7, 11],
      [5, 2, 9],
      [12, 6, 4],
    ]) {
      hub = MemoryTransportHub();
      final a = await phone('a', "Alex's Pixel");
      final b = await phone('b', "Priya's Pixel");
      final c = await phone('c', "Sam's Pixel");
      final s = await a.seedGroup(expenses: 2);
      await b.join(a, s.g);
      await c.join(a, s.g);
      await bleSync(b, a);
      await bleSync(c, b);
      await a.addExpenses(s, 120, base: 1000);
      await b.addExpenses(s, 90, base: 2000);
      await c.addExpenses(s, 70, base: 3000);
      final e = a.state.groups[s.g]!.expenses.keys.first;
      await a.edit(e, description: 'A');
      await c.edit(e, description: 'C');
      await b.ledger.deleteExpense(e);

      final hops = [(a, b), (b, c), (c, a)];
      for (var i = 0; i < hops.length; i++) {
        final (x, y) = hops[i];
        await bleSync(x, y, cut: cuts[i]);
        expectNoDuplicates(x);
        expectNoDuplicates(y);
      }
      for (var round = 0; round < 2; round++) {
        for (final (x, y) in hops) {
          await bleSync(x, y);
        }
      }
      expect(allEqual([a, b, c]), isTrue, reason: '$cuts');
      expect({a.totalOps, b.totalOps, c.totalOps}, hasLength(1));
      for (final p in [a, b, c]) {
        expect(badge(p), 0, reason: '${p.deviceName} $cuts');
        expectNoDuplicates(p);
      }
      expect(a.state.expense(e)?.isDeleted ?? true, isTrue);
      for (final p in phones) {
        await p.dispose();
      }
      phones.clear();
    }
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('newer-schema ops relayed A -> B over BLE cut at many points, then '
      'B -> C: stored byte for byte, counted once, never applied, and the '
      'version vector stops them being re-sent', () async {
    for (var cut = 2; cut <= 60; cut += 3) {
      hub = MemoryTransportHub();
      final a = await phone('a', "Alex's Pixel");
      final b = await phone('b', "Priya's Pixel");
      final c = await phone('c', "Sam's Pixel");
      final s = await a.seedGroup(expenses: 2);
      await b.join(a, s.g);
      await c.join(a, s.g);
      final e = a.state.groups[s.g]!.expenses.keys.first;
      final wire = _newerOps(s.g, e, 150);
      await a.ledger.applyRemote(s.g, [
        for (final w in wire)
          Operation.fromJson(Map<String, Object?>.from(jsonDecode(w) as Map)),
      ]);
      await a.addExpenses(s, 30, base: 4000);
      final at = 'cut $cut';

      final bOps = b.totalOps;
      final (_, rb) = await bleSync(a, b, cut: cut);
      expectNoDuplicates(b);
      expect(rb?.receivedOps ?? 0, b.totalOps - bOps, reason: at);
      final bOps2 = b.totalOps;
      final (_, rb2) = await bleSync(a, b);
      expect(rb2?.outcome, SyncOutcome.completed, reason: at);
      expect(rb2!.receivedOps, b.totalOps - bOps2, reason: at);
      expect(b.totalOps, a.totalOps, reason: at);
      final (rc, _) = await bleSync(c, b);
      expect(rc.receivedOps, a.totalOps, reason: at);

      for (final p in [a, b, c]) {
        final stored = [
          for (final o in p.opsOf(s.g))
            if (o.deviceId == _v2Device) jsonEncode(o.toJson()),
        ]..sort();
        expect(stored, [...wire]..sort(), reason: '${p.deviceName} $at');
        expect(
          (await p.ledger.versionVector(s.g))[_v2Device],
          150,
          reason: '${p.deviceName} $at',
        );
        expect(p.state.expense(e)!.description, isNot('Changed by v2'));
        expectNoDuplicates(p);
      }
      expect(allEqual([a, b, c]), isTrue, reason: at);
      final (again, _) = await bleSync(c, a);
      expect((again.sentOps, again.receivedOps), (0, 0), reason: at);

      for (final p in phones) {
        await p.dispose();
      }
      phones.clear();
    }
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('invite with h= host whose first sync is cut at many points: the '
      'join stands, nothing is stored twice, a second accept completes the '
      'group and the claim syncs back', () async {
    var partials = 0;
    for (var cut = 1; cut <= 40; cut += 2) {
      hub = MemoryTransportHub();
      // 16 KiB LAN frames, so the group arrives in several batches.
      final a = await phone('a', "Alex's Pixel", lanFrame: 16384);
      final r = await phone('r', "Ravi's Galaxy", lanFrame: 16384);
      final s = await a.seedGroup(expenses: 150, others: ['Ravi', 'Priya']);
      final link = await a.engine.inviteLinkFor(s.g);
      final at = 'cut $cut';
      r.lan.dropAfterFrames = cut;
      final first = await r.engine.acceptInvite(link);
      r.lan.dropAfterFrames = null;
      expect(first.groupId, s.g, reason: at);
      expect(first.alreadyMember, isFalse, reason: at);
      expectNoDuplicates(r);
      await waitFor(() => a.engine.status.session is! SessionActive);
      final held = r.opCount(s.g);
      expect(held, lessThanOrEqualTo(a.opCount(s.g)), reason: at);
      if (held > 0 && held < a.opCount(s.g)) partials++;
      if (first.firstSync != null) {
        expect(first.firstSync!.receivedOps, held, reason: at);
      }

      final again = await r.engine.acceptInvite(link);
      expect(again.alreadyMember, isTrue, reason: at);
      expect(again.firstSync, isNotNull, reason: at);
      expect(again.firstSync!.receivedOps, a.opCount(s.g) - held, reason: at);
      expect(r.snapshot.pendingJoins, isEmpty, reason: at);
      expect(allEqual([a, r]), isTrue, reason: at);
      expectNoDuplicates(r);

      await waitFor(() => a.engine.status.session is! SessionActive);
      await r.ledger.claimMember(s.g, s.b);
      final back = await r.engine.syncWithLink(link);
      expect(back.sentOps, 1, reason: at);
      expect(
        a.state.groups[s.g]!.members[s.b]!.deviceId,
        r.deviceId,
        reason: at,
      );
      expect(badge(r), 0, reason: at);
      for (final p in phones) {
        await p.dispose();
      }
      phones.clear();
    }
    expect(partials, greaterThan(3), reason: 'cuts landed mid-transfer');
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('skewed clocks (A +2 h, B -1 day) with the sync cut at several '
      'points: convergence, B flags the skew, A wins the same-field edit '
      'on both phones in either direction', () async {
    for (final cut in const [4, 9, 14, 19, 24, 29]) {
      hub = MemoryTransportHub();
      final a = await phone(
        'a',
        "Alex's Pixel",
        clock: SkewedClock(const Duration(hours: 2)),
      );
      final b = await phone(
        'b',
        "Priya's Pixel",
        clock: SkewedClock(const Duration(days: -1)),
      );
      final s = await a.seedGroup(expenses: 2);
      await b.join(a, s.g);
      await bleSync(b, a);
      final e = a.state.groups[s.g]!.expenses.keys.first;
      final gone = a.state.groups[s.g]!.expenses.keys.last;
      await b.edit(e, description: 'Priya');
      await a.edit(e, description: 'Alex');
      await b.addExpenses(s, 60, base: 2000);
      await a.addExpenses(s, 120, base: 1000);
      await b.ledger.deleteExpense(gone);
      final at = 'cut $cut';

      await bleSync(a, b, cut: cut);
      expectNoDuplicates(a);
      expectNoDuplicates(b);
      final (ra, rb) = await bleSync(b, a);
      expect(ra.outcome, SyncOutcome.completed, reason: at);
      expect(rb?.outcome, SyncOutcome.completed, reason: at);
      expect(allEqual([a, b]), isTrue, reason: at);
      expect(a.state.expense(e)!.description, 'Alex', reason: at);
      expect(a.state.expense(gone)!.isDeleted, isTrue, reason: at);
      expect(b.ledger.clockSkewDetected, isTrue, reason: at);
      expect(badge(a) + badge(b), 0, reason: at);
      await bleSync(a, b);
      expect(b.state.expense(e)!.description, 'Alex', reason: at);
      expect(allEqual([a, b]), isTrue, reason: at);
      for (final p in phones) {
        await p.dispose();
      }
      phones.clear();
    }
  }, timeout: const Timeout(Duration(minutes: 3)));
}
