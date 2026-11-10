// Regression tests for the round-2 data fixes: remote payload bounds
// (SECURITY-R1-02), invisible names (SECURITY-R1-06), forged peer
// knowledge (SECURITY-R2-01) and secure storage recovery (SECURITY-R2-02).
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/secure_group_key_store.dart';
import 'package:settle_up/data/text_rules.dart';

import 'helpers.dart';

final class _Phone {
  _Phone(this.store, this.keys, this.settings, this.ledger, this.seed);

  final MemoryOpStore store;
  final GroupKeyStore keys;
  KvSettingsRepository settings;
  Ledger ledger;
  final int seed;
  int _launch = 0;

  static Future<_Phone> create({int seed = 1, String name = 'Alex'}) async {
    final store = MemoryOpStore();
    await store.open();
    final settings = await KvSettingsRepository.open(store,
        defaultDeviceName: 'Pixel', ids: SequentialIdGenerator(seed << 40));
    await settings.completeOnboarding(displayName: name, homeCurrency: 'INR');
    final keys = MemoryGroupKeyStore();
    final ledger = await Ledger.open(
        store: store,
        keys: keys,
        settings: settings,
        ids: SequentialIdGenerator((seed << 40) + 0x1000),
        nowMillis: () => kBaseMs);
    return _Phone(store, keys, settings, ledger, seed);
  }

  Future<void> restart() async {
    _launch++;
    await ledger.close();
    await settings.close();
    final base = (seed + 16 * _launch) << 40;
    settings = await KvSettingsRepository.open(store,
        defaultDeviceName: 'Pixel', ids: SequentialIdGenerator(base));
    ledger = await Ledger.open(
        store: store,
        keys: keys,
        settings: settings,
        ids: SequentialIdGenerator(base + 0x1000),
        nowMillis: () => kBaseMs);
  }

  DeviceId get deviceId => settings.device.deviceId;
  LedgerSnapshot get snap => ledger.current;
}

Future<GroupId> _trip(_Phone p, {List<String> others = const ['Sam']}) =>
    p.ledger.createGroup(NewGroup(
      name: 'Goa trip',
      type: GroupType.trip,
      currency: 'INR',
      newMemberNames: others,
    ));

/// A peer's op in [g] with [payload]; ids follow the counter.
Operation _peerOp(
  GroupId g,
  int counter, {
  EntityType type = EntityType.member,
  String entityId = 'member-peer',
  OpKind kind = OpKind.update,
  required Map<String, Object?> payload,
}) =>
    Operation(
      id: 'peer-op-$counter',
      groupId: g,
      deviceId: dB,
      counter: counter,
      hlc: Hlc(kBaseMs + counter, 0, dB),
      entityType: type,
      entityId: entityId,
      kind: kind,
      payload: payload,
    );

void main() {
  group('remote payload bounds (SECURITY-R1-02)', () {
    late _Phone p;
    late GroupId g;
    setUp(() async {
      p = await _Phone.create();
      g = await _trip(p);
    });
    tearDown(() => p.ledger.close());

    test('the largest op this app writes is accepted by a peer', () async {
      const flag = '\u{1F1EE}\u{1F1F3}'; // one character, 4 code units
      final a = await _Phone.create(seed: 2, name: flag * 40);
      addTearDown(a.ledger.close);
      final big = await a.ledger.createGroup(NewGroup(
        name: flag * 60,
        type: GroupType.trip,
        currency: 'INR',
        newMemberNames: [for (var i = 0; i < 49; i++) flag * 40],
      ));
      final members = a.snap.state.groups[big]!.members.keys.toList();
      final shares = {
        for (var i = 0; i < members.length; i++) members[i]: 99999999 - i,
      };
      await a.ledger.addExpense(ExpenseDraft(
        groupId: big,
        description: flag * 120,
        total: 999999999,
        currency: 'INR',
        paidBy: SplitSpec(SplitMethod.shares, shares),
        owedBy: SplitSpec(SplitMethod.shares, shares),
        category: 'general',
        date: utcFromMillis(kBaseMs),
        notes: flag * 1000,
      ));
      await a.ledger.recordPayment(PaymentDraft(
        groupId: big,
        from: members[1],
        to: members[0],
        amount: 100,
        currency: 'INR',
        method: PaymentMethod.cash,
        date: utcFromMillis(kBaseMs),
        notes: flag * 1000,
      ));
      final ops = a.snap.ops;
      final largest =
          ops.map((o) => jsonEncode(o.toJson()).length).reduce((x, y) {
        return x > y ? x : y;
      });
      expect(largest, greaterThan(14000));
      expect(largest, lessThanOrEqualTo(TextRules.maxRemoteOpUnits));
      await p.ledger.registerJoinedGroup(
          big, (await a.ledger.groupKeys())[big]!, 'Big');
      expect(await p.ledger.applyRemote(big, ops), hasLength(ops.length));
    });

    test('an unknown field within the budget is kept (SPEC 7.6)', () async {
      final op = _peerOp(g, 1,
          payload: {MemberFields.displayName: 'Sam', 'nickname': 's' * 200});
      expect(await p.ledger.applyRemote(g, [op]), hasLength(1));
      final stored = p.snap.ops.firstWhere((o) => o.id == op.id);
      expect(stored.payload['nickname'], 's' * 200);
    });

    test('unknown fields over the budget are refused', () async {
      final op = _peerOp(g, 1, payload: {
        MemberFields.displayName: 'Sam',
        'a': 'x' * 600,
        'b': 'y' * 600,
      });
      await expectLater(p.ledger.applyRemote(g, [op]), throwsFormatException);
      expect(p.snap.ops.where((o) => o.deviceId == dB), isEmpty);
    });

    test('a known non-text field cannot carry a long string', () async {
      final bad = [
        _peerOp(g, 1,
            type: EntityType.group,
            entityId: g,
            payload: {GroupFields.currency: 'z' * 65}),
        _peerOp(g, 1, payload: {MemberFields.personId: 'p' * 5000}),
        _peerOp(g, 1,
            type: EntityType.expense,
            entityId: 'e1',
            payload: {
              ExpenseFields.money: {
                'paid': {'m' * 200: 1},
              },
            }),
        _peerOp(g, 1,
            type: EntityType.expense,
            entityId: 'e1',
            payload: {
              ExpenseFields.money: {
                'paid': {
                  'a': {
                    'b': {
                      'c': {'d': 1},
                    },
                  },
                },
              },
            }),
      ];
      for (final op in bad) {
        await expectLater(p.ledger.applyRemote(g, [op]), throwsFormatException,
            reason: '${op.payload.keys}');
      }
    });

    test('an op over the per-op cap is refused', () async {
      final ids = [
        for (var i = 0; i < 400; i++)
          '00000000-0000-7000-8000-${i.toString().padLeft(12, '0')}',
      ];
      final op = _peerOp(g, 1,
          type: EntityType.expense,
          entityId: 'e1',
          payload: {
            ExpenseFields.money: {
              'paid': {for (final m in ids) m: 1},
              'owed': {for (final m in ids) m: 1},
            },
          });
      expect(jsonEncode(op.toJson()).length,
          greaterThan(TextRules.maxRemoteOpUnits));
      await expectLater(p.ledger.applyRemote(g, [op]), throwsFormatException);
    });

    test('a batch over the batch cap is refused as a whole', () async {
      const flag = '\u{1F1EE}\u{1F1F3}';
      final ops = [
        for (var i = 1; i <= 300; i++)
          _peerOp(g, i,
              type: EntityType.expense,
              entityId: 'e$i',
              payload: {
                ExpenseFields.description: flag * 120,
                ExpenseFields.notes: flag * 1000,
              }),
      ];
      final total =
          ops.fold<int>(0, (n, o) => n + jsonEncode(o.toJson()).length);
      expect(total, greaterThan(TextRules.maxRemoteBatchUnits));
      await expectLater(p.ledger.applyRemote(g, ops), throwsFormatException);
      expect(p.snap.ops.where((o) => o.deviceId == dB), isEmpty);
      // The same ops in honest-sized batches land.
      expect(await p.ledger.applyRemote(g, ops.sublist(0, 150)), hasLength(150));
      expect(await p.ledger.applyRemote(g, ops.sublist(150)), hasLength(150));
    });
  });

  group('invisible names (SECURITY-R1-06)', () {
    test('isBlank sees the fillers and format characters', () {
      for (final v in [
        'ㅤ',
        'ᅟᅠ',
        'ﾠ',
        '⠀',
        '­',
        '͏',
        '⁢',
        '᠎',
        '\u{E0041}',
        '​ ﻿⁠',
        '',
      ]) {
        expect(TextRules.isBlank(v), isTrue, reason: '${v.runes.toList()}');
      }
      for (final v in [
        'A',
        'ㅤA',
        '\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}',
        '가',
        'क्‍ष',
      ]) {
        expect(TextRules.isBlank(v), isFalse, reason: '${v.runes.toList()}');
      }
    });

    test('a peer cannot blank a member or group name; an empty payment '
        'description is fine', () async {
      final p = await _Phone.create();
      addTearDown(p.ledger.close);
      final g = await _trip(p);
      for (final name in ['', '  ', '​', 'ㅤ']) {
        await expectLater(
            p.ledger.applyRemote(
                g, [_peerOp(g, 1, payload: {MemberFields.displayName: name})]),
            throwsFormatException,
            reason: name.runes.toList().toString());
        await expectLater(
            p.ledger.applyRemote(g, [
              _peerOp(g, 1,
                  type: EntityType.group,
                  entityId: g,
                  payload: {GroupFields.name: name}),
            ]),
            throwsFormatException);
      }
      expect(
          await p.ledger.applyRemote(g, [
            _peerOp(g, 1,
                type: EntityType.expense,
                entityId: 'pay-1',
                payload: {ExpenseFields.description: ''}),
          ]),
          hasLength(1));
    });
  });

  group('peer knowledge of my own ops (SECURITY-R2-01)', () {
    late _Phone p;
    late GroupId g;
    setUp(() async {
      p = await _Phone.create();
      g = await _trip(p);
    });
    tearDown(() => p.ledger.close());

    int mine() => p.snap.ops.where((o) => o.deviceId == p.deviceId).length;

    test('an honest report still marks my ops as shared', () async {
      expect(p.snap.unsharedCounts[g], mine());
      await p.ledger
          .recordPeerKnowledge(dB, g, VersionVector({p.deviceId: mine()}));
      expect(p.snap.unsharedCounts[g], isNull);
    });

    test('a report above what I wrote is clamped and stays clamped after a '
        'restart', () async {
      await p.ledger.recordPeerKnowledge(
          dB, g, VersionVector({p.deviceId: TextRules.maxCounter, dC: 7}));
      expect(p.snap.unsharedCounts[g], isNull);
      expect((await p.store.peerKnowledge(g))[p.deviceId], mine());
      expect((await p.store.peerKnowledge(g))[dC], 7,
          reason: 'other devices are recorded as reported');
      await p.ledger.renameMember(
          g, p.snap.state.groups[g]!.members.keys.last, 'Sammy');
      expect(p.snap.unsharedCounts[g], 1);
      await p.restart();
      expect(p.snap.unsharedCounts[g], 1);
    });

    test('a forged row already stored does not hide changes made after '
        'the open', () async {
      await p.ledger.close();
      await p.store.recordPeerKnowledge(
          dB, g, VersionVector({p.deviceId: TextRules.maxCounter}));
      await p.restart();
      expect(p.snap.unsharedCounts[g], isNull);
      await p.ledger.renameMember(
          g, p.snap.state.groups[g]!.members.keys.last, 'Sammy');
      expect(p.snap.unsharedCounts[g], 1);
    });
  });

  group('secure storage recovery (SECURITY-R2-02)', () {
    final k1 = Uint8List.fromList(List.filled(32, 1));
    final k2 = Uint8List.fromList(List.filled(32, 2));

    test('a reset writes back the keys this session still holds', () async {
      final storage = _Storage();
      final store = SecureGroupKeyStore(storage);
      await store.put('g1', k1);
      storage.lostKey = true;
      await store.put('g2', k2);
      expect(storage.resets, 1);
      expect(await store.keyFor('g1'), k1);
      expect(await store.keyFor('g2'), k2);
    });

    test('other write errors are reported and erase nothing', () async {
      final storage = _Storage();
      final store = SecureGroupKeyStore(storage);
      await store.put('g1', k1);
      storage.writeError = PlatformException(
          code: 'Exception encountered', message: 'No space left on device');
      await expectLater(store.put('g2', k2), throwsA(isA<PlatformException>()));
      expect(storage.resets, 0);
      storage.writeError = null;
      expect(await store.keyFor('g1'), k1);
    });

    test('a key mismatch that clears on retry does not reset', () async {
      final storage = _Storage()..mismatchOnce = true;
      final store = SecureGroupKeyStore(storage);
      await store.put('g1', k1);
      expect(storage.resets, 0);
      expect(await store.keyFor('g1'), k1);
    });

    test('the plugin version whose error text isLostWrappingKey matches '
        'is the one in use', () {
      // Upgrading flutter_secure_storage: re-check handleKeyMismatch's
      // messages in FlutterSecureStorage.java, then update this pin.
      final lock = File('pubspec.lock').readAsStringSync();
      final entry = RegExp(r'\n  flutter_secure_storage:\n(?:    .*\n)*?'
              r'    version: "([^"]+)"')
          .firstMatch(lock);
      expect(entry?.group(1), '11.2.0');
      expect(
          SecureGroupKeyStore.isLostWrappingKey(PlatformException(
              code: 'Exception encountered',
              message: 'Key mismatch after algorithm change (Bad padding, '
                  'wrong key for cipher algorithm). Enable '
                  'migrateOnAlgorithmChange=true to preserve data, or '
                  'resetOnError=true to delete.')),
          isTrue);
      expect(
          SecureGroupKeyStore.isLostWrappingKey(
              PlatformException(code: 'Exception encountered', message: 'x')),
          isFalse);
    });
  });
}

/// flutter_secure_storage with the 11.2.0 behaviour after a lost wrapping
/// key: every call fails unless made with resetOnError, which wipes all.
final class _Storage implements FlutterSecureStorage {
  final Map<String, String> data = {};
  bool lostKey = false;
  bool mismatchOnce = false;
  PlatformException? writeError;
  int resets = 0;

  static PlatformException get _mismatch => PlatformException(
      code: 'Exception encountered',
      message: 'Key mismatch after algorithm change (Bad padding, wrong key '
          'for cipher algorithm). Enable migrateOnAlgorithmChange=true to '
          'preserve data, or resetOnError=true to delete.');

  void _init(AndroidOptions? a) {
    if (mismatchOnce) {
      mismatchOnce = false;
      throw _mismatch;
    }
    if (!lostKey) return;
    if (a?.toMap()['resetOnError'] == 'true') {
      data.clear();
      lostKey = false;
      resets++;
      return;
    }
    throw _mismatch;
  }

  @override
  Future<String?> read({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _init(aOptions);
    return data[key];
  }

  @override
  Future<Map<String, String>> readAll({
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _init(aOptions);
    return Map.of(data);
  }

  @override
  Future<void> write({
    required String key,
    required String? value,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _init(aOptions);
    if (writeError != null) throw writeError!;
    if (value == null) {
      data.remove(key);
    } else {
      data[key] = value;
    }
  }

  @override
  Future<void> delete({
    required String key,
    AppleOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    AppleOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    _init(aOptions);
    data.remove(key);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
