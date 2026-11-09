// QA DATA-R1: forked devices (same device + counter, different op id) and
// the group key store across restarts.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/secure_group_key_store.dart';
import 'package:sqlite3/sqlite3.dart';

import 'qa_data_harness.dart';

const DeviceId peerB = 'bbbbbbbb-0000-7000-8000-0000000000b1';

Operation rename(GroupId g, DeviceId d, int counter, MemberId m, String name,
        {String? id, int dt = 1000}) =>
    Operation(
      id: id ?? '$d/$counter',
      groupId: g,
      deviceId: d,
      counter: counter,
      hlc: Hlc(kQaBaseMs + dt + counter, 0, d),
      entityType: EntityType.member,
      entityId: m,
      kind: OpKind.update,
      payload: {MemberFields.displayName: name},
    );

void main() {
  late FilePhone a;
  late Trip t;

  setUp(() async {
    resetKeystore();
    a = FilePhone(qaTempDir());
    await a.launch();
    await a.settings
        .completeOnboarding(displayName: 'Alex', homeCurrency: 'INR');
    t = await qaTrip(a);
  });

  tearDown(() async {
    try {
      await a.close();
    } catch (_) {}
    a.dir.deleteSync(recursive: true);
  });

  group('forked device', () {
    test('a later op with the same (device, counter) and another id is '
        'ignored; the first is kept, also after restart', () async {
      final first = rename(t.g, peerB, 1, t.sam, 'Sam first', id: 'x');
      final fork =
          rename(t.g, peerB, 1, t.sam, 'Sam fork', id: 'y', dt: 999999);
      expect(await a.ledger.applyRemote(t.g, [first]), [first]);
      expect(await a.ledger.applyRemote(t.g, [fork]), isEmpty);
      expect(a.group(t.g).members[t.sam]!.displayName, 'Sam first');
      expect(a.snap.ops.map((o) => o.id), isNot(contains('y')));
      await a.restart();
      expect(a.group(t.g).members[t.sam]!.displayName, 'Sam first');
      expect(a.snap.ops.map((o) => o.id), isNot(contains('y')));
      expect(await a.ledger.versionVector(t.g),
          VersionVector({a.deviceId: 4, peerB: 1}));
    });

    test('two forks inside one batch: the first in batch order wins',
        () async {
      final x = rename(t.g, peerB, 1, t.sam, 'X', id: 'x');
      final y = rename(t.g, peerB, 1, t.sam, 'Y', id: 'y', dt: 5000);
      expect(await a.ledger.applyRemote(t.g, [x, y]), [x]);
      expect(a.group(t.g).members[t.sam]!.displayName, 'X');
    });

    test('a fork of MY OWN counter relayed by a peer (cloned phone) does '
        'not replace my op or move my counter', () async {
      final mine = a.mineIn(t.g);
      final clone = rename(t.g, a.deviceId, 3, t.sam, 'Clone',
          id: 'clone-3', dt: 999999);
      expect(await a.ledger.applyRemote(t.g, [clone]), isEmpty);
      expect(a.mineIn(t.g).map((o) => o.id), mine.map((o) => o.id));
      await a.ledger.renameMember(t.g, t.priya, 'P');
      expect(a.mineIn(t.g).last.counter, 5);
      await a.restart();
      expect(a.mineIn(t.g).map((o) => o.counter), [1, 2, 3, 4, 5]);
    });

    test('the forked op is never relayed to other peers', () async {
      await a.ledger.applyRemote(t.g, [rename(t.g, peerB, 1, t.sam, 'A', id: 'x')]);
      await a.ledger.applyRemote(t.g, [rename(t.g, peerB, 1, t.sam, 'B', id: 'y')]);
      final out = await a.ledger.opsMissingFor(t.g, VersionVector.empty);
      expect(out.map((o) => o.id), contains('x'));
      expect(out.map((o) => o.id), isNot(contains('y')));
    });
  });

  group('group keys', () {
    test('keys survive a restart and are served to sync byte for byte',
        () async {
      final t2 = await qaTrip(a, name: 'Flat');
      final before = await a.ledger.groupKeys();
      expect(before.keys, containsAll([t.g, t2.g]));
      expect(before.values.every((k) => k.length == kGroupKeyLength), isTrue);
      await a.restart();
      final after = await a.ledger.groupKeys();
      expect(after.keys.toSet(), before.keys.toSet());
      for (final g in before.keys) {
        expect(after[g], before[g]);
      }
      // A brand-new key store instance on the same keystore sees them too.
      final fresh = await SecureGroupKeyStore().all();
      expect(fresh.keys, containsAll([t.g, t2.g]));
    });

    test('joined-group key and name hint survive restart; the pending join '
        'clears once the create op arrives', () async {
      const joined = '00000000-0000-7000-9000-00000000j01n';
      final key = Uint8List.fromList(List.generate(32, (i) => i));
      expect(await a.ledger.registerJoinedGroup(joined, key, ' Cabin '), isTrue);
      await a.restart();
      expect(a.snap.pendingJoins, {joined: 'Cabin'});
      final create = Operation(
        id: 'create-cabin',
        groupId: joined,
        deviceId: peerB,
        counter: 1,
        hlc: Hlc(kQaBaseMs + 5000, 0, peerB),
        entityType: EntityType.group,
        entityId: joined,
        kind: OpKind.create,
        payload: {
          GroupFields.name: 'Cabin',
          GroupFields.type: 'trip',
          GroupFields.currency: 'INR',
          GroupFields.simplifyDebts: true,
          GroupFields.createdAt: kQaBaseMs,
        },
      );
      await a.ledger.applyRemote(joined, [create]);
      expect(a.snap.pendingJoins, isEmpty);
      await a.restart();
      expect(a.snap.pendingJoins, isEmpty);
      expect(a.snap.state.groups[joined]!.group!.name, 'Cabin');
      final db = sqlite3.open(a.path);
      addTearDown(db.close);
      expect(
          db.select("SELECT * FROM kv WHERE key LIKE 'pending.%'"), isEmpty);
    });

    test('missing key for a group that has ops: the group still opens and '
        'is usable locally; remote ops for it are refused', () async {
      await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
      await a.close();
      resetKeystore(); // keystore wiped (e.g. keystore reset by the OS)
      await a.launch();
      expect(a.group(t.g).liveExpenses, hasLength(1));
      expect(await a.ledger.groupKeys(), isEmpty);
      expect(a.snap.pendingJoins, isEmpty);
      await a.ledger.addExpense(qaDraft(t.g, [t.me]));
      expect(a.group(t.g).liveExpenses, hasLength(2));
      await expectLater(
          a.ledger.applyRemote(t.g, [rename(t.g, peerB, 1, t.sam, 'S')]),
          throwsFormatException);
    });

    test('missing key: re-joining by invite restores sync for the group '
        'without a pending row', () async {
      await a.close();
      resetKeystore();
      await a.launch();
      final key = Uint8List.fromList(List.filled(32, 9));
      expect(await a.ledger.registerJoinedGroup(t.g, key, 'Goa'), isFalse);
      expect((await a.ledger.groupKeys())[t.g], key);
      expect(a.snap.pendingJoins, isEmpty);
      expect(await a.ledger.applyRemote(t.g, [rename(t.g, peerB, 1, t.sam, 'S')]),
          hasLength(1));
    });

    test('malformed key value in the keystore is ignored, others load',
        () async {
      final good = await a.ledger.groupKeys();
      await a.close();
      resetKeystore({
        for (final e in good.entries) 'gk.${e.key}': base64Url.encode(e.value),
        'gk.broken-group': 'not base64 !!',
        'gk.short-group': base64Url.encode([1, 2, 3]),
      });
      await a.launch();
      expect((await a.ledger.groupKeys()).keys.toSet(), good.keys.toSet());
    });

    test(
      'an orphaned key with no ops and no pending hint (app killed between '
      'keystore write and op commit) is not shown as a nameless pending join',
      skip: 'QA DATA-R1-08: Ledger._load turns every key without a group '
          'create op into pendingJoins[g] = "" (hint ?? ""), so a half-'
          'created group shows forever as an untitled "Waiting for first '
          'sync" row',
      () async {
        await a.close();
        final keys = await SecureGroupKeyStore().all();
        resetKeystore({
          for (final e in keys.entries) 'gk.${e.key}': base64Url.encode(e.value),
          'gk.00000000-0000-7000-9000-0000000ghost':
              base64Url.encode(List.filled(32, 1)),
        });
        await a.launch();
        expect(a.snap.pendingJoins, isEmpty,
            reason: 'ghost row: ${a.snap.pendingJoins}');
      },
    );
  });
}
