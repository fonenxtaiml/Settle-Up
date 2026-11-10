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
    this.subtitleLines = 1,
    this.stackTrailing = false,
    this.trailingWidth,
    this.leadingWidth = 0,
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

  /// Lines the subline may take below the large-text threshold (it always
  /// may wrap to three at large text). Rows whose subline carries an amount
  /// ("Sam paid ¥5,000") take two, so the amount is never cut off.
  final int subtitleLines;

  /// Put [trailing] under the text, end-aligned, below the large-text
  /// threshold too: rows that measured that their text has no room beside
  /// it ([ExpenseRow] on a small phone at 1.3x) stack early.
  final bool stackTrailing;

  /// The natural width of [trailing], when the row should measure it: the
  /// row then stacks [trailing] under the text below the large-text
  /// threshold too, whenever the title or subline would get less room than
  /// its longest word beside it (VISUAL-R4-04, VISUAL-R4-05). [leadingWidth]
  /// is the width of [leading].
  final double? trailingWidth;
  final double leadingWidth;

  @override
  Widget build(BuildContext context) {
    final w = trailingWidth;
    if (w == null ||
        trailing == null ||
        keepTrailingBeside ||
        stackTrailing ||
        isLargeText(context)) {
      return _build(context, stackTrailing);
    }
    final theme = Theme.of(context);
    final titleStyle = this.titleStyle ?? theme.textTheme.titleMedium;
    final subtitleStyle = this.subtitleStyle ?? theme.textTheme.bodySmall;
    return LayoutBuilder(
      builder: (context, c) {
        final room =
            c.maxWidth -
            Space.rowInset * 2 -
            (leading != null ? leadingWidth + 14 : 0) -
            Space.md -
            w -
            (subtitleTrailing != null ? Space.sm + 8 : 0);
        final needs = [
          longestWordWidth(context, title, titleStyle),
          if (subtitle != null)
            longestWordWidth(context, subtitle!, subtitleStyle),
        ].fold(0.0, (a, b) => a > b ? a : b);
        return _build(context, room + 0.5 < needs);
      },
    );
  }

  Widget _build(BuildContext context, bool stack) {
    final theme = Theme.of(context);
    final large = isLargeText(context);
    final stacked = (large || stack) && trailing != null && !keepTrailingBeside;
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
                  maxLines: large ? maxLines : subtitleLines,
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
