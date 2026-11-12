// MONEY-R28-01 class: a screen that saves something and then leaves takes
// no input while the write is pending, so nothing (Edit, a menu, a prompt,
// another screen) can open over it and be closed by the save in its place;
// it then closes itself and only itself.
// - Expense detail delete: seeded random taps on every control during a
//   held write; a failed delete unlocks; a pop-up opened over the screen
//   some other way is closed with it; Undo on the snack restores.
// - Edit group archive: Members and Delete group are locked during a held
//   write, the screen closes only itself; a failed archive unlocks.
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
import 'package:settle_up/ui/screens/expense/expense_detail_screen.dart';
import 'package:settle_up/ui/screens/expense/expense_edit_screen.dart';
import 'package:settle_up/ui/screens/group/group_edit_screen.dart';
import 'package:settle_up/ui/screens/group/group_screen.dart';
import 'package:settle_up/ui/screens/group/members_screen.dart';

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
  ExpenseId cab,
});

/// Me and Sam, Sam paid a 60 cab for me (INR); the group screen is open.
Future<_World> _world(WidgetTester tester) async {
  final store = _GatedStore();
  late KvSettingsRepository settings;
  late Ledger ledger;
  late GroupId g;
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
    final me = gs.memberForPerson(settings.profile!.personId)!.id;
    final sam = gs.members.keys.firstWhere((x) => x != me);
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
  return (store: store, ledger: ledger, g: g, c: c, cab: cab);
}

Future<void> _done(WidgetTester tester, _World w) async {
  await tester.runAsync(pumpEventQueue);
  await w.ledger.close();
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

/// Opens the cab's detail and confirms Delete expense; the write is held
/// when [hold] is set.
Future<void> _deleteCab(
  WidgetTester tester,
  _World w, {
  bool hold = true,
}) async {
  await tester.tap(find.byTooltip('More options'));
  await settle(tester);
  await tester.tap(find.text('Delete expense'));
  await settle(tester);
  if (hold) w.store.gate = Completer<void>();
  await tester.tap(find.text('Delete'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Expense _cab(_World w) => w.ledger.current.state.expenseIn(w.g, w.cab)!;

/// Nothing is open over the detail screen.
void _nothingOver() {
  expect(find.byType(Dialog), findsNothing);
  expect(find.byType(BottomSheet), findsNothing);
  expect(find.text('Delete expense'), findsNothing, reason: 'menu closed');
  expect(find.byType(ExpenseEditScreen), findsNothing);
}

void _onGroupWithUndo() {
  expect(find.byType(ExpenseDetailScreen), findsNothing);
  expect(find.byType(GroupScreen), findsOneWidget);
  expect(find.text('Expense deleted'), findsOneWidget);
  expect(find.text('Undo'), findsOneWidget);
}

void main() {
  for (var seed = 1; seed <= 6; seed++) {
    testWidgets('MONEY-R28-01 property (seed $seed): while the delete is '
        'saved no control on Expense detail opens anything, and the delete '
        'closes the detail screen and only it', (tester) async {
      final rng = Random(seed);
      final w = await _world(tester);
      await _push(tester, w, Routes.expense(w.cab, groupId: w.g));
      await _deleteCab(tester, w);
      final targets = [
        find.byTooltip('Edit'),
        find.byTooltip('More options'),
        find.text('Cab'),
        find.text('Sam'),
        find.text('Restore'),
      ];
      for (var i = 0; i < 6; i++) {
        final t = targets[rng.nextInt(targets.length)];
        if (t.evaluate().isNotEmpty) {
          await tester.tap(t.first, warnIfMissed: false);
        }
        await settle(tester);
        _nothingOver();
        expect(find.byType(ExpenseDetailScreen), findsOneWidget);
      }
      await _release(tester, w);
      expect(_cab(w).isDeleted, isTrue);
      _nothingOver();
      _onGroupWithUndo();
      await _done(tester, w);
    });
  }

  testWidgets('MONEY-R28-01: Edit and the menu are disabled while the delete '
      'is saved', (tester) async {
    final w = await _world(tester);
    await _push(tester, w, Routes.expense(w.cab, groupId: w.g));
    await _deleteCab(tester, w);
    final edit = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.edit_outlined),
        matching: find.byType(IconButton),
      ),
    );
    expect(edit.onPressed, isNull);
    expect(
      tester
          .widget<PopupMenuButton<Object?>>(
            find.byWidgetPredicate((x) => x is PopupMenuButton),
          )
          .enabled,
      isFalse,
    );
    await _release(tester, w);
    _onGroupWithUndo();
    await _done(tester, w);
  });

  testWidgets('MONEY-R28-01: a failed delete unlocks Expense detail, and a '
      'second delete then lands on the group screen', (tester) async {
    final w = await _world(tester);
    await _push(tester, w, Routes.expense(w.cab, groupId: w.g));
    w.store.fail = true;
    await _deleteCab(tester, w, hold: false);
    await tester.runAsync(pumpEventQueue);
    await settle(tester);
    expect(_cab(w).isDeleted, isFalse);
    expect(find.byType(ExpenseDetailScreen), findsOneWidget);
    final edit = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.edit_outlined),
        matching: find.byType(IconButton),
      ),
    );
    expect(edit.onPressed, isNotNull);
    w.store.fail = false;
    await _deleteCab(tester, w);
    await _release(tester, w);
    expect(_cab(w).isDeleted, isTrue);
    _onGroupWithUndo();
    await _done(tester, w);
  });

  testWidgets('MONEY-R28-01: a pop-up opened over Expense detail some other '
      'way while the delete is saved is closed with the screen', (
    tester,
  ) async {
    final w = await _world(tester);
    await _push(tester, w, Routes.expense(w.cab, groupId: w.g));
    await _deleteCab(tester, w);
    unawaited(
      showDialog<void>(
        context: tester.element(find.byType(ExpenseDetailScreen)),
        builder: (_) => const AlertDialog(content: Text('over')),
      ),
    );
    await settle(tester);
    expect(find.text('over'), findsOneWidget);
    await _release(tester, w);
    expect(find.text('over'), findsNothing);
    _onGroupWithUndo();
    await _done(tester, w);
  });

  testWidgets('MONEY-R28-01: Undo on the snack after the delete restores the '
      'expense', (tester) async {
    final w = await _world(tester);
    await _push(tester, w, Routes.expense(w.cab, groupId: w.g));
    await _deleteCab(tester, w);
    await _release(tester, w);
    _onGroupWithUndo();
    await tester.tap(find.text('Undo'));
    await tester.runAsync(pumpEventQueue);
    await settle(tester);
    expect(_cab(w).isDeleted, isFalse);
    await _done(tester, w);
  });

  // ------------------------------------------ Edit group: archive --

  testWidgets('MONEY-R28-01 class: Edit group is locked while Archive is '
      'saved; Members and Delete group open nothing and the screen closes '
      'only itself', (tester) async {
    final w = await _world(tester);
    await _push(tester, w, Routes.editGroup(w.g));
    expect(find.byType(GroupEditScreen), findsOneWidget);
    await tester.ensureVisible(find.text('Archive group'));
    await settle(tester);
    w.store.gate = Completer<void>();
    await tester.tap(find.text('Archive group'));
    await tester.pump();
    for (final t in ['Members', 'Delete group', 'Archive group']) {
      await tester.tap(find.text(t), warnIfMissed: false);
      await settle(tester);
      expect(find.byType(MembersScreen), findsNothing);
      expect(find.byType(Dialog), findsNothing);
      expect(find.byType(GroupEditScreen), findsOneWidget);
    }
    await _release(tester, w);
    expect(w.ledger.current.state.groups[w.g]!.group!.archived, isTrue);
    expect(find.byType(GroupEditScreen), findsNothing);
    expect(find.byType(GroupScreen), findsOneWidget);
    expect(find.text('Group archived'), findsOneWidget);
    await _done(tester, w);
  });

  testWidgets('MONEY-R28-01 class: a failed archive unlocks Edit group', (
    tester,
  ) async {
    final w = await _world(tester);
    await _push(tester, w, Routes.editGroup(w.g));
    await tester.ensureVisible(find.text('Archive group'));
    await settle(tester);
    w.store.fail = true;
    await tester.tap(find.text('Archive group'));
    await tester.runAsync(pumpEventQueue);
    await settle(tester);
    expect(w.ledger.current.state.groups[w.g]!.group!.archived, isFalse);
    expect(find.byType(GroupEditScreen), findsOneWidget);
    w.store.fail = false;
    await tester.tap(find.text('Members'));
    await settle(tester);
    expect(find.byType(MembersScreen), findsOneWidget);
    await _done(tester, w);
  });
}
