// Shared builders for the data-layer tests.
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';

/// 2026-11-09T00:00:00Z
const int kBaseMs = 1794182400000;

const GroupId gA = '00000000-0000-7000-9000-00000000000a';
const GroupId gB = '00000000-0000-7000-9000-00000000000b';
const DeviceId dA = 'aaaaaaaa-0000-7000-8000-000000000001';
const DeviceId dB = 'bbbbbbbb-0000-7000-8000-000000000001';
const DeviceId dC = 'cccccccc-0000-7000-8000-000000000001';

/// A member-rename op; ids default to `{group}/{device}/{counter}`.
Operation rawOp(
  GroupId group,
  DeviceId device,
  int counter, {
  String? id,
  int? millis,
  int schemaVersion = kSchemaVersion,
}) =>
    Operation(
      id: id ?? '$group/$device/$counter',
      groupId: group,
      deviceId: device,
      counter: counter,
      hlc: Hlc(millis ?? kBaseMs + counter, 0, device),
      entityType: EntityType.member,
      entityId: 'm-$device',
      kind: OpKind.update,
      payload: {MemberFields.displayName: 'name $counter'},
      schemaVersion: schemaVersion,
    );

SyncRecord record(String id, int startedMs, {List<GroupId> groups = const []}) =>
    SyncRecord(
      id: id,
      peerDeviceId: dB,
      peerName: 'Pixel 8',
      transport: TransportKind.ble,
      startedAt: utcFromMillis(startedMs),
      endedAt: utcFromMillis(startedMs + 1500),
      sentOps: 3,
      receivedOps: 4,
      groupIds: groups,
      outcome: SyncOutcome.partial,
      error: 'dropped',
    );

/// A clock that only moves when told to.
final class FakeClock {
  FakeClock([this.now = kBaseMs]);
  int now;
  int call() => now;
  void advance([int ms = 1000]) => now += ms;
}
