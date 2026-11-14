import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import 'button_semantics.dart';
import 'kit_layout.dart';
import 'kit_strings.dart';
import 'list_row.dart';
import 'list_section.dart';

enum NearbyPhoneKind { android, iphone, unknown }

enum NearbyPhoneAction {
  /// Shares a group: tonal "Sync".
  sync,

  /// Unknown phone: outlined "Pair".
  pair,

  /// A session with this phone is running: spinner.
  busy,

  /// No action (for example while another session runs).
  none,
}

/// A phone found nearby (render 5): a phone icon in ink, the phone's name,
/// "Wi-Fi, shares Goa trip" and a Sync or Pair button.
class NearbyPhoneRow extends StatelessWidget {
  const NearbyPhoneRow({
    super.key,
    required this.name,
    required this.subtitle,
    this.kind = NearbyPhoneKind.android,
    this.action = NearbyPhoneAction.sync,
    this.onAction,
  });

  final String name; // "Priya's Pixel 8"
  final String subtitle; // "Wi-Fi, shares Goa trip"
  final NearbyPhoneKind kind;
  final NearbyPhoneAction action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final icon = switch (kind) {
      NearbyPhoneKind.android => Icons.smartphone_rounded,
      NearbyPhoneKind.iphone => Icons.phone_iphone_rounded,
      NearbyPhoneKind.unknown => Icons.device_unknown_rounded,
    };
    final Widget? trailing = switch (action) {
      NearbyPhoneAction.sync => ButtonSemantics(
        label: KitStrings.syncWith(name),
        onTap: onAction,
        child: FilledButton.tonal(
          onPressed: onAction,
          style: KitButtonStyles.small(context),
          child: const Text(KitStrings.sync),
        ),
      ),
      NearbyPhoneAction.pair => ButtonSemantics(
        label: KitStrings.pairWith(name),
        onTap: onAction,
        child: OutlinedButton(
          onPressed: onAction,
          style: KitButtonStyles.small(context),
          child: const Text(KitStrings.pair),
        ),
      ),
      NearbyPhoneAction.busy => const Padding(
        padding: EdgeInsets.symmetric(horizontal: Space.md),
        child: SizedBox.square(dimension: 20, child: KitSpinner()),
      ),
      NearbyPhoneAction.none => null,
    };
    return MergeSemantics(
      child: KitListRow(
        // The phone's name wraps in full: the row opens nothing, and Pair
        // (a phone that shares no group) only explains how to join, so a
        // cut name would read in full nowhere, and two phones of one owner
        // that differ only at the end would look the same (VISUAL-R36-01).
        // The status line is the app's words ("Wi-Fi, may share a group",
        // "and 2 more") around at most one group name: it wraps in full
        // too (VISUAL-R31-02).
        title: name,
        subtitle: subtitle,
        leading: ExcludeSemantics(
          child: SizedBox(
            width: 24,
            child: Icon(icon, color: scheme.onSurface),
          ),
        ),
        trailing: trailing,
        keepTrailingBeside: true,
      ),
    );
  }
}

/// "Make this phone visible" (render 5): a white card with a hotspot icon,
/// the title, the time left and a switch. When visible it shows the QR
/// code (always dark on white so scanners read it in dark mode too) and
/// the address and hotspot to connect to by hand.
class HostQrCard extends StatelessWidget {
  const HostQrCard({
    super.key,
    required this.visible,
    required this.onVisibleChanged,
    required this.subtitle,
    this.qrData,
    this.address,
    this.hotspotName,
    this.title = KitStrings.makeVisible,
    this.caption = KitStrings.friendsScan,
  });

  final bool visible;
  final ValueChanged<bool>? onVisibleChanged;

  /// "On your hotspot, for 4:58 more".
  final String subtitle;
  final String? qrData;
  final String? address; // "192.168.43.1:7420"
  final String? hotspotName; // "AndroidAP_4B"
  final String title;
  final String caption;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final large = isLargeText(context);
    final infoStyle = theme.textTheme.bodySmall!.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final valueStyle = theme.textTheme.titleSmall!.tabular;

    final head = MergeSemantics(
      child: Padding(
        padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 12, 12),
        child: Row(
          children: [
            ExcludeSemantics(
              child: Icon(
                Icons.wifi_tethering_rounded,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: theme.textTheme.titleMedium),
                  Text(subtitle, style: infoStyle),
                ],
              ),
            ),
            const SizedBox(width: Space.sm),
            Switch(value: visible, onChanged: onVisibleChanged),
          ],
        ),
      ),
    );

    Widget info(String label, String value) => Semantics(
      container: true,
      label: '$label $value',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: infoStyle),
          Text(value, style: valueStyle),
        ],
      ),
    );

    final qr = qrData == null
        ? null
        : Container(
            width: Sizes.qr,
            height: Sizes.qr,
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: const Color(0xFFFFFFFF),
              borderRadius: BorderRadius.circular(Radii.md),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: QrImageView(
              data: qrData!,
              padding: EdgeInsets.zero,
              backgroundColor: const Color(0xFFFFFFFF),
              semanticsLabel: KitStrings.qrLabel,
              eyeStyle: const QrEyeStyle(
                eyeShape: QrEyeShape.square,
                color: Palette.ink,
              ),
              dataModuleStyle: const QrDataModuleStyle(
                dataModuleShape: QrDataModuleShape.square,
                color: Palette.ink,
              ),
            ),
          );

    final details = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(caption, style: infoStyle),
        if (address != null) ...[
          const SizedBox(height: 10),
          info(KitStrings.orConnectTo, address!),
        ],
        if (hotspotName != null) ...[
          const SizedBox(height: 10),
          info(KitStrings.hotspot, hotspotName!),
        ],
      ],
    );

    return Material(
      color: scheme.surfaceContainerLowest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Radii.lg)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          head,
          if (visible)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: large || qr == null
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        ?qr,
                        if (qr != null) const SizedBox(height: Space.md),
                        details,
                      ],
                    )
                  : Row(
                      children: [
                        qr,
                        const SizedBox(width: Space.lg),
                        Expanded(child: details),
                      ],
                    ),
            ),
        ],
      ),
    );
  }
}
