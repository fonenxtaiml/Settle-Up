// Regression tests for the round-1 data fixes: text rules, member cap,
// remote op checks, keystore loss, device and profile recovery.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/schema.dart';
import 'package:settle_up/data/secure_group_key_store.dart';
import 'package:settle_up/data/text_rules.dart';

import 'helpers.dart';

final class _Phone {
  _Phone(this.store, this.keys, this.settings, this.ledger, this.clock);

  final MemoryOpStore store;
  final GroupKeyStore keys;
  KvSettingsRepository settings;
  Ledger ledger;
  final FakeClock clock;
  int _launch = 0;

  static Future<_Phone> create({GroupKeyStore? keys}) async {
    final store = MemoryOpStore();
    await store.open();
    final settings = await KvSettingsRepository.open(store,
        defaultDeviceName: 'Pixel', ids: SequentialIdGenerator(1 << 40));
    await settings.completeOnboarding(displayName: 'Alex', homeCurrency: 'INR');
    final k = keys ?? MemoryGroupKeyStore();
    final clock = FakeClock();
    final ledger = await Ledger.open(
        store: store,
        keys: k,
        settings: settings,
        ids: SequentialIdGenerator((1 << 40) + 0x1000),
        nowMillis: clock.call);
    return _Phone(store, k, settings, ledger, clock);
  }

  Future<void> restart() async {
    _launch++;
    await ledger.close();
    await settings.close();
    settings = await KvSettingsRepository.open(store,
        defaultDeviceName: 'Pixel',
        ids: SequentialIdGenerator((2 + _launch) << 40));
    ledger = await Ledger.open(
        store: store,
        keys: keys,
        settings: settings,
        ids: SequentialIdGenerator(((2 + _launch) << 40) + 0x1000),
        nowMillis: clock.call);
  }

  DeviceId get deviceId => settings.device.deviceId;
}

Matcher _invalid(LedgerInputIssue? issue) => throwsA(isA<LedgerException>()
    .having((e) => e.code, 'code', LedgerErrorCode.invalidInput)
    .having((e) => e.issue, 'issue', issue));

Future<GroupId> _trip(_Phone p, {List<String> others = const ['Sam']}) =>
    p.ledger.createGroup(NewGroup(
      name: 'Goa trip',
      type: GroupType.trip,
      currency: 'INR',
      newMemberNames: others,
    ));

Operation _remoteRename(GroupId g, String member, int counter,
        {DeviceId device = dB, int? millis, String name = 'S'}) =>
    Operation(
      id: 'r-$device-$counter',
      groupId: g,
      deviceId: device,
      counter: counter,
      hlc: Hlc(millis ?? kBaseMs + counter, 0, device),
      entityType: EntityType.member,
      entityId: member,
      kind: OpKind.update,
      payload: {MemberFields.displayName: name},
    );

void main() {
  group('TextRules.clean', () {
    test('drops bidi, control and zero-width characters, keeps joiners',
        () {
      expect(TextRules.clean('Bob\u202E5000 diap'), 'Bob5000 diap');
      expect(TextRules.clean('\u2066Al\u2069ex\u200F'), 'Alex');
      expect(TextRules.clean('Al\u0000e\u0007x\u00AD'), 'Alex\u00AD');
      expect(TextRules.clean('\u200B\u200B'), '');
      // Family emoji and a Devanagari conjunct keep their ZWJ.
      const family = '\u{1F468}\u200D\u{1F469}\u200D\u{1F467}';
      expect(TextRules.clean(family), family);
      expect(TextRules.clean('\u0915\u094D\u200D\u0937'),
          '\u0915\u094D\u200D\u0937');
    });

    test('line breaks become spaces in one-line fields, stay in notes', () {
      expect(TextRules.clean(' Al\nex\t'), 'Al ex');
      expect(TextRules.clean('a\r\nb\rc\td', multiline: true), 'a\nb\nc\td');
    });

    test('isBlank sees through joiners and variation selectors', () {
      expect(TextRules.isBlank('\u200D\uFE0F '), isTrue);
      expect(TextRules.isBlank('A'), isFalse);
    });

    test('tooLong counts characters, with a code-unit cap per character', () {
      const flag = '\u{1F1EE}\u{1F1F3}'; // one character, 4 code units
      expect(TextRules.tooLong(flag * 40, 40), isNull);
      expect(TextRules.tooLong(flag * 41, 40), isNotNull);
      // One "character" made of 200 combining marks.
      expect(TextRules.tooLong('a${'\u0301' * 200}', 40), isNotNull);
    });
  });

  group('Ledger limits (SPEC 5.16)', () {
    late _Phone p;
    setUp(() async => p = await _Phone.create());
    tearDown(() => p.ledger.close());

    test('createGroup with more than 49 others is refused as groupFull',
        () async {
      await expectLater(
          _trip(p, others: [for (var i = 0; i < 50; i++) 'P$i']),
          _invalid(LedgerInputIssue.groupFull));
      final g = await _trip(p, others: [for (var i = 0; i < 49; i++) 'P$i']);
      expect(p.ledger.current.state.groups[g]!.activeMembers, hasLength(50));
      await expectLater(p.ledger.addMember(g, displayName: 'One more'),
          _invalid(LedgerInputIssue.groupFull));
    });

    test('a removed member frees a place', () async {
      final g = await _trip(p, others: [for (var i = 0; i < 49; i++) 'P$i']);
      final gs = p.ledger.current.state.groups[g]!;
      final victim = gs.activeMembers.firstWhere((m) => m.displayName == 'P3');
      await p.ledger.removeMember(g, victim.id);
      await p.ledger.addMember(g, displayName: 'New');
      expect(p.ledger.current.state.groups[g]!.activeMembers, hasLength(50));
    });

    test('over-long text carries the tooLong issue', () async {
      final g = await _trip(p);
      await expectLater(p.ledger.addMember(g, displayName: 'm' * 41),
          _invalid(LedgerInputIssue.tooLong));
    });

    test('a profile name saved before the limit is shortened in the '
        'member op instead of blocking new groups', () async {
      await p.store.setKv(
          KvKeys.profile,
          jsonEncode({
            'personId': p.settings.profile!.personId,
            'displayName': 'n' * 45,
            'homeCurrency': 'INR',
          }));
      await p.restart();
      final g = await _trip(p);
      final names = p.ledger.current.state.groups[g]!.members.values
          .map((m) => m.displayName);
      expect(names, contains('n' * 40));
    });
  });

  group('remote ops', () {
    late _Phone p;
    late GroupId g;
    late String sam;
    setUp(() async {
      p = await _Phone.create();
      g = await _trip(p);
      sam = p.ledger.current.state.groups[g]!.members.values
          .firstWhere((m) => m.displayName == 'Sam')
          .id;
    });
    tearDown(() => p.ledger.close());

    test('names over the limit or with bidi controls are rejected', () async {
      for (final name in ['x' * 161, 'Bob\u202Eevil', 'A\u0000B']) {
        await expectLater(
            p.ledger.applyRemote(g, [_remoteRename(g, sam, 1, name: name)]),
            throwsFormatException,
            reason: name);
      }
      // Tabs and line breaks from a peer are data, not an attack.
      expect(
          await p.ledger
              .applyRemote(g, [_remoteRename(g, sam, 1, name: 'S\tam')]),
          hasLength(1));
    });

    test('an op stamped beyond the forward window is held back, then lands '
        'once the clock catches up', () async {
      final far = kBaseMs + Ledger.maxRemoteAheadMs + 60000;
      final op = _remoteRename(g, sam, 1, millis: far, name: 'Future');
      expect(await p.ledger.applyRemote(g, [op]), isEmpty);
      expect(p.ledger.clockSkewDetected, isTrue);
      expect((await p.ledger.versionVector(g))[dB], 0,
          reason: 'not stored, so the peer offers it again');
      p.clock.now = far;
      expect(await p.ledger.applyRemote(g, [op]), hasLength(1));
    });

    test('an op with my device id and a counter I never used is rejected; '
        'one I hold is a harmless duplicate', () async {
      final mine = p.ledger.current.ops.where((o) => o.deviceId == p.deviceId);
      await expectLater(
          p.ledger.applyRemote(
              g, [_remoteRename(g, sam, mine.length + 1, device: p.deviceId)]),
          throwsFormatException);
      expect(await p.ledger.applyRemote(g, [mine.last]), isEmpty);
      await p.ledger.renameMember(g, sam, 'Sammy');
      final counters = [
        for (final o in p.ledger.current.ops)
          if (o.deviceId == p.deviceId) o.counter
      ];
      expect(counters, List.generate(counters.length, (i) => i + 1));
    });

    test('purgeGroup remembers the removed counters', () async {
      await p.ledger.close();
      await p.store.purgeGroup(g);
      final mark = jsonDecode((await p.store.getKv(KvKeys.purged(g)))!) as Map;
      expect(mark[p.deviceId], 3);
      await p.restart();
      expect(p.ledger.current.pendingJoins, {g: ''},
          reason: 'a purged group with its key is waiting to be re-received');
    });
  });

  group('keys', () {
    test('a visible group without a key is listed in groupsWithoutKey',
        () async {
      final keys = MemoryGroupKeyStore();
      final p = await _Phone.create(keys: keys);
      addTearDown(() => p.ledger.close());
      final g = await _trip(p);
      expect(p.ledger.current.groupsWithoutKey, isEmpty);
      await keys.remove(g);
      await p.restart();
      expect(p.ledger.current.groupsWithoutKey, {g});
      await p.ledger.registerJoinedGroup(
          g, Uint8List.fromList(List.filled(32, 7)), 'Goa trip');
      expect(p.ledger.current.groupsWithoutKey, isEmpty);
    });

    test('a failed keystore write in createGroup is storageFailed and '
        'leaves nothing behind', () async {
      final keys = _FailingKeys();
      final p = await _Phone.create(keys: keys);
      addTearDown(() => p.ledger.close());
      keys.failPut = true;
      await expectLater(
          _trip(p),
          throwsA(isA<LedgerException>().having(
              (e) => e.code, 'code', LedgerErrorCode.storageFailed)));
      expect(p.ledger.current.ops, isEmpty);
    });

    test('a failed keystore write in registerJoinedGroup leaves no hint',
        () async {
      final keys = _FailingKeys();
      final p = await _Phone.create(keys: keys);
      addTearDown(() => p.ledger.close());
      keys.failPut = true;
      await expectLater(
          p.ledger.registerJoinedGroup(
              gA, Uint8List.fromList(List.filled(32, 1)), 'Goa'),
          throwsA(anything));
      expect(await p.store.getKv(KvKeys.pending(gA)), isNull);
      expect(p.ledger.current.pendingJoins, isEmpty);
    });

    test('one unreadable entry does not hide the other keys', () async {
      final keys = _FailingKeys();
      final p = await _Phone.create(keys: keys);
      addTearDown(() => p.ledger.close());
      final g = await _trip(p);
      keys.failAll = true;
      await p.restart();
      expect((await p.ledger.groupKeys()).keys, [g]);
    });

    test('the platform store does not wipe every key on a read error', () {
      expect(SecureGroupKeyStore.android.toMap()['resetOnError'], 'false');
    });
  });

  group('settings recovery', () {
    test('an unreadable device row keeps the id from hlc.last and the old '
        'device name when it is still readable', () async {
      final p = await _Phone.create();
      addTearDown(() => p.ledger.close());
      await _trip(p);
      final id = p.deviceId;
      await p.store.setKv(KvKeys.device,
          jsonEncode({'deviceId': 5, 'deviceName': "Alex's Pixel"}));
      await p.restart();
      expect(p.deviceId, id);
      expect(p.settings.device.deviceName, "Alex's Pixel");
    });

    test('a missing device row on a phone with ops keeps its id', () async {
      final p = await _Phone.create();
      addTearDown(() => p.ledger.close());
      await _trip(p);
      final id = p.deviceId;
      await p.store.setKv(KvKeys.device, null);
      await p.restart();
      expect(p.deviceId, id);
    });

    test('without hlc.last a corrupt device row gets a new id', () async {
      final store = MemoryOpStore();
      await store.open();
      await store.setKv(KvKeys.device, '{oops');
      final s = await KvSettingsRepository.open(store,
          defaultDeviceName: 'Pixel', ids: SequentialIdGenerator(9));
      expect(s.device.deviceId, isNotEmpty);
      expect(s.device.deviceName, 'Pixel');
    });

    test('a fresh install still mints a personId', () async {
      final store = MemoryOpStore();
      await store.open();
      final s = await KvSettingsRepository.open(store,
          defaultDeviceName: 'Pixel', ids: SequentialIdGenerator(9));
      final profile =
          await s.completeOnboarding(displayName: 'Alex', homeCurrency: 'INR');
      expect(profile.personId, isNotEmpty);
    });
  });
}

final class _FailingKeys implements GroupKeyStore {
  final MemoryGroupKeyStore _inner = MemoryGroupKeyStore();
  bool failPut = false;
  bool failAll = false;

  @override
  Future<Map<GroupId, Uint8List>> all() async {
    if (failAll) throw StateError('keystore says no');
    return _inner.all();
  }

  @override
  Future<Uint8List?> keyFor(GroupId groupId) => _inner.keyFor(groupId);

  @override
  Future<void> put(GroupId groupId, Uint8List key) async {
    if (failPut) throw StateError('keystore says no');
    return _inner.put(groupId, key);
  }

  @override
  Future<void> remove(GroupId groupId) => _inner.remove(groupId);
}
