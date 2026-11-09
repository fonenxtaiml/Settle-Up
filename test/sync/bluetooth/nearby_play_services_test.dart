// NearbyTransport on a phone without Google Play services (QA
// PLATFORM-R1-09): Huawei / HarmonyOS, Fire tablets and de-Googled ROMs
// fail every Nearby Connections call with ApiException 17
// (API_UNAVAILABLE). The first such failure is remembered: availability()
// reports unsupported, later calls fail at once with a
// NearbyUnavailableException naming the reason, and the plugin is not
// called again. Ordinary failures are not remembered.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/default_sync_engine.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/sync/transport/nearby/nearby_api.dart';
import 'package:settle_up/sync/transport/nearby/nearby_transport.dart';
import 'package:settle_up/sync/transport/transport.dart';

import '../support/harness.dart';
import '../support/phone.dart';
import 'support/fake_permissions.dart';

/// ApiException 17 as nearby_connections 4.3.0 surfaces it on a phone
/// without Play services.
PlatformException apiUnavailable([String status = 'SERVICE_INVALID']) =>
    PlatformException(
      code: 'Failure',
      message: '17: API: Nearby.CONNECTIONS_API is not available on this '
          'device. Connection failed with: ConnectionResult{statusCode='
          '$status, resolution=null, message=null}',
    );

/// A Nearby error that says nothing about Play services.
PlatformException alreadyAdvertising() => PlatformException(
      code: 'Failure',
      message: '8001: STATUS_ALREADY_ADVERTISING',
    );

const AdvertiseInfo _info = AdvertiseInfo(
  deviceId: '0190a0a0-0000-7000-8000-000000000001',
  deviceName: 'Huawei P40',
  groupTokens: [],
);

const DiscoveredPeer _peer = DiscoveredPeer(
  kind: TransportKind.nearby,
  address: 'EP01',
  name: 'Priya',
);

/// Counts calls; [failure] (when set) is thrown by every call that can
/// fail on a real phone.
final class _CountingNearby implements NearbyApi {
  _CountingNearby([this.failure]);

  Object? failure;
  final List<String> calls = [];
  final StreamController<NearbyEvent> _events = StreamController.broadcast();

  int count(String call) => calls.where((c) => c == call).length;

  Future<void> _maybeFail(String call) async {
    calls.add(call);
    final f = failure;
    if (f != null) throw f;
  }

  void emit(NearbyEvent e) => _events.add(e);

  @override
  Stream<NearbyEvent> get events => _events.stream;
  @override
  Future<void> startAdvertising(String endpointName) =>
      _maybeFail('startAdvertising');
  @override
  Future<void> stopAdvertising() async => calls.add('stopAdvertising');
  @override
  Future<void> startDiscovery(String endpointName) =>
      _maybeFail('startDiscovery');
  @override
  Future<void> stopDiscovery() async => calls.add('stopDiscovery');
  @override
  Future<void> requestConnection(String endpointName, String endpointId) =>
      _maybeFail('requestConnection');
  @override
  Future<void> acceptConnection(String endpointId) =>
      _maybeFail('acceptConnection');
  @override
  Future<void> rejectConnection(String endpointId) async =>
      calls.add('rejectConnection');
  @override
  Future<void> disconnect(String endpointId) async => calls.add('disconnect');
  @override
  Future<void> sendBytes(String endpointId, Uint8List bytes) =>
      _maybeFail('sendBytes');
  @override
  Future<void> stopAllEndpoints() async => calls.add('stopAllEndpoints');
}

final Matcher _namesPlayServices = isA<NearbyUnavailableException>()
    .having((e) => e.message, 'message', contains('Google Play services'))
    .having((e) => e.cause, 'cause', isA<PlatformException>());

void main() {
  NearbyTransport transport(_CountingNearby api) {
    final t = NearbyTransport(
      permissions: grantedPermissions(),
      api: api,
      isAndroid: true,
    );
    addTearDown(t.dispose);
    return t;
  }

  group('isNearbyApiUnavailable', () {
    test('matches API_UNAVAILABLE for every missing-Play-services status',
        () {
      for (final status in [
        'SERVICE_INVALID',
        'SERVICE_MISSING',
        'SERVICE_DISABLED',
        'SERVICE_VERSION_UPDATE_REQUIRED',
      ]) {
        expect(isNearbyApiUnavailable(apiUnavailable(status)), isTrue,
            reason: status);
      }
      expect(
        isNearbyApiUnavailable(
          PlatformException(code: 'Failure', message: '17: API_UNAVAILABLE'),
        ),
        isTrue,
      );
    });

    test('does not match ordinary Nearby or Dart failures', () {
      expect(isNearbyApiUnavailable(alreadyAdvertising()), isFalse);
      expect(
        isNearbyApiUnavailable(PlatformException(
          code: 'Failure',
          message: '8007: STATUS_RADIO_ERROR',
        )),
        isFalse,
      );
      expect(
        isNearbyApiUnavailable(PlatformException(code: 'Failure')),
        isFalse,
      );
      expect(
        isNearbyApiUnavailable(
          StateError('Nearby startAdvertising returned false'),
        ),
        isFalse,
      );
      expect(isNearbyApiUnavailable(const SocketException('gone')), isFalse);
      expect(
        isNearbyApiUnavailable(
          const SocketException('connect to 10.0.0.17: refused'),
        ),
        isFalse,
      );
    });
  });

  group('without Play services', () {
    test('is ready until Nearby itself says it is unavailable', () async {
      final api = _CountingNearby(apiUnavailable());
      final t = transport(api);
      expect(await t.availability(), TransportAvailability.ready);
      expect(t.isApiUnavailable, isFalse);
      expect(api.calls, isEmpty, reason: 'availability() calls no plugin');
    });

    test('a failed start names the reason and is remembered', () async {
      final api = _CountingNearby(apiUnavailable());
      final t = transport(api);
      await expectLater(t.startAdvertising(_info), throwsA(_namesPlayServices));
      expect(t.isApiUnavailable, isTrue);
      expect(t.isAdvertising, isFalse);
      expect(await t.availability(), TransportAvailability.unsupported);
      expect(await t.requestPermissions(), TransportAvailability.unsupported);

      // Nothing calls the failing plugin again.
      final before = api.calls.length;
      await expectLater(t.startAdvertising(_info), throwsA(_namesPlayServices));
      await expectLater(t.discover().first, throwsA(_namesPlayServices));
      await expectLater(
        t.connect(_peer),
        throwsA(isA<SocketException>().having(
          (e) => e.message,
          'message',
          contains('Google Play services'),
        )),
      );
      expect(api.calls.sublist(before), isEmpty);
      expect(api.count('startAdvertising'), 1);
    });

    test('a failed scan is remembered too', () async {
      final api = _CountingNearby(apiUnavailable('SERVICE_MISSING'));
      final t = transport(api);
      await expectLater(t.discover().first, throwsA(_namesPlayServices));
      expect(await t.availability(), TransportAvailability.unsupported);
      expect(t.isDiscovering, isFalse);
      await expectLater(t.startAdvertising(_info), throwsA(_namesPlayServices));
      expect(api.count('startDiscovery'), 1);
      expect(api.count('startAdvertising'), 0);
    });

    test('a failed connection request is remembered too', () async {
      final api = _CountingNearby(apiUnavailable());
      final t = transport(api);
      await expectLater(
        t.connect(_peer),
        throwsA(isA<SocketException>().having(
          (e) => e.message,
          'message',
          contains('Google Play services'),
        )),
      );
      expect(await t.availability(), TransportAvailability.unsupported);
      expect(t.openChannels, 0);
    });

    test('an ordinary failure is not remembered', () async {
      final api = _CountingNearby(alreadyAdvertising());
      final t = transport(api);
      await expectLater(
        t.startAdvertising(_info),
        throwsA(isA<PlatformException>()),
      );
      expect(t.isApiUnavailable, isFalse);
      expect(await t.availability(), TransportAvailability.ready);
      api.failure = null;
      await t.startAdvertising(_info);
      expect(t.isAdvertising, isTrue);
      expect(api.count('startAdvertising'), 2);
    });

    test('the engine hosts and scans without Nearby after the first failure',
        () async {
      final api = _CountingNearby(apiUnavailable());
      final nearby = transport(api);
      final hub = MemoryTransportHub();
      final ble = MemoryTransport(
        hub,
        kind: TransportKind.ble,
        address: 'ble-a',
      );
      final phone = await TestPhone.create('a', deviceName: 'Huawei P40');
      addTearDown(phone.close);
      final engine = DefaultSyncEngine(
        store: phone.ledger,
        transports: [nearby, ble],
        timings: fastTimings,
      );
      addTearDown(engine.dispose);

      final first = await engine.startHosting();
      expect(first.transports, {TransportKind.ble});
      await engine.stopHosting();
      expect(api.count('startAdvertising'), 1);

      expect(
        (await engine.availability())[TransportKind.nearby],
        TransportAvailability.unsupported,
      );
      final second = await engine.startHosting();
      expect(second.transports, {TransportKind.ble});
      await engine.stopHosting();
      await engine.startDiscovery();
      await engine.stopDiscovery();
      expect(api.count('startAdvertising'), 1,
          reason: 'hosting no longer calls the failing plugin');
      expect(api.count('startDiscovery'), 0,
          reason: 'scanning no longer calls the failing plugin');
    });
  });
}
