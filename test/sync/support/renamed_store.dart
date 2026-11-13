// A SyncStore that sends [name] as its device name, whatever Settings
// allows: a peer on another app version, or a forged one.
import 'dart:typed_data';

import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/repositories.dart';

final class RenamedStore implements SyncStore {
  RenamedStore(this.inner, this.name);

  final SyncStore inner;
  final String name;

  @override
  DeviceId get localDeviceId => inner.localDeviceId;
  @override
  String get localDeviceName => name;
  @override
  Stream<String> watchLocalDeviceName() => Stream.value(name);
  @override
  Future<Map<GroupId, Uint8List>> groupKeys() => inner.groupKeys();
  @override
  Future<VersionVector> versionVector(GroupId groupId) =>
      inner.versionVector(groupId);
  @override
  Future<List<Operation>> opsMissingFor(GroupId groupId, VersionVector peer) =>
      inner.opsMissingFor(groupId, peer);
  @override
  Future<List<Operation>> applyRemote(GroupId groupId, List<Operation> ops) =>
      inner.applyRemote(groupId, ops);
  @override
  Future<void> recordPeerKnowledge(
    DeviceId peer,
    GroupId groupId,
    VersionVector vv,
  ) => inner.recordPeerKnowledge(peer, groupId, vv);
  @override
  Stream<Operation> get localOps => inner.localOps;
  @override
  Future<bool> registerJoinedGroup(
    GroupId groupId,
    Uint8List key,
    String nameHint,
  ) => inner.registerJoinedGroup(groupId, key, nameHint);
  @override
  Future<void> addSyncRecord(SyncRecord record) => inner.addSyncRecord(record);
  @override
  Stream<List<SyncRecord>> watchSyncRecords() => inner.watchSyncRecords();
}
