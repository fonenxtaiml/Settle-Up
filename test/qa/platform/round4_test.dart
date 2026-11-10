// QA PLATFORM round 4: reverification of PLATFORM-R3-01 (hosting with the
// location switch off) and PLATFORM-R3-02 (the privacy policy and the
// visible-phone QR), plus the neighbouring cases a fix often misses. The
// real NearbyPermissions, transports and DefaultSyncEngine run; only the
// OS edge is scripted (AndroidPhone from round 3).
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
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
import 'package:settle_up/ui/dev/fake_settings.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/screens/sync/radios.dart';
import 'package:settle_up/ui/strings.dart';

import '../../sync/bluetooth/support/fake_ble.dart';
import '../../sync/bluetooth/support/fake_nearby.dart';
import '../../sync/lan/support.dart';
import 'round3_test.dart' show AndroidPhone;

const _allRadioPermissions = [
  Permission.bluetoothScan,
  Permission.bluetoothAdvertise,
  Permission.bluetoothConnect,
  Permission.nearbyWifiDevices,
  Permission.locationWhenInUse,
];

/// The production wiring (bootstrap.dart) over one scripted phone.
Future<(DefaultSyncEngine, FakeBlePeripheral)> _engine(
  PermissionPlatform platform, {
  bool nearbySupported = true,
}) async {
  final ledger = await Ledger.open(
    store: MemoryOpStore(),
    keys: MemoryGroupKeyStore(),
    settings: FakeSettingsRepository(),
  );
  final perms = NearbyPermissions(platform: platform);
  final peripheral = FakeBleAir().peripheral('p');
  final engine = DefaultSyncEngine(
    store: ledger,
    transports: [
      LanTransport(
        permissions: perms,
        network: FakeLanNetwork(),
        mdns: FakeMdns(FakeMdnsHub()),
      ),
      NearbyTransport(
        permissions: perms,
        api: FakeNearbyAir().phone('a'),
        isAndroid: nearbySupported,
      ),
      BleTransport(
        permissions: perms,
        central: FakeBleAir().central('c'),
        peripheral: peripheral,
      ),
    ],
  );
  return (engine, peripheral);
}

/// Hosting's outcome: the transports it advertises on, or its failure.
Future<(Set<TransportKind>?, SyncFailure?)> _host(
  AndroidPhone phone, {
  bool nearbySupported = true,
  bool bleAdvertisingFails = false,
  List<Permission> granted = _allRadioPermissions,
}) async {
  for (final p in granted) {
    phone.os_[p] = PermissionStatus.granted;
  }
  final (engine, peripheral) = await _engine(
    phone,
    nearbySupported: nearbySupported,
  );
  addTearDown(engine.dispose);
  // A peripheral that refuses to advertise (the plugin throws).
  if (bleAdvertisingFails) peripheral.advertising = true;
  try {
    final host = await engine.startHosting();
    await engine.stopHosting();
    return (host.transports, null);
  } on SyncException catch (e) {
    return (null, e.failure);
  }
}

void main() {
  group('round 4: PLATFORM-R3-01 reverification', () {
    test(
      'API 29, location off, no Wi-Fi: the failure names location',
      () async {
        final (_, f) = await _host(
          AndroidPhone(sdk: 29)
            ..locationOn = false
            ..lan = false,
        );
        expect(f, SyncFailure.locationOff);
        final copy = errorMessage(SyncException(f!, ''));
        expect(copy, contains('ocation'));
        expect(copy, isNot(contains('Bluetooth or Wi-Fi is off')));
      },
    );

    test('API 26 and 30 behave as API 29', () async {
      for (final sdk in [26, 30]) {
        final (_, f) = await _host(
          AndroidPhone(sdk: sdk)
            ..locationOn = false
            ..lan = false,
        );
        expect(f, SyncFailure.locationOff, reason: 'API $sdk');
      }
    });

    test('API 31-32, location off, no Wi-Fi: BLE needs no location and '
        'hosting goes ahead over it', () async {
      for (final sdk in [31, 32]) {
        final (kinds, f) = await _host(
          AndroidPhone(sdk: sdk)
            ..locationOn = false
            ..lan = false,
        );
        expect(f, isNull, reason: 'API $sdk');
        expect(kinds, {TransportKind.ble}, reason: 'API $sdk');
      }
    });

    test(
      'API 33+, location off, no Wi-Fi: Nearby and BLE both advertise',
      () async {
        for (final sdk in [33, 34, 36]) {
          final (kinds, f) = await _host(
            AndroidPhone(sdk: sdk)
              ..locationOn = false
              ..lan = false,
          );
          expect(f, isNull, reason: 'API $sdk');
          expect(kinds, {
            TransportKind.nearby,
            TransportKind.ble,
          }, reason: 'API $sdk');
        }
      },
    );

    test('API 29 without Nearby (no Play services), location off, no Wi-Fi '
        '-> locationOff', () async {
      final (_, f) = await _host(
        AndroidPhone(sdk: 29)
          ..locationOn = false
          ..lan = false,
        nearbySupported: false,
      );
      expect(f, SyncFailure.locationOff);
    });

    test('API 29, location permission refused and location off -> the '
        'permission comes first', () async {
      final (_, f) = await _host(
        AndroidPhone(sdk: 29)
          ..locationOn = false
          ..lan = false,
        granted: const [],
      );
      expect(f, SyncFailure.permissionDenied);
    });

    test('API 29, Bluetooth state unknown, location off -> locationOff, '
        'not internal', () async {
      final (_, f) = await _host(
        AndroidPhone(sdk: 29)
          ..radio = RadioState.unknown
          ..locationOn = false
          ..lan = false,
      );
      expect(f, SyncFailure.locationOff);
    });

    test('API 31, location off, no Wi-Fi, BLE advertising refused -> '
        'locationOff (turning location on lets Nearby advertise)', () async {
      final (_, f) = await _host(
        AndroidPhone(sdk: 31)
          ..locationOn = false
          ..lan = false,
        bleAdvertisingFails: true,
      );
      expect(f, SyncFailure.locationOff);
      final (kinds, f2) = await _host(
        AndroidPhone(sdk: 31)..lan = false,
        bleAdvertisingFails: true,
      );
      expect(f2, isNull);
      expect(kinds, {TransportKind.nearby});
    });

    test('the snack and the radio card point to the same switch', () async {
      final phone = AndroidPhone(sdk: 29)
        ..locationOn = false
        ..lan = false;
      for (final p in _allRadioPermissions) {
        phone.os_[p] = PermissionStatus.granted;
      }
      final (engine, _) = await _engine(phone);
      addTearDown(engine.dispose);
      final issues = radioIssues(await engine.availability());
      expect(issues, contains(RadioIssue.locationOff));
      expect(issues, isNot(contains(RadioIssue.bluetoothOff)));
      expect(S.errLocationOff, contains('Turn on location'));
      expect(S.errLocationOff, isNot(contains('Bluetooth is off')));
    });
  });

  group('round 4: PLATFORM-R3-02 reverification', () {
    test('the policy names the device id and local address for the '
        'visible-phone QR, and the link carries nothing more', () {
      final link = const ConnectLink(
        hosts: ['192.168.43.1:7531', '10.0.0.5:7531'],
        deviceId: '0192f0aa-1111-7000-8000-000000000001',
        deviceName: 'Pixel 8',
      ).encode();
      final keys = Uri.parse(link).queryParametersAll.keys.toSet();
      // Only version, hosts, device id and name: no group key or names,
      // as the policy says.
      expect(keys.difference({'v', 'h', 'd', 'n'}), isEmpty, reason: link);

      final policy = File('docs/PRIVACY.md')
          .readAsStringSync()
          .replaceAll(RegExp(r'\s+'), ' ');
      expect(policy, contains('QR code shown while the phone is visible'));
      expect(policy, contains('device id'));
      expect(policy, contains('address on the local network'));
      expect(policy, contains('not what it shows on its screen'));
    });
  });
}
