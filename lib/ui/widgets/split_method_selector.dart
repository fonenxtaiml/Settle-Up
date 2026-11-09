import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../theme/tokens.dart';
import 'haptics.dart';
import 'kit_strings.dart';
import 'row_layout.dart';

/// Equally / Amounts / Percent / Shares segmented control (DESIGN 5.5).
/// Adjustment is reachable from the split editor's overflow, not a segment.
class SplitMethodSelector extends StatelessWidget {
  const SplitMethodSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final SplitMethod value;
  final ValueChanged<SplitMethod> onChanged;

  static const List<SplitMethod> segments = [
    SplitMethod.equal,
    SplitMethod.exact,
    SplitMethod.percent,
    SplitMethod.shares,
  ];

  static String labelFor(SplitMethod m) => switch (m) {
    SplitMethod.equal => KitStrings.splitEqually,
    SplitMethod.exact => KitStrings.splitAmounts,
    SplitMethod.percent => KitStrings.splitPercent,
    SplitMethod.shares => KitStrings.splitShares,
    SplitMethod.adjustment => KitStrings.splitAdjust,
  };

  void _select(BuildContext context, SplitMethod m) {
    if (m == value) return;
    Haptics.selection(context);
    onChanged(m);
  }

  @override
  Widget build(BuildContext context) {
    // At a large text scale four segments cannot fit; a scrolling chip row
    // keeps every label whole (DESIGN 5.5).
    if (isStackedRow(context)) {
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final m in segments) ...[
              if (m != segments.first) const SizedBox(width: Space.x2),
              ChoiceChip(
                label: Text(labelFor(m)),
                selected: m == value,
                showCheckmark: false,
                onSelected: (_) => _select(context, m),
              ),
            ],
          ],
        ),
      );
    }
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<SplitMethod>(
        segments: [
          for (final m in segments)
            ButtonSegment<SplitMethod>(
              value: m,
              label: Text(labelFor(m), maxLines: 1, softWrap: false),
            ),
        ],
        selected: segments.contains(value) ? {value} : const <SplitMethod>{},
        emptySelectionAllowed: true,
        showSelectedIcon: false,
        onSelectionChanged: (s) {
          if (s.isNotEmpty) _select(context, s.first);
        },
      ),
    );
  }
}
