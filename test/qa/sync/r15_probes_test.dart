// QA SYNC round 15: final regression sweep of multi-phone convergence on
// the integrated build. Rounds 7-14 changed how names are stored and shown
// (NameText: NFKC, blank fillers as spaces, invisible characters left out,
// cut to the field limit) in the reducer (buildGroup, buildMember), the
// Ledger and the sync layer (peer names, invite hints). These probes run
// that code through the real DefaultSyncEngine and Ledger: names that are
// equal only once normalised, raw names from a phone that never
// normalised them, names that grow under NFKC, gossip with skewed clocks
// and an invite from a phone whose name shows nothing.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/peer_label.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';

import 'qa_phone.dart';

/// A phone that wrote its names without normalising them (a forged peer,
/// or any phone that sends raw text): its ops pass the remote checks.
const _rawDevice = 'eeeeeeee-0000-7000-8000-000000000015';

Operation _rawOp({
  required String groupId,
  required int counter,
  required String entityType,
  required String entityId,
  required Map<String, Object?> payload,
  String kind = 'update',
  int? millis,
}) => Operation.fromJson({
  'id': 'eeeeeeee-0000-7000-9000-${counter.toRadixString(16).padLeft(12, '0')}',
  'groupId': groupId,
  'deviceId': _rawDevice,
  'counter': counter,
  'hlc': Hlc(
    millis ?? DateTime.now().millisecondsSinceEpoch,
    0,
    _rawDevice,
  ).encode(),
  'entityType': entityType,
  'entityId': entityId,
  'kind': kind,
  'payload': payload,
  'schemaVersion': 1,
});

void main() {
  late MemoryTransportHub hub;
  final phones = <QaPhone>[];

  Future<QaPhone> phone(
    String letter,
    String name, {
    String displayName = 'Alex',
    SkewedClock? clock,
    bool sqlite = false,
  }) async {
    final p = await QaPhone.create(
      hub,
      letter,
      name,
      displayName: displayName,
      clock: clock,
      sqlite: sqlite,
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

  Future<(QaPhone, QaPhone, QaSeed)> pair({bool sqlite = false}) async {
    final alex = await phone('a', "Alex's Pixel", sqlite: sqlite);
    final priya = await phone(
      'b',
      "Priya's Pixel",
      displayName: 'Priya',
      sqlite: !sqlite,
    );
    final seed = await alex.seedGroup(expenses: 2);
    await priya.join(alex, seed.g);
    await syncByLink(priya, alex);
    expect(priya.canonical, alex.canonical);
    return (alex, priya, seed);
  }

  group('names equal only once normalised', () {
    test('concurrent renames of one member to "Priya S" and its fullwidth '
        'form converge; both phones show "Priya S"', () async {
      final (alex, priya, seed) = await pair();
      await alex.ledger.renameMember(seed.g, seed.b, 'Priya S');
      await priya.ledger.renameMember(
        seed.g,
        seed.b,
        '\uFF30\uFF52\uFF49\uFF59\uFF41\u3164S',
      );
      // Both stored the same normalised text.
      expect(
        alex.state.groups[seed.g]!.members[seed.b]!.displayName,
        'Priya S',
      );
      expect(
        priya.state.groups[seed.g]!.members[seed.b]!.displayName,
        'Priya S',
      );
      await syncByLink(alex, priya);
      expect(alex.canonical, priya.canonical);
      expect(
        alex.state.groups[seed.g]!.members[seed.b]!.displayName,
        'Priya S',
      );
      final again = await syncByLink(priya, alex);
      expect((again.sentOps, again.receivedOps), (0, 0));
    });

    test('both phones add "Bob" offline, one typed in fullwidth: two '
        'members, the same on both phones', () async {
      final (alex, priya, seed) = await pair(sqlite: true);
      final a = await alex.ledger.addMember(seed.g, displayName: 'Bob');
      final b = await priya.ledger.addMember(
        seed.g,
        displayName: ' \uFF22\uFF4F\uFF42\u200B ',
      );
      expect(a, isNot(b));
      await syncByLink(priya, alex);
      expect(alex.canonical, priya.canonical);
      final bobs = alex.state.groups[seed.g]!.members.values
          .where((m) => m.displayName == 'Bob')
          .toList();
      expect(bobs, hasLength(2));
    });
  });

  group('raw names from a phone that does not normalise them', () {
    test(
      'a raw member rename and group rename relay A -> B -> C byte for '
      'byte, and every phone shows them in the same normalised form',
      () async {
        final a = await phone('a', 'A');
        final b = await phone('b', 'B', sqlite: true);
        final c = await phone('c', 'C');
        final s = await a.seedGroup(expenses: 1);
        await b.join(a, s.g);
        await c.join(a, s.g);
        // 70 fullwidth characters: within the remote limit (60 x 4 units)
        // but longer than a group name may be once shown.
        final longRaw = '\uFF27' * 70;
        final raw = [
          _rawOp(
            groupId: s.g,
            counter: 1,
            entityType: 'member',
            entityId: s.b,
            payload: {'displayName': '\uFF30riya\u3164\u00ADS\u200D'},
          ),
          _rawOp(
            groupId: s.g,
            counter: 2,
            entityType: 'group',
            entityId: s.g,
            payload: {'name': longRaw},
          ),
        ];
        final wire = [for (final o in raw) jsonEncode(o.toJson())];
        final added = await a.ledger.applyRemote(s.g, raw);
        expect(added, hasLength(2));

        await syncByLink(b, a);
        await syncByLink(c, b); // C never meets A.
        for (final p in [a, b, c]) {
          final stored = [
            for (final o in p.opsOf(s.g))
              if (o.deviceId == _rawDevice) jsonEncode(o.toJson()),
          ];
          expect(stored, wire, reason: '${p.deviceName} relays what it got');
          expect(
            p.state.groups[s.g]!.members[s.b]!.displayName,
            'Priya S',
            reason: p.deviceName,
          );
          final name = p.state.groups[s.g]!.group!.name;
          expect(name, 'G' * NameText.maxGroupLength, reason: p.deviceName);
        }
        expect(allEqual([a, b, c]), isTrue);
      },
    );

    test('renaming a raw-named member to its shown name writes nothing '
        'and stays converged', () async {
      final (alex, priya, seed) = await pair();
      await alex.ledger.applyRemote(seed.g, [
        _rawOp(
          groupId: seed.g,
          counter: 1,
          entityType: 'member',
          entityId: seed.b,
          payload: {'displayName': 'Priya\u3164S'},
        ),
      ]);
      await syncByLink(priya, alex);
      final before = alex.totalOps;
      await alex.ledger.renameMember(seed.g, seed.b, 'Priya S');
      expect(alex.totalOps, before);
      await alex.ledger.updateGroup(seed.g, const GroupPatch(name: 'Goa trip'));
      expect(alex.totalOps, before);
      final again = await syncByLink(priya, alex);
      expect((again.sentOps, again.receivedOps), (0, 0));
      expect(alex.canonical, priya.canonical);
    });
  });

  group('invites with names that change when normalised', () {
    test('a group name that grows under NFKC: the invite, the pending '
        'join and the synced group all show the same cut name', () async {
      final alex = await phone('a', "Alex's Pixel");
      final ravi = await phone('c', "Ravi's Galaxy", displayName: 'Ravi');
      // U+337F is one character typed and four once NFKC'd: 20 of them
      // are 80 characters, cut to 60.
      final g = await alex.ledger.createGroup(
        NewGroup(
          name: '\u337F' * 20,
          type: GroupType.trip,
          currency: 'INR',
          newMemberNames: const ['Ravi'],
        ),
      );
      final stored = alex.state.groups[g]!.group!.name;
      expect(stored.length, lessThanOrEqualTo(NameText.maxGroupLength));

      final link = await alex.engine.inviteLinkFor(g, includeHost: false);
      expect(InviteLink.tryParse(link)!.groupName, stored);
      final join = await ravi.engine.acceptInvite(link);
      expect(join.groupName, stored);
      expect(ravi.snapshot.pendingJoins[g], stored);

      await syncByLink(ravi, alex);
      expect(ravi.snapshot.pendingJoins, isEmpty);
      expect(ravi.state.groups[g]!.group!.name, stored);
      expect(ravi.canonical, alex.canonical);
    });

    test('an invite from a phone whose name shows nothing: the prompt and '
        'both Sync histories never show a blank name', () async {
      final alex = await phone('a', '\u3164\u3164');
      final ravi = await phone('c', "Ravi's Galaxy", displayName: 'Ravi');
      // This phone cannot keep a name that shows nothing.
      expect(alex.deviceName, kUnnamedPeer);
      final seed = await alex.seedGroup(others: const ['Ravi']);
      // A link edited (or made by another app) to carry one.
      final made = Uri.parse(await alex.engine.inviteLinkFor(seed.g));
      final link = made
          .replace(
            queryParameters: {
              ...made.queryParameters,
              'f': '\u3164\u200B\u115F',
            },
          )
          .toString();
      final invite = InviteLink.tryParse(link)!;
      expect(invite.fromName, isEmpty, reason: 'the prompt says "Someone"');
      final join = await ravi.engine.acceptInvite(link);
      expect(join.firstSync, isNotNull);
      expect(ravi.canonical, alex.canonical);
      await waitFor(() async => (await alex.records()).isNotEmpty);
      for (final p in [alex, ravi]) {
        final rec = (await p.records()).first;
        expect(rec.peerName.trim(), isNotEmpty, reason: p.deviceName);
        expect(showsPeerName(rec.peerName), isTrue, reason: p.deviceName);
      }
    });
  });

  group('gossip with skewed clocks and normalised names', () {
    test(
      'three phones (+2 h, 0, -1 day) rename the same member and the '
      'group concurrently, sync in a ring and reach one fixed point',
      () async {
        final a = await phone(
          'a',
          'A',
          clock: SkewedClock(const Duration(hours: 2)),
        );
        final b = await phone('b', 'B', sqlite: true);
        final c = await phone(
          'c',
          'C',
          clock: SkewedClock(const Duration(days: -1)),
        );
        final s = await a.seedGroup(expenses: 3);
        await b.join(a, s.g);
        await c.join(a, s.g);
        await syncByLink(b, a);
        await syncByLink(c, b);
        expect(allEqual([a, b, c]), isTrue);

        await a.ledger.renameMember(s.g, s.b, 'Priya A');
        await b.ledger.renameMember(s.g, s.b, '\uFF30riya B');
        await c.ledger.renameMember(s.g, s.b, 'Priya\u3164C');
        await a.ledger.updateGroup(s.g, const GroupPatch(name: 'Trip A'));
        await c.ledger.updateGroup(s.g, const GroupPatch(name: 'Trip\u00A0C'));
        await b.addExpenses(s, 5);

        // Ring until nothing moves, at most 4 rounds.
        var rounds = 0;
        while (true) {
          rounds++;
          final x = await syncByLink(a, b);
          final y = await syncByLink(b, c);
          final z = await syncByLink(c, a);
          final moved =
              x.sentOps +
              x.receivedOps +
              y.sentOps +
              y.receivedOps +
              z.sentOps +
              z.receivedOps;
          if (moved == 0) break;
          expect(rounds, lessThan(4), reason: 'ring never settles');
        }
        expect(allEqual([a, b, c]), isTrue);
        // A's clock is 2 h ahead: its writes carry the highest HLC.
        final m = b.state.groups[s.g]!.members[s.b]!;
        expect(m.displayName, 'Priya A');
        expect(b.state.groups[s.g]!.group!.name, 'Trip A');
        expect(
          b.ledger.clockSkewDetected || c.ledger.clockSkewDetected,
          isTrue,
        );

        // Five more syncs change nothing but the history.
        final ops = a.totalOps;
        final snap = a.canonical.toString();
        final recs = (await a.records()).length;
        for (var i = 0; i < 5; i++) {
          final r = await syncByLink(a, c);
          expect((r.sentOps, r.receivedOps), (0, 0));
        }
        expect(a.totalOps, ops);
        expect(a.canonical.toString(), snap);
        expect((await a.records()).length, recs + 5);
      },
    );
  });

  group('largest names at BLE frame size', () {
    test('50 members named 40 flags (160 code units each, the limit) and '
        '300 expenses arrive over 16 KiB frames and converge', () async {
      final alex = await QaPhone.create(
        hub,
        'a',
        "Alex's Pixel",
        kinds: const [TransportKind.ble],
      );
      final priya = await QaPhone.create(
        hub,
        'b',
        "Priya's Pixel",
        displayName: 'Priya',
        kinds: const [TransportKind.ble],
        sqlite: true,
      );
      phones.addAll([alex, priya]);
      const flag = '\u{1F1EE}\u{1F1F3}';
      final others = [
        for (var i = 0; i < 49; i++)
          // 40 characters, each a flag; a distinct last one per member.
          '${flag * 39}${String.fromCharCode(0x41 + i % 26)}',
      ];
      final seed = await alex.seedGroup(expenses: 0, others: others);
      final g = alex.state.groups[seed.g]!;
      expect(g.members, hasLength(50));
      for (final m in g.members.values) {
        expect(
          NameText.fits(m.displayName, NameText.maxLength),
          isTrue,
          reason: m.displayName,
        );
      }
      await alex.addExpenses(seed, 300);
      await priya.join(alex, seed.g);
      await priya.engine.startHosting();
      final r = await alex.engine.syncWith(await alex.find(priya));
      expect(r.transport, TransportKind.ble);
      await waitFor(() => priya.opCount(seed.g) == alex.opCount(seed.g));
      expect(priya.canonical, alex.canonical);
      expect(priya.state.groups[seed.g]!.members, hasLength(50));
    });
  });
}
