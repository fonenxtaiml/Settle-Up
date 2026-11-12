// MONEY-R27-01 class: while a form is being saved (and on Settle up once
// the payment is recorded) nothing the save is built from can change and
// nothing can open over the screen that is about to close; the screen then
// closes itself and only itself.
// - Settle up: every control (method, Date, Notes, Change amount) during a
//   held write and during the recorded animation, seeded random taps; what
//   is stored is what the confirmation shows; a failed save unlocks;
//   closing twice (Close during the animation, then its end) closes Settle
//   up once and leaves the group screen under it.
// - Edit payment: the same lock and close over a held write.
// - closeScreen / bringScreenToFront: a pop-up over the screen is closed
//   with it, a screen already closing is left alone.
import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
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
import 'package:settle_up/ui/screens/expense/payment_edit.dart';
import 'package:settle_up/ui/screens/group/group_screen.dart';
import 'package:settle_up/ui/screens/settle/settle_screen.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import '../../qa/money/money_harness.dart';
import '../../qa/money/settle_screen_currency_test.dart' show settle;

/// An OpStore whose writes wait for [gate] while it is set (a slow disk)
/// and are refused while [fail] is set (a full disk).
final class _GatedStore implements OpStore {
  final MemoryOpStore inner = MemoryOpStore();
  Completer<void>? gate;
  bool fail = false;

  @override
  Future<void> open() => inner.open();
  @override
  Future<void> close() => inner.close();
  @override
  Future<List<Operation>> insertAll(List<Operation> ops) async {
    final g = gate;
    if (g != null) await g.future;
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

typedef _World = ({
  _GatedStore store,
  Ledger ledger,
  GroupId g,
  ProviderContainer c,
});

/// Me and Sam, I owe Sam 60 (INR); the group screen is open.
Future<_World> _world(WidgetTester tester) async {
  final store = _GatedStore();
  late KvSettingsRepository settings;
  late Ledger ledger;
  late GroupId g;
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
    final me = gs.memberForPerson(settings.profile!.personId)!.id;
    final sam = gs.members.keys.firstWhere((x) => x != me);
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
  c.read(routerProvider).go(Routes.group(g));
  await settle(tester);
  return (store: store, ledger: ledger, g: g, c: c);
}

Future<void> _openSettle(WidgetTester tester, _World w) async {
  final gs = w.ledger.current.state.groups[w.g]!;
  final me = gs.members.values.firstWhere((m) => m.displayName == 'Alex').id;
  final sam = gs.members.values.firstWhere((m) => m.displayName == 'Sam').id;
  unawaited(
    w.c
        .read(routerProvider)
        .push(Routes.settle(groupId: w.g, from: me, to: sam, currency: 'INR')),
  );
  await settle(tester);
  expect(find.byType(SettleScreen), findsOneWidget);
}

Future<void> _done(WidgetTester tester, _World w) async {
  await tester.runAsync(pumpEventQueue);
  await w.ledger.close();
}

List<Expense> _payments(_World w) => [
  ...w.ledger.current.state.groups[w.g]!.liveExpenses.where((e) => e.isPayment),
];

PaymentMethod _shownMethod(WidgetTester tester) => tester
    .widget<PaymentMethodSelector>(find.byType(PaymentMethodSelector))
    .value;

KeyValueRow _row(WidgetTester tester, String label) => tester
    .widgetList<KeyValueRow>(find.byType(KeyValueRow))
    .firstWhere((r) => r.label == label);

/// Nothing is open over the screen: no dialog, picker, prompt or sheet.
void _nothingOpenOver() {
  expect(find.byType(Dialog), findsNothing);
  expect(find.byType(BottomSheet), findsNothing);
}

const _methodLabels = {
  PaymentMethod.upi: 'UPI',
  PaymentMethod.cash: 'Cash',
  PaymentMethod.bank: 'Bank',
  PaymentMethod.other: 'Other',
};

/// Taps one of the controls the payment is built from, chosen by [rng].
Future<void> _tapSomething(WidgetTester tester, Random rng) async {
  final targets = [
    ..._methodLabels.values.map(find.text),
    find.text('Date'),
    find.text('Note'),
    find.text('Pay part of it'),
    find.text('Change amount'),
  ];
  final t = targets[rng.nextInt(targets.length)];
  if (t.evaluate().isEmpty) return;
  await tester.tap(t.first, warnIfMissed: false);
  await tester.pump();
}

void main() {
  for (var seed = 1; seed <= 8; seed++) {
    testWidgets('MONEY-R27-01 property (seed $seed): during the save and the '
        'recorded animation every control is locked, what is stored is what '
        'is shown, and Settle up closes itself once', (tester) async {
      final rng = Random(seed);
      final w = await _world(tester);
      await _openSettle(tester, w);
      // A method picked before Record is the one stored.
      final picked = PaymentMethod.values[rng.nextInt(4)];
      await tester.tap(find.text(_methodLabels[picked]!));
      await tester.pump();
      expect(_shownMethod(tester), picked);

      w.store.gate = Completer<void>();
      await tester.tap(find.text('Record ₹60 payment'));
      await tester.pump();
      // Locked while saving.
      expect(
        tester
            .widget<PaymentMethodSelector>(find.byType(PaymentMethodSelector))
            .onChanged,
        isNull,
      );
      expect(_row(tester, 'Date').onTap, isNull);
      expect(_row(tester, 'Note').onTap, isNull);
      for (var i = 0; i < 6; i++) {
        await _tapSomething(tester, rng);
        _nothingOpenOver();
        expect(_shownMethod(tester), picked);
      }
      w.store.gate!.complete();
      w.store.gate = null;
      await tester.runAsync(pumpEventQueue);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      // Recorded, the animation is playing: still locked.
      for (var i = 0; i < 4; i++) {
        await _tapSomething(tester, rng);
        _nothingOpenOver();
        expect(_shownMethod(tester), picked);
      }
      final pay = _payments(w).single;
      expect(pay.paymentMethod, picked);
      expect(pay.money.total, 6000);
      expect(pay.notes, '');
      await settle(tester);
      await settle(tester);
      _nothingOpenOver();
      expect(find.byType(SettleScreen), findsNothing);
      expect(find.byType(GroupScreen), findsOneWidget);
      expect(find.text('Payment recorded'), findsOneWidget);
      expect(_payments(w), hasLength(1));
      await _done(tester, w);
    });
  }

  testWidgets('MONEY-R27-01: a failed save unlocks the controls and the '
      'method changed afterwards is the one stored', (tester) async {
    final w = await _world(tester);
    await _openSettle(tester, w);
    w.store.fail = true;
    await tester.tap(find.text('Record ₹60 payment'));
    await tester.runAsync(pumpEventQueue);
    await settle(tester);
    expect(_payments(w), isEmpty);
    expect(
      tester
          .widget<PaymentMethodSelector>(find.byType(PaymentMethodSelector))
          .onChanged,
      isNotNull,
    );
    expect(_row(tester, 'Date').onTap, isNotNull);
    expect(_row(tester, 'Note').onTap, isNotNull);
    await tester.tap(find.text('Bank'));
    await tester.pump();
    w.store.fail = false;
    await tester.tap(find.text('Record ₹60 payment'));
    await tester.runAsync(pumpEventQueue);
    await settle(tester);
    await settle(tester);
    expect(_payments(w).single.paymentMethod, PaymentMethod.bank);
    expect(find.byType(SettleScreen), findsNothing);
    expect(find.byType(GroupScreen), findsOneWidget);
    await _done(tester, w);
  });

  testWidgets('MONEY-R27-01: Close during the recorded animation and the '
      'animation end close Settle up once, not the group under it', (
    tester,
  ) async {
    final w = await _world(tester);
    await _openSettle(tester, w);
    await tester.tap(find.text('Record ₹60 payment'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(_payments(w), hasLength(1));
    await tester.tap(find.byTooltip('Close'));
    await tester.pump();
    await settle(tester);
    await settle(tester);
    expect(find.byType(SettleScreen), findsNothing);
    expect(find.byType(GroupScreen), findsOneWidget);
    expect(find.text('Payment recorded'), findsOneWidget);
    await _done(tester, w);
  });

  testWidgets('MONEY-R27-01 class: Edit payment is locked while it is saved, '
      'stores what it showed and closes only itself', (tester) async {
    final w = await _world(tester);
    await _openSettle(tester, w);
    await tester.tap(find.text('Record ₹60 payment'));
    await tester.runAsync(pumpEventQueue);
    await settle(tester);
    await settle(tester);
    final pay = _payments(w).single;
    expect(pay.paymentMethod, PaymentMethod.upi);
    unawaited(
      w.c.read(routerProvider).push(Routes.editExpense(pay.id, groupId: w.g)),
    );
    await settle(tester);
    expect(find.byType(PaymentEditScreen), findsOneWidget);
    await tester.tap(find.text('Cash'));
    await tester.pump();
    w.store.gate = Completer<void>();
    await tester.tap(find.text('Save changes'));
    await tester.pump();
    expect(
      tester
          .widget<PaymentMethodSelector>(find.byType(PaymentMethodSelector))
          .onChanged,
      isNull,
    );
    for (final t in ['Bank', 'Other', 'UPI', 'Date']) {
      await tester.tap(find.text(t).first, warnIfMissed: false);
      await tester.pump();
      _nothingOpenOver();
      expect(_shownMethod(tester), PaymentMethod.cash);
    }
    // No text field takes the keyboard while saving.
    await tester.tap(find.byType(TextField).last, warnIfMissed: false);
    await tester.pump();
    expect(
      tester
          .widgetList<EditableText>(find.byType(EditableText))
          .any((e) => e.focusNode.hasFocus),
      isFalse,
    );
    w.store.gate!.complete();
    w.store.gate = null;
    await tester.runAsync(pumpEventQueue);
    await settle(tester);
    expect(_payments(w).single.paymentMethod, PaymentMethod.cash);
    expect(find.byType(PaymentEditScreen), findsNothing);
    expect(find.byType(GroupScreen), findsOneWidget);
    await _done(tester, w);
  });

  group('closeScreen', () {
    late BuildContext screen;
    late GoRouter router;

    Future<void> pump(WidgetTester tester) async {
      router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) => const Scaffold(body: Text('below')),
          ),
          GoRoute(
            path: '/a',
            builder: (_, _) => Scaffold(
              body: Builder(
                builder: (context) {
                  screen = context;
                  return const Text('screen');
                },
              ),
            ),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(MaterialApp.router(routerConfig: router));
      unawaited(router.push('/a'));
      await tester.pumpAndSettle();
      expect(find.text('screen'), findsOneWidget);
    }

    testWidgets('closes a pop-up open over the screen together with it', (
      tester,
    ) async {
      await pump(tester);
      unawaited(
        showDialog<void>(
          context: screen,
          builder: (_) => const AlertDialog(content: Text('picker')),
        ),
      );
      unawaited(
        showModalBottomSheet<void>(
          context: screen,
          builder: (_) => const Text('sheet'),
        ),
      );
      await tester.pumpAndSettle();
      expect(closeScreen(screen, fallback: '/'), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('picker'), findsNothing);
      expect(find.text('sheet'), findsNothing);
      expect(find.text('screen'), findsNothing);
      expect(find.text('below'), findsOneWidget);
    });

    testWidgets('leaves a screen that is already closing alone', (
      tester,
    ) async {
      await pump(tester);
      final ctx = screen;
      expect(closeScreen(ctx, fallback: '/'), isTrue);
      // Closed again in the same frame (Close and the end of the
      // animation), and once the first close has taken effect.
      expect(closeScreen(ctx, fallback: '/'), isFalse);
      await tester.pump();
      // Closed twice while the first close is still animating.
      expect(closeScreen(ctx, fallback: '/'), isFalse);
      expect(bringScreenToFront(ctx), isFalse);
      await tester.pumpAndSettle();
      expect(find.text('below'), findsOneWidget);
    });

    testWidgets('goes to the fallback when nothing is below', (tester) async {
      await pump(tester);
      router.go('/a');
      await tester.pumpAndSettle();
      expect(closeScreen(screen, fallback: '/'), isTrue);
      await tester.pumpAndSettle();
      expect(find.text('below'), findsOneWidget);
    });
  });

  testWidgets('InputLock: no tap and no focus reach a locked form', (
    tester,
  ) async {
    var taps = 0;
    final focus = FocusNode();
    addTearDown(focus.dispose);
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    Widget form(bool locked) => MaterialApp(
      home: Scaffold(
        body: InputLock(
          locked: locked,
          child: Column(
            children: [
              TextButton(onPressed: () => taps++, child: const Text('tap')),
              TextField(focusNode: focus, controller: controller),
            ],
          ),
        ),
      ),
    );
    await tester.pumpWidget(form(false));
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(focus.hasFocus, isTrue);
    // Locking takes the focus away from a field that had it.
    await tester.pumpWidget(form(true));
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    await tester.tap(find.text('tap'), warnIfMissed: false);
    await tester.tap(find.byType(TextField), warnIfMissed: false);
    await tester.pump();
    expect(taps, 0);
    expect(focus.hasFocus, isFalse);
    focus.requestFocus();
    await tester.pump();
    expect(focus.hasFocus, isFalse);
    await tester.pumpWidget(form(false));
    await tester.tap(find.text('tap'));
    expect(taps, 1);
  });
}
