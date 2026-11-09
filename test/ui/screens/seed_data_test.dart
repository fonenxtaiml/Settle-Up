// The demo world must produce the numbers shown in the reference renders.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/ui/dev/seed_data.dart';

void main() {
  test('seeded balances match the reference renders', () async {
    final w = await createDemoWorld(
      now: DateTime(2026, 11, 9, 10),
      ids: SequentialIdGenerator(),
    );
    final state = w.ledger.current.state;
    final me = DemoIds.me;

    expect(Summaries.overall(state, me).net, {'INR': 425000});
    final groups = {
      for (final g in Summaries.groups(state, me)) g.group.group!.name: g,
    };
    expect(groups['Goa trip']!.myNet, {'INR': -84000});
    expect(groups['Flat 4B']!.myNet, {'INR': 509000});
    expect(groups['Cabin weekend']!.isSettled, isTrue);
    expect(groups['Goa trip']!.memberCount, 6);

    final people = {
      for (final p in Summaries.people(state, me)) p.displayName: p.net,
    };
    expect(people['Priya Sharma'], {'INR': 120000});

    final goa = state.groups[w.groups.goa]!;
    final names = {for (final m in goa.members.values) m.id: m.displayName};
    final transfers = [
      for (final t in BalanceCalculator.suggestedTransfers(goa))
        '${names[t.from]} -> ${names[t.to]} ${t.amount}',
    ];
    expect(
      transfers,
      unorderedEquals([
        'Arjun Mehta -> Priya Sharma 84000',
        'Kabir Singh -> Ravi Kumar 615000',
        'Isha Nair -> Ravi Kumar 401000',
      ]),
    );
    expect(w.ledger.current.totalUnshared, 3);
  });
}
