// QA PLATFORM round 1: radio availability across Android API 26-36 and
// iOS, through the real NearbyPermissions rules and the real transports
// (LanTransport, NearbyTransport, BleTransport) and DefaultSyncEngine.
// Only the OS edge (PermissionPlatform, the Nearby / BLE plugin adapters,
// the network list) is scripted.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/platform/permissions.dart';
import 'package:settle_up/sync/sync_engine.dart';
import 'package:settle_up/sync/transport/ble/ble_transport.dart';
import 'package:settle_up/sync/transport/lan/lan_transport.dart';
import 'package:settle_up/sync/transport/nearby/nearby_api.dart';
import 'package:settle_up/sync/transport/nearby/nearby_transport.dart';
import 'package:settle_up/sync/transport/transport.dart';
import 'package:settle_up/ui/dev/fake_settings.dart';
import 'package:settle_up/ui/screens/sync/radios.dart';

import '../../sync/bluetooth/support/fake_ble.dart';
import '../../sync/bluetooth/support/fake_nearby.dart';
import '../../sync/lan/support.dart';

/// A phone's permission state, scriptable per API level.
final class ScriptedPlatform implements PermissionPlatform {
  ScriptedPlatform({this.os = PermissionOs.android, this.sdk = 34});

  @override
  final PermissionOs os;
  final int sdk;

  /// Current status per permission (default: denied, as Android reports a
  /// never-asked or permanently denied permission on a status check).
  final Map<Permission, PermissionStatus> statuses = {};

  /// What the dialog turns each permission into (default: granted).
  final Map<Permission, PermissionStatus> answers = {};
  final List<List<Permission>> requests = [];
  RadioState radio = RadioState.on;
  bool locationOn = true;
  bool lan = true;

  /// Every call throws this, when set (a plugin missing or misbehaving).
  Object? failure;

  void _maybeFail() {
    final f = failure;
    if (f != null) throw f;
  }

  @override
  Future<int> androidSdkInt() async {
    _maybeFail();
    return os == PermissionOs.android ? sdk : 0;
  }

  @override
  Future<PermissionStatus> status(Permission p) async {
    _maybeFail();
    return statuses[p] ?? PermissionStatus.denied;
  }

  @override
  Future<Map<Permission, PermissionStatus>> request(
    List<Permission> permissions,
  ) async {
    _maybeFail();
    requests.add(permissions);
    for (final p in permissions) {
      statuses[p] = answers[p] ?? PermissionStatus.granted;
    }
    return {for (final p in permissions) p: statuses[p]!};
  }

  @override
  Future<RadioState> bluetooth() async {
    _maybeFail();
    return radio;
  }

  @override
  Future<bool> locationServiceOn() async {
    _maybeFail();
    return locationOn;
  }

  @override
  Future<bool> hasLanInterface() async {
    _maybeFail();
    return lan;
  }
}

const _apiLevels = [26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36];

/// The manifest names permission_handler maps each Permission to.
final Map<Permission, List<String>> _manifestNames = {
  Permission.bluetoothScan: ['android.permission.BLUETOOTH_SCAN'],
  Permission.bluetoothAdvertise: ['android.permission.BLUETOOTH_ADVERTISE'],
  Permission.bluetoothConnect: ['android.permission.BLUETOOTH_CONNECT'],
  Permission.nearbyWifiDevices: ['android.permission.NEARBY_WIFI_DEVICES'],
  Permission.locationWhenInUse: [
    'android.permission.ACCESS_FINE_LOCATION',
    'android.permission.ACCESS_COARSE_LOCATION',
  ],
};

/// uses-permission name -> maxSdkVersion (null: no cap), from the source
/// manifest.
Map<String, int?> _declaredPermissions() {
  final xml = File('android/app/src/main/AndroidManifest.xml')
      .readAsStringSync();
  final out = <String, int?>{};
  final tag = RegExp(r'<uses-permission\b([^>]*)/?>', dotAll: true);
  for (final m in tag.allMatches(xml)) {
    final attrs = m.group(1)!;
    final name = RegExp(r'android:name="([^"]+)"').firstMatch(attrs)?.group(1);
    if (name == null) continue;
    final max = RegExp(r'android:maxSdkVersion="(\d+)"').firstMatch(attrs);
    out[name] = max == null ? null : int.parse(max.group(1)!);
  }
  return out;
}

SyncTransport _transport(TransportKind kind, ScriptedPlatform platform) {
  final perms = NearbyPermissions(platform: platform);
  return switch (kind) {
    TransportKind.lan => LanTransport(
      permissions: perms,
      network: FakeLanNetwork(),
      mdns: FakeMdns(FakeMdnsHub()),
    ),
    TransportKind.nearby => NearbyTransport(
      permissions: perms,
      api: FakeNearbyAir().phone('a'),
      isAndroid: platform.os == PermissionOs.android,
    ),
    TransportKind.ble => BleTransport(
      permissions: perms,
      central: FakeBleAir().central('c'),
      peripheral: FakeBleAir().peripheral('p'),
    ),
  };
}

void main() {
  group('permission rules vs the manifest, API 26-36', () {
    final declared = _declaredPermissions();

    test(
      'every runtime permission requested is declared for that API level',
      () async {
        for (final sdk in _apiLevels) {
          final perms = NearbyPermissions(platform: ScriptedPlatform(sdk: sdk));
          for (final kind in TransportKind.values) {
            for (final p in (await perms.requiredFor(kind))!) {
              final names = _manifestNames[p];
              expect(names, isNotNull, reason: 'unmapped $p');
              final fine = names!.first;
              expect(
                declared.containsKey(fine),
                isTrue,
                reason: '$fine needed by ${kind.name} on API $sdk',
              );
              final max = declared[fine];
              expect(
                max == null || max >= sdk,
                isTrue,
                reason:
                    '$fine is capped at $max but ${kind.name} asks for it '
                    'on API $sdk; the dialog would never show',
              );
            }
          }
        }
      },
    );

    test('caps: location <= 32, legacy BLUETOOTH* <= 30, nothing broader', () {
      expect(declared['android.permission.ACCESS_FINE_LOCATION'], 32);
      expect(declared['android.permission.ACCESS_COARSE_LOCATION'], 32);
      expect(declared['android.permission.BLUETOOTH'], 30);
      expect(declared['android.permission.BLUETOOTH_ADMIN'], 30);
      expect(
        declared.containsKey('android.permission.ACCESS_BACKGROUND_LOCATION'),
        isFalse,
      );
    });

    test(
      'no location is ever asked on API 33+, no BLUETOOTH_* below 31',
      () async {
        for (final sdk in _apiLevels) {
          final perms = NearbyPermissions(platform: ScriptedPlatform(sdk: sdk));
          for (final kind in TransportKind.values) {
            final need = (await perms.requiredFor(kind))!;
            if (sdk >= 33) {
              expect(need, isNot(contains(Permission.locationWhenInUse)));
            }
            if (sdk < 31) {
              expect(need, isNot(contains(Permission.bluetoothScan)));
              expect(need, isNot(contains(Permission.bluetoothConnect)));
              expect(need, isNot(contains(Permission.bluetoothAdvertise)));
            }
            if (sdk < 33) {
              expect(need, isNot(contains(Permission.nearbyWifiDevices)));
            }
          }
        }
      },
    );
  });

  group('transport availability through the real transports', () {
    for (final sdk in _apiLevels) {
      for (final kind in TransportKind.values) {
        test(
          'API $sdk ${kind.name}: fresh install -> request -> ready',
          () async {
            final platform = ScriptedPlatform(sdk: sdk);
            final t = _transport(kind, platform);
            addTearDown(t.dispose);
            final expectFresh = kind == TransportKind.lan
                ? TransportAvailability.ready
                : TransportAvailability.needsPermission;
            expect(await t.availability(), expectFresh);
            expect(
              platform.requests,
              isEmpty,
              reason: 'availability() must never show a dialog',
            );
            expect(await t.requestPermissions(), TransportAvailability.ready);
            expect(await t.availability(), TransportAvailability.ready);
          },
        );

        if (kind == TransportKind.lan) continue;

        test(
          'API $sdk ${kind.name}: "Don\'t allow" twice -> permanently denied',
          () async {
            final platform = ScriptedPlatform(sdk: sdk);
            for (final p in _manifestNames.keys) {
              platform.answers[p] = PermissionStatus.permanentlyDenied;
            }
            final t = _transport(kind, platform);
            addTearDown(t.dispose);
            expect(
              await t.requestPermissions(),
              TransportAvailability.permissionPermanentlyDenied,
            );
          },
        );

        test(
          'API $sdk ${kind.name}: partial grant stays needsPermission',
          () async {
            final platform = ScriptedPlatform(sdk: sdk);
            final need = (await NearbyPermissions(platform: platform)
                .requiredFor(kind))!;
            platform.answers[need.last] = PermissionStatus.denied;
            final t = _transport(kind, platform);
            addTearDown(t.dispose);
            expect(
              await t.requestPermissions(),
              TransportAvailability.needsPermission,
            );
          },
        );

        test(
          'API $sdk ${kind.name}: Bluetooth off -> radioOff, not ready',
          () async {
            final platform = ScriptedPlatform(sdk: sdk)..radio = RadioState.off;
            final t = _transport(kind, platform);
            addTearDown(t.dispose);
            expect(
              await t.requestPermissions(),
              TransportAvailability.radioOff,
            );
          },
        );

        test('API $sdk ${kind.name}: no Bluetooth hardware -> unsupported, '
            'no dialog', () async {
          final platform = ScriptedPlatform(sdk: sdk)
            ..radio = RadioState.unsupported;
          final t = _transport(kind, platform);
          addTearDown(t.dispose);
          expect(
            await t.requestPermissions(),
            TransportAvailability.unsupported,
          );
          expect(platform.requests, isEmpty);
        });

        test('API $sdk ${kind.name}: location service switch off', () async {
          final platform = ScriptedPlatform(sdk: sdk)..locationOn = false;
          final t = _transport(kind, platform);
          addTearDown(t.dispose);
          final needsLocation = kind == TransportKind.nearby
              ? sdk <= 32
              : sdk <= 30;
          expect(
            await t.requestPermissions(),
            // PLATFORM-R2-01: a distinct reason, so the Sync tab offers the
            // location switch rather than Bluetooth settings.
            needsLocation
                ? TransportAvailability.locationOff
                : TransportAvailability.ready,
          );
        });
      }
    }

    test('LAN with no usable IPv4 interface (Wi-Fi off, no hotspot)', () async {
      final platform = ScriptedPlatform()..lan = false;
      final t = _transport(TransportKind.lan, platform);
      addTearDown(t.dispose);
      expect(await t.availability(), TransportAvailability.radioOff);
    });

    test(
      'a platform that throws on every call never makes availability throw',
      () async {
        for (final sdk in [26, 30, 31, 33, 36]) {
          for (final kind in TransportKind.values) {
            final platform = ScriptedPlatform(sdk: sdk)
              ..failure = PlatformException(code: 'boom');
            final t = _transport(kind, platform);
            addTearDown(t.dispose);
            await expectLater(t.availability(), completes);
            await expectLater(t.requestPermissions(), completes);
            expect(await t.availability(), isNot(TransportAvailability.ready));
          }
        }
      },
    );

    test(
      'a MissingPluginException (plugin not registered) is reported',
      () async {
        final platform = ScriptedPlatform()
          ..failure = MissingPluginException('no impl');
        final t = _transport(TransportKind.ble, platform);
        addTearDown(t.dispose);
        expect(await t.availability(), TransportAvailability.unsupported);
      },
    );
  });

  group('iOS', () {
    test('Nearby is unsupported on iOS without touching the plugin', () async {
      final api = FakeNearbyAir().phone('x');
      final t = NearbyTransport(
        permissions: NearbyPermissions(
          platform: ScriptedPlatform(os: PermissionOs.ios),
        ),
        api: api,
        isAndroid: false,
      );
      addTearDown(t.dispose);
      expect(await t.availability(), TransportAvailability.unsupported);
      expect(await t.requestPermissions(), TransportAvailability.unsupported);
      expect(api.calls, isEmpty);
    });

    test('BLE asks for the Bluetooth permission only', () async {
      final platform = ScriptedPlatform(os: PermissionOs.ios);
      final t = _transport(TransportKind.ble, platform);
      addTearDown(t.dispose);
      expect(await t.requestPermissions(), TransportAvailability.ready);
      expect(platform.requests.single, [Permission.bluetooth]);
    });

    test(
      'LAN needs no runtime permission (Local Network prompt is the OS)',
      () async {
        final platform = ScriptedPlatform(os: PermissionOs.ios);
        final t = _transport(TransportKind.lan, platform);
        addTearDown(t.dispose);
        expect(await t.requestPermissions(), TransportAvailability.ready);
        expect(platform.requests, isEmpty);
      },
    );
  });

  group('default constructors on a host with no radios (bootstrap path)', () {
    test('LanTransport/BleTransport/NearbyTransport build and report '
        'availability without throwing', () async {
      final transports = <SyncTransport>[
        LanTransport(),
        if (Platform.isAndroid) NearbyTransport(),
        BleTransport(),
        NearbyTransport(isAndroid: false),
      ];
      for (final t in transports) {
        final a = await t.availability().timeout(const Duration(seconds: 5));
        expect(TransportAvailability.values, contains(a));
      }
      // Not a phone: Bluetooth transports are unsupported here.
      expect(
        await transports[1].availability(),
        TransportAvailability.unsupported,
      );
      for (final t in transports) {
        await t.dispose();
      }
    });

    test('SystemPermissionPlatform off Android/iOS: other, sdk 0', () async {
      final p = SystemPermissionPlatform(network: FakeLanNetwork());
      expect(p.os, PermissionOs.other);
      expect(await p.androidSdkInt(), 0);
      expect(await p.bluetooth(), RadioState.unsupported);
    });
  });

  group('engine over the real transports', () {
    Future<DefaultSyncEngine> engineWith(List<SyncTransport> transports) async {
      final settings = FakeSettingsRepository();
      final ledger = await Ledger.open(
        store: MemoryOpStore(),
        keys: MemoryGroupKeyStore(),
        settings: settings,
      );
      final engine = DefaultSyncEngine(store: ledger, transports: transports);
      addTearDown(engine.dispose);
      return engine;
    }

    test('hosting with Bluetooth only and no permission: permissionDenied, '
        'then works after requestPermissions', () async {
      final platform = ScriptedPlatform(sdk: 34);
      final ble = _transport(TransportKind.ble, platform);
      final engine = await engineWith([ble]);
      await expectLater(
        engine.startHosting(),
        throwsA(
          isA<SyncException>().having(
            (e) => e.failure,
            'failure',
            SyncFailure.permissionDenied,
          ),
        ),
      );
      final after = await engine.requestPermissions({TransportKind.ble});
      expect(after[TransportKind.ble], TransportAvailability.ready);
      final host = await engine.startHosting();
      expect(host.transports, {TransportKind.ble});
      await engine.stopHosting();
    });

    test('Bluetooth off everywhere: hosting fails with radioOff', () async {
      final platform = ScriptedPlatform(sdk: 34)..radio = RadioState.off;
      for (final p in _manifestNames.keys) {
        platform.statuses[p] = PermissionStatus.granted;
      }
      final engine = await engineWith([
        _transport(TransportKind.nearby, platform),
        _transport(TransportKind.ble, platform),
      ]);
      await expectLater(
        engine.startHosting(),
        throwsA(
          isA<SyncException>().having(
            (e) => e.failure,
            'failure',
            SyncFailure.radioOff,
          ),
        ),
      );
    });

    test(
      'Nearby without Google Play services: hosting falls back to BLE',
      () async {
        final platform = ScriptedPlatform(sdk: 34);
        for (final p in _manifestNames.keys) {
          platform.statuses[p] = PermissionStatus.granted;
        }
        final nearby = NearbyTransport(
          permissions: NearbyPermissions(platform: platform),
          api: _NoPlayServicesNearby(),
          isAndroid: true,
        );
        final engine = await engineWith([
          nearby,
          _transport(TransportKind.ble, platform),
        ]);
        final host = await engine.startHosting();
        expect(host.transports, {TransportKind.ble});
        await engine.stopHosting();
        // Discovery with a Nearby that cannot start must not throw either.
        await engine.startDiscovery();
        await engine.stopDiscovery();
      },
    );
  });

  group('Nearby without Google Play services', () {
    test(
      'availability reports unsupported once Nearby says API unavailable',
      () async {
        final platform = ScriptedPlatform(sdk: 34);
        for (final p in _manifestNames.keys) {
          platform.statuses[p] = PermissionStatus.granted;
        }
        final nearby = NearbyTransport(
          permissions: NearbyPermissions(platform: platform),
          api: _NoPlayServicesNearby(),
          isAndroid: true,
        );
        addTearDown(nearby.dispose);
        await expectLater(
          nearby.startAdvertising(
            const AdvertiseInfo(
              deviceId: '0190a0a0-0000-7000-8000-000000000001',
              deviceName: 'Huawei P40',
              groupTokens: [],
            ),
          ),
          throwsA(anything),
        );
        expect(
          await nearby.availability(),
          TransportAvailability.unsupported,
          reason:
              'a phone without Play services can never use Nearby; '
              'reporting ready sends every host/scan attempt into a failing '
              'plugin call and hides the reason from the user',
        );
      },
    );
  });
  round2();
}

/// [ScriptedPlatform] with Android's status semantics: permission_handler's
/// status() never returns permanentlyDenied on Android (only request() can
/// tell), so a permanently denied permission reads as plain denied.
final class _AndroidStatusPlatform implements PermissionPlatform {
  _AndroidStatusPlatform(this.inner);

  final ScriptedPlatform inner;

  @override
  PermissionOs get os => inner.os;
  @override
  Future<int> androidSdkInt() => inner.androidSdkInt();
  @override
  Future<PermissionStatus> status(Permission p) async {
    final s = await inner.status(p);
    return s == PermissionStatus.permanentlyDenied
        ? PermissionStatus.denied
        : s;
  }

  @override
  Future<Map<Permission, PermissionStatus>> request(List<Permission> p) =>
      inner.request(p);
  @override
  Future<RadioState> bluetooth() => inner.bluetooth();
  @override
  Future<bool> locationServiceOn() => inner.locationServiceOn();
  @override
  Future<bool> hasLanInterface() => inner.hasLanInterface();
}

// QA PLATFORM round 2.
void round2() {
  group('round 2', () {
    // PLATFORM-R1-11 (reopened): the permanently denied verdict from a
    // request is lost on the next status-only check, so the Sync tab's
    // resume re-check turns "Open settings" back into "Allow".
    test('PLATFORM-R1-11: a permanently denied request is still reported by '
        'the next check on Android', () async {
      final scripted = ScriptedPlatform(sdk: 34);
      for (final p in [
        Permission.bluetoothScan,
        Permission.bluetoothAdvertise,
        Permission.bluetoothConnect,
      ]) {
        scripted.answers[p] = PermissionStatus.permanentlyDenied;
      }
      final perms = NearbyPermissions(
        platform: _AndroidStatusPlatform(scripted),
      );
      expect(
        await perms.request(TransportKind.ble),
        TransportAvailability.permissionPermanentlyDenied,
      );
      expect(
        await perms.check(TransportKind.ble),
        TransportAvailability.permissionPermanentlyDenied,
        reason:
            'Android status() says "denied" for a permanently denied '
            'permission; the wrapper must remember what request() said',
      );
    });

    // PLATFORM-R2-01: on API 26-30 a BLE scan needs the location service
    // switch on. With Bluetooth on and location off, availability says
    // radioOff, and the Sync tab says "Bluetooth is off" with a button to
    // the Bluetooth settings, where Bluetooth is already on.
    for (final sdk in [26, 29, 30]) {
      test('PLATFORM-R2-01: API $sdk, Bluetooth on, location switch off: the '
          'Sync tab does not say Bluetooth is off', () async {
        final platform = ScriptedPlatform(sdk: sdk)..locationOn = false;
        for (final p in _manifestNames.keys) {
          platform.statuses[p] = PermissionStatus.granted;
        }
        final settings = FakeSettingsRepository();
        final ledger = await Ledger.open(
          store: MemoryOpStore(),
          keys: MemoryGroupKeyStore(),
          settings: settings,
        );
        final engine = DefaultSyncEngine(
          store: ledger,
          transports: [
            _transport(TransportKind.lan, platform),
            _transport(TransportKind.nearby, platform),
            _transport(TransportKind.ble, platform),
          ],
        );
        addTearDown(engine.dispose);
        expect(platform.radio, RadioState.on);
        final issues = radioIssues(await engine.availability());
        expect(
          issues,
          isNot(contains(RadioIssue.bluetoothOff)),
          reason:
              'Bluetooth is on; the fix is the location switch. '
              'Issues were $issues',
        );
      });
    }

    test('Bluetooth really off on API 34: the Sync tab says so', () async {
      final platform = ScriptedPlatform(sdk: 34)..radio = RadioState.off;
      for (final p in _manifestNames.keys) {
        platform.statuses[p] = PermissionStatus.granted;
      }
      final ble = _transport(TransportKind.ble, platform);
      addTearDown(ble.dispose);
      expect(radioIssues({TransportKind.ble: await ble.availability()}), [
        RadioIssue.bluetoothOff,
      ]);
    });

    test('Nearby API_UNAVAILABLE is remembered across discovery and '
        'connect, without calling the plugin again', () async {
      final platform = ScriptedPlatform(sdk: 34);
      for (final p in _manifestNames.keys) {
        platform.statuses[p] = PermissionStatus.granted;
      }
      final api = _CountingNoPlayServicesNearby();
      final nearby = NearbyTransport(
        permissions: NearbyPermissions(platform: platform),
        api: api,
        isAndroid: true,
      );
      addTearDown(nearby.dispose);
      // First failure from discovery (not advertising).
      final sub = nearby.discover().listen((_) {}, onError: (Object _) {});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await sub.cancel();
      expect(await nearby.availability(), TransportAvailability.unsupported);
      expect(
        await nearby.requestPermissions(),
        TransportAvailability.unsupported,
      );
      final before = api.calls;
      await expectLater(
        nearby.connect(
          const DiscoveredPeer(
            kind: TransportKind.nearby,
            address: 'ep1',
            name: 'x',
          ),
          timeout: const Duration(seconds: 1),
        ),
        throwsA(anything),
      );
      expect(api.calls, before, reason: 'no plugin call once unavailable');
    });

    test('an ordinary Nearby failure (already advertising) does not mark '
        'Nearby unsupported', () async {
      expect(
        isNearbyApiUnavailable(
          PlatformException(
            code: 'Failure',
            message: '8001: STATUS_ALREADY_ADVERTISING',
          ),
        ),
        isFalse,
      );
      expect(
        isNearbyApiUnavailable(
          PlatformException(
            code: 'Failure',
            message: '8034: MISSING_PERMISSION_ACCESS_FINE_LOCATION',
          ),
        ),
        isFalse,
      );
      expect(isNearbyApiUnavailable(StateError('17: x')), isFalse);
      expect(
        isNearbyApiUnavailable(
          PlatformException(code: 'Failure', message: '17: API: Nearby'),
        ),
        isTrue,
      );
    });
  });
}

final class _CountingNoPlayServicesNearby extends _NoPlayServicesNearby {
  int calls = 0;

  @override
  Future<void> startAdvertising(String endpointName) {
    calls++;
    return super.startAdvertising(endpointName);
  }

  @override
  Future<void> startDiscovery(String endpointName) {
    calls++;
    return super.startDiscovery(endpointName);
  }

  @override
  Future<void> requestConnection(String endpointName, String endpointId) {
    calls++;
    return super.requestConnection(endpointName, endpointId);
  }
}

/// What nearby_connections does on a phone without Google Play services:
/// every ConnectionsClient call fails with ApiException 17
/// (API_UNAVAILABLE), surfaced as a PlatformException.
base class _NoPlayServicesNearby implements NearbyApi {
  final StreamController<NearbyEvent> _events = StreamController.broadcast();

  static PlatformException get _unavailable => PlatformException(
    code: 'Failure',
    message:
        '17: API: Nearby.CONNECTIONS_API is not available on this '
        'device. Connection failed with: ConnectionResult{statusCode='
        'SERVICE_INVALID}',
  );

  @override
  Stream<NearbyEvent> get events => _events.stream;
  @override
  Future<void> startAdvertising(String endpointName) async =>
      throw _unavailable;
  @override
  Future<void> stopAdvertising() async {}
  @override
  Future<void> startDiscovery(String endpointName) async => throw _unavailable;
  @override
  Future<void> stopDiscovery() async {}
  @override
  Future<void> requestConnection(
    String endpointName,
    String endpointId,
  ) async => throw _unavailable;
  @override
  Future<void> acceptConnection(String endpointId) async => throw _unavailable;
  @override
  Future<void> rejectConnection(String endpointId) async {}
  @override
  Future<void> disconnect(String endpointId) async {}
  @override
  Future<void> sendBytes(String endpointId, Uint8List bytes) async =>
      throw _unavailable;
  @override
  Future<void> stopAllEndpoints() async {}
}
