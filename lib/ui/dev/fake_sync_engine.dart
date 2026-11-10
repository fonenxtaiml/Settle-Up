// Scripted SyncEngine for development builds and widget tests (SPEC 10.2).
// No radios: hosting, discovery and sessions are simulated with short
// delays so every SyncStatus variant can be seen on screen.
import 'dart:async';
import 'dart:typed_data';

import '../../core/ids.dart';
import '../../core/models.dart';
import '../../data/repositories.dart';
import '../../sync/pairing/links.dart';
import '../../sync/sync_engine.dart';
import '../../sync/transport/transport.dart';
import 'fake_ledger.dart';

final class FakeSyncEngine implements SyncEngine {
  FakeSyncEngine({
    this.ledger,
    SettingsRepository? settings,
    DateTime Function()? now,
    this.step = const Duration(milliseconds: 450),
    List<NearbyPeer> peers = const [],
    List<SyncRecord> history = const [],
    this.hotspotName = 'AndroidAP_4B',
    this.hostAddress = '192.168.43.1:52741',
  }) : _repo = settings,
       _now = now ?? DateTime.now,
       peersToFind = List.of(peers),
       _history = List.of(history);

  final FakeLedgerRepository? ledger;
  final SettingsRepository? _repo;
  final DateTime Function() _now;

  /// Delay between simulated session phases.
  final Duration step;
  final String hotspotName;
  final String hostAddress;

  /// Phones "found" when discovery starts.
  final List<NearbyPeer> peersToFind;
  List<NearbyPeer> _nearby = const [];
  final List<SyncRecord> _history;
  SyncStatus _status = SyncStatus.idle;
  int _runs = 0;

  final _statusChanges = StreamController<SyncStatus>.broadcast();
  final _nearbyChanges = StreamController<List<NearbyPeer>>.broadcast();
  final _historyChanges = StreamController<List<SyncRecord>>.broadcast();

  /// Recorded calls, for tests.
  final List<String> calls = [];

  bool _liveMode = false;
  bool get liveModeEnabled => _liveMode;

  // ------------------------------------------------------- test helpers --

  /// Replaces the status (tests render every variant this way).
  void emitStatus(SyncStatus status) {
    _status = status;
    _statusChanges.add(status);
  }

  void emitNearby(List<NearbyPeer> peers) {
    _nearby = List.unmodifiable(peers);
    _nearbyChanges.add(_nearby);
  }

  void addHistory(SyncRecord record) {
    _history.insert(0, record);
    _historyChanges.add(List.unmodifiable(_history));
  }

  // ---------------------------------------------------------- contract --

  Stream<T> _current<T>(T Function() value, Stream<T> changes) async* {
    yield value();
    yield* changes;
  }

  @override
  SyncStatus get status => _status;

  @override
  Stream<SyncStatus> watchStatus() =>
      _current(() => _status, _statusChanges.stream);

  @override
  Stream<List<NearbyPeer>> watchNearby() =>
      _current(() => _nearby, _nearbyChanges.stream);

  @override
  Stream<List<SyncRecord>> watchHistory() =>
      _current(() => List.unmodifiable(_history), _historyChanges.stream);

  @override
  Future<Map<TransportKind, TransportAvailability>> availability() async => {
    for (final k in TransportKind.values) k: TransportAvailability.ready,
  };

  @override
  Future<Map<TransportKind, TransportAvailability>> requestPermissions(
    Set<TransportKind> kinds,
  ) async => {for (final k in kinds) k: TransportAvailability.ready};

  DeviceId get _deviceId =>
      _repo?.device.deviceId ?? '00000000-0000-7000-8000-00000000f00d';

  String get _deviceName => _repo?.device.deviceName ?? 'Pixel 8';

  @override
  Future<HostInfo> startHosting({
    Duration duration = const Duration(minutes: 5),
  }) async {
    calls.add('startHosting');
    final host = HostInfo(
      connectLink: ConnectLink(
        hosts: [hostAddress],
        deviceId: _deviceId,
        deviceName: _deviceName,
      ).encode(),
      addresses: [hostAddress],
      expiresAt: _now().add(duration),
      transports: const {TransportKind.lan, TransportKind.ble},
      wifiName: hotspotName,
    );
    emitStatus(
      SyncStatus(
        host: host,
        discovering: _status.discovering,
        session: _status.session,
      ),
    );
    return host;
  }

  @override
  Future<void> stopHosting() async {
    calls.add('stopHosting');
    emitStatus(
      SyncStatus(discovering: _status.discovering, session: _status.session),
    );
  }

  @override
  Future<void> startDiscovery({
    Set<TransportKind> kinds = const {
      TransportKind.lan,
      TransportKind.nearby,
      TransportKind.ble,
    },
  }) async {
    calls.add('startDiscovery');
    emitStatus(
      SyncStatus(
        host: _status.host,
        discovering: true,
        session: _status.session,
      ),
    );
    if (_nearby.isEmpty && peersToFind.isNotEmpty) emitNearby(peersToFind);
  }

  @override
  Future<void> stopDiscovery() async {
    calls.add('stopDiscovery');
    if (!_status.discovering) return;
    emitStatus(SyncStatus(host: _status.host, session: _status.session));
  }

  void _session(SessionStatus s) => emitStatus(
    SyncStatus(
      host: _status.host,
      discovering: _status.discovering,
      session: s,
    ),
  );

  Future<SyncSummary> _run({
    required String peerName,
    required TransportKind transport,
    required List<GroupId> groupIds,
    DeviceId? peerDeviceId,
  }) async {
    final run = ++_runs;
    final started = _now();
    final toSend = ledger?.current.totalUnshared ?? 0;
    const toReceive = 4;
    SyncProgress progress(SyncPhase phase, {int sent = 0, int received = 0}) =>
        SyncProgress(
          peerName: peerName,
          peerDeviceId: peerDeviceId,
          transport: transport,
          phase: phase,
          groupIds: groupIds,
          sentOps: sent,
          toSendOps: toSend,
          receivedOps: received,
          toReceiveOps: phase.index >= SyncPhase.transferring.index
              ? toReceive
              : 0,
          bytesSent: sent * 420,
          bytesReceived: received * 380,
          verificationCode: phase.index >= SyncPhase.comparing.index
              ? '482913'
              : null,
        );

    bool cancelled() => run != _runs || _status.session is SessionFailed;

    for (final phase in [
      SyncPhase.connecting,
      SyncPhase.handshaking,
      SyncPhase.comparing,
    ]) {
      _session(SessionActive(progress(phase)));
      await Future<void>.delayed(step);
      if (cancelled()) {
        throw const SyncException(SyncFailure.cancelled);
      }
    }
    final steps = toSend > toReceive ? toSend : toReceive;
    for (var i = 1; i <= steps; i++) {
      _session(
        SessionActive(
          progress(
            SyncPhase.transferring,
            sent: i > toSend ? toSend : i,
            received: i > toReceive ? toReceive : i,
          ),
        ),
      );
      await Future<void>.delayed(step ~/ 2);
      if (cancelled()) throw const SyncException(SyncFailure.cancelled);
    }
    _session(
      SessionActive(
        progress(SyncPhase.finishing, sent: toSend, received: toReceive),
      ),
    );
    await Future<void>.delayed(step ~/ 2);
    final summary = SyncSummary(
      peerName: peerName,
      peerDeviceId: peerDeviceId,
      transport: transport,
      startedAt: started,
      endedAt: _now(),
      sentOps: toSend,
      receivedOps: toReceive,
      receivedByGroup: {if (groupIds.isNotEmpty) groupIds.first: toReceive},
      groupIds: groupIds,
    );
    ledger?.markAllShared();
    addHistory(
      SyncRecord(
        id: 'sync-${_history.length + 1}',
        peerDeviceId: peerDeviceId,
        peerName: peerName,
        transport: transport,
        startedAt: summary.startedAt,
        endedAt: summary.endedAt,
        sentOps: summary.sentOps,
        receivedOps: summary.receivedOps,
        groupIds: groupIds,
        outcome: SyncOutcome.completed,
      ),
    );
    _session(SessionCompleted(summary));
    return summary;
  }

  Never _fail(SyncFailure failure, String message) {
    _session(SessionFailed(failure, message));
    throw SyncException(failure, message);
  }

  @override
  Future<SyncSummary> syncWith(NearbyPeer peer) async {
    calls.add('syncWith:${peer.name}');
    if (!peer.sharesGroups) {
      _fail(SyncFailure.noSharedGroups, 'no shared groups');
    }
    final transport = peer.transports.contains(TransportKind.lan)
        ? TransportKind.lan
        : peer.transports.contains(TransportKind.nearby)
        ? TransportKind.nearby
        : TransportKind.ble;
    return _run(
      peerName: peer.name,
      transport: transport,
      groupIds: peer.sharedGroupIds,
    );
  }

  @override
  Future<SyncSummary> syncWithLink(String link) async {
    calls.add('syncWithLink');
    final connect = ConnectLink.tryParse(link);
    if (connect != null) {
      return _run(
        peerName: connect.deviceName.isEmpty ? 'Phone' : connect.deviceName,
        peerDeviceId: connect.deviceId,
        transport: TransportKind.lan,
        groupIds: [
          ...?ledger?.current.state.visibleGroups.map((g) => g.groupId),
        ],
      );
    }
    final invite = InviteLink.tryParse(link);
    if (invite != null && invite.host != null) {
      return _run(
        peerName: invite.fromName.isEmpty ? 'Phone' : invite.fromName,
        peerDeviceId: invite.deviceId,
        transport: TransportKind.lan,
        groupIds: [invite.groupId],
      );
    }
    _fail(SyncFailure.invalidCode, 'not a sync link');
  }

  @override
  Future<JoinResult> acceptInvite(String link) async {
    calls.add('acceptInvite');
    final invite = InviteLink.tryParse(link);
    if (invite == null) {
      throw const SyncException(SyncFailure.invalidCode, 'bad invite');
    }
    final known = ledger?.current.state.groups[invite.groupId]?.group != null;
    if (!known && ledger != null) {
      await ledger!.createJoinedGroup(
        groupId: invite.groupId,
        name: invite.groupName,
        currency: invite.currency,
        inviterDevice: invite.deviceId ?? 'inviter-${invite.groupId}',
        inviterName: _ownerOf(invite.fromName),
        otherMembers: const [],
      );
    }
    return JoinResult(
      groupId: invite.groupId,
      groupName: invite.groupName,
      alreadyMember: known,
    );
  }

  /// "Priya's Pixel 8" -> "Priya".
  static String _ownerOf(String deviceName) {
    final i = deviceName.indexOf("'s ");
    final name = i > 0 ? deviceName.substring(0, i) : deviceName;
    return name.trim().isEmpty ? 'Friend' : name.trim();
  }

  @override
  Future<String> inviteLinkFor(
    GroupId groupId, {
    bool includeHost = true,
  }) async {
    calls.add('inviteLinkFor');
    final g = ledger?.current.state.groups[groupId]?.group;
    final host = includeHost ? (await startHosting()).addresses.first : null;
    return InviteLink(
      groupId: groupId,
      groupKey: Uint8List.fromList(
        List<int>.generate(32, (i) => (groupId.hashCode >> (i % 24)) & 0xff),
      ),
      groupName: g?.name ?? 'Group',
      currency: g?.currency ?? 'INR',
      fromName: _deviceName,
      host: host,
      deviceId: _deviceId,
    ).encode();
  }

  @override
  Future<void> cancel() async {
    calls.add('cancel');
    _runs++;
    _session(const SessionFailed(SyncFailure.cancelled, 'cancelled'));
  }

  @override
  set liveMode(bool enabled) => _liveMode = enabled;

  @override
  Future<void> dispose() async {
    await _statusChanges.close();
    await _nearbyChanges.close();
    await _historyChanges.close();
  }
}
