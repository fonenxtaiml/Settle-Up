// QA SYNC round 21: final regression sweep of multi-phone convergence on
// the integrated build. Since round 15 the Ledger folds a sync batch into
// the reducer with applyAll, which rebuilds each touched entity once after
// the last op of the batch instead of once per op (DATA-R15-01), and the
// reducer keeps the last shown name per entity so an op that leaves the
// name as it is does not normalise it again. Names are normalised by a new
// linear-time NormalForm. These probes run those paths through the real
// DefaultSyncEngine and Ledger: big mixed batches (renames, edits,
// delete/restore cycles) compared with op-by-op application in any order
// and any chunking, the same batches cut mid-flight at BLE frame size,
// raw names alternating across sessions, and newer-schema ops interleaved
// into one bulk batch for the same entity.
import 'dart:convert';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';

import 'qa_phone.dart';

const _rawDevice = 'eeeeeeee-0000-7000-8000-000000000021';

Map<String, Object?> _rawJson({
  required String groupId,
  required int counter,
  required String entityType,
  required String entityId,
  required Map<String, Object?> payload,
  required int millis,
  String kind = 'update',
  int schemaVersion = 1,
}) => {
  'id': 'eeeeeeee-0000-7000-9000-${counter.toRadixString(16).padLeft(12, '0')}',
  'groupId': groupId,
  'deviceId': _rawDevice,
  'counter': counter,
  'hlc': Hlc(millis, 0, _rawDevice).encode(),
  'entityType': entityType,
  'entityId': entityId,
  'kind': kind,
  'payload': payload,
  'schemaVersion': schemaVersion,
};

Operation _op(Map<String, Object?> json) => Operation.fromJson(
  Map<String, Object?>.from(jsonDecode(jsonEncode(json)) as Map),
);

/// Canonical state of [ops] applied one at a time, in [ops] order.
String _oneByOne(Iterable<Operation> ops) {
  final r = LedgerReducer();
  for (final op in ops) {
    r.apply(op);
  }
  return r.state.toCanonicalJson().toString();
}

/// Canonical state of [ops] applied with applyAll in chunks of random size.
String _chunked(List<Operation> ops, Random rnd) {
  final r = LedgerReducer();
  var i = 0;
  while (i < ops.length) {
    final n = 1 + rnd.nextInt(200);
    final end = min(i + n, ops.length);
    r.applyAll(ops.sublist(i, end));
    i = end;
  }
  return r.state.toCanonicalJson().toString();
}

/// Names that differ raw but some of which are equal once normalised.
const _names = [
  'Priya',
  'Ｐｒｉｙａ', // fullwidth "Priya"
  'Priya S',
  'Príya', // decomposed accent
  'Príya', // precomposed accent
  'Priya​',
  'Priya ㅤS',
];

void main() {
  late MemoryTransportHub hub;
  final phones = <QaPhone>[];

  Future<QaPhone> phone(
    String letter,
    String name, {
    bool sqlite = false,
    bool spyStore = false,
  }) async {
    final p = await QaPhone.create(
      hub,
      letter,
      name,
      sqlite: sqlite,
      spyStore: spyStore,
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

  /// A history that hits every entity many times: renames of one member
  /// through names that normalise alike, many edits of one expense,
  /// delete / restore cycles of another, a member removed, and plain adds.
  Future<({QaSeed s, ExpenseId edited, ExpenseId cycled})> busyHistory(
    QaPhone a,
  ) async {
    final s = await a.seedGroup(expenses: 2, others: const ['Priya', 'Rahul']);
    final ids = a.state.groups[s.g]!.expenses.keys.toList()..sort();
    final edited = ids.first;
    final cycled = ids.last;
    for (var i = 0; i < 60; i++) {
      await a.ledger.renameMember(s.g, s.b, _names[i % _names.length]);
    }
    for (var i = 0; i < 40; i++) {
      await a.edit(edited, description: 'Edit $i', total: 2000 + i);
    }
    for (var i = 0; i < 8; i++) {
      await a.ledger.deleteExpense(cycled);
      await a.ledger.restoreExpense(cycled);
    }
    await a.ledger.deleteExpense(cycled);
    await a.addExpenses(s, 30);
    final rahul = a.state.groups[s.g]!.members.values
        .firstWhere((m) => m.displayName == 'Rahul')
        .id;
    await a.ledger.removeMember(s.g, rahul);
    await a.ledger.updateGroup(s.g, const GroupPatch(name: 'Ｇoa trip 2'));
    return (s: s, edited: edited, cycled: cycled);
  }

  group('a sync batch rebuilt once per entity', () {
    test('one bulk session gives the state of op-by-op application, in any '
        'order and any chunking', () async {
      final a = await phone('a', 'A');
      final b = await phone('b', 'B', sqlite: true);
      final h = await busyHistory(a);
      final s = h.s;
      await b.join(a, s.g);

      final summary = await syncByLink(b, a);
      expect(summary.receivedOps, a.opCount(s.g));
      expect(summary.receivedOps, greaterThan(64), reason: 'bulk path');
      expect(b.canonical, a.canonical);
      expect(b.opCount(s.g), a.opCount(s.g));

      final gs = b.state.groups[s.g]!;
      expect(
        gs.members[s.b]!.displayName,
        a.state.groups[s.g]!.members[s.b]!.displayName,
      );
      expect(gs.expenses[h.edited]!.description, 'Edit 39');
      expect(gs.expenses[h.edited]!.money.total, 2039);
      expect(b.state.expense(h.cycled)?.isDeleted ?? true, isTrue);
      expect(gs.group!.name, 'Goa trip 2');

      // The same ops on a fresh reducer: op by op in HLC order, shuffled,
      // reversed, and with applyAll in random chunks: all the same state.
      final ops = a.opsOf(s.g);
      final want = a.canonical.toString();
      expect(_oneByOne(ops), want);
      expect(_oneByOne(ops.reversed), want);
      final rnd = Random(21);
      for (var i = 0; i < 5; i++) {
        final shuffled = [...ops]..shuffle(rnd);
        expect(_oneByOne(shuffled), want, reason: 'shuffle $i');
        expect(_chunked(shuffled, rnd), want, reason: 'chunks $i');
        // Duplicates within and across chunks change nothing.
        expect(_chunked([...shuffled, ...shuffled.take(100)], rnd), want);
      }

      // Repeat syncs move nothing.
      for (var i = 0; i < 3; i++) {
        final again = await syncByLink(b, a);
        expect((again.sentOps, again.receivedOps), (0, 0));
      }
      expect(b.canonical, a.canonical);
    });

    for (final drop in [3, 5, 8, 12]) {
      test('the same history over BLE frames cut after $drop frames, then '
          'resumed: no double apply, same state', () async {
        final a = await phone('a', 'A', spyStore: true);
        final c = await phone('c', 'C', spyStore: true);
        final h = await busyHistory(a);
        final s = h.s;
        await c.join(a, s.g);
        await a.engine.startHosting();
        // Force the BLE route (16 KiB frames).
        c.lan.failConnect = true;
        c.ble.dropAfterFrames = drop;
        final peer = await c.find(a, transports: 2);
        Object? outcome;
        try {
          outcome = await c.engine.syncWith(peer);
        } on SyncException catch (e) {
          outcome = e;
        }
        expect(outcome, isA<SyncException>(), reason: 'drop at $drop');
        final partial = c.opCount(s.g);
        expect(partial, lessThan(a.opCount(s.g)));
        // What arrived is a prefix-closed set per device and its state is
        // the op-by-op state of exactly those ops.
        expect(c.canonical.toString(), _oneByOne(c.opsOf(s.g)));

        c.ble.dropAfterFrames = null;
        await waitFor(() => a.engine.status.session is! SessionActive);
        final again = await c.engine.syncWith(await c.find(a));
        expect(again.transport, TransportKind.ble);
        expect(c.canonical, a.canonical);
        expect(c.opCount(s.g), a.opCount(s.g));
        expect(c.spy.duplicatesIgnored + a.spy.duplicatesIgnored, 0);
        final last = (await c.records()).first;
        expect(last.outcome, SyncOutcome.completed);
        expect(c.snapshot.unsharedCounts[s.g] ?? 0, 0);
      });
    }

    test('A and C converge through B without meeting, B receiving both '
        'histories as bulk batches', () async {
      final a = await phone('a', 'A');
      final b = await phone('b', 'B', sqlite: true);
      final c = await phone('c', 'C');
      final h = await busyHistory(a);
      final s = h.s;
      await b.join(a, s.g);
      await c.join(a, s.g);
      await syncByLink(b, a);
      await syncByLink(c, b);
      // Both edit offline: C renames Priya, A renames her too, both edit
      // the same expense, C restores the deleted one, A deletes the edited.
      await c.ledger.renameMember(s.g, s.b, 'Priya K');
      await c.edit(h.edited, description: 'From C');
      await c.ledger.restoreExpense(h.cycled);
      await c.addExpenses(s, 70, base: 9000);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await a.ledger.renameMember(s.g, s.b, 'Ｐriya A');
      await a.ledger.deleteExpense(h.edited);
      await a.addExpenses(s, 70, base: 7000);

      await syncByLink(b, c);
      await syncByLink(a, b);
      await syncByLink(c, b);
      expect(allEqual([a, b, c]), isTrue);
      expect(a.state.groups[s.g]!.members[s.b]!.displayName, 'Priya A');
      expect(a.state.expense(h.edited)?.isDeleted ?? true, isTrue);
      expect(a.state.expense(h.cycled)?.isDeleted, isFalse);
      // Fixed point.
      final ring = [(a, b), (b, c), (c, a)];
      for (final (x, y) in ring) {
        final r = await syncByLink(x, y);
        expect((r.sentOps, r.receivedOps), (0, 0));
      }
      expect(c.canonical.toString(), _oneByOne(c.opsOf(s.g)));
    });
  });

  group('raw names across batches', () {
    test('a raw peer flips a name between forms in separate sessions and '
        'within one batch: every phone shows the newest, normalised', () async {
      final a = await phone('a', 'A');
      final b = await phone('b', 'B');
      final s = await a.seedGroup(expenses: 1);
      await b.join(a, s.g);
      await syncByLink(b, a);
      final t0 = DateTime.now().millisecondsSinceEpoch;
      var counter = 0;
      Operation rename(String name, int dt) => _op(
        _rawJson(
          groupId: s.g,
          counter: ++counter,
          entityType: 'member',
          entityId: s.b,
          payload: {'displayName': name},
          millis: t0 + dt,
        ),
      );
      final rounds = <(List<Operation>, String)>[
        ([rename('ＰriyaㅤX', 10)], 'Priya X'),
        ([rename('Priya', 20)], 'Priya'),
        // Same raw value as round 1: the shown name must follow it back.
        ([rename('ＰriyaㅤX', 30)], 'Priya X'),
        // One batch, out of HLC order, bigger than the bulk threshold.
        (
          [
            for (var i = 0; i < 80; i++)
              rename(i.isEven ? 'Príya $i' : 'Q $i', 1000 - i),
          ],
          'Príya 0',
        ),
        // An older write arrives late: it loses.
        ([rename('Late', 15)], 'Príya 0'),
      ];
      for (final (batch, rawWinner) in rounds) {
        await a.ledger.applyRemote(s.g, batch);
        await syncByLink(b, a);
        final want = NameText.display(rawWinner, NameText.maxLength);
        for (final p in [a, b]) {
          expect(
            p.state.groups[s.g]!.members[s.b]!.displayName,
            want,
            reason: '${p.deviceName} after $rawWinner',
          );
        }
        expect(a.canonical, b.canonical);
        expect(a.canonical.toString(), _oneByOne(a.opsOf(s.g)));
      }
    });

    test(
      'newer-schema ops interleaved into one bulk batch for the same '
      'member: relayed byte for byte, never applied, v1 winner shown',
      () async {
        final a = await phone('a', 'A');
        final b = await phone('b', 'B', sqlite: true);
        final c = await phone('c', 'C');
        final s = await a.seedGroup(expenses: 1);
        await b.join(a, s.g);
        await c.join(a, s.g);
        final t0 = DateTime.now().millisecondsSinceEpoch;
        final raw = <Map<String, Object?>>[
          for (var i = 0; i < 100; i++)
            _rawJson(
              groupId: s.g,
              counter: i + 1,
              entityType: 'member',
              entityId: s.b,
              // Every third op is from a newer app, with the highest HLCs.
              payload: {'displayName': i % 3 == 0 ? 'V2 $i' : 'Príya $i'},
              millis: t0 + (i % 3 == 0 ? 100000 + i : i),
              schemaVersion: i % 3 == 0 ? kSchemaVersion + 1 : 1,
            ),
        ];
        final wire = [for (final m in raw) jsonEncode(m)];
        final ops = [for (final m in raw) _op(m)];
        await a.ledger.applyRemote(s.g, ops);
        await syncByLink(b, a);
        await syncByLink(c, b);
        for (final p in [a, b, c]) {
          final stored = {
            for (final o in p.opsOf(s.g))
              if (o.deviceId == _rawDevice) o.counter: jsonEncode(o.toJson()),
          };
          expect(stored.length, 100, reason: p.deviceName);
          for (var i = 0; i < 100; i++) {
            if (i % 3 == 0) {
              expect(stored[i + 1], wire[i], reason: '${p.deviceName} op $i');
            }
          }
          expect(
            p.state.groups[s.g]!.members[s.b]!.displayName,
            'Príya 98',
            reason: p.deviceName,
          );
          expect((await p.ledger.versionVector(s.g))[_rawDevice], 100);
        }
        expect(allEqual([a, b, c]), isTrue);
        final again = await syncByLink(c, a);
        expect((again.sentOps, again.receivedOps), (0, 0));
      },
    );
  });

  group('phones whose names show nothing', () {
    for (final (aName, bName, latency, stagger) in const [
      ('ㅤ', '​', 0, 0),
      ('ㅤ', '​', 30, 5),
      ('ㅤ', 'ㅤ', 30, 25),
      ("Alex's Pixel (2)", 'ㅤ', 30, 5),
      ("Alex's Pixel", "Alex's Pixel (2)", 30, 5),
    ]) {
      test('both tap Sync at once (${jsonEncode(aName)} / ${jsonEncode(bName)}'
          ', latency ${latency}ms, stagger ${stagger}ms): both succeed, one '
          'completed record each, rows and records never blank', () async {
        hub.latency = Duration(milliseconds: latency);
        final alex = await phone('a', aName);
        final priya = await phone('b', bName);
        final seed = await alex.seedGroup(expenses: 1);
        await priya.join(alex, seed.g);
        await syncByLink(priya, alex);
        await alex.addExpenses(seed, 5);
        await priya.addExpenses(seed, 5, base: 700);
        final ra0 = (await alex.records()).length;
        final rp0 = (await priya.records()).length;
        await alex.engine.startHosting();
        await priya.engine.startHosting();
        Future<NearbyPeer> only(QaPhone p) async {
          if (!p.engine.status.discovering) await p.engine.startDiscovery();
          final list = await p.engine
              .watchNearby()
              .firstWhere((l) => l.isNotEmpty)
              .timeout(const Duration(seconds: 3));
          expect(list, hasLength(1));
          expect(list.single.name.trim(), isNotEmpty);
          return list.single;
        }

        final toPriya = await only(alex);
        final toAlex = await only(priya);
        Future<Object> tap(QaPhone p, NearbyPeer to) => p.engine
            .syncWith(to)
            .then<Object>((s) => s, onError: (Object e) => e);
        final f1 = tap(alex, toPriya);
        await Future<void>.delayed(Duration(milliseconds: stagger));
        final f2 = tap(priya, toAlex);
        final results = await Future.wait([f1, f2])
            .timeout(const Duration(seconds: 10));
        expect(
          results.whereType<SyncSummary>(),
          hasLength(2),
          reason: 'results: $results',
        );
        expect(priya.canonical, alex.canonical);
        await waitFor(
          () =>
              alex.engine.status.session is! SessionActive &&
              priya.engine.status.session is! SessionActive,
        );
        await Future<void>.delayed(const Duration(milliseconds: 100));
        for (final (p, before) in [(alex, ra0), (priya, rp0)]) {
          final all = await p.records();
          final mine = all.take(all.length - before).toList();
          expect(
            mine.map((r) => r.outcome),
            [SyncOutcome.completed],
            reason:
                '${p.letter}: ${mine.map((r) => '${r.outcome} ${r.error}')}',
          );
          expect(mine.single.peerName.trim(), isNotEmpty);
        }
      });
    }
  });
}
