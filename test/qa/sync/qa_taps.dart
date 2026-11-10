// QA SYNC-R1: a transport wrapper that taps (and can rewrite or drop)
// every frame of the channels it opens.
import 'dart:typed_data';

import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/transport/hosting_details.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/sync/transport/transport.dart';

/// Delegates to a MemoryTransport; channels it opens pass every frame
/// through [onSend] / [onReceive] (index counts per channel).
final class TapTransport implements SyncTransport, HostingDetails {
  TapTransport(this.inner);
  final MemoryTransport inner;
  Uint8List? Function(int index, Uint8List frame)? onSend;
  Uint8List? Function(int index, Uint8List frame)? onReceive;
  final List<List<Uint8List>> sent = [];

  // Transparent for host mode and connect links, like the transport it
  // wraps (SPEC 8.6: only hosts the transport accepts are dialed).
  @override
  Future<List<String>> hostAddresses() => inner.hostAddresses();
  @override
  Future<String?> wifiName() => inner.wifiName();
  @override
  bool isLinkHost(String address) => inner.isLinkHost(address);

  @override
  TransportKind get kind => inner.kind;
  @override
  Future<TransportAvailability> availability() => inner.availability();
  @override
  Future<TransportAvailability> requestPermissions() =>
      inner.requestPermissions();
  @override
  Future<void> startAdvertising(AdvertiseInfo info) =>
      inner.startAdvertising(info);
  @override
  Future<void> stopAdvertising() => inner.stopAdvertising();
  @override
  Stream<FrameChannel> get inbound => inner.inbound;
  @override
  Stream<DiscoveredPeer> discover() => inner.discover();
  @override
  Future<FrameChannel> connect(
    DiscoveredPeer peer, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    final log = <Uint8List>[];
    sent.add(log);
    return _TapChannel(await inner.connect(peer, timeout: timeout), this, log);
  }

  @override
  Future<void> dispose() => inner.dispose();
}

final class _TapChannel implements FrameChannel {
  _TapChannel(this.inner, this.tap, this.log);
  final FrameChannel inner;
  final TapTransport tap;
  final List<Uint8List> log;
  int _sent = 0;
  int _received = 0;

  @override
  TransportKind get kind => inner.kind;
  @override
  String get peerAddress => inner.peerAddress;
  @override
  int get maxFrameBytes => inner.maxFrameBytes;
  @override
  Stream<Uint8List> get frames => inner.frames.expand((f) {
    final hook = tap.onReceive;
    final out = hook == null ? f : hook(_received, f);
    _received++;
    return out == null ? const <Uint8List>[] : [out];
  });
  @override
  Future<void> send(Uint8List frame) async {
    log.add(Uint8List.fromList(frame));
    final hook = tap.onSend;
    final out = hook == null ? frame : hook(_sent, frame);
    _sent++;
    if (out != null) await inner.send(out);
  }

  @override
  Future<void> close() => inner.close();
}

Uint8List flipByte(Uint8List f, [int at = -1]) {
  final copy = Uint8List.fromList(f);
  final i = at < 0 ? copy.length + at : at;
  copy[i] ^= 0x01;
  return copy;
}
