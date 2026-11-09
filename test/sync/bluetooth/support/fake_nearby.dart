// An in-process Nearby Connections "air" for NearbyTransport tests. Each
// FakeNearbyApi is one phone; they see each other through FakeNearbyAir.
// It mimics the plugin's behaviour where it matters:
// - startAdvertising / startDiscovery fail when already running;
// - both sides must accept before either gets a CONNECTED result;
// - disconnect notifies only the other side;
// - BYTES payloads arrive whole and in order (asynchronously).
import 'dart:async';
import 'dart:typed_data';

import 'package:settle_up/sync/transport/nearby/nearby_api.dart';

final class FakeNearbyAir {
  final Map<String, FakeNearbyApi> _phones = {};

  FakeNearbyApi phone(String endpointId) =>
      _phones[endpointId] ??= FakeNearbyApi._(this, endpointId);

  Iterable<FakeNearbyApi> get _all => _phones.values;
}

final class _Pending {
  final Set<String> accepted = {};
  bool rejected = false;
}

final class FakeNearbyApi implements NearbyApi {
  FakeNearbyApi._(this.air, this.endpointId);

  final FakeNearbyAir air;

  /// The id other phones see this phone under.
  final String endpointId;

  final StreamController<NearbyEvent> _events = StreamController.broadcast();

  String? advertisedName;
  bool discovering = false;

  /// Endpoints this phone is connected to.
  final Set<String> connected = {};

  /// Call log, e.g. 'startAdvertising', 'stopDiscovery'.
  final List<String> calls = [];

  /// Payloads this phone sent, per destination.
  final Map<String, List<Uint8List>> sent = {};

  /// When true, connection requests never reach this phone (a peer that
  /// walked away), so the requester waits until it times out.
  bool ignoreConnectionRequests = false;

  /// If set, the n-th payload this phone sends (1-based) fails on both
  /// sides instead of arriving.
  int? failPayloadNumber;
  int _payloads = 0;

  final Map<String, _Pending> _pending = {};

  void _emit(NearbyEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  @override
  Stream<NearbyEvent> get events => _events.stream;

  @override
  Future<void> startAdvertising(String endpointName) async {
    calls.add('startAdvertising');
    if (advertisedName != null) {
      throw StateError('STATUS_ALREADY_ADVERTISING');
    }
    advertisedName = endpointName;
    for (final p in air._all) {
      if (p != this && p.discovering) {
        p._emit(NearbyEndpointFound(endpointId, endpointName));
      }
    }
  }

  @override
  Future<void> stopAdvertising() async {
    calls.add('stopAdvertising');
    if (advertisedName == null) return;
    advertisedName = null;
    for (final p in air._all) {
      if (p != this && p.discovering) p._emit(NearbyEndpointLost(endpointId));
    }
  }

  @override
  Future<void> startDiscovery(String endpointName) async {
    calls.add('startDiscovery');
    if (discovering) throw StateError('STATUS_ALREADY_DISCOVERING');
    discovering = true;
    for (final p in air._all) {
      final name = p.advertisedName;
      if (p != this && name != null) {
        _emit(NearbyEndpointFound(p.endpointId, name));
      }
    }
  }

  @override
  Future<void> stopDiscovery() async {
    calls.add('stopDiscovery');
    discovering = false;
  }

  @override
  Future<void> requestConnection(String endpointName, String endpointId) async {
    calls.add('requestConnection');
    final target = air._phones[endpointId];
    if (target == null || target.advertisedName == null) {
      throw StateError('STATUS_ENDPOINT_UNKNOWN');
    }
    final pending = _Pending();
    _pending[endpointId] = pending;
    target._pending[this.endpointId] = pending;
    _emit(NearbyConnectionInitiated(
      endpointId,
      endpointName: target.advertisedName!,
      incoming: false,
    ));
    if (!target.ignoreConnectionRequests) {
      target._emit(NearbyConnectionInitiated(
        this.endpointId,
        endpointName: endpointName,
        incoming: true,
      ));
    }
  }

  @override
  Future<void> acceptConnection(String endpointId) async {
    calls.add('acceptConnection');
    final pending = _pending[endpointId];
    if (pending == null) throw StateError('No pending connection');
    pending.accepted.add(this.endpointId);
    _settle(endpointId, pending);
  }

  @override
  Future<void> rejectConnection(String endpointId) async {
    calls.add('rejectConnection');
    final pending = _pending[endpointId];
    if (pending == null) return;
    pending.rejected = true;
    _settle(endpointId, pending);
  }

  void _settle(String otherId, _Pending pending) {
    final other = air._phones[otherId]!;
    if (pending.rejected) {
      _pending.remove(otherId);
      other._pending.remove(endpointId);
      _emit(NearbyConnectionResult(otherId, connected: false));
      other._emit(NearbyConnectionResult(endpointId, connected: false));
      return;
    }
    if (pending.accepted.length < 2) return;
    _pending.remove(otherId);
    other._pending.remove(endpointId);
    connected.add(otherId);
    other.connected.add(endpointId);
    _emit(NearbyConnectionResult(otherId, connected: true));
    other._emit(NearbyConnectionResult(endpointId, connected: true));
  }

  @override
  Future<void> disconnect(String endpointId) async {
    calls.add('disconnect');
    if (!connected.remove(endpointId)) return;
    final other = air._phones[endpointId]!;
    other.connected.remove(this.endpointId);
    other._emit(NearbyDisconnected(this.endpointId));
  }

  /// The radio link dies: both sides get onDisconnected.
  void dropLink(String endpointId) {
    final other = air._phones[endpointId]!;
    connected.remove(endpointId);
    other.connected.remove(this.endpointId);
    _emit(NearbyDisconnected(endpointId));
    other._emit(NearbyDisconnected(this.endpointId));
  }

  @override
  Future<void> sendBytes(String endpointId, Uint8List bytes) async {
    if (!connected.contains(endpointId)) {
      throw StateError('STATUS_ENDPOINT_IO_ERROR');
    }
    final copy = Uint8List.fromList(bytes);
    (sent[endpointId] ??= []).add(copy);
    final n = ++_payloads;
    final other = air._phones[endpointId]!;
    if (n == failPayloadNumber) {
      _emit(NearbyPayloadFailed(endpointId, n));
      other._emit(NearbyPayloadFailed(this.endpointId, n));
      return;
    }
    other._emit(NearbyBytesReceived(this.endpointId, copy));
  }

  /// Injects a payload as if [from] had sent it.
  void receiveFrom(String from, Uint8List bytes) =>
      _emit(NearbyBytesReceived(from, bytes));

  @override
  Future<void> stopAllEndpoints() async {
    calls.add('stopAllEndpoints');
    for (final id in connected.toList()) {
      await disconnect(id);
    }
  }

  int count(String call) => calls.where((c) => c == call).length;
}
