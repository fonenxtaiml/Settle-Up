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
  // The location switch is off where Bluetooth scans need it (Android API
  // <= 32 for Nearby, <= 30 for BLE); Bluetooth itself may be on.
  locationOff,
  unsupported, // platform/hardware cannot do it
}

/// What we advertise while "visible".
@immutable
final class AdvertiseInfo {
  const AdvertiseInfo({
    required this.deviceId,
    required this.deviceName,
    required this.groupTokens,
    this.advertId,
    this.tokenWindow,
  });

  /// This phone's device id. Never advertised: transports advertise
  /// [advertId] instead.
  final DeviceId deviceId;
  final String deviceName;

  /// Rotating blinded tokens, one per group we hold (4 base64url chars
  /// each, SPEC 8.3), most important first. Transports include as many as
  /// fit from the front (LAN: up to 240, Nearby: up to 24, BLE: in the
  /// INFO characteristic, up to 96), sort them, and flag the advert when
  /// they had to leave some out.
  final List<String> groupTokens;

  /// Per-window random id (8 hex chars, SPEC 8.3) that lets scanners merge
  /// this phone's transports and recognise their own adverts. Null: none
  /// advertised.
  final String? advertId;

  /// The token window [groupTokens] are for (advertised as its window tag,
  /// so scanners with a skewed clock still match). Null: not advertised.
  final int? tokenWindow;
}

@immutable
final class DiscoveredPeer {
  const DiscoveredPeer({
    required this.kind,
    required this.address,
    required this.name,
    this.advertId,
    this.groupTokens = const {},
    this.windowTag,
    this.moreGroups = false,
  });

  final TransportKind kind;

  /// Transport-specific connect handle: 'host:port' (lan, IPv6 bracketed),
  /// Nearby endpointId (nearby), peripheral UUID string (ble).
  final String address;
  final String name; // device name as advertised ('' if unknown)
  final String? advertId; // per-window advert id (SPEC 8.3), if advertised
  final Set<String> groupTokens;

  /// The advertised window tag of [groupTokens] (window mod 4096), if any.
  final int? windowTag;

  /// The advert left some of the phone's group tokens out (it is in more
  /// groups than the advert holds), so it may share a group with us even
  /// when no token matches.
  final bool moreGroups;

  /// Whether [other] is the same advertiser on the same transport: the same
  /// connect handle (a LAN phone runs one server, kept across re-adverts)
  /// or the same advert id (random per phone and window, SPEC 8.3). A
  /// transport that caches sightings by service name or endpoint shows only
  /// the newest of these, so a re-advert under a new name replaces the old
  /// one even when its goodbye is missed (SYNC-R6-01).
  bool sameAdvertiserAs(DiscoveredPeer other) =>
      other.kind == kind &&
      (other.address == address ||
          (advertId != null && other.advertId == advertId));

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
