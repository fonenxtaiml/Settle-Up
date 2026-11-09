// FROZEN CONTRACT (docs/SPEC.md section 5.12). Owner: sync-core.
// A transport moves opaque FRAMES (already encrypted by the session layer)
// reliably and in order. It knows nothing about ops, groups or crypto.
import 'dart:typed_data';

import 'package:meta/meta.dart';

import '../../core/ids.dart';
import '../../core/models.dart';

enum TransportAvailability {
  ready,
  needsPermission,
  permissionPermanentlyDenied,
  radioOff, // Bluetooth or Wi-Fi switched off
  unsupported, // platform/hardware cannot do it
}

/// What we advertise while "visible".
@immutable
final class AdvertiseInfo {
  const AdvertiseInfo({
    required this.deviceId,
    required this.deviceName,
    required this.groupTokens,
  });

  final DeviceId deviceId;
  final String deviceName;

  /// Rotating blinded tokens, one per group we hold (16 hex chars each,
  /// SPEC 8.3). Transports include as many as fit (LAN: all up to 16,
  /// Nearby: up to 4, BLE: in the INFO characteristic, up to 16).
  final List<String> groupTokens;
}

@immutable
final class DiscoveredPeer {
  const DiscoveredPeer({
    required this.kind,
    required this.address,
    required this.name,
    this.deviceIdPrefix,
    this.groupTokens = const {},
  });

  final TransportKind kind;

  /// Transport-specific connect handle: 'host:port' (lan, IPv6 bracketed),
  /// Nearby endpointId (nearby), peripheral UUID string (ble).
  final String address;
  final String name; // device name as advertised ('' if unknown)
  final String? deviceIdPrefix; // first 8 chars of deviceId, if advertised
  final Set<String> groupTokens;

  @override
  bool operator ==(Object other) =>
      other is DiscoveredPeer && other.kind == kind && other.address == address;

  @override
  int get hashCode => Object.hash(kind, address);
}

/// Reliable, ordered, message-oriented, full duplex.
abstract interface class FrameChannel {
  TransportKind get kind;
  String get peerAddress;

  /// Largest frame this channel carries: lan 1 MiB, nearby 32 KiB,
  /// ble 16 KiB. The session negotiates min(local, remote).
  int get maxFrameBytes;

  /// Single-subscription. Each event is exactly one frame as passed to
  /// [send] on the other side. Done when the channel closes; errors on
  /// transport failure.
  Stream<Uint8List> get frames;

  /// Completes when the frame is handed to the OS (applies backpressure).
  /// Throws StateError after close, ArgumentError if > maxFrameBytes.
  Future<void> send(Uint8List frame);

  Future<void> close();
}

abstract interface class SyncTransport {
  TransportKind get kind;

  Future<TransportAvailability> availability();

  /// Requests the runtime permissions this transport needs. Returns the
  /// availability afterwards.
  Future<TransportAvailability> requestPermissions();

  /// Start accepting inbound connections and announcing [info].
  Future<void> startAdvertising(AdvertiseInfo info);
  Future<void> stopAdvertising();

  /// Inbound connections while advertising (broadcast stream).
  Stream<FrameChannel> get inbound;

  /// Scans while listened to; cancelling the subscription stops scanning.
  /// Emits a peer again when its info changes.
  Stream<DiscoveredPeer> discover();

  /// Throws TimeoutException or SocketException-like errors on failure.
  Future<FrameChannel> connect(
    DiscoveredPeer peer, {
    Duration timeout = const Duration(seconds: 10),
  });

  Future<void> dispose();
}
