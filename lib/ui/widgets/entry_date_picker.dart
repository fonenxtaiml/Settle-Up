// The date picker the expense, payment and settle-up editors open.
//
// It is the stock Material [DatePickerDialog], laid out so that it meets the
// charter on every phone (VISUAL-R10-01, VISUAL-R10-02):
//
// * Every day of the calendar is a 48 x 48 dp tap target
//   ([kMinInteractiveDimension]). The stock portrait calendar is 360 dp
//   wide with 12 dp at each side, so its seven columns are exactly 48 dp
//   wide when the dialog keeps its full width, and its rows are 48 dp tall
//   when it keeps its full height. The dialog therefore runs edge to edge
//   (no inset) when the screen is not wider than it, and the calendar is
//   offered only where both hold, always in the portrait layout (the
//   stock landscape calendar has 42 dp rows), which a tablet or a wide
//   window has room for in either orientation. Where they cannot (a
//   screen under 360 dp wide, a phone on its side, or a screen too short
//   for the calendar at the text size) the picker opens in input mode
//   only: a date field and two buttons, all of them full size.
// * The chosen date in the header always fits on its line. The stock
//   header is a fixed 120 dp box (more at large text) that takes the
//   theme's headlineLarge (44 sp here, for the settle-up amount): at 2.0x
//   that wrapped onto two lines and overflowed onto the month row. The
//   header style is sized here from the widest date the header can show,
//   measured in the real font, so it never wraps, is never cut and never
//   leaves the header, at any text size.
// * Dates are written and read day first, as everywhere else in the app,
//   and the date field's label names the format (VISUAL-R11-01): the
//   picker runs with [AppMaterialLocalizations] whatever app hosts it.
//
// Every decision is taken from the room the dialog really has (the safe
// area it is laid out in) and the phone's text size, never from a list of
// known screens.
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../format/app_material_localizations.dart';

/// The text size the stock picker reads its scale factor from.
const double _scaleProbe = 14;

/// The stock dialog's portrait sizes at 1.0x (Material 3).
const Size _calendarDialog = Size(360, 568);
const Size _inputDialog = Size(328, 270);

/// The stock calendar's layout: 12 dp at each side of the day grid, a
/// 52 dp month row above it and six week rows plus the weekday row.
const double _gridSidePadding = 12;
const double _monthRowHeight = 52;
const int _gridRows = 7;

/// The stock header: 120 dp tall in portrait at up to 1.3x, its content
/// 24 dp from the start, 12 dp from the end and the bottom, 16 dp from
/// the top; 152 dp wide in landscape with 16 dp at each side.
const double _headerHeight = 120;
const double _headerHorizontal = 24 + 12;
const double _headerVertical = 16 + 12;
const double _landscapeHeaderText = 152 - 2 * 16;

/// The stock header clamps its text to these scales (with and without the
/// entry mode button), and lets the title take two lines in portrait once
/// its scaled size passes 70.
const double _headerScaleWithButton = 1.4;
const double _headerScale = 1.6;
const double _singleLineLimit = 70;

/// The stock action row (Cancel, OK) is at least 52 dp tall.
const double _actionsMinHeight = 52;

/// How the editors' date picker is laid out on this screen.
@immutable
class EntryDatePickerLayout {
  const EntryDatePickerLayout({
    required this.entryMode,
    required this.orientation,
    required this.insetPadding,
    required this.headlineSize,
  });

  /// [DatePickerEntryMode.calendar] where every day can be a full tap
  /// target, otherwise [DatePickerEntryMode.inputOnly].
  final DatePickerEntryMode entryMode;

  /// The layout the dialog takes: portrait for the calendar, whatever the
  /// phone's orientation, since only the portrait calendar has 48 dp rows.
  final Orientation orientation;

  /// The room left around the dialog.
  final EdgeInsets insetPadding;

  /// The font size of the chosen date in the header, before text scaling.
  final double headlineSize;

  bool get calendar => entryMode == DatePickerEntryMode.calendar;
}

/// The phone's text scale as the stock picker reads it.
double _scaleOf(TextScaler s) => s.scale(_scaleProbe) / _scaleProbe;

/// Lays out the picker for a dialog that may use [room] (the safe area)
/// with the text at [textScaler]. [headline] is the header style before
/// sizing, [help] the style of "Select date", and [widestTitleAt] the
/// width of the widest date the header can show at a font size of 1.
EntryDatePickerLayout entryDatePickerLayout({
  required Size room,
  required Orientation orientation,
  required TextScaler textScaler,
  required TextStyle headline,
  required TextStyle help,
  required double widestTitleAt1,
}) {
  final scale = _scaleOf(textScaler);
  // The stock dialog grows with the text up to 3.0x.
  final dialogScale = math.min(scale, 3.0);
  final calendarWidth = math.min(
    _calendarDialog.width * dialogScale,
    room.width,
  );
  final calendarHeight = math.min(
    _calendarDialog.height * dialogScale,
    room.height,
  );
  final withButton = math.min(scale, _headerScaleWithButton);
  final cellWidth =
      (calendarWidth - 2 * _gridSidePadding) / DateTime.daysPerWeek;
  // The rows get what the dialog has left under the header and over the
  // actions; the stock grid shares it out evenly over seven rows.
  final gridHeight =
      calendarHeight -
      _portraitHeaderHeight(withButton) -
      _actionsHeight(scale) -
      _monthRowHeight;
  final cellHeight = gridHeight / _gridRows;
  final calendar =
      cellWidth >= kMinInteractiveDimension &&
      cellHeight >= kMinInteractiveDimension;

  final headerScale = calendar ? withButton : math.min(scale, _headerScale);
  final base = headline.fontSize ?? 24;
  final lineHeight = headline.height ?? 1.2;
  final portrait = calendar || orientation == Orientation.portrait;
  double size;
  if (portrait) {
    // The calendar can switch to input mode, whose dialog is narrower:
    // the header must fit both.
    final dialogWidth = math.min(_inputDialog.width * dialogScale, room.width);
    final textWidth =
        dialogWidth -
        _headerHorizontal -
        (calendar ? kMinInteractiveDimension : 0);
    // One line, as wide as the header has room for (5% to spare for the
    // dates not measured, a digit or two wider) ...
    size = 0.95 * textWidth / (widestTitleAt1 * headerScale);
    // ... that the stock header keeps on one line ...
    size = math.min(size, (_singleLineLimit - 0.5) / scale);
    // ... and that fits under "Select date" in the header's height.
    final helpHeight =
        (help.fontSize ?? 14) *
        (help.height ?? 1.4) *
        math.min(headerScale, _headerScale);
    final rowRoom =
        _portraitHeaderHeight(headerScale) - _headerVertical - helpHeight;
    size = math.min(size, rowRoom / (lineHeight * headerScale));
  } else {
    // Landscape: a 120 dp wide column that wraps the date onto two lines.
    size = 0.95 * 2 * _landscapeHeaderText / (widestTitleAt1 * headerScale);
  }
  return EntryDatePickerLayout(
    entryMode: calendar
        ? DatePickerEntryMode.calendar
        : DatePickerEntryMode.inputOnly,
    orientation: portrait ? Orientation.portrait : Orientation.landscape,
    insetPadding: EdgeInsets.zero,
    headlineSize: math.min(base, size),
  );
}

/// The stock portrait header's height at the header text scale [s].
double _portraitHeaderHeight(double s) =>
    _headerHeight * (s > 1.3 ? s - 0.2 : 1.0);

/// The stock action row's height at the text scale [s]: the 52 dp minimum
/// or a 48 dp padded button around a label that has grown past it.
double _actionsHeight(double s) =>
    math.max(_actionsMinHeight, 20 * math.min(s, 3.0) + 32);

/// The widest date the header can show, at a font size of 1: every
/// weekday in every month with a two-digit day, in the header's font.
double widestEntryDateTitle(
  MaterialLocalizations l,
  TextStyle style,
  TextDirection direction,
) {
  var widest = 0.0;
  final painter = TextPainter(
    textDirection: direction,
    textScaler: TextScaler.noScaling,
    maxLines: 1,
  );
  final probe = style.copyWith(fontSize: 100);
  for (var m = 1; m <= 12; m++) {
    for (var d = 22; d <= 28; d++) {
      painter.text = TextSpan(
        text: l.formatMediumDate(DateTime(2026, m, d)),
        style: probe,
      );
      painter.layout();
      widest = math.max(widest, painter.width);
    }
  }
  painter.dispose();
  return widest / 100;
}

/// Opens the editors' date picker on [initialDate] in [firstDate] to
/// [lastDate].
Future<DateTime?> showEntryDatePicker(
  BuildContext context, {
  required DateTime initialDate,
  required DateTime firstDate,
  required DateTime lastDate,
}) {
  return showDialog<DateTime>(
    context: context,
    builder: (_) => EntryDatePicker(
      initialDate: initialDate,
      firstDate: firstDate,
      lastDate: lastDate,
    ),
  );
}

/// The stock [DatePickerDialog] in the layout [entryDatePickerLayout]
/// chooses for the room it is given.
class EntryDatePicker extends StatelessWidget {
  const EntryDatePicker({
    super.key,
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
  });

  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  Widget build(BuildContext context) => Localizations.override(
    context: context,
    delegates: const [AppMaterialLocalizations.delegate],
    child: Builder(builder: _build),
  );

  Widget _build(BuildContext context) {
    final theme = Theme.of(context);
    final headline = theme.textTheme.headlineSmall ?? const TextStyle();
    final help = theme.textTheme.labelLarge ?? const TextStyle();
    final widest = widestEntryDateTitle(
      MaterialLocalizations.of(context),
      headline,
      Directionality.of(context),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final layout = entryDatePickerLayout(
          room: constraints.biggest,
          orientation: MediaQuery.orientationOf(context),
          textScaler: MediaQuery.textScalerOf(context),
          headline: headline,
          help: help,
          widestTitleAt1: widest,
        );
        final style = headline.copyWith(fontSize: layout.headlineSize);
        // The stock dialog reads its orientation from the screen's shape
        // and nothing else from its size: a calendar on a wide screen
        // takes the portrait layout by being told the screen is tall.
        final mq = MediaQuery.of(context);
        final shape = layout.orientation == mq.orientation
            ? mq
            : mq.copyWith(size: mq.size.flipped);
        final dialog = Theme(
          data: theme.copyWith(
            datePickerTheme: theme.datePickerTheme.copyWith(
              headerHeadlineStyle: style,
            ),
            // The stock landscape input header takes headlineSmall.
            textTheme: theme.textTheme.copyWith(headlineSmall: style),
            // The stock field lets the app's field theme override the
            // picker's; the picker's is the one meant for its surface.
            inputDecorationTheme:
                theme.datePickerTheme.inputDecorationTheme ??
                theme.inputDecorationTheme,
          ),
          child: DatePickerDialog(
            initialDate: initialDate,
            firstDate: firstDate,
            lastDate: lastDate,
            initialEntryMode: layout.entryMode,
            insetPadding: layout.insetPadding,
          ),
        );
        return MediaQuery(data: shape, child: dialog);
      },
    );
  }
}
