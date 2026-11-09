import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'level_vial.dart';

/// Empty state with static vial (DESIGN 5.7).
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.headline,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final String headline;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Space.x4,
            vertical: Space.x8,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // The brand device at rest: a short vial, bubble between the
              // marks, nothing animated.
              const SizedBox(
                width: Sizes.rowMin2 * 2,
                child: LevelVial(
                  position: 0,
                  height: 20,
                  showEndLabels: false,
                  animate: false,
                ),
              ),
              const SizedBox(height: Space.x6),
              Semantics(
                header: true,
                child: Text(
                  headline,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.headlineSmall,
                ),
              ),
              const SizedBox(height: Space.x2),
              Text(
                body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium!.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (actionLabel != null) ...[
                const SizedBox(height: Space.x6),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
