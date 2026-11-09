// NearbyPermissions (SPEC 8.10): which runtime permissions each transport
// needs per OS and Android API level, and how statuses map to
// TransportAvailability.
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/platform/permissions.dart';
import 'package:settle_up/sync/transport/transport.dart';

final class FakePlatform implements PermissionPlatform {
  FakePlatform(this.os, {this.sdk = 34});

  @override
  final PermissionOs os;
  int sdk;
  final Map<Permission, PermissionStatus> statuses = {};

  /// What a request turns each permission into (default: granted).
  final Map<Permission, PermissionStatus> answers = {};
  final List<List<Permission>> requests = [];
  RadioState radio = RadioState.on;
  bool locationOn = true;
  bool lanInterface = true;

  @override
  Future<int> androidSdkInt() async => os == PermissionOs.android ? sdk : 0;

  @override
  Future<PermissionStatus> status(Permission p) async =>
      statuses[p] ?? PermissionStatus.denied;

  @override
  Future<Map<Permission, PermissionStatus>> request(
    List<Permission> permissions,
  ) async {
    requests.add(permissions);
    for (final p in permissions) {
      statuses[p] = answers[p] ?? PermissionStatus.granted;
    }
    return {for (final p in permissions) p: statuses[p]!};
  }

  @override
  Future<RadioState> bluetooth() async => radio;

  @override
  Future<bool> locationServiceOn() async => locationOn;

  @override
  Future<bool> hasLanInterface() async => lanInterface;
}

const _bt = [
  Permission.bluetoothScan,
  Permission.bluetoothAdvertise,
  Permission.bluetoothConnect,
];

void main() {
  group('requiredFor, Android', () {
    Future<List<Permission>?> need(int sdk, TransportKind kind) =>
        NearbyPermissions(platform: FakePlatform(PermissionOs.android, sdk: sdk))
            .requiredFor(kind);

    test('lan needs nothing on any API level', () async {
      for (final sdk in [26, 30, 31, 33, 36]) {
        expect(await need(sdk, TransportKind.lan), isEmpty);
      }
    });

    test('nearby', () async {
      expect(await need(26, TransportKind.nearby), [Permission.locationWhenInUse]);
      expect(await need(30, TransportKind.nearby), [Permission.locationWhenInUse]);
      expect(await need(31, TransportKind.nearby),
          [..._bt, Permission.locationWhenInUse]);
      expect(await need(32, TransportKind.nearby),
          [..._bt, Permission.locationWhenInUse]);
      expect(await need(33, TransportKind.nearby),
          [..._bt, Permission.nearbyWifiDevices]);
      expect(await need(36, TransportKind.nearby),
          [..._bt, Permission.nearbyWifiDevices]);
    });

    test('ble', () async {
      expect(await need(26, TransportKind.ble), [Permission.locationWhenInUse]);
      expect(await need(30, TransportKind.ble), [Permission.locationWhenInUse]);
      expect(await need(31, TransportKind.ble), _bt);
      expect(await need(32, TransportKind.ble), _bt);
      expect(await need(36, TransportKind.ble), _bt);
    });
  });

  test('requiredFor, iOS and other platforms', () async {
    final ios = NearbyPermissions(platform: FakePlatform(PermissionOs.ios));
    expect(await ios.requiredFor(TransportKind.lan), isEmpty);
    expect(await ios.requiredFor(TransportKind.ble), [Permission.bluetooth]);
    expect(await ios.requiredFor(TransportKind.nearby), isNull);
    final other = NearbyPermissions(platform: FakePlatform(PermissionOs.other));
    expect(await other.requiredFor(TransportKind.lan), isEmpty);
    expect(await other.requiredFor(TransportKind.ble), isNull);
    expect(await other.requiredFor(TransportKind.nearby), isNull);
  });

  group('check', () {
    test('lan: ready with an interface, radioOff without, no dialogs',
        () async {
      final p = FakePlatform(PermissionOs.android);
      final perms = NearbyPermissions(platform: p);
      expect(await perms.check(TransportKind.lan), TransportAvailability.ready);
      p.lanInterface = false;
      expect(await perms.check(TransportKind.lan), TransportAvailability.radioOff);
      expect(await perms.request(TransportKind.lan),
          TransportAvailability.radioOff);
      expect(p.requests, isEmpty);
    });

    test('nearby on iOS is unsupported', () async {
      final perms = NearbyPermissions(platform: FakePlatform(PermissionOs.ios));
      expect(await perms.check(TransportKind.nearby),
          TransportAvailability.unsupported);
      expect(await perms.request(TransportKind.nearby),
          TransportAvailability.unsupported);
    });

    test('missing permission -> needsPermission; granted -> ready', () async {
      final p = FakePlatform(PermissionOs.android, sdk: 34);
      final perms = NearbyPermissions(platform: p);
      expect(await perms.check(TransportKind.ble),
          TransportAvailability.needsPermission);
      for (final x in _bt) {
        p.statuses[x] = PermissionStatus.granted;
      }
      expect(await perms.check(TransportKind.ble), TransportAvailability.ready);
      expect(p.requests, isEmpty);
    });

    test('a permanently denied permission wins', () async {
      final p = FakePlatform(PermissionOs.android, sdk: 34)
        ..statuses[Permission.bluetoothScan] = PermissionStatus.granted
        ..statuses[Permission.bluetoothConnect] =
            PermissionStatus.permanentlyDenied;
      final perms = NearbyPermissions(platform: p);
      expect(await perms.check(TransportKind.ble),
          TransportAvailability.permissionPermanentlyDenied);
    });

    test('Bluetooth off -> radioOff once permitted; unsupported hardware',
        () async {
      final p = FakePlatform(PermissionOs.ios)
        ..statuses[Permission.bluetooth] = PermissionStatus.granted
        ..radio = RadioState.off;
      final perms = NearbyPermissions(platform: p);
      expect(await perms.check(TransportKind.ble), TransportAvailability.radioOff);
      p.radio = RadioState.unknown;
      expect(await perms.check(TransportKind.ble), TransportAvailability.ready);
      p.radio = RadioState.unsupported;
      expect(await perms.check(TransportKind.ble),
          TransportAvailability.unsupported);
    });

    test('old Android: location service off -> radioOff', () async {
      final p = FakePlatform(PermissionOs.android, sdk: 29)
        ..statuses[Permission.locationWhenInUse] = PermissionStatus.granted
        ..locationOn = false;
      final perms = NearbyPermissions(platform: p);
      expect(await perms.check(TransportKind.ble), TransportAvailability.radioOff);
      p.locationOn = true;
      expect(await perms.check(TransportKind.ble), TransportAvailability.ready);
    });

    test('new Android does not care about the location switch', () async {
      final p = FakePlatform(PermissionOs.android, sdk: 33)
        ..locationOn = false;
      for (final x in [..._bt, Permission.nearbyWifiDevices]) {
        p.statuses[x] = PermissionStatus.granted;
      }
      expect(await NearbyPermissions(platform: p).check(TransportKind.nearby),
          TransportAvailability.ready);
    });
  });

  group('request', () {
    test('asks only for what is missing, then reports ready', () async {
      final p = FakePlatform(PermissionOs.android, sdk: 33)
        ..statuses[Permission.bluetoothScan] = PermissionStatus.granted;
      final perms = NearbyPermissions(platform: p);
      expect(await perms.request(TransportKind.nearby),
          TransportAvailability.ready);
      expect(p.requests, [
        [
          Permission.bluetoothAdvertise,
          Permission.bluetoothConnect,
          Permission.nearbyWifiDevices,
        ],
      ]);
    });

    test('a refusal stays needsPermission; "don\'t ask again" is permanent',
        () async {
      final p = FakePlatform(PermissionOs.android, sdk: 31)
        ..answers[Permission.bluetoothScan] = PermissionStatus.denied;
      final perms = NearbyPermissions(platform: p);
      expect(await perms.request(TransportKind.ble),
          TransportAvailability.needsPermission);
      p.answers[Permission.bluetoothScan] = PermissionStatus.permanentlyDenied;
      expect(await perms.request(TransportKind.ble),
          TransportAvailability.permissionPermanentlyDenied);
    });

    test('no dialog when every missing permission is permanently denied',
        () async {
      final p = FakePlatform(PermissionOs.ios)
        ..statuses[Permission.bluetooth] = PermissionStatus.permanentlyDenied;
      final perms = NearbyPermissions(platform: p);
      expect(await perms.request(TransportKind.ble),
          TransportAvailability.permissionPermanentlyDenied);
      expect(p.requests, isEmpty);
    });

    test('limited and provisional count as granted', () async {
      final p = FakePlatform(PermissionOs.ios)
        ..statuses[Permission.bluetooth] = PermissionStatus.limited;
      expect(await NearbyPermissions(platform: p).check(TransportKind.ble),
          TransportAvailability.ready);
      p.statuses[Permission.bluetooth] = PermissionStatus.provisional;
      expect(await NearbyPermissions(platform: p).check(TransportKind.ble),
          TransportAvailability.ready);
    });
  });

  test('explain lists the permissions it decided on', () async {
    final p = FakePlatform(PermissionOs.android, sdk: 30);
    final r = await NearbyPermissions(platform: p).explain(TransportKind.nearby);
    expect(r.availability, TransportAvailability.needsPermission);
    expect(r.permissions, [Permission.locationWhenInUse]);
  });
}
