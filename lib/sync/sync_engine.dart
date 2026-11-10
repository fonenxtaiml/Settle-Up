// FROZEN CONTRACT (docs/SPEC.md section 5.13). Owner: sync-core.
// The only sync API the UI uses.
import 'package:meta/meta.dart';

import '../core/ids.dart';
import '../core/models.dart';
import 'transport/transport.dart';

enum SyncPhase { connecting, handshaking, comparing, transferring, finishing }

enum SyncFailure {
  permissionDenied,
  radioOff,
  locationOff, // Bluetooth on, the location switch off where scans need it
  peerUnreachable,
  timeout,
  noSharedGroups,
  authFailed,
  protocolMismatch,
  connectionLost,
  invalidCode, // QR/link could not be parsed
  cancelled,
  internal,
}

final class SyncException implements Exception {
  const SyncException(this.failure, [this.message = '', this.partial]);
  final SyncFailure failure;
  final String message;
  final SyncSummary? partial;
  @override
  String toString() => 'SyncException(${failure.name}: $message)';
}

@immutable
final class SyncProgress {
  const SyncProgress({
    required this.peerName,
    required this.transport,
    required this.phase,
    this.peerDeviceId,
    this.groupIds = const [],
    this.sentOps = 0,
    this.toSendOps = 0,
    this.receivedOps = 0,
    this.toReceiveOps = 0,
    this.bytesSent = 0,
    this.bytesReceived = 0,
    this.verificationCode,
  });

  final String peerName;
  final DeviceId? peerDeviceId;
  final TransportKind transport;
  final SyncPhase phase;
  final List<GroupId> groupIds; // shared groups in this session
  final int sentOps;
  final int toSendOps;
  final int receivedOps;
  final int toReceiveOps; // from the peer's OPS.total; 0 until known
  final int bytesSent;
  final int bytesReceived;

  /// 6 digits derived from the handshake transcript; identical on both
  /// phones ("Check that Priya's phone shows 482 913"). Null before auth.
  final String? verificationCode;
}

@immutable
final class SyncSummary {
  const SyncSummary({
    required this.peerName,
    required this.transport,
    required this.startedAt,
    required this.endedAt,
    required this.sentOps,
    required this.receivedOps,
    required this.receivedByGroup,
    required this.groupIds,
    this.peerDeviceId,
  });

  final String peerName;
  final DeviceId? peerDeviceId;
  final TransportKind transport;
  final DateTime startedAt;
  final DateTime endedAt;
  final int sentOps;
  final int receivedOps;
  final Map<GroupId, int> receivedByGroup;
  final List<GroupId> groupIds;
}

sealed class SessionStatus {
  const SessionStatus();
}

final class SessionIdle extends SessionStatus {
  const SessionIdle();
}

final class SessionActive extends SessionStatus {
  const SessionActive(this.progress);
  final SyncProgress progress;
}

final class SessionCompleted extends SessionStatus {
  const SessionCompleted(this.summary);
  final SyncSummary summary;
}

final class SessionFailed extends SessionStatus {
  const SessionFailed(this.failure, this.message, [this.partial]);
  final SyncFailure failure;
  final String message;
  final SyncSummary? partial;
}

/// "Visible" mode details for the host screen.
@immutable
final class HostInfo {
  const HostInfo({
    required this.connectLink,
    required this.addresses,
    required this.expiresAt,
    required this.transports,
    this.wifiName,
  });

  final String connectLink; // settleup://sync?... (SPEC 8.6), shown as QR
  final List<String> addresses; // 'ip:port' on every usable interface
  final DateTime expiresAt; // auto-stop (default 5 min)
  final Set<TransportKind> transports; // actually advertising
  final String? wifiName; // SSID if known (needs location on some APIs)
}

@immutable
final class SyncStatus {
  const SyncStatus({
    this.host,
    this.discovering = false,
    this.session = const SessionIdle(),
  });

  final HostInfo? host; // non-null while visible
  final bool discovering;
  final SessionStatus session;

  static const SyncStatus idle = SyncStatus();
}

/// A phone seen nearby, merged across transports by its advert id.
@immutable
final class NearbyPeer {
  const NearbyPeer({
    required this.key,
    required this.name,
    required this.transports,
    required this.sharedGroupIds,
    this.advertId,
    this.moreGroups = false,
  });

  /// Stable for the discovery run, also when the advert id rotates.
  final String key;
  final String name;

  /// The advert id seen most recently (SPEC 8.3), if any.
  final String? advertId;
  final Set<TransportKind> transports; // preferred: lan > nearby > ble
  final List<GroupId> sharedGroupIds; // from tokens; empty = unknown/none

  /// Its advert left some group tokens out (the phone is in more groups
  /// than an advert holds), so it may share a group that [sharedGroupIds]
  /// does not show. Sync may still be tried; the HELLO decides.
  final bool moreGroups;

  bool get sharesGroups => sharedGroupIds.isNotEmpty;

  /// Whether a Sync with this phone may find a shared group.
  bool get maySync => sharesGroups || moreGroups;
}

@immutable
final class JoinResult {
  const JoinResult({
    required this.groupId,
    required this.groupName,
    required this.alreadyMember,
    this.firstSync,
  });

  final GroupId groupId;
  final String groupName;
  final bool alreadyMember;
  final SyncSummary? firstSync; // when the invite carried a reachable host
}

abstract interface class SyncEngine {
  SyncStatus get status;
  Stream<SyncStatus> watchStatus(); // emits current first

  /// Emits the current list first; updated as peers appear/disappear
  /// (a peer not seen for 15 s is dropped).
  Stream<List<NearbyPeer>> watchNearby();

  Future<Map<TransportKind, TransportAvailability>> availability();
  Future<Map<TransportKind, TransportAvailability>> requestPermissions(
      Set<TransportKind> kinds);

  /// Starts the LAN server (+ mDNS) and Bluetooth advertising; accepts and
  /// runs inbound sessions automatically until stopped or expired.
  Future<HostInfo> startHosting({Duration duration = const Duration(minutes: 5)});
  Future<void> stopHosting();

  Future<void> startDiscovery({
    Set<TransportKind> kinds = const {TransportKind.lan, TransportKind.nearby, TransportKind.ble},
  });
  Future<void> stopDiscovery();

  /// Runs one full session (all shared groups) over the best transport.
  /// Throws [SyncException]. Status is updated throughout.
  Future<SyncSummary> syncWith(NearbyPeer peer);

  /// Accepts a scanned/pasted `settleup://sync?...` link (or a join link
  /// that carries a host). Throws [SyncException].
  Future<SyncSummary> syncWithLink(String link);

  /// Accepts a `settleup://join?...` invite: stores the group key, then
  /// syncs immediately if the invite has a reachable host. Throws
  /// [SyncException] (invalidCode) for bad links; a failed first sync is
  /// reported in the result (firstSync null), not thrown.
  Future<JoinResult> acceptInvite(String link);

  /// Builds the invite link for [groupId] (SPEC 8.6). With [includeHost],
  /// hosting is started (if not already) and its address is embedded.
  Future<String> inviteLinkFor(GroupId groupId, {bool includeHost = true});

  /// Cancels the running session (status -> SessionFailed(cancelled)).
  /// A Sync still connecting ends at once: the connect attempt under way
  /// is abandoned (its channel, if it opens later, is closed) and no other
  /// route is tried (QA SYNC-R4-01).
  Future<void> cancel();

  /// Keeps an authenticated session open and pushes new local ops while
  /// the Sync screen is visible. Off by default.
  set liveMode(bool enabled);

  Stream<List<SyncRecord>> watchHistory();

  Future<void> dispose();
}
