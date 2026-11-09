// Pumps the real app (router, theme, screens) over the fakes, seeded with
// the demo world at the reference time (Sun 9 Nov 2026, 10:00).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/ui/app.dart';
import 'package:settle_up/ui/dev/fake_ledger.dart';
import 'package:settle_up/ui/dev/fake_settings.dart';
import 'package:settle_up/ui/dev/fake_sync_engine.dart';
import 'package:settle_up/ui/dev/seed_data.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';

final DateTime referenceNow = DateTime(2026, 11, 9, 10);

/// A fake world plus the container the app runs in.
final class TestWorld {
  TestWorld({
    required this.settings,
    required this.ledger,
    required this.engine,
    this.groups,
  });

  final FakeSettingsRepository settings;
  final FakeLedgerRepository ledger;
  final FakeSyncEngine engine;
  final DemoGroups? groups;
  late final ProviderContainer container;

  static Future<TestWorld> demo() async {
    final w = await createDemoWorld(
      now: referenceNow,
      ids: SequentialIdGenerator(),
      syncStep: Duration.zero,
    );
    return TestWorld(
      settings: w.settings,
      ledger: w.ledger,
      engine: w.engine,
      groups: w.groups,
    );
  }

  static TestWorld empty() {
    final settings = FakeSettingsRepository(
      device: const DeviceIdentity(
        deviceId: DemoIds.thisPhone,
        deviceName: 'Pixel 8',
      ),
      ids: SequentialIdGenerator(1000),
    );
    final ledger = FakeLedgerRepository(
      settings: settings,
      ids: SequentialIdGenerator(),
      nowMillis: () => referenceNow.millisecondsSinceEpoch,
    );
    final engine = FakeSyncEngine(
      ledger: ledger,
      settings: settings,
      now: () => referenceNow,
      step: Duration.zero,
    );
    return TestWorld(settings: settings, ledger: ledger, engine: engine);
  }

  DemoGroups get g => groups!;

  /// The member id of [person] in [groupId].
  String member(String groupId, String person) =>
      ledger.current.state.groups[groupId]!.memberForPerson(person)!.id;

  void go(String location) => container.read(routerProvider).go(location);
  void push(String location) => container.read(routerProvider).push(location);
}

/// Sets a 412 x 915 dp phone at 2x with status and gesture bars.
void phoneView(WidgetTester tester, {Size size = const Size(412, 915)}) {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  tester.view.padding = const FakeViewPadding(top: 36 * 2, bottom: 24 * 2);
  addTearDown(tester.view.reset);
}

Future<void> pumpApp(
  WidgetTester tester,
  TestWorld world, {
  String? location,
  Brightness brightness = Brightness.light,
  double textScale = 1,
}) async {
  await world.settings.updateSettings(
    world.settings.settings.copyWith(
      themeMode: brightness == Brightness.dark
          ? AppThemeMode.dark
          : AppThemeMode.light,
    ),
  );
  world.container = ProviderContainer(
    overrides: [
      settingsRepositoryProvider.overrideWithValue(world.settings),
      ledgerRepositoryProvider.overrideWithValue(world.ledger),
      syncEngineProvider.overrideWithValue(world.engine),
      clockProvider.overrideWithValue(() => referenceNow),
    ],
  );
  addTearDown(world.container.dispose);
  if (textScale != 1) {
    tester.platformDispatcher.textScaleFactorTestValue = textScale;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: world.container,
      child: const SettleUpApp(),
    ),
  );
  await settle(tester);
  if (location != null) {
    world.go(location);
    await settle(tester);
  }
}

/// Lets streams deliver and animations finish without waiting on the
/// spinners that never stop.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 400));
}
