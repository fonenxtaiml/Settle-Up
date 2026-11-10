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
