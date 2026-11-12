// QA MONEY round 26: reverification of MONEY-R24-01 (Settle up "What
// changes" preview) on the real Settle up screen over Ledger(MemoryOpStore)
// and the real providers, probing the whole defect class:
// - a widget property over seeded random groups (simplify on and off):
//   every row of the "What changes" table, before and after the payment is
//   recorded (the frozen confirmation), against what the providers show
//   once the payment is stored, and every balance with me that moves is
//   listed;
// - a person shared across two groups and a direct group ("Sam overall");
// - a payment between two other people that moves my balances;
// - a save that fails and is retried with another amount.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/app.dart';
import 'package:settle_up/ui/dev/fake_sync_engine.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/widgets/settle_controls.dart';

import 'money_harness.dart';
import 'settle_screen_currency_test.dart' show pumpReal, settle;

/// What [b] owes [a] in [currency] in the group (negative: [a] owes [b]),
/// from the suggested payments the Group screen lists.
int _pair(QaPhone p, GroupId g, MemberId a, MemberId b, String currency) {
  var v = 0;
  for (final t in p.transfers(g)) {
    if (t.currency != currency) continue;
    if (t.from == a && t.to == b) v -= t.amount;
    if (t.to == a && t.from == b) v += t.amount;
  }
  return v;
}

int _person(QaPhone p, PersonId who, String currency) {
  for (final x in p.people()) {
    if (x.personId == who) return x.net[currency] ?? 0;
  }
  return 0;
}

/// "12.34" for 1234 INR minor units.
String _major(int minor) =>
    '${minor ~/ 100}.${(minor % 100).toString().padLeft(2, '0')}';

/// Opens Settle up for [from] -> [to] (INR) and, when [amount] is given,
/// enters it through "Pay part of it" / "Change amount".
Future<void> _open(
  WidgetTester tester,
  ProviderContainer c,
  GroupId g,
  MemberId from,
  MemberId to, {
  int? amount,
}) async {
  c
      .read(routerProvider)
      .go(Routes.settle(groupId: g, from: from, to: to, currency: 'INR'));
  await settle(tester);
  if (amount != null) await _enter(tester, amount);
}

Future<void> _enter(WidgetTester tester, int amount) async {
  final part = find.text('Pay part of it');
  await tester.tap(part.evaluate().isEmpty ? find.text('Change amount') : part);
  await settle(tester);
  await tester.enterText(find.byType(TextField).last, _major(amount));
  await settle(tester);
  await tester.tap(find.text('Done'));
  await settle(tester);
}

BeforeAfterTable _table(WidgetTester tester) =>
    tester.widget<BeforeAfterTable>(find.byType(BeforeAfterTable).last);

List<String> _texts(WidgetTester tester) => [
  for (final e in find.byType(Text).evaluate())
    if ((e.widget as Text).data case final String d) d,
];

Future<void> _tapRecord(WidgetTester tester) async {
  await tester.tap(find.textContaining(RegExp(r'^Record .* payment$')));
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// An OpStore that refuses writes while [fail] is set (a full disk).
final class _FlakyStore implements OpStore {
  final MemoryOpStore inner = MemoryOpStore();
  bool fail = false;

  @override
  Future<void> open() => inner.open();
  @override
  Future<void> close() => inner.close();
  @override
  Future<List<Operation>> insertAll(List<Operation> ops) {
    if (fail) throw StateError('disk full');
    return inner.insertAll(ops);
  }

  @override
  Future<List<Operation>> loadAll() => inner.loadAll();
  @override
  Future<VersionVector> versionVector(GroupId groupId) =>
      inner.versionVector(groupId);
  @override
  Future<List<Operation>> missingFor(GroupId groupId, VersionVector peer) =>
      inner.missingFor(groupId, peer);
  @override
  Future<int> maxCounter(GroupId groupId, DeviceId deviceId) =>
      inner.maxCounter(groupId, deviceId);
  @override
  Future<void> purgeGroup(GroupId groupId) => inner.purgeGroup(groupId);
  @override
  Future<VersionVector> peerKnowledge(GroupId groupId) =>
      inner.peerKnowledge(groupId);
  @override
  Future<void> recordPeerKnowledge(
    DeviceId peer,
    GroupId groupId,
    VersionVector vv,
  ) => inner.recordPeerKnowledge(peer, groupId, vv);
  @override
  Future<bool> capPeerKnowledge(GroupId groupId, DeviceId deviceId, int max) =>
      inner.capPeerKnowledge(groupId, deviceId, max);
  @override
  Future<String?> getKv(String key) => inner.getKv(key);
  @override
  Future<void> setKv(String key, String? value) => inner.setKv(key, value);
  @override
  Future<void> addSyncRecord(SyncRecord record) => inner.addSyncRecord(record);
  @override
  Future<List<SyncRecord>> syncRecords({int limit = 50}) =>
      inner.syncRecords(limit: limit);
}

void main() {
  // ------------------------------------------- MONEY-R24-01 widget class --

  // Every row of the table, before and after Record, is what the Group,
  // Person and Friends screens show once the payment is stored; and every
  // balance with me in the group that moves has a row.
  for (final simplify in [true, false]) {
    for (var seed = 1; seed <= 8; seed++) {
      testWidgets('R26 MONEY-R24-01 screen property (simplify '
          '${simplify ? 'on' : 'off'}, seed $seed): What changes and the '
          'frozen confirmation match the ledger after Record', (tester) async {
        final r = Random(seed * 104729 + (simplify ? 1 : 0));
        late QaPhone p;
        late GroupId g;
        late Map<String, MemberId> m;
        late MemberId from, to;
        late int amount;
        await tester.runAsync(() async {
          p = await QaPhone.create(prefix: 'eeeeeeee');
          final t = await p.group([
            'Sam',
            'Priya',
            'Dev',
            'Kai',
          ], simplify: simplify);
          g = t.g;
          m = t.m;
          final ms = m.values.toList();
          for (var i = 0; i < 4 + r.nextInt(5); i++) {
            final total = 100 + r.nextInt(20000);
            final payer = ms[r.nextInt(ms.length)];
            final owers = ([...ms]..shuffle(r)).take(1 + r.nextInt(4));
            await p.add(
              g,
              total: total,
              paidBy: one(payer, total),
              owedBy: eq(owers),
            );
          }
          final ts = p.transfers(g).where((x) => x.currency == 'INR').toList();
          final mine = ts
              .where((x) => x.from == m['me'] || x.to == m['me'])
              .toList();
          final pool = mine.isNotEmpty && r.nextInt(4) != 0 ? mine : ts;
          if (pool.isEmpty) {
            from = m['me']!;
            to = m['Sam']!;
            amount = 1 + r.nextInt(5000);
          } else {
            final tr = pool[r.nextInt(pool.length)];
            from = tr.from;
            to = tr.to;
            amount = switch (r.nextInt(3)) {
              0 when tr.amount > 1 => 1 + r.nextInt(tr.amount - 1),
              1 => tr.amount + 1 + r.nextInt(5000),
              _ => tr.amount,
            };
          }
        });
        final me = m['me']!;
        final nameOf = {
          for (final e in m.entries)
            if (e.key != 'me') e.value: e.key,
        };
        final personOf = {
          for (final id in m.values) id: p.gs(g).members[id]!.personId,
        };
        final pairsBefore = {
          for (final x in nameOf.keys) x: _pair(p, g, me, x, 'INR'),
        };
        final peopleBefore = {
          for (final x in nameOf.keys) x: _person(p, personOf[x]!, 'INR'),
        };
        final overallBefore = p.overall().net['INR'] ?? 0;
        final fromToBefore = _pair(p, g, from, to, 'INR');

        final c = await pumpReal(tester, p);
        await _open(tester, c, g, from, to, amount: amount);
        final preview = _table(tester).entries;
        final previewTitles = [for (final e in preview) e.title];
        await _tapRecord(tester);
        final frozen = _table(tester).entries;
        await settle(tester);
        await tester.runAsync(pumpEventQueue);
        final pay = p.gs(g).liveExpenses.where((e) => e.isPayment).single;
        expect((pay.payer, pay.receiver, pay.money.total), (from, to, amount));

        final why =
            'from ${nameOf[from] ?? 'me'} to ${nameOf[to] ?? 'me'} '
            '$amount (rows: $previewTitles)';
        expect(frozen.map((e) => e.title), previewTitles, reason: why);
        for (var i = 0; i < preview.length; i++) {
          final e = preview[i];
          final int now, after;
          final t = e.title;
          if (t == 'Your overall') {
            now = overallBefore;
            after = p.overall().net['INR'] ?? 0;
          } else if (t.startsWith('You and ')) {
            final x = nameOf.entries
                .firstWhere((n) => n.value == t.substring(8))
                .key;
            now = pairsBefore[x]!;
            after = _pair(p, g, me, x, 'INR');
          } else if (t.endsWith(' overall')) {
            final x = nameOf.entries
                .firstWhere((n) => n.value == t.substring(0, t.length - 8))
                .key;
            now = peopleBefore[x]!;
            after = _person(p, personOf[x]!, 'INR');
          } else {
            // "Dev and Priya": the third-party pair, unsigned.
            now = fromToBefore.abs();
            after = _pair(p, g, from, to, 'INR').abs();
          }
          expect(e.now.minor, now, reason: '$why: $t now');
          expect(e.after.minor, after, reason: '$why: $t after');
          expect(frozen[i].after.minor, after, reason: '$why: $t frozen');
          expect(frozen[i].now.minor, after, reason: '$why: $t frozen now');
        }
        // Completeness when I am the payer or the one paid (the payment
        // between two others is MONEY-R26-01).
        if (from == me || to == me) {
          for (final x in nameOf.keys) {
            if (_pair(p, g, me, x, 'INR') != pairsBefore[x]) {
              expect(
                previewTitles,
                contains('You and ${nameOf[x]}'),
                reason: '$why: my balance with ${nameOf[x]} moved',
              );
            }
          }
          expect(previewTitles.last, 'Your overall', reason: why);
        }
        await tester.runAsync(p.dispose);
      });
    }
  }

  testWidgets('R26 MONEY-R24-01: "Sam overall" counts Sam in another group '
      'and our direct group, before and after the payment', (tester) async {
    late QaPhone p;
    late GroupId g;
    late MemberId me, sam;
    late PersonId samPerson;
    await tester.runAsync(() async {
      p = await QaPhone.create();
      final t = await p.group(['Sam', 'Priya', 'Dev']);
      g = t.g;
      me = t.m['me']!;
      sam = t.m['Sam']!;
      final priya = t.m['Priya']!, dev = t.m['Dev']!;
      samPerson = p.gs(g).members[sam]!.personId;
      await p.add(
        g,
        total: 6000,
        paidBy: one(sam, 6000),
        owedBy: one(me, 6000),
      );
      await p.add(
        g,
        total: 4000,
        paidBy: one(priya, 4000),
        owedBy: spec(SplitMethod.exact, {me: 1000, dev: 3000}),
      );
      // Sam also owes me 15 in a second group (same person).
      final g2 = await p.ledger.createGroup(
        NewGroup(
          name: 'Flat',
          type: GroupType.home,
          currency: 'INR',
          simplifyDebts: true,
          existingPeople: [(personId: samPerson, displayName: 'Sam')],
        ),
      );
      await pumpEventQueue();
      final s2 = p.gs(g2).memberForPerson(samPerson)!.id;
      final me2 = p.gs(g2).memberForPerson(p.me)!.id;
      await p.add(
        g2,
        total: 1500,
        paidBy: one(me2, 1500),
        owedBy: one(s2, 1500),
      );
      // And I owe Sam 5 in our direct group.
      final d = await p.ledger.directGroupWith(
        personId: samPerson,
        displayName: 'Sam',
        currency: 'INR',
      );
      await pumpEventQueue();
      final s3 = p.gs(d).memberForPerson(samPerson)!.id;
      final me3 = p.gs(d).memberForPerson(p.me)!.id;
      await p.add(d, total: 500, paidBy: one(s3, 500), owedBy: one(me3, 500));
    });
    expect(_person(p, samPerson, 'INR'), -5000);
    final c = await pumpReal(tester, p);
    await _open(tester, c, g, me, sam, amount: 2500);
    final rows = {for (final e in _table(tester).entries) e.title: e};
    expect(rows['Sam overall']!.now.minor, -5000);
    await tester.runAsync(() => p.pay(g, from: me, to: sam, amount: 2500));
    expect(rows['Sam overall']!.after.minor, _person(p, samPerson, 'INR'));
    expect(rows['You and Sam']!.after.minor, _pair(p, g, me, sam, 'INR'));
    await tester.runAsync(p.dispose);
  });

  // ---------------------------------------------------------- new: R26 --

  testWidgets(
    'QA MONEY-R26-01: a payment between two others that moves my balances '
    'lists none of them under What changes',
    (tester) async {
      late QaPhone p;
      late GroupId g;
      late MemberId me, sam, priya, dev;
      await tester.runAsync(() async {
        p = await QaPhone.create();
        final t = await p.group(['Sam', 'Priya', 'Dev']);
        g = t.g;
        me = t.m['me']!;
        sam = t.m['Sam']!;
        priya = t.m['Priya']!;
        dev = t.m['Dev']!;
        // Suggested: I pay Sam 60, Dev pays Priya 30, I pay Priya 10.
        await p.add(
          g,
          total: 6000,
          paidBy: one(sam, 6000),
          owedBy: one(me, 6000),
        );
        await p.add(
          g,
          total: 4000,
          paidBy: one(priya, 4000),
          owedBy: spec(SplitMethod.exact, {me: 1000, dev: 3000}),
        );
      });
      expect(_pair(p, g, me, priya, 'INR'), -1000);
      expect(_pair(p, g, me, dev, 'INR'), 0);
      final c = await pumpReal(tester, p);
      // Dev pays Priya 50 of the 30 he owes her.
      await _open(tester, c, g, dev, priya, amount: 5000);
      final titles = [for (final e in _table(tester).entries) e.title];
      await tester.runAsync(() => p.pay(g, from: dev, to: priya, amount: 5000));
      // The ledger now has me paying Dev 10 instead of Priya 10.
      expect(_pair(p, g, me, priya, 'INR'), 0);
      expect(_pair(p, g, me, dev, 'INR'), -1000);
      expect(
        titles,
        containsAll(['You and Priya', 'You and Dev']),
        reason: 'my balance with Priya and with Dev both move',
      );
      await tester.runAsync(p.dispose);
    },
  );

  testWidgets(
    'QA MONEY-R26-02: after a save fails, the over-payment sentence stays '
    'on screen and in the confirmation for a smaller amount',
    skip: true, // QA MONEY-R26-02: after a failed save the over-payment sentence no longer follows the amount
    (tester) async {
      final store = _FlakyStore();
      late KvSettingsRepository settings;
      late Ledger ledger;
      late GroupId g;
      late MemberId me, sam;
      var clock = kBaseMs;
      await tester.runAsync(() async {
        await store.open();
        settings = await KvSettingsRepository.open(
          store,
          defaultDeviceName: 'Alex phone',
          ids: ScriptedIds('aaaaffff'),
          localeName: 'en_IN',
        );
        await settings.completeOnboarding(
          displayName: 'Alex',
          homeCurrency: 'INR',
        );
        ledger = await Ledger.open(
          store: store,
          keys: MemoryGroupKeyStore(),
          settings: settings,
          ids: ScriptedIds('aaaaaaaa'),
          nowMillis: () => clock += 1000,
        );
        g = await ledger.createGroup(
          const NewGroup(
            name: 'Trip',
            type: GroupType.trip,
            currency: 'INR',
            simplifyDebts: true,
            newMemberNames: ['Sam'],
          ),
        );
        final gs = ledger.current.state.groups[g]!;
        me = gs.memberForPerson(settings.profile!.personId)!.id;
        sam = gs.members.keys.firstWhere((x) => x != me);
        await ledger.addExpense(
          ExpenseDraft(
            groupId: g,
            description: 'Cab',
            total: 6000,
            currency: 'INR',
            paidBy: one(sam, 6000),
            owedBy: one(me, 6000),
            category: 'food.dining',
            date: utcFromMillis(kBaseMs),
          ),
        );
      });
      tester.view.physicalSize = const Size(412, 915) * 2;
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.reset);
      final c = ProviderContainer(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(settings),
          ledgerRepositoryProvider.overrideWithValue(ledger),
          syncEngineProvider.overrideWithValue(
            FakeSyncEngine(step: Duration.zero),
          ),
          clockProvider.overrideWithValue(() => DateTime.utc(2026, 11, 9, 10)),
        ],
      );
      addTearDown(c.dispose);
      await tester.pumpWidget(
        UncontrolledProviderScope(container: c, child: const SettleUpApp()),
      );
      await settle(tester);
      // I owe Sam 60 and type 70.
      await _open(tester, c, g, me, sam, amount: 7000);
      expect(
        _texts(tester),
        contains("That's ₹10 more than the balance. Sam will owe you ₹10."),
      );
      // The save fails (storage), the user lowers the amount to 40.
      store.fail = true;
      await _tapRecord(tester);
      await settle(tester);
      store.fail = false;
      expect(ledger.current.state.groups[g]!.liveExpenses.length, 1);
      await _enter(tester, 4000);
      expect(find.text('Record ₹40 payment'), findsOneWidget);
      expect(
        _texts(tester).where((s) => s.contains('more than the balance')),
        isEmpty,
        reason: '₹40 is less than the ₹60 I owe Sam',
      );
      await _tapRecord(tester);
      expect(
        _texts(tester).where((s) => s.contains('more than the balance')),
        isEmpty,
        reason: 'the confirmation of a ₹40 payment',
      );
      await settle(tester);
      await tester.runAsync(() async {
        await pumpEventQueue();
        await ledger.close();
      });
    },
  );
}
