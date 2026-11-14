// QA SECURITY round 42 (final regression sweep): the only product change
// since round 41 is the SYNC-R41-01 fix in SyncSession, which now keeps the
// peer's version vector from VV and every ACK to count what was "sent".
// Those vectors come from the other phone, so a key holder sending forged
// ACKs must not crash the session, inflate "sent" past what was offered,
// or undo the SECURITY-R2-01 clamp of stored peer knowledge.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/sync/protocol/messages.dart';
import 'package:settle_up/sync/protocol/session.dart';

import '../../sync/support/evil_peer.dart';
import '../../sync/support/harness.dart';
import '../../sync/support/phone.dart';

const DeviceId mallory = 'eeeeeeee-0000-7000-8000-000000000042';

/// Seals a raw ACK body (bypasses the typed encoder).
Future<void> sendRawAck(EvilPeer evil, Map<String, Object?> body) async {
  final json = utf8.encode(jsonEncode(body));
  final plain = Uint8List(2 + json.length)
    ..[0] = MessageType.ack.code
    ..[1] = 0
    ..setRange(2, 2 + json.length, json);
  await evil.channel.send(await evil.keys!.cipher.seal(plain));
}

void main() {
  late TestPhone alex, priya;
  late Seed seed;

  setUp(() async {
    alex = await TestPhone.create('a', deviceName: 'Alex');
    priya = await TestPhone.create('b', deviceName: 'Priya', name: 'Priya');
    seed = await alex.seedGroup(expenses: 2);
    await priya.join(alex, seed.g);
    final (ri, rr) = await syncPair(alex, priya);
    expect(ri.isSuccess && rr.isSuccess, isTrue);
    // Changes only Priya has, so she has her own ops to offer Mallory.
    await priya.addExpenses(seed, 3);
  });

  tearDown(() async {
    await alex.close();
    await priya.close();
  });

  /// Mallory holds the group key and dials Priya, claiming to hold nothing.
  /// Returns her and Priya's session result once Priya's first OPS arrives.
  Future<(EvilPeer, Future<SessionResult>, OpsMessage)> attack() async {
    final (ci, cr) = await channelPair();
    final result = SyncSession(
      channel: cr,
      store: priya.store,
      role: SessionRole.responder,
      timings: fastTimings,
    ).run();
    final evil = EvilPeer(ci, initiator: true);
    await evil.handshake({seed.g: await alex.keyOf(seed.g)}, deviceId: mallory);
    await evil.sendSealed(emptyVv(seed.g));
    final ops = await evil.until((m) => m is OpsMessage);
    expect(ops, isA<OpsMessage>());
    return (evil, result, ops! as OpsMessage);
  }

  Future<void> expectStillSyncs() async {
    await alex.addExpense(seed.g, payer: seed.a, owers: [seed.a, seed.b]);
    final (ri, rr) = await syncPair(alex, priya);
    expect(ri.isSuccess, isTrue, reason: ri.message);
    expect(rr.isSuccess, isTrue, reason: rr.message);
    expect(priya.canonical, alex.canonical);
  }

  Future<int> ownWritten() async =>
      (await priya.opStore.versionVector(seed.g))[priya.deviceId];

  test(
    'a forged ACK vector claiming every counter and 10,000 authors '
    'leaves "sent" at most what was offered and peer knowledge clamped',
    () async {
      final written = await ownWritten();
      expect(written, greaterThan(0));
      final (evil, result, ops) = await attack();
      final forged = <DeviceId, int>{
        priya.deviceId: 1 << 52,
        alex.deviceId: 1 << 52,
        for (var i = 0; i < 9998; i++)
          'ffffffff-0000-7000-8000-${i.toString().padLeft(12, '0')}': 1 << 40,
      };
      await evil.sendSealed(
        AckMessage(
          groupId: seed.g,
          batch: ops.batch,
          vv: VersionVector(forged),
        ),
      );
      // Mallory has nothing to send; Priya may go on to DONE and BYE.
      await evil.sendSealed(DoneMessage(groupId: seed.g));
      await evil.until((m) => m is DoneMessage || m is ErrorMessage);
      await evil.sendSealed(const ByeMessage());
      final r = await result.timeout(const Duration(seconds: 10));
      await evil.close();
      expect(
        r.sentOps,
        lessThanOrEqualTo(ops.total),
        reason: 'only offered ops can be counted as sent',
      );
      // SECURITY-R2-01: Mallory cannot hold more of Priya's ops than exist.
      final stored = await priya.opStore.peerKnowledge(seed.g);
      expect(stored[priya.deviceId], lessThanOrEqualTo(written));
      // A later own change still counts as unshared.
      await priya.addExpense(seed.g, payer: seed.b, owers: [seed.a, seed.b]);
      await pumpEventQueue();
      expect(
        priya.ledger.current.unsharedCounts[seed.g] ?? 0,
        greaterThanOrEqualTo(1),
      );
      await expectStillSyncs();
    },
  );

  group('malformed ACK vectors are bad frames and Priya still syncs', () {
    final cases = <String, Map<String, Object?> Function(GroupId, int)>{
      'vv with 10,001 authors': (g, b) => {
        'g': g,
        'batch': b,
        'vv': {for (var i = 0; i < 10001; i++) 'd$i': 1},
      },
      'negative counter': (g, b) => {
        'g': g,
        'batch': b,
        'vv': {mallory: -1},
      },
      'double counter': (g, b) => {
        'g': g,
        'batch': b,
        'vv': {mallory: 1.5},
      },
      'vv as list': (g, b) => {
        'g': g,
        'batch': b,
        'vv': [1, 2],
      },
      'oversized author id': (g, b) => {
        'g': g,
        'batch': b,
        'vv': {'x' * 5000: 1},
      },
      'ACK for a group not shared': (g, b) => {
        'g': 'other-group',
        'batch': b,
        'vv': <String, Object?>{},
      },
      'ACK for a batch never sent': (g, b) => {
        'g': g,
        'batch': b + 99,
        'vv': <String, Object?>{},
      },
    };
    for (final MapEntry(key: name, value: body) in cases.entries) {
      test(name, () async {
        final (evil, result, ops) = await attack();
        await sendRawAck(evil, body(seed.g, ops.batch));
        final r = await result.timeout(const Duration(seconds: 10));
        await evil.close();
        expect(r.isSuccess, isFalse, reason: name);
        expect(r.sentOps, 0, reason: '$name: nothing was shared');
        await expectStillSyncs();
      });
    }
  });

  test('the same batch ACKed twice is refused the second time', () async {
    final (evil, result, ops) = await attack();
    final vv = await priya.opStore.versionVector(seed.g);
    await evil.sendSealed(
      AckMessage(groupId: seed.g, batch: ops.batch, vv: vv),
    );
    await evil.sendSealed(
      AckMessage(groupId: seed.g, batch: ops.batch, vv: vv),
    );
    final r = await result.timeout(const Duration(seconds: 10));
    await evil.close();
    expect(r.isSuccess, isFalse);
    expect(r.sentOps, lessThanOrEqualTo(ops.total));
    await expectStillSyncs();
  });
}
