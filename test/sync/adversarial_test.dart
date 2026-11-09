// Adversarial and fault-injection tests for the sync core (SPEC 8):
// hostile or confused peers, size limits, links, leaks and resume.
import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/sync/crypto/handshake.dart';
import 'package:settle_up/sync/protocol/codec.dart';
import 'package:settle_up/sync/protocol/messages.dart';
import 'package:settle_up/sync/protocol/session.dart';
import 'package:settle_up/sync/sync_engine.dart';

import 'support/evil_peer.dart';
import 'support/harness.dart';
import 'support/test_ledger.dart';

void main() {
  late TestLedger alex, priya;

  setUp(() {
    alex = TestLedger(deviceIdOf('a'), localDeviceName: 'Alex');
    priya = TestLedger(deviceIdOf('b'), localDeviceName: 'Priya');
  });

  /// Priya runs a responder session; the returned peer is the other end.
  Future<(EvilPeer, Future<SessionResult>, SyncSession)> victim(
    TestLedger store, {
    SessionTimings timings = fastTimings,
  }) async {
    final (ci, cr) = await channelPair();
    final session = SyncSession(
      channel: cr,
      store: store,
      role: SessionRole.responder,
      timings: timings,
    );
    final result = session.run();
    return (EvilPeer(ci, initiator: true), result, session);
  }

  group('a member of one group', () {
    // Priya holds groups 1 and 2. Mallory only holds group 1's key but
    // has copies of group 2 ops (from somewhere).
    late List<Operation> g2ops;
    setUp(() async {
      await seedGroup(alex, group: 1, expenses: 1);
      await seedGroup(alex, group: 2, expenses: 1);
      g2ops = alex.opsOf(groupIdOf(2));
      await priya.registerJoinedGroup(groupIdOf(1), groupKeyOf(1), 'G1');
      await priya.registerJoinedGroup(groupIdOf(2), groupKeyOf(2), 'G2');
    });

    test('proves only that group: S excludes the other', () async {
      final (evil, result, s) = await victim(priya);
      final keys = await evil.handshake({groupIdOf(1): groupKeyOf(1)});
      expect(keys.sharedGroups, [groupIdOf(1)]);
      await eventually(() => s.state == SessionState.exchanging);
      expect(s.sharedGroups, [groupIdOf(1)]);
      await evil.close();
      await result;
    });

    test('cannot push ops into a group it did not prove', () async {
      final (evil, result, _) = await victim(priya);
      await evil.handshake({groupIdOf(1): groupKeyOf(1)});
      await evil.sendSealed(OpsMessage(
          groupId: groupIdOf(2), batch: 1, total: 1, ops: g2ops, more: false));
      final r = await result;
      expect(r.failure, SyncFailure.protocolMismatch);
      expect(priya.opCount(groupIdOf(2)), 0);
    });

    test('cannot smuggle another group op inside a proven batch', () async {
      final (evil, result, _) = await victim(priya);
      await evil.handshake({groupIdOf(1): groupKeyOf(1)});
      final g1ops = alex.opsOf(groupIdOf(1));
      await evil.sendSealed(OpsMessage(
          groupId: groupIdOf(1),
          batch: 1,
          total: 2,
          ops: [g1ops.first, g2ops.first],
          more: false));
      final r = await result;
      expect(r.failure, SyncFailure.protocolMismatch);
      expect(priya.opCount(groupIdOf(1)), 0);
      expect(priya.opCount(groupIdOf(2)), 0);
    });

    test('asking for the other group (VV) gets nothing from it', () async {
      await seedGroup(priya, group: 3, expenses: 0); // so priya has ops
      final (evil, result, _) = await victim(priya);
      await evil.handshake({groupIdOf(1): groupKeyOf(1)});
      await evil.sendSealed(emptyVv(groupIdOf(2)));
      final r = await result;
      expect(r.failure, SyncFailure.protocolMismatch);
      expect(evil.received.whereType<OpsMessage>(), isEmpty);
    });

    test('duplicate VV, ACK for nothing, DONE for an unproven group', () async {
      for (final bad in <SyncMessage Function()>[
        () => emptyVv(groupIdOf(1)),
        () => AckMessage(
            groupId: groupIdOf(1), batch: 9, vv: emptyVv('x').vv),
        () => DoneMessage(groupId: groupIdOf(2)),
      ]) {
        final store = TestLedger(deviceIdOf('p'));
        await store.registerJoinedGroup(groupIdOf(1), groupKeyOf(1), 'G1');
        await store.registerJoinedGroup(groupIdOf(2), groupKeyOf(2), 'G2');
        final (evil, result, _) = await victim(store);
        await evil.handshake({groupIdOf(1): groupKeyOf(1)});
        await evil.sendSealed(emptyVv(groupIdOf(1)));
        await evil.sendSealed(bad());
        final r = await result;
        expect(r.failure, SyncFailure.protocolMismatch, reason: r.message);
      }
    });
  });

  group('size limits', () {
    test('an unauthenticated peer cannot make us inflate a large body',
        () async {
      await seedGroup(priya, expenses: 0);
      final (evil, result, _) = await victim(priya);
      // A real HELLO padded with whitespace to 512 KiB of JSON, gzipped to
      // a few hundred bytes. Nothing legitimate before AUTH is that big.
      final hs = await Handshake.start(
        initiator: true,
        groupKeys: {groupIdOf(1): groupKeyOf(1)},
        deviceId: deviceIdOf('m'),
        deviceName: 'Mallory',
        maxFrame: 1 << 20,
        transport: TransportKind.lan,
      );
      final json = jsonEncode(hs.hello.toJson());
      final padded = '${' ' * (512 * 1024)}$json';
      final body = gzip.encode(utf8.encode(padded));
      final frame = Uint8List.fromList(
          [FrameKind.plain, MessageType.hello.code, kFlagGzip, ...body]);
      expect(frame.length, lessThan(4096));
      await evil.channel.send(frame);
      final r = await result;
      expect(r.failure, SyncFailure.protocolMismatch);
      expect(r.message, contains('too large'));
      expect(evil.received.whereType<AuthMessage>(), isEmpty);
    });

    test('a legitimate HELLO with 256 groups still fits', () {
      final keys = {
        for (var i = 0; i < 300; i++) groupIdOf(i): groupKeyOf(i),
      };
      return Handshake.start(
        initiator: true,
        groupKeys: keys,
        deviceId: deviceIdOf('a'),
        deviceName: 'x' * 100,
        maxFrame: 1 << 20,
        transport: TransportKind.lan,
      ).then((hs) {
        final m = FrameCodec.decodePlainFrame(hs.helloFrame,
            maxBodyBytes: kMaxPreAuthBodyBytes);
        expect((m as HelloMessage).blindedGroups, hasLength(kMaxHelloGroups));
      });
    });
  });

  group('resources', () {
    test('a live session leaves no listener on localOps', () async {
      await seedGroup(alex);
      await priya.registerJoinedGroup(groupIdOf(1), groupKeyOf(1), 'G');
      final (ci, cr) = await channelPair();
      final si = SyncSession(
          channel: ci,
          store: alex,
          role: SessionRole.initiator,
          timings: fastTimings,
          liveMode: true);
      final sr = SyncSession(
          channel: cr,
          store: priya,
          role: SessionRole.responder,
          timings: fastTimings,
          liveMode: true);
      final fa = si.run();
      final fp = sr.run();
      expect(
          await eventually(() =>
              si.state == SessionState.live && sr.state == SessionState.live),
          isTrue);
      expect(alex.hasLocalOpsListener, isTrue);
      si.liveMode = false;
      expect((await fa).outcome, SyncOutcome.completed);
      expect((await fp).outcome, SyncOutcome.completed);
      expect(alex.hasLocalOpsListener, isFalse);
      expect(priya.hasLocalOpsListener, isFalse);
    });

    test('a failed session leaves no listener on localOps', () async {
      await seedGroup(priya, expenses: 0);
      final (evil, result, _) = await victim(priya);
      await evil.handshake({groupIdOf(1): groupKeyOf(1)});
      expect(await eventually(() => priya.hasLocalOpsListener), isTrue);
      await evil.close();
      await result;
      expect(priya.hasLocalOpsListener, isFalse);
    });
  });

  group('drop anywhere, then resume', () {
    for (final drop in [3, 5, 7, 9, 12, 17, 23, 31]) {
      test('drop after $drop frames, two groups, both sides writing',
          () async {
        final a1 = await seedGroup(alex, group: 1, expenses: 0);
        final a2 = await seedGroup(alex, group: 2, expenses: 0);
        await priya.registerJoinedGroup(a1.g, groupKeyOf(1), 'G1');
        await priya.registerJoinedGroup(a2.g, groupKeyOf(2), 'G2');
        await syncPair(alex, priya);
        for (var i = 0; i < 120; i++) {
          await alex.authorExpense(i.isEven ? a1.g : a2.g,
              payer: i.isEven ? a1.a : a2.a,
              owers: i.isEven ? [a1.a, a1.b] : [a2.a, a2.b],
              total: 100 + i);
          await priya.authorExpense(i.isEven ? a2.g : a1.g,
              payer: i.isEven ? a2.b : a1.b,
              owers: i.isEven ? [a2.a, a2.b] : [a1.a, a1.b],
              total: 300 + i);
        }
        final dupsBefore = priya.duplicatesIgnored + alex.duplicatesIgnored;
        final (r1, _) =
            await syncPair(alex, priya, maxFrameBytes: 8192, dropAfterFrames: drop);
        expect(r1.isSuccess, isFalse);
        final (r2a, r2p) = await syncPair(priya, alex, maxFrameBytes: 8192);
        expect(r2a.outcome, SyncOutcome.completed, reason: r2a.message);
        expect(r2p.outcome, SyncOutcome.completed, reason: r2p.message);
        expect(priya.canonical, alex.canonical);
        expect(alex.opCount(a1.g), priya.opCount(a1.g));
        expect(alex.opCount(a2.g), priya.opCount(a2.g));
        expect(priya.duplicatesIgnored + alex.duplicatesIgnored, dupsBefore);
        for (final g in [a1.g, a2.g]) {
          expect(await alex.versionVector(g), await priya.versionVector(g));
        }
      });
    }
  });
}
