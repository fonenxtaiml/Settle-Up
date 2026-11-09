// QA SYNC-R1: invite -> join -> first sync -> claim, through the real
// DefaultSyncEngine and Ledger over MemoryTransport.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';

import 'qa_phone.dart';

void main() {
  late MemoryTransportHub hub;
  late QaPhone alex, ravi;
  late QaSeed seed;
  final extra = <QaPhone>[];

  setUp(() async {
    hub = MemoryTransportHub();
    alex = await QaPhone.create(hub, 'a', "Alex's Pixel");
    ravi = await QaPhone.create(hub, 'c', "Ravi's Galaxy", displayName: 'Ravi');
    seed = await alex.seedGroup(expenses: 5, others: const ['Priya', 'Ravi']);
  });

  tearDown(() async {
    for (final p in [alex, ravi, ...extra]) {
      await p.dispose();
    }
    extra.clear();
  });

  test('invite -> accept -> whole group arrives -> claim syncs back', () async {
    final link = await alex.engine.inviteLinkFor(seed.g);
    final invite = InviteLink.tryParse(link)!;
    expect(invite.host, 'a-lan', reason: 'host hint h= is embedded');

    final join = await ravi.engine.acceptInvite(link);
    expect(join.alreadyMember, isFalse);
    expect(join.groupName, 'Goa trip');
    expect(join.firstSync, isNotNull);
    expect(join.firstSync!.receivedOps, alex.opCount(seed.g));
    expect(ravi.canonical, alex.canonical);
    expect(ravi.snapshot.pendingJoins, isEmpty);
    expect(ravi.state.groups[seed.g]!.group!.name, 'Goa trip');

    // "Which one are you?" -> Ravi.
    final raviMember = ravi.state.groups[seed.g]!.members.values.firstWhere(
      (m) => m.displayName == 'Ravi',
    );
    await ravi.ledger.claimMember(seed.g, raviMember.id);
    expect(ravi.snapshot.unsharedCounts[seed.g], 1);

    final back = await syncByLink(ravi, alex);
    expect(back.sentOps, 1);
    expect(alex.canonical, ravi.canonical);
    expect(
      alex.state.groups[seed.g]!.members[raviMember.id]!.deviceId,
      ravi.deviceId,
    );
    expect(ravi.snapshot.unsharedCounts, isEmpty);
  });

  test('accepting the same invite twice is idempotent', () async {
    final link = await alex.engine.inviteLinkFor(seed.g);
    final first = await ravi.engine.acceptInvite(link);
    final opsAfterFirst = ravi.totalOps;
    final second = await ravi.engine.acceptInvite(link);

    expect(first.alreadyMember, isFalse);
    expect(second.alreadyMember, isTrue);
    expect(second.groupId, seed.g);
    // The second accept still syncs (nothing new), and adds nothing.
    expect(second.firstSync?.receivedOps ?? 0, 0);
    expect(ravi.totalOps, opsAfterFirst);
    expect(ravi.canonical, alex.canonical);
  });

  test('the inviter scanning its own invite is already a member', () async {
    final link = await alex.engine.inviteLinkFor(seed.g, includeHost: false);
    final before = alex.canonical;
    final result = await alex.engine.acceptInvite(link);
    expect(result.alreadyMember, isTrue);
    expect(alex.canonical, before);
    expect(alex.snapshot.pendingJoins, isEmpty);
  });

  test(
    'joining a group already held through gossip: alreadyMember, no dupes',
    () async {
      // Priya got the group from Alex earlier and relays it to Ravi... but Ravi
      // already has it from a previous invite.
      final link = await alex.engine.inviteLinkFor(seed.g);
      await ravi.engine.acceptInvite(link);
      await alex.addExpenses(seed, 3);
      final again = await ravi.engine.acceptInvite(link);
      expect(again.alreadyMember, isTrue);
      expect(
        again.firstSync,
        isNotNull,
        reason: 'the h= host is still reachable',
      );
      expect(again.firstSync!.receivedOps, 3);
      expect(ravi.canonical, alex.canonical);
    },
  );

  test(
    'invite without host joins as pending; a later sync completes it',
    () async {
      final link = await alex.engine.inviteLinkFor(seed.g, includeHost: false);
      final join = await ravi.engine.acceptInvite(link);
      expect(join.firstSync, isNull);
      expect(ravi.snapshot.pendingJoins[seed.g], 'Goa trip');

      await syncByLink(ravi, alex);
      expect(ravi.snapshot.pendingJoins, isEmpty);
      expect(ravi.canonical, alex.canonical);
    },
  );

  test(
    'invite whose h= host is unreachable still joins; first sync is null',
    () async {
      final link = InviteLink.tryParse(
        await alex.engine.inviteLinkFor(seed.g, includeHost: false),
      )!;
      final withDeadHost = InviteLink(
        groupId: link.groupId,
        groupKey: link.groupKey,
        groupName: link.groupName,
        currency: link.currency,
        fromName: link.fromName,
        host: '10.255.255.1:47321',
        deviceId: link.deviceId,
      ).encode();
      final join = await ravi.engine.acceptInvite(withDeadHost);
      expect(join.firstSync, isNull);
      expect(join.alreadyMember, isFalse);
      // A failed first sync is in the history, and the engine is free again.
      expect((await ravi.records()).single.outcome, SyncOutcome.failed);
      expect(ravi.engine.status.session, isA<SessionFailed>());
      await syncByLink(ravi, alex);
      expect(ravi.canonical, alex.canonical);
    },
  );

  test('syncWithLink on an invite link joins and syncs in one go', () async {
    final link = await alex.engine.inviteLinkFor(seed.g);
    final summary = await ravi.engine.syncWithLink(link);
    expect(summary.receivedOps, alex.opCount(seed.g));
    expect(ravi.canonical, alex.canonical);
  });

  test(
    'a third phone joins from the second phone (relay of the invite)',
    () async {
      final priya = await QaPhone.create(
        hub,
        'b',
        "Priya's Pixel",
        displayName: 'Priya',
      );
      extra.add(priya);
      await priya.engine.acceptInvite(await alex.engine.inviteLinkFor(seed.g));
      await alex.engine.stopHosting();
      // Ravi is invited by Priya, never meets Alex.
      final fromPriya = await priya.engine.inviteLinkFor(seed.g);
      expect(InviteLink.tryParse(fromPriya)!.groupName, 'Goa trip');
      expect(InviteLink.tryParse(fromPriya)!.currency, 'INR');
      final join = await ravi.engine.acceptInvite(fromPriya);
      expect(join.firstSync, isNotNull);
      expect(ravi.canonical, alex.canonical);
    },
  );

  test(
    'inviteLinkFor a group without a key is an error, not a crash',
    () async {
      await expectLater(
        alex.engine.inviteLinkFor('00000000-0000-7000-9000-00000000dead'),
        throwsA(isA<SyncException>()),
      );
    },
  );
}
