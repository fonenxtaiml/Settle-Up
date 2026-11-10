// A thin adapter over `nearby_connections` 4.3.0, so NearbyTransport's
// logic runs under `flutter test` against a fake.
//
// The plugin keeps ONE callback per kind globally (the last
// startAdvertising / startDiscovery / requestConnection / acceptConnection
// call wins), so the adapter registers the same dispatchers every time and
// turns every callback into one event on a single broadcast stream. The
// transport routes events by endpoint id.
import 'dart:async';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:nearby_connections/nearby_connections.dart' as nc;

/// Nearby service id (SPEC 8.7.2). Only apps using the same id see each
/// other.
const String kNearbyServiceId = 'app.settleup.sync';

@immutable
sealed class NearbyEvent {
  const NearbyEvent(this.endpointId);
  final String endpointId;
}

/// Discovery found an advertiser.
final class NearbyEndpointFound extends NearbyEvent {
  const NearbyEndpointFound(super.endpointId, this.endpointName);
  final String endpointName;
}

/// Discovery lost an advertiser.
final class NearbyEndpointLost extends NearbyEvent {
  const NearbyEndpointLost(super.endpointId);
}

/// A connection is being set up (both sides must accept it).
final class NearbyConnectionInitiated extends NearbyEvent {
  const NearbyConnectionInitiated(
    super.endpointId, {
    required this.endpointName,
    required this.incoming,
  });
  final String endpointName;

  /// True on the advertiser side (the peer called requestConnection).
  final bool incoming;
}

/// Both sides accepted (connected) or one rejected / it failed.
final class NearbyConnectionResult extends NearbyEvent {
  const NearbyConnectionResult(super.endpointId, {required this.connected});
  final bool connected;
}

final class NearbyDisconnected extends NearbyEvent {
  const NearbyDisconnected(super.endpointId);
}

/// One BYTES payload arrived complete.
final class NearbyBytesReceived extends NearbyEvent {
  const NearbyBytesReceived(super.endpointId, this.bytes);
  final Uint8List bytes;
}

/// A payload (either direction) failed or was cancelled. Data is lost, so
/// the connection can no longer promise ordered, reliable frames.
final class NearbyPayloadFailed extends NearbyEvent {
  const NearbyPayloadFailed(super.endpointId, this.payloadId);
  final int payloadId;
}

/// ConnectionResult names that mean Google Play services is not installed,
/// is not the real one, or cannot run the Nearby API on this phone.
const List<String> _unavailableMarkers = [
  'API_UNAVAILABLE',
  'is not available on this device',
  'SERVICE_MISSING',
  'SERVICE_INVALID',
  'SERVICE_DISABLED',
  'SERVICE_VERSION_UPDATE_REQUIRED',
];

/// ApiException messages start with the status code; 17 is
/// CommonStatusCodes.API_UNAVAILABLE. PlatformException.toString() puts
/// the message after the code: "PlatformException(Failure, 17: ...".
final RegExp _apiUnavailableCode = RegExp(r'(^|, )17: ');

/// Whether [error], thrown by a [NearbyApi] call, says Nearby Connections
/// cannot run on this phone at all: no Google Play services (Huawei /
/// HarmonyOS, Fire tablets, de-Googled ROMs), a disabled one, or one too
/// old for the Nearby API. The plugin reports a failed Task as
/// PlatformException('Failure', ApiException.getMessage()), for example
/// "17: API: Nearby.CONNECTIONS_API is not available on this device.
/// Connection failed with: ConnectionResult{statusCode=SERVICE_INVALID}".
///
/// Ordinary failures (already advertising, a busy radio, a missing
/// permission, an endpoint that went away) and Dart [Error]s are not
/// matched. The error is read through toString(), because sync code may
/// not import Flutter's services library (SPEC 3.2).
bool isNearbyApiUnavailable(Object error) {
  if (error is Error) return false;
  final text = error.toString();
  return _apiUnavailableCode.hasMatch(text) ||
      _unavailableMarkers.any(text.contains);
}

/// What NearbyTransport needs from Nearby Connections. Every call may throw
/// (a PlatformException from the plugin, e.g. missing permissions).
abstract interface class NearbyApi {
  Stream<NearbyEvent> get events;

  /// Advertises [endpointName] with Strategy.P2P_CLUSTER.
  Future<void> startAdvertising(String endpointName);
  Future<void> stopAdvertising();

  /// Discovers advertisers of [kNearbyServiceId]; [endpointName] is ours.
  Future<void> startDiscovery(String endpointName);
  Future<void> stopDiscovery();

  Future<void> requestConnection(String endpointName, String endpointId);
  Future<void> acceptConnection(String endpointId);
  Future<void> rejectConnection(String endpointId);
  Future<void> disconnect(String endpointId);

  /// Hands one BYTES payload (<= 32 KiB) to Nearby.
  Future<void> sendBytes(String endpointId, Uint8List bytes);

  Future<void> stopAllEndpoints();
}

/// The real plugin. Construct only on Android: the plugin's singleton
/// listens to its event channel as soon as it exists.
final class PluginNearbyApi implements NearbyApi {
  PluginNearbyApi();

  late final nc.Nearby _nearby = nc.Nearby();
  final StreamController<NearbyEvent> _events = StreamController.broadcast();

  @override
  Stream<NearbyEvent> get events => _events.stream;

  void _add(NearbyEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  void _initiated(String id, nc.ConnectionInfo info) =>
      _add(NearbyConnectionInitiated(
        id,
        endpointName: info.endpointName,
        incoming: info.isIncomingConnection,
      ));

  void _result(String id, nc.Status status) =>
      _add(NearbyConnectionResult(id, connected: status == nc.Status.CONNECTED));

  void _disconnected(String id) => _add(NearbyDisconnected(id));

  void _payload(String id, nc.Payload payload) {
    final bytes = payload.bytes;
    if (payload.type == nc.PayloadType.BYTES && bytes != null) {
      _add(NearbyBytesReceived(id, bytes));
    }
  }

  void _transfer(String id, nc.PayloadTransferUpdate update) {
    if (update.status == nc.PayloadStatus.FAILURE ||
        update.status == nc.PayloadStatus.CANCELED) {
      _add(NearbyPayloadFailed(id, update.id));
    }
  }

  @override
  Future<void> startAdvertising(String endpointName) async {
    final ok = await _nearby.startAdvertising(
      endpointName,
      nc.Strategy.P2P_CLUSTER,
      onConnectionInitiated: _initiated,
      onConnectionResult: _result,
      onDisconnected: _disconnected,
      serviceId: kNearbyServiceId,
    );
    if (!ok) throw StateError('Nearby startAdvertising returned false');
  }

  @override
  Future<void> stopAdvertising() => _nearby.stopAdvertising();

  @override
  Future<void> startDiscovery(String endpointName) async {
    final ok = await _nearby.startDiscovery(
      endpointName,
      nc.Strategy.P2P_CLUSTER,
      onEndpointFound: (id, name, serviceId) {
        if (serviceId == kNearbyServiceId) _add(NearbyEndpointFound(id, name));
      },
      onEndpointLost: (id) {
        if (id != null) _add(NearbyEndpointLost(id));
      },
      serviceId: kNearbyServiceId,
    );
    if (!ok) throw StateError('Nearby startDiscovery returned false');
  }

  @override
  Future<void> stopDiscovery() => _nearby.stopDiscovery();

  @override
  Future<void> requestConnection(String endpointName, String endpointId) async {
    final ok = await _nearby.requestConnection(
      endpointName,
      endpointId,
      onConnectionInitiated: _initiated,
      onConnectionResult: _result,
      onDisconnected: _disconnected,
    );
    if (!ok) throw StateError('Nearby requestConnection returned false');
  }

  @override
  Future<void> acceptConnection(String endpointId) async {
    final ok = await _nearby.acceptConnection(
      endpointId,
      onPayLoadRecieved: _payload,
      onPayloadTransferUpdate: _transfer,
    );
    if (!ok) throw StateError('Nearby acceptConnection returned false');
  }

  @override
  Future<void> rejectConnection(String endpointId) =>
      _nearby.rejectConnection(endpointId);

  @override
  Future<void> disconnect(String endpointId) =>
      _nearby.disconnectFromEndpoint(endpointId);

  @override
  Future<void> sendBytes(String endpointId, Uint8List bytes) =>
      _nearby.sendBytesPayload(endpointId, bytes);

  @override
  Future<void> stopAllEndpoints() => _nearby.stopAllEndpoints();
}
