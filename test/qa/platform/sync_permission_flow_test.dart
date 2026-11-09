// QA PLATFORM round 1: does the app ever ask for the runtime permissions
// that Bluetooth and Nearby sync need (SPEC 8.10)?
//
// The engine and transports only report `needsPermission` until
// SyncEngine.requestPermissions runs (that is the only call that shows the
// system dialog). This drives the real app (router, Sync tab, visible
// switch) and records every engine call.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/transport.dart';
import 'package:settle_up/ui/app.dart';
import 'package:settle_up/ui/dev/fake_sync_engine.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/strings.dart';

import '../../ui/screens/screen_harness.dart';

/// Delegates to the demo FakeSyncEngine and records what the UI asked for.
final class RecordingEngine implements SyncEngine {
  RecordingEngine(this._inner);

  final FakeSyncEngine _inner;
  final List<String> calls = [];

  /// What the transports report before any permission request.
  Map<TransportKind, TransportAvailability> before = {
    TransportKind.lan: TransportAvailability.ready,
    TransportKind.nearby: TransportAvailability.needsPermission,
    TransportKind.ble: TransportAvailability.needsPermission,
  };

  /// What requestPermissions answers (null: everything ready).
  Map<TransportKind, TransportAvailability>? afterRequest;

  @override
  SyncStatus get status => _inner.status;
  @override
  Stream<SyncStatus> watchStatus() => _inner.watchStatus();
  @override
  Stream<List<NearbyPeer>> watchNearby() => _inner.watchNearby();
  @override
  Future<Map<TransportKind, TransportAvailability>> availability() async {
    calls.add('availability');
    return before;
  }

  @override
  Future<Map<TransportKind, TransportAvailability>> requestPermissions(
    Set<TransportKind> kinds,
  ) async {
    calls.add(
      'requestPermissions:${(kinds.map((k) => k.name).toList()..sort()).join(',')}',
    );
    return {
      for (final k in kinds) k: afterRequest?[k] ?? TransportAvailability.ready,
    };
  }

  @override
  Future<HostInfo> startHosting({
    Duration duration = const Duration(minutes: 5),
  }) {
    calls.add('startHosting');
    return _inner.startHosting(duration: duration);
  }

  @override
  Future<void> stopHosting() {
    calls.add('stopHosting');
    return _inner.stopHosting();
  }

  @override
  Future<void> startDiscovery({
    Set<TransportKind> kinds = const {
      TransportKind.lan,
      TransportKind.nearby,
      TransportKind.ble,
    },
  }) {
    calls.add('startDiscovery');
    return _inner.startDiscovery(kinds: kinds);
  }

  @override
  Future<void> stopDiscovery() {
    calls.add('stopDiscovery');
    return _inner.stopDiscovery();
  }

  @override
  Future<SyncSummary> syncWith(NearbyPeer peer) => _inner.syncWith(peer);
  @override
  Future<SyncSummary> syncWithLink(String link) => _inner.syncWithLink(link);
  @override
  Future<JoinResult> acceptInvite(String link) => _inner.acceptInvite(link);
  @override
  Future<String> inviteLinkFor(GroupId groupId, {bool includeHost = true}) =>
      _inner.inviteLinkFor(groupId, includeHost: includeHost);
  @override
  Future<void> cancel() => _inner.cancel();
  @override
  set liveMode(bool enabled) => _inner.liveMode = enabled;
  @override
  Stream<List<SyncRecord>> watchHistory() => _inner.watchHistory();
  @override
  Future<void> dispose() => _inner.dispose();
}

Future<(TestWorld, RecordingEngine)> _world() async {
  final demo = await TestWorld.demo();
  return (demo, RecordingEngine(demo.engine));
}

/// pumpApp (screen_harness.dart) with [engine] in place of the fake.
Future<void> _pumpWithEngine(
  WidgetTester tester,
  TestWorld world,
  RecordingEngine engine,
  String location,
) async {
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
  world.go(location);
  await settle(tester);
}

void main() {
  group('Sync tab asks for Bluetooth / Nearby permissions', () {
    testWidgets('opening Sync requests permissions before discovery', (
      tester,
    ) async {
      final (world, engine) = await _world();
      await _pumpWithEngine(tester, world, engine, Routes.sync);
      expect(engine.calls, contains('startDiscovery'));
      final ask = engine.calls.indexWhere(
        (c) => c.startsWith('requestPermissions') && c.contains('ble'),
      );
      expect(
        ask,
        isNot(-1),
        reason:
            'BLE/Nearby stay needsPermission forever unless the app '
            'calls requestPermissions; calls were ${engine.calls}',
      );
      expect(ask, lessThan(engine.calls.indexOf('startDiscovery')));
    });

    testWidgets('turning "visible" on requests permissions before hosting', (
      tester,
    ) async {
      final (world, engine) = await _world();
      await _pumpWithEngine(tester, world, engine, Routes.sync);
      await tester.tap(find.byType(Switch).first);
      await settle(tester);
      expect(engine.calls, contains('startHosting'));
      final ask = engine.calls.lastIndexWhere(
        (c) => c.startsWith('requestPermissions'),
      );
      expect(ask, isNot(-1), reason: 'calls were ${engine.calls}');
      expect(ask, lessThan(engine.calls.lastIndexOf('startHosting')));
      // Unmount before the container is disposed (the host card ticks).
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('a permanently denied permission has a way out', () {
    testWidgets(
      'Sync shows how to open app settings when Bluetooth permission is '
      'permanently denied',
      (tester) async {
        final (world, engine) = await _world();
        engine.before = {
          TransportKind.lan: TransportAvailability.radioOff,
          TransportKind.nearby:
              TransportAvailability.permissionPermanentlyDenied,
          TransportKind.ble: TransportAvailability.permissionPermanentlyDenied,
        };
        engine.afterRequest = engine.before;
        await _pumpWithEngine(tester, world, engine, Routes.sync);
        // Android never shows the dialog again after "Don't allow" twice;
        // only the app's system settings page can grant it now.
        expect(
          find.byWidgetPredicate(
            (w) =>
                (w is Text &&
                RegExp(
                  r'settings',
                  caseSensitive: false,
                ).hasMatch(w.data ?? '') &&
                !RegExp(r'^(Settings|Hotspot settings)$')
                    .hasMatch(w.data ?? '')),
          ),
          findsWidgets,
          reason: 'expected an "Open settings" style action on the Sync tab',
        );
      },
    );
  });

  // QA PLATFORM round 2.
  group('round 2: permission flow regressions', () {
    testWidgets('a granted dialog on the Sync tab lets discovery use '
        'Bluetooth, and no "Allow" row is left', (tester) async {
      final (world, engine) = await _world();
      await _pumpWithEngine(tester, world, engine, Routes.sync);
      expect(find.text(S.allow), findsNothing);
      expect(find.text(S.openSettings), findsNothing);
      expect(engine.calls, contains('startDiscovery'));
    });

    testWidgets('a denied (not permanent) dialog offers "Allow", which asks '
        'again', (tester) async {
      final (world, engine) = await _world();
      engine.afterRequest = {
        TransportKind.nearby: TransportAvailability.needsPermission,
        TransportKind.ble: TransportAvailability.needsPermission,
      };
      await _pumpWithEngine(tester, world, engine, Routes.sync);
      expect(find.text(S.allow), findsOneWidget);
      final asked = engine.calls
          .where((c) => c.startsWith('requestPermissions'))
          .length;
      await tester.tap(find.text(S.allow));
      await settle(tester);
      expect(
        engine.calls.where((c) => c.startsWith('requestPermissions')).length,
        asked + 1,
      );
    });

    testWidgets('back from settings with the permission granted: discovery '
        'starts again', (tester) async {
      final (world, engine) = await _world();
      engine.afterRequest = {
        TransportKind.nearby: TransportAvailability.needsPermission,
        TransportKind.ble: TransportAvailability.needsPermission,
      };
      await _pumpWithEngine(tester, world, engine, Routes.sync);
      final discoveries = engine.calls
          .where((c) => c == 'startDiscovery')
          .length;
      engine.before = {
        TransportKind.lan: TransportAvailability.ready,
        TransportKind.nearby: TransportAvailability.ready,
        TransportKind.ble: TransportAvailability.ready,
      };
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(
        engine.calls.where((c) => c == 'startDiscovery').length,
        discoveries + 1,
      );
      expect(find.text(S.allow), findsNothing);
    });

    // PLATFORM-R1-11 (reopened in round 2). On Android, permission_handler's
    // status() can never report permanentlyDenied (PermissionManager
    // "a status check cannot detect 'permanently denied'"); only request()
    // can. SyncEngine.availability() is status-only, so it reports
    // needsPermission for a permanently denied permission. The permission
    // dialog is an activity on top of ours, so closing it resumes the app,
    // and the Sync tab's resume re-check (availability only) replaces the
    // permanentlyDenied verdict from the request with needsPermission: the
    // "Open settings" way out turns into "Allow", which shows no dialog.
    // The same happens when the user comes back from the settings page
    // without granting. skip: PLATFORM-R1-11.
    testWidgets('PLATFORM-R1-11: "Open settings" survives the resume that '
        'follows the permission dialog', (tester) async {
      final (world, engine) = await _world();
      // Android's status check: denied, never permanentlyDenied.
      engine.before = {
        TransportKind.lan: TransportAvailability.ready,
        TransportKind.nearby: TransportAvailability.needsPermission,
        TransportKind.ble: TransportAvailability.needsPermission,
      };
      // Android's request: the dialog was not shown (denied twice before).
      engine.afterRequest = {
        TransportKind.nearby: TransportAvailability.permissionPermanentlyDenied,
        TransportKind.ble: TransportAvailability.permissionPermanentlyDenied,
      };
      await _pumpWithEngine(tester, world, engine, Routes.sync);
      expect(find.text(S.openSettings), findsOneWidget);

      // The permission activity closes: our activity is resumed.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await settle(tester);
      expect(
        find.text(S.openSettings),
        findsOneWidget,
        reason:
            'the resume re-check must not turn a permanently denied '
            'permission back into "Allow" (Android never shows the dialog '
            'again, so "Allow" does nothing); calls were ${engine.calls}',
      );
    }, skip: true); // PLATFORM-R1-11
  });
}
