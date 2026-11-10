// Names are stored, shown and synced in the one normalised form NameText
// gives them (UIFLOW-R6-01), on every path that writes one.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';

import '../sync/support/harness.dart';
import '../sync/support/phone.dart';

void main() {
  late TestPhone a, b;
  setUp(() async {
    a = await TestPhone.create('a', name: 'Arjun­');
    b = await TestPhone.create('b', name: 'Priya');
  });
  tearDown(() async {
    await a.close();
    await b.close();
  });

  test(
    'people, groups, my name and the phone name are stored normalised',
    () async {
      final g = await a.ledger.createGroup(
        const NewGroup(
          name: 'Goa　trip​',
          type: GroupType.trip,
          currency: 'INR',
          newMemberNames: ['RahulㅤKumar', 'Ｐｒｉｙａ'],
        ),
      );
      final group = a.state.groups[g]!;
      expect(group.group!.name, 'Goa trip');
      expect(group.activeMembers.map((m) => m.displayName).toSet(), {
        'Arjun',
        'Rahul Kumar',
        'Priya',
      });
      final m = await a.ledger.addMember(g, displayName: ' Meera⠀ Das ');
      expect(a.state.groups[g]!.members[m]!.displayName, 'Meera Das');
      await a.settings.setDeviceName('Pixel 8‎');
      expect(a.settings.device.deviceName, 'Pixel 8');
    },
  );

  test('a name with no letter or number is refused everywhere', () async {
    final g = await a.ledger.createGroup(
      const NewGroup(name: 'Trip', type: GroupType.trip, currency: 'INR'),
    );
    for (final n in ['ㅤ', '⠀', 'ᅟᅠ', '­', '-', '.']) {
      await expectLater(
        a.ledger.addMember(g, displayName: n),
        throwsA(isA<LedgerException>()),
        reason: n.runes.map((r) => r.toRadixString(16)).join(' '),
      );
      expect(() => a.settings.setDeviceName(n), throwsArgumentError);
    }
    await expectLater(
      a.ledger.createGroup(
        const NewGroup(name: 'ㅤ', type: GroupType.trip, currency: 'INR'),
      ),
      throwsA(isA<LedgerException>()),
    );
  });

  test('a name from another phone shows in the same form', () async {
    final s = await a.seedGroup(expenses: 0);
    await b.join(a, s.g);
    await syncPair(a, b);
    expect(
      b.state.groups[s.g]!.activeMembers.map((m) => m.displayName),
      a.state.groups[s.g]!.activeMembers.map((m) => m.displayName),
    );
    expect(
      b.state.groups[s.g]!.activeMembers.map((m) => m.displayName),
      contains('Arjun'),
    );
  });
}
