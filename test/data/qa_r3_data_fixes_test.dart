// Regression tests for the round-3 data fixes: field types in peer ops
// (SECURITY-R3-01), default-ignorable names (SECURITY-R3-02) and forged
// peer knowledge already on disk (DATA-R3-01).
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

final class _Phone {
  _Phone(this.store, this.keys, this.settings, this.ledger, this.seed);

  final MemoryOpStore store;
  final MemoryGroupKeyStore keys;
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
  List<MemberId> members(GroupId g) =>
      snap.state.groups[g]!.members.keys.toList();
}

Future<GroupId> _trip(_Phone p) => p.ledger.createGroup(const NewGroup(
      name: 'Goa trip',
      type: GroupType.trip,
      currency: 'INR',
      emoji: '\u{1F334}',
      newMemberNames: ['Sam', 'Priya'],
    ));

ExpenseDraft _dinner(GroupId g, List<MemberId> ms, {int total = 1200}) =>
    ExpenseDraft(
      groupId: g,
      description: 'Dinner',
      total: total,
      currency: 'INR',
      paidBy: SplitSpec.single(ms.first, total),
      owedBy: SplitSpec.equal(ms),
      category: 'food',
      date: utcFromMillis(kBaseMs),
      notes: 'Beach shack',
    );

Operation _op(
  EntityType type,
  Map<String, Object?> payload, {
  OpKind kind = OpKind.update,
  int schemaVersion = kSchemaVersion,
}) =>
    Operation(
      id: 'peer-op',
      groupId: gA,
      deviceId: dB,
      counter: 1,
      hlc: Hlc(kBaseMs, 0, dB),
      entityType: type,
      entityId: type == EntityType.group ? gA : 'entity-1',
      kind: kind,
      payload: payload,
      schemaVersion: schemaVersion,
    );

Map<String, Object?> _money() => {
      'total': 300,
      'currency': 'INR',
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
  group('field types in peer ops (SECURITY-R3-01)', () {
    test('every op an honest phone writes passes the remote check', () async {
      final p = await _Phone.create();
      addTearDown(p.ledger.close);
      final g = await _trip(p);
      final ms = p.members(g);
      await p.ledger.updateGroup(
          g,
          const GroupPatch(
              name: 'Goa 2026',
              type: GroupType.home,
              currency: 'EUR',
              emoji: '',
              simplifyDebts: false,
              archived: true));
      await p.ledger.updateGroup(g, const GroupPatch(archived: false));
      await p.ledger.renameMember(g, ms[1], 'Sammy');
      final extra = await p.ledger.addMember(g, displayName: 'Ravi');
      await p.ledger.mergeMembers(g, from: extra, into: ms[2]);
      await p.ledger.claimMember(g, ms[1]);
      await p.ledger.claimMember(g, ms[0]);
      final e = await p.ledger.addExpense(_dinner(g, ms));
      await p.ledger.updateExpense(e, _dinner(g, ms, total: 1500));
      await p.ledger.deleteExpense(e, groupId: g);
      await p.ledger.restoreExpense(e, groupId: g);
      final pay = await p.ledger.recordPayment(PaymentDraft(
          groupId: g,
          from: ms[1],
          to: ms[0],
          amount: 500,
          currency: 'INR',
          method: PaymentMethod.upi,
          date: utcFromMillis(kBaseMs)));
      await p.ledger.updatePayment(
          pay,
          PaymentDraft(
              groupId: g,
              from: ms[1],
              to: ms[0],
              amount: 400,
              currency: 'INR',
              method: PaymentMethod.cash,
              date: utcFromMillis(kBaseMs)));
      await p.ledger.removeMember(g, ms[2]);
      await p.ledger.deleteGroup(g);

      final ops = p.snap.ops.where((o) => o.groupId == g).toList();
      expect(ops.length, greaterThan(15));
      for (final op in ops) {
        expect(TextRules.remoteProblem(op), isNull, reason: '$op');
      }
      // And a second phone stores all of them.
      final b = await _Phone.create(seed: 2, name: 'Sam');
      addTearDown(b.ledger.close);
      await b.ledger.registerJoinedGroup(g, (await p.keys.keyFor(g))!, 'Goa');
      expect(await b.ledger.applyRemote(g, ops), hasLength(ops.length));
    });

    test('the nulls the schema allows pass', () {
      for (final op in [
        _op(EntityType.group, {GroupFields.emoji: null}),
        _op(EntityType.group, {GroupFields.deletedAt: null},
            kind: OpKind.restore),
        _op(EntityType.member, {
          MemberFields.deviceId: null,
          MemberFields.mergedInto: null,
        }),
        _op(EntityType.expense, {ExpenseFields.paymentMethod: null}),
        _op(EntityType.expense, {ExpenseFields.money: _money()}),
        _op(EntityType.expense, {ExpenseFields.deletedAt: -1}),
      ]) {
        expect(TextRules.remoteProblem(op), isNull, reason: '$op');
      }
    });

    test('wrong shapes are refused', () {
      Map<String, Object?> money(void Function(Map<String, Object?> m) edit) {
        final m = _money();
        edit(m);
        return m;
      }

      final bad = <String, Operation>{
        'null as a required text': _op(EntityType.expense,
            {ExpenseFields.description: null}),
        'null notes': _op(EntityType.expense, {ExpenseFields.notes: null}),
        'empty personId':
            _op(EntityType.member, {MemberFields.personId: ''}),
        'empty currency': _op(EntityType.group, {GroupFields.currency: ''}),
        'a number as createdBy':
            _op(EntityType.expense, {ExpenseFields.createdBy: 3}),
        'null archived': _op(EntityType.group, {GroupFields.archived: null}),
        'a string deletedAt':
            _op(EntityType.member, {MemberFields.deletedAt: 'now'}),
        'a date past the DateTime range': _op(EntityType.expense,
            {ExpenseFields.date: TextRules.maxDateMs + 1}),
        'a double as the date':
            _op(EntityType.expense, {ExpenseFields.date: 1.5}),
        'a money block that does not add up': _op(EntityType.expense, {
          ExpenseFields.money: money((m) => m['owed'] = {'m1': 1, 'm2': 1}),
        }),
        'a money block without owed': _op(EntityType.expense, {
          ExpenseFields.money: money((m) => m.remove('owed')),
        }),
        'a double total': _op(EntityType.expense, {
          ExpenseFields.money: money((m) => m['total'] = 300.0),
        }),
        'a padded split spec': _op(EntityType.expense, {
          ExpenseFields.money: money((m) => m['paidBy'] = {
                'method': 'exact',
                'values': {'m1': 300},
                'pad': 'x',
              }),
        }),
        'a string in split values': _op(EntityType.expense, {
          ExpenseFields.money: money((m) => m['owedBy'] = {
                'method': 'equal',
                'values': {'m1': '1'},
              }),
        }),
        'a number as the split method': _op(EntityType.expense, {
          ExpenseFields.money: money((m) => m['owedBy'] = {
                'method': 1,
                'values': {'m1': 1},
              }),
        }),
      };
      bad.forEach((what, op) {
        expect(TextRules.remoteProblem(op), isNotNull, reason: what);
      });
    });

    test('ops from a newer schema are not held to these types', () {
      final op = _op(EntityType.group, {GroupFields.name: 7},
          schemaVersion: kSchemaVersion + 1);
      expect(TextRules.remoteProblem(op), isNull);
    });

    test('a refused op leaves the group visible and stores nothing',
        () async {
      final p = await _Phone.create();
      addTearDown(p.ledger.close);
      final g = await _trip(p);
      final before = p.snap.ops.length;
      final evil = Operation(
        id: 'peer-retype',
        groupId: g,
        deviceId: dB,
        counter: 1,
        hlc: Hlc(kBaseMs + 1000, 0, dB),
        entityType: EntityType.group,
        entityId: g,
        kind: OpKind.update,
        payload: {GroupFields.simplifyDebts: 'yes'},
      );
      await expectLater(
          p.ledger.applyRemote(g, [evil]), throwsFormatException);
      expect(p.snap.ops, hasLength(before));
      expect(p.snap.state.visibleGroups.map((s) => s.groupId), contains(g));
    });
  });

  group('default-ignorable names (SECURITY-R3-02)', () {
    test('every Default_Ignorable_Code_Point range is blank', () {
      for (final r in [
        0x2060, 0x2065, 0x206F, //
        0xFFF0, 0xFFF4, 0xFFF8,
        0xE0000, 0xE007F, 0xE0080, 0xE00FF, 0xE0100, 0xE01EF, 0xE01F0,
        0xE0FFF,
      ]) {
        final v = String.fromCharCode(r);
        expect(TextRules.isBlank(v), isTrue, reason: r.toRadixString(16));
        expect(TextRules.isBlank('${v}A'), isFalse,
            reason: 'a letter next to U+${r.toRadixString(16)} shows');
      }
    });

    test('neighbours outside the ranges still show', () {
      for (final r in [0x205E, 0xFFE9, 0xFFFC, 0xFFFD, 0xE1000]) {
        expect(TextRules.isBlank(String.fromCharCode(r)), isFalse,
            reason: r.toRadixString(16));
      }
    });

    test('a peer member create with such a name is refused', () async {
      final p = await _Phone.create();
      addTearDown(p.ledger.close);
      final g = await _trip(p);
      final evil = Operation(
        id: 'peer-blank',
        groupId: g,
        deviceId: dB,
        counter: 1,
        hlc: Hlc(kBaseMs + 1000, 0, dB),
        entityType: EntityType.member,
        entityId: 'member-blank',
        kind: OpKind.create,
        payload: {
          MemberFields.displayName: '⁥\u{E01F0}',
          MemberFields.personId: 'person-blank',
          MemberFields.createdAt: kBaseMs,
        },
      );
      await expectLater(
          p.ledger.applyRemote(g, [evil]), throwsFormatException);
    });
  });

  group('forged peer knowledge on disk (DATA-R3-01)', () {
    test('the stored row is cut to what I wrote and stays cut', () async {
      final p = await _Phone.create();
      addTearDown(() => p.ledger.close());
      final g = await _trip(p);
      final written = p.snap.ops.where((o) => o.deviceId == p.deviceId).length;
      await p.ledger.close();
      await p.store.recordPeerKnowledge(
          dB, g, VersionVector({p.deviceId: TextRules.maxCounter, dC: 9}));
      await p.restart();
      expect((await p.store.peerKnowledge(g))[p.deviceId], written);
      expect((await p.store.peerKnowledge(g))[dC], 9,
          reason: 'other devices are not touched');
      expect(p.snap.unsharedCounts[g], isNull);
      for (var i = 1; i <= 3; i++) {
        await p.ledger.renameMember(g, p.members(g)[1], 'Sam $i');
        await p.restart();
        expect(p.snap.unsharedCounts[g], i, reason: 'after restart $i');
        expect(p.snap.totalUnshared, i);
      }
      // An honest report afterwards still marks them shared.
      await p.ledger.recordPeerKnowledge(
          dB, g, VersionVector({p.deviceId: written + 3}));
      expect(p.snap.unsharedCounts[g], isNull);
      await p.restart();
      expect(p.snap.unsharedCounts[g], isNull);
    });

    test('a forged row in a group where I have not written yet', () async {
      final a = await _Phone.create();
      addTearDown(a.ledger.close);
      final g = await _trip(a);
      final b = await _Phone.create(seed: 2, name: 'Sam');
      addTearDown(() => b.ledger.close());
      await b.ledger.registerJoinedGroup(g, (await a.keys.keyFor(g))!, 'Goa');
      await b.ledger.applyRemote(g, a.snap.ops);
      await b.ledger.close();
      await b.store.recordPeerKnowledge(
          a.deviceId, g, VersionVector({b.deviceId: TextRules.maxCounter}));
      await b.restart();
      expect((await b.store.peerKnowledge(g))[b.deviceId], 0);
      await b.ledger.renameMember(g, b.members(g)[1], 'Sammy');
      expect(b.snap.unsharedCounts[g], 1);
      await b.restart();
      expect(b.snap.unsharedCounts[g], 1);
    });
  });
}
