import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/activity.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/ops.dart';

import 'helpers.dart';

const g = 'g1';

void main() {
  late FakeDevice alex;
  late FakeDevice priya;
  late List<Operation> ops;

  setUp(() {
    FakeDevice.wallMs = kBaseMs;
    alex = FakeDevice('dev-alex');
    priya = FakeDevice('dev-priya');
    ops = [
      alex.createGroup(g),
      alex.addMember(g, 'a', 'Alex', claimedBy: 'dev-alex'),
      alex.addMember(g, 'b', 'Bob'),
      alex.addMember(g, 'p', 'Priya'),
      alex.addExpense(g, 'e1', money: equalBlock(9000, 'a', ['a', 'b', 'p'])),
    ];
    priya.saw(ops);
  });

  List<ActivityEntry> build(List<Operation> all,
          {Set<String> unshared = const {}, String? groupId}) =>
      ActivityBuilder.build(
        ops: all,
        state: reduce(all).state,
        localDeviceId: 'dev-alex',
        unsharedOpIds: unshared,
        groupId: groupId,
      );

  List<ActivityEntry> history(List<Operation> all, String entityId,
          {String? groupId}) =>
      ActivityBuilder.historyOf(
        ops: all,
        state: reduce(all).state,
        localDeviceId: 'dev-alex',
        unsharedOpIds: const {},
        entityId: entityId,
        groupId: groupId,
      );

  test('kinds for every op type, newest first', () {
    FakeDevice.wallMs += 1000;
    final claim = priya.updateMember(
        g, 'p', {'personId': 'person-priya', 'deviceId': 'dev-priya'});
    alex.saw([claim]);
    final rename = alex.updateMember(g, 'b', {'displayName': 'Bobby'});
    final bob2 = alex.addMember(g, 'b2', 'Bob');
    final merge = alex.mergeMember(g, 'b2', 'b');
    final remove = alex.removeMember(g, 'b2');
    final edit = alex.updateExpense(g, 'e1', {'description': 'Lunch'});
    final del = alex.deleteExpense(g, 'e1');
    final restore = alex.restoreExpense(g, 'e1');
    final pay = alex.addPayment(g, 'pay1', from: 'b', to: 'a', amount: 3000);
    final payEdit = alex.updateExpense(g, 'pay1', {'notes': 'cash'});
    final payDel = alex.deleteExpense(g, 'pay1');
    final payRestore = alex.restoreExpense(g, 'pay1');
    final groupEdit = alex.updateGroup(g, {'name': 'Goa'});
    final hlc = alex.clock.tick();
    final groupDel = alex.op(g, EntityType.group, g, OpKind.delete,
        {'deletedAt': hlc.millis},
        hlc: hlc);
    final all = [
      ...ops,
      claim,
      rename,
      bob2,
      merge,
      remove,
      edit,
      del,
      restore,
      pay,
      payEdit,
      payDel,
      payRestore,
      groupEdit,
      groupDel,
    ]..shuffle();
    final feed = build(all);
    expect(feed.map((e) => e.kind), [
      ActivityKind.groupDeleted,
      ActivityKind.groupEdited,
      ActivityKind.paymentRestored,
      ActivityKind.paymentDeleted,
      ActivityKind.paymentEdited,
      ActivityKind.paymentAdded,
      ActivityKind.expenseRestored,
      ActivityKind.expenseDeleted,
      ActivityKind.expenseEdited,
      ActivityKind.memberRemoved,
      ActivityKind.membersMerged,
      ActivityKind.memberAdded,
      ActivityKind.memberEdited,
      ActivityKind.memberClaimed,
      ActivityKind.expenseAdded,
      ActivityKind.memberAdded,
      ActivityKind.memberAdded,
      ActivityKind.memberAdded,
      ActivityKind.groupCreated,
    ]);
    for (var i = 1; i < feed.length; i++) {
      expect(feed[i - 1].op.hlc > feed[i].op.hlc, isTrue);
    }
    expect(feed.first.at, utcFromHlc(groupDel.hlc));
  });

  test('before/after changes replay earlier ops in HLC order', () {
    final e1 = alex.updateExpense(g, 'e1', {'description': 'Lunch', 'notes': 'n1'});
    final e2 = priya.updateExpense(g, 'e1', {'description': 'Brunch'});
    final hist = history([e2, ...ops.reversed, e1], 'e1');
    expect(hist.map((e) => e.op.id), [ops[4].id, e1.id, e2.id]);

    final create = hist[0];
    expect(create.kind, ActivityKind.expenseAdded);
    expect(create.changes['description']!.before, isNull);
    expect(create.changes['description']!.after, 'Dinner');
    expect(create.changes.keys,
        containsAll(['kind', 'money', 'date', 'createdBy', 'createdAt']));

    expect(hist[1].changes.keys, unorderedEquals(['description', 'notes']));
    expect(hist[1].changes['description']!.before, 'Dinner');
    expect(hist[1].changes['description']!.after, 'Lunch');
    expect(hist[1].changes['notes']!.before, isNull);
    expect(hist[1].changes['notes']!.after, 'n1');
    expect(hist[2].changes['description']!.before, 'Lunch');
    expect(hist[2].changes['description']!.after, 'Brunch');
  });

  test('unchanged re-writes are not listed as changes', () {
    final same = alex.updateExpense(g, 'e1', {'description': 'Dinner', 'notes': 'x'});
    final h = history([...ops, same], 'e1');
    expect(h.last.changes.keys, ['notes']);
  });

  test('supersededBy marks the losing side of a concurrent money edit', () {
    final mine = alex.editMoney(g, 'e1', equalBlock(6000, 'a', ['a', 'b']));
    final hers = priya.editMoney(g, 'e1', equalBlock(7000, 'p', ['a', 'p']));
    final winner = mine.hlc > hers.hlc ? mine : hers;
    final loser = identical(winner, mine) ? hers : mine;
    final feed = build([...ops, mine, hers]);
    final byId = {for (final e in feed) e.op.id: e};
    expect(byId[loser.id]!.supersededBy, winner.id);
    expect(byId[winner.id]!.supersededBy, isNull);
    expect(byId[ops[4].id]!.supersededBy, isNull,
        reason: 'the create was replaced by its own device later');
    expect(reduce([...ops, mine, hers]).state.expense('e1')!.money.toJson(),
        winner.payload['money']);
  });

  test('no supersededBy for sequential edits on one device or equal values',
      () {
    final first = alex.editMoney(g, 'e1', equalBlock(6000, 'a', ['a', 'b']));
    final second = alex.editMoney(g, 'e1', equalBlock(6500, 'a', ['a', 'b']));
    final sameAsWinner = priya.op(g, EntityType.expense, 'e1', OpKind.update,
        {'money': second.payload['money']},
        hlc: Hlc(first.hlc.millis, first.hlc.counter, 'dev-priya'));
    final feed = build([...ops, first, second, sameAsWinner]);
    expect(feed.every((e) => e.supersededBy == null), isTrue);
  });

  test('actor, isLocal and isShared', () {
    final hers = priya.updateExpense(g, 'e1', {'notes': 'from priya'});
    final claim = priya.updateMember(g, 'p', {'deviceId': 'dev-priya'});
    final mine = alex.updateExpense(g, 'e1', {'notes': 'from alex'});
    final feed = build([...ops, hers, mine, claim], unshared: {mine.id});
    final byId = {for (final e in feed) e.op.id: e};
    expect(byId[mine.id]!.actor, 'a');
    expect(byId[mine.id]!.isLocal, isTrue);
    expect(byId[mine.id]!.isShared, isFalse);
    expect(byId[ops[0].id]!.isLocal, isTrue);
    expect(byId[ops[0].id]!.isShared, isTrue);
    expect(byId[hers.id]!.actor, 'p');
    expect(byId[hers.id]!.isLocal, isFalse);
    expect(byId[hers.id]!.isShared, isFalse);
    // Unknown device: no actor.
    final stranger = FakeDevice('dev-stranger')..saw(ops);
    final s = stranger.updateExpense(g, 'e1', {'notes': '?'});
    expect(build([...ops, s]).first.actor, isNull);
  });

  test('actor resolves through merges', () {
    final dup = alex.addMember(g, 'a2', 'Alex again', claimedBy: 'dev-alex');
    final merge = alex.mergeMember(g, 'a', 'a2');
    final edit = alex.updateExpense(g, 'e1', {'notes': 'x'});
    expect(build([...ops, dup, merge, edit]).first.actor, 'a2');
  });

  test('group filter, newer schema skipped, ignored ops skipped', () {
    final other = alex.createGroup('g2', name: 'Other');
    final future = Operation(
      id: 'future',
      groupId: g,
      deviceId: 'dev-alex',
      counter: 50,
      hlc: alex.clock.tick(),
      entityType: EntityType.expense,
      entityId: 'e1',
      kind: OpKind.update,
      payload: const {'notes': 'v2'},
      schemaVersion: kSchemaVersion + 1,
    );
    final badGroupOp = alex.op(g, EntityType.group, 'g2', OpKind.update, {'name': 'x'});
    final reused = priya.addMember('g2', 'a', 'Impostor');
    final all = [...ops, other, future, badGroupOp, reused, ops.first];
    expect(build(all, groupId: g).map((e) => e.op.id),
        ops.reversed.map((o) => o.id));
    // Ids are scoped by group (SECURITY-R1-04): the reused id is g2's own
    // member, listed in g2 only.
    expect(build(all, groupId: 'g2').map((e) => e.op.id),
        [reused.id, other.id]);
    expect(build(all).map((e) => e.op.id),
        [reused.id, other.id, ...ops.reversed.map((o) => o.id)]);
    expect(build(all, groupId: 'none'), isEmpty);
    expect(history(all, 'a', groupId: g).map((e) => e.op.id), [ops[1].id]);
    expect(history(all, 'a', groupId: 'g2').map((e) => e.op.id),
        [reused.id]);
    expect(history(all, 'a').map((e) => e.op.id), [ops[1].id, reused.id]);
  });

  test('history of an unknown entity is empty', () {
    expect(history(ops, 'nope'), isEmpty);
    expect(
        ActivityBuilder.build(
            ops: const [],
            state: LedgerState.empty,
            localDeviceId: 'x',
            unsharedOpIds: const {}),
        isEmpty);
  });
}

DateTime utcFromHlc(Hlc h) =>
    DateTime.fromMillisecondsSinceEpoch(h.millis, isUtc: true);
