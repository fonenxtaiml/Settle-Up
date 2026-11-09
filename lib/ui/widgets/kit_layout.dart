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
