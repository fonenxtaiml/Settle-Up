// QA SYNC round 42, final regression sweep: LIVE sessions through the real
// engine after the SYNC-R39-01 / SYNC-R41-01 count changes (live pushes
// are tracked against the peer's version vector too), links lost while
// LIVE, the peer leaving LIVE with pushes on the wire, and a 3-phone ring
// with skewed clocks repeated to a fixed point.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';

import 'qa_phone.dart';

void main() {
  late MemoryTransportHub hub;
  final phones = <QaPhone>[];

  Future<QaPhone> phone(
    String letter,
    String name, {
    SkewedClock? clock,
    List<CuttableTransport>? cuttable,
  }) async {
    final p = await QaPhone.create(
      hub,
      letter,
      name,
      clock: clock,
      wrap: cuttable == null
          ? null
          : (t) {
              final c = CuttableTransport(t);
              cuttable.add(c);
              return c;
            },
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

  int unshared(QaPhone p, GroupId g) => p.snapshot.unsharedCounts[g] ?? 0;

  Future<void> recorded(QaPhone p, int before) async {
    expect(
      await waitFor(
        () async => (await p.records()).length > before,
        timeout: const Duration(seconds: 8),
      ),
      isTrue,
      reason: '${p.deviceName} wrote no sync record',
    );
  }

  Future<(SyncRecord, SyncRecord)> sync(QaPhone from, QaPhone to) async {
    final fromBefore = (await from.records()).length;
    final toBefore = (await to.records()).length;
    await syncByLink(from, to);
    await recorded(to, toBefore);
    await recorded(from, fromBefore);
    return ((await from.records()).first, (await to.records()).first);
  }

  /// Starts a LIVE session from [a] to hosting [b]; returns when LIVE.
  Future<SyncSummary> goLive(QaPhone a, QaPhone b) async {
    a.engine.liveMode = true;
    b.engine.liveMode = true;
    final host = await b.engine.startHosting();
    return a.engine
        .syncWithLink(host.connectLink)
        .timeout(const Duration(seconds: 5));
  }

  group('LIVE sessions', () {
    test('ops typed on both phones while LIVE: pushed both ways, counted '
        'once in each record, badges clear', () async {
      final a = await phone('a', "Alex's Pixel");
      final b = await phone('b', "Priya's Pixel");
      final s = await a.seedGroup(expenses: 2);
      await b.join(a, s.g);
      final aBefore = (await a.records()).length;
      final bBefore = (await b.records()).length;
      final live = await goLive(a, b);
      expect(live.sentOps, a.opCount(s.g));
      expect(b.canonical, a.canonical);
      final first = a.opCount(s.g);

      await a.addExpenses(s, 3);
      await b.addExpense(
        s.g,
        payer: s.b,
        owers: [s.a, s.b],
        total: 4321,
        description: 'Typed on B',
      );
      await b.addExpense(
        s.g,
        payer: s.b,
        owers: [s.a, s.b],
        total: 4322,
        description: 'Typed on B again',
      );
      expect(
        await waitFor(
          () => a.opCount(s.g) == first + 5 && b.opCount(s.g) == first + 5,
        ),
        isTrue,
        reason: 'live pushes did not arrive',
      );
      expect(b.canonical, a.canonical);
      expect(
        await waitFor(() => unshared(a, s.g) == 0 && unshared(b, s.g) == 0),
        isTrue,
        reason:
            'badges after live pushes: '
            'A ${unshared(a, s.g)}, B ${unshared(b, s.g)}',
      );

      a.engine.liveMode = false;
      b.engine.liveMode = false;
      await recorded(a, aBefore);
      await recorded(b, bBefore);
      final ra = (await a.records()).first;
      final rb = (await b.records()).first;
      expect(ra.outcome, SyncOutcome.completed);
      expect(rb.outcome, SyncOutcome.completed);
      expect(ra.sentOps, first + 3, reason: 'A sent initial + 3 live');
      expect(ra.receivedOps, 2, reason: 'A got B\'s 2 live ops');
      expect(rb.sentOps, 2);
      expect(rb.receivedOps, first + 3);

      // Next sync is idempotent.
      final (ra2, rb2) = await sync(a, b);
      expect(ra2.sentOps + ra2.receivedOps + rb2.sentOps + rb2.receivedOps, 0);
      expect(a.opCount(s.g), first + 5);
      expect(b.canonical, a.canonical);
    });

    for (final halfOpen in [false, true]) {
      test('link ${halfOpen ? 'cut (half-open)' : 'closed'} while LIVE with '
          'pushes on the wire: sent is what B came to hold, the next sync '
          'completes with nothing counted twice', () async {
        final ts = <CuttableTransport>[];
        final a = await phone('a', "Alex's Pixel", cuttable: ts);
        final b = await phone('b', "Priya's Pixel");
        final s = await a.seedGroup(expenses: 1);
        await b.join(a, s.g);
        final aBefore = (await a.records()).length;
        final bBefore = (await b.records()).length;
        await goLive(a, b);
        final first = a.opCount(s.g);
        final covered0 = (await b.ledger.versionVector(s.g))[a.deviceId];
        final badge0 = unshared(a, s.g);
        expect(badge0, 0);

        // 40 ops typed while LIVE; drop the link once some have landed.
        for (var i = 0; i < 40; i++) {
          await a.addExpense(
            s.g,
            payer: s.a,
            owers: [s.a, s.b],
            total: 100 + i,
            description: 'L$i',
          );
          if (i == 20) {
            await waitFor(() => b.opCount(s.g) > first);
            for (final t in ts) {
              if (halfOpen) {
                t.cut();
              } else {
                for (final c in t.channels) {
                  await c.inner.close();
                }
              }
            }
          }
        }
        await recorded(a, aBefore);
        await recorded(b, bBefore);
        final ra = (await a.records()).first;
        final rb = (await b.records()).first;
        final covered1 = (await b.ledger.versionVector(s.g))[a.deviceId];
        final badge1 = unshared(a, s.g);
        final gotLive = covered1 - covered0;
        expect(ra.outcome, isNot(SyncOutcome.cancelled));
        expect(rb.receivedOps, first + gotLive);
        expect(b.opCount(s.g), first + gotLive);
        // A counts what B ACKed covering it; a lost link may eat the
        // last ACKs, so it can be fewer than B holds, never more, and it
        // moves with A's badge.
        expect(ra.sentOps, lessThanOrEqualTo(first + gotLive));
        expect(ra.sentOps - first, 40 - badge1, reason: 'sent vs badge');

        a.engine.liveMode = false;
        b.engine.liveMode = false;
        ts.clear();
        await waitFor(() => b.engine.status.session is! SessionActive);
        final (ra2, rb2) = await sync(a, b);
        expect(ra2.outcome, SyncOutcome.completed);
        expect(ra2.sentOps, 40 - gotLive, reason: 'resume sends the rest');
        expect(rb2.receivedOps, 40 - gotLive);
        expect(unshared(a, s.g), 0);
        expect(b.opCount(s.g), first + 40);
        expect(b.canonical, a.canonical);
      });
    }

    test('B leaves LIVE right as A pushes 300 ops over BLE: both complete, '
        'A counts what B holds, the rest goes next sync', () async {
      final a = await phone('a', "Alex's Pixel");
      final b = await phone('b', "Priya's Pixel");
      final s = await a.seedGroup(expenses: 1);
      await b.join(a, s.g);
      a.lan.failConnect = true;
      a.engine.liveMode = true;
      b.engine.liveMode = true;
      await b.engine.startHosting();
      final peer = await a.find(b, transports: 2);
      final aBefore = (await a.records()).length;
      final bBefore = (await b.records()).length;
      await a.engine.syncWith(peer).timeout(const Duration(seconds: 5));
      final first = a.opCount(s.g);
      // 300 ops in one ledger batch would be one local-op burst; type them
      // one by one so the live buffer fills, then B leaves LIVE.
      for (var i = 0; i < 300; i++) {
        await a.addExpense(
          s.g,
          payer: s.a,
          owers: [s.a, s.b],
          total: 100 + i,
          description: 'Burst $i with a longer description to fill frames',
        );
      }
      await waitFor(() => b.opCount(s.g) > first);
      b.engine.liveMode = false;
      await recorded(a, aBefore);
      await recorded(b, bBefore);
      final ra = (await a.records()).first;
      final rb = (await b.records()).first;
      final heldLive = b.opCount(s.g) - first;
      expect(rb.outcome, SyncOutcome.completed);
      expect(ra.outcome, SyncOutcome.completed);
      expect(ra.sentOps, first + heldLive);
      expect(rb.receivedOps, first + heldLive);
      expect(unshared(a, s.g), 300 - heldLive);

      a.engine.liveMode = false;
      a.lan.failConnect = false;
      await waitFor(() => b.engine.status.session is! SessionActive);
      final (ra2, rb2) = await sync(a, b);
      expect(ra2.sentOps, 300 - heldLive);
      expect(rb2.receivedOps, 300 - heldLive);
      expect(unshared(a, s.g), 0);
      expect(b.canonical, a.canonical);
    });
  });

  group('LIVE scope', () {
    test(
      'no echo, no other group, cancel while LIVE keeps what was shared',
      () async {
        final a = await QaPhone.create(
          hub,
          'a',
          "Alex's Pixel",
          spyStore: true,
        );
        final b = await QaPhone.create(
          hub,
          'b',
          "Priya's Pixel",
          spyStore: true,
        );
        phones.addAll([a, b]);
        final s = await a.seedGroup(expenses: 1);
        final solo = await a.seedGroup(expenses: 0, name: 'Only on A');
        await b.join(a, s.g);
        final aBefore = (await a.records()).length;
        final bBefore = (await b.records()).length;
        await goLive(a, b);
        final first = a.opCount(s.g);
        await a.addExpenses(s, 2);
        await b.addExpense(s.g, payer: s.b, owers: [s.a, s.b], total: 999);
        await a.addExpenses(solo, 2);
        expect(
          await waitFor(
            () => a.opCount(s.g) == first + 3 && b.opCount(s.g) == first + 3,
          ),
          isTrue,
        );
        // Give any echo time to come back.
        await Future<void>.delayed(const Duration(milliseconds: 1500));
        expect(a.spy.duplicatesIgnored, 0, reason: 'B echoed A its own ops');
        expect(b.spy.duplicatesIgnored, 0, reason: 'A echoed B its own ops');
        expect(b.opCount(solo.g), 0, reason: 'an unshared group was pushed');
        expect(b.state.groups.containsKey(solo.g), isFalse);

        await a.engine.cancel();
        await recorded(a, aBefore);
        await recorded(b, bBefore);
        final ra = (await a.records()).first;
        final rb = (await b.records()).first;
        expect(ra.sentOps, first + 2);
        expect(ra.receivedOps, 1);
        expect(rb.sentOps, 1);
        expect(rb.receivedOps, first + 2);
        expect(rb.outcome, isNot(SyncOutcome.failed));
        expect(unshared(a, s.g), 0);
        expect(unshared(b, s.g), 0);
        expect(
          b.canonical['groups'].toString(),
          isNot(contains(solo.g.toString())),
        );
        // The engine takes the next session.
        a.engine.liveMode = false;
        b.engine.liveMode = false;
        await waitFor(() => b.engine.status.session is! SessionActive);
        final (ra2, _) = await sync(a, b);
        expect(ra2.outcome, SyncOutcome.completed);
        expect(ra2.sentOps, 0);
      },
    );
  });

  group('invite names at the limit (SECURITY-R39-01 cut on links)', () {
    final names = {
      'emoji ZWJ': '👩‍💻 Dev trip ' * 10,
      'Devanagari conjuncts': 'प्रिया की गोवा ट्रिप ' * 6,
      'astral letters': '𝒢𝑜𝒶 ' * 30,
      'flags': '🇮🇳🇬🇧 Goa ' * 10,
      'combining marks': 'Ǵóá̃ trip ' * 10,
    };
    for (final e in names.entries) {
      test('${e.key}: stored name, link, pending join and synced group '
          'are the same', () async {
        final alex = await phone('a', "Alex's Pixel");
        final ravi = await phone('c', "Ravi's Galaxy");
        final g = await alex.ledger.createGroup(
          NewGroup(
            name: NameText.fit(e.value, NameText.maxGroupLength),
            type: GroupType.trip,
            currency: 'INR',
            newMemberNames: const ['Ravi'],
          ),
        );
        final stored = alex.state.groups[g]!.group!.name;
        final link = await alex.engine.inviteLinkFor(g);
        expect(InviteLink.tryParse(link)!.groupName, stored);
        // Host hint h= reaches Alex: the first sync delivers the group.
        await alex.engine.startHosting();
        final join = await ravi.engine.acceptInvite(link);
        expect(join.groupName, stored);
        expect(join.firstSync, isNotNull);
        expect(ravi.state.groups[g]!.group!.name, stored);
        expect(ravi.snapshot.pendingJoins, isEmpty);
        expect(ravi.canonical, alex.canonical);
      });
    }
  });

  group('ring with skewed clocks', () {
    test(
      'A (+2 h), B (0), C (-1 day) edit the same expense and members '
      'offline, then gossip A-B, B-C, C-A five times: one fixed point, '
      'op counts stop moving, every sync after the first ring is empty',
      () async {
        final a = await phone(
          'a',
          "Alex's Pixel",
          clock: SkewedClock(const Duration(hours: 2)),
        );
        final b = await phone('b', "Priya's Pixel");
        final c = await phone(
          'c',
          "Sam's Galaxy",
          clock: SkewedClock(const Duration(days: -1)),
        );
        final s = await a.seedGroup(expenses: 2);
        await b.join(a, s.g);
        await c.join(a, s.g);
        await sync(b, a);
        await sync(c, a);
        final ids = a.state.groups[s.g]!.expenses.keys.toList()..sort();
        final e = ids[0];
        await a.edit(e, description: 'From A', total: 1111);
        await b.edit(e, description: 'From B');
        await c.edit(e, total: 3333);
        await a.ledger.addMember(s.g, displayName: 'Bob');
        await c.ledger.addMember(s.g, displayName: 'Bob');
        final x = ids[1];
        await b.ledger.deleteExpense(x);
        await c.edit(x, description: 'C edits what B deleted');

        final counts = <int>[];
        for (var round = 0; round < 5; round++) {
          final r1 = await sync(a, b);
          final r2 = await sync(b, c);
          final r3 = await sync(c, a);
          if (round >= 2) {
            for (final (x, y) in [r1, r2, r3]) {
              expect(
                x.sentOps + x.receivedOps + y.sentOps + y.receivedOps,
                0,
                reason: 'round $round moved ops',
              );
            }
          }
          counts.add(a.opCount(s.g));
        }
        expect(allEqual([a, b, c]), isTrue);
        expect(counts.toSet(), hasLength(1), reason: 'op count moved: $counts');
        expect(a.opCount(s.g), b.opCount(s.g));
        expect(c.opCount(s.g), b.opCount(s.g));
        for (final p in [a, b, c]) {
          expect(unshared(p, s.g), 0, reason: p.deviceName);
        }
      },
    );
  });
}
