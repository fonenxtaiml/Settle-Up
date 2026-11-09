// A scripted permission platform for the Bluetooth transports: the real
// NearbyPermissions wrapper (SPEC 8.10) on top of it, so availability is
// decided by the same rules as on a phone.
import 'package:permission_handler/permission_handler.dart';
import 'package:settle_up/sync/platform/permissions.dart';

final class FakePermissionPlatform implements PermissionPlatform {
  FakePermissionPlatform({
    this.os = PermissionOs.android,
    this.sdk = 34,
    bool granted = true,
  }) : _grantAll = granted;

  @override
  final PermissionOs os;
  final int sdk;
  final bool _grantAll;
  final Map<Permission, PermissionStatus> statuses = {};
  RadioState radio = RadioState.on;
  int requests = 0;

  @override
  Future<int> androidSdkInt() async => os == PermissionOs.android ? sdk : 0;

  @override
  Future<PermissionStatus> status(Permission p) async =>
      statuses[p] ??
      (_grantAll ? PermissionStatus.granted : PermissionStatus.denied);

  @override
  Future<Map<Permission, PermissionStatus>> request(
    List<Permission> permissions,
  ) async {
    requests++;
    for (final p in permissions) {
      statuses[p] = PermissionStatus.granted;
    }
    return {for (final p in permissions) p: PermissionStatus.granted};
  }

  @override
  Future<RadioState> bluetooth() async => radio;

  @override
  Future<bool> locationServiceOn() async => true;

  @override
  Future<bool> hasLanInterface() async => true;
}

/// Permissions that report every Bluetooth transport ready.
NearbyPermissions grantedPermissions({
  PermissionOs os = PermissionOs.android,
}) =>
    NearbyPermissions(platform: FakePermissionPlatform(os: os));
