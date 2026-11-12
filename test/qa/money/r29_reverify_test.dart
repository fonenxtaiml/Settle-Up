// QA MONEY round 29: reverification of MONEY-R28-01 (Expense detail
// Delete closed whatever was on top) and a sweep of the same class around
// the changed delete path: a detail screen with no screen under it, one
// opened from Activity, a payment's detail, Restore on the deleted banner,
// and the balances after each.
//
// Tests named "QA MONEY-R29-NN" with `skip:` are failing repros of an open
// finding.
import 'dart:async';

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
import 'package:settle_up/ui/screens/activity/activity_screen.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/screens/expense/expense_detail_screen.dart';
import 'package:settle_up/ui/screens/expense/expense_edit_screen.dart';
import 'package:settle_up/ui/screens/group/group_screen.dart';

import 'money_harness.dart';
import 'settle_screen_currency_test.dart' show settle;

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

typedef _World = ({
  _SlowStore store,
  Ledger ledger,
  ProviderContainer c,
  GroupId g,
  MemberId me,
  MemberId sam,
  ExpenseId cab,
});

/// Me and Sam (INR, simplify on), Sam paid a 60 cab for me. The app is on
/// the group screen.
Future<_World> _world(WidgetTester tester) async {
  final store = _SlowStore();
  late KvSettingsRepository settings;
  late Ledger ledger;
  late GroupId g;
  late MemberId me, sam;
  late ExpenseId cab;
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
    cab = await ledger.addExpense(
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
  c.read(routerProvider).go(Routes.group(g));
  await settle(tester);
  return (store: store, ledger: ledger, c: c, g: g, me: me, sam: sam, cab: cab);
}

Future<void> _push(WidgetTester tester, _World w, String location) async {
  unawaited(w.c.read(routerProvider).push(location));
  await settle(tester);
}

Future<void> _release(WidgetTester tester, _World w) async {
  w.store.gate!.complete();
  w.store.gate = null;
  await tester.runAsync(pumpEventQueue);
  await settle(tester);
  await settle(tester);
}

Future<void> _done(WidgetTester tester, _World w) async {
  await tester.runAsync(pumpEventQueue);
  await w.ledger.close();
}

/// Confirms Delete on the Expense detail on top and holds the write.
Future<void> _heldDelete(WidgetTester tester, _World w) async {
  await tester.tap(find.byTooltip('More options'));
  await settle(tester);
  await tester.tap(find.text('Delete expense'));
  await settle(tester);
  w.store.gate = Completer<void>();
  await tester.tap(find.text('Delete'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

/// Taps Edit and More options as the impatient user does while the delete
/// is held; neither may open anything.
Future<void> _pokeControls(WidgetTester tester) async {
  for (final tip in ['Edit', 'More options']) {
    final f = find.byTooltip(tip);
    if (f.evaluate().isNotEmpty) {
      await tester.tap(f.first, warnIfMissed: false);
      await settle(tester);
    }
  }
}

Map<MemberId, int> _nets(_World w) {
  final nets = w.c.read(groupNetsProvider(w.g)).value!;
  for (final e in nets.entries) {
    expect(
      e.value.values.fold<int>(0, (a, b) => a + b),
      0,
      reason: 'nets sum to zero in ${e.key}',
    );
  }
  return {
    for (final e in (nets['INR'] ?? const <MemberId, int>{}).entries)
      if (e.value != 0) e.key: e.value,
  };
}

int _opCount(_World w) => w.ledger.current.state.groups[w.g]!.expenses.length;

void main() {
  testWidgets('R29 MONEY-R28-01: Expense detail with no screen under it '
      '(opened by a link): the held delete opens nothing and lands on the '
      'group screen with the Undo snack', (tester) async {
    final w = await _world(tester);
    w.c.read(routerProvider).go(Routes.expense(w.cab, groupId: w.g));
    await settle(tester);
    expect(find.byType(ExpenseDetailScreen), findsOneWidget);
    await _heldDelete(tester, w);
    await _pokeControls(tester);
    expect(find.byType(ExpenseEditScreen), findsNothing);
    expect(find.byType(PopupMenuItem<Object?>), findsNothing);
    await _release(tester, w);
    expect(w.ledger.current.state.expenseIn(w.g, w.cab)!.isDeleted, isTrue);
    expect(find.byType(ExpenseDetailScreen), findsNothing);
    expect(find.byType(GroupScreen), findsOneWidget);
    expect(find.text('Expense deleted'), findsOneWidget);
    expect(_nets(w), isEmpty);
    await _done(tester, w);
  });

  testWidgets('R29 MONEY-R28-01: Expense detail opened from Activity: the '
      'held delete opens nothing and returns to Activity, which stays', (
    tester,
  ) async {
    final w = await _world(tester);
    w.c.read(routerProvider).go(Routes.activity);
    await settle(tester);
    expect(find.byType(ActivityScreen), findsOneWidget);
    await _push(tester, w, Routes.expense(w.cab, groupId: w.g));
    expect(find.byType(ExpenseDetailScreen), findsOneWidget);
    await _heldDelete(tester, w);
    await _pokeControls(tester);
    expect(find.byType(ExpenseEditScreen), findsNothing);
    await _release(tester, w);
    expect(w.ledger.current.state.expenseIn(w.g, w.cab)!.isDeleted, isTrue);
    expect(find.byType(ExpenseDetailScreen), findsNothing);
    expect(find.byType(ActivityScreen), findsOneWidget);
    expect(_nets(w), isEmpty);
    await _done(tester, w);
  });

  testWidgets('R29 MONEY-R28-01: a payment\'s detail: the held delete opens '
      'nothing (Edit payment, menu) and closes only the detail; the debt '
      'comes back exactly', (tester) async {
    final w = await _world(tester);
    late ExpenseId pay;
    await tester.runAsync(() async {
      pay = await w.ledger.recordPayment(
        PaymentDraft(
          groupId: w.g,
          from: w.me,
          to: w.sam,
          amount: 2500,
          currency: 'INR',
          method: PaymentMethod.cash,
          date: utcFromMillis(kBaseMs),
        ),
      );
    });
    await settle(tester);
    expect(_nets(w), {w.me: -3500, w.sam: 3500});
    await _push(tester, w, Routes.expense(pay, groupId: w.g));
    expect(find.byType(ExpenseDetailScreen), findsOneWidget);
    await _heldDelete(tester, w);
    await _pokeControls(tester);
    expect(find.byType(ExpenseEditScreen), findsNothing);
    expect(find.byType(Dialog), findsNothing);
    await _release(tester, w);
    expect(w.ledger.current.state.expenseIn(w.g, pay)!.isDeleted, isTrue);
    expect(find.byType(ExpenseDetailScreen), findsNothing);
    expect(find.byType(GroupScreen), findsOneWidget);
    expect(_nets(w), {w.me: -6000, w.sam: 6000});
    await _done(tester, w);
  });

  testWidgets('R29 class: back during the held delete, then the same expense '
      'opened again from the group: the old delete does not close the new '
      'detail screen', (tester) async {
    final w = await _world(tester);
    await _push(tester, w, Routes.expense(w.cab, groupId: w.g));
    await _heldDelete(tester, w);
    await tester.tap(find.byType(BackArrow));
    await settle(tester);
    expect(find.byType(GroupScreen), findsOneWidget);
    await tester.tap(find.text('Cab').first);
    await settle(tester);
    expect(find.byType(ExpenseDetailScreen), findsOneWidget);
    await _release(tester, w);
    expect(w.ledger.current.state.expenseIn(w.g, w.cab)!.isDeleted, isTrue);
    expect(
      find.byType(ExpenseDetailScreen),
      findsOneWidget,
      reason: 'the reopened detail stays and shows the deleted banner',
    );
    expect(find.text('Restore'), findsWidgets);
    expect(_nets(w), isEmpty);
    // Back from the reopened detail lands on the group, still there.
    await tester.tap(find.byType(BackArrow));
    await settle(tester);
    expect(find.byType(GroupScreen), findsOneWidget);
    await _done(tester, w);
  });

  testWidgets('R29 class: Restore tapped twice on the deleted banner while '
      'the write is held restores once and stays on the detail', (
    tester,
  ) async {
    final w = await _world(tester);
    await tester.runAsync(() => w.ledger.deleteExpense(w.cab, groupId: w.g));
    await settle(tester);
    final before = w.ledger.current.state.groups[w.g]!.expenses.length;
    await _push(tester, w, Routes.expense(w.cab, groupId: w.g));
    expect(_nets(w), isEmpty);
    w.store.gate = Completer<void>();
    final restore = find.widgetWithText(FilledButton, 'Restore');
    await tester.tap(restore);
    await tester.pump();
    if (restore.evaluate().isNotEmpty) {
      await tester.tap(restore, warnIfMissed: false);
      await tester.pump();
    }
    await _release(tester, w);
    expect(w.ledger.current.state.expenseIn(w.g, w.cab)!.isDeleted, isFalse);
    expect(_opCount(w), before, reason: 'no new expense from a double tap');
    expect(find.byType(ExpenseDetailScreen), findsOneWidget);
    expect(find.byTooltip('Edit'), findsOneWidget);
    expect(_nets(w), {w.me: -6000, w.sam: 6000});
    expect(find.textContaining('error', findRichText: true), findsNothing);
    await _done(tester, w);
  });
}
