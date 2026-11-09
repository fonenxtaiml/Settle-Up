// Thin adapters over `bluetooth_low_energy` 6.2.1, so BleTransport's logic
// (discovery cache, chunking, flow control, one link at a time) runs under
// `flutter test` against a fake radio. Plugin objects (Peripheral, Central,
// GATT characteristics) stay in here; the transport only sees string ids:
// the peripheral or central UUID as `toString()` prints it.
//
// Platform notes kept here, next to the calls they concern:
// - Android renames the phone's Bluetooth adapter to the advertised local
//   name (PeripheralManager.startAdvertising calls setName). The "SU" name
//   is therefore only advertised on iOS; Android advertises the service
//   UUID alone, which is what scanners filter on anyway.
// - requestMTU exists only on Android; iOS negotiates the MTU itself.
// - The plugin's characteristic objects are matched by identity on
//   Android, so the peripheral keeps the instances it added.
import 'dart:async';
import 'dart:io' show Platform, SocketException;
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';

import 'ble_uuids.dart';

/// The central (scanner / initiator) role.
abstract interface class BleCentralApi {
  /// While scanning: the id of every peripheral advertising the Settle Up
  /// service, each time an advertisement is seen (repeats are expected).
  Stream<String> get advertisements;

  /// Peripheral ids whose connection ended (either side, or the radio).
  Stream<String> get disconnections;

  /// TX notifications: (peripheral id, value).
  Stream<(String, Uint8List)> get notifications;

  /// Scans for the Settle Up service UUID only.
  Future<void> startScan();
  Future<void> stopScan();

  Future<void> connect(String peripheralId);
  Future<void> disconnect(String peripheralId);

  /// Asks for [mtu] where the platform allows it (Android). Returns the
  /// MTU in effect, or null when the platform negotiates by itself.
  Future<int?> requestMtu(String peripheralId, int mtu);

  /// Discovers GATT and finds the Settle Up service. Throws when the
  /// peripheral does not have it.
  Future<void> discoverService(String peripheralId);

  Future<Uint8List> readInfo(String peripheralId);

  /// Turns TX notifications on or off.
  Future<void> setTxNotify(String peripheralId, {required bool enabled});

  /// Largest value one RX write with response should carry (one ATT
  /// packet, so the peripheral never has to reassemble a long write).
  Future<int> maxWriteLength(String peripheralId);

  /// Writes one chunk to RX with response (the OS paces these).
  Future<void> writeRx(String peripheralId, Uint8List value);
}

/// What the peripheral adapter asks of the transport. Called on the
/// platform's event order.
abstract interface class BlePeripheralHandler {
  /// The INFO value; null answers the read with an error.
  Uint8List? infoValue();

  /// One RX chunk from [centralId]. False answers the write with an error.
  bool onRxWrite(String centralId, Uint8List value);

  /// [centralId] turned TX notifications on or off.
  void onTxSubscription(String centralId, {required bool subscribed});

  /// [centralId] disconnected (Android reports this; iOS does not).
  void onCentralDisconnected(String centralId);
}

/// The peripheral (advertiser / responder) role.
abstract interface class BlePeripheralApi {
  set handler(BlePeripheralHandler? handler);

  /// Publishes the GATT service (once) and starts advertising.
  Future<void> startAdvertising();
  Future<void> stopAdvertising();

  /// Largest value one TX notification to [centralId] may carry.
  Future<int> maxNotifyLength(String centralId);

  /// Sends one chunk; completes when the platform took it.
  Future<void> notifyTx(String centralId, Uint8List value);

  /// Drops [centralId] (Android; throws where the platform cannot).
  Future<void> disconnect(String centralId);
}

final UUID _service = UUID.fromString(kBleServiceUuid);
final UUID _info = UUID.fromString(kBleInfoUuid);
final UUID _rx = UUID.fromString(kBleRxUuid);
final UUID _tx = UUID.fromString(kBleTxUuid);

final class _RemoteGatt {
  _RemoteGatt(this.info, this.rx, this.tx);
  final GATTCharacteristic info;
  final GATTCharacteristic rx;
  final GATTCharacteristic tx;
}

/// The real central, on `CentralManager`.
final class PluginBleCentral implements BleCentralApi {
  PluginBleCentral({bool? isAndroid}) : _isAndroid = isAndroid ?? Platform.isAndroid;

  final bool _isAndroid;
  late final CentralManager _manager = CentralManager();
  final Map<String, Peripheral> _peripherals = {};
  final Map<String, _RemoteGatt> _gatt = {};

  @override
  Stream<String> get advertisements => _manager.discovered
      .where((e) => e.advertisement.serviceUUIDs.contains(_service))
      .map((e) {
        final id = e.peripheral.uuid.toString();
        _peripherals[id] = e.peripheral;
        return id;
      });

  @override
  Stream<String> get disconnections => _manager.connectionStateChanged
      .where((e) => e.state == ConnectionState.disconnected)
      .map((e) {
        final id = e.peripheral.uuid.toString();
        _gatt.remove(id);
        return id;
      });

  @override
  Stream<(String, Uint8List)> get notifications => _manager
      .characteristicNotified
      .where((e) => e.characteristic.uuid == _tx)
      .map((e) => (e.peripheral.uuid.toString(), e.value));

  Peripheral _peripheral(String id) {
    final p = _peripherals[id];
    if (p == null) throw SocketException('Bluetooth device $id not seen');
    return p;
  }

  _RemoteGatt _remote(String id) {
    final g = _gatt[id];
    if (g == null) throw SocketException('Bluetooth device $id not set up');
    return g;
  }

  @override
  Future<void> startScan() => _manager.startDiscovery(serviceUUIDs: [_service]);

  @override
  Future<void> stopScan() => _manager.stopDiscovery();

  @override
  Future<void> connect(String peripheralId) =>
      _manager.connect(_peripheral(peripheralId));

  @override
  Future<void> disconnect(String peripheralId) async {
    _gatt.remove(peripheralId);
    final p = _peripherals[peripheralId];
    if (p != null) await _manager.disconnect(p);
  }

  @override
  Future<int?> requestMtu(String peripheralId, int mtu) async {
    if (!_isAndroid) return null;
    return _manager.requestMTU(_peripheral(peripheralId), mtu: mtu);
  }

  @override
  Future<void> discoverService(String peripheralId) async {
    final services = await _manager.discoverGATT(_peripheral(peripheralId));
    GATTCharacteristic? find(GATTService s, UUID uuid) {
      for (final c in s.characteristics) {
        if (c.uuid == uuid) return c;
      }
      return null;
    }

    for (final s in services) {
      if (s.uuid != _service) continue;
      final info = find(s, _info), rx = find(s, _rx), tx = find(s, _tx);
      if (info != null && rx != null && tx != null) {
        _gatt[peripheralId] = _RemoteGatt(info, rx, tx);
        return;
      }
    }
    throw SocketException('Bluetooth device $peripheralId has no Settle Up service');
  }

  @override
  Future<Uint8List> readInfo(String peripheralId) => _manager.readCharacteristic(
        _peripheral(peripheralId),
        _remote(peripheralId).info,
      );

  @override
  Future<void> setTxNotify(String peripheralId, {required bool enabled}) =>
      _manager.setCharacteristicNotifyState(
        _peripheral(peripheralId),
        _remote(peripheralId).tx,
        state: enabled,
      );

  @override
  Future<int> maxWriteLength(String peripheralId) async {
    final p = _peripheral(peripheralId);
    final withResponse = await _manager.getMaximumWriteLength(p,
        type: GATTCharacteristicWriteType.withResponse);
    // iOS reports 512 for writes with response at any MTU and splits
    // larger values into slow prepared writes; the without-response
    // length is the real per-packet room (MTU - 3) on both platforms.
    final perPacket = await _manager.getMaximumWriteLength(p,
        type: GATTCharacteristicWriteType.withoutResponse);
    return perPacket < withResponse ? perPacket : withResponse;
  }

  @override
  Future<void> writeRx(String peripheralId, Uint8List value) =>
      _manager.writeCharacteristic(
        _peripheral(peripheralId),
        _remote(peripheralId).rx,
        value: value,
        type: GATTCharacteristicWriteType.withResponse,
      );
}

/// The real peripheral, on `PeripheralManager`.
final class PluginBlePeripheral implements BlePeripheralApi {
  PluginBlePeripheral({bool? isIOS}) : _isIOS = isIOS ?? Platform.isIOS;

  final bool _isIOS;
  late final PeripheralManager _manager = PeripheralManager();

  late final GATTCharacteristic _infoChar = GATTCharacteristic.mutable(
    uuid: _info,
    properties: const [GATTCharacteristicProperty.read],
    permissions: const [GATTCharacteristicPermission.read],
    descriptors: const [],
  );
  late final GATTCharacteristic _rxChar = GATTCharacteristic.mutable(
    uuid: _rx,
    properties: const [GATTCharacteristicProperty.write],
    permissions: const [GATTCharacteristicPermission.write],
    descriptors: const [],
  );
  late final GATTCharacteristic _txChar = GATTCharacteristic.mutable(
    uuid: _tx,
    properties: const [GATTCharacteristicProperty.notify],
    permissions: const [],
    descriptors: const [],
  );

  BlePeripheralHandler? _handler;
  bool _serviceAdded = false;
  final List<StreamSubscription<Object?>> _subs = [];
  final Map<String, Central> _centrals = {};

  /// INFO as it was at the start of each central's (long) read.
  final Map<String, Uint8List> _infoReads = {};

  @override
  set handler(BlePeripheralHandler? handler) => _handler = handler;

  Central _central(String id) {
    final c = _centrals[id];
    if (c == null) throw SocketException('Bluetooth central $id not connected');
    return c;
  }

  String _remember(Central c) {
    final id = c.uuid.toString();
    _centrals[id] = c;
    return id;
  }

  Future<void> _setUp() async {
    if (_serviceAdded) return;
    _subs
      ..add(_manager.characteristicReadRequested.listen(_onRead))
      ..add(_manager.characteristicWriteRequested.listen(_onWrite))
      ..add(_manager.characteristicNotifyStateChanged.listen((e) {
        if (e.characteristic.uuid != _tx) return;
        _handler?.onTxSubscription(_remember(e.central), subscribed: e.state);
      }))
      ..add(_manager.connectionStateChanged.listen((e) {
        if (e.state != ConnectionState.disconnected) return;
        final id = e.central.uuid.toString();
        _infoReads.remove(id);
        _handler?.onCentralDisconnected(id);
      }));
    // A previous run of the app may have left the service registered.
    await _manager.removeAllServices();
    await _manager.addService(GATTService(
      uuid: _service,
      isPrimary: true,
      includedServices: const [],
      characteristics: [_infoChar, _rxChar, _txChar],
    ));
    _serviceAdded = true;
  }

  Future<void> _onRead(GATTCharacteristicReadRequestedEventArgs e) async {
    final id = _remember(e.central);
    final request = e.request;
    try {
      if (e.characteristic.uuid != _info) {
        await _manager.respondReadRequestWithError(request,
            error: GATTError.readNotPermitted);
        return;
      }
      final Uint8List? value = request.offset == 0
          ? (_infoReads[id] = _handler?.infoValue() ?? Uint8List(0))
          : _infoReads[id];
      if (value == null || request.offset > value.length) {
        await _manager.respondReadRequestWithError(request,
            error: GATTError.invalidOffset);
        return;
      }
      await _manager.respondReadRequestWithValue(request,
          value: Uint8List.sublistView(value, request.offset));
    } catch (_) {
      // The central went away mid-read; nothing to answer.
    }
  }

  Future<void> _onWrite(GATTCharacteristicWriteRequestedEventArgs e) async {
    final id = _remember(e.central);
    final request = e.request;
    try {
      if (e.characteristic.uuid != _rx) {
        await _manager.respondWriteRequestWithError(request,
            error: GATTError.writeNotPermitted);
        return;
      }
      final ok = _handler?.onRxWrite(id, request.value) ?? false;
      if (ok) {
        await _manager.respondWriteRequest(request);
      } else {
        await _manager.respondWriteRequestWithError(request,
            error: GATTError.unlikelyError);
      }
    } catch (_) {
      // The central went away before the response.
    }
  }

  @override
  Future<void> startAdvertising() async {
    await _setUp();
    await _manager.startAdvertising(Advertisement(
      // See the file comment: a name on Android renames the phone.
      name: _isIOS ? kBleLocalName : null,
      serviceUUIDs: [_service],
    ));
  }

  @override
  Future<void> stopAdvertising() => _manager.stopAdvertising();

  @override
  Future<int> maxNotifyLength(String centralId) =>
      _manager.getMaximumNotifyLength(_central(centralId));

  @override
  Future<void> notifyTx(String centralId, Uint8List value) =>
      _manager.notifyCharacteristic(_central(centralId), _txChar, value: value);

  @override
  Future<void> disconnect(String centralId) async {
    _infoReads.remove(centralId);
    await _manager.disconnect(_central(centralId));
  }
}
