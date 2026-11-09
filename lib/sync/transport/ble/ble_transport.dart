// BleTransport (SPEC 8.7.2, kind ble, maxFrame 16 KiB): a GATT service
// through `bluetooth_low_energy`, Android and iOS, both roles.
//
// Peripheral (advertising, responder): one primary service with INFO
// (read), RX (write with response) and TX (notify). A central that turns TX
// notifications on is an inbound channel. Re-advertising swaps the INFO
// value in place; the radio advertisement (service UUID) never changes.
//
// Central (scanning, initiator): the scan filters on the service UUID. A
// new peripheral is probed once: connect, read INFO, disconnect. The
// result is cached by peripheral UUID for 60 s and re-emitted every few
// seconds while advertisements keep arriving, so the engine (which drops
// peers unseen for 15 s) keeps listing it. connect() asks for MTU 517 on
// Android, subscribes to TX and opens the channel.
//
// Frames are cut into BleChunker chunks sized to the write / notify length
// minus the 2-byte header. Flow control: the central writes with response
// (OS paced); the peripheral awaits each notification, retrying a failed
// one after 20 ms up to 50 times. One BLE link carries a channel at a time
// (probes wait for it, a second connect() is refused).
//
// Plugin calls go through BleCentralApi / BlePeripheralApi (ble_api.dart)
// so this file is unit tested against a fake radio (test/sync/bluetooth).
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io' show SocketException;
import 'dart:typed_data';

import '../../../core/models.dart';
import '../../platform/permissions.dart';
import '../transport.dart';
import 'ble_api.dart';
import 'ble_chunker.dart';
import 'ble_info.dart';
import 'ble_uuids.dart';

export 'ble_chunker.dart' show kBleMaxFrameBytes;

void _log(String message, [Object? error, StackTrace? st]) => developer.log(
      message,
      name: 'settle_up.sync.ble',
      error: error,
      stackTrace: st,
    );

final class BleTransport implements SyncTransport {
  /// [permissions] defaults to the system wrapper; [central] and
  /// [peripheral] default to the plugin. The durations are test hooks.
  BleTransport({
    this._permissions,
    BleCentralApi? central,
    BlePeripheralApi? peripheral,
    this.rediscoverInterval = const Duration(seconds: 5),
    this.visibleFor = const Duration(seconds: 10),
    this.infoCacheFor = const Duration(seconds: 60),
    this.probeTimeout = const Duration(seconds: 8),
    this.probeRetryAfter = const Duration(seconds: 10),
    this.notifyRetryDelay = const Duration(milliseconds: 20),
    this.notifyAttempts = 50,
    this.maxFrameBytes = kBleMaxFrameBytes,
  })  : _centralOverride = central,
        _peripheralOverride = peripheral;

  /// How often [discover] re-emits peripherals that are still advertising.
  final Duration rediscoverInterval;

  /// A peripheral counts as visible this long after its last advertisement.
  final Duration visibleFor;

  /// How long an INFO read stays good (SPEC: 60 s).
  final Duration infoCacheFor;

  /// Limit for one connect + INFO read + disconnect.
  final Duration probeTimeout;

  /// Wait before probing a peripheral again after a failed probe.
  final Duration probeRetryAfter;

  /// Peripheral flow control: delay between notify attempts, and how many.
  final Duration notifyRetryDelay;
  final int notifyAttempts;

  /// Largest frame on channels from this transport (SPEC: 16 KiB).
  final int maxFrameBytes;

  NearbyPermissions? _permissions;
  NearbyPermissions get _perms => _permissions ??= NearbyPermissions();

  final BleCentralApi? _centralOverride;
  final BlePeripheralApi? _peripheralOverride;
  BleCentralApi? _centralApi;
  BlePeripheralApi? _peripheralApi;
  final List<StreamSubscription<Object?>> _centralSubs = [];

  BleCentralApi get _central {
    final existing = _centralApi;
    if (existing != null) return existing;
    final api = _centralApi = _centralOverride ?? PluginBleCentral();
    _centralSubs
      ..add(api.notifications.listen(
        (n) => _onNotification(n.$1, n.$2),
        onError: (Object e, StackTrace st) => _log('notifications', e, st),
      ))
      ..add(api.disconnections.listen(
        _onPeripheralDisconnected,
        onError: (Object e, StackTrace st) => _log('disconnections', e, st),
      ));
    return api;
  }

  BlePeripheralApi get _peripheral {
    final existing = _peripheralApi;
    if (existing != null) return existing;
    final api = _peripheralApi = _peripheralOverride ?? PluginBlePeripheral();
    api.handler = _PeripheralHandler(this);
    return api;
  }

  final StreamController<FrameChannel> _inbound = StreamController.broadcast();
  bool _disposed = false;

  /// Serializes start/stop of advertising and scanning.
  Future<void> _queue = Future.value();

  /// Serializes use of the central radio (probes and connects).
  Future<void> _radio = Future.value();

  // Peripheral role.
  bool _advertising = false;
  Uint8List? _infoValue;
  final Map<String, _Link> _byCentral = {};

  // Central role.
  final Map<String, _Link> _byPeripheral = {};
  final Set<StreamController<DiscoveredPeer>> _listeners = {};
  final Map<String, _Sighting> _seen = {};
  final List<String> _probeQueue = [];
  bool _probing = false;
  bool _scanning = false;
  StreamSubscription<String>? _adverts;
  Timer? _tick;
  int _connecting = 0;

  @override
  TransportKind get kind => TransportKind.ble;

  bool get isAdvertising => _advertising;
  bool get isScanning => _scanning;

  /// Channels open in either role (tests).
  int get openChannels => [
        ..._byCentral.values,
        ..._byPeripheral.values,
      ].where((l) => l.channel.isOpen && l.announced).length;

  /// A channel is open or being set up: the one BLE link is taken.
  bool get _linkBusy =>
      _connecting > 0 ||
      _byPeripheral.values.any((l) => l.channel.isOpen) ||
      _byCentral.values.any((l) => l.channel.isOpen && l.announced);

  // ------------------------------------------------------ availability --

  @override
  Future<TransportAvailability> availability() => _perms.check(kind);

  @override
  Future<TransportAvailability> requestPermissions() => _perms.request(kind);

  // ---------------------------------------------------- peripheral role --

  @override
  Future<void> startAdvertising(AdvertiseInfo info) => _serial(() async {
        _checkAlive();
        // A repeated call (new token window, new group) only swaps INFO;
        // the advertisement itself is the service UUID and never changes.
        _infoValue = BleInfo.of(info).encode();
        if (_advertising) return;
        try {
          await _peripheral.startAdvertising();
          _advertising = true;
        } catch (e) {
          _infoValue = null;
          rethrow;
        }
      });

  @override
  Future<void> stopAdvertising() => _serial(() async {
        _infoValue = null;
        // Centrals that connected but never subscribed are not sessions.
        for (final link in _byCentral.values.toList()) {
          if (!link.announced) link.channel._remoteClosed();
        }
        if (!_advertising) return;
        _advertising = false;
        try {
          await _peripheral.stopAdvertising();
        } catch (e, st) {
          _log('stopAdvertising failed', e, st);
        }
      });

  @override
  Stream<FrameChannel> get inbound => _inbound.stream;

  _Link? _peripheralLinkFor(String centralId) {
    final existing = _byCentral[centralId];
    if (existing != null && existing.channel.isOpen) return existing;
    if (!_advertising || _disposed) return null;
    final link = _Link.peripheral(this, centralId);
    _byCentral[centralId] = link;
    return link;
  }

  bool _onRxWrite(String centralId, Uint8List value) {
    final link = _peripheralLinkFor(centralId);
    if (link == null) return false;
    return link.channel._receiveChunk(value);
  }

  void _onTxSubscription(String centralId, {required bool subscribed}) {
    if (!subscribed) {
      _byCentral[centralId]?.channel._remoteClosed();
      return;
    }
    final link = _peripheralLinkFor(centralId);
    if (link == null) {
      unawaited(_dropCentral(centralId));
      return;
    }
    if (link.announced) return;
    link.announced = true;
    _inbound.add(link.channel);
  }

  void _onCentralDisconnected(String centralId) {
    _byCentral[centralId]?.channel._remoteClosed();
  }

  Future<void> _dropCentral(String centralId) async {
    try {
      await _peripheral.disconnect(centralId);
    } catch (e, st) {
      // iOS cannot drop a central; it goes away when the phone does.
      _log('disconnect central $centralId failed', e, st);
    }
  }

  /// One notification, retried on failure (SPEC: 20 ms, up to 50 times).
  Future<void> _notify(String centralId, Uint8List chunk) async {
    for (var attempt = 1;; attempt++) {
      try {
        await _peripheral.notifyTx(centralId, chunk);
        return;
      } catch (e) {
        if (attempt >= notifyAttempts) {
          throw SocketException(
            'Bluetooth notify to $centralId failed $attempt times: $e',
          );
        }
        await Future<void>.delayed(notifyRetryDelay);
      }
    }
  }

  // ------------------------------------------------------- central role --

  @override
  Stream<DiscoveredPeer> discover() {
    late final StreamController<DiscoveredPeer> ctl;
    ctl = StreamController<DiscoveredPeer>(
      onListen: () {
        if (_disposed) {
          unawaited(ctl.close());
          return;
        }
        _listeners.add(ctl);
        final now = DateTime.now();
        for (final s in _seen.values) {
          final peer = s.peer;
          if (peer != null && s.visibleAt(now, visibleFor)) ctl.add(peer);
        }
        unawaited(_updateScan());
      },
      onCancel: () {
        _listeners.remove(ctl);
        return _updateScan();
      },
    );
    return ctl.stream;
  }

  Future<void> _updateScan() => _serial(() async {
        final want = _listeners.isNotEmpty && !_disposed;
        if (want == _scanning) return;
        final api = _central;
        if (want) {
          _scanning = true;
          _adverts = api.advertisements.listen(
            _onAdvertisement,
            onError: (Object e, StackTrace st) => _log('scan error', e, st),
          );
          try {
            await api.startScan();
          } catch (e, st) {
            _scanning = false;
            await _adverts?.cancel();
            _adverts = null;
            _log('startScan failed', e, st);
            for (final l in _listeners.toList()) {
              l.addError(e, st);
            }
            return;
          }
          _tick = Timer.periodic(rediscoverInterval, (_) => _onTick());
        } else {
          _scanning = false;
          _tick?.cancel();
          _tick = null;
          await _adverts?.cancel();
          _adverts = null;
          _probeQueue.clear();
          try {
            await api.stopScan();
          } catch (e, st) {
            _log('stopScan failed', e, st);
          }
        }
      });

  void _onAdvertisement(String id) {
    if (!_scanning || _disposed) return;
    final now = DateTime.now();
    final s = _seen.putIfAbsent(id, _Sighting.new);
    final wasVisible = s.visibleAt(now, visibleFor);
    s.lastSeen = now;
    final peer = s.peer;
    if (peer != null && !wasVisible && s.fresh(now, infoCacheFor)) {
      _emit(peer);
    }
    _maybeProbe(id, s, now);
  }

  void _onTick() {
    final now = DateTime.now();
    for (final entry in _seen.entries.toList()) {
      final s = entry.value;
      if (!s.visibleAt(now, visibleFor)) {
        // Long gone: forget it, a later sighting probes again.
        if (now.difference(s.lastSeen) > infoCacheFor) _seen.remove(entry.key);
        continue;
      }
      final peer = s.peer;
      if (peer != null) _emit(peer);
      _maybeProbe(entry.key, s, now);
    }
  }

  void _maybeProbe(String id, _Sighting s, DateTime now) {
    if (s.fresh(now, infoCacheFor) || s.queued) return;
    final failed = s.failedAt;
    if (failed != null && now.difference(failed) < probeRetryAfter) return;
    if (_byPeripheral.containsKey(id)) return;
    s.queued = true;
    _probeQueue.add(id);
    unawaited(_runProbes());
  }

  Future<void> _runProbes() async {
    if (_probing) return;
    _probing = true;
    try {
      while (_probeQueue.isNotEmpty && _scanning && !_disposed) {
        // One BLE link at a time: a session in progress goes first.
        if (_linkBusy) break;
        final id = _probeQueue.removeAt(0);
        final s = _seen[id];
        if (s == null) continue;
        s.queued = false;
        await _withRadio(() => _probe(id, s));
      }
    } finally {
      _probing = false;
    }
  }

  Future<void> _probe(String id, _Sighting s) async {
    if (_linkBusy || _disposed) {
      // Try again on the next tick.
      return;
    }
    final api = _central;
    BleInfo? info;
    final attempt = () async {
      await api.connect(id);
      await api.discoverService(id);
      return BleInfo.tryParse(await api.readInfo(id));
    }();
    try {
      info = await attempt.timeout(probeTimeout);
    } on TimeoutException catch (e) {
      _log('probe $id timed out', e);
      // A connect that completes late must not stay up.
      unawaited(attempt.then(
        (_) => _disconnectPeripheral(id),
        onError: (Object _) {},
      ));
    } catch (e) {
      _log('probe $id failed', e);
    }
    await _disconnectPeripheral(id);
    final now = DateTime.now();
    if (info == null) {
      s.failedAt = now;
      return;
    }
    s
      ..peer = info.toPeer(id)
      ..infoAt = now
      ..failedAt = null;
    if (s.visibleAt(now, visibleFor)) _emit(s.peer!);
  }

  Future<void> _disconnectPeripheral(String id) async {
    try {
      await _central.disconnect(id);
    } catch (e, st) {
      _log('disconnect $id failed', e, st);
    }
  }

  void _emit(DiscoveredPeer peer) {
    for (final l in _listeners) {
      l.add(peer);
    }
  }

  @override
  Future<FrameChannel> connect(
    DiscoveredPeer peer, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    _checkAlive();
    if (peer.kind != kind) {
      throw ArgumentError.value(peer.kind, 'peer.kind', 'not ble');
    }
    if (_linkBusy) {
      throw const SocketException('Another Bluetooth connection is active');
    }
    final id = peer.address;
    _connecting++;
    try {
      return await _withRadio(() => _open(id, timeout));
    } finally {
      _connecting--;
    }
  }

  Future<FrameChannel> _open(String id, Duration timeout) async {
    _checkAlive();
    final api = _central;
    final link = _Link.central(this, id);
    _byPeripheral[id] = link;
    final setUp = () async {
      await api.connect(id);
      try {
        final mtu = await api.requestMtu(id, kBleRequestedMtu);
        if (mtu != null) _log('MTU $mtu with $id');
      } catch (e) {
        // A smaller MTU only means smaller chunks.
        _log('requestMtu($id) failed', e);
      }
      await api.discoverService(id);
      await api.setTxNotify(id, enabled: true);
    }();
    try {
      await setUp.timeout(timeout);
    } catch (e) {
      if (identical(_byPeripheral[id], link)) _byPeripheral.remove(id);
      link.channel._remoteClosed();
      if (e is TimeoutException) {
        // A set-up that completes late must not leave the link up.
        unawaited(setUp.then(
          (_) => _disconnectPeripheral(id),
          onError: (Object _) {},
        ));
      }
      await _disconnectPeripheral(id);
      if (e is TimeoutException || e is SocketException) rethrow;
      throw SocketException('Bluetooth connect to $id failed: $e');
    }
    link.announced = true;
    return link.channel;
  }

  void _onNotification(String peripheralId, Uint8List value) {
    final link = _byPeripheral[peripheralId];
    if (link == null) return;
    link.channel._receiveChunk(value);
  }

  void _onPeripheralDisconnected(String peripheralId) {
    _byPeripheral[peripheralId]?.channel._remoteClosed();
  }

  // ------------------------------------------------------------- links --

  void _released(_Link link) {
    final map = link.isCentral ? _byPeripheral : _byCentral;
    if (identical(map[link.remoteId], link)) map.remove(link.remoteId);
    // The link is free again: pending probes may run.
    if (_probeQueue.isNotEmpty) unawaited(_runProbes());
  }

  Future<int> _attPayload(_Link link) => link.isCentral
      ? _central.maxWriteLength(link.remoteId)
      : _peripheral.maxNotifyLength(link.remoteId);

  Future<void> _sendChunk(_Link link, Uint8List chunk) => link.isCentral
      ? _central.writeRx(link.remoteId, chunk)
      : _notify(link.remoteId, chunk);

  Future<void> _hangUp(_Link link) async {
    if (link.isCentral) {
      await _disconnectPeripheral(link.remoteId);
    } else {
      await _dropCentral(link.remoteId);
    }
  }

  // ------------------------------------------------------------ dispose --

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    await stopAdvertising();
    _disposed = true;
    for (final l in _listeners.toList()) {
      await l.close();
    }
    _listeners.clear();
    await _updateScan();
    for (final link in [..._byPeripheral.values, ..._byCentral.values]) {
      await link.channel.close();
    }
    _byPeripheral.clear();
    _byCentral.clear();
    for (final s in _centralSubs) {
      await s.cancel();
    }
    _centralSubs.clear();
    _peripheralApi?.handler = null;
    await _inbound.close();
  }

  Future<void> _serial(Future<void> Function() body) {
    final next = _queue.then((_) => body());
    _queue = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  Future<T> _withRadio<T>(Future<T> Function() body) {
    final next = _radio.then((_) => body());
    _radio = next.then((_) {}, onError: (Object _) {});
    return next;
  }

  void _checkAlive() {
    if (_disposed) throw StateError('BleTransport disposed');
  }
}

final class _PeripheralHandler implements BlePeripheralHandler {
  _PeripheralHandler(this._t);
  final BleTransport _t;

  @override
  Uint8List? infoValue() => _t._infoValue;

  @override
  bool onRxWrite(String centralId, Uint8List value) =>
      _t._onRxWrite(centralId, value);

  @override
  void onTxSubscription(String centralId, {required bool subscribed}) =>
      _t._onTxSubscription(centralId, subscribed: subscribed);

  @override
  void onCentralDisconnected(String centralId) =>
      _t._onCentralDisconnected(centralId);
}

/// A peripheral the scanner has seen.
final class _Sighting {
  DateTime lastSeen = DateTime.fromMillisecondsSinceEpoch(0);
  DiscoveredPeer? peer;
  DateTime? infoAt;
  DateTime? failedAt;
  bool queued = false;

  bool visibleAt(DateTime now, Duration window) =>
      now.difference(lastSeen) <= window;

  bool fresh(DateTime now, Duration cacheFor) {
    final at = infoAt;
    return at != null && now.difference(at) < cacheFor;
  }
}

/// One BLE connection in one role, and its channel.
final class _Link {
  _Link.central(BleTransport t, this.remoteId) : isCentral = true {
    channel = _BleChannel(t, this);
  }

  _Link.peripheral(BleTransport t, this.remoteId) : isCentral = false {
    channel = _BleChannel(t, this);
  }

  /// True when we are the central (remote is a peripheral).
  final bool isCentral;
  final String remoteId;
  late final _BleChannel channel;

  /// The channel was handed out (connect() returned it / inbound got it).
  bool announced = false;
}

final class _BleChannel implements FrameChannel {
  _BleChannel(this._t, this._link)
      : _chunker = BleChunker(maxFrameBytes: _t.maxFrameBytes),
        _reassembler = BleReassembler(maxFrameBytes: _t.maxFrameBytes);

  final BleTransport _t;
  final _Link _link;
  final BleChunker _chunker;
  final BleReassembler _reassembler;
  final StreamController<Uint8List> _frames = StreamController();
  Future<void> _tail = Future.value();

  /// No more sends accepted.
  bool _closed = false;

  /// The connection is gone: queued sends fail instead of going out.
  bool _dead = false;

  bool get isOpen => !_dead;

  @override
  TransportKind get kind => TransportKind.ble;

  @override
  String get peerAddress => _link.remoteId;

  @override
  int get maxFrameBytes => _t.maxFrameBytes;

  @override
  Stream<Uint8List> get frames => _frames.stream;

  @override
  Future<void> send(Uint8List frame) {
    if (_closed) return Future.error(StateError('Channel closed'));
    if (frame.length > maxFrameBytes) {
      return Future.error(
        ArgumentError('Frame of ${frame.length} bytes > $maxFrameBytes'),
      );
    }
    final copy = Uint8List.fromList(frame);
    final sent = _tail.then((_) async {
      if (_dead) throw StateError('Channel closed');
      try {
        final att = await _t._attPayload(_link);
        for (final chunk in _chunker.split(copy, attPayload: att)) {
          if (_dead) throw const _Closed();
          await _t._sendChunk(_link, chunk);
        }
      } on _Closed {
        throw StateError('Channel closed');
      } catch (e) {
        final error = e is SocketException
            ? e
            : SocketException('Bluetooth send to $peerAddress failed: $e');
        _fail(error);
        throw error;
      }
    });
    _tail = sent.then((_) {}, onError: (Object _) {});
    return sent;
  }

  /// Feeds one chunk; false (and the channel fails) on a violation.
  bool _receiveChunk(Uint8List chunk) {
    if (_dead) return false;
    final Uint8List? frame;
    try {
      frame = _reassembler.add(chunk);
    } on BleChunkException catch (e) {
      _fail(SocketException('Bluetooth stream from $peerAddress broken: '
          '${e.message}'));
      return false;
    }
    if (frame != null) _frames.add(frame);
    return true;
  }

  void _fail(Object error) {
    if (_dead) return;
    _closed = _dead = true;
    _frames.addError(error);
    unawaited(_frames.close());
    _t._released(_link);
    unawaited(_t._hangUp(_link));
  }

  void _remoteClosed() {
    if (_dead) return;
    _closed = _dead = true;
    unawaited(_frames.close());
    _t._released(_link);
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // Frames queued before close still go out first.
    await _tail;
    if (_dead) return;
    _dead = true;
    _t._released(_link);
    await _t._hangUp(_link);
    // Nobody may drain it after a local close; do not wait.
    unawaited(_frames.close());
  }
}

/// The channel died between two chunks of a frame.
final class _Closed implements Exception {
  const _Closed();
}
