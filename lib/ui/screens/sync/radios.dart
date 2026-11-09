// Bluetooth and Nearby need runtime permissions (SPEC 8.10). The Sync flow
// asks for them before it looks for phones or becomes visible, and when a
// permission is permanently denied or a radio is off, says so with the way
// out: the app's settings page, or the Bluetooth / Wi-Fi settings.
import 'package:app_settings/app_settings.dart';
import 'package:flutter/material.dart';

import '../../../core/models.dart' show TransportKind;
import '../../../sync/sync_engine.dart';
import '../../../sync/transport/transport.dart';
import '../../strings.dart';
import '../../widgets/widgets.dart';

/// The transports that need a runtime permission.
const Set<TransportKind> kPermissionTransports = {
  TransportKind.nearby,
  TransportKind.ble,
};

/// Availability of every transport, after asking for the permissions that
/// can still be asked for. Shows the system dialog when needed; never
/// throws (an engine error reads as "unknown", i.e. an empty map).
Future<Map<TransportKind, TransportAvailability>> prepareRadios(
  SyncEngine engine,
) async {
  try {
    final now = await engine.availability();
    final ask = {
      for (final k in kPermissionTransports)
        if (now[k] == TransportAvailability.needsPermission) k,
    };
    if (ask.isEmpty) return now;
    final after = await engine.requestPermissions(ask);
    return {...now, ...after};
  } on Object catch (_) {
    return const {};
  }
}

/// What the Sync tab shows about the radios, most urgent first.
enum RadioIssue { permissionDenied, needsPermission, bluetoothOff, wifiOff }

List<RadioIssue> radioIssues(Map<TransportKind, TransportAvailability> a) {
  bool any(TransportAvailability v) =>
      kPermissionTransports.any((k) => a[k] == v);
  return [
    if (any(TransportAvailability.permissionPermanentlyDenied))
      RadioIssue.permissionDenied
    else if (any(TransportAvailability.needsPermission))
      RadioIssue.needsPermission,
    if (a[TransportKind.ble] == TransportAvailability.radioOff)
      RadioIssue.bluetoothOff,
    if (a[TransportKind.lan] == TransportAvailability.radioOff)
      RadioIssue.wifiOff,
  ];
}

/// One row per issue, each with its fix.
class RadioIssuesCard extends StatelessWidget {
  const RadioIssuesCard({
    super.key,
    required this.issues,
    required this.onAllow,
  });

  final List<RadioIssue> issues;

  /// Asks for the permissions again (the system dialog can still show).
  final VoidCallback onAllow;

  @override
  Widget build(BuildContext context) {
    if (issues.isEmpty) return const SizedBox.shrink();
    return ListSection(
      children: [
        for (final i in issues)
          KitListRow(
            title: switch (i) {
              RadioIssue.permissionDenied => S.radiosDeniedTitle,
              RadioIssue.needsPermission => S.radiosAskTitle,
              RadioIssue.bluetoothOff => S.bluetoothOffTitle,
              RadioIssue.wifiOff => S.wifiOffTitle,
            },
            subtitle: switch (i) {
              RadioIssue.permissionDenied => S.radiosDeniedBody,
              RadioIssue.needsPermission => S.radiosAskBody,
              RadioIssue.bluetoothOff => S.bluetoothOffBody,
              RadioIssue.wifiOff => S.wifiOffBody,
            },
            subtitleLines: 3,
            leading: Icon(switch (i) {
              RadioIssue.wifiOff => Icons.wifi_off_rounded,
              _ => Icons.bluetooth_disabled_rounded,
            }),
            keepTrailingBeside: true,
            trailing: FilledButton.tonal(
              style: KitButtonStyles.small(context),
              onPressed: switch (i) {
                RadioIssue.permissionDenied =>
                  () => AppSettings.openAppSettings(),
                RadioIssue.needsPermission => onAllow,
                RadioIssue.bluetoothOff => () => AppSettings.openAppSettings(
                  type: AppSettingsType.bluetooth,
                ),
                RadioIssue.wifiOff => () => AppSettings.openAppSettings(
                  type: AppSettingsType.wifi,
                ),
              },
              child: Text(switch (i) {
                RadioIssue.permissionDenied => S.openSettings,
                RadioIssue.needsPermission => S.allow,
                RadioIssue.bluetoothOff => S.turnOnBluetooth,
                RadioIssue.wifiOff => S.turnOnWifi,
              }),
            ),
          ),
      ],
    );
  }
}
