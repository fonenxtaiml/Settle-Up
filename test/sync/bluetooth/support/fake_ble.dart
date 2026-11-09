// An in-process BLE "air" for BleTransport tests. Every phone has a
// FakeBleCentral and a FakeBlePeripheral sharing its id (the peripheral
// UUID other phones see, and the central UUID peripherals see).
//
// Like the plugin it:
// - repeats advertisements while a central scans (every [advertEvery]);
// - negotiates the MTU on requestMtu (Android) or keeps a fixed one (iOS);
// - sizes writes and notifications by the MTU and rejects bigger ones;
// - answers writes after the peripheral handler ran (write with response);
// - reports disconnects on both sides.
import 'dart:async';
import 'dart:typed_data';

import 'package:settle_up/sync/transport/ble/ble_api.dart';
import 'package:settle_up/sync/transport/ble/ble_chunker.dart';

final class FakeBleAir {
  FakeBleAir({this.advertEvery = const Duration(milliseconds: 40)});

  final Duration advertEvery;
  final Map<String, FakeBleCentral> _centrals = {};
  final Map<String, FakeBlePeripheral> _peripherals = {};

  FakeBleCentral central(String id) =>
      _centrals[id] ??= FakeBleCentral._(this, id);

  FakeBlePeripheral peripheral(String id) =>
      _peripherals[id] ??= FakeBlePeripheral._(this, id);
}

/// One central-peripheral connection.
final class _Conn {
  _Conn(this.central, this.peripheral, this.mtu);
  final FakeBleCentral central;
  final FakeBlePeripheral peripheral;
  int mtu;
  bool subscribed = false;
}

final class FakeBleCentral implements BleCentralApi {
  FakeBleCentral._(this.air, this.id);

  final FakeBleAir air;
  final String id;

  /// Android asks for an MTU; iOS does not (requestMtu returns null).
  bool canRequestMtu = true;

  /// Most MTU this phone's stack allows.
  int maxMtu = 517;

  /// MTU when nothing was negotiated.
  int defaultMtu = 23;

  /// Make connect() hang (a peripheral that walked away).
  bool connectHangs = false;

  /// Peripherals that answer INFO reads with garbage.
  final Set<String> garbageInfo = {};

  /// The disconnect report for a connection arrives this much later than
  /// the disconnect() call returns (a slow platform callback).
  Duration disconnectReportDelay = Duration.zero;

  /// How long connect() takes.
  Duration connectDelay = Duration.zero;

  final StreamController<String> _adverts = StreamController.broadcast();
  final StreamController<String> _disconnects = StreamController.broadcast();
  final StreamController<(String, Uint8List)> _notifications =
      StreamController.broadcast();
  Timer? _scan;
  final Map<String, _Conn> _conns = {};

  bool get scanning => _scan != null;
  final List<String> calls = [];
  final List<int> writeSizes = [];

  int count(String call) => calls.where((c) => c == call).length;

  /// Open connections (probes and channels).
  Iterable<String> get connectedTo => _conns.keys;

  @override
  Stream<String> get advertisements => _adverts.stream;

  @override
  Stream<String> get disconnections => _disconnects.stream;

  @override
  Stream<(String, Uint8List)> get notifications => _notifications.stream;

  @override
  Future<void> startScan() async {
    calls.add('startScan');
    _scan ??= Timer.periodic(air.advertEvery, (_) {
      for (final p in air._peripherals.values) {
        if (p.advertising && p.id != id) _adverts.add(p.id);
      }
    });
  }

  @override
  Future<void> stopScan() async {
    calls.add('stopScan');
    _scan?.cancel();
    _scan = null;
  }

  FakeBlePeripheral _target(String peripheralId) {
    final p = air._peripherals[peripheralId];
    if (p == null) throw StateError('No such peripheral $peripheralId');
    return p;
  }

  _Conn _conn(String peripheralId) {
    final c = _conns[peripheralId];
    if (c == null) throw StateError('Not connected to $peripheralId');
    return c;
  }

  @override
  Future<void> connect(String peripheralId) async {
    calls.add('connect');
    if (connectHangs) await Completer<void>().future;
    final p = _target(peripheralId);
    if (!p.advertising && !p.connectable) {
      throw StateError('Peripheral $peripheralId not connectable');
    }
    await Future<void>.delayed(connectDelay);
    final conn = _Conn(this, p, defaultMtu);
    _conns[peripheralId] = conn;
    p._conns[id] = conn;
  }

  @override
  Future<void> disconnect(String peripheralId) async {
    calls.add('disconnect');
    final conn = _conns.remove(peripheralId);
    if (conn == null) return;
    conn.peripheral._conns.remove(id);
    conn.peripheral._handler?.onCentralDisconnected(id);
    final delay = disconnectReportDelay;
    if (delay == Duration.zero) {
      _disconnects.add(peripheralId);
    } else {
      unawaited(Future<void>.delayed(delay, () => _disconnects.add(peripheralId)));
    }
  }

  /// The radio link dies.
  void dropLink(String peripheralId) => unawaited(disconnect(peripheralId));

  @override
  Future<int?> requestMtu(String peripheralId, int mtu) async {
    calls.add('requestMtu:$mtu');
    final conn = _conn(peripheralId);
    if (!canRequestMtu) return null;
    var m = mtu;
    if (maxMtu < m) m = maxMtu;
    if (conn.peripheral.maxMtu < m) m = conn.peripheral.maxMtu;
    conn.mtu = m;
    return m;
  }

  @override
  Future<void> discoverService(String peripheralId) async {
    calls.add('discoverService');
    final conn = _conn(peripheralId);
    if (!conn.peripheral.hasService) throw StateError('No service');
  }

  @override
  Future<Uint8List> readInfo(String peripheralId) async {
    calls.add('readInfo');
    final conn = _conn(peripheralId);
    if (garbageInfo.contains(peripheralId)) {
      return Uint8List.fromList([1, 2, 3]);
    }
    final value = conn.peripheral._handler?.infoValue();
    if (value == null) throw StateError('GATT read error');
    return value;
  }

  @override
  Future<void> setTxNotify(String peripheralId, {required bool enabled}) async {
    calls.add('setTxNotify:$enabled');
    final conn = _conn(peripheralId);
    conn.subscribed = enabled;
    await Future<void>.delayed(Duration.zero);
    conn.peripheral._handler?.onTxSubscription(id, subscribed: enabled);
  }

  @override
  Future<int> maxWriteLength(String peripheralId) async =>
      bleAttPayloadForMtu(_conn(peripheralId).mtu);

  @override
  Future<void> writeRx(String peripheralId, Uint8List value) async {
    final conn = _conn(peripheralId);
    if (value.length > bleAttPayloadForMtu(conn.mtu)) {
      throw StateError('Write of ${value.length} > MTU ${conn.mtu}');
    }
    writeSizes.add(value.length);
    await Future<void>.delayed(Duration.zero);
    final p = conn.peripheral;
    final drop = p.dropRxChunkNumber;
    if (drop != null && ++p._rxChunks == drop) return; // lost, but "ok"
    final ok = p._handler?.onRxWrite(id, Uint8List.fromList(value)) ?? false;
    if (!ok) throw StateError('GATT write error');
  }

  void _notified(String peripheralId, Uint8List value) =>
      _notifications.add((peripheralId, value));
}

final class FakeBlePeripheral implements BlePeripheralApi {
  FakeBlePeripheral._(this.air, this.id);

  final FakeBleAir air;
  final String id;

  bool advertising = false;
  bool hasService = false;

  /// Lets centrals connect while not advertising (a link made earlier).
  bool connectable = false;

  int maxMtu = 517;

  /// The next this-many notifications fail (then succeed).
  int failNotifies = 0;

  /// If set, the n-th RX chunk (1-based) is silently lost.
  int? dropRxChunkNumber;
  int _rxChunks = 0;

  BlePeripheralHandler? _handler;
  final Map<String, _Conn> _conns = {};
  final List<String> calls = [];
  final List<int> notifySizes = [];
  int notifyAttempts = 0;

  int count(String call) => calls.where((c) => c == call).length;

  @override
  set handler(BlePeripheralHandler? handler) => _handler = handler;

  @override
  Future<void> startAdvertising() async {
    calls.add('startAdvertising');
    if (advertising) throw StateError('Already advertising');
    hasService = true;
    advertising = true;
  }

  @override
  Future<void> stopAdvertising() async {
    calls.add('stopAdvertising');
    advertising = false;
  }

  _Conn _conn(String centralId) {
    final c = _conns[centralId];
    if (c == null) throw StateError('Central $centralId not connected');
    return c;
  }

  @override
  Future<int> maxNotifyLength(String centralId) async =>
      bleAttPayloadForMtu(_conn(centralId).mtu);

  @override
  Future<void> notifyTx(String centralId, Uint8List value) async {
    notifyAttempts++;
    final conn = _conn(centralId);
    if (failNotifies > 0) {
      failNotifies--;
      throw StateError('Notification queue full');
    }
    if (value.length > bleAttPayloadForMtu(conn.mtu)) {
      throw StateError('Notify of ${value.length} > MTU ${conn.mtu}');
    }
    if (!conn.subscribed) throw StateError('Central not subscribed');
    notifySizes.add(value.length);
    await Future<void>.delayed(Duration.zero);
    conn.central._notified(id, Uint8List.fromList(value));
  }

  @override
  Future<void> disconnect(String centralId) async {
    calls.add('disconnect');
    final conn = _conns[centralId];
    if (conn == null) return;
    await conn.central.disconnect(id);
  }

  /// Injects an RX chunk from [centralId] as if it had written it.
  bool writeFrom(String centralId, Uint8List value) =>
      _handler?.onRxWrite(centralId, value) ?? false;
}
