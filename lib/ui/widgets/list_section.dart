import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';

/// A grouped list (DESIGN.md "Layout"): an optional section heading on the
/// stone background, then a white container with a 20 dp radius and inset
/// hairline dividers between the rows. Flat: no shadow.
///
/// Place it inside the 16 dp container gutter; the heading insets itself by
/// 4 dp so its text lines up with the text inside the card.
class ListSection extends StatelessWidget {
  const ListSection({
    super.key,
    required this.children,
    this.title,
    this.titleAction,
    this.header,
    this.dividerIndent = Space.rowInset,
    this.padding = EdgeInsets.zero,
    this.semanticLabel,
  });

  final List<Widget> children;

  /// Section heading above the card ("Groups").
  final String? title;

  /// Trailing heading action, usually a [TextLink] ("See all").
  final Widget? titleAction;

  /// Header inside the card, above the rows ("Suggested payments").
  final Widget? header;

  /// Start inset of the dividers: 16 for plain rows, 70 for 40 dp avatar
  /// rows, 64 for member rows.
  final double dividerIndent;
  final EdgeInsetsGeometry padding;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final rows = <Widget>[
      ?header,
      for (var i = 0; i < children.length; i++) ...[
        if (i > 0 &&
            children[i] is! DateSubhead &&
            children[i - 1] is! DateSubhead)
          Divider(indent: dividerIndent, height: 1, thickness: 1),
        children[i],
      ],
    ];
    final card = Semantics(
      label: semanticLabel,
      container: semanticLabel != null,
      child: Material(
        color: scheme.surfaceContainerLowest,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(Radii.lg)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: padding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: rows,
          ),
        ),
      ),
    );
    if (title == null) return card;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        SectionHeading(title!, action: titleAction),
        card,
      ],
    );
  }
}

/// Section heading on stone: 16/22 semibold, 18 dp above and 8 dp below,
/// with an optional trailing action aligned on the baseline.
class SectionHeading extends StatelessWidget {
  const SectionHeading(
    this.title, {
    super.key,
    this.action,
    this.padding = const EdgeInsets.fromLTRB(
      4,
      Space.sectionTop,
      4,
      Space.sectionBottom,
    ),
  });

  final String title;
  final Widget? action;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    if (action is TextLink) {
      // Centre the 32 dp link on the 22 dp title without growing the gap.
      const grow = (kTextLinkHeight - 22) / 2;
      final p = padding.resolve(Directionality.of(context));
      return Padding(
        padding: p.copyWith(
          top: (p.top - grow).clamp(0, double.infinity),
          bottom: (p.bottom - grow).clamp(0, double.infinity),
        ),
        child: Row(
          children: [
            Expanded(
              child: Semantics(
                header: true,
                child: Text(title, style: AppType.section(context)),
              ),
            ),
            action!,
          ],
        ),
      );
    }
    return Padding(
      padding: padding,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          Expanded(
            child: Semantics(
              header: true,
              child: Text(title, style: AppType.section(context)),
            ),
          ),
          ?action,
        ],
      ),
    );
  }
}

/// Day label inside a grouped list ("Today", "Sat, 8 Nov").
class DateSubhead extends StatelessWidget {
  const DateSubhead(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(Space.lg, 10, Space.lg, 0),
      child: Semantics(
        header: true,
        child: Text(
          label,
          style: theme.textTheme.labelMedium!.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// Height of a [TextLink]'s tap target.
const double kTextLinkHeight = 32;

/// Underlined text link ("See all", "Pay part of it"): ink, 14 dp
/// semibold, underline in the outline colour. The target is 32 dp tall
/// (above the WCAG 2.5.8 minimum) so a heading keeps its rhythm.
class TextLink extends StatelessWidget {
  const TextLink(this.label, {super.key, required this.onPressed});

  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      enabled: onPressed != null,
      onTap: onPressed,
      excludeSemantics: true,
      label: label,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(Radii.sm),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: kTextLinkHeight),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Space.xs),
            child: Center(
              widthFactor: 1,
              child: Text(label, style: AppType.link(context)),
            ),
          ),
        ),
      ),
    );
  }
}

/// Button styles that are not the theme default.
abstract final class KitButtonStyles {
  /// 36 dp pill with 14 dp text ("Sync", "Pair" in rows).
  static ButtonStyle small(BuildContext context) {
    final t = Theme.of(context).textTheme.titleSmall!.copyWith(fontSize: 14);
    return ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(64, Sizes.buttonSmall)),
      padding: const WidgetStatePropertyAll(
        EdgeInsets.symmetric(horizontal: Space.lg),
      ),
      textStyle: WidgetStatePropertyAll(t),
      visualDensity: VisualDensity.standard,
    );
  }

  /// Full-width 52 dp pill ("Save expense", "Record ₹840 payment").
  static const ButtonStyle block = ButtonStyle(
    minimumSize: WidgetStatePropertyAll(Size.fromHeight(Sizes.buttonBlock)),
  );
}
