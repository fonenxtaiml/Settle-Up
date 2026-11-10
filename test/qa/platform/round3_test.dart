// QA PLATFORM round 3: reverification of PLATFORM-R1-11 and PLATFORM-R2-01
// through the real NearbyPermissions, the real transports and
// DefaultSyncEngine (only the OS edge is scripted, with Android's status
// semantics), plus the neighbouring cases a fix often misses.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/pairing/links.dart';
import 'package:settle_up/sync/platform/permissions.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/ble/ble_transport.dart';
import 'package:settle_up/sync/transport/lan/lan_transport.dart';
import 'package:settle_up/sync/transport/nearby/nearby_transport.dart';
import 'package:settle_up/sync/transport/transport.dart';
import 'package:settle_up/ui/app.dart';
import 'package:settle_up/ui/dev/fake_settings.dart';
import 'package:settle_up/ui/dev/fake_sync_engine.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/screens/sync/radios.dart';
import 'package:settle_up/ui/strings.dart';

import '../../sync/bluetooth/support/fake_ble.dart';
import '../../sync/bluetooth/support/fake_nearby.dart';
import '../../sync/lan/support.dart';
import '../../ui/screens/screen_harness.dart';

/// An Android phone as permission_handler_android sees it: status() can
/// never say permanentlyDenied (only request() can), and a request for a
/// permission the user refused twice shows no dialog and answers
/// permanentlyDenied.
final class AndroidPhone implements PermissionPlatform {
  AndroidPhone({this.sdk = 34});

  final int sdk;

  @override
  PermissionOs get os => PermissionOs.android;

  /// What the OS holds: granted, denied (askable) or permanentlyDenied.
  final Map<Permission, PermissionStatus> os_ = {};

  /// What the user taps in the dialog when it shows (default: granted).
  final Map<Permission, PermissionStatus> answers = {};

  /// Every request() call, and whether a dialog showed for it.
  final List<(List<Permission>, bool)> requests = [];

  RadioState radio = RadioState.on;
  bool locationOn = true;
  bool lan = true;

  @override
  Future<int> androidSdkInt() async => sdk;

  @override
  Future<PermissionStatus> status(Permission p) async {
    final s = os_[p] ?? PermissionStatus.denied;
    return s == PermissionStatus.permanentlyDenied
        ? PermissionStatus.denied
        : s;
  }

  @override
  Future<Map<Permission, PermissionStatus>> request(
    List<Permission> permissions,
  ) async {
    final askable = permissions.any(
      (p) => (os_[p] ?? PermissionStatus.denied) == PermissionStatus.denied,
    );
    requests.add((permissions, askable));
    for (final p in permissions) {
      if ((os_[p] ?? PermissionStatus.denied) == PermissionStatus.denied) {
        os_[p] = answers[p] ?? PermissionStatus.granted;
      }
    }
    return {for (final p in permissions) p: os_[p]!};
  }

  @override
  Future<RadioState> bluetooth() async => radio;
  @override
  Future<bool> locationServiceOn() async => locationOn;
  @override
  Future<bool> hasLanInterface() async => lan;

  void grantAllInSettings() {
    for (final p in Permission.values) {
      os_[p] = PermissionStatus.granted;
    }
  }
}

const _bt = [
  Permission.bluetoothScan,
  Permission.bluetoothAdvertise,
  Permission.bluetoothConnect,
];

const _allRadioPermissions = [
  ..._bt,
  Permission.nearbyWifiDevices,
  Permission.locationWhenInUse,
];

/// The production wiring (bootstrap.dart): one NearbyPermissions shared by
/// all three transports.
List<SyncTransport> _transports(NearbyPermissions perms) => [
  LanTransport(
    permissions: perms,
    network: FakeLanNetwork(),
    mdns: FakeMdns(FakeMdnsHub()),
  ),
  NearbyTransport(
    permissions: perms,
    api: FakeNearbyAir().phone('a'),
    isAndroid: true,
  ),
  BleTransport(
    permissions: perms,
    central: FakeBleAir().central('c'),
    peripheral: FakeBleAir().peripheral('p'),
  ),
];

Future<DefaultSyncEngine> _engine(PermissionPlatform platform) async {
  final ledger = await Ledger.open(
    store: MemoryOpStore(),
    keys: MemoryGroupKeyStore(),
    settings: FakeSettingsRepository(),
  );
  final engine = DefaultSyncEngine(
    store: ledger,
    transports: _transports(NearbyPermissions(platform: platform)),
  );
  return engine;
}

/// The demo FakeSyncEngine, with the radio answers of a real
/// DefaultSyncEngine over real transports (availability and
/// requestPermissions are the only calls the radio card depends on).
final class _RealRadiosEngine implements SyncEngine {
  _RealRadiosEngine(this._inner, this._radios);

  final FakeSyncEngine _inner;
  final DefaultSyncEngine _radios;
  int discoveries = 0;

  @override
  Future<Map<TransportKind, TransportAvailability>> availability() =>
      _radios.availability();
  @override
  Future<Map<TransportKind, TransportAvailability>> requestPermissions(
    Set<TransportKind> kinds,
  ) => _radios.requestPermissions(kinds);

  @override
  SyncStatus get status => _inner.status;
  @override
  Stream<SyncStatus> watchStatus() => _inner.watchStatus();
  @override
  Stream<List<NearbyPeer>> watchNearby() => _inner.watchNearby();
  @override
  Future<HostInfo> startHosting({
    Duration duration = const Duration(minutes: 5),
  }) => _inner.startHosting(duration: duration);
  @override
  Future<void> stopHosting() => _inner.stopHosting();
  @override
  Future<void> startDiscovery({
    Set<TransportKind> kinds = const {
      TransportKind.lan,
      TransportKind.nearby,
      TransportKind.ble,
    },
  }) {
    discoveries++;
    return _inner.startDiscovery(kinds: kinds);
  }

  @override
  Future<void> stopDiscovery() => _inner.stopDiscovery();
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

Future<void> _pump(
  WidgetTester tester,
  TestWorld world,
  SyncEngine engine,
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

Future<void> _resume(WidgetTester tester) async {
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
  await settle(tester);
}

void main() {
  group('round 3: PLATFORM-R1-11 reverification', () {
    testWidgets('end to end on Android semantics: refused twice before, '
        '"Open settings" stays across the dialog resume, a tab change and '
        'a resume from settings without a grant, and goes once granted', (
      tester,
    ) async {
      final phone = AndroidPhone(sdk: 34);
      for (final p in _bt) {
        phone.os_[p] = PermissionStatus.permanentlyDenied;
      }
      phone.os_[Permission.nearbyWifiDevices] =
          PermissionStatus.permanentlyDenied;
      final real = await tester.runAsync(() => _engine(phone));
      addTearDown(() => tester.runAsync(real!.dispose));
      final world = await TestWorld.demo();
      final engine = _RealRadiosEngine(world.engine, real!);
      await _pump(tester, world, engine, Routes.sync);
      expect(find.text(S.openSettings), findsOneWidget);
      expect(find.text(S.allow), findsNothing);

      // The (not shown) permission activity closes: resume.
      await _resume(tester);
      expect(find.text(S.openSettings), findsOneWidget);
      expect(find.text(S.allow), findsNothing);

      // Leave the tab and come back (a fresh check with a new screen
      // state when the tab is rebuilt).
      world.go(Routes.home);
      await settle(tester);
      world.go(Routes.sync);
      await settle(tester);
      expect(find.text(S.openSettings), findsOneWidget);

      // Back from settings without granting.
      await _resume(tester);
      expect(find.text(S.openSettings), findsOneWidget);

      // Granted in settings.
      final before = engine.discoveries;
      phone.grantAllInSettings();
      await _resume(tester);
      expect(find.text(S.openSettings), findsNothing);
      expect(find.text(S.allow), findsNothing);
      expect(engine.discoveries, greaterThan(before));
    });

    test('after an app restart (memory lost) the first request shows no '
        'dialog, answers permanentlyDenied and the next check keeps it', () async {
      final phone = AndroidPhone(sdk: 31);
      for (final p in _bt) {
        phone.os_[p] = PermissionStatus.permanentlyDenied;
      }
      final perms = NearbyPermissions(platform: phone);
      expect(
        await perms.check(TransportKind.ble),
        TransportAvailability.needsPermission,
      );
      expect(
        await perms.request(TransportKind.ble),
        TransportAvailability.permissionPermanentlyDenied,
      );
      expect(phone.requests.single.$2, isFalse, reason: 'no dialog shown');
      expect(
        await perms.check(TransportKind.ble),
        TransportAvailability.permissionPermanentlyDenied,
      );
      // A second request does not call the platform again.
      expect(
        await perms.request(TransportKind.ble),
        TransportAvailability.permissionPermanentlyDenied,
      );
      expect(phone.requests, hasLength(1));
    });

    test('the verdict from a Nearby request also covers BLE, which needs '
        'the same Bluetooth permissions (shared instance, API 31)', () async {
      final phone = AndroidPhone(sdk: 31);
      for (final p in _bt) {
        phone.os_[p] = PermissionStatus.permanentlyDenied;
      }
      phone.os_[Permission.locationWhenInUse] = PermissionStatus.granted;
      final engine = await _engine(phone);
      addTearDown(engine.dispose);
      final after = await engine.requestPermissions({TransportKind.nearby});
      expect(
        after[TransportKind.nearby],
        TransportAvailability.permissionPermanentlyDenied,
      );
      final now = await engine.availability();
      expect(
        now[TransportKind.ble],
        TransportAvailability.permissionPermanentlyDenied,
      );
      expect(radioIssues(now), [RadioIssue.permissionDenied]);
    });

    test('a later grant clears the remembered verdict, and a later revoke '
        'is askable again', () async {
      final phone = AndroidPhone(sdk: 30);
      phone.answers[Permission.locationWhenInUse] =
          PermissionStatus.permanentlyDenied;
      final perms = NearbyPermissions(platform: phone);
      expect(
        await perms.request(TransportKind.ble),
        TransportAvailability.permissionPermanentlyDenied,
      );
      phone.grantAllInSettings();
      expect(await perms.check(TransportKind.ble), TransportAvailability.ready);
      // Revoked in settings (Android kills the process on a revoke, but the
      // engine instance may outlive a soft reset): now plain denied.
      phone.os_[Permission.locationWhenInUse] = PermissionStatus.denied;
      phone.answers[Permission.locationWhenInUse] = PermissionStatus.granted;
      expect(
        await perms.check(TransportKind.ble),
        TransportAvailability.needsPermission,
      );
      expect(
        await perms.request(TransportKind.ble),
        TransportAvailability.ready,
      );
    });

    test('a request that throws keeps the earlier verdict and never '
        'throws out of check/request', () async {
      final phone = _ThrowingRequest(sdk: 34);
      for (final p in _bt) {
        phone.os_[p] = PermissionStatus.permanentlyDenied;
      }
      final perms = NearbyPermissions(platform: phone);
      expect(
        await perms.request(TransportKind.ble),
        TransportAvailability.needsPermission,
      );
      expect(
        await perms.check(TransportKind.ble),
        TransportAvailability.needsPermission,
      );
    });
  });

  group('round 3: PLATFORM-R2-01 reverification', () {
    Future<Map<TransportKind, TransportAvailability>> locationOff(
      int sdk, {
      RadioState radio = RadioState.on,
    }) async {
      final phone = AndroidPhone(sdk: sdk)
        ..locationOn = false
        ..radio = radio;
      for (final p in _allRadioPermissions) {
        phone.os_[p] = PermissionStatus.granted;
      }
      final engine = await _engine(phone);
      addTearDown(engine.dispose);
      return engine.availability();
    }

    for (final sdk in [26, 27, 28, 29, 30]) {
      test('API $sdk: location off -> BLE and Nearby locationOff, one '
          '"Location is off" row, no "Bluetooth is off"', () async {
        final a = await locationOff(sdk);
        expect(a[TransportKind.ble], TransportAvailability.locationOff);
        expect(a[TransportKind.nearby], TransportAvailability.locationOff);
        expect(radioIssues(a), [RadioIssue.locationOff]);
      });
    }

    for (final sdk in [31, 32]) {
      test('API $sdk: location off -> only Nearby needs it; BLE ready', () async {
        final a = await locationOff(sdk);
        expect(a[TransportKind.ble], TransportAvailability.ready);
        expect(a[TransportKind.nearby], TransportAvailability.locationOff);
        expect(radioIssues(a), [RadioIssue.locationOff]);
      });
    }

    for (final sdk in [33, 34, 35, 36]) {
      test('API $sdk: location off does not matter', () async {
        final a = await locationOff(sdk);
        expect(a[TransportKind.ble], TransportAvailability.ready);
        expect(a[TransportKind.nearby], TransportAvailability.ready);
        expect(radioIssues(a), isEmpty);
      });
    }

    test('API 29, Bluetooth and location both off: Bluetooth first, then '
        'location once Bluetooth is on', () async {
      final a = await locationOff(29, radio: RadioState.off);
      expect(radioIssues(a), [RadioIssue.bluetoothOff]);
    });

    testWidgets('Sync tab, API 29, location off: "Turn on location" row, no '
        '"Turn on Bluetooth"', (tester) async {
      final phone = AndroidPhone(sdk: 29)..locationOn = false;
      for (final p in _allRadioPermissions) {
        phone.os_[p] = PermissionStatus.granted;
      }
      final real = await tester.runAsync(() => _engine(phone));
      addTearDown(() => tester.runAsync(real!.dispose));
      final world = await TestWorld.demo();
      await _pump(
        tester,
        world,
        _RealRadiosEngine(world.engine, real!),
        Routes.sync,
      );
      expect(find.text(S.turnOnLocation), findsOneWidget);
      expect(find.text(S.turnOnBluetooth), findsNothing);
      phone.locationOn = true;
      await _resume(tester);
      expect(find.text(S.turnOnLocation), findsNothing);
    });

    // PLATFORM-R3-01: "Make this phone visible" on API 26-30 with Bluetooth
    // on, every permission granted, no Wi-Fi and the location switch off.
    // BLE advertising needs neither the location permission nor the
    // location switch, yet hosting skips BLE (locationOff is not ready) and
    // the failure maps locationOff to SyncFailure.radioOff, whose snack
    // says "Bluetooth or Wi-Fi is off". Bluetooth is on; the fix the user
    // needs is the location switch (or BLE should advertise anyway).
    test('PLATFORM-R3-01: hosting with location off (API 29, no Wi-Fi) does '
        'not say Bluetooth or Wi-Fi is off', () async {
      final phone = AndroidPhone(sdk: 29)
        ..locationOn = false
        ..lan = false;
      for (final p in _allRadioPermissions) {
        phone.os_[p] = PermissionStatus.granted;
      }
      final engine = await _engine(phone);
      addTearDown(engine.dispose);
      String? message;
      try {
        await engine.startHosting();
        await engine.stopHosting();
      } on SyncException catch (e) {
        message = errorMessage(e);
      }
      expect(
        message == null || message.contains('ocation'),
        isTrue,
        reason:
            'Bluetooth is on and only the location switch is off, but the '
            'user is told: "$message"',
      );
    });

    // Regressions for the PLATFORM-R3-01 fix: which failure hosting reports.
    Future<SyncFailure?> hostingFailure(AndroidPhone phone) async {
      for (final p in _allRadioPermissions) {
        phone.os_[p] = PermissionStatus.granted;
      }
      final engine = await _engine(phone);
      addTearDown(engine.dispose);
      try {
        await engine.startHosting();
        await engine.stopHosting();
        return null;
      } on SyncException catch (e) {
        return e.failure;
      }
    }

    test('PLATFORM-R3-01 fix: location off, no Wi-Fi -> locationOff, whose '
        'copy names location, not Bluetooth', () async {
      final f = await hostingFailure(
        AndroidPhone(sdk: 29)
          ..locationOn = false
          ..lan = false,
      );
      expect(f, SyncFailure.locationOff);
      final copy = syncFailureMessage(f!);
      expect(copy, contains('ocation'));
      expect(copy, isNot(contains('Bluetooth or Wi-Fi is off')));
    });

    test('PLATFORM-R3-01 fix: Bluetooth and location off, no Wi-Fi -> still '
        'radioOff (Bluetooth first)', () async {
      final f = await hostingFailure(
        AndroidPhone(sdk: 29)
          ..locationOn = false
          ..radio = RadioState.off
          ..lan = false,
      );
      expect(f, SyncFailure.radioOff);
    });

    test('PLATFORM-R3-01 fix: location off with Wi-Fi -> hosting works over '
        'Wi-Fi', () async {
      final f = await hostingFailure(AndroidPhone(sdk: 29)..locationOn = false);
      expect(f, isNull);
    });
  });

  group('round 3: privacy policy neighbours of PLATFORM-R2-03', () {
    // PLATFORM-R3-02: the policy lists the Sync screen "and its QR code
    // screen" as when nearby devices can see the name, a rotating id and
    // group codes, and says nothing stable such as the device id is
    // advertised. But the QR shown while the phone is visible (sync_screen
    // qrData / host_screen QrImageView: HostInfo.connectLink) is
    // ConnectLink.encode(): local IP addresses, the full device id (d=) and
    // the name. Anyone who can see or photograph the screen gets the stable
    // device id. Only the invite QR is described as carrying it.
    test('PLATFORM-R3-02: the policy says the visible-phone QR carries the '
        'device id and local address', () {
      final link = const ConnectLink(
        hosts: ['192.168.43.1:7531'],
        deviceId: '0192f0aa-1111-7000-8000-000000000001',
        deviceName: 'Pixel 8',
      ).encode();
      expect(link, contains('0192f0aa-1111-7000-8000-000000000001'));
      final policy = File('docs/PRIVACY.md').readAsStringSync();
      final paragraphs = policy
          .split(RegExp(r'\n\s*\n'))
          .map((p) => p.replaceAll(RegExp(r'\s+'), ' '))
          .where((p) => p.contains('QR') && !p.contains('invite'));
      expect(
        paragraphs.any((p) => p.contains('device id') && p.contains('address')),
        isTrue,
        reason:
            'the QR shown on the Sync screen and its QR code screen carries '
            'the device id and the local address; paragraphs about it: '
            '${paragraphs.toList()}',
      );
    });
  });
}

final class _ThrowingRequest extends AndroidPhone {
  _ThrowingRequest({super.sdk});

  @override
  Future<Map<Permission, PermissionStatus>> request(
    List<Permission> permissions,
  ) async => throw StateError('activity gone');
}
