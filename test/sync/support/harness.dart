// Helpers to run two SyncSessions against each other over MemoryTransport.
import 'dart:async';
import 'dart:typed_data';

import 'package:settle_up/core/models.dart';
import 'package:settle_up/sync/protocol/session.dart';
import 'package:settle_up/sync/transport/memory_transport.dart';
import 'package:settle_up/sync/transport/transport.dart';

import 'test_ledger.dart';

/// Fast timers for tests (the defaults are seconds long).
const SessionTimings fastTimings = SessionTimings(
  handshakeTimeout: Duration(seconds: 2),
  idleTimeout: Duration(seconds: 3),
  pingAfter: Duration(milliseconds: 500),
  liveIdleTimeout: Duration(seconds: 3),
  livePingEvery: Duration(milliseconds: 500),
  closeTimeout: Duration(milliseconds: 500),
  progressInterval: Duration(milliseconds: 20),
  liveFlushDelay: Duration(milliseconds: 50),
  tick: Duration(milliseconds: 25),
);

/// Wraps a channel and rewrites the frames it RECEIVES. [transform] gets
/// the 0-based index of each frame and returns the frames to deliver.
final class InterceptChannel implements FrameChannel {
  InterceptChannel(this.inner, this.transform);

  final FrameChannel inner;
  final List<Uint8List> Function(int index, Uint8List frame) transform;
  final List<int> receivedSizes = [];
  final List<int> sentSizes = [];
  int _index = 0;

  @override
  TransportKind get kind => inner.kind;
  @override
  String get peerAddress => inner.peerAddress;
  @override
  int get maxFrameBytes => inner.maxFrameBytes;

  @override
  Stream<Uint8List> get frames => inner.frames.expand((f) {
        receivedSizes.add(f.length);
        return transform(_index++, f);
      });

  @override
  Future<void> send(Uint8List frame) {
    sentSizes.add(frame.length);
    return inner.send(frame);
  }

  @override
  Future<void> close() => inner.close();
}

List<Uint8List> passThrough(int index, Uint8List frame) => [frame];

/// A connected channel pair over a fresh hub: (initiator end, responder end).
Future<(FrameChannel, FrameChannel)> channelPair({
  int maxFrameBytes = 1 << 20,
  int? dropAfterFrames,
  Duration latency = Duration.zero,
  TransportKind kind = TransportKind.lan,
}) async {
  final hub = MemoryTransportHub(latency: latency);
  final ti = MemoryTransport(hub,
      kind: kind, address: 'initiator', maxFrameBytes: maxFrameBytes)
    ..dropAfterFrames = dropAfterFrames;
  final tr = MemoryTransport(hub,
      kind: kind, address: 'responder', maxFrameBytes: maxFrameBytes);
  await tr.startAdvertising(const AdvertiseInfo(
    deviceId: 'rrrrrrrr',
    deviceName: 'Responder',
    groupTokens: [],
  ));
  final inbound = tr.inbound.first;
  final ci = await ti.connect(DiscoveredPeer(
    kind: kind,
    address: 'responder',
    name: 'Responder',
  ));
  return (ci, await inbound);
}

/// Runs one session between [initiator] and [responder].
Future<(SessionResult, SessionResult)> syncPair(
  TestLedger initiator,
  TestLedger responder, {
  int maxFrameBytes = 1 << 20,
  int? dropAfterFrames,
  SessionTimings timings = fastTimings,
  FrameChannel Function(FrameChannel responderEnd)? wrapResponder,
  FrameChannel Function(FrameChannel initiatorEnd)? wrapInitiator,
  bool live = false,
}) async {
  final (ci, cr) = await channelPair(
    maxFrameBytes: maxFrameBytes,
    dropAfterFrames: dropAfterFrames,
  );
  final si = SyncSession(
    channel: wrapInitiator == null ? ci : wrapInitiator(ci),
    store: initiator,
    role: SessionRole.initiator,
    timings: timings,
    liveMode: live,
  );
  final sr = SyncSession(
    channel: wrapResponder == null ? cr : wrapResponder(cr),
    store: responder,
    role: SessionRole.responder,
    timings: timings,
    liveMode: live,
  );
  final results = await Future.wait([si.run(), sr.run()]);
  return (results[0], results[1]);
}

/// Polls [condition] until it holds or [timeout] passes.
Future<bool> eventually(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    if (condition()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return condition();
}
