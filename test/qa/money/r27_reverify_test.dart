// QA MONEY round 27: reverification of MONEY-R26-01 (What changes leaves
// out my balances moved by a payment between two others) and MONEY-R26-02
// (frozen Settle up state after a failed save) on the real Settle up
// screen over a real Ledger and the real providers, probing each class:
// - R26-01: seeded random 5-person groups, simplify on and off, INR and
//   USD, payments only between two other people (under, exact and over):
//   the "You and X" rows are exactly the members whose balance with me
//   moves, with the values the ledger shows once it is recorded; the
//   original vector with simplify off; a group I am not a member of.
// - R26-02: everything the payment is built from while it is being saved
//   (method, date, note) against what is stored and what the
//   confirmation shows (MONEY-R27-01: tests named "QA MONEY-R27-01" with
//   `skip: true` are failing repros of an open finding).
import 'dart:async';
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
import 'package:settle_up/ui/screens/settle/settle_screen.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'money_harness.dart';
import 'settle_screen_currency_test.dart' show pumpReal, settle;

int _pair(QaPhone p, GroupId g, MemberId a, MemberId b, String currency) {
  var v = 0;
  for (final t in p.transfers(g)) {
    if (t.currency != currency) continue;
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

/// An OpStore whose writes wait for [gate] while it is set (a slow disk).
final class _SlowStore implements OpStore {
  final MemoryOpStore inner = MemoryOpStore();
  Completer<void>? gate;

  @override
  Future<void> open() => inner.open();
  @override
  Future<void> close() => inner.close();
  @override
  Future<List<Operation>> insertAll(List<Operation> ops) async {
    final g = gate;
    if (g != null) await g.future;
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

/// Opens Settle up (INR) for me -> Sam (I owe Sam 60) over a [_SlowStore].
Future<({_SlowStore store, Ledger ledger, GroupId g})> _slowWorld(
  WidgetTester tester,
) async {
  final store = _SlowStore();
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
    await settings.completeOnboarding(displayName: 'Alex', homeCurrency: 'INR');
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
      syncEngineProvider.overrideWithValue(FakeSyncEngine(step: Duration.zero)),
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
  return (store: store, ledger: ledger, g: g);
}

void main() {
  // ------------------------------------------- MONEY-R26-01 class sweep --

  for (final simplify in [true, false]) {
    for (final currency in ['INR', 'USD']) {
      for (var seed = 1; seed <= 6; seed++) {
        testWidgets('R27 MONEY-R26-01 class (simplify '
            '${simplify ? 'on' : 'off'}, $currency, seed $seed): a payment '
            'between two others lists exactly the balances with me it '
            'moves', (tester) async {
          final r = Random(seed * 6151 + (simplify ? 7 : 0) + currency.length);
          late QaPhone p;
          late GroupId g;
          late Map<String, MemberId> m;
          MemberId? from, to;
          var amount = 0;
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
            for (var i = 0; i < 4 + r.nextInt(6); i++) {
              final total = 100 + r.nextInt(20000);
              final payer = ms[r.nextInt(ms.length)];
              final owers = ([...ms]..shuffle(r)).take(1 + r.nextInt(5));
              await p.add(
                g,
                total: total,
                currency: r.nextInt(3) == 0 ? 'INR' : currency,
                paidBy: one(payer, total),
                owedBy: eq(owers),
              );
            }
            final others = p
                .transfers(g)
                .where(
                  (x) =>
                      x.currency == currency &&
                      x.from != m['me'] &&
                      x.to != m['me'],
                )
                .toList();
            if (others.isEmpty) return;
            final tr = others[r.nextInt(others.length)];
            from = tr.from;
            to = tr.to;
            amount = switch (r.nextInt(3)) {
              0 when tr.amount > 1 => 1 + r.nextInt(tr.amount - 1),
              1 => tr.amount + 1 + r.nextInt(8000),
              _ => tr.amount,
            };
          });
          if (from == null) {
            await tester.runAsync(p.dispose);
            return; // nothing between two others in this seed
          }
          final me = m['me']!;
          final nameOf = {
            for (final e in m.entries)
              if (e.key != 'me') e.value: e.key,
          };
          final before = {
            for (final x in nameOf.keys) x: _pair(p, g, me, x, currency),
          };
          final c = await pumpReal(tester, p);
          c
              .read(routerProvider)
              .go(
                Routes.settle(
                  groupId: g,
                  from: from!,
                  to: to!,
                  currency: currency,
                ),
              );
          await settle(tester);
          if (amount != _pairAbs(p, g, from!, to!, currency)) {
            await _enter(tester, amount);
          }
          final rows = {for (final e in _rows(tester)) e.title: e};
          await tester.runAsync(
            () => p.pay(
              g,
              from: from!,
              to: to!,
              amount: amount,
              currency: currency,
            ),
          );
          final why =
              '${nameOf[from]} pays ${nameOf[to]} $amount $currency '
              '(rows: ${rows.keys.toList()})';
          for (final x in nameOf.keys) {
            final after = _pair(p, g, me, x, currency);
            final row = rows['You and ${nameOf[x]}'];
            if (after != before[x]) {
              expect(row, isNotNull, reason: '$why: me and ${nameOf[x]} moved');
              expect(row!.now.minor, before[x], reason: '$why: ${nameOf[x]}');
              expect(row.after.minor, after, reason: '$why: ${nameOf[x]}');
            } else {
              expect(row, isNull, reason: '$why: ${nameOf[x]} did not move');
            }
          }
          expect(rows.containsKey('Your overall'), isFalse, reason: why);
          await tester.runAsync(p.dispose);
        });
      }
    }
  }

  testWidgets('R27 MONEY-R26-01: the original vector with simplify off moves '
      'none of my balances and lists none', (tester) async {
    late QaPhone p;
    late GroupId g;
    late MemberId me, sam, priya, dev;
    await tester.runAsync(() async {
      p = await QaPhone.create();
      final t = await p.group(['Sam', 'Priya', 'Dev'], simplify: false);
      g = t.g;
      me = t.m['me']!;
      sam = t.m['Sam']!;
      priya = t.m['Priya']!;
      dev = t.m['Dev']!;
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
    final c = await pumpReal(tester, p);
    c
        .read(routerProvider)
        .go(Routes.settle(groupId: g, from: dev, to: priya, currency: 'INR'));
    await settle(tester);
    await _enter(tester, 5000);
    final titles = [for (final e in _rows(tester)) e.title];
    final before = [_pair(p, g, me, priya, 'INR'), _pair(p, g, me, dev, 'INR')];
    await tester.runAsync(() => p.pay(g, from: dev, to: priya, amount: 5000));
    final after = [_pair(p, g, me, priya, 'INR'), _pair(p, g, me, dev, 'INR')];
    expect(after, before);
    expect(titles, ['Dev and Priya']);
    await tester.runAsync(p.dispose);
  });

  testWidgets('R27 MONEY-R26-01: Settle up in a group I am not a member of '
      'shows only the pair', (tester) async {
    late QaPhone p;
    late GroupId g;
    late MemberId sam, priya;
    await tester.runAsync(() async {
      p = await QaPhone.create();
      final t = await p.group(['Sam', 'Priya']);
      g = t.g;
      sam = t.m['Sam']!;
      priya = t.m['Priya']!;
      await p.add(
        g,
        total: 6000,
        paidBy: one(sam, 6000),
        owedBy: eq([sam, priya]),
      );
      await p.ledger.removeMember(g, t.m['me']!);
      await pumpEventQueue();
    });
    final c = await pumpReal(tester, p);
    c
        .read(routerProvider)
        .go(Routes.settle(groupId: g, from: priya, to: sam, currency: 'INR'));
    await settle(tester);
    expect(tester.takeException(), isNull);
    final titles = [for (final e in _rows(tester)) e.title];
    expect(titles, ['Priya and Sam']);
    await tester.runAsync(p.dispose);
  });

  // ------------------------------------------- MONEY-R26-02 class sweep --

  testWidgets('R27 MONEY-R26-02: Change amount is disabled while the '
      'payment is saved and the held write stores the amount shown', (
    tester,
  ) async {
    final w = await _slowWorld(tester);
    await _enter(tester, 7000);
    expect(find.textContaining('more than the balance'), findsOneWidget);
    // Hold the write, check the screen is frozen while saving.
    w.store.gate = Completer<void>();
    await tester.tap(find.text('Record ₹70 payment'));
    await tester.pump();
    expect(
      tester
          .widgetList<TextLink>(find.byType(TextLink))
          .firstWhere((l) => l.label == 'Change amount')
          .onPressed,
      isNull,
    );
    w.store.gate!.complete();
    w.store.gate = null;
    await tester.runAsync(pumpEventQueue);
    await settle(tester);
    final pay = w.ledger.current.state.groups[w.g]!.liveExpenses
        .where((e) => e.isPayment)
        .single;
    expect(pay.money.total, 7000);
    await tester.runAsync(pumpEventQueue);
    await w.ledger.close();
  });

  testWidgets(
    'QA MONEY-R27-01: the method picked while the payment is saved is shown '
    'on the confirmation but not stored',
    skip: true, // QA MONEY-R27-01
    (tester) async {
      final w = await _slowWorld(tester);
      PaymentMethod shown() => tester
          .widget<PaymentMethodSelector>(find.byType(PaymentMethodSelector))
          .value;
      expect(shown(), PaymentMethod.upi);
      w.store.gate = Completer<void>();
      await tester.tap(find.text('Record ₹60 payment'));
      await tester.pump();
      // While the write is held, tap Cash.
      await tester.tap(find.text('Cash'));
      await tester.pump();
      final duringSave = shown();
      w.store.gate!.complete();
      w.store.gate = null;
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final atConfirmation = shown();
      final pay = w.ledger.current.state.groups[w.g]!.liveExpenses
          .where((e) => e.isPayment)
          .single;
      await settle(tester);
      expect(
        (duringSave, atConfirmation),
        (pay.paymentMethod, pay.paymentMethod),
        reason: 'the screen shows the method of the payment it recorded',
      );
      await tester.runAsync(pumpEventQueue);
      await w.ledger.close();
    },
  );

  testWidgets(
    'QA MONEY-R27-01: after Record, tapping Date before the screen closes '
    'leaves Settle up open (the close pops the picker)',
    skip: true, // QA MONEY-R27-01
    (tester) async {
      final w = await _slowWorld(tester);
      await tester.tap(find.text('Record ₹60 payment'));
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 50)),
      );
      await tester.pump();
      await tester.tap(find.text('Date'));
      await settle(tester);
      await settle(tester);
      final pays = w.ledger.current.state.groups[w.g]!.liveExpenses
          .where((e) => e.isPayment)
          .length;
      expect(pays, 1);
      // The picker the tap opened was closed by the screen's own close,
      // not the screen: no dialog is left and Settle up is still open.
      expect(find.byType(DatePickerDialog), findsNothing);
      expect(
        find.byType(SettleScreen),
        findsNothing,
        reason: 'the recorded Settle up closes itself',
      );
      await tester.runAsync(pumpEventQueue);
      await w.ledger.close();
    },
  );
}

int _pairAbs(QaPhone p, GroupId g, MemberId a, MemberId b, String c) =>
    _pair(p, g, a, b, c).abs();
