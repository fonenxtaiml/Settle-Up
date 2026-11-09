import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/split.dart';

import 'helpers.dart';

const me = 'p-me';

Map<String, int> _sumMaps(Iterable<Map<String, int>> maps) {
  final out = <String, int>{};
  for (final m in maps) {
    m.forEach((k, v) => out[k] = (out[k] ?? 0) + v);
  }
  out.removeWhere((_, v) => v == 0);
  return out;
}

void _expectConsistent(LedgerState state) {
  final overall = Summaries.overall(state, me);
  final people = Summaries.people(state, me);
  expect(overall.net,
      _sumMaps(state.visibleGroups.map((g) => Summaries.myNetInGroup(g, me))),
      reason: 'overall.net == sum of myNetInGroup');
  expect(overall.net, _sumMaps(people.map((p) => p.net)));
  overall.owedToMe.forEach((c, v) => expect(v, greaterThan(0)));
  overall.iOwe.forEach((c, v) => expect(v, greaterThan(0)));
  for (final c in {...overall.owedToMe.keys, ...overall.iOwe.keys}) {
    expect((overall.owedToMe[c] ?? 0) - (overall.iOwe[c] ?? 0),
        overall.net[c] ?? 0);
  }
  for (final p in people) {
    expect(p.personId, isNot(me));
  }
}

void main() {
  // Trip: me (m), Priya (p), Sam (s). Flat: me (m2), Priya (p2).
  // Direct with Sam.
  GroupState trip({bool simplify = true}) => groupOf(
        [
          member('m', name: 'Me', personId: me),
          member('p', name: 'Priya', personId: 'p-priya', createdAt: kBaseMs),
          member('s', name: 'Sam', personId: 'p-sam'),
        ],
        [
          expense(equalBlock(9000, 'm', ['m', 'p', 's']), id: 't1'),
          expense(equalBlock(3000, 'p', ['m', 'p']), id: 't2', date: kBaseMs + 5),
        ],
        simplify: simplify,
        id: 'trip',
      );
  GroupState flat() => groupOf(
        [
          member('m2', name: 'Me', personId: me, groupId: 'flat'),
          member('p2',
              name: 'Priya S',
              personId: 'p-priya',
              createdAt: kBaseMs + 1000,
              groupId: 'flat'),
          member('r2', name: 'Ravi', personId: 'p-ravi', groupId: 'flat'),
        ],
        [
          expense(equalBlock(2000, 'p2', ['m2', 'p2']),
              id: 'f1', groupId: 'flat'),
          expense(equalBlock(500, 'm2', ['m2', 'p2'], currency: 'EUR'),
              id: 'f2', groupId: 'flat'),
        ],
        id: 'flat',
      );
  GroupState direct() => groupOf(
        [
          member('m3', personId: me, groupId: 'd'),
          member('s3', name: 'Sammy', personId: 'p-sam', groupId: 'd'),
        ],
        [expense(equalBlock(400, 's3', ['m3']), id: 'd1', groupId: 'd')],
        type: GroupType.direct,
        id: 'd',
      );
  GroupState notMine() => groupOf(
        [member('x', personId: 'p-x'), member('y', personId: 'p-y')],
        [expense(equalBlock(100, 'x', ['y']), id: 'n1', groupId: 'other')],
        id: 'other',
      );

  LedgerState state([List<GroupState>? groups]) => LedgerState({
        for (final g in groups ?? [trip(), flat(), direct(), notMine()])
          g.groupId: g,
      });

  test('myNetInGroup', () {
    expect(Summaries.myNetInGroup(trip(), me), {'GBP': 4500});
    expect(Summaries.myNetInGroup(flat(), me), {'EUR': 250, 'GBP': -1000});
    expect(Summaries.myNetInGroup(direct(), me), {'GBP': -400});
    expect(Summaries.myNetInGroup(notMine(), me), isEmpty);
  });

  test('me merged into another member: my net follows the merge', () {
    final g = groupOf([
      member('old', personId: me, mergedInto: 'new'),
      member('new', personId: 'p-other'),
      member('b'),
    ], [
      expense(equalBlock(100, 'old', ['b'])),
    ]);
    expect(Summaries.myNetInGroup(g, me), {'GBP': 100});
  });

  test('people aggregates across groups, direct included', () {
    final people = Summaries.people(state(), me);
    final byId = {for (final p in people) p.personId: p};
    // Trip (simplified): Priya pays me 1500. Flat (pairwise): I owe her
    // 1000 GBP, she owes me 250 EUR.
    expect(byId['p-priya']!.net, {'EUR': 250, 'GBP': 1500 - 1000});
    expect(byId['p-priya']!.groupIds, ['flat', 'trip']);
    expect(byId['p-priya']!.displayName, 'Priya S',
        reason: 'most recently created member name');
    expect(byId['p-sam']!.net, {'GBP': 3000 - 400});
    expect(byId['p-sam']!.groupIds, ['d', 'trip']);
    expect(byId['p-ravi']!.net, isEmpty);
    expect(byId['p-ravi']!.isSettled, isTrue);
    expect(byId['p-ravi']!.groupIds, ['flat']);
    expect(byId.containsKey('p-x'), isFalse, reason: 'not my group');
    expect(byId.containsKey(me), isFalse);
    // Unsettled first, then by display name.
    expect(people.map((p) => p.personId), ['p-priya', 'p-sam', 'p-ravi']);
    _expectConsistent(state());
  });

  test('overall', () {
    final o = Summaries.overall(state(), me);
    expect(o.owedToMe, {'EUR': 250, 'GBP': 500 + 2600});
    expect(o.iOwe, isEmpty);
    expect(o.net, {'EUR': 250, 'GBP': 3100});
    // A person I owe in one currency and who owes me in another counts on
    // both sides.
    final s2 = state([flat()]);
    final o2 = Summaries.overall(s2, me);
    expect(o2.owedToMe, {'EUR': 250});
    expect(o2.iOwe, {'GBP': 1000});
    expect(o2.net, {'EUR': 250, 'GBP': -1000});
    expect(Summaries.overall(LedgerState.empty, me).net, isEmpty);
  });

  test('me not a member anywhere', () {
    final s = state([notMine()]);
    expect(Summaries.people(s, me), isEmpty);
    expect(Summaries.overall(s, me).net, isEmpty);
    final groups = Summaries.groups(s, me);
    expect(groups.single.myMemberId, isNull);
    expect(groups.single.myNet, isEmpty);
    expect(groups.single.isSettled, isTrue);
  });

  test('groups: non-direct visible only, unsettled first, then recent', () {
    final settled = groupOf(
      [member('m4', personId: me, groupId: 'z')],
      [expense(equalBlock(100, 'm4', ['m4']), id: 'z1', date: kBaseMs + 99999)],
      id: 'z',
    );
    final deleted = GroupState(
      groupId: 'del',
      group: Group(
        id: 'del',
        name: 'Gone',
        type: GroupType.home,
        currency: 'GBP',
        simplifyDebts: true,
        createdAt: utcFromMillis(kBaseMs),
        deletedAt: utcFromMillis(kBaseMs + 1),
      ),
      members: const {},
      expenses: const {},
    );
    const pending = GroupState(
        groupId: 'pending', group: null, members: {}, expenses: {});
    final s = state([trip(), flat(), direct(), settled, deleted, pending]);
    final out = Summaries.groups(s, me);
    expect(out.map((x) => x.group.groupId), ['trip', 'flat', 'z']);
    final t = out.first;
    expect(t.myMemberId, 'm');
    expect(t.memberCount, 3);
    expect(t.myNet, {'GBP': 4500});
    expect(t.isSettled, isFalse);
    expect(t.lastActivityAt, utcFromMillis(kBaseMs + 5));
    expect(out.last.isSettled, isTrue);
    final empty = groupOf([member('m5', personId: me)], [], id: 'e');
    expect(Summaries.groups(state([empty]), me).single.lastActivityAt,
        empty.group!.createdAt);
  });

  test('pairwise groups give the same totals as simplified ones', () {
    final a = state([trip(simplify: true), flat(), direct()]);
    final b = state([trip(simplify: false), flat(), direct()]);
    expect(Summaries.overall(a, me).net, Summaries.overall(b, me).net);
    _expectConsistent(b);
  });

  test('property: overall.net == sum of myNetInGroup for random ledgers', () {
    final rnd = math.Random(5);
    for (var i = 0; i < 300; i++) {
      final groups = <GroupState>[];
      for (var gi = 0; gi < 1 + rnd.nextInt(4); gi++) {
        final gid = 'g$gi';
        final ids = [for (var k = 0; k < 2 + rnd.nextInt(5); k++) '$gid-m$k'];
        final persons = ['p-a', 'p-b', 'p-c', 'p-d', 'p-e'];
        final members = <Member>[
          for (var k = 0; k < ids.length; k++)
            member(ids[k],
                groupId: gid,
                personId: k == 0 && rnd.nextInt(4) != 0
                    ? me
                    : persons[rnd.nextInt(persons.length)],
                mergedInto: k > 1 && rnd.nextInt(6) == 0 ? ids[1] : null,
                removed: k > 0 && rnd.nextInt(8) == 0),
        ];
        final expenses = <Expense>[
          for (var k = 0; k < rnd.nextInt(8); k++)
            expense(
              SplitCalculator.buildMoneyBlock(
                total: 1 + rnd.nextInt(10000),
                currency: ['GBP', 'EUR', 'JPY'][rnd.nextInt(3)],
                paidBy: SplitSpec.equal(
                    (List.of(ids)..shuffle(rnd)).take(1 + rnd.nextInt(2))),
                owedBy: SplitSpec.equal(
                    (List.of(ids)..shuffle(rnd)).take(1 + rnd.nextInt(ids.length))),
              ),
              id: '$gid-e$k',
              groupId: gid,
            ),
        ];
        groups.add(groupOf(members, expenses,
            id: gid,
            simplify: rnd.nextBool(),
            type: rnd.nextInt(4) == 0 ? GroupType.direct : GroupType.trip));
      }
      final s = state(groups);
      // Members sharing my personId besides my chosen one would make me
      // owe myself; the generator avoids that by giving only member 0 my id.
      _expectConsistent(s);
    }
  });
}
