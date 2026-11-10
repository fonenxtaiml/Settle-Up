import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/reducer/canonical.dart';
import 'package:settle_up/core/split.dart';

import 'helpers.dart';

const g = 'g1';

void main() {
  late FakeDevice alex;
  late FakeDevice priya;

  setUp(() {
    FakeDevice.wallMs = kBaseMs;
    alex = FakeDevice('dev-alex');
    priya = FakeDevice('dev-priya');
  });

  /// Group with members a, b, c and one 90.00 dinner paid by a. Priya has
  /// synced these ops (her clock has seen them); later edits by both are
  /// concurrent.
  List<Operation> base() {
    final ops = [
      alex.createGroup(g),
      alex.addMember(g, 'a', 'Alex', claimedBy: alex.deviceId),
      alex.addMember(g, 'b', 'Bob'),
      alex.addMember(g, 'c', 'Cat'),
      alex.addExpense(g, 'e1', money: equalBlock(9000, 'a', ['a', 'b', 'c'])),
    ];
    priya.saw(ops);
    return ops;
  }

  group('basics', () {
    test('materializes group, members and expenses from create ops', () {
      final r = reduce(base());
      final gs = r.state.groups[g]!;
      expect(gs.group!.name, 'Trip');
      expect(gs.group!.type, GroupType.trip);
      expect(gs.group!.currency, 'GBP');
      expect(gs.group!.simplifyDebts, isTrue);
      expect(gs.group!.archived, isFalse);
      expect(gs.group!.isDeleted, isFalse);
      expect(gs.members.keys, unorderedEquals(['a', 'b', 'c']));
      expect(gs.members['a']!.deviceId, alex.deviceId);
      expect(gs.members['b']!.isPlaceholder, isTrue);
      final e = gs.expenses['e1']!;
      expect(e.description, 'Dinner');
      expect(e.kind, ExpenseKind.expense);
      expect(e.notes, '');
      expect(e.money.owed, {'a': 3000, 'b': 3000, 'c': 3000});
      expect(e.createdBy, 'a');
      expect(r.state.visibleGroups.map((x) => x.groupId), [g]);
      expect(r.state.expense('e1'), same(e));
      expect(r.state.expense('nope'), isNull);
    });

    test('apply returns true on change, false on re-apply (idempotence)', () {
      final ops = base();
      final r = LedgerReducer();
      for (final op in ops) {
        expect(r.apply(op), isTrue);
      }
      final before = jsonEncode(r.state.toCanonicalJson());
      for (final op in ops) {
        expect(r.apply(op), isFalse);
      }
      expect(r.applyAll(ops), isEmpty);
      expect(jsonEncode(r.state.toCanonicalJson()), before);
    });

    test('an op that loses every field changes nothing visible', () {
      final r = reduce(base());
      final hlc = alex.clock.tick();
      final newer = alex.updateExpense(g, 'e1', {'description': 'New'});
      final older = priya.op(g, EntityType.expense, 'e1', OpKind.update,
          {'description': 'Old'},
          hlc: Hlc(hlc.millis - 1, 0, priya.deviceId));
      expect(r.apply(newer), isTrue);
      final snap = r.state;
      expect(r.apply(older), isFalse);
      expect(identical(r.state, snap), isTrue, reason: 'snapshot reused');
      expect(r.state.expense('e1')!.description, 'New');
    });

    test('applyAll returns ids of changed entities', () {
      final r = LedgerReducer();
      final ops = base();
      expect(r.applyAll(ops), {g, 'a', 'b', 'c', 'e1'});
      final edit = alex.updateExpense(g, 'e1', {'notes': 'n'});
      expect(r.applyAll([edit, edit]), {'e1'});
    });

    test('snapshots are immutable and unaffected by later ops', () {
      final r = reduce(base());
      final snap = r.state;
      r.apply(alex.updateExpense(g, 'e1', {'description': 'Lunch'}));
      r.apply(alex.addMember(g, 'd', 'Dee'));
      expect(snap.expense('e1')!.description, 'Dinner');
      expect(snap.groups[g]!.members.containsKey('d'), isFalse);
      expect(r.state.expense('e1')!.description, 'Lunch');
      expect(() => snap.groups[g]!.members.remove('a'), throwsUnsupportedError);
      expect(() => snap.groups.remove(g), throwsUnsupportedError);
      expect(() => r.state.groups[g]!.expenses.clear(), throwsUnsupportedError);
    });

    test('Expense.updatedHlc is the max HLC of all its ops', () {
      final ops = base();
      final edit = priya.updateExpense(g, 'e1', {'notes': 'x'});
      final r = reduce([...ops, edit]);
      expect(r.state.expense('e1')!.updatedHlc, edit.hlc);
      // An op that loses every field still advances updatedHlc.
      final late = priya.op(g, EntityType.expense, 'e1', OpKind.update, {},
          hlc: Hlc(edit.hlc.millis + 5, 0, priya.deviceId));
      r.apply(late);
      expect(r.state.expense('e1')!.updatedHlc, late.hlc);
    });

    test('createdAt values come from their fields', () {
      final r = reduce([
        alex.createGroup(g, createdAt: 1234),
        alex.addMember(g, 'a', 'A', createdAt: 5678),
      ]);
      expect(r.state.groups[g]!.group!.createdAt, utcFromMillis(1234));
      expect(r.state.groups[g]!.members['a']!.createdAt, utcFromMillis(5678));
    });
  });

  group('conflict table (SPEC 7.2)', () {
    test('A edits the description, B edits the amount: both kept', () {
      final ops = base();
      final a = alex.updateExpense(g, 'e1', {'description': 'Dinner at the shack'});
      final b = priya.editMoney(g, 'e1', equalBlock(12000, 'a', ['a', 'b', 'c']));
      for (final order in [
        [...ops, a, b],
        [...ops, b, a],
        [b, a, ...ops.reversed],
      ]) {
        final e = reduce(order).state.expense('e1')!;
        expect(e.description, 'Dinner at the shack');
        expect(e.money.total, 12000);
      }
    });

    test('A and B both edit the amount/split: higher HLC block wins whole',
        () {
      final ops = base();
      final a = alex.editMoney(g, 'e1', equalBlock(6000, 'a', ['a', 'b']));
      final b = priya.editMoney(
          g,
          'e1',
          SplitCalculator.buildMoneyBlock(
            total: 9900,
            currency: 'EUR',
            paidBy: SplitSpec.equal(['b', 'c']),
            owedBy: SplitSpec.equal(['a', 'b', 'c']),
          ));
      final winner = a.hlc > b.hlc ? a : b;
      for (final order in [
        [...ops, a, b],
        [...ops, b, a],
      ]) {
        final e = reduce(order).state.expense('e1')!;
        expect(e.money.toJson(), winner.payload[ExpenseFields.money]);
        expect(e.money.isConsistent, isTrue);
      }
    });

    test('concurrent money edits never mix (no torn block)', () {
      // Same HLC millis: the device id breaks the tie, and the block from
      // the winning op is taken entirely.
      final ops = base();
      final t = alex.clock.tick().millis + 10;
      final a = alex.op(g, EntityType.expense, 'e1', OpKind.update,
          {'money': equalBlock(500, 'a', ['b']).toJson()},
          hlc: Hlc(t, 0, alex.deviceId));
      final b = priya.op(g, EntityType.expense, 'e1', OpKind.update,
          {'money': equalBlock(700, 'c', ['a', 'b'], currency: 'JPY').toJson()},
          hlc: Hlc(t, 0, priya.deviceId));
      for (final order in [
        [...ops, a, b],
        [...ops, b, a],
      ]) {
        final e = reduce(order).state.expense('e1')!;
        expect(e.money.total, 700);
        expect(e.money.currency, 'JPY');
        expect(e.money.paid, {'c': 700});
      }
    });

    test('edit vs delete: deleted; restore brings back the latest edits', () {
      final ops = base();
      final del = alex.deleteExpense(g, 'e1');
      final edit = priya.updateExpense(g, 'e1', {'description': 'Edited'});
      final r = reduce([...ops, edit, del]);
      expect(r.state.expense('e1')!.isDeleted, isTrue);
      expect(r.state.groups[g]!.liveExpenses, isEmpty);
      final r2 = reduce([del, ...ops, edit]);
      expect(r2.state.expense('e1')!.isDeleted, isTrue);
      expect(r2.state.expense('e1')!.description, 'Edited');

      FakeDevice.wallMs += 1000;
      final restore = alex.restoreExpense(g, 'e1');
      r.apply(restore);
      final e = r.state.expense('e1')!;
      expect(e.isDeleted, isFalse);
      expect(e.description, 'Edited');
      expect(r.state.groups[g]!.liveExpenses.single.id, 'e1');
    });

    test('delete vs later restore: higher HLC on deletedAt wins', () {
      final ops = base();
      final del = alex.deleteExpense(g, 'e1');
      FakeDevice.wallMs += 10;
      final restore = priya.restoreExpense(g, 'e1');
      expect(restore.hlc > del.hlc, isTrue);
      expect(reduce([...ops, restore, del]).state.expense('e1')!.isDeleted,
          isFalse);
      expect(reduce([...ops, del, restore]).state.expense('e1')!.isDeleted,
          isFalse);
      // And a delete that comes after the restore wins again.
      FakeDevice.wallMs += 10;
      final del2 = alex.deleteExpense(g, 'e1');
      expect(
          reduce([del2, ...ops, restore, del]).state.expense('e1')!.isDeleted,
          isTrue);
    });

    test('both add "Bob": two members', () {
      final r = reduce([
        ...base(),
        alex.addMember(g, 'bob-1', 'Bob'),
        priya.addMember(g, 'bob-2', 'Bob'),
      ]);
      final bobs = r.state.groups[g]!.activeMembers
          .where((m) => m.displayName == 'Bob')
          .map((m) => m.id);
      expect(bobs, ['b', 'bob-1', 'bob-2']);
    });

    test('expense referencing a removed member is still counted', () {
      final ops = [...base(), alex.removeMember(g, 'b')];
      final gs = reduce(ops).state.groups[g]!;
      expect(gs.members['b']!.isRemoved, isTrue);
      expect(gs.activeMembers.map((m) => m.id), ['a', 'c']);
      expect(BalanceCalculator.groupNets(gs)['GBP']!['b'], -3000);
    });

    test('two payments for the same debt: both kept', () {
      final ops = [
        ...base(),
        alex.addPayment(g, 'p1', from: 'b', to: 'a', amount: 3000),
        priya.addPayment(g, 'p2', from: 'b', to: 'a', amount: 3000),
      ];
      final gs = reduce(ops).state.groups[g]!;
      expect(gs.liveExpenses.where((e) => e.isPayment).length, 2);
      expect(BalanceCalculator.groupNets(gs)['GBP']!['b'], 3000);
      final p = gs.expenses['p1']!;
      expect(p.payer, 'b');
      expect(p.receiver, 'a');
      expect(p.paymentMethod, PaymentMethod.cash);
      expect(p.category, 'payment');
    });

    test('concurrent merges A->B and B->A resolve to the smaller id', () {
      final ops = [
        ...base(),
        alex.mergeMember(g, 'b', 'c'),
        priya.mergeMember(g, 'c', 'b'),
      ];
      final gs = reduce(ops).state.groups[g]!;
      expect(gs.resolve('b'), 'b');
      expect(gs.resolve('c'), 'b');
      expect(gs.activeMembers.map((m) => m.id), ['a', 'b']);
      expect(BalanceCalculator.groupNets(gs)['GBP'], {'a': 6000, 'b': -6000});
    });
  });

  group('visibility', () {
    test('invisible until the create op arrives', () {
      final create = alex.addExpense(g, 'e9',
          money: equalBlock(100, 'a', ['a']), description: 'Late');
      final edit = alex.updateExpense(g, 'e9', {'description': 'Edited'});
      final r = reduce([edit]);
      expect(r.state.groups[g]!.expenses, isEmpty);
      expect(r.state.groups[g]!.group, isNull);
      expect(r.state.visibleGroups, isEmpty);
      r.apply(create);
      expect(r.state.expense('e9')!.description, 'Edited');
    });

    test('an update cannot create an entity even with all fields', () {
      final full = alex.addExpense(g, 'e9', money: equalBlock(100, 'a', ['a']));
      final asUpdate = alex.updateExpense(g, 'e9', full.payload);
      expect(reduce([asUpdate]).state.groups[g]!.expenses, isEmpty);
    });

    test('a create missing required fields stays invisible until completed',
        () {
      final partial = alex.op(g, EntityType.member, 'm', OpKind.create,
          {MemberFields.displayName: 'Mo', MemberFields.createdAt: 1});
      final r = reduce([partial]);
      expect(r.state.groups[g]!.members, isEmpty);
      r.apply(alex.updateMember(g, 'm', {MemberFields.personId: 'p-m'}));
      expect(r.state.groups[g]!.members['m']!.displayName, 'Mo');
    });

    test('wrong-type fields are treated as absent', () {
      final ops = base();
      final r = reduce(ops);
      // Required field with a wrong type hides the entity.
      r.apply(alex.updateExpense(g, 'e1', {'description': 42}));
      expect(r.state.expense('e1'), isNull);
      r.apply(alex.updateExpense(g, 'e1', {'description': 'Back'}));
      expect(r.state.expense('e1')!.description, 'Back');
      // Optional fields with a wrong type fall back to defaults.
      r.apply(alex.updateExpense(g, 'e1', {
        'notes': 7,
        'deletedAt': 'yesterday',
        'paymentMethod': 3,
      }));
      final e = r.state.expense('e1')!;
      expect(e.notes, '');
      expect(e.isDeleted, isFalse);
      expect(e.paymentMethod, isNull);
      // Doubles are not ints.
      r.apply(alex.updateExpense(g, 'e1', {'date': 1.5}));
      expect(r.state.expense('e1'), isNull);
      r.apply(alex.updateGroup(g, {'simplifyDebts': 'yes'}));
      expect(r.state.groups[g]!.group, isNull);
      expect(r.state.visibleGroups, isEmpty);
      r.apply(alex.updateGroup(g, {'simplifyDebts': false, 'archived': 'no'}));
      expect(r.state.groups[g]!.group!.simplifyDebts, isFalse);
      expect(r.state.groups[g]!.group!.archived, isFalse);
      r.apply(alex.updateMember(g, 'b', {'mergedInto': 5, 'deviceId': true}));
      expect(r.state.groups[g]!.members['b']!.mergedInto, isNull);
      expect(r.state.groups[g]!.members['b']!.deviceId, isNull);
    });

    test('inconsistent or malformed money hides the expense', () {
      final good = equalBlock(900, 'a', ['a', 'b', 'c']).toJson();
      final bad = <Map<String, Object?>>[
        {...good, 'total': 901},
        {...good, 'paid': {'a': 800}},
        {...good, 'owed': {'a': 1000, 'b': -100}},
        {...good, 'owed': {'a': 900.0}},
        {...good, 'currency': ''},
        {...good, 'total': 0, 'paid': {}, 'owed': {}},
        Map.of(good)..remove('paidBy'),
        {...good, 'paid': 'lots'},
      ];
      for (final money in bad) {
        final r = reduce(base());
        r.apply(alex.updateExpense(g, 'e1', {'money': money}));
        expect(r.state.expense('e1'), isNull, reason: '$money');
      }
      final r = reduce(base());
      r.apply(alex.updateExpense(g, 'e1', {'money': 'nope'}));
      expect(r.state.expense('e1'), isNull);
    });

    test('unknown fields are kept and ignored', () {
      final r = reduce([
        ...base(),
        alex.updateExpense(g, 'e1', {'receiptSha': 'abc', 'notes': 'n'}),
      ]);
      expect(r.state.expense('e1')!.notes, 'n');
    });

    test('unknown enum names fall back', () {
      final r = reduce([
        alex.createGroup(g, extra: {'type': 'festival'}),
      ]);
      expect(r.state.groups[g]!.group!.type, GroupType.other);
    });

    test('newer schema ops are skipped', () {
      final r = reduce(base());
      final newer = Operation(
        id: 'future',
        groupId: g,
        deviceId: alex.deviceId,
        counter: 99,
        hlc: alex.clock.tick(),
        entityType: EntityType.expense,
        entityId: 'e1',
        kind: OpKind.update,
        payload: const {'description': 'From the future'},
        schemaVersion: kSchemaVersion + 1,
      );
      expect(r.apply(newer), isFalse);
      expect(r.state.expense('e1')!.description, 'Dinner');
    });

    test('group op with entityId != groupId is ignored', () {
      final r = LedgerReducer();
      final op = alex.op(g, EntityType.group, 'other', OpKind.create,
          alex.createGroup('other').payload);
      expect(r.apply(op), isFalse);
      expect(r.state.groups, isEmpty);
    });

    test('an entity id in two groups is a separate entity in each', () {
      final first = alex.addMember('g1', 'm', 'In g1');
      final second = priya.addMember('g2', 'm', 'In g2');
      for (final order in [
        [first, second],
        [second, first],
      ]) {
        final s = reduce(order).state;
        expect(s.groups['g1']!.members['m']!.displayName, 'In g1');
        expect(s.groups['g2']!.members['m']!.displayName, 'In g2');
      }
    });

    test('an earlier-HLC create in another group leaves the entity where it '
        'is (order independent)', () {
      final early = priya.op('g2', EntityType.expense, 'x', OpKind.create,
          alex.addExpense('g2', 'tmp', money: equalBlock(1, 'a', ['a'])).payload,
          hlc: const Hlc(10, 0, 'dev-priya'));
      final late = alex.addExpense('g1', 'x', money: equalBlock(5, 'a', ['a']));
      for (final order in [
        [late, early],
        [early, late],
      ]) {
        final s = reduce(order).state;
        expect(s.groups['g1']!.expenses['x']!.money.total, 5);
        expect(s.groups['g2']!.expenses['x']!.money.total, 1);
      }
    });
  });

  group('entity ownership across groups (SECURITY-R1-04)', () {
    test('an earlier-stamped update in another group does not move an '
        'expense out of the group that created it', () {
      final created =
          alex.addExpense('g1', 'x', money: equalBlock(5, 'a', ['a']));
      final forged = priya.op('g2', EntityType.expense, 'x', OpKind.update,
          {ExpenseFields.description: 'Hidden'},
          hlc: const Hlc(1, 0, 'dev-priya'));
      for (final order in [
        [created, forged],
        [forged, created],
      ]) {
        final s = reduce(order).state;
        expect(s.groups['g1']!.expenses['x']!.money.total, 5);
        expect(s.groups['g1']!.expenses['x']!.description,
            isNot('Hidden'));
        expect(s.groups['g2']!.expenses, isEmpty);
      }
    });

    test('the same holds for members and for deletes', () {
      final created = alex.addMember('g1', 'm', 'In g1');
      final forged = priya.op('g2', EntityType.member, 'm', OpKind.delete,
          {MemberFields.deletedAt: 1},
          hlc: const Hlc(1, 0, 'dev-priya'));
      for (final order in [
        [created, forged],
        [forged, created],
      ]) {
        final s = reduce(order).state;
        expect(s.groups['g1']!.members['m']!.displayName, 'In g1');
      }
    });

    test('a create beats earlier updates elsewhere, whatever the order', () {
      final a = alex.op('g1', EntityType.expense, 'x', OpKind.update,
          {ExpenseFields.description: 'a'},
          hlc: const Hlc(20, 0, 'dev-alex'));
      final b = priya.op('g2', EntityType.expense, 'x', OpKind.update,
          {ExpenseFields.description: 'b'},
          hlc: const Hlc(10, 0, 'dev-priya'));
      final create = alex.addExpense('g1', 'x',
          money: equalBlock(5, 'a', ['a']));
      for (final order in [
        [a, b, create],
        [create, b, a],
        [b, create, a],
      ]) {
        final s = reduce(order).state;
        expect(s.groups['g1']!.expenses['x'], isNotNull,
            reason: 'the create in g1 claims it');
        expect(s.groups['g2']!.expenses, isEmpty);
      }
    });

    // Round 2: ids are scoped by group, so even a forged create with an
    // older HLC elsewhere leaves the entity of its own group untouched.
    test('a forged earlier create in another group cannot hide or change an '
        'expense of its own group', () {
      final members = [
        alex.addMember('g1', 'a', 'Alex'),
        alex.addMember('g1', 'b', 'Bob'),
      ];
      final created = alex.addExpense('g1', 'x',
          description: 'Rent', money: equalBlock(600, 'a', ['a', 'b']));
      final forged = priya.op('g2', EntityType.expense, 'x', OpKind.create,
          priya.addExpense('g2', 'tmp',
                  description: 'Forged', money: equalBlock(1, 'z', ['z']))
              .payload,
          hlc: const Hlc(1, 0, 'dev-priya'));
      final honest = reduce([...members, created]).state;
      for (final order in [
        [...members, created, forged],
        [forged, ...members, created],
        [created, forged, ...members],
      ]) {
        final s = reduce(order).state;
        final x = s.groups['g1']!.expenses['x']!;
        expect(x.description, 'Rent');
        expect(x.money.total, 600);
        expect(BalanceCalculator.groupNets(s.groups['g1']!),
            BalanceCalculator.groupNets(honest.groups['g1']!));
        expect(jsonEncode(groupStateToJson(s.groups['g1']!)),
            jsonEncode(groupStateToJson(honest.groups['g1']!)));
        // g2 only sees its own (forged) entity.
        expect(s.expenseIn('g2', 'x')!.description, 'Forged');
        expect(s.expenseIn('g1', 'x')!.description, 'Rent');
        expect(s.expense('x')!.groupId, 'g1', reason: 'lowest group id');
      }
    });

    test('a forged earlier member create in another group cannot hide a '
        'member of its own group', () {
      final created = alex.addMember('g1', 'm', 'Priya');
      final forged = priya.op('g2', EntityType.member, 'm', OpKind.create,
          priya.addMember('g2', 'tmp', 'Mallory').payload,
          hlc: const Hlc(1, 0, 'dev-priya'));
      for (final order in [
        [created, forged],
        [forged, created],
      ]) {
        final s = reduce(order).state;
        expect(s.groups['g1']!.members['m']!.displayName, 'Priya');
        expect(s.groups['g2']!.members['m']!.displayName, 'Mallory');
      }
    });

    test('an edit in one group never reaches the same id in another', () {
      final a = alex.addExpense('g1', 'x',
          description: 'One', money: equalBlock(5, 'a', ['a']));
      final b = priya.addExpense('g2', 'x',
          description: 'Two', money: equalBlock(7, 'a', ['a']));
      final edit = priya.op('g2', EntityType.expense, 'x', OpKind.update,
          {ExpenseFields.description: 'Edited', ExpenseFields.deletedAt: 9});
      final s = reduce([a, b, edit]).state;
      expect(s.groups['g1']!.expenses['x']!.description, 'One');
      expect(s.groups['g1']!.expenses['x']!.isDeleted, isFalse);
      expect(s.groups['g2']!.expenses['x']!.description, 'Edited');
    });
  });

  group('group lifecycle', () {
    test('delete group tombstones it; members/expenses stay', () {
      final r = reduce(base());
      final hlc = alex.clock.tick();
      r.apply(alex.op(g, EntityType.group, g, OpKind.delete,
          {GroupFields.deletedAt: hlc.millis},
          hlc: hlc));
      expect(r.state.groups[g]!.group!.isDeleted, isTrue);
      expect(r.state.visibleGroups, isEmpty);
      expect(r.state.groups[g]!.expenses, isNotEmpty);
    });

    test('archive and emoji edits', () {
      final r = reduce([
        ...base(),
        alex.updateGroup(g, {'archived': true, 'emoji': '🏖'}),
      ]);
      expect(r.state.groups[g]!.group!.archived, isTrue);
      expect(r.state.groups[g]!.group!.emoji, '🏖');
    });
  });

  group('GroupState queries', () {
    test('activeMembers: not removed, not merged, sorted by name then id', () {
      final gs = groupOf([
        member('z1', name: 'bob'),
        member('a9', name: 'Bob'),
        member('k', name: 'alice'),
        member('m', name: 'Zed', removed: true),
        member('n', name: 'Ann', mergedInto: 'k'),
        member('a1', name: 'Bob'),
      ], []);
      expect(gs.activeMembers.map((m) => m.id), ['k', 'a1', 'a9', 'z1']);
    });

    test('resolve follows chains, handles cycles and missing targets', () {
      final gs = groupOf([
        member('a'),
        member('b', mergedInto: 'c'),
        member('c', mergedInto: 'd'),
        member('d'),
        member('x', mergedInto: 'y'),
        member('y', mergedInto: 'w'),
        member('w', mergedInto: 'x'),
        member('t', mergedInto: 'y'),
        member('self', mergedInto: 'self'),
        member('lost', mergedInto: 'nobody'),
        member('l2', mergedInto: 'lost'),
      ], []);
      expect(gs.resolve('a'), 'a');
      expect(gs.resolve('b'), 'd');
      expect(gs.resolve('c'), 'd');
      expect(gs.resolve('x'), 'w');
      expect(gs.resolve('y'), 'w');
      expect(gs.resolve('w'), 'w');
      expect(gs.resolve('t'), 'w', reason: 'tail into a cycle');
      expect(gs.resolve('self'), 'self');
      expect(gs.resolve('lost'), 'lost');
      expect(gs.resolve('l2'), 'lost');
      expect(gs.resolve('unknown'), 'unknown');
      expect(gs.activeMembers.map((m) => m.id),
          containsAll(['a', 'd', 'w', 'self', 'lost']));
      expect(gs.activeMembers.map((m) => m.id),
          isNot(anyElement(isIn(['b', 'c', 'x', 'y', 't', 'l2']))));
    });

    test('memberForPerson prefers active members', () {
      final gs = groupOf([
        member('a', personId: 'p', removed: true),
        member('b', personId: 'p', mergedInto: 'c'),
        member('c', personId: 'q'),
        member('d', personId: 'p'),
        member('e', personId: 'p'),
      ], []);
      expect(gs.memberForPerson('p')!.id, 'd');
      expect(gs.memberForPerson('q')!.id, 'c');
      expect(gs.memberForPerson('nobody'), isNull);
      final gs2 = groupOf([
        member('a', personId: 'p', removed: true),
        member('b', personId: 'p', mergedInto: 'c'),
        member('c'),
      ], []);
      expect(gs2.memberForPerson('p')!.id, 'b');
    });

    test('liveExpenses: newest date first, ties by id descending', () {
      final block = equalBlock(100, 'a', ['a']);
      final gs = groupOf([member('a')], [
        expense(block, id: 'e1', date: 1000),
        expense(block, id: 'e2', date: 3000),
        expense(block, id: 'e3', date: 3000),
        expense(block, id: 'e4', date: 2000, deleted: true),
        expense(rawBlock({'a': 5}, {'a': 4}), id: 'e5', date: 9000),
        expense(block, id: 'e6', date: 500, kind: ExpenseKind.payment),
      ]);
      expect(gs.liveExpenses.map((e) => e.id), ['e3', 'e2', 'e1', 'e6']);
    });
  });

  group('canonical JSON', () {
    test('key-sorted at every level and JSON-encodable', () {
      final r = reduce([
        ...base(),
        alex.addPayment(g, 'p1', from: 'b', to: 'a', amount: 10),
      ]);
      final json = r.state.toCanonicalJson();
      void checkSorted(Object? v) {
        if (v is Map) {
          final keys = v.keys.cast<String>().toList();
          expect(keys, orderedEquals([...keys]..sort()));
          v.values.forEach(checkSorted);
        } else if (v is List) {
          v.forEach(checkSorted);
        }
      }

      checkSorted(json);
      final decoded = jsonDecode(jsonEncode(json));
      expect(decoded, json);
      final groupJson = (json['groups']! as Map)[g] as Map;
      expect((groupJson['expenses'] as Map).keys, ['e1', 'p1']);
      expect(((groupJson['expenses'] as Map)['e1'] as Map)['updatedHlc'],
          isA<String>());
    });

    test('includes tombstones and differs when state differs', () {
      final ops = base();
      final del = alex.deleteExpense(g, 'e1');
      final a = reduce(ops).state.toCanonicalJson();
      final b = reduce([...ops, del]).state.toCanonicalJson();
      expect(jsonEncode(a) == jsonEncode(b), isFalse);
      final e = (((b['groups']! as Map)[g] as Map)['expenses'] as Map)['e1'];
      expect((e as Map)['deletedAt'], del.hlc.millis);
    });

    test('empty state', () {
      expect(LedgerState.empty.toCanonicalJson(), {'groups': <String, Object?>{}});
      expect(LedgerReducer().state.groups, isEmpty);
    });
  });
}
