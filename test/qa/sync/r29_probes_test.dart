// QA SYNC round 29: final regression sweep of multi-phone convergence on
// the integrated build. lib/sync is unchanged since round 24; what moved
// under the engine is the Ledger (DATA-R24-01): every stored op is read
// through TextRules.canonical when the Ledger opens and when it is offered
// to a peer (opsMissingFor), so an op stored by an earlier build with text
// today's peers refuse no longer fails every sync. These probes run that
// path through the real DefaultSyncEngine and Ledger the way it happens on
// a phone: the legacy ops are in the store before the app starts, then
// the phone syncs in a three-phone gossip, over 16 KiB BLE frames, with
// the link dropped mid-batch, at scale (2,000+ ops) and repeatedly.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';

import 'qa_phone.dart';

const _legacyDevice = 'dddddddd-0000-7000-8000-000000000029';

Operation _legacy({
  required GroupId groupId,
  required int counter,
  required String entityType,
  required String entityId,
  required Map<String, Object?> payload,
  required int millis,
  String kind = 'update',
  int schemaVersion = 1,
}) => Operation.fromJson({
  'id': 'dddddddd-0000-7000-9000-${counter.toRadixString(16).padLeft(12, '0')}',
  'groupId': groupId,
  'deviceId': _legacyDevice,
  'counter': counter,
  'hlc': Hlc(millis, 0, _legacyDevice).encode(),
  'entityType': entityType,
  'entityId': entityId,
  'kind': kind,
  'payload': payload,
  'schemaVersion': schemaVersion,
});

/// Ids of a reopened phone, past every id the first run made.
final class _LaterIds implements IdGenerator {
  _LaterIds(this.letter);
  final String letter;
  int _next = 0x100000;

  @override
  String newId() =>
      '${letter * 8}-0000-7000-9000-${(_next++).toRadixString(16).padLeft(12, '0')}';
}

void main() {
  late MemoryTransportHub hub;
  final phones = <QaPhone>[];

  Future<QaPhone> phone(
    String letter,
    String name, {
    bool sqlite = false,
  }) async {
    final p = await QaPhone.create(hub, letter, name, sqlite: sqlite);
    phones.add(p);
    return p;
  }

  /// [p] restarted over what it stored: its engine and Ledger are closed
  /// (the store is kept) and a new Ledger opens over the same store and
  /// keys, as the app does at its next start.
  Future<QaPhone> restart(QaPhone p) async {
    await p.engine.dispose();
    await p.ledger.close();
    phones.remove(p);
    final q = await QaPhone.create(
      hub,
      p.letter,
      p.deviceName,
      store: p.opStore,
      keys: p.keys,
      idGenerator: _LaterIds(p.letter),
    );
    phones.add(q);
    return q;
  }

  setUp(() => hub = MemoryTransportHub());
  tearDown(() async {
    for (final p in phones) {
      await p.dispose();
    }
    phones.clear();
  });

  int unshared(QaPhone p, GroupId g) => p.snapshot.unsharedCounts[g] ?? 0;

  /// Legacy ops of every class TextRules.canonical puts right, one each,
  /// on entities of seed [s] of [owner]: a control and a bidi character in
  /// a description, notes over their cap, a member name that shows
  /// nothing, a lone surrogate in the group name and one in a note of an
  /// unknown nested field.
  List<Operation> legacyOps(QaPhone owner, QaSeed s, {int from = 1}) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final e = (owner.state.groups[s.g]!.expenses.keys.toList()..sort());
    var c = from;
    return [
      _legacy(
        groupId: s.g,
        counter: c++,
        entityType: 'expense',
        entityId: e[0],
        payload: {'description': 'Taxi\u0007 \u202Eride'},
        millis: now + 1,
      ),
      _legacy(
        groupId: s.g,
        counter: c++,
        entityType: 'expense',
        entityId: e[1],
        payload: {
          'notes': 'n' * (TextRules.notes * TextRules.unitsPerChar + 9),
        },
        millis: now + 2,
      ),
      _legacy(
        groupId: s.g,
        counter: c++,
        entityType: 'member',
        entityId: s.b,
        payload: {'displayName': '\u200B \u3164'},
        millis: now + 3,
      ),
      _legacy(
        groupId: s.g,
        counter: c++,
        entityType: 'group',
        entityId: s.g,
        payload: {
          'name': 'Goa \uD83D trip',
          'futureNote': {'x': 'y\uDC00'},
        },
        millis: now + 4,
      ),
    ];
  }

  group('ops stored by an earlier build, read at start (DATA-R24-01)', () {
    test('three-phone gossip: B meets A, C meets only B, then C meets A; '
        'every phone shows the same snapshot, holds the same ops, and five '
        'repeat syncs per pair move nothing and add records', () async {
      var a = await phone('a', "Alex's Pixel");
      final b = await phone('b', "Priya's Pixel", sqlite: true);
      final c = await phone('c', "Sam's Galaxy");
      final s = await a.seedGroup(expenses: 3);
      await b.join(a, s.g);
      await c.join(a, s.g);

      // A held these before its update: they are in its store at start.
      await a.opStore.insertAll(legacyOps(a, s));
      a = await restart(a);
      final shown = a.canonical;
      final group = a.state.groups[s.g]!;
      expect(group.group!.name, 'Goa trip');
      expect(group.members[s.b]!.displayName, TextRules.unreadableName);

      final ab = await syncByLink(b, a);
      expect(ab.receivedOps, a.opCount(s.g));
      expect(b.canonical, shown);
      final bc = await syncByLink(c, b);
      expect(bc.receivedOps, b.opCount(s.g));
      expect(c.canonical, shown);
      // C and A never met: they already agree, and their meeting moves
      // nothing (the version vectors match although A stores the old form).
      final ca = await syncByLink(c, a);
      expect((ca.sentOps, ca.receivedOps), (0, 0));
      expect(allEqual([a, b, c]), isTrue);
      for (final p in [a, b, c]) {
        expect(p.opCount(s.g), a.opCount(s.g));
        expect(unshared(p, s.g), 0, reason: p.letter);
        expect((await p.ledger.versionVector(s.g))[_legacyDevice], 4);
      }

      // Every pair, five times: nothing moves, a record each time.
      for (final (x, y) in [(a, b), (b, c), (c, a)]) {
        final before = (await x.records()).length;
        for (var i = 0; i < 5; i++) {
          final again = await syncByLink(x, y);
          expect((again.sentOps, again.receivedOps), (0, 0));
          expect(again.groupIds, contains(s.g));
        }
        expect((await x.records()).length, before + 5);
        expect((await x.records()).first.outcome, SyncOutcome.completed);
      }
      expect(allEqual([a, b, c]), isTrue);
      expect(a.canonical, shown);

      // B and C restart too: what they stored shows the same.
      final b2 = await restart(b);
      final c2 = await restart(c);
      expect(b2.canonical, shown);
      expect(c2.canonical, shown);
    });

    test(
      'a later edit by an updated phone of an entity a legacy op touched '
      'wins by HLC on every phone (LWW unchanged by the canonical form)',
      () async {
        var a = await phone('a', "Alex's Pixel");
        final b = await phone('b', "Priya's Pixel", sqlite: true);
        final s = await a.seedGroup(expenses: 2);
        await b.join(a, s.g);
        await syncByLink(b, a);
        // B's edits come after the legacy ops (stamped "now" + a few ms).
        await a.opStore.insertAll(legacyOps(a, s));
        a = await restart(a);
        await syncByLink(b, a);
        final e0 = (b.state.groups[s.g]!.expenses.keys.toList()..sort())[0];
        expect(b.state.expense(e0)!.description, 'Taxi ride');
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await b.edit(e0, description: 'Cab ride');
        await b.ledger.renameMember(s.g, s.b, 'Priya');
        await syncByLink(a, b);
        expect(a.state.expense(e0)!.description, 'Cab ride');
        expect(a.state.groups[s.g]!.members[s.b]!.displayName, 'Priya');
        expect(a.canonical, b.canonical);
      },
    );

    for (final drop in [9, 13, 18]) {
      test('a 16 KiB BLE sync of 300 expenses and the legacy ops, dropped '
          'after $drop frames: partial or failed, nothing applied twice, the '
          'next session completes and all agree', () async {
        var a = await phone('a', "Alex's Pixel");
        final b = await phone('b', "Priya's Pixel");
        final s = await a.seedGroup(expenses: 2);
        await b.join(a, s.g);
        await syncByLink(b, a);
        await a.addExpenses(s, 300, base: 2000);
        await a.opStore.insertAll(legacyOps(a, s));
        a = await restart(a);
        final total = a.opCount(s.g);

        await b.engine.startHosting();
        final peer = await a.find(b, transports: 2);
        a.lan.failConnect = true; // the BLE route, 16 KiB frames
        a.ble.dropAfterFrames = drop;
        Object? outcome;
        try {
          outcome = await a.engine.syncWith(peer);
        } on SyncException catch (e) {
          outcome = e;
        }
        expect(outcome, isA<SyncException>(), reason: 'drop at $drop');
        final rec = (await a.records()).first;
        expect(rec.outcome, anyOf(SyncOutcome.partial, SyncOutcome.failed));
        await waitFor(() => b.engine.status.session is! SessionActive);
        final got = b.opCount(s.g);
        expect(got, lessThan(total));
        // What B holds is a prefix of what A sent, each op once.
        expect(b.opsOf(s.g).map((o) => o.id).toSet(), hasLength(got));

        a.ble.dropAfterFrames = null;
        final again = await a.engine.syncWith(await a.find(b));
        expect(again.transport, TransportKind.ble);
        expect(again.sentOps, total - got);
        expect(b.opCount(s.g), total);
        expect(b.canonical, a.canonical);
        expect(
          await b.ledger.versionVector(s.g),
          await a.ledger.versionVector(s.g),
        );
        expect(unshared(a, s.g), 0);
        await waitFor(() => unshared(b, s.g) == 0);
        expect(unshared(b, s.g), 0);
      });
    }

    test('2,000+ ops of which 400 legacy over 16 KiB BLE frames: one session '
        'carries all, both agree, and a repeat moves nothing', () async {
      var a = await phone('a', "Alex's Pixel", sqlite: true);
      final b = await phone('b', "Priya's Pixel", sqlite: true);
      final s = await a.seedGroup(
        expenses: 2,
        others: [for (var i = 1; i < 50; i++) 'Friend $i'],
      );
      await b.join(a, s.g);
      await a.addExpenses(s, 1700, base: 5000);
      final ids = (a.state.groups[s.g]!.expenses.keys.toList()..sort());
      final now = DateTime.now().millisecondsSinceEpoch;
      await a.opStore.insertAll([
        for (var i = 0; i < 400; i++)
          _legacy(
            groupId: s.g,
            counter: i + 1,
            entityType: 'expense',
            entityId: ids[i],
            payload: {
              'description': 'Old \u202E$i\uD83D',
              'notes': 'x' * (TextRules.notes * TextRules.unitsPerChar + 1),
            },
            millis: now + i,
          ),
      ]);
      a = await restart(a);
      final total = a.opCount(s.g);
      expect(total, greaterThan(2000));

      await b.engine.startHosting();
      final peer = await a.find(b, transports: 2);
      a.lan.failConnect = true;
      final sw = Stopwatch()..start();
      final sum = await a.engine.syncWith(peer);
      sw.stop();
      expect(sum.transport, TransportKind.ble);
      expect(sum.sentOps, total);
      expect(b.opCount(s.g), total);
      expect(b.canonical, a.canonical);
      expect(b.state.expense(ids[7])!.description, 'Old 7');
      expect(sw.elapsed, lessThan(const Duration(seconds: 60)));
      final again = await a.engine.syncWith(await a.find(b));
      expect((again.sentOps, again.receivedOps), (0, 0));
      expect(unshared(a, s.g), 0);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('a newer-schema op is relayed byte-for-byte when it needs nothing, '
        'and as its canonical form when it held a lone surrogate', () async {
      var a = await phone('a', "Alex's Pixel");
      final b = await phone('b', "Priya's Pixel");
      final c = await phone('c', "Sam's Galaxy");
      final s = await a.seedGroup(expenses: 1);
      await b.join(a, s.g);
      await c.join(a, s.g);
      final now = DateTime.now().millisecondsSinceEpoch;
      final clean = _legacy(
        groupId: s.g,
        counter: 1,
        entityType: 'receipt',
        entityId: 'r-1',
        kind: 'attach',
        schemaVersion: 2,
        payload: {
          'blob': {
            'z': 1,
            'a': [3, 2, 1],
          },
          'label': 'Bill',
        },
        millis: now,
      );
      final dirty = _legacy(
        groupId: s.g,
        counter: 2,
        entityType: 'receipt',
        entityId: 'r-2',
        kind: 'attach',
        schemaVersion: 2,
        payload: {'label': 'Bill \uDC00'},
        millis: now + 1,
      );
      await a.opStore.insertAll([clean, dirty]);
      a = await restart(a);
      final before = a.canonical;
      await syncByLink(b, a);
      await syncByLink(c, b);
      Operation find(QaPhone p, OpId id) =>
          (p.opsOf(s.g)).firstWhere((o) => o.id == id);
      for (final p in [b, c]) {
        expect(
          find(p, clean.id).toJson().toString(),
          clean.toJson().toString(),
        );
        expect(find(p, dirty.id).toJson()['payload'], {'label': 'Bill '});
        expect(find(p, dirty.id).schemaVersion, 2);
      }
      expect(allEqual([a, b, c]), isTrue);
      expect(a.canonical, before);
    });
  });
}
