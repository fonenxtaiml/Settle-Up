import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../format/dates.dart';

/// Sentence-case section header (DESIGN 6.2, 6.9): titleSmall, never caps.
/// Use it only when a list has more than one section.
class SectionHeader extends StatelessWidget {
  const SectionHeader(this.title, {super.key, this.emphasized = true});

  final String title;

  /// Plumb for settings-style sections; onSurfaceVariant for list sections
  /// like "Unsettled" / "Settled up".
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.x4,
          Space.x6,
          Space.x4,
          Space.x2,
        ),
        child: Text(
          title,
          style: theme.textTheme.titleSmall!.copyWith(
            color: emphasized ? scheme.primary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Day header that groups expense and activity rows (DESIGN 5.3):
/// "Today", "Yesterday", "Mon 4 Mar".
class DateHeader extends StatelessWidget {
  const DateHeader({super.key, required this.date, this.now});

  final DateTime date;
  final DateTime? now; // test hook

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Semantics(
      header: true,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          Space.x4,
          Space.x4,
          Space.x4,
          Space.x1,
        ),
        child: Text(
          DateLabels.dayHeader(date, now: now),
          style: theme.textTheme.titleSmall!.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
