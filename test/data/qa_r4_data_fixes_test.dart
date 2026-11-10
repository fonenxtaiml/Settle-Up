// Regression tests for the round-4 data fixes: a failed cut of forged peer
// knowledge at open is retried before new edits are stored (DATA-R4-01),
// peer dates are held to a window every phone can show in local time
// (SECURITY-R4-01) and peer currency codes to the ISO shape the Ledger
// writes (SECURITY-R4-02).
import 'dart:io';

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
import 'package:settle_up/data/text_rules.dart';

import 'helpers.dart';

/// A store whose capPeerKnowledge fails while [capFails] is set.
final class _CapFailStore implements OpStore {
  _CapFailStore(this.inner);

  final OpStore inner;
  bool capFails = true;
  int capCalls = 0;
  int inserts = 0;

  @override
  Future<bool> capPeerKnowledge(GroupId g, DeviceId d, int max) async {
    capCalls++;
    if (capFails) {
      throw const FileSystemException('database or disk is full');
    }
    return inner.capPeerKnowledge(g, d, max);
  }

  @override
  Future<List<Operation>> insertAll(List<Operation> ops) {
    inserts++;
    return inner.insertAll(ops);
  }

  @override
  Future<void> setKv(String key, String? value) => inner.setKv(key, value);
  @override
  Future<void> recordPeerKnowledge(
          DeviceId peer, GroupId groupId, VersionVector vv) =>
      inner.recordPeerKnowledge(peer, groupId, vv);
  @override
  Future<void> addSyncRecord(SyncRecord record) => inner.addSyncRecord(record);
  @override
  Future<void> purgeGroup(GroupId groupId) => inner.purgeGroup(groupId);
  @override
  Future<void> open() => inner.open();
  @override
  Future<void> close() async {}
  @override
  Future<List<Operation>> loadAll() => inner.loadAll();
  @override
  Future<VersionVector> versionVector(GroupId groupId) =>
      inner.versionVector(groupId);
  @override
  Future<List<Operation>> missingFor(GroupId groupId, VersionVector peer) =>
      inner.missingFor(groupId, peer);
  @override
  Future<int> maxCounter(GroupId groupId, DeviceId deviceId) =>
      inner.maxCounter(groupId, deviceId);
  @override
  Future<VersionVector> peerKnowledge(GroupId groupId) =>
      inner.peerKnowledge(groupId);
  @override
  Future<String?> getKv(String key) => inner.getKv(key);
  @override
  Future<List<SyncRecord>> syncRecords({int limit = 50}) =>
      inner.syncRecords(limit: limit);
}

final class _Phone {
  _Phone(this.store, this.keys, this.settings, this.ledger);

  final MemoryOpStore store;
  final MemoryGroupKeyStore keys;
  KvSettingsRepository settings;
  Ledger ledger;
  int _launch = 0;

  static Future<_Phone> create() async {
    final store = MemoryOpStore();
    await store.open();
    final settings = await KvSettingsRepository.open(store,
        defaultDeviceName: 'Pixel', ids: SequentialIdGenerator(1 << 40));
    await settings.completeOnboarding(displayName: 'Alex', homeCurrency: 'INR');
    final keys = MemoryGroupKeyStore();
    final ledger = await Ledger.open(
        store: store,
        keys: keys,
        settings: settings,
        ids: SequentialIdGenerator((1 << 40) + 0x1000),
        nowMillis: () => kBaseMs);
    return _Phone(store, keys, settings, ledger);
  }

  /// Relaunches on [store] (default: the plain memory store).
  Future<void> restart([OpStore? via]) async {
    _launch++;
    await ledger.close();
    await settings.close();
    final base = (1 + 16 * _launch) << 40;
    settings = await KvSettingsRepository.open(store,
        defaultDeviceName: 'Pixel', ids: SequentialIdGenerator(base));
    ledger = await Ledger.open(
        store: via ?? store,
        keys: keys,
        settings: settings,
        ids: SequentialIdGenerator(base + 0x1000),
        nowMillis: () => kBaseMs);
  }

  DeviceId get deviceId => settings.device.deviceId;
  LedgerSnapshot get snap => ledger.current;
  List<MemberId> members(GroupId g) =>
      snap.state.groups[g]!.members.keys.toList();
  int written(GroupId g) =>
      snap.ops.where((o) => o.groupId == g && o.deviceId == deviceId).length;
}

Future<GroupId> _trip(_Phone p, {String name = 'Goa trip'}) =>
    p.ledger.createGroup(NewGroup(
      name: name,
      type: GroupType.trip,
      currency: 'INR',
      newMemberNames: const ['Sam'],
    ));

ExpenseDraft _dinner(GroupId g, List<MemberId> ms,
        {DateTime? date, String currency = 'INR'}) =>
    ExpenseDraft(
      groupId: g,
      description: 'Dinner',
      total: 1200,
      currency: currency,
      paidBy: SplitSpec.single(ms.first, 1200),
      owedBy: SplitSpec.equal(ms),
      category: 'food',
      date: date ?? utcFromMillis(kBaseMs),
    );

Operation _op(EntityType type, Map<String, Object?> payload) => Operation(
      id: 'peer-op',
      groupId: gA,
      deviceId: dB,
      counter: 1,
      hlc: Hlc(kBaseMs, 0, dB),
      entityType: type,
      entityId: type == EntityType.group ? gA : 'entity-1',
      kind: OpKind.update,
      payload: payload,
    );

Map<String, Object?> _money({String currency = 'INR'}) => {
      'total': 300,
      'currency': currency,
      'paidBy': {
        'method': 'exact',
        'values': {'m1': 300},
      },
      'owedBy': {
        'method': 'equal',
        'values': {'m1': 1, 'm2': 1},
      },
      'paid': {'m1': 300},
      'owed': {'m1': 150, 'm2': 150},
    };

void main() {
  group('a failed cut at open is retried (DATA-R4-01)', () {
    late _Phone p;
    late GroupId g;

    /// Plants a forged report of all my ops while the app is closed, then
    /// opens on a store whose cut fails.
    Future<_CapFailStore> openWithFailingCut() async {
      await p.ledger.close();
      await p.store.recordPeerKnowledge(
          dB, g, VersionVector({p.deviceId: TextRules.maxCounter}));
      final s = _CapFailStore(p.store);
      await p.restart(s);
      expect(s.capCalls, 1);
      return s;
    }

    setUp(() async {
      p = await _Phone.create();
      g = await _trip(p);
    });
    tearDown(() => p.ledger.close());

    test('the cut is retried before the next edit of that group', () async {
      final written = p.written(g);
      final s = await openWithFailingCut();
      s.capFails = false;
      await p.ledger.addExpense(_dinner(g, p.members(g)));
      expect(s.capCalls, 2);
      expect((await p.store.peerKnowledge(g))[p.deviceId], written,
          reason: 'cut to what I had written before the edit');
      expect(p.snap.unsharedCounts[g], 1);
      await p.restart();
      expect(p.snap.unsharedCounts[g], 1);
      // Done once: later edits do not try again.
      await p.ledger.addExpense(_dinner(g, p.members(g)));
      expect(s.capCalls, 2);
    });

    test('while the cut still fails the edit is refused and nothing is '
        'stored', () async {
      final s = await openWithFailingCut();
      final ops = p.snap.ops.length;
      await expectLater(
          p.ledger.addExpense(_dinner(g, p.members(g))),
          throwsA(isA<LedgerException>().having(
              (e) => e.code, 'code', LedgerErrorCode.storageFailed)));
      expect(s.inserts, 0);
      expect(p.snap.ops.length, ops);
      // The counter was not used up: the next edit after the disk frees
      // up takes the next number.
      s.capFails = false;
      await p.ledger.addExpense(_dinner(g, p.members(g)));
      final mine = p.snap.ops
          .where((o) => o.groupId == g && o.deviceId == p.deviceId)
          .map((o) => o.counter)
          .toList();
      expect(mine, List.generate(mine.length, (i) => i + 1));
      await p.restart();
      expect(p.snap.unsharedCounts[g], 1);
      expect(p.snap.totalUnshared, 1);
    });

    test('an edit of another group is not held up', () async {
      final other = await _trip(p, name: 'Flat');
      final s = await openWithFailingCut();
      await p.ledger.addExpense(_dinner(other, p.members(other)));
      expect(s.capCalls, 1, reason: 'only the uncut group retries');
      expect(p.snap.unsharedCounts[other], isNotNull);
    });

    test('a peer report retries the cut, so an honest report counts',
        () async {
      final written = p.written(g);
      final s = await openWithFailingCut();
      s.capFails = false;
      await p.ledger
          .recordPeerKnowledge(dB, g, VersionVector({p.deviceId: written}));
      expect(s.capCalls, 2);
      expect((await p.store.peerKnowledge(g))[p.deviceId], written);
      await p.ledger.addExpense(_dinner(g, p.members(g)));
      expect(s.capCalls, 2);
      await p.restart();
      expect(p.snap.unsharedCounts[g], 1);
    });

    test('a peer report is still stored while the cut fails', () async {
      final s = await openWithFailingCut();
      await p.ledger
          .recordPeerKnowledge(dC, g, VersionVector({p.deviceId: 1}));
      expect((await p.store.peerKnowledge(g))[p.deviceId],
          TextRules.maxCounter);
      expect(s.capCalls, 2);
    });
  });

  group('peer dates every phone can show (SECURITY-R4-01)', () {
    test('the window is 1900-01-01 to the end of 9999 in UTC', () {
      expect(TextRules.minModelDateMs,
          DateTime.utc(1900).millisecondsSinceEpoch);
      expect(TextRules.maxModelDateMs,
          DateTime.utc(10000).millisecondsSinceEpoch - 1);
      // Every date in the window has a local calendar day, a month start
      // and a year start in any offset from -12 h to +14 h.
      for (final ms in [TextRules.minModelDateMs, TextRules.maxModelDateMs]) {
        for (final h in [-12, 14]) {
          final t = DateTime.fromMillisecondsSinceEpoch(ms + h * 3600000,
              isUtc: true);
          expect(DateTime(t.year).year, t.year);
          expect(DateTime(t.year, t.month, t.day + 1).isAfter(t), isTrue);
        }
      }
    });

    test('every date field keeps to the window', () {
      final fields = <EntityType, List<String>>{
        EntityType.group: [GroupFields.createdAt, GroupFields.deletedAt],
        EntityType.member: [MemberFields.createdAt, MemberFields.deletedAt],
        EntityType.expense: [
          ExpenseFields.date,
          ExpenseFields.createdAt,
          ExpenseFields.deletedAt,
        ],
      };
      for (final MapEntry(key: type, value: keys) in fields.entries) {
        for (final key in keys) {
          for (final ok in [
            TextRules.minModelDateMs,
            0,
            kBaseMs,
            TextRules.maxModelDateMs,
          ]) {
            expect(TextRules.remoteProblem(_op(type, {key: ok})), isNull,
                reason: '$type.$key = $ok');
          }
          for (final bad in [
            TextRules.minModelDateMs - 1,
            TextRules.maxModelDateMs + 1,
            -TextRules.maxDateMs,
            -TextRules.maxDateMs + 14 * 3600000,
            TextRules.maxDateMs,
          ]) {
            expect(TextRules.remoteProblem(_op(type, {key: bad})), isNotNull,
                reason: '$type.$key = $bad');
          }
        }
      }
      expect(
          TextRules.remoteProblem(
              _op(EntityType.expense, {ExpenseFields.deletedAt: null})),
          isNull);
    });

    test('the Ledger refuses a local date peers would refuse', () async {
      final p = await _Phone.create();
      addTearDown(p.ledger.close);
      final g = await _trip(p);
      final ms = p.members(g);
      for (final date in [
        DateTime.utc(1899, 12, 31, 23, 59),
        DateTime.utc(10000),
        utcFromMillis(-TextRules.maxDateMs),
      ]) {
        await expectLater(
            p.ledger.addExpense(_dinner(g, ms, date: date)),
            throwsA(isA<LedgerException>().having(
                (e) => e.code, 'code', LedgerErrorCode.invalidInput)),
            reason: '$date');
        await expectLater(
            p.ledger.recordPayment(PaymentDraft(
                groupId: g,
                from: ms[1],
                to: ms[0],
                amount: 100,
                currency: 'INR',
                method: PaymentMethod.cash,
                date: date)),
            throwsA(isA<LedgerException>().having(
                (e) => e.code, 'code', LedgerErrorCode.invalidInput)),
            reason: '$date');
      }
      final id = await p.ledger
          .addExpense(_dinner(g, ms, date: DateTime.utc(1900)));
      await p.ledger.updateExpense(
          id, _dinner(g, ms, date: DateTime.utc(9999, 12, 31, 23, 59)));
      for (final op in p.snap.ops) {
        expect(TextRules.remoteProblem(op), isNull, reason: op.id);
      }
    });
  });

  group('peer currency codes (SECURITY-R4-02)', () {
    test('a group currency must be three upper-case letters', () {
      for (final ok in ['INR', 'EUR', 'XAU']) {
        expect(
            TextRules.remoteProblem(
                _op(EntityType.group, {GroupFields.currency: ok})),
            isNull,
            reason: ok);
      }
      for (final bad in ['inr', 'Inr', 'EURO', 'EU', 'Q' * 64, 'E1R', 'ÉUR',
          'ＩＮＲ', ' INR', '', 3]) {
        expect(
            TextRules.remoteProblem(
                _op(EntityType.group, {GroupFields.currency: bad})),
            isNotNull,
            reason: '$bad');
      }
    });

    test('a money block currency must be three upper-case letters', () {
      expect(
          TextRules.remoteProblem(
              _op(EntityType.expense, {ExpenseFields.money: _money()})),
          isNull);
      for (final bad in ['inr', 'EURO', 'Q' * 64, 'IN']) {
        expect(
            TextRules.remoteProblem(_op(EntityType.expense,
                {ExpenseFields.money: _money(currency: bad)})),
            isNotNull,
            reason: bad);
      }
    });

    test('the Ledger still takes a lower-case code and writes it upper case',
        () async {
      final p = await _Phone.create();
      addTearDown(p.ledger.close);
      final g = await _trip(p);
      final id = await p.ledger
          .addExpense(_dinner(g, p.members(g), currency: ' eur '));
      await p.ledger.updateGroup(g, const GroupPatch(currency: 'usd'));
      expect(p.snap.state.groups[g]!.expenses[id]!.money.currency, 'EUR');
      expect(p.snap.state.groups[g]!.group!.currency, 'USD');
      for (final op in p.snap.ops) {
        expect(TextRules.remoteProblem(op), isNull, reason: op.id);
      }
    });
  });
}
