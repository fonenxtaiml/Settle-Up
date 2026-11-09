// QA SYNC-R1: hostile or broken peers through the real engine. Wrong key,
// no shared group, tampered frames, replayed HELLO/AUTH: the right failure,
// no ops applied, no crash, and the engine accepts the next session.
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/protocol/codec.dart';
import 'package:settle_up/sync/protocol/messages.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/sync/transport/transport.dart';

import '../../sync/support/phone.dart' show groupKeyOf;
import 'qa_phone.dart';
import 'qa_taps.dart';

void main() {
  late MemoryTransportHub hub;
  final phones = <QaPhone>[];
  late QaPhone alex, priya;
  late QaSeed seed;
  late TapTransport tap;

  setUp(() async {
    hub = MemoryTransportHub();
    alex = await QaPhone.create(
      hub,
      'a',
      "Alex's Pixel",
      kinds: const [TransportKind.lan],
      spyStore: true,
      wrap: (t) => tap = TapTransport(t),
    );
    priya = await QaPhone.create(
      hub,
      'b',
      "Priya's Pixel",
      kinds: const [TransportKind.lan],
      spyStore: true,
    );
    phones
      ..add(alex)
      ..add(priya);
    seed = await alex.seedGroup(expenses: 4);
  });

  tearDown(() async {
    for (final p in phones) {
      await p.dispose();
    }
    phones.clear();
  });

  Future<SyncException> syncFails() async {
    final host = await priya.engine.startHosting();
    try {
      await alex.engine.syncWithLink(host.connectLink);
    } on SyncException catch (e) {
      return e;
    }
    fail('sync unexpectedly succeeded');
  }

  Future<void> nextSessionWorks() async {
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    tap
      ..onSend = null
      ..onReceive = null;
    if (!(await priya.ledger.groupKeys()).containsKey(seed.g)) {
      await priya.join(alex, seed.g);
    }
    final host = await priya.engine.startHosting();
    await alex.engine.syncWithLink(host.connectLink);
    expect(priya.canonical['groups'] is Map, isTrue);
    expect(
      priya.opsOf(seed.g).map((o) => o.id).toSet(),
      alex.opsOf(seed.g).map((o) => o.id).toSet(),
    );
    expect(priya.spy.duplicatesIgnored, 0);
  }

  test(
    'no shared group: noSharedGroups on both sides, nothing applied',
    () async {
      await priya.seedGroup(expenses: 2, name: 'Flat');
      final e = await syncFails();
      expect(e.failure, SyncFailure.noSharedGroups);
      expect(priya.state.groups.containsKey(seed.g), isFalse);
      expect(priya.spy.applyRemoteCalls, 0);
      await waitFor(() async => (await priya.records()).isNotEmpty);
      expect((await priya.records()).single.error, contains('noSharedGroups'));
      await nextSessionWorks();
    },
  );

  test('wrong group key (same id): noSharedGroups, nothing applied', () async {
    await priya.ledger.registerJoinedGroup(seed.g, groupKeyOf(99), 'Goa trip');
    final e = await syncFails();
    expect(e.failure, SyncFailure.noSharedGroups);
    expect(priya.spy.applyRemoteCalls, 0);
    expect(alex.spy.applyRemoteCalls, 0);
  });

  test('tampered AUTH mac: authFailed, nothing applied, next works', () async {
    await priya.join(alex, seed.g);
    // 2nd frame = AUTH: a well-formed AUTH with a wrong mac.
    tap.onSend = (i, f) {
      if (i != 1) return f;
      final auth = FrameCodec.decodePlainFrame(f) as AuthMessage;
      return FrameCodec.plainFrame(AuthMessage(mac: flipByte(auth.mac, 0)));
    };
    final e = await syncFails();
    expect(e.failure, SyncFailure.authFailed);
    expect(priya.spy.applyRemoteCalls, 0);
    expect(priya.opCount(seed.g), 0);
    await waitFor(() async => (await priya.records()).isNotEmpty);
    expect((await priya.records()).single.error, contains('authFailed'));
    await nextSessionWorks();
  });

  // Alex's frames: 0 HELLO, 1 AUTH, 2 VV, 3 OPS, 4 DONE, 5 BYE.
  for (final (at, what) in [(2, 'VV'), (3, 'OPS'), (4, 'DONE')]) {
    test('tampered sealed $what from the initiator: host fails authFailed, '
        'tampered content never applied', () async {
      await priya.join(alex, seed.g);
      tap.onSend = (i, f) => i == at ? flipByte(f) : f;
      final host = await priya.engine.startHosting();
      final result = await alex.engine
          .syncWithLink(host.connectLink)
          .then<Object>((s) => s, onError: (Object e) => e);
      await waitFor(() async => (await priya.records()).isNotEmpty);
      expect((await priya.records()).single.error, contains('authFailed'));
      if (at <= 3) {
        expect(result, isA<SyncException>());
        expect(priya.opCount(seed.g), 0, reason: 'the OPS frame was forged');
      } else {
        // DONE came after the OPS batch was ACKed: Alex's data really did
        // arrive, so Alex may report success; Priya keeps every op once.
        expect(priya.opCount(seed.g), alex.opCount(seed.g));
      }
      await nextSessionWorks();
    });
  }

  test('tampered frame toward the initiator: initiator authFailed', () async {
    await priya.join(alex, seed.g);
    // Priya's 3rd frame is her first sealed one (VV or DONE).
    tap.onReceive = (i, f) => i == 2 ? flipByte(f, 10) : f;
    final e = await syncFails();
    expect(e.failure, SyncFailure.authFailed);
    await nextSessionWorks();
  });

  test(
    'a dropped (not altered) sealed frame is detected, not skipped',
    () async {
      await alex.addExpenses(seed, 600);
      await priya.join(alex, seed.g);
      var dropped = false;
      tap.onSend = (i, f) {
        if (i == 4 && !dropped) {
          dropped = true;
          return null;
        }
        return f;
      };
      final e = await syncFails();
      expect(e.failure, isNot(SyncFailure.cancelled));
      await waitFor(() async => (await priya.records()).isNotEmpty);
      expect(
        (await priya.records()).single.outcome,
        anyOf(SyncOutcome.failed, SyncOutcome.partial),
      );
      await nextSessionWorks();
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );

  test('replayed HELLO + AUTH from an earlier session: rejected, no ops, host '
      'still serves the real phone', () async {
    await priya.join(alex, seed.g);
    final host = await priya.engine.startHosting();
    await alex.engine.syncWithLink(host.connectLink);
    final captured = tap.sent.single;
    expect(captured.length, greaterThan(2));
    await Future<void>.delayed(const Duration(milliseconds: 300));

    // Mallory replays Alex's HELLO, AUTH and first sealed frames.
    final mallory = MemoryTransport(
      hub,
      kind: TransportKind.lan,
      address: 'm-lan',
    );
    final ch = await mallory.connect(
      const DiscoveredPeer(
        kind: TransportKind.lan,
        address: 'b-lan',
        name: 'Priya',
      ),
    );
    final got = <Uint8List>[];
    final done = Completer<void>();
    ch.frames.listen(
      got.add,
      onDone: done.complete,
      onError: (Object _) {
        if (!done.isCompleted) done.complete();
      },
    );
    final before = priya.totalOps;
    final recordsBefore = (await priya.records()).length;
    for (final f in captured.take(6)) {
      await ch.send(f);
    }
    await done.future.timeout(const Duration(seconds: 5));
    expect(priya.totalOps, before);
    await waitFor(() async => (await priya.records()).length > recordsBefore);
    final r = (await priya.records()).first;
    expect(r.outcome, SyncOutcome.failed);
    expect(r.error, contains('authFailed'));
    await mallory.dispose();

    await alex.addExpenses(seed, 1);
    final s = await alex.engine.syncWithLink(host.connectLink);
    expect(s.sentOps, 1);
  });

  test('a stranger with no keys at all: noSharedGroups, the host keeps '
      'hosting', () async {
    await priya.join(alex, seed.g);
    final stranger = await QaPhone.create(
      hub,
      'z',
      'Stranger',
      kinds: const [TransportKind.lan],
    );
    phones.add(stranger);
    final host = await priya.engine.startHosting();
    await expectLater(
      stranger.engine.syncWithLink(host.connectLink),
      throwsA(
        isA<SyncException>().having(
          (e) => e.failure,
          'failure',
          SyncFailure.noSharedGroups,
        ),
      ),
    );
    expect(priya.engine.status.host, isNotNull);
    expect(stranger.totalOps, 0);
    await nextSessionWorks();
  });
}
