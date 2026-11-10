// QA DATA-R1: performance with a large log (20k ops across 10 groups,
// three authoring devices). Host timings are a proxy for a phone: the
// budget is open + replay < 2 s on the host (JIT, shared CPU). Numbers are
// printed so the QA report can quote them.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/activity.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/split.dart';
import 'package:settle_up/core/version_vector.dart';

import 'qa_data_harness.dart';

const DeviceId peerB = 'bbbbbbbb-0000-7000-8000-0000000000b1';
const DeviceId peerC = 'cccccccc-0000-7000-8000-0000000000c1';

const int kGroups = 10;
const int kTotalOps = 20000;

/// Builds a realistic log: per group one create + 6 members by [me], then
/// expenses (70%), edits of earlier expenses (20%) and payments (10%) by
/// me / B / C in turn, HLCs spread over ~3 months.
List<Operation> buildLog(DeviceId me) {
  final ops = <Operation>[];
  final counters = <(GroupId, DeviceId), int>{};
  var t = kQaBaseMs - 90 * 86400 * 1000;
  var seq = 0;
  Operation op(GroupId g, DeviceId d, EntityType type, String entity,
      OpKind kind, Map<String, Object?> payload) {
    final c = counters[(g, d)] = (counters[(g, d)] ?? 0) + 1;
    t += 389; // ~3 months over 20k ops
    return Operation(
      id: 'op-${(seq++).toString().padLeft(6, '0')}',
      groupId: g,
      deviceId: d,
      counter: c,
      hlc: Hlc(t, 0, d),
      entityType: type,
      entityId: entity,
      kind: kind,
      payload: payload,
    );
  }

  final perGroup = kTotalOps ~/ kGroups;
  for (var gi = 0; gi < kGroups; gi++) {
    final g = 'group-$gi';
    final members = [for (var m = 0; m < 6; m++) '$g-m$m'];
    ops.add(op(g, me, EntityType.group, g, OpKind.create, {
      GroupFields.name: 'Group $gi',
      GroupFields.type: 'trip',
      GroupFields.currency: 'INR',
      GroupFields.simplifyDebts: gi.isEven,
      GroupFields.archived: false,
      GroupFields.createdAt: t,
    }));
    for (var m = 0; m < members.length; m++) {
      ops.add(op(g, me, EntityType.member, members[m], OpKind.create, {
        MemberFields.displayName: 'Person $m',
        MemberFields.personId: m == 0 ? 'me-person' : '$g-p$m',
        if (m == 0) MemberFields.deviceId: me,
        MemberFields.createdAt: t,
      }));
    }
    final expenses = <String>[];
    final devices = [me, peerB, peerC];
    for (var i = members.length + 1; i < perGroup; i++) {
      final d = devices[i % 3];
      final r = i % 10;
      if (r < 7 || expenses.isEmpty) {
        final id = '$g-e$i';
        expenses.add(id);
        final total = 1000 + (i * 37) % 90000;
        final owed = members.take(2 + i % 5).toList();
        final money = SplitCalculator.buildMoneyBlock(
          total: total,
          currency: 'INR',
          paidBy: SplitSpec.single(members[i % members.length], total),
          owedBy: SplitSpec.equal(owed),
        );
        ops.add(op(g, d, EntityType.expense, id, OpKind.create, {
          ExpenseFields.kind: 'expense',
          ExpenseFields.description: 'Expense $i',
          ExpenseFields.category: 'food.dining',
          ExpenseFields.date: t,
          ExpenseFields.notes: '',
          ExpenseFields.money: money.toJson(),
          ExpenseFields.createdBy: members[0],
          ExpenseFields.createdAt: t,
        }));
      } else if (r < 9) {
        ops.add(op(g, d, EntityType.expense, expenses[(i * 7) % expenses.length],
            OpKind.update, {ExpenseFields.description: 'Edited $i'}));
      } else {
        final id = '$g-pay$i';
        final money = SplitCalculator.paymentBlock(
            from: members[1], to: members[0], amount: 500, currency: 'INR');
        ops.add(op(g, d, EntityType.expense, id, OpKind.create, {
          ExpenseFields.kind: 'payment',
          ExpenseFields.description: '',
          ExpenseFields.category: 'payment',
          ExpenseFields.date: t,
          ExpenseFields.notes: '',
          ExpenseFields.money: money.toJson(),
          ExpenseFields.paymentMethod: 'upi',
          ExpenseFields.createdBy: members[1],
          ExpenseFields.createdAt: t,
        }));
      }
    }
  }
  return ops;
}

int ms(Stopwatch s) => s.elapsedMilliseconds;

void main() {
  late FilePhone a;

  setUpAll(() async {
    resetKeystore();
    a = FilePhone(qaTempDir());
    await a.launch();
    await a.settings
        .completeOnboarding(displayName: 'Alex', homeCurrency: 'INR');
    final log = buildLog(a.deviceId);
    expect(log, hasLength(kTotalOps));
    final sw = Stopwatch()..start();
    // A first sync delivers the log in 500-op batches.
    for (var i = 0; i < log.length; i += 500) {
      await a.store.insertAll(log.sublist(i, (i + 500).clamp(0, log.length)));
    }
    // ignore: avoid_print
    print('[perf] insert 20k ops in 500-op transactions: ${ms(sw)} ms');
    for (var gi = 0; gi < kGroups; gi++) {
      await a.keys.put('group-$gi', Uint8List.fromList(List.filled(32, gi)));
    }
    await a.close();
  });

  tearDownAll(() async {
    try {
      await a.close();
    } catch (_) {}
    a.dir.deleteSync(recursive: true);
  });

  test('cold open + replay of 20k ops is under 2 s on the host', () async {
    final rssBefore = ProcessInfo.currentRss;
    final sw = Stopwatch()..start();
    await a.launch();
    final open = ms(sw);
    final rssAfter = ProcessInfo.currentRss;
    // ignore: avoid_print
    print('[perf] cold open + replay (store, settings, ledger): $open ms; '
        'RSS +${((rssAfter - rssBefore) / 1048576).toStringAsFixed(1)} MiB '
        '(total ${(rssAfter / 1048576).toStringAsFixed(0)} MiB)');
    expect(a.snap.ops, hasLength(kTotalOps));
    expect(a.snap.state.visibleGroups, hasLength(kGroups));
    expect(open, lessThan(2000));

    // Warm reopen (page cache hot, JIT warm) for comparison.
    await a.close();
    sw
      ..reset()
      ..start();
    await a.launch();
    // ignore: avoid_print
    print('[perf] warm reopen: ${ms(sw)} ms');
  });

  test('per-command cost (snapshot rebuild) stays small with 20k ops',
      () async {
    final g = a.snap.state.groups['group-0']!;
    final members = g.members.keys.toList()..sort();
    // Warm up.
    for (var i = 0; i < 5; i++) {
      await a.ledger.addExpense(qaDraft('group-0', members.take(3).toList(),
          total: 100 + i));
    }
    const n = 50;
    final sw = Stopwatch()..start();
    for (var i = 0; i < n; i++) {
      await a.ledger.addExpense(qaDraft('group-${i % kGroups}',
          a.snap.state.groups['group-${i % kGroups}']!.members.keys
              .take(3)
              .toList(),
          total: 200 + i));
    }
    final per = ms(sw) / n;
    // ignore: avoid_print
    print('[perf] addExpense with 20k ops: ${per.toStringAsFixed(1)} ms/command');
    expect(per, lessThan(100), reason: 'a tap must not feel slow');

    sw
      ..reset()
      ..start();
    await a.ledger.recordPeerKnowledge(
        peerB, 'group-0', VersionVector({a.deviceId: 999999}));
    // ignore: avoid_print
    print('[perf] recordPeerKnowledge + snapshot: ${ms(sw)} ms');
  });

  test('derived views a screen rebuilds on every snapshot', () async {
    final s = a.snap;
    // Best of 5 so JIT warm-up does not count.
    var balances = 1 << 30, act = 1 << 30;
    late OverallBalance overall;
    late List<GroupBalanceSummary> groups;
    late List<ActivityEntry> activity;
    for (var i = 0; i < 5; i++) {
      final sw = Stopwatch()..start();
      overall = Summaries.overall(s.state, 'me-person');
      groups = Summaries.groups(s.state, 'me-person');
      if (ms(sw) < balances) balances = ms(sw);
      sw
        ..reset()
        ..start();
      activity = ActivityBuilder.build(
        ops: s.ops,
        state: s.state,
        localDeviceId: s.localDeviceId,
        unsharedOpIds: s.unsharedOpIds,
      );
      if (ms(sw) < act) act = ms(sw);
    }
    final sw = Stopwatch()..start();
    final ids = s.unsharedEntityIds;
    final once = sw.elapsedMicroseconds;
    // ignore: avoid_print
    print('[perf] Summaries.overall+groups: $balances ms; '
        'ActivityBuilder.build(all): $act ms (${activity.length} entries); '
        'unsharedEntityIds once: $once us (${ids.length} ids)');
    expect(groups, hasLength(kGroups));
    expect(overall, isNotNull);
    expect(balances, lessThan(500));
    expect(act, lessThan(1000));
  });

  test('search results: unsharedEntityIds evaluated per row is O(rows x ops)',
      () async {
    // search_screen.dart builds every result row eagerly and calls
    // snap.unsharedEntityIds (a getter that scans every op) once per row.
    final s = a.snap;
    final rows = s.state.groups.values
        .expand((g) => g.liveExpenses)
        .take(1000)
        .toList();
    final sw = Stopwatch()..start();
    var n = 0;
    for (final e in rows) {
      if (s.unsharedEntityIds.contains(e.id)) n++;
    }
    final perKeystroke = ms(sw);
    // ignore: avoid_print
    print('[perf] 1000 search rows x unsharedEntityIds: $perKeystroke ms '
        '($n unshared)');
    expect(perKeystroke, lessThan(16 * 4),
        reason: 'a search keystroke must not drop frames for seconds');
  });

  test('a 1000-op remote batch applies quickly with 20k ops present',
      () async {
    final batch = [
      for (var i = 1; i <= 1000; i++)
        Operation(
          id: 'late-$i',
          groupId: 'group-1',
          deviceId: 'dddddddd-0000-7000-8000-0000000000d1',
          counter: i,
          hlc: Hlc(kQaBaseMs + i, 0, 'dddddddd-0000-7000-8000-0000000000d1'),
          entityType: EntityType.member,
          entityId: 'group-1-m${i % 6}',
          kind: OpKind.update,
          payload: {MemberFields.displayName: 'N$i'},
        ),
    ];
    final sw = Stopwatch()..start();
    expect(await a.ledger.applyRemote('group-1', batch), hasLength(1000));
    // ignore: avoid_print
    print('[perf] applyRemote 1000 ops onto 20k: ${ms(sw)} ms');
    expect(ms(sw), lessThan(2000));
    sw
      ..reset()
      ..start();
    final missing =
        await a.ledger.opsMissingFor('group-1', VersionVector.empty);
    // ignore: avoid_print
    print('[perf] opsMissingFor(full group, ${missing.length} ops): '
        '${ms(sw)} ms');
  });
}
