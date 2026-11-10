// QA SECURITY round 1: op validation from peers (SPEC 8.5, 8.9, 5.16).
//
// A peer that holds a group key (a member, or anyone who photographed the
// QR) sends hostile OPS batches over a real SyncSession with the real
// Ledger behind it. Each test checks the batch is rejected with bad_op,
// nothing is stored, and the phone still syncs with an honest peer
// afterwards.
import 'dart:convert';
import 'dart:io' show gzip;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/sync/protocol/codec.dart';
import 'package:settle_up/sync/protocol/messages.dart';
import 'package:settle_up/sync/protocol/session.dart';
import 'package:settle_up/sync/sync_engine.dart';

import '../../sync/support/evil_peer.dart';
import '../../sync/support/harness.dart';
import '../../sync/support/phone.dart';

const DeviceId mallory = 'eeeeeeee-0000-7000-8000-000000000001';

/// Seals a raw JSON body as an OPS frame (bypasses the typed encoder so
/// the test can send malformed fields).
Future<void> sendRawOps(EvilPeer evil, Map<String, Object?> body) async {
  final json = utf8.encode(jsonEncode(body));
  var flags = 0;
  List<int> payload = json;
  if (json.length > kGzipThreshold) {
    payload = gzipEncode(json);
    flags = kFlagGzip;
  }
  final plain = Uint8List(2 + payload.length)
    ..[0] = MessageType.ops.code
    ..[1] = flags
    ..setRange(2, 2 + payload.length, payload);
  await evil.channel.send(await evil.keys!.cipher.seal(plain));
}

List<int> gzipEncode(List<int> bytes) => gzip.encode(bytes);

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
  });

  tearDown(() async {
    await alex.close();
    await priya.close();
  });

  Future<(EvilPeer, Future<SessionResult>)> attack() async {
    final (ci, cr) = await channelPair();
    final session = SyncSession(
      channel: cr,
      store: priya.store,
      role: SessionRole.responder,
      timings: fastTimings,
    );
    final result = session.run();
    final evil = EvilPeer(ci, initiator: true);
    await evil.handshake({seed.g: await alex.keyOf(seed.g)}, deviceId: mallory);
    return (evil, result);
  }

  /// A valid expense-create op JSON authored by [device].
  Map<String, Object?> expenseJson({
    String id = 'evil-op-1',
    DeviceId device = mallory,
    int counter = 1,
    int? millis,
    Map<String, Object?>? payloadOverride,
  }) {
    final template = alex.opsOf(seed.g).last; // an expense create
    return {
      ...template.toJson(),
      'id': id,
      'deviceId': device,
      'counter': counter,
      'hlc': Hlc(millis ?? kBaseMs + 5000, 0, device).encode(),
      'entityId': 'evil-expense-$id',
      'payload': {...template.payload, ...?payloadOverride},
    };
  }

  Future<ErrorMessage?> errorFrom(EvilPeer evil) async {
    final e = await evil.until((m) => m is ErrorMessage || m is AckMessage);
    return e is ErrorMessage ? e : null;
  }

  /// Priya still completes an honest sync with Alex.
  Future<void> expectStillSyncs() async {
    await alex.addExpense(seed.g, payer: seed.a, owers: [seed.a, seed.b]);
    final (ri, rr) = await syncPair(alex, priya);
    expect(ri.isSuccess, isTrue, reason: ri.message);
    expect(rr.isSuccess, isTrue, reason: rr.message);
    expect(priya.canonical, alex.canonical);
  }

  group('type confusion and malformed ops are rejected with bad_op', () {
    final cases = <String, Map<String, Object?> Function(Map<String, Object?>)>{
      'counter as string': (j) => {...j, 'counter': '1'},
      'counter as double': (j) => {...j, 'counter': 1.5},
      'counter zero': (j) => {...j, 'counter': 0},
      'counter negative': (j) => {...j, 'counter': -4},
      'id as int': (j) => {...j, 'id': 42},
      'missing groupId': (j) => {...j}..remove('groupId'),
      'payload as list': (j) => {
        ...j,
        'payload': [1, 2],
      },
      'payload as string': (j) => {...j, 'payload': 'x'},
      'hlc as number': (j) => {...j, 'hlc': 12},
      'hlc of another device': (j) => {
        ...j,
        'hlc': const Hlc(kBaseMs, 0, 'someone-else').encode(),
      },
      'hlc with 16 digit millis': (j) => {
        ...j,
        'hlc': '1234567890123456-0000-$mallory',
      },
      'unknown entityType at schema 1': (j) => {...j, 'entityType': 'robot'},
      'unknown kind at schema 1': (j) => {...j, 'kind': 'explode'},
      'schemaVersion as string': (j) => {...j, 'schemaVersion': '2'},
    };
    for (final MapEntry(key: name, value: mutate) in cases.entries) {
      test(name, () async {
        final (evil, result) = await attack();
        final before = priya.opCount(seed.g);
        await sendRawOps(evil, {
          'g': seed.g,
          'batch': 1,
          'total': 1,
          'ops': [mutate(expenseJson())],
          'more': false,
        });
        final error = await errorFrom(evil);
        expect(error?.code, ErrorCodes.badOp, reason: '$name: ${error?.msg}');
        final r = await result;
        expect(r.failure, SyncFailure.protocolMismatch);
        expect(priya.opCount(seed.g), before);
        await expectStillSyncs();
      });
    }

    test('an op entry that is not an object', () async {
      final (evil, result) = await attack();
      await sendRawOps(evil, {
        'g': seed.g,
        'batch': 1,
        'total': 1,
        'ops': ['not an op'],
        'more': false,
      });
      expect((await errorFrom(evil))?.code, ErrorCodes.badOp);
      await result;
      await expectStillSyncs();
    });

    test('ops field that is not a list is a bad frame', () async {
      final (evil, result) = await attack();
      await sendRawOps(evil, {
        'g': seed.g,
        'batch': 1,
        'total': 1,
        'ops': {'0': expenseJson()},
        'more': false,
      });
      expect((await errorFrom(evil))?.code, ErrorCodes.badFrame);
      await result;
      await expectStillSyncs();
    });

    test('more than 500 ops in one batch is a bad frame', () async {
      final (evil, result) = await attack();
      await sendRawOps(evil, {
        'g': seed.g,
        'batch': 1,
        'total': 501,
        'ops': [
          for (var i = 1; i <= 501; i++) expenseJson(id: 'bulk-$i', counter: i),
        ],
        'more': false,
      });
      expect((await errorFrom(evil))?.code, ErrorCodes.badFrame);
      await result;
      expect(priya.opsOf(seed.g).where((o) => o.deviceId == mallory), isEmpty);
      await expectStillSyncs();
    });
  });

  group('group scoping', () {
    test('an op whose groupId differs from the batch group', () async {
      final (evil, result) = await attack();
      await sendRawOps(evil, {
        'g': seed.g,
        'batch': 1,
        'total': 1,
        'ops': [
          {...expenseJson(), 'groupId': groupIdOf(99)},
        ],
        'more': false,
      });
      expect((await errorFrom(evil))?.code, ErrorCodes.badOp);
      await result;
      expect(priya.state.groups[groupIdOf(99)], isNull);
      await expectStillSyncs();
    });

    test('a group op whose entityId is another group is ignored', () async {
      final other = await priya.seedGroup(expenses: 0, name: 'Private');
      final (evil, result) = await attack();
      await sendRawOps(evil, {
        'g': seed.g,
        'batch': 1,
        'total': 1,
        'ops': [
          {
            ...expenseJson(),
            'entityType': 'group',
            'kind': 'update',
            'entityId': other.g,
            'payload': {'name': 'Hijacked', 'deletedAt': kBaseMs},
          },
        ],
        'more': false,
      });
      await errorFrom(evil);
      await evil.close();
      await result;
      final g = priya.state.groups[other.g]!.group!;
      expect(g.name, 'Private');
      expect(g.isDeleted, isFalse);
    });

    Future<void> crossGroupUpdate(
      Seed other,
      ExpenseId target,
      int millis,
    ) async {
      final (evil, result) = await attack();
      await sendRawOps(evil, {
        'g': seed.g,
        'batch': 1,
        'total': 1,
        'ops': [
          {
            ...expenseJson(millis: millis),
            'kind': 'update',
            'entityId': target,
            'payload': {'description': 'Pwned', 'deletedAt': kBaseMs},
          },
        ],
        'more': false,
      });
      await errorFrom(evil);
      await evil.close();
      await result;
    }

    test(
      'a later update for an expense of another group does not touch it',
      () async {
        // Priya's private group expense; Mallory (only in Goa trip) learns
        // its id and writes an update for it inside Goa trip.
        final other = await priya.seedGroup(expenses: 1, name: 'Private');
        final target = priya.state.groups[other.g]!.expenses.values.single;
        await crossGroupUpdate(
          other,
          target.id,
          target.updatedHlc.millis + 60000,
        );
        final after = priya.state.groups[other.g]!.expenses[target.id];
        expect(after, isNotNull);
        expect(after!.description, target.description);
        expect(after.isDeleted, isFalse);
      },
    );

    test(
      'an earlier-stamped op for an expense id of another group cannot hide '
      'it from its own group',
      () async {
        final other = await priya.seedGroup(expenses: 1, name: 'Private');
        final target = priya.state.groups[other.g]!.expenses.values.single;
        await crossGroupUpdate(other, target.id, 1);
        final after = priya.state.groups[other.g]!.expenses[target.id];
        expect(
          after,
          isNotNull,
          reason: 'the Goa trip op took ownership of the Private expense',
        );
      },
    );
  });

  group('counters and forged authors', () {
    test('a gap in a third device counters is stored but never counted in '
        'the version vector', () async {
      final (evil, result) = await attack();
      await sendRawOps(evil, {
        'g': seed.g,
        'batch': 1,
        'total': 1,
        'ops': [expenseJson(counter: 7)],
        'more': false,
      });
      await errorFrom(evil);
      await evil.close();
      await result;
      final vv = await priya.ledger.versionVector(seed.g);
      expect(vv[mallory], 0);
      await expectStillSyncs();
    });

    test(
      'an op forged with this phone own device id and a huge counter cannot '
      'break the phone later ops',
      () async {
        final (evil, result) = await attack();
        // Max int64: the next local counter wraps to a negative number.
        await sendRawOps(evil, {
          'g': seed.g,
          'batch': 1,
          'total': 1,
          'ops': [
            expenseJson(
              id: 'forged-own',
              device: priya.deviceId,
              counter: 0x7FFFFFFFFFFFFFFF,
            ),
          ],
          'more': false,
        });
        final error = await errorFrom(evil);
        await evil.close();
        await result;
        // Expected: rejected; this phone is the only author of its id.
        expect(error?.code, ErrorCodes.badOp);
        // And in any case the phone must keep writing valid ops.
        await priya.addExpense(seed.g, payer: seed.b, owers: [seed.a, seed.b]);
        final mine = priya
            .opsOf(seed.g)
            .where((o) => o.deviceId == priya.deviceId)
            .toList();
        expect(
          mine.every((o) => o.counter >= 1),
          isTrue,
          reason: 'counters: ${mine.map((o) => o.counter).toList()}',
        );
        final (ri, rr) = await syncPair(priya, alex);
        expect(ri.isSuccess, isTrue, reason: ri.message);
        expect(rr.isSuccess, isTrue, reason: rr.message);
        // Today the wrapped (negative) counter is never above any version
        // vector, so the new expense silently never leaves this phone.
        expect(alex.canonical, priya.canonical);
      },
    );

    test(
      'an op forged with this phone own device id and a counter gap leaves '
      'every later local change unshared forever',
      () async {
        final (evil, result) = await attack();
        await sendRawOps(evil, {
          'g': seed.g,
          'batch': 1,
          'total': 1,
          'ops': [
            expenseJson(
              id: 'forged-gap',
              device: priya.deviceId,
              counter: 1000,
            ),
          ],
          'more': false,
        });
        await errorFrom(evil);
        await evil.close();
        await result;
        await priya.addExpense(seed.g, payer: seed.b, owers: [seed.a, seed.b]);
        final (ri, rr) = await syncPair(priya, alex);
        expect(ri.isSuccess && rr.isSuccess, isTrue);
        expect(priya.canonical, alex.canonical);
        // Alex holds everything Priya wrote, so nothing is unshared.
        expect(
          priya.snapshot.unsharedCounts,
          isEmpty,
          reason:
              'Priya next counter jumped past the forged 1000, so her '
              'contiguous version vector never covers her own ops',
        );
      },
    );
  });

  group('sizes', () {
    test(
      'a highly compressible 500 KB description is rejected (SPEC 5.16)',
      () async {
        final (evil, result) = await attack();
        await sendRawOps(evil, {
          'g': seed.g,
          'batch': 1,
          'total': 1,
          'ops': [
            expenseJson(
              id: 'huge',
              payloadOverride: {ExpenseFields.description: 'a' * 500000},
            ),
          ],
          'more': false,
        });
        final error = await errorFrom(evil);
        await evil.close();
        await result;
        expect(error?.code, ErrorCodes.badOp);
        expect(priya.opsOf(seed.g).where((o) => o.id == 'huge'), isEmpty);
      },
    );

    test(
      'many compressible ops cannot grow the op log without bound',
      () async {
        final (evil, result) = await attack();
        // 12 ops x 512 KB of notes: about 6 MB stored from one ~10 KB
        // frame (under the 8 MiB decompressed body limit).
        await sendRawOps(evil, {
          'g': seed.g,
          'batch': 1,
          'total': 12,
          'ops': [
            for (var i = 1; i <= 12; i++)
              expenseJson(
                id: 'fat-$i',
                counter: i,
                payloadOverride: {ExpenseFields.notes: 'z' * (1 << 19)},
              ),
          ],
          'more': false,
        });
        await errorFrom(evil);
        await evil.close();
        await result;
        final stored = priya.opsOf(seed.g).where((o) => o.deviceId == mallory);
        final bytes = stored.fold<int>(
          0,
          (n, o) => n + utf8.encode(jsonEncode(o.toJson())).length,
        );
        expect(bytes, lessThan(64 * 1024));
      },
    );

    test('deeply nested JSON in a payload is rejected and the session '
        'survives', () async {
      final (evil, result) = await attack();
      Object deep = 'x';
      for (var i = 0; i < 20000; i++) {
        deep = [deep];
      }
      await sendRawOps(evil, {
        'g': seed.g,
        'batch': 1,
        'total': 1,
        'ops': [
          expenseJson(id: 'deep', payloadOverride: {'extra': deep}),
        ],
        'more': false,
      });
      final error = await errorFrom(evil);
      await evil.close();
      final r = await result;
      // Either refused, or stored as an unknown field the reducer ignores;
      // never a crash.
      if (error != null) {
        expect(error.code, isIn([ErrorCodes.badOp, ErrorCodes.tooLarge]));
      } else {
        expect(r.failure, isNot(SyncFailure.internal));
      }
      await expectStillSyncs();
    });

    test('a gzip bomb in a sealed frame is refused as too large', () async {
      final (evil, result) = await attack();
      final bomb = utf8.encode(
        '{"g":"${seed.g}","batch":1,"total":1,"more":false,"ops":[],'
        '"pad":"${'0' * (9 << 20)}"}',
      );
      final gz = gzipEncode(bomb);
      expect(gz.length, lessThan(64 << 10));
      final plain = Uint8List(2 + gz.length)
        ..[0] = MessageType.ops.code
        ..[1] = kFlagGzip
        ..setRange(2, 2 + gz.length, gz);
      await evil.channel.send(await evil.keys!.cipher.seal(plain));
      final error = await errorFrom(evil);
      expect(error?.code, ErrorCodes.tooLarge);
      await result;
      await expectStillSyncs();
    });

    test(
      'a version vector with out of range counters is a bad frame',
      () async {
        final (evil, result) = await attack();
        final body = utf8.encode(
          jsonEncode({
            'g': seed.g,
            'vv': {alex.deviceId: -1},
          }),
        );
        final plain = Uint8List(2 + body.length)
          ..[0] = MessageType.vv.code
          ..setRange(2, 2 + body.length, body);
        await evil.channel.send(await evil.keys!.cipher.seal(plain));
        final e = await evil.until((m) => m is ErrorMessage);
        expect((e as ErrorMessage?)?.code, ErrorCodes.badFrame);
        await result;
        await expectStillSyncs();
      },
    );
  });

  group('time', () {
    test(
      'an op stamped far in the future cannot freeze a field forever',
      () async {
        final target = priya.state.groups[seed.g]!.expenses.values.first;
        final (evil, result) = await attack();
        await sendRawOps(evil, {
          'g': seed.g,
          'batch': 1,
          'total': 1,
          'ops': [
            {
              ...expenseJson(id: 'future', millis: 999999999999999),
              'kind': 'update',
              'entityId': target.id,
              'payload': {ExpenseFields.description: 'Frozen by Mallory'},
            },
          ],
          'more': false,
        });
        await errorFrom(evil);
        await evil.close();
        await result;
        // Priya (an honest member) fixes the description afterwards.
        await priya.rename(seed.g, target.id, 'Dinner, fixed');
        expect(
          priya.state.groups[seed.g]!.expenses[target.id]!.description,
          'Dinner, fixed',
        );
      },
    );
  });

  test('VV entries with an empty device id are refused', () async {
    expect(
      () => SyncMessage.fromJson(MessageType.vv, {
        'g': seed.g,
        'vv': {'': 3},
      }),
      throwsA(isA<ProtocolException>()),
    );
    expect(VersionVector.empty.entries, isEmpty);
  });

  // ------------------------------------------------- QA SECURITY round 2 --

  group('round 2: cross-group ownership', () {
    test('a create op in another group with an older HLC cannot take an '
        'expense away from its own group', () async {
      // SECURITY-R1-04 (reopened). The R1 fix prefers a group holding a create
      // op; Mallory simply sends a create (not an update) for the
      // Private expense id, stamped earlier than the real create.
      final other = await priya.seedGroup(expenses: 1, name: 'Private');
      final target = priya.state.groups[other.g]!.expenses.values.single;
      final (evil, result) = await attack();
      await sendRawOps(evil, {
        'g': seed.g,
        'batch': 1,
        'total': 1,
        'ops': [
          {
            ...expenseJson(id: 'steal-create', millis: 1),
            'kind': 'create',
            'entityId': target.id,
          },
        ],
        'more': false,
      });
      await errorFrom(evil);
      await evil.close();
      await result;
      expect(
        priya.state.groups[other.g]!.expenses[target.id],
        isNotNull,
        reason: 'a Goa trip create op took the Private expense away',
      );
    });

    test('a member create op in another group with an older HLC cannot take '
        'a member away from its own group', () async {
      final other = await priya.seedGroup(expenses: 0, name: 'Private');
      final target = priya.state.groups[other.g]!.members.values.firstWhere(
        (m) => m.displayName == 'Priya',
      );
      final memberOp = alex
          .opsOf(seed.g)
          .firstWhere((o) => o.entityType == EntityType.member);
      final (evil, result) = await attack();
      await sendRawOps(evil, {
        'g': seed.g,
        'batch': 1,
        'total': 1,
        'ops': [
          {
            ...memberOp.toJson(),
            'id': 'steal-member',
            'deviceId': mallory,
            'counter': 1,
            'hlc': Hlc(1, 0, mallory).encode(),
            'entityId': target.id,
          },
        ],
        'more': false,
      });
      await errorFrom(evil);
      await evil.close();
      await result;
      expect(
        priya.state.groups[other.g]!.members[target.id],
        isNotNull,
        reason: 'a Goa trip create op took the Private member away',
      );
    });
  });

  group('round 2: own counter and peer knowledge', () {
    test(
      'an op with this phone own device id at the next counter is refused',
      () async {
        final mine = priya
            .opsOf(seed.g)
            .where((o) => o.deviceId == priya.deviceId);
        final next = mine.isEmpty
            ? 1
            : mine.map((o) => o.counter).reduce((a, b) => a > b ? a : b) + 1;
        final (evil, result) = await attack();
        await sendRawOps(evil, {
          'g': seed.g,
          'batch': 1,
          'total': 1,
          'ops': [
            expenseJson(id: 'own-next', device: priya.deviceId, counter: next),
          ],
          'more': false,
        });
        expect((await errorFrom(evil))?.code, ErrorCodes.badOp);
        await evil.close();
        await result;
        await priya.addExpense(seed.g, payer: seed.b, owers: [seed.a, seed.b]);
        final (ri, rr) = await syncPair(priya, alex);
        expect(ri.isSuccess && rr.isSuccess, isTrue);
        expect(alex.canonical, priya.canonical);
        expect(priya.snapshot.unsharedCounts, isEmpty);
      },
    );

    test('a forged version vector claiming this phone ops cannot mark later '
        'local changes as shared', () async {
      // SECURITY-R2-01. Mallory's VV says she holds Priya's ops up to
      // 2^53-1. recordPeerKnowledge keeps it, so every op Priya writes
      // afterwards is shown as shared although no phone has it.
      final (evil, result) = await attack();
      await evil.sendSealed(
        VvMessage(
          groupId: seed.g,
          vv: VersionVector({priya.deviceId: (1 << 53) - 1}),
        ),
      );
      await evil.until((m) => m is OpsMessage || m is ErrorMessage);
      await evil.close();
      await result;
      await priya.addExpense(seed.g, payer: seed.b, owers: [seed.a, seed.b]);
      expect(
        priya.snapshot.unsharedCounts[seed.g],
        1,
        reason: 'the new expense reached no phone, yet it shows as shared',
      );
    }, skip: 'SECURITY-R2-01');
  });

  group('round 2: sizes', () {
    test('compressible padding in a field the schema does not know cannot '
        'store megabytes from one small frame', () async {
      // SECURITY-R1-02 (reopened). The per-field limits only cover
      // known text fields; any other payload key is bounded only by the
      // 32 Ki-unit op cap. 240 ops of ~32 KB each gzip to ~12 KB (fits
      // even a BLE frame) and store ~7.6 MB per batch, repeatable.
      final (evil, result) = await attack();
      await sendRawOps(evil, {
        'g': seed.g,
        'batch': 1,
        'total': 240,
        'ops': [
          for (var i = 1; i <= 240; i++)
            expenseJson(
              id: 'pad-$i',
              counter: i,
              payloadOverride: {'pad': 'z' * 30000},
            ),
        ],
        'more': false,
      });
      await errorFrom(evil);
      await evil.close();
      await result;
      final stored = priya.opsOf(seed.g).where((o) => o.deviceId == mallory);
      final bytes = stored.fold<int>(
        0,
        (n, o) => n + utf8.encode(jsonEncode(o.toJson())).length,
      );
      expect(
        bytes,
        lessThan(1 << 20),
        reason: '${stored.length} ops, $bytes bytes from one ~12 KB frame',
      );
    }, skip: 'SECURITY-R1-02');
  });

  group('round 2: remote text', () {
    Future<String?> remoteMemberName(String name) async {
      final memberOp = alex
          .opsOf(seed.g)
          .firstWhere((o) => o.entityType == EntityType.member);
      final (evil, result) = await attack();
      await sendRawOps(evil, {
        'g': seed.g,
        'batch': 1,
        'total': 1,
        'ops': [
          {
            ...memberOp.toJson(),
            'id': 'name-op',
            'deviceId': mallory,
            'counter': 1,
            'hlc': Hlc(kBaseMs + 9000, 0, mallory).encode(),
            'entityId': 'member-evil-1',
            'payload': {
              ...memberOp.payload,
              MemberFields.displayName: name,
              MemberFields.personId: 'person-evil-1',
            },
          },
        ],
        'more': false,
      });
      await errorFrom(evil);
      await evil.close();
      await result;
      return priya.state.groups[seed.g]!.members['member-evil-1']?.displayName;
    }

    const invisible = <String, String>{
      'zero width spaces': '\u200B\u200B',
      'BOM': '\uFEFF',
      'word joiner': '\u2060',
      'empty': '',
      'spaces only': '   ',
    };
    for (final MapEntry(key: what, value: name) in invisible.entries) {
      test('a remote member name of $what is refused', () async {
        // SECURITY-R1-06 (remote side): names that show nothing.
        final stored = await remoteMemberName(name);
        expect(
          stored,
          isNull,
          reason: 'stored invisible name ${stored?.runes.toList()}',
        );
      }, skip: 'SECURITY-R1-06');
    }

    test('a peer device name with bidi overrides is not shown or recorded '
        'verbatim', () async {
      // SECURITY-R2-04. HELLO deviceName (and the name in adverts and
      // connect links) is peer-controlled and only length-checked. It is
      // shown in the nearby list, the session screen and Sync history.
      final spoof = await TestPhone.create('c', deviceName: 'Alex\u202E5000 diap');
      addTearDown(spoof.close);
      await spoof.ledger.registerJoinedGroup(
        seed.g,
        await alex.keyOf(seed.g),
        'Goa trip',
      );
      final (ri, rr) = await syncPair(spoof, priya);
      expect(ri.isSuccess && rr.isSuccess, isTrue);
      bool bidi(String v) => v.runes.any(
        (r) => (r >= 0x202A && r <= 0x202E) || (r >= 0x2066 && r <= 0x2069),
      );
      expect(
        bidi(rr.peerName),
        isFalse,
        reason: rr.peerName.runes.toList().toString(),
      );
      final records = await priya.records();
      expect(records.any((r) => bidi(r.peerName)), isFalse);
    }, skip: 'SECURITY-R2-04');

    test('a remote member name with an RLO is refused', () async {
      expect(await remoteMemberName('Bob\u202E5000 diap'), isNull);
    });
  });
}
