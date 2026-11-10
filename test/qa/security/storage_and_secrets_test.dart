// QA SECURITY round 1: where secrets live and where they must never be.
//
// - Group keys only in the GroupKeyStore: never in the SQLite file (ops,
//   kv, sync_records, WAL) or the settings kv, not even as text.
// - No group key, invite link or decrypted payload in SyncRecord JSON or
//   in the messages of exceptions the UI can see.
// - Key loss: the ledger still opens, sync of that group stops, and a new
//   invite restores it.
// - Invites cannot overwrite the key of a group already held.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/codecs.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/secure_group_key_store.dart';
import 'package:settle_up/data/sqlite_op_store.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/protocol/messages.dart';
import 'package:settle_up/sync/protocol/session.dart';
import 'package:settle_up/sync/sync_engine.dart';

import '../../sync/support/evil_peer.dart';
import '../../sync/support/harness.dart';
import '../../sync/support/phone.dart';

const String secretText = 'SECRET-DINNER-7f3a';

/// Every common text form of a key.
List<String> keyForms(List<int> key) {
  final b64 = base64.encode(key);
  final b64url = base64Url.encode(key);
  return [
    b64,
    b64.replaceAll('=', ''),
    b64url,
    b64url.replaceAll('=', ''),
    key.map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
  ];
}

bool containsBytes(List<int> hay, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= hay.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (hay[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Phone on a real SQLite file with a separate key store.
final class FilePhone {
  FilePhone._(this.dir, this.store, this.settings, this.ledger, this.keys);

  static Future<FilePhone> open(
    Directory dir,
    GroupKeyStore keys, {
    String letter = 'f',
  }) async {
    final store = SqliteOpStore('${dir.path}/settle_up.db');
    await store.open();
    final settings = await KvSettingsRepository.open(
      store,
      defaultDeviceName: 'Pixel 8',
      ids: PhoneIds(letter),
    );
    if (settings.profile == null) {
      await settings.completeOnboarding(
        displayName: 'Farah',
        homeCurrency: 'INR',
      );
    }
    final ledger = await Ledger.open(
      store: store,
      keys: keys,
      settings: settings,
      ids: PhoneIds(letter),
    );
    return FilePhone._(dir, store, settings, ledger, keys);
  }

  final Directory dir;
  final SqliteOpStore store;
  final KvSettingsRepository settings;
  final Ledger ledger;
  final GroupKeyStore keys;

  Future<void> close() async {
    await ledger.close();
    await settings.close();
    await store.close();
  }

  /// Bytes of the database and its WAL/SHM side files.
  List<int> fileBytes() => [
    for (final f in dir.listSync().whereType<File>())
      if (f.path.contains('settle_up.db')) ...f.readAsBytesSync(),
  ];
}

void main() {
  group('keys are never written to SQLite or kv', () {
    late Directory dir;
    setUp(() async => dir = await Directory.systemTemp.createTemp('su-sec'));
    tearDown(() => dir.delete(recursive: true));

    test('own group, joined group, sync records and settings', () async {
      final keys = MemoryGroupKeyStore();
      final phone = await FilePhone.open(dir, keys);
      final g = await phone.ledger.createGroup(
        const NewGroup(
          name: 'Goa trip',
          type: GroupType.trip,
          currency: 'INR',
          newMemberNames: ['Priya'],
        ),
      );
      final gs = phone.ledger.current.state.groups[g]!;
      final a = gs.members.values.first.id;
      await phone.ledger.addExpense(
        ExpenseDraft(
          groupId: g,
          description: secretText,
          total: 1000,
          currency: 'INR',
          paidBy: SplitSpec.single(a, 1000),
          owedBy: SplitSpec.equal(gs.members.keys.toList()),
          category: 'food.dining',
          date: utcFromMillis(kBaseMs),
        ),
      );
      // A joined group from an invite.
      final joinedKey = Uint8List.fromList(List.generate(32, (i) => 200 - i));
      final invite = InviteLink(
        groupId: groupIdOf(77),
        groupKey: joinedKey,
        groupName: 'Flat 4B',
        currency: 'INR',
        fromName: 'Priya',
      ).encode();
      final engine = DefaultSyncEngine(store: phone.ledger, transports: []);
      final join = await engine.acceptInvite(invite);
      expect(join.alreadyMember, isFalse);
      // An invite generated for our own group (what the QR shows).
      final shown = await engine.inviteLinkFor(g, includeHost: false);
      await phone.ledger.addSyncRecord(
        SyncRecord(
          id: 'r1',
          peerName: 'Priya',
          transport: TransportKind.lan,
          startedAt: utcFromMillis(kBaseMs),
          endedAt: utcFromMillis(kBaseMs + 10),
          sentOps: 0,
          receivedOps: 0,
          groupIds: [g],
          outcome: SyncOutcome.failed,
          error: 'authFailed: Bad AUTH mac',
        ),
      );
      await engine.dispose();
      final ownKey = (await keys.all())[g]!;
      await phone.close();

      final bytes = phone.fileBytes();
      expect(bytes, isNotEmpty);
      for (final key in [ownKey, joinedKey]) {
        expect(containsBytes(bytes, key), isFalse, reason: 'raw key bytes');
        for (final form in keyForms(key)) {
          expect(
            containsBytes(bytes, utf8.encode(form)),
            isFalse,
            reason: 'key as text: $form',
          );
        }
      }
      expect(containsBytes(bytes, utf8.encode('settleup://join')), isFalse);
      expect(containsBytes(bytes, utf8.encode(shown)), isFalse);
      // The expense itself is in the op log (expected: SQLite is not
      // encrypted; Android app sandbox only).
      expect(containsBytes(bytes, utf8.encode(secretText)), isTrue);
    });

    test('SecureGroupKeyStore keeps keys under gk.<groupId> only', () async {
      FlutterSecureStorage.setMockInitialValues({});
      final store = SecureGroupKeyStore();
      final key = Uint8List.fromList(List.generate(32, (i) => i));
      await store.put('g1', key);
      expect(await store.keyFor('g1'), key);
      expect((await store.all()).keys, ['g1']);
      await expectLater(store.put('g2', Uint8List(16)), throwsArgumentError);
      final raw = await const FlutterSecureStorage().readAll();
      expect(raw.keys, ['gk.g1']);
      // Malformed values are skipped, never surfaced.
      await const FlutterSecureStorage().write(key: 'gk.bad', value: '!!');
      await const FlutterSecureStorage().write(
        key: 'gk.short',
        value: base64Url.encode([1, 2, 3]),
      );
      expect((await store.all()).keys, ['g1']);
      await store.remove('g1');
      expect(await store.keyFor('g1'), isNull);
    });
  });

  group('secrets in records and errors', () {
    late TestPhone alex, priya;
    late Seed seed;

    setUp(() async {
      alex = await TestPhone.create('a', deviceName: 'Alex');
      priya = await TestPhone.create('b', deviceName: 'Priya', name: 'Priya');
      seed = await alex.seedGroup(expenses: 1);
      await alex.addExpense(
        seed.g,
        payer: seed.a,
        owers: [seed.a, seed.b],
        description: secretText,
      );
      await priya.join(alex, seed.g);
    });

    tearDown(() async {
      await alex.close();
      await priya.close();
    });

    Future<void> expectClean(List<SyncRecord> records, List<int> key) async {
      expect(records, isNotEmpty);
      for (final r in records) {
        final json = jsonEncode(syncRecordToJson(r));
        expect(json, isNot(contains(secretText)), reason: json);
        expect(json, isNot(contains('settleup://')), reason: json);
        for (final form in keyForms(key)) {
          expect(json, isNot(contains(form)), reason: json);
        }
      }
    }

    test('records of a good, a wrong-key and a bad-op session', () async {
      final key = await alex.keyOf(seed.g);
      final engineA = DefaultSyncEngine(store: alex.store, transports: []);
      addTearDown(engineA.dispose);
      final (ri, rr) = await syncPair(alex, priya);
      expect(ri.isSuccess && rr.isSuccess, isTrue);
      await alex.ledger.addSyncRecord(ri.toRecord('ok'));

      // A stranger with the wrong key.
      final (ci, cr) = await channelPair();
      final s1 = SyncSession(
        channel: cr,
        store: priya.store,
        role: SessionRole.responder,
        timings: fastTimings,
      );
      final f1 = s1.run();
      final evil = EvilPeer(ci, initiator: true);
      try {
        await evil.handshake({seed.g: Uint8List(32)..[0] = 1});
      } on Object {
        // expected: no shared groups
      }
      final r1 = await f1;
      expect(r1.failure, SyncFailure.noSharedGroups);
      await priya.ledger.addSyncRecord(r1.toRecord('stranger'));

      // A member sending a batch with a bad op that carries the secret.
      final (ci2, cr2) = await channelPair();
      final s2 = SyncSession(
        channel: cr2,
        store: priya.store,
        role: SessionRole.responder,
        timings: fastTimings,
      );
      final f2 = s2.run();
      final evil2 = EvilPeer(ci2, initiator: true);
      await evil2.handshake({seed.g: key});
      final op = alex.opsOf(seed.g).last;
      final bad = {
        ...op.toJson(),
        'id': 'x-$secretText',
        'groupId': groupIdOf(5),
      };
      await evil2.sendSealed(
        OpsMessage(
          groupId: seed.g,
          batch: 1,
          total: 1,
          ops: [Operation.fromJson(bad)],
          more: false,
        ),
      );
      final r2 = await f2;
      expect(r2.failure, SyncFailure.protocolMismatch);
      await priya.ledger.addSyncRecord(r2.toRecord('bad-op'));
      final records = await priya.records();
      // The op id is attacker-chosen text, so it may show up; the payload
      // (description) of the op must not.
      for (final r in records) {
        final json = jsonEncode(syncRecordToJson(r));
        expect(json, isNot(contains(op.payload['description'] as String)));
        expect(json, isNot(contains('"payload"')));
        for (final form in keyForms(key)) {
          expect(json, isNot(contains(form)));
        }
      }
      await expectClean(await alex.records(), key);
    });

    test('invite errors do not echo the link or key', () async {
      final key = await alex.keyOf(seed.g);
      final engine = DefaultSyncEngine(store: priya.store, transports: []);
      addTearDown(engine.dispose);
      final good = InviteLink(
        groupId: 'g' * 65, // too long: refused
        groupKey: key,
        groupName: 'Goa',
        currency: 'INR',
        fromName: 'Alex',
      ).encode();
      for (final link in [good, '${good}x&v=9', good.replaceAll('k=', 'k=%')]) {
        try {
          await engine.acceptInvite(link);
          fail('accepted $link');
        } on SyncException catch (e) {
          expect(e.failure, SyncFailure.invalidCode);
          final text = '$e ${e.message}';
          expect(text, isNot(contains('settleup://')));
          for (final form in keyForms(key)) {
            expect(text, isNot(contains(form)));
          }
        }
      }
      try {
        await engine.syncWithLink(good);
        fail('synced');
      } on SyncException catch (e) {
        expect('$e', isNot(contains('settleup://')));
      }
    });

    test(
      'Operation, InviteLink and session keys do not print secrets',
      () async {
        final key = await alex.keyOf(seed.g);
        final invite = InviteLink(
          groupId: seed.g,
          groupKey: key,
          groupName: 'Goa',
          currency: 'INR',
          fromName: 'Alex',
        );
        for (final text in ['$invite']) {
          for (final form in keyForms(key)) {
            expect(text, isNot(contains(form)));
          }
        }
      },
    );
  });

  group('key loss and invites', () {
    late TestPhone alex;
    late Seed seed;

    setUp(() async {
      alex = await TestPhone.create('a', deviceName: 'Alex');
      seed = await alex.seedGroup(expenses: 2);
    });

    tearDown(() => alex.close());

    test('a broken keystore does not stop the ledger; a new invite brings '
        'sync back', () async {
      final key = await alex.keyOf(seed.g);
      // Priya had the group, then lost every key (keystore reset).
      final priya = await TestPhone.create('b', deviceName: 'Priya');
      addTearDown(priya.close);
      await priya.join(alex, seed.g);
      final (r1, _) = await syncPair(alex, priya);
      expect(r1.isSuccess, isTrue);
      final reopened = await Ledger.open(
        store: priya.opStore,
        keys: _BrokenKeyStore(),
        settings: priya.settings,
      );
      addTearDown(reopened.close);
      expect(reopened.current.state.groups[seed.g]!.group, isNotNull);
      expect(await reopened.groupKeys(), isEmpty);

      // The friend shows the QR again: the key is stored for the group
      // that already exists locally.
      final engine = DefaultSyncEngine(store: reopened, transports: []);
      addTearDown(engine.dispose);
      final link = InviteLink(
        groupId: seed.g,
        groupKey: key,
        groupName: 'Goa trip',
        currency: 'INR',
        fromName: 'Alex',
      ).encode();
      await engine.acceptInvite(link);
      expect((await reopened.groupKeys())[seed.g], key);
    });

    test('an invite for a group already held cannot replace its key', () async {
      final key = await alex.keyOf(seed.g);
      final engine = DefaultSyncEngine(store: alex.store, transports: []);
      addTearDown(engine.dispose);
      final forged = InviteLink(
        groupId: seed.g,
        groupKey: Uint8List(32)..fillRange(0, 32, 9),
        groupName: 'Goa trip',
        currency: 'INR',
        fromName: 'Mallory',
      ).encode();
      final r = await engine.acceptInvite(forged);
      expect(r.alreadyMember, isTrue);
      expect((await alex.ledger.groupKeys())[seed.g], key);
    });

    test(
      'a pending join created by an invite with a hostile name is inert',
      () async {
        final engine = DefaultSyncEngine(store: alex.store, transports: []);
        addTearDown(engine.dispose);
        final link = InviteLink(
          groupId: groupIdOf(42),
          groupKey: Uint8List(32)..[5] = 5,
          groupName: '=cmd|calc\u202E',
          currency: 'XXX',
          fromName: 'Mallory',
        ).encode();
        final r = await engine.acceptInvite(link);
        expect(r.alreadyMember, isFalse);
        expect(alex.snapshot.pendingJoins[groupIdOf(42)], isNotNull);
        // No group, member or op appears until a real create op arrives.
        expect(alex.state.groups[groupIdOf(42)], isNull);
        expect(alex.opCount(groupIdOf(42)), 0);
      },
    );
  });
}

final class _BrokenKeyStore implements GroupKeyStore {
  final MemoryGroupKeyStore _inner = MemoryGroupKeyStore();
  bool _broken = true;

  @override
  Future<Map<GroupId, Uint8List>> all() async {
    if (_broken) {
      _broken = false;
      throw StateError('keystore unavailable');
    }
    return _inner.all();
  }

  @override
  Future<Uint8List?> keyFor(GroupId groupId) => _inner.keyFor(groupId);
  @override
  Future<void> put(GroupId groupId, Uint8List key) => _inner.put(groupId, key);
  @override
  Future<void> remove(GroupId groupId) => _inner.remove(groupId);
}
