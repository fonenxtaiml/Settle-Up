import 'package:flutter/material.dart';

import '../../core/models.dart';
import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../format/money_format.dart';
import 'haptics.dart';
import 'kit_layout.dart';
import 'kit_strings.dart';
import 'person_avatar.dart';
import 'tether.dart';

/// Split methods as one row of outlined chips (render 3): Equally, Exact
/// amounts, Percent, Shares, Adjust. The selected chip is filled ink. The
/// row scrolls sideways on narrow phones and wraps at a large text scale.
class SplitMethodSelector extends StatelessWidget {
  const SplitMethodSelector({
    super.key,
    required this.value,
    required this.onChanged,
    this.methods = SplitMethod.values,
  });

  final SplitMethod value;
  final ValueChanged<SplitMethod> onChanged;
  final List<SplitMethod> methods;

  static String labelFor(SplitMethod m) => switch (m) {
    SplitMethod.equal => KitStrings.splitEqually,
    SplitMethod.exact => KitStrings.splitExact,
    SplitMethod.percent => KitStrings.splitPercent,
    SplitMethod.shares => KitStrings.splitShares,
    SplitMethod.adjustment => KitStrings.splitAdjust,
  };

  @override
  Widget build(BuildContext context) {
    final chips = [
      for (final m in methods)
        _MethodChip(
          label: labelFor(m),
          selected: m == value,
          onTap: () {
            if (m == value) return;
            Haptics.selection(context);
            onChanged(m);
          },
        ),
    ];
    final Widget body = isLargeText(context)
        ? Wrap(spacing: 6, runSpacing: 6, children: chips)
        : SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            clipBehavior: Clip.none,
            child: Row(
              children: [
                for (var i = 0; i < chips.length; i++) ...[
                  if (i > 0) const SizedBox(width: 6),
                  chips[i],
                ],
              ],
            ),
          );
    return Semantics(
      label: KitStrings.splitMethod,
      container: true,
      explicitChildNodes: true,
      child: body,
    );
  }
}

class _MethodChip extends StatelessWidget {
  const _MethodChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    const radius = BorderRadius.all(Radius.circular(Radii.chip));
    return Semantics(
      inMutuallyExclusiveGroup: true,
      checked: selected,
      button: true,
      label: label,
      excludeSemantics: true,
      // 34 dp visual chip inside a 48 dp tap target.
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 7),
        child: Material(
          color: selected ? scheme.primary : Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: radius,
            side: selected
                ? BorderSide.none
                : BorderSide(color: scheme.outline),
          ),
          child: InkWell(
            onTap: onTap,
            borderRadius: radius,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 34),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                child: Center(
                  widthFactor: 1,
                  child: Text(
                    label,
                    style: theme.textTheme.titleSmall!.copyWith(
                      fontSize: 13.5,
                      color: selected ? scheme.onPrimary : scheme.onSurface,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// A member in the split list (render 3): checkbox, avatar, name with a
/// subline, and their share. Your own row shows how the expense leaves you
/// ("you owe Priya" with a tether, in the direction colour). People not in
/// the split are dimmed and read "not in this expense". The whole row
/// toggles.
class MemberSplitRow extends StatelessWidget {
  const MemberSplitRow({
    super.key,
    required this.id,
    required this.name,
    required this.included,
    required this.onChanged,
    required this.currency,
    this.isMe = false,
    this.subtitle,
    this.subtitleDirection,
    this.shareMinor,
    this.shareDirection = MoneyDirection.neutral,
    this.avatarName,
  });

  final String id;

  /// Shown name: "You", "Priya".
  final String name;

  /// Name used for the initials; defaults to [name].
  final String? avatarName;
  final bool included;
  final ValueChanged<bool>? onChanged;
  final String currency;
  final bool isMe;

  /// "owes Priya", "her own share"; defaults to "not in this expense" when
  /// excluded.
  final String? subtitle;

  /// Colours the subline and adds a tether ([MoneyDirection.owe] for "you
  /// owe Priya"). Null keeps it secondary ink.
  final MoneyDirection? subtitleDirection;

  /// This person's share, unsigned. Null hides it.
  final int? shareMinor;

  /// [MoneyDirection.owe] shows "−₹600" in Kiln for your own share.
  final MoneyDirection shareDirection;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final money = context.money;
    final sub = subtitle ?? (included ? null : KitStrings.notInThisExpense);
    final subColor = subtitleDirection == null
        ? scheme.onSurfaceVariant
        : money.forDirection(subtitleDirection!);
    final subStyle = theme.textTheme.bodySmall!.copyWith(color: subColor);
    final titleStyle = included
        ? theme.textTheme.titleSmall!
        : theme.textTheme.titleSmall!
              .withWeight(FontWeight.w500)
              .copyWith(color: scheme.onSurfaceVariant);

    final share = shareMinor == null || !included
        ? null
        : MoneyFormat.format(
            shareDirection == MoneyDirection.owe
                ? -shareMinor!.abs()
                : shareMinor!.abs(),
            currency,
            signed:
                shareDirection == MoneyDirection.owe ||
                shareDirection == MoneyDirection.owed,
          );

    final spoken = [
      name,
      ?sub,
      if (share != null) MoneyFormat.spoken(shareMinor!, currency),
    ].join(', ');

    void toggle() {
      if (onChanged == null) return;
      Haptics.selection(context);
      onChanged!(!included);
    }

    final shareStyle = AppType.amountSmall(context)
        .copyWith(color: money.forDirection(shareDirection));
    // The tether glyph (26 dp, following the text scale up to 1.5x) and
    // its gap, when the subline shows one.
    final tether =
        6 + 26 * MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 1.5);
    final text = ExcludeSemantics(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(name, style: titleStyle),
          if (sub != null)
            Row(
              children: [
                if (subtitleDirection != null) ...[
                  TetherGlyph(direction: subtitleDirection!, color: subColor),
                  const SizedBox(width: 6),
                ],
                // An amount in the subline ("you get back ₹80,000.33") is
                // set smaller rather than broken (VISUAL-R5-02).
                Flexible(child: FitWordsText(sub, style: subStyle)),
              ],
            ),
        ],
      ),
    );

    return MergeSemantics(
      child: Semantics(
        label: spoken,
        child: InkWell(
          onTap: onChanged == null ? null : toggle,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(0, 4, 16, 4),
              child: Row(
                children: [
                  Checkbox(
                    value: included,
                    onChanged: onChanged == null ? null : (_) => toggle(),
                  ),
                  PersonAvatar(
                    id: id,
                    name: avatarName ?? name,
                    size: Sizes.avatarSmall,
                    isMe: isMe,
                  ),
                  const SizedBox(width: Space.md),
                  Expanded(
                    child: share == null
                        ? text
                        : LayoutBuilder(
                            builder: (context, c) {
                              // The share goes under the text at large
                              // text, and whenever the name's longest word
                              // or an amount in the subline would get less
                              // room beside it (VISUAL-R5-02), as
                              // KitListRow does.
                              final needs = [
                                longestWordWidth(context, name, titleStyle),
                                if (sub != null)
                                  longestWordWidth(context, sub, subStyle) +
                                      (subtitleDirection != null ? tether : 0),
                              ].fold(0.0, (a, b) => a > b ? a : b);
                              final room =
                                  c.maxWidth -
                                  Space.sm -
                                  measureTextWidth(context, share, shareStyle);
                              final stacked =
                                  isLargeText(context) || room + 0.5 < needs;
                              return BesideOrUnder(
                                text: text,
                                stacked: stacked,
                                gap: Space.sm,
                                stackedAlignment:
                                    AlignmentDirectional.centerEnd,
                                trailing: ExcludeSemantics(
                                  // Under the text, a share wider than
                                  // the row is set smaller, never cut.
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      share,
                                      maxLines: 1,
                                      style: shareStyle,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The live check above "Save expense" (render 3): a summary on the left
/// ("₹600 each, 4 people") and what is left to split on the right ("₹0
/// left to split"). Over-assigned shows "₹200 too much" in the error
/// colour: that one is a real error, not money direction.
class SplitSummaryBar extends StatelessWidget {
  const SplitSummaryBar({
    super.key,
    required this.summary,
    required this.leftMinor,
    required this.currency,
    this.problem,
  });

  final String summary;

  /// Why Save is off when no amount says it ("Pick at least one person").
  /// Shown in place of the remainder, in the error colour.
  final String? problem;

  /// Total minus assigned: 0 when done, negative when over-assigned.
  final int leftMinor;
  final String currency;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final base = theme.textTheme.bodyMedium!.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final over = leftMinor < 0;
    final amount = MoneyFormat.format(leftMinor.abs(), currency);
    final strong = theme.textTheme.titleSmall!
        .copyWith(fontSize: 14, color: over ? scheme.error : scheme.onSurface)
        .tabular;
    final problem = this.problem;
    final right = problem != null
        ? Text(
            problem,
            textAlign: TextAlign.end,
            style: base.copyWith(color: scheme.error),
          )
        : Text.rich(
            TextSpan(
              children: [
                TextSpan(text: amount, style: strong),
                TextSpan(
                  text: over ? ' too much' : ' left to split',
                  style: over ? base.copyWith(color: scheme.error) : base,
                ),
              ],
            ),
            textAlign: TextAlign.end,
          );
    final spoken =
        problem ??
        (over
            ? KitStrings.tooMuch(MoneyFormat.spoken(leftMinor.abs(), currency))
            : KitStrings.leftToSplit(MoneyFormat.spoken(leftMinor, currency)));
    return Semantics(
      liveRegion: true,
      container: true,
      label: '$summary. $spoken',
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: LayoutBuilder(
          builder: (context, c) {
            // Stacked at large text, and earlier whenever an amount in the
            // summary would not fit beside the remainder: an amount is
            // never broken over two lines (VISUAL-R4-03).
            final stack =
                isLargeText(context) ||
                (problem == null &&
                    _longestWord(context, summary, base) +
                            Space.sm +
                            _width(context, right) >
                        c.maxWidth);
            return stack
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(summary, style: base),
                      Align(
                        alignment: AlignmentDirectional.centerStart,
                        child: right,
                      ),
                    ],
                  )
                : Row(
                    children: [
                      Expanded(child: Text(summary, style: base)),
                      const SizedBox(width: Space.sm),
                      if (problem != null) Flexible(child: right) else right,
                    ],
                  );
          },
        ),
      ),
    );
  }

  static double _width(BuildContext context, Text text) {
    final span = text.textSpan ?? TextSpan(text: text.data, style: text.style);
    final tp = TextPainter(
      text: span,
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final w = tp.width;
    tp.dispose();
    return w;
  }

  static double _longestWord(BuildContext context, String s, TextStyle st) {
    var widest = 0.0;
    for (final word in s.split(RegExp(r'\s+'))) {
      if (word.isEmpty) continue;
      final w = _width(context, Text(word, style: st));
      if (w > widest) widest = w;
    }
    return widest;
  }
}
