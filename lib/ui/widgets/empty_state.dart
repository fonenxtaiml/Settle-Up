import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'tether.dart';

/// Empty state: a slack tether (two rings, nothing owed, nothing moving),
/// a headline, one sentence and at most one primary action. Centred, at
/// most 320 dp wide. No illustration beyond the brand device.
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
            horizontal: Space.gutter,
            vertical: Space.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(
                child: CustomPaint(
                  size: const Size(112, 24),
                  painter: TetherPainter(
                    from: TetherPoint.ring,
                    to: TetherPoint.ring,
                    line: TetherLine.slack,
                    color: scheme.outline,
                    strokeWidth: 2,
                    pointRadius: 9,
                  ),
                ),
              ),
              const SizedBox(height: Space.xl),
              Semantics(
                header: true,
                child: Text(
                  headline,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleLarge,
                ),
              ),
              const SizedBox(height: Space.sm),
              Text(
                body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium!.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
              if (actionLabel != null) ...[
                const SizedBox(height: Space.xl),
                FilledButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
