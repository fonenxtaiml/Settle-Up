import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../format/well_formed_formatter.dart';
import 'beside_or_below.dart';
import 'button_semantics.dart';
import 'category_glyph.dart';
import 'kit_layout.dart';
import 'kit_strings.dart';

/// White 12 dp-radius input with a small label above the text and an
/// optional trailing widget, usually a [CategoryChip] (render 3,
/// "Description").
///
/// The label and the hint are the app's words and always read in full
/// (VISUAL-R33-03, as VISUAL-R31-01 for helper and error text): the label
/// wraps over the input's top padding (the whole field still takes a tap,
/// VISUAL-R8-01), the hint wraps, and the trailing widget goes under the
/// field, end-aligned, when beside it the label or the hint would get less
/// room than its widest word ([BesideOrBelow]).
class LabeledTextField extends StatelessWidget {
  const LabeledTextField({
    super.key,
    required this.label,
    this.controller,
    this.onChanged,
    this.trailing,
    this.hintText,
    this.focusNode,
    this.textInputAction,
    this.onSubmitted,
    this.errorText,
    this.maxLength,
    this.inputFormatters,
    this.multiline = false,
  });

  final String label;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final Widget? trailing;
  final String? hintText;
  final FocusNode? focusNode;
  final TextInputAction? textInputAction;
  final ValueChanged<String>? onSubmitted;
  final String? errorText;
  final int? maxLength;

  /// Run before the [maxLength] cap, e.g. a name field's stored-length
  /// cap.
  final List<TextInputFormatter>? inputFormatters;

  /// The field grows with its text and keeps line breaks (notes and the
  /// description, SPEC 5.16); a one-line field joins the lines of a text
  /// it holds on the first key.
  final bool multiline;

  static const double _fieldPad = 8;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final valueStyle = theme.textTheme.titleMedium!.withWeight(FontWeight.w500);
    final labelStyle = theme.textTheme.labelSmall!
        .withWeight(FontWeight.w500)
        .copyWith(color: scheme.onSurfaceVariant);
    final hintStyle = valueStyle.copyWith(color: scheme.onSurfaceVariant);

    Widget field(double labelHeight) => TextField(
      controller: controller,
      focusNode: focusNode,
      onChanged: onChanged,
      onSubmitted: onSubmitted,
      textInputAction: textInputAction,
      maxLength: maxLength,
      inputFormatters: WellFormedTextFormatter.first(inputFormatters),
      minLines: 1,
      maxLines: multiline ? null : 1,
      // With an action of its own (Done on the description) the key
      // performs it: line breaks the field holds are kept, none is typed.
      keyboardType: !multiline
          ? null
          : textInputAction == null ||
                textInputAction == TextInputAction.newline
          ? TextInputType.multiline
          : TextInputType.text,
      textCapitalization: TextCapitalization.sentences,
      style: valueStyle,
      decoration: InputDecoration(
        isDense: true,
        filled: false,
        border: InputBorder.none,
        enabledBorder: InputBorder.none,
        focusedBorder: InputBorder.none,
        errorBorder: InputBorder.none,
        // The 8 dp above the label and below the text are the field's own
        // padding, and so is the label's room, so the whole height takes a
        // tap (at least 48 dp, VISUAL-R8-01).
        contentPadding: EdgeInsets.only(
          top: _fieldPad + labelHeight,
          bottom: _fieldPad,
        ),
        counterText: '',
        hintText: hintText,
        // The hint wraps in full (the theme's hintMaxLines, VISUAL-R33-03).
        hintMaxLines: AppTheme.fieldNoteMaxLines,
        hintStyle: hintStyle,
      ),
    );

    // The label (render 3: 12 dp, medium) wraps in the field's width and
    // sits in the field's top padding; taps go through it to the field,
    // and TalkBack reads it as the field's label (one merged node).
    final main = _NoMinIntrinsicWidth(
      child: LayoutBuilder(
        builder: (context, c) {
          final painter = TextPainter(
            text: TextSpan(
              text: label,
              style: effectiveTextStyle(context, labelStyle),
            ),
            textDirection: Directionality.of(context),
            textScaler: MediaQuery.textScalerOf(context),
            locale: Localizations.maybeLocaleOf(context),
          )..layout(maxWidth: c.maxWidth);
          final labelHeight = painter.height;
          painter.dispose();
          return MergeSemantics(
            child: Stack(
              children: [
                field(labelHeight),
                PositionedDirectional(
                  top: _fieldPad,
                  start: 0,
                  end: 0,
                  child: IgnorePointer(child: Text(label, style: labelStyle)),
                ),
              ],
            ),
          );
        },
      ),
    );

    final trailing = this.trailing;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 12, 0),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerLowest,
            borderRadius: BorderRadius.circular(Radii.md),
            border: errorText == null
                ? null
                : Border.all(color: scheme.error, width: 2),
          ),
          child: trailing == null
              ? main
              : BesideOrBelow(
                  main: main,
                  gap: Space.md,
                  spacing: 0,
                  // What the user types never moves the chip: only the
                  // label's and the hint's widest words decide whether it
                  // fits beside the field.
                  minMainWidth: [
                    longestWordWidth(context, label, labelStyle),
                    if (hintText case final hint?)
                      longestWordWidth(context, hint, hintStyle),
                  ].reduce((a, b) => a > b ? a : b),
                  trailing: Padding(
                    // A CategoryChip brings its own 48 dp target (8 dp
                    // above and below its 32 dp chip), so the field stays
                    // 56 dp with the chip where it was (VISUAL-R9-01).
                    padding: EdgeInsets.symmetric(
                      vertical: trailing is CategoryChip
                          ? _fieldPad - CategoryChip.targetPad / 2
                          : _fieldPad,
                    ),
                    child: trailing,
                  ),
                ),
        ),
        if (errorText != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, Space.xs, 4, 0),
            child: Semantics(
              liveRegion: true,
              child: Text(
                errorText!,
                style: theme.textTheme.bodySmall!.copyWith(color: scheme.error),
              ),
            ),
          ),
      ],
    );
  }
}

/// [child] with no least width of its own (and none asked of it): a text
/// field's typed words do not count when a row decides whether its trailing
/// block fits beside it.
class _NoMinIntrinsicWidth extends SingleChildRenderObjectWidget {
  const _NoMinIntrinsicWidth({required Widget super.child});

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderNoMinIntrinsicWidth();
}

class _RenderNoMinIntrinsicWidth extends RenderProxyBox {
  @override
  double computeMinIntrinsicWidth(double height) => 0;
}

/// Tonal category chip (render 3, "Transport"): stone fill, 8 dp radius,
/// 18 dp icon and a 13 dp semibold label. Tapping opens the picker.
class CategoryChip extends StatelessWidget {
  const CategoryChip({
    super.key,
    required this.categoryId,
    required this.label,
    this.onTap,
  });

  /// Above and below the 32 dp chip, for a 48 dp target.
  static const double targetPad = 8;

  final String categoryId;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return ButtonSemantics(
      label: KitStrings.changeCategory(label),
      onTap: onTap,
      // 32 dp visual chip inside a 48 dp tap target (VISUAL-R9-01).
      child: TapTargetPadding(
        padding: const EdgeInsets.symmetric(vertical: CategoryChip.targetPad),
        onTap: onTap,
        child: Material(
          color: scheme.surfaceContainer,
          borderRadius: BorderRadius.circular(Radii.sm),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(Radii.sm),
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: 32),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CategoryGlyph(
                      categoryId: categoryId,
                      size: 18,
                      color: scheme.onSurface,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      label,
                      style: theme.textTheme.labelMedium!.withWeight(
                        FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Two [PickerTile]s side by side (Add expense: Paid by | Date), each
/// taking half the row, or one above the other when either would break a
/// word of its label or value in half the row ("Today / , 9 / Nov" on a
/// 320 dp phone at 1.3x, VISUAL-R33-02, the VISUAL-R32-02 rule) and at a
/// large text scale.
class PickerTilePair extends StatelessWidget {
  const PickerTilePair({super.key, required this.first, required this.second});

  final PickerTile first;
  final PickerTile second;

  static const double _gap = Space.sm;

  bool _fitsBeside(BuildContext context, double width) {
    if (!width.isFinite) return true;
    final half = (width - _gap) / 2;
    for (final t in [first, second]) {
      final need = PickerTile.minWidthFor(
        context,
        label: t.label,
        value: t.value,
        hasLeading: t.leading != null,
      );
      if (half + 0.5 < need) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      if (!isLargeText(context) && _fitsBeside(context, c.maxWidth)) {
        return Row(
          children: [
            Expanded(child: first),
            const SizedBox(width: _gap),
            Expanded(child: second),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          first,
          const SizedBox(height: _gap),
          second,
        ],
      );
    },
  );
}

/// A picker button on Add expense ("Paid by Priya", "Date Today, 9 Nov"):
/// white, 12 dp radius, a leading avatar or icon, a small label above the
/// value, and an expand chevron.
///
/// The value comes first (VISUAL-R17-01): a wide leading (a currency
/// symbol at large text, [SymbolText]) takes only the width the value can
/// spare and scales down in it, so the value shows whole in two lines
/// whenever it would beside the 26 dp an avatar takes. A value that does
/// not fit two lines even then takes as many as it needs, up to four.
class PickerTile extends StatelessWidget {
  const PickerTile({
    super.key,
    required this.label,
    required this.value,
    this.leading,
    this.onTap,
  });

  final String label;
  final String value;
  final Widget? leading;
  final VoidCallback? onTap;

  /// The slot an avatar or icon takes; a wider leading never gets less.
  static const double _leadingMin = 26;

  /// The most lines a value takes before it ends in an ellipsis: enough
  /// for the longest currency name with its code ("Bosnia and Herzegovina
  /// convertible mark (BAM)") at 2.0x on a 320 dp phone.
  static const int _maxLines = 4;

  /// The gaps beside the value (10 + 10) and the 20 dp chevron.
  static const double _chrome = 10 + 10 + 20;

  /// The narrowest whole-dp width that shows [text] in [style] within
  /// [maxLines], or null when even [max] does not.
  static double? _narrowestFit(
    BuildContext context,
    String text,
    TextStyle style,
    int maxLines,
    double max,
  ) {
    final painter = TextPainter(
      text: TextSpan(text: text, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: maxLines,
      ellipsis: '\u2026',
      locale: Localizations.maybeLocaleOf(context),
    );
    // A width narrower than a word would break it at character level
    // ("Today / , 9 / Nov") and still count as a fit: the value never
    // gets less than its widest word (VISUAL-R33-02).
    bool fits(double w) {
      painter.layout(maxWidth: w);
      return !painter.didExceedMaxLines && painter.minIntrinsicWidth <= w + 0.5;
    }

    try {
      if (!fits(max)) return null;
      var lo = 0;
      var hi = max.floor();
      while (lo < hi) {
        final mid = (lo + hi) >> 1;
        if (fits(mid.toDouble())) {
          hi = mid;
        } else {
          lo = mid + 1;
        }
      }
      return hi.toDouble();
    } finally {
      painter.dispose();
    }
  }

  /// The horizontal padding of the tile (12 + 10).
  static const double _padding = 12 + 10;

  /// The gap between the leading and the value.
  static const double _leadingGap = 10;

  static TextStyle _labelStyle(ThemeData theme) => theme.textTheme.labelSmall!
      .withWeight(FontWeight.w500)
      .copyWith(color: theme.colorScheme.onSurfaceVariant);

  /// The least width a tile showing [label] and [value] beside a 26 dp
  /// leading needs so that neither breaks a word: layouts that put two
  /// tiles side by side (Paid by | Date) stack them when half the row is
  /// less (VISUAL-R33-02, the VISUAL-R32-02 rule).
  static double minWidthFor(
    BuildContext context, {
    required String label,
    required String value,
    bool hasLeading = true,
  }) {
    final theme = Theme.of(context);
    final text = [
      longestWordWidth(context, label, _labelStyle(theme)),
      longestWordWidth(context, value, theme.textTheme.titleSmall),
    ].reduce((a, b) => a > b ? a : b);
    return _padding +
        (hasLeading ? _leadingMin + _leadingGap : 0) +
        text.ceilToDouble() +
        _chrome;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final valueStyle = theme.textTheme.titleSmall;
    return ButtonSemantics(
      label: '$label, $value',
      onTap: onTap,
      child: Material(
        color: scheme.surfaceContainerLowest,
        borderRadius: BorderRadius.circular(Radii.md),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(Radii.md),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 56),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 10, 8),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  var maxLines = 2;
                  var leadingMax = double.infinity;
                  final room = constraints.maxWidth - _chrome;
                  if (leading != null && room.isFinite) {
                    final style = DefaultTextStyle.of(context).style
                        .merge(valueStyle);
                    // The fewest lines (two, up to [_maxLines]) the value
                    // fits beside the narrowest leading, and the narrowest
                    // width it needs in them.
                    double? need;
                    for (; maxLines <= _maxLines; maxLines++) {
                      need = _narrowestFit(
                        context,
                        value,
                        style,
                        maxLines,
                        room - _leadingMin,
                      );
                      if (need != null) break;
                    }
                    if (maxLines > _maxLines) maxLines = _maxLines;
                    leadingMax = need == null
                        ? _leadingMin
                        : (room - need).floorToDouble();
                    if (leadingMax < _leadingMin) leadingMax = _leadingMin;
                  }
                  return Row(
                    children: [
                      if (leading != null) ...[
                        // 26 dp for an avatar or icon; a wider leading (a
                        // currency symbol at large text) takes what it
                        // needs, up to what the value can spare.
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            minWidth: _leadingMin,
                            maxWidth: leadingMax,
                          ),
                          child: Center(widthFactor: 1, child: leading),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(label, style: _labelStyle(theme)),
                            Text(
                              value,
                              maxLines: maxLines,
                              overflow: TextOverflow.ellipsis,
                              style: valueStyle,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      Icon(
                        Icons.expand_more_rounded,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Key and value row in a grouped list (render 4, "Date Today, 9 Nov"):
/// a 72 dp secondary key column, a semibold value, a chevron. A null value
/// shows [placeholder] in secondary ink ("Optional").
///
/// When the key column or the room beside it is narrower than a word of
/// the key or the value ("Optional" at 2.0x on a 320 dp phone), the value
/// goes under the key: no word is broken mid-word (the VISUAL-R32-02 rule,
/// as [PickerTilePair] and the Settle up table, VISUAL-R33-01/02).
class KeyValueRow extends StatelessWidget {
  const KeyValueRow({
    super.key,
    required this.label,
    required this.value,
    this.placeholder,
    this.onTap,
  });

  final String label;
  final String? value;
  final String? placeholder;
  final VoidCallback? onTap;

  /// The chevron.
  static const double _chevron = 20;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final shown = value ?? placeholder ?? '';
    final keyWidth = MediaQuery.textScalerOf(context)
        .scale(72)
        .clamp(72.0, 140.0);
    final keyStyle = theme.textTheme.bodyMedium!.copyWith(
      color: scheme.onSurfaceVariant,
    );
    final valueStyle = value == null
        ? theme.textTheme.titleSmall!
              .withWeight(FontWeight.w500)
              .copyWith(color: scheme.onSurfaceVariant)
        : theme.textTheme.titleSmall!;
    final keyText = Text(label, style: keyStyle);
    final valueText = Text(shown, style: valueStyle);
    return ButtonSemantics(
      alwaysButton: false,
      label: '$label, $shown',
      onTap: onTap,
      child: InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsetsDirectional.fromSTEB(16, 6, 12, 6),
            child: LayoutBuilder(
              builder: (context, c) {
                final room =
                    c.maxWidth - (onTap == null ? 0 : _chevron) - Space.md;
                final beside =
                    !c.hasBoundedWidth ||
                    (longestWordWidth(context, label, keyStyle) <=
                            keyWidth + 0.5 &&
                        longestWordWidth(context, shown, valueStyle) <=
                            room - keyWidth + 0.5);
                return Row(
                  children: [
                    if (beside) ...[
                      SizedBox(width: keyWidth, child: keyText),
                      const SizedBox(width: Space.md),
                      Expanded(child: valueText),
                    ] else
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [keyText, valueText],
                        ),
                      ),
                    if (onTap != null)
                      Icon(
                        Icons.chevron_right_rounded,
                        size: _chevron,
                        color: scheme.onSurfaceVariant,
                      ),
                  ],
                );
              },
            ),
          ),
        ),
      ),
    );
  }
}
