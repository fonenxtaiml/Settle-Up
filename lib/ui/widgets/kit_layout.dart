import 'package:flutter/material.dart';

/// Text scale at which rows stack their trailing amount under the title
/// and side-by-side layouts become vertical (DESIGN-level 3.4, kept).
const double kLargeTextScale = 1.6;

/// True when the user's text scale is large enough that two-column rows
/// would squeeze their text; such rows stack instead.
bool isLargeText(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(1) >= kLargeTextScale;

/// The kit's indeterminate spinner. Under "Remove animations" it is a still
/// ring (75%) and the words next to it carry the state.
class KitSpinner extends StatelessWidget {
  const KitSpinner({super.key, this.strokeWidth = 2});

  final double strokeWidth;

  @override
  Widget build(BuildContext context) => CircularProgressIndicator(
    strokeWidth: strokeWidth,
    value: MediaQuery.disableAnimationsOf(context) ? 0.75 : null,
  );
}

/// [style] as a [Text] in [context] would paint it (merged over the
/// ambient [DefaultTextStyle]).
TextStyle effectiveTextStyle(BuildContext context, TextStyle? style) =>
    DefaultTextStyle.of(context).style.merge(style);

TextPainter _painter(
  BuildContext context,
  String text,
  TextStyle? style, {
  int? maxLines,
}) => TextPainter(
  text: TextSpan(text: text, style: effectiveTextStyle(context, style)),
  textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
  textScaler: MediaQuery.textScalerOf(context),
  locale: Localizations.maybeLocaleOf(context),
  maxLines: maxLines,
);

/// The width [text] takes on one line in [style] at the current text scale.
double measureTextWidth(BuildContext context, String text, TextStyle? style) {
  final p = _painter(context, text, style)..layout();
  final w = p.width;
  p.dispose();
  return w;
}

/// The width of the widest word of [text] (split at white space) in
/// [style] at the current text scale: the least room a label needs so no
/// word is cut or broken.
double longestWordWidth(BuildContext context, String text, TextStyle? style) {
  var widest = 0.0;
  for (final word in text.split(RegExp(r'\s+'))) {
    if (word.isEmpty) continue;
    final w = measureTextWidth(context, word, style);
    if (w > widest) widest = w;
  }
  return widest;
}

/// Whether [text] in [style] fits [maxWidth] in at most [maxLines] lines
/// at the current text scale, with no word broken or cut. Layouts use it to
/// stack (or give way) before a label turns into "Cas" or "borrowe/d".
bool textFitsWords(
  BuildContext context,
  String text,
  TextStyle? style,
  double maxWidth, {
  int maxLines = 1,
}) {
  if (maxWidth <= 0) return false;
  final p = _painter(context, text, style, maxLines: maxLines)
    ..layout(maxWidth: maxWidth);
  final fits = !p.didExceedMaxLines && p.minIntrinsicWidth <= maxWidth + 0.5;
  p.dispose();
  return fits;
}

/// A segmented-button label that is never broken or clipped: one line,
/// scaled down when its segment is narrower than the word.
class SegmentLabel extends StatelessWidget {
  const SegmentLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => FittedBox(
    fit: BoxFit.scaleDown,
    child: Text(text, maxLines: 1, softWrap: false),
  );
}

/// Whether the widest of [labels] fits one of [count] equal segments of
/// [width], each losing [chrome] dp to padding, borders and any icon.
bool segmentsFit(
  BuildContext context,
  Iterable<String> labels,
  double width, {
  required int count,
  required double chrome,
}) {
  final style = Theme.of(context).textTheme.labelLarge;
  final room = width / count - chrome;
  for (final l in labels) {
    if (measureTextWidth(context, l, style) > room) return false;
  }
  return true;
}

/// Two hero buttons side by side (Settle up | All balances). At large text,
/// or when a label would not fit its half as one whole line, they stack
/// full width instead, so no word is broken ("All bal/ances").
class ButtonPair extends StatelessWidget {
  const ButtonPair({
    super.key,
    required this.first,
    required this.second,
    required this.labels,
  });

  final Widget first;
  final Widget second;

  /// The two button labels, measured to decide the layout.
  final List<String> labels;

  /// A filled button's side padding (24 a side at 1x).
  static const double _chrome = 48;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final half = (constraints.maxWidth - 8) / 2;
      final style = Theme.of(context).textTheme.labelLarge;
      final fits =
          !isLargeText(context) &&
          labels.every(
            (l) => measureTextWidth(context, l, style) <= half - _chrome,
          );
      if (!fits) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [first, const SizedBox(height: 8), second],
        );
      }
      return Row(
        children: [
          Expanded(child: first),
          const SizedBox(width: 8),
          Expanded(child: second),
        ],
      );
    },
  );
}

/// A [Text] that never breaks a word over two lines: when its longest word
/// (an amount: "₹1,20,000.50", "KD99,999,999.999") is wider than the room
/// it gets, the whole text is set smaller until that word fits, as the
/// balance heroes scale theirs (VISUAL-R4-03, VISUAL-R5-02).
class FitWordsText extends StatelessWidget {
  const FitWordsText(
    this.data, {
    super.key,
    this.style,
    this.maxLines,
    this.overflow,
  });

  final String data;
  final TextStyle? style;
  final int? maxLines;
  final TextOverflow? overflow;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) => Text(
      data,
      style: fitWordsStyle(context, data, style, c.maxWidth),
      maxLines: maxLines,
      overflow: overflow,
    ),
  );
}

/// [style] at the largest size (at most its own) at which the longest word
/// of [text] fits [width]; [style] itself when it already fits.
TextStyle? fitWordsStyle(
  BuildContext context,
  String text,
  TextStyle? style,
  double width,
) {
  if (!width.isFinite || width <= 0) return style;
  if (longestWordWidth(context, text, style) <= width + 0.25) return style;
  final base = effectiveTextStyle(context, style);
  final size = base.fontSize ?? 14;
  // Text scaling may be nonlinear (Android 14), so search for the size.
  var lo = 1.0;
  var hi = size;
  for (var i = 0; i < 14; i++) {
    final mid = (lo + hi) / 2;
    final w = longestWordWidth(context, text, base.copyWith(fontSize: mid));
    if (w <= width) {
      lo = mid;
    } else {
      hi = mid;
    }
  }
  return base.copyWith(fontSize: lo);
}

/// [text] with [trailing] (an amount, a share field) beside it, or under it
/// when [stacked]. The children keep their places in the tree whichever
/// layout is picked, so a focused field never loses its focus (and the
/// keyboard never closes) when the row switches while typing
/// (VISUAL-R5-01).
class BesideOrUnder extends StatelessWidget {
  const BesideOrUnder({
    super.key,
    required this.text,
    required this.trailing,
    required this.stacked,
    this.gap = 8,
    this.stackGap = 4,
    this.stackedAlignment = AlignmentDirectional.centerStart,
  });

  final Widget text;
  final Widget trailing;
  final bool stacked;

  /// Space between [text] and [trailing] beside it, and under it.
  final double gap;
  final double stackGap;

  /// Where [trailing] sits under [text].
  final AlignmentDirectional stackedAlignment;

  @override
  Widget build(BuildContext context) => Flex(
    direction: stacked ? Axis.vertical : Axis.horizontal,
    mainAxisSize: stacked ? MainAxisSize.min : MainAxisSize.max,
    crossAxisAlignment: stacked
        ? CrossAxisAlignment.stretch
        : CrossAxisAlignment.center,
    children: [
      Flexible(
        flex: stacked ? 0 : 1,
        fit: stacked ? FlexFit.loose : FlexFit.tight,
        child: Align(alignment: AlignmentDirectional.centerStart, child: text),
      ),
      SizedBox(width: stacked ? 0 : gap, height: stacked ? stackGap : 0),
      Align(
        alignment: stacked
            ? stackedAlignment
            : AlignmentDirectional.centerStart,
        widthFactor: stacked ? null : 1,
        child: trailing,
      ),
    ],
  );
}
