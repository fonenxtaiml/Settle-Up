import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../format/dates.dart';
import 'beside_or_below.dart';
import 'button_semantics.dart';
import 'kit_layout.dart';
import 'kit_strings.dart';
import 'list_section.dart';

enum SyncChipState {
  neverSynced,
  allShared,
  changesWaiting,
  inProgress,
  failed,
}

String _title(SyncChipState state, int pending, String? peer) =>
    switch (state) {
      SyncChipState.neverSynced => KitStrings.onThisPhone,
      SyncChipState.allShared => KitStrings.allShared,
      SyncChipState.changesWaiting => KitStrings.changesToShare(pending),
      SyncChipState.inProgress =>
        peer == null ? KitStrings.syncing : KitStrings.syncingWith(peer),
      SyncChipState.failed => KitStrings.syncStopped,
    };

IconData _icon(SyncChipState state) => switch (state) {
  SyncChipState.neverSynced => Icons.smartphone_rounded,
  SyncChipState.allShared => Icons.check_rounded,
  SyncChipState.changesWaiting => Icons.sync_alt_rounded,
  SyncChipState.inProgress => Icons.sync_alt_rounded,
  SyncChipState.failed => Icons.error_outline_rounded,
};

class _Spinner extends StatelessWidget {
  const _Spinner({this.size = 16});

  final double size;

  @override
  Widget build(BuildContext context) =>
      SizedBox.square(dimension: size, child: const KitSpinner());
}

/// Compact sync state pill for app bars (stone fill, 36 dp). Never says
/// "offline": local-first states are normal.
class SyncStatusChip extends StatelessWidget {
  const SyncStatusChip({
    super.key,
    required this.state,
    this.pendingCount = 0,
    this.lastSyncedAt,
    this.peerName,
    this.onTap,
  });

  final SyncChipState state;
  final int pendingCount;
  final DateTime? lastSyncedAt;
  final String? peerName;
  final VoidCallback? onTap;

  String get label => state == SyncChipState.allShared
      ? (lastSyncedAt == null
            ? KitStrings.synced
            : KitStrings.syncedAgo(DateLabels.ago(lastSyncedAt!)))
      : _title(state, pendingCount, peerName);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final iconColor = state == SyncChipState.failed
        ? scheme.error
        : scheme.onSurface;
    final Widget pill = Material(
      color: scheme.surfaceContainer,
      shape: const StadiumBorder(),
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: Sizes.buttonSmall),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(10, 6, 14, 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (state == SyncChipState.inProgress)
                  const _Spinner()
                else
                  Icon(_icon(state), size: 18, color: iconColor),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall!.copyWith(fontSize: 14),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    return ButtonSemantics(
      alwaysButton: false,
      label: label,
      onTap: onTap,
      // A tappable 36 dp pill sits in a 48 dp tap target (VISUAL-R9-01).
      child: onTap == null
          ? pill
          : TapTargetPadding(
              padding: const EdgeInsets.symmetric(
                vertical: (Sizes.minTap - Sizes.buttonSmall) / 2,
              ),
              onTap: onTap,
              child: pill,
            ),
    );
  }
}

/// The sync strip on Home (render 1): a white card with the sync icon,
/// "3 changes to share", "Last synced with Priya's Pixel 8 yesterday" and
/// a tonal "Sync" button. The whole card opens Sync; the button starts it.
class SyncBanner extends StatelessWidget {
  const SyncBanner({
    super.key,
    required this.state,
    this.pendingCount = 0,
    this.lastSyncedAt,
    this.peerName,
    this.onTap,
    this.onSync,
    this.now,
  });

  final SyncChipState state;
  final int pendingCount;
  final DateTime? lastSyncedAt;

  /// Last or current peer: "Priya's Pixel 8".
  final String? peerName;
  final VoidCallback? onTap;
  final VoidCallback? onSync;

  /// Clock for "yesterday" style labels (tests).
  final DateTime? now;

  String get title => _title(state, pendingCount, peerName);

  String get subtitle {
    if (state == SyncChipState.failed) return KitStrings.syncStoppedBody;
    if (state == SyncChipState.inProgress && peerName != null) {
      return KitStrings.changesToShare(pendingCount);
    }
    if (lastSyncedAt == null) return KitStrings.neverSynced;
    final ago = DateLabels.ago(lastSyncedAt!, now: now);
    return peerName == null
        ? KitStrings.lastSynced(ago)
        : KitStrings.lastSyncedWith(peerName!, ago);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final large = isLargeText(context);
    final Widget? action = state == SyncChipState.inProgress
        ? const Padding(
            padding: EdgeInsets.symmetric(horizontal: Space.md),
            child: _Spinner(size: 20),
          )
        : onSync == null
        ? null
        : Semantics(
            // Its own button inside the card's.
            container: true,
            label: '${KitStrings.sync}, $title',
            button: true,
            onTap: onSync,
            excludeSemantics: true,
            child: FilledButton.tonal(
              onPressed: onSync,
              style: KitButtonStyles.small(context),
              child: const Text(KitStrings.sync),
            ),
          );
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(title, style: theme.textTheme.titleSmall),
        // The strip's status and a stopped sync's next step wrap in full
        // in every state (VISUAL-R31-02).
        Text(
          subtitle,
          style: theme.textTheme.bodySmall!.copyWith(
            color: scheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    final icon = state == SyncChipState.failed
        ? Icon(Icons.error_outline_rounded, color: scheme.error)
        : Icon(_icon(state), color: scheme.onSurface);
    return Material(
      color: scheme.surfaceContainerLowest,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.all(Radius.circular(Radii.lg)),
      ),
      clipBehavior: Clip.antiAlias,
      // One labelled button for the card ("5 changes to share, Not synced
      // with another phone yet") that opens Sync; the Sync action inside is
      // its own button.
      child: Semantics(
        container: true,
        button: onTap != null,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            // A 48 dp button already brings its own vertical room.
            padding: EdgeInsetsDirectional.fromSTEB(
              16,
              action == null || large ? 12 : 6.5,
              12,
              action == null || large ? 12 : 6.5,
            ),
            // The Sync button sits beside the text while the text keeps a
            // readable column, else under it (VISUAL-R32-02).
            child: BesideOrBelow(
              leading: ExcludeSemantics(child: icon),
              leadingGap: Space.md,
              main: text,
              trailing: action,
              gap: Space.md,
              spacing: 0,
              below: large,
              minMainWidth: kMinTextBeside,
              minMainFraction: 0.5,
            ),
          ),
        ),
      ),
    );
  }
}

/// "Looking" with a small spinner, for the Nearby phones heading.
class LookingIndicator extends StatelessWidget {
  const LookingIndicator({super.key, this.label = KitStrings.looking});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      label: label,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const _Spinner(size: 14),
          const SizedBox(width: 6),
          Text(
            label,
            style: theme.textTheme.labelMedium!.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
