import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/crypto/aead.dart';
import 'package:settle_up/sync/protocol/codec.dart';
import 'package:settle_up/sync/protocol/messages.dart';
import 'package:settle_up/sync/protocol/session.dart';
import 'package:settle_up/sync/sync_engine.dart';

import 'support/harness.dart';
import 'support/phone.dart';

void main() {
  late TestPhone alex, priya, ravi;

  setUp(() async {
    alex = await TestPhone.create('a', deviceName: "Alex's Pixel");
    priya = await TestPhone.create(
      'b',
      deviceName: "Priya's Pixel",
      name: 'Priya',
    );
    ravi = await TestPhone.create(
      'c',
      deviceName: "Ravi's iPhone",
      name: 'Ravi',
    );
  });

  tearDown(() async {
    await alex.close();
    await priya.close();
    await ravi.close();
  });

  test('a fresh joiner receives the whole group', () async {
    final s = await alex.seedGroup(expenses: 5);
    await priya.join(alex, s.g);

    final (ra, rp) = await syncPair(alex, priya);

    expect(ra.outcome, SyncOutcome.completed);
    expect(rp.outcome, SyncOutcome.completed);
    expect(priya.canonical, alex.canonical);
    expect(priya.state.groups[s.g]!.liveExpenses, hasLength(5));
    expect(ra.sentOps, 8); // group + 2 members + 5 expenses
    expect(rp.receivedOps, 8);
    expect(rp.receivedByGroup, {s.g: 8});
    expect(ra.groupIds, [s.g]);
    expect(ra.peerDeviceId, priya.deviceId);
    expect(ra.peerName, "Priya's Pixel");
    expect(ra.verificationCode, matches(RegExp(r'^\d{6}$')));
    expect(ra.verificationCode, rp.verificationCode);
    // The sender learned what the receiver now holds (unshared count).
    expect((await alex.peerKnowledge(s.g))[alex.deviceId], 8);
  });

  test('DATA-R5-02: a HELLO name with nothing to show (only hidden '
      'characters) falls back to the advert or link name', () async {
    final s = await alex.seedGroup(expenses: 1);
    await priya.join(alex, s.g);
    // Settings here refuse a phone name with no letter or number, but a
    // phone on an older version only trimmed it, so a zero-width space is
    // a 1-character name there; the peer cleans it to ''.
    expect(
      () => priya.settings.setDeviceName('\u200B'),
      throwsArgumentError,
    );
    priya.store.deviceNameOverride = '\u200B';
    final (ci, cr) = await channelPair();
    final si = SyncSession(
      channel: ci,
      store: alex.store,
      role: SessionRole.initiator,
      timings: fastTimings,
      peerNameHint: "Priya's Pixel",
    );
    final sr = SyncSession(
      channel: cr,
      store: priya.store,
      role: SessionRole.responder,
      timings: fastTimings,
    );
    final results = await Future.wait([si.run(), sr.run()]);
    expect(results[0].outcome, SyncOutcome.completed);
    expect(results[0].peerName, "Priya's Pixel");
    expect(results[1].peerName, "Alex's Pixel");
  });

  test('concurrent edits on both sides are equal after one session', () async {
    final s = await alex.seedGroup(expenses: 2);
    await priya.join(alex, s.g);
    await syncPair(alex, priya);

    final e = alex.state.groups[s.g]!.liveExpenses.first.id;
    await alex.rename(s.g, e, 'Dinner at the shack');
    await alex.addExpense(s.g, payer: s.a, owers: [s.a, s.b], total: 990);
    await priya.addExpense(s.g, payer: s.b, owers: [s.a, s.b], total: 450);
    await priya.rename(s.g, e, 'Shack dinner');
    expect(priya.canonical, isNot(alex.canonical));

    final (ra, rp) = await syncPair(priya, alex);

    expect(ra.outcome, SyncOutcome.completed);
    expect(rp.outcome, SyncOutcome.completed);
    expect(priya.canonical, alex.canonical);
    expect(alex.state.groups[s.g]!.liveExpenses, hasLength(4));
    expect(ra.sentOps, 2);
    expect(ra.receivedOps, 2);
  });

  test('gossip: A and C converge through B without meeting', () async {
    final s = await alex.seedGroup(expenses: 4);
    await priya.join(alex, s.g);
    await ravi.join(alex, s.g);

    await syncPair(alex, priya);
    await priya.addExpense(s.g, payer: s.b, owers: [s.a, s.b], total: 300);
    final (rb, rc) = await syncPair(priya, ravi);

    expect(rb.outcome, SyncOutcome.completed);
    expect(rc.outcome, SyncOutcome.completed);
    // Ravi got Alex's ops relayed by Priya (third-party ops).
    expect(
      ravi.opsOf(s.g).where((op) => op.deviceId == alex.deviceId),
      hasLength(7),
    );
    expect(ravi.canonical, priya.canonical);

    // Alex and Ravi never met; one more hop brings Priya's op back.
    await syncPair(ravi, alex);
    expect(alex.canonical, ravi.canonical);
    expect(alex.canonical, priya.canonical);
  });

  test(
    'several shared groups sync in one session; unshared ones do not',
    () async {
      final g1 = (await alex.seedGroup()).g;
      final g2 = (await alex.seedGroup()).g;
      final g3 = (await alex.seedGroup()).g; // Priya is not in g3
      await priya.join(alex, g1);
      await priya.join(alex, g2);
      final g4 = (await priya.seedGroup()).g; // Alex is not in g4

      final (ra, rp) = await syncPair(alex, priya);

      expect(ra.outcome, SyncOutcome.completed);
      expect(ra.groupIds, [g1, g2]..sort());
      expect(rp.groupIds, ra.groupIds);
      expect(priya.opCount(g1), 6);
      expect(priya.opCount(g2), 6);
      expect(priya.opCount(g3), 0);
      expect(alex.opCount(g4), 0);
    },
  );

  test(
    '2,000 ops over 16 KiB frames (BLE sized), batched within limits',
    () async {
      final s = await alex.seedGroup(expenses: 0);
      await alex.addExpenses(s, 1997);
      await priya.join(alex, s.g);
      late InterceptChannel tap;

      final (ra, rp) = await syncPair(
        alex,
        priya,
        maxFrameBytes: 16 * 1024,
        wrapResponder: (c) => tap = InterceptChannel(c, passThrough),
      );

      expect(ra.outcome, SyncOutcome.completed, reason: ra.message);
      expect(rp.outcome, SyncOutcome.completed, reason: rp.message);
      expect(priya.opCount(s.g), 2000);
      expect(priya.canonical, alex.canonical);
      expect(ra.sentOps, 2000);
      expect(
        tap.receivedSizes.reduce((a, b) => a > b ? a : b),
        lessThanOrEqualTo(16 * 1024),
      );
      // Many OPS batches, each committed separately.
      expect(priya.applyRemoteCalls, greaterThan(10));
      expect(priya.duplicatesIgnored, 0);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('a dropped connection is partial; the next session completes '
      'without duplicates', () async {
    final s = await alex.seedGroup(expenses: 0);
    await alex.addExpenses(s, 300);
    await priya.join(alex, s.g);

    final (ra, rp) = await syncPair(
      alex,
      priya,
      maxFrameBytes: 16 * 1024,
      dropAfterFrames: 14,
    );

    expect(ra.outcome, SyncOutcome.partial, reason: ra.message);
    expect(ra.failure, SyncFailure.connectionLost);
    expect(rp.outcome, SyncOutcome.partial, reason: rp.message);
    final first = priya.opCount(s.g);
    expect(first, greaterThan(0));
    expect(first, lessThan(303));
    expect(ra.sentOps, lessThanOrEqualTo(first));

    final (ra2, rp2) = await syncPair(alex, priya, maxFrameBytes: 16 * 1024);

    expect(ra2.outcome, SyncOutcome.completed);
    expect(rp2.outcome, SyncOutcome.completed);
    expect(priya.opCount(s.g), 303);
    expect(rp2.receivedOps, 303 - first);
    expect(priya.duplicatesIgnored, 0);
    expect(priya.canonical, alex.canonical);
  });

  test('a rejected batch fails both sides with bad_op', () async {
    final s = await alex.seedGroup();
    await priya.join(alex, s.g);
    // Like a store that finds a bad op in every batch.
    priya.store.onApplyRemote = (_, _) =>
        Future.error(const FormatException('rejected'));

    final (ra, rp) = await syncPair(alex, priya);

    expect(rp.failure, SyncFailure.protocolMismatch);
    expect(ra.failure, SyncFailure.protocolMismatch);
    expect(ra.message, contains(ErrorCodes.badOp));
    expect(priya.opCount(s.g), 0);
  });

  test('a version-vector gap closes on the next sync', () async {
    final s = await alex.seedGroup(expenses: 0);
    await priya.join(alex, s.g);
    await ravi.join(alex, s.g);
    await syncPair(alex, priya);
    await syncPair(alex, ravi);
    await ravi.addExpenses(s, 5);
    final fromRavi = [
      for (final op in ravi.opsOf(s.g))
        if (op.deviceId == ravi.deviceId) op,
    ];
    // Alex got all of Ravi's ops; Priya got them through a relay that
    // lost counter 3, so her contiguous VV for Ravi stops at 2.
    await alex.ledger.applyRemote(s.g, fromRavi);
    await priya.ledger
        .applyRemote(s.g, [for (final op in fromRavi) if (op.counter != 3) op]);
    expect((await priya.ledger.versionVector(s.g))[ravi.deviceId], 2);
    expect(priya.opCount(s.g), 7);

    final (ra, rp) = await syncPair(alex, priya);

    expect(ra.outcome, SyncOutcome.completed);
    expect(rp.outcome, SyncOutcome.completed);
    expect((await priya.ledger.versionVector(s.g))[ravi.deviceId], 5);
    expect(await priya.ledger.versionVector(s.g),
        await alex.ledger.versionVector(s.g));
    expect(priya.opCount(s.g), 8);
    expect(rp.receivedByGroup, {s.g: 1});
    // Ops past the gap are offered again and ignored (SPEC 7.4).
    expect(priya.duplicatesIgnored, 2);
    expect(priya.canonical, alex.canonical);
  });

  test('nothing to send on either side still completes', () async {
    final s = await alex.seedGroup();
    await priya.join(alex, s.g);
    await syncPair(alex, priya);

    final (ra, rp) = await syncPair(priya, alex);

    expect(ra.outcome, SyncOutcome.completed);
    expect(rp.outcome, SyncOutcome.completed);
    expect(ra.sentOps + ra.receivedOps, 0);
  });

  test('progress reports totals, the verification code and phases', () async {
    final s = await alex.seedGroup(expenses: 40);
    await priya.join(alex, s.g);
    final (ci, cr) = await channelPair(maxFrameBytes: 4096);
    final seen = <SyncProgress>[];
    final si = SyncSession(
      channel: ci,
      store: alex.store,
      role: SessionRole.initiator,
      timings: fastTimings,
      onProgress: seen.add,
    );
    final sr = SyncSession(
      channel: cr,
      store: priya.store,
      role: SessionRole.responder,
      timings: fastTimings,
    );

    await Future.wait([si.run(), sr.run()]);

    expect(seen, isNotEmpty);
    final phases = seen.map((p) => p.phase).toSet();
    expect(phases, contains(SyncPhase.handshaking));
    expect(phases, contains(SyncPhase.finishing));
    expect(seen.last.toSendOps, 43);
    expect(seen.last.groupIds, [s.g]);
    expect(seen.last.verificationCode, isNotNull);
    expect(seen.first.verificationCode, isNull);
  });

  test('the handshake times out when the peer never answers', () async {
    final (ci, cr) = await channelPair();
    unawaited(cr.frames.drain<void>()); // a silent peer
    await alex.seedGroup();
    final si = SyncSession(
      channel: ci,
      store: alex.store,
      role: SessionRole.initiator,
      timings: const SessionTimings(
        handshakeTimeout: Duration(milliseconds: 200),
        tick: Duration(milliseconds: 20),
      ),
    );

    final r = await si.run();

    expect(r.failure, SyncFailure.timeout);
    expect(r.outcome, SyncOutcome.failed);
  });

  test('cancel sends ERROR cancelled to the peer', () async {
    final s = await alex.seedGroup(expenses: 200);
    await priya.join(alex, s.g);
    final (ci, cr) = await channelPair(
      maxFrameBytes: 4096,
      latency: const Duration(milliseconds: 5),
    );
    final si = SyncSession(
      channel: ci,
      store: alex.store,
      role: SessionRole.initiator,
      timings: fastTimings,
    );
    final sr = SyncSession(
      channel: cr,
      store: priya.store,
      role: SessionRole.responder,
      timings: fastTimings,
    );
    final fi = si.run();
    final fr = sr.run();
    await eventually(() => si.state == SessionState.exchanging);

    await si.cancel();

    expect((await fi).outcome, SyncOutcome.cancelled);
    final rr = await fr;
    expect(rr.failure, SyncFailure.cancelled, reason: rr.message);
  });

  test(
    'frames other than HELLO, AUTH and ERROR before AUTH are rejected',
    () async {
      await alex.seedGroup();
      final (ci, cr) = await channelPair();
      final peerFrames = <Uint8List>[];
      final sub = cr.frames.listen(peerFrames.add);
      final si = SyncSession(
        channel: ci,
        store: alex.store,
        role: SessionRole.initiator,
        timings: fastTimings,
      );
      final f = si.run();
      await cr.send(FrameCodec.plainFrame(const PingMessage(1)));

      final r = await f;

      expect(r.failure, SyncFailure.protocolMismatch);
      await eventually(() => peerFrames.length >= 2);
      final error = FrameCodec.decodePlainFrame(peerFrames.last);
      expect((error as ErrorMessage).code, ErrorCodes.badFrame);
      await sub.cancel();
    },
  );

  test('a sealed frame before AUTH is rejected', () async {
    await alex.seedGroup();
    final (ci, cr) = await channelPair();
    unawaited(cr.frames.drain<void>());
    final si = SyncSession(
      channel: ci,
      store: alex.store,
      role: SessionRole.initiator,
      timings: fastTimings,
    );
    final f = si.run();
    final bogus = Uint8List(64)..[0] = FrameKind.sealed;
    await cr.send(bogus);

    expect((await f).failure, SyncFailure.protocolMismatch);
    expect(bogus.length, greaterThan(kSealOverhead));
  });

  test('live mode pushes a new local op to the peer within 1 s', () async {
    final s = await alex.seedGroup();
    await priya.join(alex, s.g);
    final (ci, cr) = await channelPair();
    var aliveA = false;
    final si = SyncSession(
      channel: ci,
      store: alex.store,
      role: SessionRole.initiator,
      timings: fastTimings,
      liveMode: true,
      onLive: (_) => aliveA = true,
    );
    final sr = SyncSession(
      channel: cr,
      store: priya.store,
      role: SessionRole.responder,
      timings: fastTimings,
      liveMode: true,
    );
    final fa = si.run();
    final fp = sr.run();
    expect(
      await eventually(() => aliveA && sr.state == SessionState.live),
      isTrue,
    );
    expect(priya.canonical, alex.canonical);

    final sw = Stopwatch()..start();
    await alex.addExpense(s.g, payer: s.a, owers: [s.a, s.b], total: 777);
    expect(priya.opCount(s.g), 6);
    expect(await eventually(() => priya.opCount(s.g) == 7), isTrue);
    expect(sw.elapsed, lessThan(const Duration(seconds: 1)));
    // And the other way.
    await priya.addExpense(s.g, payer: s.b, owers: [s.a, s.b], total: 222);
    expect(await eventually(() => alex.opCount(s.g) == 8), isTrue);
    // Keepalive holds the session open past the idle limit... briefly.
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(si.state, SessionState.live);

    si.liveMode = false;
    final ra = await fa;
    final rp = await fp;
    expect(ra.outcome, SyncOutcome.completed);
    expect(rp.outcome, SyncOutcome.completed);
    expect(ra.sentOps, 7);
    expect(ra.receivedOps, 1);
    expect(priya.canonical, alex.canonical);
  });

  test('leaving live mode while the peer pushes an op completes both sides',
      () async {
    final s = await alex.seedGroup();
    await priya.join(alex, s.g);
    final (ci, cr) =
        await channelPair(latency: const Duration(milliseconds: 40));
    final tap = InterceptChannel(cr, passThrough);
    final si = SyncSession(
        channel: ci,
        store: alex.store,
        role: SessionRole.initiator,
        timings: fastTimings,
        liveMode: true);
    final sr = SyncSession(
        channel: tap,
        store: priya.store,
        role: SessionRole.responder,
        timings: fastTimings,
        liveMode: true);
    final fa = si.run();
    final fp = sr.run();
    expect(
        await eventually(() =>
            si.state == SessionState.live && sr.state == SessionState.live),
        isTrue);
    final sent = tap.sentSizes.length;

    // Priya pushes an op; Alex leaves the Sync screen while it is on the
    // wire, so his BYE crosses her OPS.
    await priya.addExpense(s.g, payer: s.b, owers: [s.a, s.b], total: 321);
    expect(await eventually(() => tap.sentSizes.length > sent), isTrue);
    si.liveMode = false;

    final ra = await fa;
    final rp = await fp;
    expect(ra.outcome, SyncOutcome.completed, reason: ra.message);
    expect(rp.outcome, SyncOutcome.completed, reason: rp.message);
    expect(alex.opCount(s.g), 7);
    expect(rp.sentOps, 1);
    expect(priya.canonical, alex.canonical);
  });
}
