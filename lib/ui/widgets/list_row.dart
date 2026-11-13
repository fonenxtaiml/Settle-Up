import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import 'beside_or_below.dart';
import 'kit_layout.dart';

/// The row used inside [ListSection]s (render 1, 2, 5): 62 dp minimum,
/// 16 dp side padding, 14 dp gaps, a 16/22 semibold title, a 13/18
/// secondary subline and a trailing block. No fixed height.
///
/// Text: the app's own words (a setting, a notice, a help line, an empty
/// state, "Not on Settle Up yet") always wrap in full and are never cut
/// with an ellipsis (VISUAL-R31-02, VISUAL-R32-01). Only list entries
/// whose line is the user's data (a name, an expense, a phone) cap it, with
/// [titleLines] or [subtitleLines], and show it in full one tap away.
///
/// Trailing: beside the text while the text keeps room for its widest
/// word (and, when the text wraps in full, [kMinTextBeside] and half the
/// row), else under it, end-aligned ([BesideOrBelow], VISUAL-R32-02); at
/// a large text scale always under it unless [keepTrailingBeside].
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
    this.titleLines,
    this.subtitleLines,
    this.stackTrailing = false,
    this.trailingWidth,
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

  /// Keep [trailing] beside the text at a large text scale too (buttons),
  /// still only while the text keeps room for its widest word.
  final bool keepTrailingBeside;

  /// The most lines the title takes below the large-text threshold (three
  /// at large text), ending in an ellipsis; null, the default, wraps it in
  /// full. Set only for a title that is the user's data (a name), never
  /// for the app's own words.
  final int? titleLines;

  /// As [titleLines], for the subline. Rows whose subline carries an
  /// amount ("Sam paid ¥5,000") take two, so the amount is never cut off.
  final int? subtitleLines;

  /// Put [trailing] under the text, end-aligned, below the large-text
  /// threshold too: rows that measured that their text has no room beside
  /// it ([ExpenseRow] on a small phone at 1.3x) stack early.
  final bool stackTrailing;

  /// The natural width of [trailing] as its owner measured it (an amount
  /// that scales down once stacked), used instead of its intrinsic width
  /// when the row decides whether it fits beside the text (VISUAL-R4-04,
  /// VISUAL-R4-05).
  final double? trailingWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final large = isLargeText(context);
    int? cap(int? lines) =>
        lines == null ? null : (large ? math.max(lines, 3) : lines);
    final titleCap = cap(titleLines);
    final subtitleCap = cap(subtitleLines);
    final wraps = titleCap == null || (subtitle != null && subtitleCap == null);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          maxLines: titleCap,
          overflow: titleCap == null ? null : TextOverflow.ellipsis,
          style: titleStyle ?? theme.textTheme.titleMedium,
        ),
        if (subtitle != null)
          Row(
            children: [
              Flexible(
                // An amount in the subline ("Sam paid KD99,999,999.999")
                // is never split across lines: when a word is wider than
                // the line, the subline is set smaller (VISUAL-R34-01).
                child: FitWordsText(
                  subtitle!,
                  maxLines: subtitleCap,
                  overflow: subtitleCap == null ? null : TextOverflow.ellipsis,
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
        child: BesideOrBelow(
          leading: leading,
          main: text,
          trailing: trailing,
          gap: Space.md,
          spacing: Space.xs,
          below: stackTrailing || (large && !keepTrailingBeside),
          // Text that wraps in full keeps a readable column beside the
          // trailing block, else the block goes under it (VISUAL-R32-02).
          minMainWidth: wraps ? kMinTextBeside : 0,
          minMainFraction: wraps ? 0.5 : 0,
          trailingWidth: trailingWidth,
        ),
      ),
    );
    if (onTap == null && onLongPress == null) return row;
    return InkWell(onTap: onTap, onLongPress: onLongPress, child: row);
  }
}
