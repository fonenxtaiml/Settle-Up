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
// * The year list opens on the selected year at every text size
//   (VISUAL-R13-01). The stock [YearPicker] places its list from three
//   columns of 52 dp rows, but its own grid lays the rows out taller with
//   the text and in two columns past 1.65x, so above 1.0x the list opened
//   rows (for a far date, thousands of years) away from the year. The
//   picker's year list is placed here from the grid's real layout, read
//   from the list's own grid delegate, before its first frame.
//
// Every decision is taken from the room the dialog really has (the safe
// area it is laid out in) and the phone's text size, never from a list of
// known screens.
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

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
        return MediaQuery(
          data: shape,
          child: ScrollConfiguration(
            behavior: YearListScrollBehavior(ScrollConfiguration.of(context)),
            child: dialog,
          ),
        );
      },
    );
  }
}

/// The scroll offset that opens a [YearPicker]'s list on its selected year.
///
/// [grid] is the list's own grid layout for a viewport [viewport] dp tall,
/// [padding] its main axis padding before and after the grid and
/// [childCount] the number of tiles. The selected tile's row is put two
/// rows below the top, as the stock picker means to (at 1.0x this is the
/// stock offset), or centred when the list is too short for that, and the
/// offset stays inside the list, so it never springs back.
double yearListOffset({
  required SliverGridLayout grid,
  required int index,
  required int childCount,
  required double viewport,
  double paddingBefore = 0,
  double paddingAfter = 0,
}) {
  if (childCount <= 0) return 0;
  final i = index.clamp(0, childCount - 1);
  final tile = grid.getGeometryForChildIndex(i);
  final top = paddingBefore + tile.scrollOffset;
  final lead = math.min(
    2 * tile.mainAxisExtent,
    math.max(0.0, (viewport - tile.mainAxisExtent) / 2),
  );
  final content =
      paddingBefore + grid.computeMaxScrollOffset(childCount) + paddingAfter;
  final max = math.max(0.0, content - viewport);
  return (top - lead).clamp(0.0, max);
}

/// The index of [YearPicker]'s tile for its selected year, as the stock
/// picker builds its tiles (short ranges are padded with disabled years).
int yearPickerIndex(YearPicker picker) {
  const minYears = 18;
  final count = picker.lastDate.year - picker.firstDate.year + 1;
  final backfill = count < minYears ? (minYears - count) ~/ 2 : 0;
  final year = (picker.selectedDate ?? picker.firstDate).year;
  return year - picker.firstDate.year + backfill;
}

/// The scroll behavior of the editors' date picker: [parent]'s, except
/// that a [YearPicker]'s list is placed on its selected year before its
/// first frame (VISUAL-R13-01), and again if the selected year changes.
class YearListScrollBehavior extends ScrollBehavior {
  const YearListScrollBehavior(this.parent);

  /// The behavior every other scrollable in the dialog keeps.
  final ScrollBehavior parent;

  /// The year each year list was last placed on.
  static final Expando<int> _placed = Expando<int>('yearListPlaced');

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    final controller = details.controller;
    final picker = context.findAncestorWidgetOfExactType<YearPicker>();
    final grid = context.findAncestorWidgetOfExactType<GridView>();
    if (controller != null &&
        picker != null &&
        grid != null &&
        identical(grid.controller, controller) &&
        axisDirectionToAxis(details.direction) == Axis.vertical) {
      final direction = Directionality.maybeOf(context) ?? TextDirection.ltr;
      final list = child;
      return parent.buildScrollbar(
        context,
        LayoutBuilder(
          builder: (context, constraints) {
            _place(controller, picker, grid, constraints, direction);
            return list;
          },
        ),
        details,
      );
    }
    return parent.buildScrollbar(context, child, details);
  }

  /// Places [controller]'s list, laid out in [constraints], on [picker]'s
  /// selected year unless it is already placed there. Runs in the layout
  /// before the list's own, so the first frame shows the year.
  static void _place(
    ScrollController controller,
    YearPicker picker,
    GridView grid,
    BoxConstraints constraints,
    TextDirection direction,
  ) {
    if (!controller.hasClients || controller.positions.length != 1) return;
    final position = controller.position;
    final year = (picker.selectedDate ?? picker.firstDate).year;
    if (_placed[position] == year) return;
    final count = grid.childrenDelegate.estimatedChildCount;
    if (count == null ||
        !constraints.hasBoundedHeight ||
        !constraints.hasBoundedWidth) {
      return;
    }
    final padding = (grid.padding ?? EdgeInsets.zero).resolve(direction);
    final viewport = constraints.maxHeight;
    final cross = math.max(0.0, constraints.maxWidth - padding.horizontal);
    final layout = grid.gridDelegate.getLayout(
      SliverConstraints(
        axisDirection: AxisDirection.down,
        growthDirection: GrowthDirection.forward,
        userScrollDirection: ScrollDirection.idle,
        scrollOffset: 0,
        precedingScrollExtent: 0,
        overlap: 0,
        remainingPaintExtent: viewport,
        crossAxisExtent: cross,
        crossAxisDirection: direction == TextDirection.rtl
            ? AxisDirection.left
            : AxisDirection.right,
        viewportMainAxisExtent: viewport,
        remainingCacheExtent: viewport,
        cacheOrigin: 0,
      ),
    );
    _placed[position] = year;
    position.correctPixels(
      yearListOffset(
        grid: layout,
        index: yearPickerIndex(picker),
        childCount: count,
        viewport: viewport,
        paddingBefore: padding.top,
        paddingAfter: padding.bottom,
      ),
    );
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) => parent.buildOverscrollIndicator(context, child, details);

  @override
  Set<PointerDeviceKind> get dragDevices => parent.dragDevices;

  @override
  Set<LogicalKeyboardKey> get pointerAxisModifiers =>
      parent.pointerAxisModifiers;

  @override
  MultitouchDragStrategy getMultitouchDragStrategy(BuildContext context) =>
      parent.getMultitouchDragStrategy(context);

  @override
  TargetPlatform getPlatform(BuildContext context) =>
      parent.getPlatform(context);

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      parent.getScrollPhysics(context);

  @override
  ScrollViewKeyboardDismissBehavior getKeyboardDismissBehavior(
    BuildContext context,
  ) => parent.getKeyboardDismissBehavior(context);

  @override
  GestureVelocityTrackerBuilder velocityTrackerBuilder(BuildContext context) =>
      parent.velocityTrackerBuilder(context);

  @override
  bool shouldNotify(covariant YearListScrollBehavior oldDelegate) =>
      parent.runtimeType != oldDelegate.parent.runtimeType ||
      parent.shouldNotify(oldDelegate.parent);
}
