import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'kit_layout.dart';

/// The two-line row used inside [ListSection]s (render 1, 2, 5): 62 dp
/// minimum, 16 dp side padding, 14 dp gaps, a 16/22 semibold title and a
/// 13/18 secondary subline, both one line with ellipsis, and a trailing
/// block. No fixed height: at a large text scale the trailing block moves
/// under the text, still end-aligned, and the lines may wrap.
class KitListRow extends StatelessWidget {
  const KitListRow({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.onLongPress,
    this.minHeight = Sizes.rowMin,
    this.verticalPadding = 9,
    this.titleStyle,
    this.subtitleStyle,
    this.subtitleTrailing,
    this.keepTrailingBeside = false,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double minHeight;
  final double verticalPadding;
  final TextStyle? titleStyle;
  final TextStyle? subtitleStyle;

  /// Small widget after the subline (the "not yet shared" mark).
  final Widget? subtitleTrailing;

  /// Keep [trailing] beside the text at every text scale (buttons).
  final bool keepTrailingBeside;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final large = isLargeText(context);
    final stacked = large && trailing != null && !keepTrailingBeside;
    final maxLines = large ? 3 : 1;
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: titleStyle ?? theme.textTheme.titleMedium,
        ),
        if (subtitle != null)
          Row(
            children: [
              Flexible(
                child: Text(
                  subtitle!,
                  maxLines: maxLines,
                  overflow: TextOverflow.ellipsis,
                  style:
                      subtitleStyle ??
                      theme.textTheme.bodySmall!.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                ),
              ),
              if (subtitleTrailing != null) ...[
                const SizedBox(width: Space.sm),
                subtitleTrailing!,
              ],
            ],
          ),
        if (stacked) ...[
          const SizedBox(height: Space.xs),
          Align(alignment: AlignmentDirectional.centerEnd, child: trailing),
        ],
      ],
    );
    final row = ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: Space.rowInset,
          // A 48 dp trailing button brings its own vertical room.
          vertical: keepTrailingBeside ? verticalPadding - 2 : verticalPadding,
        ),
        child: Row(
          // Stacked rows are tall; keep the avatar or icon by the title.
          crossAxisAlignment: stacked
              ? CrossAxisAlignment.start
              : CrossAxisAlignment.center,
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 14)],
            Expanded(child: text),
            if (!stacked && trailing != null) ...[
              const SizedBox(width: Space.md),
              trailing!,
            ],
          ],
        ),
      ),
    );
    if (onTap == null && onLongPress == null) return row;
    return InkWell(onTap: onTap, onLongPress: onLongPress, child: row);
  }
}
