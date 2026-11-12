// QA MONEY round 28: reverification of MONEY-R27-01 (Settle up keeps its
// controls live while the payment is saved and closes whatever is on top)
// and a sweep of the same class on the other screens that save money and
// then leave: Edit payment and Expense detail delete.
//
// Tests named "QA MONEY-R28-NN" with `skip:` are failing repros of an open
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
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/screens/expense/expense_detail_screen.dart';
import 'package:settle_up/ui/screens/expense/payment_edit.dart';
import 'package:settle_up/ui/screens/group/group_screen.dart';
import 'package:settle_up/ui/screens/settle/settle_screen.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

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

List<Expense> _payments(_World w) => w
    .ledger
    .current
    .state
    .groups[w.g]!
    .liveExpenses
    .where((e) => e.isPayment)
    .toList();

void main() {
  // ---------------------------------------- MONEY-R27-01 reverification --

  for (final control in ['Cash', 'Date', 'Note', 'Pay part of it']) {
    testWidgets('R28 MONEY-R27-01: "$control" tapped while the payment is '
        'saved changes nothing and opens nothing; Settle up closes itself and '
        'only itself', (tester) async {
      final w = await _world(tester);
      await _push(
        tester,
        w,
        Routes.settle(groupId: w.g, from: w.me, to: w.sam, currency: 'INR'),
      );
      w.store.gate = Completer<void>();
      await tester.tap(find.text('Record ₹60 payment'));
      await tester.pump();
      await tester.tap(find.text(control), warnIfMissed: false);
      await settle(tester);
      expect(find.byType(Dialog), findsNothing, reason: 'nothing opened');
      expect(find.byType(BottomSheet), findsNothing, reason: 'nothing opened');
      expect(
        tester
            .widget<PaymentMethodSelector>(find.byType(PaymentMethodSelector))
            .value,
        PaymentMethod.upi,
      );
      await _release(tester, w);
      final pays = _payments(w);
      expect(pays, hasLength(1));
      expect(pays.single.paymentMethod, PaymentMethod.upi);
      expect(pays.single.money.total, 6000);
      expect(find.byType(SettleScreen), findsNothing);
      expect(find.byType(GroupScreen), findsOneWidget);
      expect(find.text('Payment recorded'), findsOneWidget);
      await _done(tester, w);
    });
  }

  testWidgets('R28 MONEY-R27-01: close tapped during the recorded animation '
      'closes Settle up once, never the group under it', (tester) async {
    final w = await _world(tester);
    await _push(
      tester,
      w,
      Routes.settle(groupId: w.g, from: w.me, to: w.sam, currency: 'INR'),
    );
    await tester.tap(find.text('Record ₹60 payment'));
    await tester.runAsync(pumpEventQueue);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.byType(BackArrow));
    await settle(tester);
    await settle(tester);
    expect(find.byType(SettleScreen), findsNothing);
    expect(find.byType(GroupScreen), findsOneWidget);
    expect(find.text('Payment recorded'), findsOneWidget);
    expect(_payments(w), hasLength(1));
    await _done(tester, w);
  });

  testWidgets('R28 MONEY-R27-01: back tapped while the payment is saved '
      'leaves the group screen in place once the save lands', (tester) async {
    final w = await _world(tester);
    await _push(
      tester,
      w,
      Routes.settle(groupId: w.g, from: w.me, to: w.sam, currency: 'INR'),
    );
    w.store.gate = Completer<void>();
    await tester.tap(find.text('Record ₹60 payment'));
    await tester.pump();
    await tester.tap(find.byType(BackArrow));
    await tester.pump(const Duration(milliseconds: 50));
    await _release(tester, w);
    expect(find.byType(SettleScreen), findsNothing);
    expect(find.byType(GroupScreen), findsOneWidget);
    expect(_payments(w), hasLength(1));
    await _done(tester, w);
  });

  // ------------------------------------ class sweep: Edit payment save --

  for (final control in ['Cash', 'Date', 'notes']) {
    testWidgets('R28 class: Edit payment, "$control" tapped while saving '
        'opens nothing and the form closes only itself', (tester) async {
      final w = await _world(tester);
      late ExpenseId pay;
      await tester.runAsync(() async {
        pay = await w.ledger.recordPayment(
          PaymentDraft(
            groupId: w.g,
            from: w.me,
            to: w.sam,
            amount: 6000,
            currency: 'INR',
            method: PaymentMethod.upi,
            date: utcFromMillis(kBaseMs),
          ),
        );
      });
      await settle(tester);
      await _push(tester, w, Routes.expense(pay, groupId: w.g));
      await _push(tester, w, Routes.editExpense(pay, groupId: w.g));
      expect(find.byType(PaymentEditScreen), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, '50');
      await settle(tester);
      w.store.gate = Completer<void>();
      await tester.tap(find.text('Save changes'));
      await tester.pump();
      final target = control == 'notes'
          ? find.byType(TextField).last
          : find.text(control);
      await tester.tap(target, warnIfMissed: false);
      await settle(tester);
      expect(find.byType(Dialog), findsNothing);
      await _release(tester, w);
      final p = w.ledger.current.state.expenseIn(w.g, pay)!;
      expect(p.money.total, 5000);
      expect(p.paymentMethod, PaymentMethod.upi);
      expect(find.byType(PaymentEditScreen), findsNothing);
      expect(find.byType(ExpenseDetailScreen), findsOneWidget);
      await _done(tester, w);
    });
  }

  // ----------------------------- class sweep: Expense detail delete --

  testWidgets(
    'R28 class: back tapped on Expense detail while its delete is saved '
    'leaves the group screen under it in place',
    (tester) async {
      final w = await _world(tester);
      await _push(tester, w, Routes.expense(w.cab, groupId: w.g));
      expect(find.byType(ExpenseDetailScreen), findsOneWidget);
      await tester.tap(find.byTooltip('More options'));
      await settle(tester);
      await tester.tap(find.text('Delete expense'));
      await settle(tester);
      w.store.gate = Completer<void>();
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // The write is held: the user goes back to the group.
      await tester.tap(find.byType(BackArrow));
      await tester.pump(const Duration(milliseconds: 50));
      w.store.gate!.complete();
      w.store.gate = null;
      await tester.runAsync(pumpEventQueue);
      await settle(tester);
      await settle(tester);
      expect(w.ledger.current.state.expenseIn(w.g, w.cab)!.isDeleted, isTrue);
      expect(find.byType(ExpenseDetailScreen), findsNothing);
      expect(
        find.byType(GroupScreen),
        findsOneWidget,
        reason:
            'the delete closes the detail screen only, not the screen '
            'the user went back to',
      );
      await _done(tester, w);
    },
  );

  testWidgets(
    'QA MONEY-R28-01: Edit tapped on Expense detail while its delete is saved '
    'is closed by the delete in place of the detail screen',
    (tester) async {
      final w = await _world(tester);
      await _push(tester, w, Routes.expense(w.cab, groupId: w.g));
      await tester.tap(find.byTooltip('More options'));
      await settle(tester);
      await tester.tap(find.text('Delete expense'));
      await settle(tester);
      w.store.gate = Completer<void>();
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final edit = find.byTooltip('Edit');
      final editable = edit.evaluate().isNotEmpty;
      if (editable) await tester.tap(edit);
      await settle(tester);
      w.store.gate!.complete();
      w.store.gate = null;
      await tester.runAsync(pumpEventQueue);
      await settle(tester);
      await settle(tester);
      expect(w.ledger.current.state.expenseIn(w.g, w.cab)!.isDeleted, isTrue);
      expect(
        (
          find.byType(ExpenseDetailScreen).evaluate().length,
          find.byType(GroupScreen).evaluate().length,
        ),
        (0, 1),
        reason:
            'the delete closes the detail screen and lands on the group '
            '(Edit was ${editable ? '' : 'not '}reachable during the save)',
      );
      await _done(tester, w);
    },
    skip: true, // QA MONEY-R28-01: Expense detail delete pops whatever was opened over it
  );

  testWidgets(
    'QA MONEY-R28-01: the menu opened on Expense detail while its delete is '
    'saved is closed by the delete in place of the detail screen',
    (tester) async {
      final w = await _world(tester);
      await _push(tester, w, Routes.expense(w.cab, groupId: w.g));
      await tester.tap(find.byTooltip('More options'));
      await settle(tester);
      await tester.tap(find.text('Delete expense'));
      await settle(tester);
      w.store.gate = Completer<void>();
      await tester.tap(find.text('Delete'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byTooltip('More options'));
      await settle(tester);
      w.store.gate!.complete();
      w.store.gate = null;
      await tester.runAsync(pumpEventQueue);
      await settle(tester);
      await settle(tester);
      expect(w.ledger.current.state.expenseIn(w.g, w.cab)!.isDeleted, isTrue);
      expect(
        (
          find.byType(ExpenseDetailScreen).evaluate().length,
          find.byType(GroupScreen).evaluate().length,
        ),
        (0, 1),
        reason: 'the delete closes the detail screen and lands on the group',
      );
      await _done(tester, w);
    },
    skip: true, // QA MONEY-R28-01: Expense detail delete pops whatever was opened over it
  );
}
