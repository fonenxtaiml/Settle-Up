// Ledger: every command, counters, validation, undo, replay, unshared
// counts and remote batches (SPEC 3.1, 5.11, 7.1-7.4, 11.2).
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/categories.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/schema.dart';
import 'package:settle_up/data/sqlite_op_store.dart';

import 'helpers.dart';

/// One simulated phone.
final class Phone {
  Phone._(this.store, this.keys, this.settings, this.ledger, this.clock,
      this.ids);

  final OpStore store;
  final MemoryGroupKeyStore keys;
  final KvSettingsRepository settings;
  Ledger ledger;
  final FakeClock clock;
  final IdGenerator ids;

  static Future<Phone> create({
    int seed = 1,
    bool onboard = true,
    OpStore? store,
    String name = 'Alex',
  }) async {
    final s = store ?? MemoryOpStore();
    await s.open();
    final settings = await KvSettingsRepository.open(s,
        defaultDeviceName: 'Phone $seed',
        ids: SequentialIdGenerator(seed << 40),
        localeName: 'en_IN');
    if (onboard) {
      await settings.completeOnboarding(displayName: name, homeCurrency: 'INR');
    }
    final keys = MemoryGroupKeyStore();
    final clock = FakeClock();
    final ids = SequentialIdGenerator((seed << 40) + 0x1000);
    final ledger = await Ledger.open(
        store: s, keys: keys, settings: settings, ids: ids, nowMillis: clock.call);
    return Phone._(s, keys, settings, ledger, clock, ids);
  }

  DeviceId get deviceId => settings.device.deviceId;
  LedgerSnapshot get snap => ledger.current;
  GroupState group(GroupId g) => snap.state.groups[g]!;

  Future<void> restart() async {
    await ledger.close();
    ledger = await Ledger.open(
        store: store,
        keys: keys,
        settings: settings,
        ids: ids,
        nowMillis: clock.call);
  }

  List<Operation> opsOf(GroupId g) =>
      [for (final o in snap.ops) if (o.groupId == g) o];

  /// Pulls everything [from] has for [g] that this phone lacks.
  Future<List<Operation>> pull(Phone from, GroupId g) async =>
      ledger.applyRemote(
          g, await from.ledger.opsMissingFor(g, await ledger.versionVector(g)));
}

Matcher throwsLedger(LedgerErrorCode code) => throwsA(
    isA<LedgerException>().having((e) => e.code, 'code', code));

ExpenseDraft draft(
  GroupId g,
  List<MemberId> members, {
  String description = 'Dinner',
  int total = 6000,
  String currency = 'INR',
  SplitSpec? paidBy,
  SplitSpec? owedBy,
  String category = 'food.dining',
  DateTime? date,
  String notes = '',
}) =>
    ExpenseDraft(
      groupId: g,
      description: description,
      total: total,
      currency: currency,
      paidBy: paidBy ?? SplitSpec.single(members.first, total),
      owedBy: owedBy ?? SplitSpec.equal(members),
      category: category,
      date: date ?? utcFromMillis(kBaseMs),
      notes: notes,
    );

void main() {
  late Phone a;

  setUp(() async => a = await Phone.create());
  tearDown(() => a.ledger.close());

  Future<({GroupId g, MemberId me, MemberId sam, MemberId priya})> trip(
      [Phone? p]) async {
    final phone = p ?? a;
    final g = await phone.ledger.createGroup(const NewGroup(
      name: 'Goa trip',
      type: GroupType.trip,
      currency: 'INR',
      newMemberNames: ['Sam', 'Priya'],
    ));
    final gs = phone.group(g);
    MemberId named(String n) =>
        gs.members.values.firstWhere((m) => m.displayName == n).id;
    return (g: g, me: named(phone.settings.profile!.displayName), sam: named('Sam'), priya: named('Priya'));
  }

  group('createGroup', () {
    test('writes the group, my claimed member and placeholders', () async {
      final t = await trip();
      final ops = a.opsOf(t.g);
      expect(ops, hasLength(4));
      expect(ops.map((o) => o.kind), everyElement(OpKind.create));
      expect(ops.map((o) => o.counter), [1, 2, 3, 4]);
      expect(ops.first.entityType, EntityType.group);
      expect(ops.first.entityId, t.g);
      expect(ops.first.payload.keys, containsAll(GroupFields.required));
      for (final o in ops.skip(1)) {
        expect(o.payload.keys, containsAll(MemberFields.required));
      }
      for (var i = 1; i < ops.length; i++) {
        expect(ops[i].hlc > ops[i - 1].hlc, isTrue);
      }

      final gs = a.group(t.g);
      final group = gs.group!;
      expect(group.name, 'Goa trip');
      expect(group.type, GroupType.trip);
      expect(group.currency, 'INR');
      expect(group.simplifyDebts, isTrue);
      expect(group.archived, isFalse);
      expect(group.createdAt, utcFromMillis(kBaseMs));
      final me = gs.members[t.me]!;
      expect(me.deviceId, a.deviceId);
      expect(me.personId, a.settings.profile!.personId);
      expect(gs.members[t.sam]!.isPlaceholder, isTrue);
      expect(gs.members[t.sam]!.personId,
          isNot(gs.members[t.priya]!.personId));

      final key = (await a.ledger.groupKeys())[t.g]!;
      expect(key, hasLength(32));
      expect(await a.keys.keyFor(t.g), key);
    });

    test('options: emoji, simplify, existing people (self skipped)', () async {
      final myPerson = a.settings.profile!.personId;
      final g = await a.ledger.createGroup(NewGroup(
        name: '  Flat 4B ',
        type: GroupType.home,
        currency: 'eur',
        emoji: '🏠',
        simplifyDebts: false,
        existingPeople: [
          (personId: 'person-sam', displayName: 'Sam'),
          (personId: 'person-sam', displayName: 'Sam again'),
          (personId: myPerson, displayName: 'Me'),
        ],
      ));
      final gs = a.group(g);
      expect(gs.group!.name, 'Flat 4B');
      expect(gs.group!.currency, 'EUR');
      expect(gs.group!.emoji, '🏠');
      expect(gs.group!.simplifyDebts, isFalse);
      expect(gs.members, hasLength(2));
      expect(gs.memberForPerson('person-sam')!.displayName, 'Sam');
    });

    test('simplifyDebts defaults to the app setting', () async {
      await a.settings.updateSettings(
          a.settings.settings.copyWith(simplifyByDefault: false));
      final g = await a.ledger.createGroup(
          const NewGroup(name: 'X', type: GroupType.other, currency: 'INR'));
      expect(a.group(g).group!.simplifyDebts, isFalse);
    });

    test('validation', () async {
      expect(
          a.ledger.createGroup(const NewGroup(
              name: 'D', type: GroupType.direct, currency: 'INR')),
          throwsLedger(LedgerErrorCode.invalidInput));
      expect(
          a.ledger.createGroup(
              const NewGroup(name: ' ', type: GroupType.trip, currency: 'INR')),
          throwsLedger(LedgerErrorCode.invalidInput));
      expect(
          a.ledger.createGroup(
              const NewGroup(name: 'X', type: GroupType.trip, currency: 'rupees')),
          throwsLedger(LedgerErrorCode.invalidInput));
      expect(
          a.ledger.createGroup(const NewGroup(
              name: 'X',
              type: GroupType.trip,
              currency: 'INR',
              newMemberNames: [''])),
          throwsLedger(LedgerErrorCode.invalidInput));
      await pumpEventQueue();
      expect(a.snap.ops, isEmpty);
      expect(await a.ledger.groupKeys(), isEmpty);
    });

    test('requires onboarding', () async {
      final fresh = await Phone.create(seed: 2, onboard: false);
      addTearDown(fresh.ledger.close);
      expect(
          fresh.ledger.createGroup(const NewGroup(
              name: 'X', type: GroupType.trip, currency: 'INR')),
          throwsLedger(LedgerErrorCode.notOnboarded));
      expect(
          fresh.ledger.directGroupWith(
              personId: 'p', displayName: 'Sam', currency: 'INR'),
          throwsLedger(LedgerErrorCode.notOnboarded));
    });
  });

  group('snapshot streams', () {
    test('watch emits the current snapshot first, then each change',
        () async {
      final seen = <LedgerSnapshot>[];
      final sub = a.ledger.watch().listen(seen.add);
      await pumpEventQueue();
      expect(seen, hasLength(1));
      expect(seen.single.ops, isEmpty);
      expect(seen.single.localDeviceId, a.deviceId);
      final t = await trip();
      await a.ledger.addExpense(draft(t.g, [t.me, t.sam]));
      await pumpEventQueue();
      expect(seen, hasLength(3));
      expect(seen.last.ops, hasLength(5));
      expect(identical(seen.last, a.ledger.current), isTrue);
      expect(() => seen.last.ops.add(seen.last.ops.first),
          throwsUnsupportedError);
      await sub.cancel();
    });

    test('ops are ascending by HLC, remote ones included', () async {
      final b = await Phone.create(seed: 2, name: 'Sam');
      addTearDown(b.ledger.close);
      final t = await trip();
      await b.ledger.registerJoinedGroup(
          t.g, (await a.ledger.groupKeys())[t.g]!, 'Goa');
      await b.pull(a, t.g);
      b.clock.advance(5000);
      await b.ledger.addExpense(draft(t.g, [t.me, t.sam]));
      await a.ledger.addExpense(draft(t.g, [t.me, t.sam], description: 'Taxi'));
      await a.pull(b, t.g);
      final hlcs = [for (final o in a.snap.ops) o.hlc];
      expect(hlcs, isNotEmpty);
      expect(hlcs.isSorted((x, y) => x.compareTo(y)), isTrue);
      expect(a.snap.ops.last.deviceId, b.deviceId);
    });

    test('localOps carries every committed local op', () async {
      final out = <Operation>[];
      final sub = a.ledger.localOps.listen(out.add);
      final t = await trip();
      await a.ledger.addExpense(draft(t.g, [t.me, t.sam]));
      await pumpEventQueue();
      expect(out, a.snap.ops);
      await sub.cancel();
    });

    test('close completes streams and later commands fail', () async {
      final done = a.ledger.watch().toList();
      await a.ledger.close();
      expect(await done, hasLength(1));
      expect(
          a.ledger.createGroup(const NewGroup(
              name: 'X', type: GroupType.trip, currency: 'INR')),
          throwsStateError);
      a.ledger = await Ledger.open(
          store: a.store, keys: a.keys, settings: a.settings);
    });
  });

  group('group and member commands', () {
    test('updateGroup writes only changed fields', () async {
      final t = await trip();
      await a.ledger.updateGroup(
          t.g,
          const GroupPatch(
              name: 'Goa trip', currency: 'INR', simplifyDebts: true));
      expect(a.opsOf(t.g), hasLength(4), reason: 'nothing changed');
      await a.ledger.updateGroup(
          t.g,
          const GroupPatch(
              name: 'Goa 2026', emoji: '🌴', archived: true, type: GroupType.trip));
      final op = a.opsOf(t.g).last;
      expect(op.kind, OpKind.update);
      expect(op.payload,
          {GroupFields.name: 'Goa 2026', GroupFields.emoji: '🌴', GroupFields.archived: true});
      await a.ledger.updateGroup(t.g, const GroupPatch(emoji: ''));
      expect(a.opsOf(t.g).last.payload, {GroupFields.emoji: null});
      final g = a.group(t.g).group!;
      expect(g.name, 'Goa 2026');
      expect(g.archived, isTrue);
      expect(g.emoji, isNull);
      expect(a.ledger.updateGroup(t.g, const GroupPatch(type: GroupType.direct)),
          throwsLedger(LedgerErrorCode.invalidInput));
      expect(a.ledger.updateGroup('nope', const GroupPatch(name: 'x')),
          throwsLedger(LedgerErrorCode.groupNotFound));
    });

    test('deleteGroup tombstones; the key stays for sync', () async {
      final t = await trip();
      await a.ledger.deleteGroup(t.g);
      final op = a.opsOf(t.g).last;
      expect(op.kind, OpKind.delete);
      expect(op.payload, {GroupFields.deletedAt: op.hlc.millis});
      expect(a.group(t.g).group!.isDeleted, isTrue);
      expect(a.snap.state.visibleGroups, isEmpty);
      expect((await a.ledger.groupKeys()).keys, [t.g]);
      expect(a.ledger.addExpense(draft(t.g, [t.me])),
          throwsLedger(LedgerErrorCode.groupNotFound));
      expect(a.ledger.deleteGroup(t.g),
          throwsLedger(LedgerErrorCode.groupNotFound));
    });

    test('addMember: fresh person, or an existing person re-used', () async {
      final t = await trip();
      final m = await a.ledger.addMember(t.g, displayName: ' Kai ');
      final kai = a.group(t.g).members[m]!;
      expect(kai.displayName, 'Kai');
      expect(kai.isPlaceholder, isTrue);
      final again = await a.ledger.addMember(t.g,
          displayName: 'Kai (other group)', personId: kai.personId);
      expect(again, m, reason: 'same person is already active here');
      final n = await a.ledger.addMember(t.g,
          displayName: 'Zoe', personId: 'person-zoe');
      expect(a.group(t.g).members[n]!.personId, 'person-zoe');
      expect(a.ledger.addMember(t.g, displayName: ''),
          throwsLedger(LedgerErrorCode.invalidInput));
    });

    test('rename, remove, merge', () async {
      final t = await trip();
      await a.ledger.renameMember(t.g, t.sam, 'Samir');
      expect(a.opsOf(t.g).last.payload, {MemberFields.displayName: 'Samir'});
      final count = a.opsOf(t.g).length;
      await a.ledger.renameMember(t.g, t.sam, ' Samir ');
      expect(a.opsOf(t.g), hasLength(count));

      final kai = await a.ledger.addMember(t.g, displayName: 'Kai');
      await a.ledger.removeMember(t.g, kai);
      expect(a.opsOf(t.g).last.kind, OpKind.delete);
      expect(a.group(t.g).members[kai]!.isRemoved, isTrue);
      await a.ledger.removeMember(t.g, kai);
      expect(a.opsOf(t.g).last.kind, OpKind.delete);
      expect(a.opsOf(t.g), hasLength(count + 2));

      await a.ledger.mergeMembers(t.g, from: t.priya, into: t.sam);
      expect(a.opsOf(t.g).last.payload, {MemberFields.mergedInto: t.sam});
      expect(a.group(t.g).resolve(t.priya), t.sam);
      expect(a.ledger.mergeMembers(t.g, from: t.sam, into: t.priya),
          throwsLedger(LedgerErrorCode.invalidInput));
      expect(a.ledger.mergeMembers(t.g, from: t.sam, into: t.sam),
          throwsLedger(LedgerErrorCode.invalidInput));
      expect(a.ledger.mergeMembers(t.g, from: t.me, into: kai),
          throwsLedger(LedgerErrorCode.invalidInput));
      expect(a.ledger.renameMember(t.g, 'ghost', 'x'),
          throwsLedger(LedgerErrorCode.memberNotFound));
      expect(a.ledger.removeMember(t.g, 'ghost'),
          throwsLedger(LedgerErrorCode.memberNotFound));
    });

    test('claimMember sets my person and device, releasing an old claim',
        () async {
      final t = await trip();
      final myPerson = a.settings.profile!.personId;
      await a.ledger.claimMember(t.g, t.sam);
      final ops = a.opsOf(t.g);
      final release = ops[ops.length - 2];
      final claim = ops.last;
      expect(release.entityId, t.me);
      expect(release.payload[MemberFields.deviceId], isNull);
      expect(release.payload[MemberFields.personId], isNot(myPerson));
      expect(claim.entityId, t.sam);
      expect(claim.payload,
          {MemberFields.personId: myPerson, MemberFields.deviceId: a.deviceId});
      final gs = a.group(t.g);
      expect(gs.members[t.sam]!.deviceId, a.deviceId);
      expect(gs.members[t.me]!.isPlaceholder, isTrue);
      expect(gs.memberForPerson(myPerson)!.id, t.sam);

      final count = a.opsOf(t.g).length;
      await a.ledger.claimMember(t.g, t.sam);
      expect(a.opsOf(t.g), hasLength(count), reason: 'already mine');
    });

    test('directGroupWith finds or creates the 1:1 group', () async {
      final g = await a.ledger.directGroupWith(
          personId: 'person-sam', displayName: 'Sam', currency: 'INR');
      final gs = a.group(g);
      expect(gs.group!.isDirect, isTrue);
      expect(gs.members, hasLength(2));
      expect(gs.memberForPerson('person-sam')!.displayName, 'Sam');
      expect(gs.memberForPerson(a.settings.profile!.personId)!.deviceId,
          a.deviceId);
      final again = await a.ledger.directGroupWith(
          personId: 'person-sam', displayName: 'Sam K', currency: 'EUR');
      expect(again, g);
      final other = await a.ledger.directGroupWith(
          personId: 'person-kai', displayName: 'Kai', currency: 'INR');
      expect(other, isNot(g));
      expect(
          a.ledger.directGroupWith(
              personId: a.settings.profile!.personId,
              displayName: 'Me',
              currency: 'INR'),
          throwsLedger(LedgerErrorCode.invalidInput));
      expect(a.ledger.updateGroup(g, const GroupPatch(type: GroupType.trip)),
          throwsLedger(LedgerErrorCode.invalidInput));
    });
  });

  group('expenses', () {
    test('addExpense writes every required field and a consistent block',
        () async {
      final t = await trip();
      final e = await a.ledger.addExpense(draft(
        t.g,
        [t.me, t.sam, t.priya],
        description: '  Dinner at Thalassa ',
        total: 1000,
        notes: ' window table ',
        date: DateTime.utc(2026, 11, 8, 20),
        paidBy: SplitSpec(SplitMethod.exact, {t.me: 600, t.sam: 400}),
      ));
      final op = a.opsOf(t.g).last;
      expect(op.kind, OpKind.create);
      expect(op.entityType, EntityType.expense);
      expect(op.entityId, e);
      expect(op.payload.keys, containsAll(ExpenseFields.required));
      expect(op.payload[ExpenseFields.createdBy], t.me);
      final x = a.snap.state.expense(e)!;
      expect(x.description, 'Dinner at Thalassa');
      expect(x.notes, 'window table');
      expect(x.date, DateTime.utc(2026, 11, 8, 20));
      expect(x.kind, ExpenseKind.expense);
      expect(x.money.isConsistent, isTrue);
      expect(x.money.paid, {t.me: 600, t.sam: 400});
      expect(x.money.owed.values.sum, 1000);
      expect(x.money.owed.values.toSet(), {333, 334});
      expect(a.group(t.g).liveExpenses.single.id, e);
    });

    test('local dates are stored as UTC milliseconds', () async {
      final t = await trip();
      final local = DateTime(2026, 11, 8, 20, 30);
      final e = await a.ledger.addExpense(draft(t.g, [t.me], date: local));
      expect(a.snap.state.expense(e)!.date,
          utcFromMillis(local.millisecondsSinceEpoch));
    });

    test('empty category becomes general', () async {
      final t = await trip();
      final e = await a.ledger.addExpense(draft(t.g, [t.me], category: ' '));
      expect(a.snap.state.expense(e)!.category, Categories.general);
    });

    test('validation errors', () async {
      final t = await trip();
      final before = a.snap.ops.length;
      Future<void> bad(ExpenseDraft d, LedgerErrorCode code) =>
          expectLater(a.ledger.addExpense(d), throwsLedger(code));
      await bad(draft(t.g, [t.me], description: '  '),
          LedgerErrorCode.invalidInput);
      await bad(draft(t.g, [t.me], total: 0), LedgerErrorCode.invalidInput);
      await bad(draft(t.g, [t.me], total: 1000000000),
          LedgerErrorCode.invalidInput);
      await bad(draft(t.g, [t.me], currency: 'X'), LedgerErrorCode.invalidInput);
      await bad(draft('nope', [t.me]), LedgerErrorCode.groupNotFound);
      await bad(draft(t.g, [t.me, 'ghost']), LedgerErrorCode.memberNotFound);
      await bad(
          draft(t.g, [t.me, t.sam],
              owedBy: SplitSpec(SplitMethod.exact, {t.me: 100, t.sam: 100})),
          LedgerErrorCode.invalidSplit);
      await bad(
          draft(t.g, [t.me, t.sam],
              owedBy: SplitSpec(SplitMethod.percent, {t.me: 5000, t.sam: 4000})),
          LedgerErrorCode.invalidSplit);
      await bad(draft(t.g, [t.me], owedBy: const SplitSpec(SplitMethod.equal, {})),
          LedgerErrorCode.invalidSplit);
      expect(a.snap.ops, hasLength(before));
      // Counters stay contiguous after failures.
      await a.ledger.addExpense(draft(t.g, [t.me]));
      expect(a.opsOf(t.g).map((o) => o.counter),
          List.generate(before + 1, (i) => i + 1));
    });

    test('updateExpense writes only the fields that changed', () async {
      final t = await trip();
      final base = draft(t.g, [t.me, t.sam]);
      final e = await a.ledger.addExpense(base);
      final n = a.opsOf(t.g).length;

      await a.ledger.updateExpense(e, base);
      expect(a.opsOf(t.g), hasLength(n), reason: 'no change, no op');

      await a.ledger.updateExpense(
          e, draft(t.g, [t.me, t.sam], description: 'Late dinner'));
      expect(a.opsOf(t.g).last.kind, OpKind.update);
      expect(a.opsOf(t.g).last.payload,
          {ExpenseFields.description: 'Late dinner'});

      await a.ledger.updateExpense(
          e, draft(t.g, [t.me, t.sam], description: 'Late dinner', total: 9000));
      final money = a.opsOf(t.g).last.payload;
      expect(money.keys, [ExpenseFields.money]);
      expect((money[ExpenseFields.money]! as Map)['total'], 9000);

      await a.ledger.updateExpense(
          e,
          draft(t.g, [t.me, t.sam],
              description: 'Late dinner',
              total: 9000,
              notes: 'tip incl.',
              category: 'food.drinks',
              date: utcFromMillis(kBaseMs + 1)));
      expect(a.opsOf(t.g).last.payload.keys.toSet(), {
        ExpenseFields.notes,
        ExpenseFields.category,
        ExpenseFields.date,
      });

      // Same split, members listed in another order: no money write.
      final count = a.opsOf(t.g).length;
      await a.ledger.updateExpense(
          e,
          draft(t.g, [t.sam, t.me],
              paidBy: SplitSpec.single(t.me, 9000),
              description: 'Late dinner',
              total: 9000,
              notes: 'tip incl.',
              category: 'food.drinks',
              date: utcFromMillis(kBaseMs + 1)));
      expect(a.opsOf(t.g), hasLength(count));

      final x = a.snap.state.expense(e)!;
      expect(x.description, 'Late dinner');
      expect(x.money.total, 9000);
      expect(x.notes, 'tip incl.');
      expect(x.updatedHlc, a.opsOf(t.g).last.hlc);

      expect(a.ledger.updateExpense('nope', base),
          throwsLedger(LedgerErrorCode.expenseNotFound));
      expect(a.ledger.updateExpense(e, draft(t.g, [t.me], total: -1)),
          throwsLedger(LedgerErrorCode.invalidInput));
    });

    test('an expense cannot move to another group', () async {
      final t = await trip();
      final other = await a.ledger.createGroup(
          const NewGroup(name: 'Other', type: GroupType.other, currency: 'INR'));
      final e = await a.ledger.addExpense(draft(t.g, [t.me]));
      final me2 = a.group(other).members.keys.single;
      expect(a.ledger.updateExpense(e, draft(other, [me2])),
          throwsLedger(LedgerErrorCode.invalidInput));
    });

    test('undo add: delete hides it; undo delete: restore brings it back',
        () async {
      final t = await trip();
      final e = await a.ledger.addExpense(draft(t.g, [t.me, t.sam]));
      await a.ledger.deleteExpense(e); // undo of the add
      final del = a.opsOf(t.g).last;
      expect(del.kind, OpKind.delete);
      expect(del.payload, {ExpenseFields.deletedAt: del.hlc.millis});
      expect(a.group(t.g).liveExpenses, isEmpty);
      expect(a.snap.state.expense(e)!.isDeleted, isTrue);

      await a.ledger.restoreExpense(e); // undo of the delete
      final res = a.opsOf(t.g).last;
      expect(res.kind, OpKind.restore);
      expect(res.payload, {ExpenseFields.deletedAt: null});
      expect(a.group(t.g).liveExpenses.single.id, e);

      final n = a.opsOf(t.g).length;
      await a.ledger.restoreExpense(e);
      expect(a.opsOf(t.g), hasLength(n), reason: 'not deleted: no-op');
      await a.ledger.deleteExpense(e);
      await a.ledger.deleteExpense(e);
      expect(a.opsOf(t.g), hasLength(n + 1), reason: 'second delete: no-op');
      expect(a.ledger.deleteExpense('nope'),
          throwsLedger(LedgerErrorCode.expenseNotFound));
    });

    test('edits made while deleted come back on restore', () async {
      final t = await trip();
      final e = await a.ledger.addExpense(draft(t.g, [t.me, t.sam]));
      await a.ledger.deleteExpense(e);
      await a.ledger.updateExpense(
          e, draft(t.g, [t.me, t.sam], description: 'Brunch'));
      expect(a.snap.state.expense(e)!.isDeleted, isTrue);
      await a.ledger.restoreExpense(e);
      expect(a.snap.state.expense(e)!.description, 'Brunch');
    });
  });

  group('payments', () {
    test('recordPayment and updatePayment', () async {
      final t = await trip();
      final p = await a.ledger.recordPayment(PaymentDraft(
        groupId: t.g,
        from: t.sam,
        to: t.me,
        amount: 2500,
        currency: 'INR',
        method: PaymentMethod.upi,
        date: utcFromMillis(kBaseMs),
      ));
      final op = a.opsOf(t.g).last;
      expect(op.payload.keys, containsAll(ExpenseFields.required));
      expect(op.payload[ExpenseFields.kind], 'payment');
      expect(op.payload[ExpenseFields.category], Categories.payment);
      expect(op.payload[ExpenseFields.paymentMethod], 'upi');
      final x = a.snap.state.expense(p)!;
      expect(x.isPayment, isTrue);
      expect(x.description, '');
      expect(x.payer, t.sam);
      expect(x.receiver, t.me);
      expect(x.money.total, 2500);
      expect(x.createdBy, t.me);

      await a.ledger.updatePayment(
          p,
          PaymentDraft(
            groupId: t.g,
            from: t.sam,
            to: t.me,
            amount: 3000,
            currency: 'INR',
            method: PaymentMethod.cash,
            date: utcFromMillis(kBaseMs),
          ));
      expect(a.opsOf(t.g).last.payload.keys.toSet(),
          {ExpenseFields.money, ExpenseFields.paymentMethod});
      expect(a.snap.state.expense(p)!.paymentMethod, PaymentMethod.cash);
      expect(a.snap.state.expense(p)!.money.total, 3000);

      final e = await a.ledger.addExpense(draft(t.g, [t.me]));
      expect(a.ledger.updateExpense(p, draft(t.g, [t.me])),
          throwsLedger(LedgerErrorCode.invalidInput));
      expect(
          a.ledger.updatePayment(
              e,
              PaymentDraft(
                  groupId: t.g,
                  from: t.sam,
                  to: t.me,
                  amount: 1,
                  currency: 'INR',
                  method: PaymentMethod.cash,
                  date: utcFromMillis(kBaseMs))),
          throwsLedger(LedgerErrorCode.invalidInput));
    });

    test('payment validation', () async {
      final t = await trip();
      PaymentDraft pd({MemberId? from, MemberId? to, int amount = 100}) =>
          PaymentDraft(
            groupId: t.g,
            from: from ?? t.sam,
            to: to ?? t.me,
            amount: amount,
            currency: 'INR',
            method: PaymentMethod.bank,
            date: utcFromMillis(kBaseMs),
          );
      expect(a.ledger.recordPayment(pd(to: t.sam)),
          throwsLedger(LedgerErrorCode.invalidInput));
      expect(a.ledger.recordPayment(pd(amount: 0)),
          throwsLedger(LedgerErrorCode.invalidInput));
      expect(a.ledger.recordPayment(pd(from: 'ghost')),
          throwsLedger(LedgerErrorCode.memberNotFound));
    });
  });

  group('counters', () {
    test('contiguous per (group, device) across commands and groups',
        () async {
      final t1 = await trip();
      final t2 = await trip();
      for (var i = 0; i < 5; i++) {
        await a.ledger.addExpense(draft(t1.g, [t1.me, t1.sam], total: 100 + i));
        await a.ledger.addExpense(draft(t2.g, [t2.me], total: 100 + i));
      }
      await a.ledger.renameMember(t1.g, t1.sam, 'S');
      for (final g in [t1.g, t2.g]) {
        final counters = a.opsOf(g).map((o) => o.counter).toList()..sort();
        expect(counters, List.generate(counters.length, (i) => i + 1));
        expect(await a.ledger.versionVector(g),
            VersionVector({a.deviceId: counters.length}));
      }
    });

    test('concurrent commands are serialized', () async {
      final t = await trip();
      final futures = [
        for (var i = 0; i < 20; i++)
          a.ledger.addExpense(draft(t.g, [t.me, t.sam], total: 100 + i)),
      ];
      final ids = await Future.wait(futures);
      expect(ids.toSet(), hasLength(20));
      final counters = a.opsOf(t.g).map((o) => o.counter).toList();
      expect(counters, List.generate(24, (i) => i + 1));
      // Commit order matches call order.
      expect([
        for (final o in a.opsOf(t.g).skip(4))
          (o.payload[ExpenseFields.money]! as Map)['total']
      ], List.generate(20, (i) => 100 + i));
    });

    test('a failed write does not use up a counter', () async {
      final flaky = _FlakyStore();
      final p = await Phone.create(seed: 3, store: flaky);
      addTearDown(p.ledger.close);
      final t = await trip(p);
      flaky.failNext = true;
      await expectLater(
          p.ledger.addExpense(draft(t.g, [t.me])), throwsA(isA<StateError>()));
      expect(p.opsOf(t.g), hasLength(4));
      await p.ledger.addExpense(draft(t.g, [t.me]));
      expect(p.opsOf(t.g).map((o) => o.counter), [1, 2, 3, 4, 5]);
    });

    test('a failed createGroup leaves no key behind', () async {
      final flaky = _FlakyStore();
      final p = await Phone.create(seed: 3, store: flaky);
      addTearDown(p.ledger.close);
      flaky.failNext = true;
      await expectLater(
          p.ledger.createGroup(const NewGroup(
              name: 'X', type: GroupType.trip, currency: 'INR')),
          throwsStateError);
      expect(await p.ledger.groupKeys(), isEmpty);
      expect(await p.keys.all(), isEmpty);
    });
  });

  group('startup', () {
    Future<void> busyDay(Phone p) async {
      final t = await trip(p);
      final e = await p.ledger.addExpense(draft(t.g, [t.me, t.sam, t.priya]));
      await p.ledger.updateExpense(
          e, draft(t.g, [t.me, t.sam, t.priya], total: 9000));
      await p.ledger.recordPayment(PaymentDraft(
          groupId: t.g,
          from: t.sam,
          to: t.me,
          amount: 3000,
          currency: 'INR',
          method: PaymentMethod.cash,
          date: utcFromMillis(kBaseMs)));
      final gone = await p.ledger.addExpense(draft(t.g, [t.me], total: 5));
      await p.ledger.deleteExpense(gone);
      await p.ledger.mergeMembers(t.g, from: t.priya, into: t.sam);
      await p.ledger.directGroupWith(
          personId: 'person-kai', displayName: 'Kai', currency: 'INR');
      await p.ledger.recordPeerKnowledge(
          dB, t.g, VersionVector({p.deviceId: 3}));
    }

    void expectSameSnapshot(LedgerSnapshot x, LedgerSnapshot y) {
      expect(x.state.toCanonicalJson(), y.state.toCanonicalJson());
      expect([for (final o in x.ops) o.id], [for (final o in y.ops) o.id]);
      expect(x.unsharedOpIds, y.unsharedOpIds);
      expect(x.unsharedCounts, y.unsharedCounts);
      expect(x.pendingJoins, y.pendingJoins);
      expect(x.localDeviceId, y.localDeviceId);
    }

    test('replay of the stored log equals the live snapshot (memory)',
        () async {
      await busyDay(a);
      final live = a.snap;
      await a.restart();
      expectSameSnapshot(a.snap, live);
    });

    test('replay equals the live snapshot (SQLite file)', () async {
      final sql = SqliteOpStore(':memory:');
      final p = await Phone.create(seed: 4, store: sql);
      await busyDay(p);
      final live = p.snap;
      await p.restart();
      expectSameSnapshot(p.snap, live);
      await p.ledger.close();
      await sql.close();
    });

    test('the HLC is restored even when the wall clock went back', () async {
      final t = await trip();
      a.clock.advance(3600 * 1000);
      await a.ledger.addExpense(draft(t.g, [t.me]));
      final last = a.snap.ops.last.hlc;
      expect(await a.store.getKv(KvKeys.hlcLast), last.encode());
      a.clock.now = kBaseMs - 86400 * 1000; // a day before the first op
      await a.restart();
      await a.ledger.addExpense(draft(t.g, [t.me]));
      final next = a.snap.ops.last;
      expect(next.hlc > last, isTrue);
      expect(next.counter, 6);
    });

    test('the HLC is restored from own ops when kv is missing or bad',
        () async {
      final t = await trip();
      a.clock.advance(7200 * 1000);
      await a.ledger.addExpense(draft(t.g, [t.me]));
      final last = a.snap.ops.last.hlc;
      await a.store.setKv(KvKeys.hlcLast, 'garbage');
      a.clock.now = kBaseMs;
      await a.restart();
      await a.ledger.renameMember(t.g, t.sam, 'S');
      expect(a.snap.ops.last.hlc > last, isTrue);
    });
  });

  group('unshared ops', () {
    test('counts drop as peers acknowledge my counters', () async {
      final t = await trip();
      await a.ledger.addExpense(draft(t.g, [t.me]));
      expect(a.snap.unsharedCounts, {t.g: 5});
      expect(a.snap.totalUnshared, 5);
      expect(a.snap.unsharedOpIds, a.opsOf(t.g).map((o) => o.id).toSet());
      expect(a.snap.unsharedEntityIds, contains(t.g));

      final seen = <LedgerSnapshot>[];
      final sub = a.ledger.watch().listen(seen.add);
      await a.ledger.recordPeerKnowledge(dB, t.g, VersionVector({a.deviceId: 3}));
      await pumpEventQueue();
      expect(seen, hasLength(2));
      expect(a.snap.unsharedCounts, {t.g: 2});
      expect(a.snap.unsharedOpIds,
          a.opsOf(t.g).skip(3).map((o) => o.id).toSet());

      // A stale report does not raise it again; other peers merge in.
      await a.ledger.recordPeerKnowledge(dB, t.g, VersionVector({a.deviceId: 1}));
      expect(a.snap.unsharedCounts, {t.g: 2});
      await a.ledger.recordPeerKnowledge(dC, t.g, VersionVector({a.deviceId: 5}));
      expect(a.snap.unsharedCounts, isEmpty);
      expect(a.snap.totalUnshared, 0);
      await pumpEventQueue();
      expect(seen, hasLength(3), reason: 'no snapshot for a no-op report');
      await sub.cancel();

      await a.restart();
      expect(a.snap.unsharedCounts, isEmpty);
    });

    test('remote ops are never unshared; my own echo is ignored', () async {
      final t = await trip();
      await a.ledger.recordPeerKnowledge(
          a.deviceId, t.g, VersionVector({a.deviceId: 4}));
      expect(a.snap.unsharedCounts, {t.g: 4});
    });
  });

  group('sync store', () {
    late Phone b;
    setUp(() async => b = await Phone.create(seed: 2, name: 'Sam'));
    tearDown(() => b.ledger.close());

    test('identity comes from settings', () async {
      expect(a.ledger.localDeviceId, a.deviceId);
      expect(a.ledger.localDeviceName, 'Phone 1');
      await a.settings.setDeviceName("Alex's Pixel");
      expect(a.ledger.localDeviceName, "Alex's Pixel");
    });

    test('join: pending until the create op arrives, then the full group',
        () async {
      final t = await trip();
      final key = (await a.ledger.groupKeys())[t.g]!;
      expect(await b.ledger.registerJoinedGroup(t.g, key, ' Goa trip '), isTrue);
      expect(await b.ledger.registerJoinedGroup(t.g, key, 'again'), isFalse);
      expect(b.snap.pendingJoins, {t.g: 'Goa trip'});
      expect((await b.ledger.groupKeys())[t.g], key);
      expect(await b.store.getKv(KvKeys.pending(t.g)), 'Goa trip');

      await b.restart();
      expect(b.snap.pendingJoins, {t.g: 'Goa trip'});

      final added = await b.pull(a, t.g);
      expect(added, hasLength(4));
      expect(b.snap.pendingJoins, isEmpty);
      expect(await b.store.getKv(KvKeys.pending(t.g)), isNull);
      expect(b.snap.state.toCanonicalJson(), a.snap.state.toCanonicalJson());
      expect(b.snap.unsharedCounts, isEmpty);
      expect(await b.ledger.versionVector(t.g), VersionVector({a.deviceId: 4}));

      // Joining a group we already hold is a no-op.
      expect(await a.ledger.registerJoinedGroup(t.g, key, 'x'), isFalse);
      expect(() => b.ledger.registerJoinedGroup('g2', Uint8List(3), 'x'),
          throwsArgumentError);
    });

    test('two phones converge; claim, edit, and each other\'s ops relayed',
        () async {
      final t = await trip();
      await b.ledger.registerJoinedGroup(
          t.g, (await a.ledger.groupKeys())[t.g]!, 'Goa');
      await b.pull(a, t.g);
      await b.ledger.claimMember(t.g, t.sam);
      final e = await b.ledger.addExpense(draft(t.g, [t.sam, t.me]));
      expect(b.snap.state.expense(e)!.createdBy, t.sam);
      await a.ledger.addExpense(draft(t.g, [t.me, t.priya], description: 'Taxi'));
      await a.pull(b, t.g);
      await b.pull(a, t.g);
      expect(a.snap.state.toCanonicalJson(), b.snap.state.toCanonicalJson());
      expect(await a.ledger.versionVector(t.g),
          await b.ledger.versionVector(t.g));
      expect(a.group(t.g).members[t.sam]!.deviceId, b.deviceId);
      // Ops authored on B are relayed by A to a third phone.
      final c = await Phone.create(seed: 5, name: 'Priya');
      addTearDown(c.ledger.close);
      await c.ledger.registerJoinedGroup(
          t.g, (await a.ledger.groupKeys())[t.g]!, 'Goa');
      await c.pull(a, t.g);
      expect(c.snap.state.toCanonicalJson(), b.snap.state.toCanonicalJson());
    });

    test('applyRemote returns only new ops and notifies once per batch',
        () async {
      final t = await trip();
      await b.ledger.registerJoinedGroup(
          t.g, (await a.ledger.groupKeys())[t.g]!, 'Goa');
      final ops = await a.ledger.opsMissingFor(t.g, VersionVector.empty);
      final seen = <LedgerSnapshot>[];
      final local = <Operation>[];
      final s1 = b.ledger.watch().listen(seen.add);
      final s2 = b.ledger.localOps.listen(local.add);
      expect(await b.ledger.applyRemote(t.g, ops.sublist(0, 2)), hasLength(2));
      expect(await b.ledger.applyRemote(t.g, ops), ops.sublist(2));
      expect(await b.ledger.applyRemote(t.g, ops), isEmpty);
      expect(await b.ledger.applyRemote(t.g, const []), isEmpty);
      await pumpEventQueue();
      expect(seen, hasLength(3));
      expect(local, isEmpty, reason: 'remote ops are not re-pushed as local');
      await s1.cancel();
      await s2.cancel();
    });

    test('applyRemote advances the HLC past the batch max', () async {
      final t = await trip();
      await b.ledger.registerJoinedGroup(
          t.g, (await a.ledger.groupKeys())[t.g]!, 'Goa');
      a.clock.advance(30 * 60 * 1000); // A's clock is 30 min ahead
      await a.ledger.renameMember(t.g, t.sam, 'S');
      await b.pull(a, t.g);
      final remoteMax = a.snap.ops.last.hlc;
      await b.ledger.renameMember(t.g, t.priya, 'P');
      expect(b.snap.ops.last.hlc > remoteMax, isTrue);
      expect(Hlc.parse((await b.store.getKv(KvKeys.hlcLast))!),
          b.snap.ops.last.hlc);
      expect(b.ledger.clockSkewDetected, isFalse);
    });

    test('a peer clock hours ahead is stored but not adopted', () async {
      final t = await trip();
      await b.ledger.registerJoinedGroup(
          t.g, (await a.ledger.groupKeys())[t.g]!, 'Goa');
      a.clock.advance(5 * 3600 * 1000);
      await a.ledger.renameMember(t.g, t.sam, 'S');
      await b.pull(a, t.g);
      expect(b.ledger.clockSkewDetected, isTrue);
      expect(b.group(t.g).members[t.sam]!.displayName, 'S');
      await b.ledger.renameMember(t.g, t.priya, 'P');
      final mine = b.snap.ops.where((o) => o.deviceId == b.deviceId).single;
      expect(mine.hlc.millis, lessThan(kBaseMs + 3600 * 1000));
      expect(b.snap.ops.last.deviceId, a.deviceId,
          reason: 'the skewed op still sorts last');
    });

    group('applyRemote rejects the whole batch on a bad op', () {
      late ({GroupId g, MemberId me, MemberId sam, MemberId priya}) t;
      late List<Operation> good;

      setUp(() async {
        t = await trip();
        await b.ledger.registerJoinedGroup(
            t.g, (await a.ledger.groupKeys())[t.g]!, 'Goa');
        good = await a.ledger.opsMissingFor(t.g, VersionVector.empty);
      });

      Operation tweak(Operation o,
              {GroupId? groupId, int? counter, Hlc? hlc, Object? payload}) =>
          Operation(
            id: o.id,
            groupId: groupId ?? o.groupId,
            deviceId: o.deviceId,
            counter: counter ?? o.counter,
            hlc: hlc ?? o.hlc,
            entityType: o.entityType,
            entityId: o.entityId,
            kind: o.kind,
            payload: payload == null
                ? o.payload
                : {...o.payload, 'x': payload},
          );

      Future<void> rejected(List<Operation> batch, [GroupId? g]) async {
        await expectLater(b.ledger.applyRemote(g ?? t.g, batch),
            throwsA(isA<FormatException>()));
        expect(b.snap.ops, isEmpty);
        expect(await b.ledger.versionVector(t.g), VersionVector.empty);
        expect(b.snap.pendingJoins, {t.g: 'Goa'});
      }

      test('op for another group', () =>
          rejected([...good.take(2), tweak(good[2], groupId: gB)]));
      test('counter < 1', () => rejected([good[0], tweak(good[1], counter: 0)]));
      test('HLC device differs from the author', () => rejected(
          [good[0], tweak(good[1], hlc: Hlc(good[1].hlc.millis, 0, dC))]));
      test('payload that is not JSON',
          () => rejected([good[0], tweak(good[1], payload: Object())]));
      test('group without a key', () async {
        await expectLater(b.ledger.applyRemote(gB, [rawOp(gB, dC, 1)]),
            throwsA(isA<FormatException>()));
        expect(b.snap.ops, isEmpty);
      });
      test('unknown kind in a current-schema op', () async {
        final bad = Operation(
          id: 'x1',
          groupId: t.g,
          deviceId: dC,
          counter: 1,
          hlc: const Hlc(kBaseMs, 0, dC),
          entityType: EntityType.group,
          entityId: t.g,
          kind: OpKind.update,
          payload: const {},
          raw: {'id': 'x1', 'kind': 'explode', 'schemaVersion': 1},
        );
        await rejected([good[0], bad]);
      });

      test('after a rejection the good batch still applies', () async {
        await rejected([good[0], tweak(good[1], counter: 0)]);
        expect(await b.ledger.applyRemote(t.g, good), hasLength(4));
      });
    });

    test('newer-schema ops are stored and relayed but not applied', () async {
      final t = await trip();
      final future = Operation.fromJson({
        'id': 'future-1',
        'groupId': t.g,
        'deviceId': dC,
        'counter': 1,
        'hlc': const Hlc(kBaseMs + 10, 0, dC).encode(),
        'entityType': 'receipt',
        'entityId': 'r1',
        'kind': 'attach',
        'payload': {'sha': 'x'},
        'schemaVersion': 2,
      });
      final before = a.snap.state.toCanonicalJson();
      expect(await a.ledger.applyRemote(t.g, [future]), [future]);
      expect(a.snap.state.toCanonicalJson(), before);
      expect(a.snap.ops.map((o) => o.id), contains('future-1'));
      final relayed = await a.ledger.opsMissingFor(t.g, VersionVector({a.deviceId: 4}));
      expect(relayed.single.toJson(), future.toJson());
    });

    test('my own ops relayed back after a purge restore my counter',
        () async {
      final t = await trip();
      final key = (await a.ledger.groupKeys())[t.g]!;
      await b.ledger.registerJoinedGroup(t.g, key, 'Goa');
      await b.pull(a, t.g);
      // Simulate a local wipe of the group on A (leave + rejoin).
      await a.ledger.close();
      await a.store.purgeGroup(t.g);
      await a.restart();
      expect(a.snap.state.groups[t.g], isNull);
      expect(a.snap.pendingJoins, {t.g: ''});
      await a.pull(b, t.g);
      await a.ledger.addExpense(draft(t.g, [t.me]));
      expect(a.opsOf(t.g).map((o) => o.counter), [1, 2, 3, 4, 5]);
    });

    test('sync records: stored, newest first, stream emits current first',
        () async {
      await a.ledger.addSyncRecord(record('r1', kBaseMs));
      final seen = <List<String>>[];
      final sub = a.ledger
          .watchSyncRecords()
          .listen((l) => seen.add([for (final r in l) r.id]));
      await pumpEventQueue();
      await a.ledger.addSyncRecord(record('r2', kBaseMs + 10));
      await pumpEventQueue();
      expect(seen, [
        ['r1'],
        ['r2', 'r1'],
      ]);
      expect((await a.store.syncRecords()).map((r) => r.id), ['r2', 'r1']);
      await sub.cancel();
      await a.restart();
      expect((await a.ledger.watchSyncRecords().first).map((r) => r.id),
          ['r2', 'r1']);
    });
  });
}

/// MemoryOpStore whose next insertAll can be made to fail.
final class _FlakyStore implements OpStore {
  final MemoryOpStore _inner = MemoryOpStore();
  bool failNext = false;

  @override
  Future<List<Operation>> insertAll(List<Operation> ops) {
    if (failNext) {
      failNext = false;
      throw StateError('disk full');
    }
    return _inner.insertAll(ops);
  }

  @override
  Future<void> open() => _inner.open();
  @override
  Future<void> close() => _inner.close();
  @override
  Future<List<Operation>> loadAll() => _inner.loadAll();
  @override
  Future<VersionVector> versionVector(GroupId groupId) =>
      _inner.versionVector(groupId);
  @override
  Future<List<Operation>> missingFor(GroupId groupId, VersionVector peer) =>
      _inner.missingFor(groupId, peer);
  @override
  Future<int> maxCounter(GroupId groupId, DeviceId deviceId) =>
      _inner.maxCounter(groupId, deviceId);
  @override
  Future<void> purgeGroup(GroupId groupId) => _inner.purgeGroup(groupId);
  @override
  Future<VersionVector> peerKnowledge(GroupId groupId) =>
      _inner.peerKnowledge(groupId);
  @override
  Future<void> recordPeerKnowledge(
          DeviceId peer, GroupId groupId, VersionVector vv) =>
      _inner.recordPeerKnowledge(peer, groupId, vv);
  @override
  Future<String?> getKv(String key) => _inner.getKv(key);
  @override
  Future<void> setKv(String key, String? value) => _inner.setKv(key, value);
  @override
  Future<void> addSyncRecord(SyncRecord record) => _inner.addSyncRecord(record);
  @override
  Future<List<SyncRecord>> syncRecords({int limit = 50}) =>
      _inner.syncRecords(limit: limit);
}
