// QA MONEY: simplify on/off, settle up (exact, partial, over, by the
// creditor, second currency), merged/removed members, person and overall
// summaries (direct groups, me not a member, hero currency choice).
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/screens/common.dart' show mainCurrencyOf;

import 'money_harness.dart';

void main() {
  late QaPhone p;
  late GroupId g;
  late MemberId me, sam, priya, dev;

  setUp(() async {
    p = await QaPhone.create();
    final t = await p.group(['Sam', 'Priya', 'Dev']);
    g = t.g;
    me = t.m['me']!;
    sam = t.m['Sam']!;
    priya = t.m['Priya']!;
    dev = t.m['Dev']!;
  });
  tearDown(() => p.dispose());

  Future<void> simplify(bool on) async {
    await p.ledger.updateGroup(g, GroupPatch(simplifyDebts: on));
    await pumpEventQueue();
  }

  PersonId person(MemberId m) => p.gs(g).members[m]!.personId;
  Map<String, int> personNet(MemberId m) =>
      p
          .people()
          .where((x) => x.personId == person(m))
          .map((x) => x.net)
          .firstOrNull ??
      const {};

  group('simplify on vs off', () {
    setUp(() async {
      // A chain and a cycle: me paid for sam, sam for priya, priya for dev,
      // dev for me.
      await p.add(g, total: 4000, paidBy: one(me, 4000), owedBy: eq([sam]));
      await p.add(g, total: 3000, paidBy: one(sam, 3000), owedBy: eq([priya]));
      await p.add(g, total: 2000, paidBy: one(priya, 2000), owedBy: eq([dev]));
      await p.add(g, total: 1000, paidBy: one(dev, 1000), owedBy: eq([me]));
    });

    test('same nets, <= n-1 transfers, my totals unchanged', () async {
      await simplify(false);
      final netsOff = p.nets(g);
      final offTransfers = p.transfers(g);
      final overallOff = p.overall();
      final myNetOff = Summaries.myNetInGroup(p.gs(g), p.me);
      expectMoneyInvariants(p, reason: 'off');
      expect(offTransfers, hasLength(4));

      await simplify(true);
      expect(p.nets(g), netsOff);
      expect(p.transfers(g).length, lessThanOrEqualTo(3));
      expect(p.overall().net, overallOff.net);
      expect(Summaries.myNetInGroup(p.gs(g), p.me), myNetOff);
      expectMoneyInvariants(p, reason: 'on');

      await simplify(false);
      expect(p.transfers(g), offTransfers, reason: 'toggle is a pure view');
    });

    Future<void> settleViaSuggestions() async {
      // nets: me +3000, sam -1000, priya -1000, dev -1000; everyone pays
      // what the (simplified) suggestions say.
      await simplify(true);
      for (final t in p.transfers(g)) {
        await p.pay(g, from: t.from, to: t.to, amount: t.amount);
      }
    }

    test('settled group shows nothing (simplify on)', () async {
      await settleViaSuggestions();
      expect(p.nets(g), isEmpty);
      expect(p.transfers(g), isEmpty);
      expect(p.overall().net, isEmpty);
      expect(p.people().every((x) => x.isSettled), isTrue);
      expect(p.summaries().single.isSettled, isTrue);
    });

    test(
      'settled group shows nothing after turning simplify off',
      skip:
          'QA MONEY-R1-03: settled group still lists pairwise payments '
          'and per-person debts when simplify is off',
      () async {
        await settleViaSuggestions();
        await simplify(false);
        expect(p.nets(g), isEmpty, reason: 'every net is zero');
        expect(p.summaries().single.isSettled, isTrue);
        // The group screen says "settled" in the hero, so it must not also
        // list payments, and Friends must not show debts with anyone.
        expect(p.transfers(g), isEmpty);
        expect(p.people().where((x) => !x.isSettled), isEmpty);
      },
    );
  });

  group('settle up', () {
    setUp(() async {
      await p.add(
        g,
        total: 9000,
        paidBy: one(me, 9000),
        owedBy: eq([me, sam, priya]),
      );
    });

    test('exact payment clears the pair', () async {
      await p.pay(g, from: sam, to: me, amount: 3000);
      expect(p.nets(g)['INR'], {me: 3000, priya: -3000});
      expect(personNet(sam), isEmpty);
      expectMoneyInvariants(p);
    });

    test('partial payment leaves the rest', () async {
      await p.pay(g, from: sam, to: me, amount: 1250);
      expect(personNet(sam), {'INR': 1750});
      expectMoneyInvariants(p);
    });

    test('over-payment flips the direction (pairwise view)', () async {
      await simplify(false);
      await p.pay(g, from: sam, to: me, amount: 5000);
      expect(personNet(sam), {'INR': -2000}, reason: 'now I owe Sam');
      expect(p.transfers(g).where((t) => t.from == me), [
        Transfer(from: me, to: sam, amount: 2000, currency: 'INR'),
      ]);
      expectMoneyInvariants(p);
    });

    test(
      'over-payment with simplify on: the extra is routed, nets exact',
      () async {
        await p.pay(g, from: sam, to: me, amount: 5000);
        expect(p.nets(g)['INR'], {me: 1000, sam: 2000, priya: -3000});
        expect(p.transfers(g), [
          Transfer(from: priya, to: sam, amount: 2000, currency: 'INR'),
          Transfer(from: priya, to: me, amount: 1000, currency: 'INR'),
        ]);
        expectMoneyInvariants(p);
      },
    );

    test('recorded by the creditor side works the same', () async {
      // I (the creditor) record that Priya paid me.
      final id = await p.pay(g, from: priya, to: me, amount: 3000);
      final e = p.state.expense(id)!;
      expect(e.createdBy, me);
      expect((e.payer, e.receiver), (priya, me));
      expect(personNet(priya), isEmpty);
      expectMoneyInvariants(p);
    });

    test('a payment in a second currency settles only that currency', () async {
      await p.add(
        g,
        total: 3000,
        currency: 'USD',
        paidBy: one(me, 3000),
        owedBy: eq([me, sam, priya]),
      );
      expect(personNet(sam), {'INR': 3000, 'USD': 1000});
      await p.pay(g, from: sam, to: me, amount: 1000, currency: 'USD');
      expect(personNet(sam), {'INR': 3000});
      expect(p.nets(g).keys, ['INR', 'USD']);
      expect(p.nets(g)['USD'], {me: 1000, priya: -1000});
      expectMoneyInvariants(p);
    });
  });

  group('merged and removed members', () {
    test('a removed member keeps their balance everywhere', () async {
      await p.add(
        g,
        total: 9000,
        paidBy: one(me, 9000),
        owedBy: eq([me, sam, priya]),
      );
      await p.ledger.removeMember(g, sam);
      await pumpEventQueue();
      expect(p.gs(g).activeMembers.map((m) => m.id), isNot(contains(sam)));
      expect(p.nets(g)['INR'], {me: 6000, sam: -3000, priya: -3000});
      expect(personNet(sam), {'INR': 3000});
      expect(p.overall().net, {'INR': 6000});
      expectMoneyInvariants(p);
      // A payment from the removed member still settles.
      await p.pay(g, from: sam, to: me, amount: 3000);
      expect(personNet(sam), isEmpty);
      expectMoneyInvariants(p);
    });

    test('merging a duplicate adds the balances together', () async {
      final sam2 = await p.ledger.addMember(g, displayName: 'Sam K');
      await p.add(g, total: 3000, paidBy: one(me, 3000), owedBy: eq([me, sam]));
      await p.add(g, total: 1000, paidBy: one(sam2, 1000), owedBy: eq([me]));
      expect(p.nets(g)['INR'], {me: 500, sam: -1500, sam2: 1000});
      await p.ledger.mergeMembers(g, from: sam2, into: sam);
      await pumpEventQueue();
      expect(p.nets(g)['INR'], {me: 500, sam: -500});
      expect(p.gs(g).activeMembers.map((m) => m.id), isNot(contains(sam2)));
      expectMoneyInvariants(p);
      // A chain: dev -> sam2 -> sam.
      await p.ledger.mergeMembers(g, from: dev, into: sam2);
      await pumpEventQueue();
      expect(p.gs(g).resolve(dev), sam);
      expectMoneyInvariants(p);
    });

    test('merging me into someone else keeps the totals consistent', () async {
      await p.add(
        g,
        total: 3000,
        paidBy: one(sam, 3000),
        owedBy: eq([me, priya]),
      );
      await p.ledger.mergeMembers(g, from: me, into: dev);
      await pumpEventQueue();
      expectMoneyInvariants(p);
    });
  });

  group('person and overall summaries', () {
    test('several groups, a direct group and a group I am not in', () async {
      await p.add(
        g,
        total: 9000,
        paidBy: one(me, 9000),
        owedBy: eq([me, sam, priya]),
      );
      // Second group with the same Sam (same personId) where I owe him.
      final g2 = await p.ledger.createGroup(
        NewGroup(
          name: 'Flat',
          type: GroupType.home,
          currency: 'INR',
          existingPeople: [(personId: person(sam), displayName: 'Sam')],
        ),
      );
      final s2 = p.gs(g2);
      final me2 = s2.memberForPerson(p.me)!.id;
      final sam2 = s2.memberForPerson(person(sam))!.id;
      await p.add(
        g2,
        total: 5000,
        paidBy: one(sam2, 5000),
        owedBy: eq([me2, sam2]),
      );
      expect(personNet(sam), {'INR': 500}, reason: '3000 - 2500 across groups');

      // Direct group with Priya in USD.
      final d = await p.ledger.directGroupWith(
        personId: person(priya),
        displayName: 'Priya',
        currency: 'USD',
      );
      final ds = p.gs(d);
      await p.add(
        d,
        total: 800,
        currency: 'USD',
        paidBy: one(ds.memberForPerson(p.me)!.id, 800),
        owedBy: eq([ds.memberForPerson(person(priya))!.id]),
      );
      expect(personNet(priya), {'INR': 3000, 'USD': 800});

      // A group where I have no member: removing my member keeps it, so
      // use a group created then joined by another phone instead.
      final q = await QaPhone.create(name: 'Zed', prefix: 'cccccccc');
      addTearDown(q.dispose);
      final other = await q.group(['Yan']);
      await q.add(
        other.g,
        total: 7000,
        paidBy: one(other.m['me']!, 7000),
        owedBy: eq([other.m['Yan']!]),
      );
      await shareGroup(q, p, other.g);
      await pull(q, p, other.g);
      expect(Summaries.myNetInGroup(p.gs(other.g), p.me), isEmpty);

      expect(p.overall().net, {'INR': 3500, 'USD': 800});
      expect(
        p.summaries().map((s) => s.group.groupId),
        isNot(contains(d)),
        reason: 'direct groups are not group rows',
      );
      expectMoneyInvariants(p);
    });

    test('hero currency: home currency if present, else the largest', () {
      expect(mainCurrencyOf({'USD': 500, 'INR': -10}, 'INR'), 'INR');
      expect(mainCurrencyOf({'USD': 500, 'EUR': -900}, 'INR'), 'EUR');
      expect(mainCurrencyOf({}, 'INR'), 'INR');
    });
  });
}
