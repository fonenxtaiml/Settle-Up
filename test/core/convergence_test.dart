// The key property test (SPEC 11.1): replicas that hold the same op SET
// materialize the same state, whatever the order or duplication.
//
// Three simulated devices, each with its own HlcClock and clock skew (one
// of them sometimes beyond the 1 h skew guard), author 300 ops against
// their own local replica, syncing with each other now and then. So edits
// are often concurrent: two devices editing the same expense's money, an
// edit racing a delete, merges racing each other into cycles, removals of
// members that new expenses still use. A few hostile or malformed ops are
// mixed in. Then:
//   - replica A applies every op one at a time in a random order;
//   - replica B applies them in another random order with 20% duplicates,
//     in random-size applyAll batches, reading snapshots in between;
//   - every device does a final full sync.
// All of them must produce deeply equal canonical JSON, equal group nets
// and equal suggested transfers, and the result must match a naive
// last-writer-wins oracle. Repeated for 200 seeds.
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/activity.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/split.dart';

import 'helpers.dart';

const int kSeeds = 200;
const int kOpsPerSeed = 300;
const List<String> kCurrencies = ['GBP', 'EUR', 'JPY', 'KWD'];

final class _Sim {
  _Sim(this.rnd) {
    FakeDevice.wallMs = kBaseMs + rnd.nextInt(1 << 30);
    devices = [
      FakeDevice('dev-0'),
      FakeDevice('dev-1', skewMs: -rnd.nextInt(10 * 60 * 1000)),
      // Sometimes beyond the skew guard (1 h), sometimes within it.
      FakeDevice('dev-2',
          skewMs: rnd.nextBool()
              ? 2 * HlcClock.maxForwardDriftMs
              : rnd.nextInt(30 * 60 * 1000)),
    ];
    replicas = [for (final _ in devices) LedgerReducer()];
    known = [for (final _ in devices) <String, Operation>{}];
  }

  final math.Random rnd;
  late final List<FakeDevice> devices;
  late final List<LedgerReducer> replicas;
  late final List<Map<String, Operation>> known;
  final List<Operation> all = [];
  int _seq = 0;
  int weird = 0;

  String newId(int d, String kind) => 'd$d-$kind-${++_seq}';

  void emit(int d, Operation op) {
    all.add(op);
    known[d][op.id] = op;
    replicas[d].apply(op);
  }

  void syncPair(int a, int b) {
    final toB = [
      for (final op in known[a].values)
        if (!known[b].containsKey(op.id)) op,
    ];
    final toA = [
      for (final op in known[b].values)
        if (!known[a].containsKey(op.id)) op,
    ];
    for (final op in toB) {
      known[b][op.id] = op;
    }
    for (final op in toA) {
      known[a][op.id] = op;
    }
    replicas[b].applyAll(toB);
    replicas[a].applyAll(toA);
    devices[b].saw(toB);
    devices[a].saw(toA);
  }

  void run() {
    // Device 0 creates the first group and its people.
    const g1 = 'group-1';
    emit(0, devices[0].createGroup(g1, simplify: rnd.nextBool()));
    for (final name in ['Alex', 'Priya', 'Sam']) {
      emit(0, devices[0].addMember(g1, newId(0, 'm'), name,
          personId: 'person-$name',
          claimedBy: name == 'Alex' ? 'dev-0' : null));
    }
    while (all.length < kOpsPerSeed) {
      FakeDevice.wallMs += rnd.nextInt(3) == 0 ? rnd.nextInt(600000) : rnd.nextInt(2000);
      if (rnd.nextInt(8) == 0) {
        final a = rnd.nextInt(3);
        final b = (a + 1 + rnd.nextInt(2)) % 3;
        syncPair(a, b);
        continue;
      }
      final d = rnd.nextInt(3);
      if (all.length > 60 &&
          rnd.nextInt(200) == 0 &&
          !replicas[d].state.groups.containsKey('group-$d-x')) {
        final g = 'group-$d-x';
        emit(d, devices[d].createGroup(g, name: 'Second', currency: 'EUR'));
        emit(d, devices[d].addMember(g, newId(d, 'm'), 'Me $d',
            personId: 'person-dev-$d', claimedBy: 'dev-$d'));
        continue;
      }
      if (rnd.nextInt(30) == 0) {
        _weirdOp(d);
        continue;
      }
      _action(d);
    }
    expect(all.length, greaterThanOrEqualTo(kOpsPerSeed));
  }

  void _action(int d) {
    final dev = devices[d];
    final groups = replicas[d].state.visibleGroups.toList()
      ..sort((a, b) => a.groupId.compareTo(b.groupId));
    if (groups.isEmpty) {
      // Has not synced yet: pull from a peer next time.
      syncPair(d, (d + 1 + rnd.nextInt(2)) % 3);
      return;
    }
    final gs = groups[rnd.nextInt(groups.length)];
    final g = gs.groupId;
    final active = gs.activeMembers.map((m) => m.id).toList();
    final allMembers = gs.members.keys.toList()..sort();
    final expenses = gs.expenses.keys.toList()..sort();
    final roll = rnd.nextInt(100);

    if (roll < 8 || active.length < 2) {
      final names = ['Bob', 'Cat', 'Dee', 'Eli', 'Priya', 'Sam'];
      emit(d, dev.addMember(g, newId(d, 'm'), names[rnd.nextInt(names.length)]));
    } else if (roll < 35) {
      final payment = rnd.nextInt(6) == 0;
      final users = List.of(active);
      if (allMembers.length > active.length && rnd.nextInt(5) == 0) {
        users.add(allMembers[rnd.nextInt(allMembers.length)]);
      }
      if (payment) {
        users.shuffle(rnd);
        emit(
            d,
            dev.addPayment(g, newId(d, 'e'),
                from: users[0],
                to: users[1],
                amount: 1 + rnd.nextInt(50000),
                currency: _currency()));
      } else {
        emit(
            d,
            dev.addExpense(g, newId(d, 'e'),
                money: _block(users),
                description: 'Expense ${rnd.nextInt(1000)}',
                createdBy: users.first,
                notes: rnd.nextBool() ? 'note' : null));
      }
    } else if (roll < 50 && expenses.isNotEmpty) {
      final e = expenses[rnd.nextInt(expenses.length)];
      emit(d, dev.editMoney(g, e, _block(active)));
    } else if (roll < 62 && expenses.isNotEmpty) {
      final e = expenses[rnd.nextInt(expenses.length)];
      final fields = <String, Object?>{
        if (rnd.nextBool()) ExpenseFields.description: 'Edited ${rnd.nextInt(99)}',
        if (rnd.nextBool()) ExpenseFields.notes: 'n${rnd.nextInt(99)}',
        if (rnd.nextInt(3) == 0) ExpenseFields.category: 'transport.taxi',
        if (rnd.nextInt(3) == 0)
          ExpenseFields.date: FakeDevice.wallMs - rnd.nextInt(86400000),
      };
      emit(d, dev.updateExpense(g, e, fields));
    } else if (roll < 72 && expenses.isNotEmpty) {
      final e = expenses[rnd.nextInt(expenses.length)];
      emit(
          d,
          gs.expenses[e]!.isDeleted && rnd.nextInt(3) != 0
              ? dev.restoreExpense(g, e)
              : dev.deleteExpense(g, e));
    } else if (roll < 78 && allMembers.length >= 2) {
      final from = allMembers[rnd.nextInt(allMembers.length)];
      final into = allMembers[rnd.nextInt(allMembers.length)];
      if (from != into) emit(d, dev.mergeMember(g, from, into));
    } else if (roll < 82 && active.length > 2) {
      emit(d, dev.removeMember(g, active[rnd.nextInt(active.length)]));
    } else if (roll < 86 && allMembers.isNotEmpty) {
      final m = allMembers[rnd.nextInt(allMembers.length)];
      emit(
          d,
          rnd.nextBool()
              ? dev.updateMember(g, m, {
                  MemberFields.personId: 'person-dev-$d',
                  MemberFields.deviceId: 'dev-$d',
                })
              : dev.updateMember(
                  g, m, {MemberFields.displayName: 'Renamed ${rnd.nextInt(9)}'}));
    } else if (roll < 88 && allMembers.isNotEmpty) {
      // Restore a removed member.
      final m = allMembers[rnd.nextInt(allMembers.length)];
      emit(
          d,
          dev.op(g, EntityType.member, m, OpKind.restore,
              {MemberFields.deletedAt: null}));
    } else if (roll < 95) {
      emit(
          d,
          dev.updateGroup(g, {
            if (rnd.nextBool()) GroupFields.name: 'Trip ${rnd.nextInt(9)}',
            if (rnd.nextBool()) GroupFields.simplifyDebts: rnd.nextBool(),
            if (rnd.nextInt(3) == 0) GroupFields.archived: rnd.nextBool(),
            if (rnd.nextInt(4) == 0) GroupFields.emoji: rnd.nextBool() ? '🏖' : null,
            if (rnd.nextInt(4) == 0) GroupFields.currency: _currency(),
          }));
    } else if (roll < 97) {
      final hlc = dev.clock.tick();
      emit(
          d,
          dev.op(g, EntityType.group, g, OpKind.delete,
              {GroupFields.deletedAt: hlc.millis},
              hlc: hlc));
    } else {
      emit(
          d,
          dev.op(g, EntityType.group, g, OpKind.restore,
              {GroupFields.deletedAt: null}));
    }
  }

  /// Malformed, hostile or future ops that must not break convergence.
  void _weirdOp(int d) {
    weird++;
    final dev = devices[d];
    final groups = (replicas[d].state.groups.keys.toList()..sort());
    final g = groups.isEmpty ? 'group-1' : groups[rnd.nextInt(groups.length)];
    final expenses = replicas[d].state.groups[g]?.expenses.keys.toList() ?? []
      ..sort();
    final e = expenses.isEmpty ? newId(d, 'e') : expenses[rnd.nextInt(expenses.length)];
    switch (rnd.nextInt(9)) {
      case 0: // wrong JSON type on a required field
        emit(d, dev.updateExpense(g, e, {ExpenseFields.description: 42}));
      case 1: // unknown field (forward compatibility)
        emit(d, dev.updateExpense(g, e, {'receipt': {'sha': 'abc'}}));
      case 2: // inconsistent money block
        emit(
            d,
            dev.updateExpense(g, e, {
              ExpenseFields.money: rawBlock({'x': 10}, {'y': 9}).toJson(),
            }));
      case 3: // update for an entity that is never created
        emit(d, dev.updateExpense(g, newId(d, 'orphan'), {'notes': 'lost'}));
      case 4: // member create missing personId, completed later or never
        final m = newId(d, 'm');
        emit(
            d,
            dev.op(g, EntityType.member, m, OpKind.create,
                {MemberFields.displayName: 'Half', MemberFields.createdAt: 1}));
        if (rnd.nextBool()) {
          emit(d, dev.updateMember(g, m, {MemberFields.personId: 'p-half'}));
        }
      case 5: // group op whose entityId is another group (ignored)
        emit(
            d,
            dev.op(g, EntityType.group, 'group-elsewhere', OpKind.update,
                {GroupFields.name: 'Hijack'}));
      case 6: // newer schema op (stored, relayed, skipped)
        final hlc = dev.clock.tick();
        final op = dev.op(g, EntityType.expense, e, OpKind.update,
            {ExpenseFields.description: 'From v2'},
            hlc: hlc);
        final json = op.toJson()..['schemaVersion'] = kSchemaVersion + 1;
        emit(d, Operation.fromJson(json));
      case 7: // the same entity id in another group (hostile)
        final other = groups.where((x) => x != g).toList();
        final target = other.isEmpty ? 'group-hostile' : other.first;
        emit(
            d,
            dev.addExpense(target, e,
                money: equalBlock(100, 'x', ['y']), description: 'Stolen id'));
      default: // money as a non-map
        emit(d, dev.updateExpense(g, e, {ExpenseFields.money: 'free'}));
    }
  }

  String _currency() => kCurrencies[rnd.nextInt(kCurrencies.length)];

  MoneyBlock _block(List<String> members) {
    final total = 1 + rnd.nextInt([100, 10000, 1000000, 999999999][rnd.nextInt(4)]);
    final shuffled = List.of(members)..shuffle(rnd);
    final payers = shuffled.take(1 + rnd.nextInt(math.min(3, shuffled.length)));
    final owers =
        (List.of(members)..shuffle(rnd)).take(1 + rnd.nextInt(members.length));
    SplitSpec paidBy;
    switch (rnd.nextInt(3)) {
      case 0:
        paidBy = SplitSpec.single(payers.first, total);
      case 1:
        paidBy = SplitSpec.equal(payers);
      default:
        paidBy = SplitSpec(SplitMethod.exact,
            SplitCalculator.allocate(total, {for (final p in payers) p: 1 + rnd.nextInt(9)}));
    }
    SplitSpec owedBy;
    switch (rnd.nextInt(5)) {
      case 0:
        owedBy = SplitSpec.equal(owers);
      case 1:
        owedBy = SplitSpec(SplitMethod.exact,
            SplitCalculator.allocate(total, {for (final o in owers) o: rnd.nextInt(9)}..[owers.first] = 1));
      case 2:
        owedBy = SplitSpec(SplitMethod.percent,
            SplitCalculator.allocate(10000, {for (final o in owers) o: 1 + rnd.nextInt(9)}));
      case 3:
        owedBy = SplitSpec(
            SplitMethod.shares, {for (final o in owers) o: 1 + rnd.nextInt(5)});
      default:
        final n = owers.length;
        owedBy = SplitSpec(SplitMethod.adjustment, {
          for (final o in owers) o: rnd.nextInt(total ~/ (2 * n) + 1) - total ~/ (4 * n),
        });
    }
    final currency = _currency();
    try {
      return SplitCalculator.buildMoneyBlock(
          total: total, currency: currency, paidBy: paidBy, owedBy: owedBy);
    } on SplitException {
      return SplitCalculator.buildMoneyBlock(
          total: total,
          currency: currency,
          paidBy: paidBy,
          owedBy: SplitSpec.equal(owers));
    }
  }
}

/// Naive last-writer-wins oracle: per (group, entity, field) the value of
/// the max-HLC op, computed without the reducer.
Map<(String, String), Map<String, (Hlc, Object?)>> _oracle(
    Iterable<Operation> ops) {
  final out = <(String, String), Map<String, (Hlc, Object?)>>{};
  for (final op in ops) {
    if (op.isFromNewerSchema || op.entityType == EntityType.group) continue;
    final fields = out.putIfAbsent((op.groupId, op.entityId), () => {});
    op.payload.forEach((k, v) {
      final cur = fields[k];
      if (cur == null || op.hlc > cur.$1) fields[k] = (op.hlc, v);
    });
  }
  return out;
}

void _checkInvariants(LedgerState state, String label) {
  for (final g in state.groups.values) {
    for (final e in g.liveExpenses) {
      expect(e.money.isConsistent, isTrue, reason: label);
    }
    final nets = BalanceCalculator.groupNets(g);
    nets.forEach((c, byMember) {
      expect(byMember.values.fold(0, (a, b) => a + b), 0, reason: '$label $c');
    });
    final left = {
      for (final e in nets.entries) e.key: Map<String, int>.of(e.value),
    };
    for (final t in BalanceCalculator.suggestedTransfers(g)) {
      final cur = left.putIfAbsent(t.currency, () => {});
      cur[t.from] = (cur[t.from] ?? 0) + t.amount;
      cur[t.to] = (cur[t.to] ?? 0) - t.amount;
    }
    for (final byMember in left.values) {
      expect(byMember.values.every((v) => v == 0), isTrue,
          reason: '$label: suggested transfers settle every net');
    }
  }
}

void _expectSameState(LedgerState a, LedgerState b, String label) {
  final ja = a.toCanonicalJson();
  final jb = b.toCanonicalJson();
  expect(ja, equals(jb), reason: '$label: canonical JSON');
  expect(jsonEncode(ja), jsonEncode(jb), reason: '$label: canonical string');
  expect(a.groups.keys.toSet(), b.groups.keys.toSet(), reason: label);
  for (final id in a.groups.keys) {
    final ga = a.groups[id]!;
    final gb = b.groups[id]!;
    expect(BalanceCalculator.groupNets(ga), BalanceCalculator.groupNets(gb),
        reason: '$label: nets of $id');
    expect(BalanceCalculator.suggestedTransfers(ga),
        BalanceCalculator.suggestedTransfers(gb),
        reason: '$label: transfers of $id');
    expect(BalanceCalculator.pairwiseDebts(ga),
        BalanceCalculator.pairwiseDebts(gb),
        reason: '$label: pairwise of $id');
    expect(ga.activeMembers.map((m) => m.id).toList(),
        gb.activeMembers.map((m) => m.id).toList(),
        reason: label);
    expect(ga.liveExpenses.map((e) => e.id).toList(),
        gb.liveExpenses.map((e) => e.id).toList(),
        reason: label);
  }
}

void main() {
  test('3 devices, 300 ops, 200 seeds: replicas converge', () {
    var totalWeird = 0;
    var concurrentMoney = 0;
    var totalExpenses = 0;
    for (var seed = 0; seed < kSeeds; seed++) {
      final rnd = math.Random(seed);
      final sim = _Sim(rnd)..run();
      totalWeird += sim.weird;
      final ops = sim.all;
      final label = 'seed $seed';
      expect(ops.map((o) => o.id).toSet().length, ops.length, reason: label);

      // Replica A: one at a time, random order.
      final orderA = List.of(ops)..shuffle(rnd);
      final a = LedgerReducer();
      for (final op in orderA) {
        a.apply(op);
      }

      // Replica B: another order, 20% duplicates, random batches, snapshot
      // reads in between.
      final orderB = List.of(ops);
      for (var i = 0; i < ops.length ~/ 5; i++) {
        orderB.add(ops[rnd.nextInt(ops.length)]);
      }
      orderB.shuffle(rnd);
      final b = LedgerReducer();
      final snapshots = <(LedgerState, String)>[];
      var i = 0;
      while (i < orderB.length) {
        final n = 1 + rnd.nextInt(40);
        b.applyAll(orderB.sublist(i, math.min(i + n, orderB.length)));
        i += n;
        if (rnd.nextInt(3) == 0) {
          final s = b.state;
          snapshots.add((s, jsonEncode(s.toCanonicalJson())));
        }
      }
      // Re-applying everything is a no-op.
      expect(b.applyAll(ops), isEmpty, reason: label);
      // Earlier snapshots were not mutated by later ops.
      for (final (s, json) in snapshots) {
        expect(jsonEncode(s.toCanonicalJson()), json, reason: label);
      }

      _expectSameState(a.state, b.state, '$label A/B');

      // Replica C: HLC-ascending order (the order Ledger replays on startup).
      final c = reduce(List.of(ops)..sort((x, y) => x.hlc.compareTo(y.hlc)));
      _expectSameState(a.state, c.state, '$label A/C');

      // Every device converges after a full sync round.
      sim
        ..syncPair(0, 1)
        ..syncPair(1, 2)
        ..syncPair(0, 1);
      for (var d = 0; d < 3; d++) {
        _expectSameState(a.state, sim.replicas[d].state, '$label device $d');
      }

      _checkInvariants(a.state, label);

      // Oracle: visible expenses/members carry the max-HLC value per field.
      final oracle = _oracle(ops);
      for (final g in a.state.groups.values) {
        for (final e in g.expenses.values) {
          totalExpenses++;
          final f = oracle[(g.groupId, e.id)]!;
          expect(e.description, f[ExpenseFields.description]!.$2, reason: label);
          expect(e.money.toJson(), f[ExpenseFields.money]!.$2, reason: label);
          expect(e.deletedAt?.millisecondsSinceEpoch,
              f[ExpenseFields.deletedAt]?.$2, reason: label);
          final maxHlc = ops
              .where((o) =>
                  o.groupId == g.groupId &&
                  o.entityId == e.id &&
                  !o.isFromNewerSchema)
              .map((o) => o.hlc)
              .reduce((x, y) => x > y ? x : y);
          expect(e.updatedHlc, maxHlc, reason: label);
        }
        for (final m in g.members.values) {
          final f = oracle[(g.groupId, m.id)]!;
          expect(m.displayName, f[MemberFields.displayName]!.$2, reason: label);
          expect(m.mergedInto, f[MemberFields.mergedInto]?.$2, reason: label);
          expect(m.personId, f[MemberFields.personId]!.$2, reason: label);
        }
      }

      // The activity feed is a pure function of the op set too.
      List<String> feed(List<Operation> list) => ActivityBuilder.build(
            ops: list,
            state: a.state,
            localDeviceId: 'dev-0',
            unsharedOpIds: const {},
          ).map((e) => '${e.op.id}:${e.kind.name}:${e.supersededBy}').toList();
      final feedA = feed(orderA);
      expect(feed(orderB), feedA, reason: label);
      concurrentMoney += feedA.where((s) => !s.endsWith(':null')).length;
    }
    // The generator must actually exercise the interesting cases.
    expect(totalWeird, greaterThan(kSeeds));
    expect(concurrentMoney, greaterThan(kSeeds));
    expect(totalExpenses, greaterThan(kSeeds * 30));
  }, timeout: const Timeout(Duration(minutes: 5)));
}
