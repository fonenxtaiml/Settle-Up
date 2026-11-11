// The reducer rebuilds each entity a batch touches once (applyAll) and
// shows a name it has shown before without normalising it again; neither
// changes what it materializes (DATA-R15-01).
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/core/ops.dart';

import 'helpers.dart';

const g = 'g1';
const g2 = 'g2';

/// Names that NFKC and the cleaning change, and some that they do not.
const _names = [
  'Sam',
  '\uFF33\uFF41\uFF4D',
  'Sam\u200B',
  ' Sam ',
  'Priya',
  'Priya\u3164K',
  '\uFDFA',
  '\uFDFA\uFDFA\uFDFA',
  '\u337F',
  'R\u0301ahul',
  '\u3164',
  '',
];

/// [n] random ops from three devices over two groups: creates, renames,
/// merges, removals, expenses and edits, some of them repeated.
List<Operation> _randomOps(Random rnd, int n) {
  final devices = [
    FakeDevice('dev-a'),
    FakeDevice('dev-b'),
    FakeDevice('dev-c'),
  ];
  final ops = <Operation>[
    devices[0].createGroup(g),
    devices[1].createGroup(g2, name: '\uFF26\uFF4C\uFF41\uFF54'),
  ];
  for (final d in devices) {
    d.saw(ops);
  }
  String name() => _names[rnd.nextInt(_names.length)];
  for (var i = 0; i < n; i++) {
    final d = devices[rnd.nextInt(devices.length)];
    final group = rnd.nextBool() ? g : g2;
    final m = 'm${rnd.nextInt(5)}';
    FakeDevice.wallMs += rnd.nextInt(3) * 1000;
    final op = switch (rnd.nextInt(9)) {
      0 => d.addMember(group, m, name()),
      1 || 2 => d.updateMember(group, m, {MemberFields.displayName: name()}),
      3 => d.mergeMember(group, m, 'm${rnd.nextInt(5)}'),
      4 => d.removeMember(group, m),
      5 => d.updateGroup(group, {GroupFields.name: name()}),
      6 => d.addExpense(
        group,
        'e${rnd.nextInt(3)}',
        money: equalBlock(300, 'm0', ['m0', 'm1', 'm2']),
      ),
      7 => d.updateExpense(group, 'e${rnd.nextInt(3)}', {
        ExpenseFields.description: name(),
      }),
      _ => ops[rnd.nextInt(ops.length)], // a duplicate
    };
    ops.add(op);
    if (rnd.nextInt(4) == 0) devices[rnd.nextInt(devices.length)].saw([op]);
  }
  return ops;
}

void main() {
  setUp(() => FakeDevice.wallMs = kBaseMs);

  test('a batch materializes what applying its ops one by one does, in any '
      'order and in any split into batches', () {
    for (var seed = 0; seed < 300; seed++) {
      final rnd = Random(seed);
      final ops = _randomOps(rnd, 40 + rnd.nextInt(80));
      final one = LedgerReducer();
      final changedOne = <String>{};
      for (final op in ops) {
        if (one.apply(op)) changedOne.add(op.entityId);
      }
      final want = one.state.toCanonicalJson();

      final batch = LedgerReducer();
      final changed = batch.applyAll(ops);
      expect(batch.state.toCanonicalJson(), want, reason: 'seed $seed');
      // From nothing, the batch changed every entity that shows.
      expect(changedOne.containsAll(changed), isTrue, reason: 'seed $seed');
      for (final gs in batch.state.groups.values) {
        expect(changed, contains(gs.groupId), reason: 'seed $seed');
        expect(changed, containsAll(gs.members.keys), reason: 'seed $seed');
        expect(changed, containsAll(gs.expenses.keys), reason: 'seed $seed');
      }

      final shuffled = [...ops]..shuffle(rnd);
      final chunks = LedgerReducer();
      for (var i = 0; i < shuffled.length;) {
        final n = 1 + rnd.nextInt(20);
        final before = chunks.state.toCanonicalJson();
        final part = shuffled.sublist(i, min(i + n, shuffled.length));
        final ids = chunks.applyAll(part);
        if (ids.isEmpty) {
          expect(chunks.state.toCanonicalJson(), before, reason: 'seed $seed');
        }
        i += n;
      }
      expect(chunks.state.toCanonicalJson(), want, reason: 'seed $seed');
      expect(chunks.applyAll(ops), isEmpty, reason: 'seed $seed');
    }
  });

  test('a batch of 4,000 renames of six members normalises each name '
      'once, not once per op', () {
    final peer = FakeDevice('dev-peer');
    final setup = [
      peer.createGroup(g),
      for (var m = 0; m < 6; m++) peer.addMember(g, 'm$m', 'Person $m'),
    ];
    final renames = [
      for (var i = 1; i <= 4000; i++)
        peer.updateMember(g, 'm${i % 6}', {
          MemberFields.displayName: '\uFDFA' * 159 + '${i % 10}',
        }),
    ];
    final r = LedgerReducer()..applyAll(setup);
    final before = NameText.unormUnits;
    final changed = r.applyAll(renames);
    final batchWork = NameText.unormUnits - before;
    expect(changed, {for (var m = 0; m < 6; m++) 'm$m'});

    final one = LedgerReducer()..applyAll(setup);
    final start = NameText.unormUnits;
    for (final op in renames) {
      one.apply(op);
    }
    final perOpWork = NameText.unormUnits - start;
    expect(r.state.toCanonicalJson(), one.state.toCanonicalJson());
    final shown = r.state.groups[g]!.members['m1']!.displayName;
    expect(shown, NameText.display('\uFDFA' * 159 + '7'));
    expect(shown, hasLength(39));
    // ignore: avoid_print
    print(
      '[work] 4,000 renames: batch $batchWork units, one by one '
      '$perOpWork units',
    );
    expect(batchWork * 100, lessThan(perOpWork));
  });

  test('an op that leaves a name as it is does not normalise it again; '
      'one that changes it does, also back to a name shown before', () {
    final peer = FakeDevice('dev-peer');
    final r = LedgerReducer()
      ..applyAll([
        peer.createGroup(g, name: '\uFDFA\uFDFA'),
        peer.addMember(g, 'm', '\uFF32\uFF41\uFF48\uFF55\uFF4C'),
      ]);
    int work(Operation op) {
      final before = NameText.unormUnits;
      r.apply(op);
      return NameText.unormUnits - before;
    }

    Member m() => r.state.groups[g]!.members['m']!;
    expect(m().displayName, 'Rahul');
    expect(
      work(peer.updateMember(g, 'm', {MemberFields.deviceId: 'dev-x'})),
      0,
    );
    expect(m().deviceId, 'dev-x');
    expect(work(peer.updateGroup(g, {GroupFields.archived: true})), 0);
    expect(r.state.groups[g]!.group!.archived, isTrue);
    expect(r.state.groups[g]!.group!.name, NameText.display('\uFDFA' * 2, 60));

    expect(
      r.apply(peer.updateMember(g, 'm', {MemberFields.displayName: 'Rahul'})),
      isFalse,
    ); // shows the same
    expect(m().displayName, 'Rahul');
    expect(
      work(
        peer.updateMember(g, 'm', {
          MemberFields.displayName: '\uFF33\uFF41\uFF4D',
        }),
      ),
      greaterThan(0),
    );
    expect(m().displayName, 'Sam');
    expect(
      work(
        peer.updateMember(g, 'm', {
          MemberFields.displayName: '\uFF32\uFF41\uFF48\uFF55\uFF4C',
        }),
      ),
      greaterThan(0),
    );
    expect(m().displayName, 'Rahul');
    r.apply(peer.updateMember(g, 'm', {MemberFields.displayName: '\u3164'}));
    expect(m().displayName, NameText.display('\u3164'));
  });
}
