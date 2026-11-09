import 'package:flutter/widgets.dart';

/// Text scale at which rows stack their trailing amount under the title
/// and side-by-side layouts become vertical (DESIGN-level 3.4, kept).
const double kLargeTextScale = 1.6;

/// True when the user's text scale is large enough that two-column rows
/// would squeeze their text; such rows stack instead.
bool isLargeText(BuildContext context) =>
    MediaQuery.textScalerOf(context).scale(1) >= kLargeTextScale;
