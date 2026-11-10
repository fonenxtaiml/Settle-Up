// Runtime permissions per transport (SPEC 8.10), on top of
// permission_handler. Used by LanTransport (WP-D1) and the Bluetooth
// transports (WP-D2).
//
// Android (API level -> permissions):
//   lan:    none (targetSdk 36).
//   nearby: API >= 31 bluetoothScan, bluetoothAdvertise, bluetoothConnect;
//           API >= 33 also nearbyWifiDevices; API <= 32 locationWhenInUse.
//   ble:    API >= 31 bluetoothScan, bluetoothAdvertise, bluetoothConnect;
//           API <= 30 locationWhenInUse.
// iOS:
//   ble -> bluetooth; nearby -> unsupported; lan -> no runtime API (the
//   system asks on the first local-network access).
// Radio state: Bluetooth from CentralManager().state (ble, nearby), Wi-Fi
// from "is there a usable IPv4 interface" (lan), and the location service
// switch where location permission is needed for scanning (API <= 32).
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../core/models.dart';
import '../transport/lan/lan_network.dart';
import '../transport/transport.dart';

void _log(String message, [Object? error, StackTrace? st]) => developer.log(
      message,
      name: 'settle_up.sync.permissions',
      error: error,
      stackTrace: st,
    );

/// Which OS the wrapper runs on.
enum PermissionOs { android, ios, other }

/// Bluetooth adapter state, as far as the wrapper cares.
enum RadioState { on, off, unsupported, unknown }

/// Everything the wrapper asks of the platform, so the per-API-level rules
/// are unit tested without plugins.
abstract interface class PermissionPlatform {
  PermissionOs get os;

  /// Android API level (0 elsewhere).
  Future<int> androidSdkInt();

  Future<PermissionStatus> status(Permission permission);

  /// Shows the system dialog(s) for [permissions].
  Future<Map<Permission, PermissionStatus>> request(List<Permission> permissions);

  /// Whether the location service switch is on (Android, API <= 32 scans).
  Future<bool> locationServiceOn();

  Future<RadioState> bluetooth();

  /// Whether a usable IPv4 interface exists (Wi-Fi on or hotspot hosted).
  Future<bool> hasLanInterface();
}

/// Result of a check, with why (for logs and the QA checklist).
final class PermissionCheck {
  const PermissionCheck(this.availability, this.permissions);

  final TransportAvailability availability;

  /// The runtime permissions [availability] was decided on.
  final List<Permission> permissions;
}

class NearbyPermissions {
  NearbyPermissions({PermissionPlatform? platform})
      : _platform = platform ?? SystemPermissionPlatform();

  final PermissionPlatform _platform;

  /// Permissions a request() reported permanently denied. On Android a
  /// status check cannot tell permanently denied from denied (only a
  /// request can), so check() keeps reporting what the last request said
  /// until the permission is granted or a later request says otherwise.
  final Set<Permission> _permanentlyDenied = {};

  /// The runtime permissions [kind] needs on this phone, in request order.
  /// Empty when none are needed. Null when the platform cannot do [kind].
  Future<List<Permission>?> requiredFor(TransportKind kind) async {
    switch (_platform.os) {
      case PermissionOs.android:
        final sdk = await _platform.androidSdkInt();
        return switch (kind) {
          TransportKind.lan => const [],
          TransportKind.nearby => [
              if (sdk >= 31) ...const [
                Permission.bluetoothScan,
                Permission.bluetoothAdvertise,
                Permission.bluetoothConnect,
              ],
              if (sdk >= 33) Permission.nearbyWifiDevices,
              if (sdk <= 32) Permission.locationWhenInUse,
            ],
          TransportKind.ble => [
              if (sdk >= 31) ...const [
                Permission.bluetoothScan,
                Permission.bluetoothAdvertise,
                Permission.bluetoothConnect,
              ],
              if (sdk <= 30) Permission.locationWhenInUse,
            ],
        };
      case PermissionOs.ios:
        return switch (kind) {
          TransportKind.lan => const [],
          TransportKind.nearby => null,
          TransportKind.ble => const [Permission.bluetooth],
        };
      case PermissionOs.other:
        return kind == TransportKind.lan ? const [] : null;
    }
  }

  /// Availability of [kind] without showing any dialog.
  Future<TransportAvailability> check(TransportKind kind) async =>
      (await _evaluate(kind, request: false)).availability;

  /// Shows the system dialog(s) for what [kind] still needs, then returns
  /// the availability.
  Future<TransportAvailability> request(TransportKind kind) async =>
      (await _evaluate(kind, request: true)).availability;

  /// [check] with the permissions it looked at.
  Future<PermissionCheck> explain(TransportKind kind) =>
      _evaluate(kind, request: false);

  Future<PermissionCheck> _evaluate(
    TransportKind kind, {
    required bool request,
  }) async {
    final List<Permission>? needed;
    try {
      needed = await requiredFor(kind);
    } catch (e, st) {
      _log('requiredFor(${kind.name}) failed', e, st);
      return const PermissionCheck(TransportAvailability.unsupported, []);
    }
    if (needed == null) {
      return const PermissionCheck(TransportAvailability.unsupported, []);
    }

    // Radio first: no dialog makes sense while Bluetooth is unsupported.
    if (kind != TransportKind.lan) {
      final radio = await _bluetooth();
      if (radio == RadioState.unsupported) {
        return PermissionCheck(TransportAvailability.unsupported, needed);
      }
    }

    var statuses = <Permission, PermissionStatus>{};
    if (needed.isNotEmpty) {
      statuses = await _statuses(needed);
      final missing = [
        for (final p in needed)
          if (!_granted(statuses[p])) p,
      ];
      if (request && missing.any((p) => !_permanent(statuses[p]))) {
        try {
          final asked = await _platform.request(missing);
          statuses.addAll(asked);
          asked.forEach((p, s) {
            if (_permanent(s)) {
              _permanentlyDenied.add(p);
            } else {
              _permanentlyDenied.remove(p);
            }
          });
        } catch (e, st) {
          _log('request(${kind.name}) failed', e, st);
        }
      }
      final denied = await _deniedAvailability(needed, statuses);
      if (denied != null) return PermissionCheck(denied, needed);
    }

    return PermissionCheck(await _radioState(kind, needed), needed);
  }

  Future<Map<Permission, PermissionStatus>> _statuses(
    List<Permission> permissions,
  ) async {
    final out = <Permission, PermissionStatus>{};
    for (final p in permissions) {
      try {
        out[p] = await _platform.status(p);
      } catch (e, st) {
        _log('status($p) failed', e, st);
        out[p] = PermissionStatus.denied;
      }
      if (_granted(out[p])) {
        _permanentlyDenied.remove(p);
      } else if (out[p] == PermissionStatus.denied &&
          _permanentlyDenied.contains(p)) {
        out[p] = PermissionStatus.permanentlyDenied;
      }
    }
    return out;
  }

  Future<TransportAvailability?> _deniedAvailability(
    List<Permission> needed,
    Map<Permission, PermissionStatus> statuses,
  ) async {
    TransportAvailability? worst;
    for (final p in needed) {
      final s = statuses[p];
      if (_granted(s)) continue;
      if (_permanent(s)) return TransportAvailability.permissionPermanentlyDenied;
      worst = TransportAvailability.needsPermission;
    }
    return worst;
  }

  /// ready, or why the radios stop [kind]: Bluetooth or Wi-Fi off
  /// (radioOff), or Bluetooth on but the location switch off where scans
  /// need it (locationOff, a different fix).
  Future<TransportAvailability> _radioState(
    TransportKind kind,
    List<Permission> needed,
  ) async {
    switch (kind) {
      case TransportKind.lan:
        try {
          return await _platform.hasLanInterface()
              ? TransportAvailability.ready
              : TransportAvailability.radioOff;
        } catch (e, st) {
          _log('hasLanInterface failed', e, st);
          return TransportAvailability.ready;
        }
      case TransportKind.nearby:
      case TransportKind.ble:
        if (await _bluetooth() == RadioState.off) {
          return TransportAvailability.radioOff;
        }
        if (needed.contains(Permission.locationWhenInUse)) {
          try {
            // Scanning on old APIs returns nothing with location off.
            if (!await _platform.locationServiceOn()) {
              return TransportAvailability.locationOff;
            }
          } catch (e, st) {
            _log('locationServiceOn failed', e, st);
          }
        }
        return TransportAvailability.ready;
    }
  }

  Future<RadioState> _bluetooth() async {
    try {
      return await _platform.bluetooth();
    } catch (e, st) {
      _log('bluetooth state failed', e, st);
      return RadioState.unknown;
    }
  }

  static bool _granted(PermissionStatus? s) =>
      s == PermissionStatus.granted ||
      s == PermissionStatus.limited ||
      s == PermissionStatus.provisional;

  static bool _permanent(PermissionStatus? s) =>
      s == PermissionStatus.permanentlyDenied ||
      s == PermissionStatus.restricted;
}

/// The real platform: permission_handler, device_info_plus,
/// bluetooth_low_energy and dart:io.
final class SystemPermissionPlatform implements PermissionPlatform {
  SystemPermissionPlatform({LanNetwork? network})
      : _network = network ?? SystemLanNetwork();

  final LanNetwork _network;
  int? _sdk;

  @override
  PermissionOs get os => Platform.isAndroid
      ? PermissionOs.android
      : Platform.isIOS
          ? PermissionOs.ios
          : PermissionOs.other;

  @override
  Future<int> androidSdkInt() async {
    if (os != PermissionOs.android) return 0;
    return _sdk ??= (await DeviceInfoPlugin().androidInfo).version.sdkInt;
  }

  @override
  Future<PermissionStatus> status(Permission permission) => permission.status;

  @override
  Future<Map<Permission, PermissionStatus>> request(
    List<Permission> permissions,
  ) =>
      permissions.request();

  @override
  Future<bool> locationServiceOn() async =>
      await Permission.locationWhenInUse.serviceStatus == ServiceStatus.enabled;

  @override
  Future<RadioState> bluetooth() async {
    if (os == PermissionOs.other) return RadioState.unsupported;
    final manager = CentralManager();
    var state = manager.state;
    if (state == BluetoothLowEnergyState.unknown) {
      // The first state arrives asynchronously after the manager starts.
      try {
        state = (await manager.stateChanged
                .firstWhere((e) => e.state != BluetoothLowEnergyState.unknown)
                .timeout(const Duration(seconds: 1)))
            .state;
      } on TimeoutException {
        state = manager.state;
      }
    }
    return switch (state) {
      BluetoothLowEnergyState.poweredOn => RadioState.on,
      BluetoothLowEnergyState.poweredOff => RadioState.off,
      BluetoothLowEnergyState.unsupported => RadioState.unsupported,
      // unauthorized: permissions decide; unknown: do not block on it.
      BluetoothLowEnergyState.unauthorized ||
      BluetoothLowEnergyState.unknown =>
        RadioState.unknown,
    };
  }

  @override
  Future<bool> hasLanInterface() async =>
      (await _network.ipv4Addresses()).isNotEmpty;
}
