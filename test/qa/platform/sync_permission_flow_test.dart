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
  group(
    'Sync tab asks for Bluetooth / Nearby permissions',
    () {
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
    },
    skip:
        'QA PLATFORM-R1-02: the app never calls requestPermissions, so '
        'Bluetooth and Nearby sync are never available',
  );

  group(
    'a permanently denied permission has a way out',
    () {
      testWidgets(
        'Sync shows how to open app settings when Bluetooth permission is '
        'permanently denied',
        (tester) async {
          final (world, engine) = await _world();
          engine.before = {
            TransportKind.lan: TransportAvailability.radioOff,
            TransportKind.nearby:
                TransportAvailability.permissionPermanentlyDenied,
            TransportKind.ble:
                TransportAvailability.permissionPermanentlyDenied,
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
    },
    skip:
        'QA PLATFORM-R1-11: no recovery path for permanently denied '
        'permissions or Bluetooth switched off',
  );
}
