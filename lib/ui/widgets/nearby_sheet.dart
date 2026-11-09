// Pieces of the nearby-phones sheet (DESIGN 5.9). ui-screens composes them
// inside showModalBottomSheet(showDragHandle: true, isScrollControlled:
// true) with a DraggableScrollableSheet (initial 0.6, max 0.95).
import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import 'kit_strings.dart';
import 'person_avatar.dart';
import 'row_layout.dart';

/// "Phones nearby" title and the searching line.
class NearbySheetHeader extends StatelessWidget {
  const NearbySheetHeader({
    super.key,
    this.title = KitStrings.phonesNearby,
    this.status = KitStrings.searching,
    this.searching = true,
  });

  final String title;
  final String status;
  final bool searching;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.x6, 0, Space.x6, Space.x2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Semantics(
            header: true,
            child: Text(title, style: theme.textTheme.headlineSmall),
          ),
          const SizedBox(height: Space.x1),
          Row(
            children: [
              if (searching) ...[
                SizedBox.square(
                  dimension: 16,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    value: reduceMotion ? 0.7 : null,
                    backgroundColor: scheme.surfaceContainerHighest,
                  ),
                ),
                const SizedBox(width: Space.x2),
              ],
              Flexible(
                child: Text(
                  status,
                  style: theme.textTheme.bodyMedium!.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One phone in the sheet: avatar, phone name, "Wi-Fi, shares Goa trip",
/// and a tonal Sync (shared groups) or outlined Pair (unknown) button.
class NearbyPeerRow extends StatelessWidget {
  const NearbyPeerRow({
    super.key,
    required this.id,
    required this.name,
    required this.transports,
    required this.sharedGroupNames,
    this.onSync,
    this.onPair,
    this.ownerName,
    this.fadeIn = true,
  });

  /// Stable seed for the avatar tone (device id prefix or discovery key).
  final String id;
  final String name; // advertised phone name, '' if unknown
  final Set<TransportKind> transports;
  final List<String> sharedGroupNames;
  final VoidCallback? onSync;
  final VoidCallback? onPair;

  /// The owner's name for the avatar when known (a member of a shared
  /// group); otherwise the phone name's first word is used ("Priya's").
  final String? ownerName;

  /// A single 240 ms fade when the row first appears (no radar pulse).
  final bool fadeIn;

  bool get isKnown => sharedGroupNames.isNotEmpty;

  /// "Priya's Pixel 8" -> "Priya" (avatar initial only).
  static String ownerFromPhoneName(String phoneName) {
    final first = phoneName.trim().split(RegExp(r'\s+')).first;
    return first.replaceFirst(RegExp(r"['’]s$"), '');
  }

  /// The transport is always a word: Wi-Fi beats Bluetooth.
  static String transportWord(Set<TransportKind> transports) =>
      transports.contains(TransportKind.lan)
      ? KitStrings.wifi
      : KitStrings.bluetooth;

  /// "Goa trip", "Goa trip and Flat 4B", "Goa trip and 2 more".
  static String groupList(List<String> names) {
    if (names.isEmpty) return '';
    if (names.length == 1) return names.first;
    if (names.length == 2) return '${names[0]} and ${names[1]}';
    return '${names.first} and ${names.length - 1} more';
  }

  static String metaFor(Set<TransportKind> transports, List<String> groups) {
    final word = transportWord(transports);
    return groups.isEmpty
        ? '$word, ${KitStrings.noSharedGroups}'
        : '$word, ${KitStrings.shares(groupList(groups))}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final title = name.trim().isEmpty ? KitStrings.unknownPhone : name;
    final meta = metaFor(transports, sharedGroupNames);

    final leading = name.trim().isEmpty
        ? SizedBox.square(
            dimension: Sizes.avatarLg,
            child: DecoratedBox(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: scheme.surfaceContainerHigh,
              ),
              child: Icon(
                Icons.question_mark_rounded,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
            ),
          )
        : PersonAvatar(id: id, name: ownerName ?? ownerFromPhoneName(name));

    final button = isKnown
        ? FilledButton.tonal(
            onPressed: onSync,
            style: _compact,
            child: const Text(KitStrings.sync),
          )
        : OutlinedButton(
            onPressed: onPair,
            style: _compact,
            child: const Text(KitStrings.pair),
          );

    final row = MergeSemantics(
      child: KitRow(
        leading: ExcludeSemantics(child: leading),
        title: Text(
          title,
          style: theme.textTheme.titleMedium,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          meta,
          style: theme.textTheme.bodyMedium!.copyWith(
            color: scheme.onSurfaceVariant,
          ),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: button,
        horizontalPadding: Space.x6,
      ),
    );

    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (!fadeIn || reduceMotion) return row;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Motion.standard,
      curve: Motion.enter,
      builder: (context, t, child) => Opacity(opacity: t, child: child),
      child: row,
    );
  }

  static final ButtonStyle _compact = ButtonStyle(
    minimumSize: const WidgetStatePropertyAll(Size(72, 40)),
    padding: const WidgetStatePropertyAll(
      EdgeInsets.symmetric(horizontal: Space.x4),
    ),
    shape: WidgetStatePropertyAll(
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.input)),
    ),
  );
}

/// "Can't see them?" help block with the two QR fallbacks.
class NearbySheetFooter extends StatelessWidget {
  const NearbySheetFooter({super.key, this.onShowQr, this.onScanQr});

  final VoidCallback? onShowQr;
  final VoidCallback? onScanQr;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.x6, Space.x4, Space.x6, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(KitStrings.cantSeeThem, style: theme.textTheme.titleSmall),
              const SizedBox(height: Space.x1),
              Text(
                KitStrings.cantSeeThemBody,
                style: theme.textTheme.bodyMedium!.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(
            Space.x3,
            Space.x2,
            Space.x3,
            Space.x4,
          ),
          child: Wrap(
            spacing: Space.x2,
            children: [
              TextButton(
                onPressed: onShowQr,
                child: const Text(KitStrings.showMyQr),
              ),
              TextButton(
                onPressed: onScanQr,
                child: const Text(KitStrings.scanQr),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The 6-digit pairing / verification code (DESIGN 5.9, 6.8):
/// "Check that Priya's phone shows" over "482 913" in displaySmall tnum.
class PairingCode extends StatelessWidget {
  const PairingCode({super.key, required this.code, this.peerName});

  final String code;
  final String? peerName;

  /// "482913" -> "482 913"; other lengths are returned unchanged.
  static String grouped(String code) {
    final digits = code.replaceAll(RegExp(r'\s'), '');
    if (digits.length != 6) return code;
    return '${digits.substring(0, 3)} ${digits.substring(3)}';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shown = grouped(code);
    final name = peerName;
    final lead = name == null
        ? null
        : KitStrings.checkCode(name, '').trimRight();
    return Semantics(
      label: name == null
          ? shown.split('').join(' ')
          : KitStrings.checkCode(name, shown.split('').join(' ')),
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (lead != null)
            Text(
              lead,
              style: theme.textTheme.bodyLarge!.copyWith(
                color: scheme.onSurfaceVariant,
              ),
            ),
          Text(
            shown,
            style: MoneyStyles.keypad(context)
                .copyWith(color: scheme.onSurface, letterSpacing: 1.5),
          ),
        ],
      ),
    );
  }
}
