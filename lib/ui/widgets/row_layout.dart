import 'package:flutter/material.dart';

import '../../theme/tokens.dart';

/// Text scale at which rows stack the amount under the title (DESIGN 3.4).
const double kStackedRowScale = 1.6;

bool isStackedRow(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(1) >= kStackedRowScale;

/// Shared skeleton of the flat list rows (DESIGN 4.2, 5.2, 5.3): 16 dp
/// gutters, 12 dp vertical padding, 40 dp leading, 16 dp gap, a
/// right-aligned trailing column, and no fixed height. At a large text
/// scale the trailing column moves under the text, still right-aligned.
class KitRow extends StatelessWidget {
  const KitRow({
    super.key,
    required this.leading,
    required this.title,
    required this.subtitle,
    this.trailing,
    this.minHeight = Sizes.rowMin2,
    this.crossAxisAlignment = CrossAxisAlignment.center,
    this.horizontalPadding = Space.x4,
  });

  final Widget leading;
  final Widget title;
  final Widget subtitle;
  final Widget? trailing;
  final double minHeight;
  final CrossAxisAlignment crossAxisAlignment;

  /// 16 dp in screen lists; 24 dp inside sheets (DESIGN 4.2).
  final double horizontalPadding;

  @override
  Widget build(BuildContext context) {
    final stacked = isStackedRow(context);
    final text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        title,
        const SizedBox(height: 2),
        subtitle,
        if (stacked && trailing != null) ...[
          const SizedBox(height: Space.x1),
          Align(alignment: AlignmentDirectional.centerEnd, child: trailing),
        ],
      ],
    );
    return ConstrainedBox(
      constraints: BoxConstraints(minHeight: minHeight),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: horizontalPadding,
          vertical: Space.x3,
        ),
        child: Row(
          crossAxisAlignment: stacked
              ? CrossAxisAlignment.start
              : crossAxisAlignment,
          children: [
            leading,
            const SizedBox(width: Space.x4),
            Expanded(child: text),
            if (!stacked && trailing != null) ...[
              const SizedBox(width: Space.x3),
              trailing!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Right-aligned column of trailing lines.
class TrailingColumn extends StatelessWidget {
  const TrailingColumn({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.end,
    children: children,
  );
}
