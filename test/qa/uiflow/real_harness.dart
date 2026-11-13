// QA UIFLOW harness: the real app (router, theme, screens) over the REAL
// data layer: Ledger(MemoryOpStore) + KvSettingsRepository, and the real
// DefaultSyncEngine with no transports (nothing to reach, but invites,
// links and status work exactly as on a phone).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/ui/app.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/form_tiles.dart';

final DateTime qaNow = DateTime(2026, 11, 9, 10);

/// One phone: real store, settings, ledger and sync engine.
final class RealWorld {
  RealWorld._(this.store, this.settings, this.ledger, this.engine);

  final MemoryOpStore store;
  final KvSettingsRepository settings;
  final Ledger ledger;
  final DefaultSyncEngine engine;
  late ProviderContainer container;

  /// A fresh install (no profile). With [name], onboarding is already done.
  static Future<RealWorld> create({
    String? name,
    String homeCurrency = 'INR',
    MemoryOpStore? store,
    int idSeed = 1,
  }) async {
    final s = store ?? MemoryOpStore();
    await s.open();
    final ids = SequentialIdGenerator(idSeed);
    final settings = await KvSettingsRepository.open(
      s,
      defaultDeviceName: 'Pixel 8',
      ids: ids,
      localeName: 'en_IN',
    );
    if (name != null) {
      await settings.completeOnboarding(
        displayName: name,
        homeCurrency: homeCurrency,
      );
    }
    final ledger = await Ledger.open(
      store: s,
      keys: MemoryGroupKeyStore(),
      settings: settings,
      ids: ids,
      nowMillis: () => qaNow.millisecondsSinceEpoch,
    );
    final engine = DefaultSyncEngine(store: ledger, transports: const []);
    return RealWorld._(s, settings, ledger, engine);
  }

  LedgerState get state => ledger.current.state;

  GroupState group(GroupId id) => state.groups[id]!;

  /// The only group with [name].
  GroupState groupNamed(String name) =>
      state.visibleGroups.singleWhere((g) => g.group!.name == name);

  MemberId member(GroupId g, String displayName) => group(
    g,
  ).activeMembers.firstWhere((m) => m.displayName == displayName).id;

  GoRouter get router => container.read(routerProvider);

  void go(String location) => container.read(routerProvider).go(location);
  void push(String location) => container.read(routerProvider).push(location);
  String get location => container.read(routerProvider).state.uri.toString();

  /// Creates a group straight through the ledger (setup for later steps).
  Future<GroupId> seedGroup({
    String name = 'Goa trip',
    List<String> people = const ['Priya', 'Rahul'],
    String currency = 'INR',
    bool simplify = true,
  }) => ledger.createGroup(
    NewGroup(
      name: name,
      type: GroupType.trip,
      currency: currency,
      simplifyDebts: simplify,
      newMemberNames: people,
    ),
  );

  /// Unmounts the app and stops the engine so no timer outlives the test.
  Future<void> shutdown(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await engine.dispose();
    await tester.pump(const Duration(seconds: 1));
  }
}

void qaPhone(WidgetTester tester, {Size size = const Size(412, 915)}) {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  tester.view.padding = const FakeViewPadding(top: 36 * 2, bottom: 24 * 2);
  addTearDown(tester.view.reset);
}

Future<void> pumpReal(
  WidgetTester tester,
  RealWorld world, {
  String? location,
}) async {
  world.container = ProviderContainer(
    overrides: [
      settingsRepositoryProvider.overrideWithValue(world.settings),
      ledgerRepositoryProvider.overrideWithValue(world.ledger),
      syncEngineProvider.overrideWithValue(world.engine),
      clockProvider.overrideWithValue(() => qaNow),
    ],
  );
  addTearDown(world.container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: world.container,
      child: const SettleUpApp(),
    ),
  );
  await qaSettle(tester);
  if (location != null) {
    world.go(location);
    await qaSettle(tester);
  }
}

/// Lets streams deliver and animations finish (spinners never stop, so no
/// pumpAndSettle).
Future<void> qaSettle(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 400));
}

/// Taps [finder] after scrolling it into view.
Future<void> qaTap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pump();
  await tester.tap(finder);
  await qaSettle(tester);
}

/// The text field labelled [label]: the field of the LabeledTextField
/// with that label (it draws the label above its TextField), or a
/// TextField with that labelText.
Finder fieldLabeled(String label) => find.byElementPredicate((e) {
  final w = e.widget;
  if (w is! TextField) return false;
  if (w.decoration?.labelText == label) return true;
  var labeled = false;
  e.visitAncestorElements((a) {
    final aw = a.widget;
    if (aw is! LabeledTextField) return true;
    labeled = aw.label == label;
    return false;
  });
  return labeled;
});

FilledButton filledButton(WidgetTester tester, String label) =>
    tester.widget<FilledButton>(
      find.ancestor(
        of: find.text(label),
        matching: find.byWidgetPredicate((w) => w is FilledButton),
      ).first,
    );

/// Current snack bar text, or null.
String? snackText(WidgetTester tester) {
  final f = find.descendant(
    of: find.byType(SnackBar),
    matching: find.byType(Text),
  );
  if (f.evaluate().isEmpty) return null;
  return tester.widget<Text>(f.first).data;
}

/// Onboards through the real screen.
Future<void> onboardThroughUi(WidgetTester tester, String name) async {
  expect(find.text(S.onboardingTitle), findsOneWidget);
  await tester.enterText(find.byType(TextField).first, name);
  await tester.pump();
  await tester.tap(find.text(S.getStarted));
  await qaSettle(tester);
}

/// Scrolls the screen's main list until [finder] is built and visible.
Future<void> qaReveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    300,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pump();
}
