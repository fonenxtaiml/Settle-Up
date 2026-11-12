// Settle up "What changes" on the real screen over a real Ledger:
// - MONEY-R26-01: every balance with me that a payment moves is listed,
//   whoever pays whom, and nothing that does not move is listed as "You
//   and X" (seeded random groups, simplify on and off, payments between
//   two other people included);
// - MONEY-R26-02: a save that fails leaves nothing frozen: the
//   over-payment sentence, the table and the confirmation follow the
//   amount entered afterwards (seeded amounts, under, equal and over).
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/balances.dart';
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
import 'package:settle_up/ui/format/money_format.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/widgets/settle_controls.dart';

import '../../qa/money/money_harness.dart';
import '../../qa/money/settle_screen_currency_test.dart' show pumpReal, settle;

int _pair(List<Transfer> ts, MemberId a, MemberId b) {
  var v = 0;
  for (final t in ts) {
    if (t.currency != 'INR') continue;
    if (t.from == a && t.to == b) v -= t.amount;
    if (t.to == a && t.from == b) v += t.amount;
  }
  return v;
}

String _major(int minor) =>
    '${minor ~/ 100}.${(minor % 100).toString().padLeft(2, '0')}';

Future<void> _enter(WidgetTester tester, int amount) async {
  final part = find.text('Pay part of it');
  await tester.tap(part.evaluate().isEmpty ? find.text('Change amount') : part);
  await settle(tester);
  await tester.enterText(find.byType(TextField).last, _major(amount));
  await settle(tester);
  await tester.tap(find.text('Done'));
  await settle(tester);
}

List<BeforeAfterEntry> _rows(WidgetTester tester) =>
    tester.widget<BeforeAfterTable>(find.byType(BeforeAfterTable).last).entries;

List<String> _overpayTexts(WidgetTester tester) => [
  for (final e in find.byType(Text).evaluate())
    if ((e.widget as Text).data case final String d
        when d.contains('more than the balance'))
      d,
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
final class _FailingStore implements OpStore {
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
  // MONEY-R26-01: the "You and X" rows are exactly the members whose
  // balance with me moves, for any payer and any one paid.
  for (final simplify in [true, false]) {
    for (var seed = 1; seed <= 10; seed++) {
      testWidgets('MONEY-R26-01 property (simplify ${simplify ? 'on' : 'off'}, '
          'seed $seed): every balance with me that moves is listed', (
        tester,
      ) async {
        final r = Random(seed * 7919 + (simplify ? 3 : 0));
        late QaPhone p;
        late GroupId g;
        late Map<String, MemberId> m;
        late MemberId from, to;
        late int amount;
        await tester.runAsync(() async {
          p = await QaPhone.create(prefix: 'cccccccc');
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
          // Mostly payments between two other people (the R26-01 case).
          final others = ts
              .where((x) => x.from != m['me'] && x.to != m['me'])
              .toList();
          final pool = others.isNotEmpty && r.nextInt(4) != 0 ? others : ts;
          if (pool.isEmpty) {
            from = m['Dev']!;
            to = m['Priya']!;
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
        final before = p.transfers(g);
        final c = await pumpReal(tester, p);
        c
            .read(routerProvider)
            .go(Routes.settle(groupId: g, from: from, to: to, currency: 'INR'));
        await settle(tester);
        await _enter(tester, amount);
        final rows = {for (final e in _rows(tester)) e.title: e};
        await tester.runAsync(
          () => p.pay(g, from: from, to: to, amount: amount),
        );
        final after = p.transfers(g);
        final why =
            'from ${nameOf[from] ?? 'me'} to ${nameOf[to] ?? 'me'} '
            '$amount (rows: ${rows.keys.toList()})';
        final counterpart = from == me ? to : (to == me ? from : null);
        for (final x in nameOf.keys) {
          final title = 'You and ${nameOf[x]}';
          final moved = _pair(before, me, x) != _pair(after, me, x);
          if (x == counterpart || moved) {
            expect(rows.keys, contains(title), reason: '$why: $title');
            expect(rows[title]!.now.minor, _pair(before, me, x), reason: why);
            expect(rows[title]!.after.minor, _pair(after, me, x), reason: why);
          } else {
            expect(rows.keys, isNot(contains(title)), reason: '$why: $title');
          }
        }
        await tester.runAsync(p.dispose);
      });
    }
  }

  // MONEY-R26-02: over-pay, the save fails, then a seeded second amount.
  // Whatever it is, the sentence, the table and the confirmation are the
  // second amount's.
  for (var seed = 1; seed <= 6; seed++) {
    testWidgets('MONEY-R26-02 property (seed $seed): after a failed save the '
        'screen follows the next amount', (tester) async {
      final r = Random(seed * 31337);
      final store = _FailingStore();
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
          ids: ScriptedIds('bbbbffff'),
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
          ids: ScriptedIds('bbbbbbbb'),
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
      c
          .read(routerProvider)
          .go(Routes.settle(groupId: g, from: me, to: sam, currency: 'INR'));
      await settle(tester);

      const owed = 6000;
      final first = owed + 100 * (1 + r.nextInt(50));
      await _enter(tester, first);
      expect(_overpayTexts(tester), hasLength(1));
      store.fail = true;
      await _tapRecord(tester);
      await settle(tester);
      store.fail = false;
      expect(ledger.current.state.groups[g]!.liveExpenses.length, 1);

      final second = switch (seed % 3) {
        0 => 100 * (1 + r.nextInt(59)),
        1 => owed,
        _ => owed + 100 * (1 + r.nextInt(50)),
      };
      await _enter(tester, second);
      final label = 'Record ${MoneyFormat.format(second, 'INR')} payment';
      expect(find.text(label), findsOneWidget);
      final expected = second > owed
          ? [
              "That's ${MoneyFormat.format(second - owed, 'INR')} more than "
                  'the balance. Sam will owe you '
                  '${MoneyFormat.format(second - owed, 'INR')}.',
            ]
          : <String>[];
      expect(_overpayTexts(tester), expected, reason: 'amount $second');
      final pairAfter = owed - second; // > 0: I still owe Sam.
      final row = _rows(tester).firstWhere((e) => e.title == 'You and Sam');
      expect(row.now.minor, -owed);
      expect(row.after.minor, -pairAfter, reason: 'amount $second');

      await _tapRecord(tester);
      expect(
        _overpayTexts(tester),
        expected,
        reason: 'confirmation of $second',
      );
      final frozen = _rows(tester).firstWhere((e) => e.title == 'You and Sam');
      expect(frozen.after.minor, -pairAfter);
      await settle(tester);
      final pays = ledger.current.state.groups[g]!.liveExpenses
          .where((e) => e.isPayment)
          .toList();
      expect(pays.single.money.total, second);
      // The last write was started by a tap (in the test's fake-async
      // zone), so the ledger's queue completes there: close it in that
      // zone, not inside runAsync, where its await never resumes.
      await tester.runAsync(pumpEventQueue);
      await ledger.close();
    });
  }
}
