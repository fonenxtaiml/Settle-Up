// PLATFORM-R1-02 / -11: permissions are asked for, and every radio problem
// on the Sync tab has a way out.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/transport/transport.dart';
import 'package:settle_up/ui/app.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/screens/sync/radios.dart';
import 'package:settle_up/ui/strings.dart';

import '../../qa/platform/sync_permission_flow_test.dart' show RecordingEngine;
import '../screens/screen_harness.dart';

Future<RecordingEngine> pumpSync(
  WidgetTester tester,
  Map<TransportKind, TransportAvailability> before, {
  Map<TransportKind, TransportAvailability>? after,
}) async {
  final world = await TestWorld.demo();
  final engine = RecordingEngine(world.engine)
    ..before = before
    ..afterRequest = after;
  phoneView(tester);
  world.container = ProviderContainer(
    overrides: [
      settingsRepositoryProvider.overrideWithValue(world.settings),
      ledgerRepositoryProvider.overrideWithValue(world.ledger),
      syncEngineProvider.overrideWithValue(engine),
      clockProvider.overrideWithValue(() => referenceNow),
    ],
  );
  addTearDown(world.container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: world.container,
      child: const SettleUpApp(),
    ),
  );
  await settle(tester);
  world.go(Routes.sync);
  await settle(tester);
  return engine;
}

void main() {
  test('issues are ordered and specific', () {
    expect(
      radioIssues({
        TransportKind.lan: TransportAvailability.radioOff,
        TransportKind.nearby: TransportAvailability.needsPermission,
        TransportKind.ble: TransportAvailability.permissionPermanentlyDenied,
      }),
      [RadioIssue.permissionDenied, RadioIssue.wifiOff],
    );
    expect(
      radioIssues({
        TransportKind.lan: TransportAvailability.ready,
        TransportKind.nearby: TransportAvailability.unsupported,
        TransportKind.ble: TransportAvailability.radioOff,
      }),
      [RadioIssue.bluetoothOff],
    );
    expect(
      radioIssues({
        for (final k in TransportKind.values) k: TransportAvailability.ready,
      }),
      isEmpty,
    );
  });

  testWidgets('a refused dialog offers Allow, which asks again', (
    tester,
  ) async {
    final denied = {
      TransportKind.lan: TransportAvailability.ready,
      TransportKind.nearby: TransportAvailability.needsPermission,
      TransportKind.ble: TransportAvailability.needsPermission,
    };
    final engine = await pumpSync(tester, denied, after: denied);
    expect(find.text(S.radiosAskTitle), findsOneWidget);
    final asked = engine.calls.where((c) => c.startsWith('request')).length;
    await tester.tap(find.text(S.allow));
    await settle(tester);
    expect(
      engine.calls.where((c) => c.startsWith('request')).length,
      asked + 1,
    );
  });

  testWidgets('Bluetooth off shows Turn on Bluetooth; nothing when ready', (
    tester,
  ) async {
    await pumpSync(tester, {
      TransportKind.lan: TransportAvailability.ready,
      TransportKind.nearby: TransportAvailability.ready,
      TransportKind.ble: TransportAvailability.radioOff,
    });
    expect(find.text(S.turnOnBluetooth), findsOneWidget);
    expect(find.text(S.openSettings), findsNothing);
    expect(find.text(S.allow), findsNothing);
  });
}
