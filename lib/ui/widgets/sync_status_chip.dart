import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../format/dates.dart';
import 'kit_strings.dart';

enum SyncChipState {
  neverSynced,
  allShared,
  changesWaiting,
  inProgress,
  failed,
}

/// App-bar sync chip (DESIGN 5.8). Never says "offline".
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

  /// The chip's sentence for [state] (DESIGN 5.8 table).
  String label({DateTime? now}) => switch (state) {
    SyncChipState.neverSynced => KitStrings.onThisPhone,
    SyncChipState.allShared =>
      lastSyncedAt == null
          ? KitStrings.synced
          : KitStrings.syncedAgo(DateLabels.ago(lastSyncedAt!, now: now)),
    SyncChipState.changesWaiting => KitStrings.changesToShare(
      pendingCount < 1 ? 1 : pendingCount,
    ),
    SyncChipState.inProgress =>
      (peerName == null || peerName!.isEmpty)
          ? KitStrings.syncing
          : KitStrings.syncingWith(peerName!),
    SyncChipState.failed => KitStrings.syncStopped,
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final money = context.money;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;

    final Widget icon = switch (state) {
      SyncChipState.neverSynced => Icon(
        Icons.smartphone_rounded,
        size: 18,
        color: scheme.onSurfaceVariant,
      ),
      SyncChipState.allShared => Icon(
        Icons.check_circle_rounded,
        size: 18,
        color: money.owed,
      ),
      SyncChipState.changesWaiting => Icon(
        Icons.upload_rounded,
        size: 18,
        color: scheme.tertiary,
      ),
      SyncChipState.inProgress => SizedBox.square(
        dimension: 18,
        child: Padding(
          padding: const EdgeInsets.all(1),
          child: CircularProgressIndicator(
            strokeWidth: 2,
            value: reduceMotion ? 0.7 : null,
            color: scheme.primary,
            backgroundColor: scheme.surfaceContainerHighest,
          ),
        ),
      ),
      SyncChipState.failed => Icon(
        Icons.error_rounded,
        size: 18,
        color: scheme.error,
      ),
    };

    final text = label();
    return Semantics(
      button: onTap != null,
      label: text,
      excludeSemantics: true,
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Center(
          widthFactor: 1,
          child: Material(
            color: scheme.surfaceContainerHigh,
            shape: const StadiumBorder(),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsetsDirectional.fromSTEB(
                  Space.x2 + 2,
                  Space.x2 - 2,
                  Space.x3,
                  Space.x2 - 2,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    icon,
                    const SizedBox(width: Space.x2 - 2),
                    Flexible(
                      child: Text(
                        text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.labelMedium!.copyWith(
                          color: scheme.onSurface,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
