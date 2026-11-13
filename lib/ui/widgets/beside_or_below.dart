import 'dart:math' as math;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';

/// A row's text with its trailing block (a button, a switch, a value or an
/// amount) beside it while the text keeps room for its widest word, and
/// under it, end-aligned, when it would not: the text column is never
/// narrower than a word, so a label or help is never broken mid-word
/// ("Blu/eto/oth") nor squeezed to a sliver beside a button
/// (VISUAL-R32-02). The choice is made at layout time from the real widths
/// of the children, so it holds for every text, font, text scale, phone
/// width and trailing block, not only the ones a caller measured.
///
/// [leading] (an avatar or icon) sits before both, centred beside the
/// text, or by the title when the trailing block goes under the text.
/// [below] puts [trailing] under the text whatever the room (large text).
/// [minMainWidth] and [minMainFraction] (of the room after [leading]) are
/// the least width the text keeps beside [trailing], on top of its widest
/// word: rows whose text wraps in full keep 96 dp and half the row, so a
/// help line never runs down a sliver beside a button.
/// [trailingWidth], when given, is the trailing block's natural width as
/// its owner measured it (an amount that scales down when stacked);
/// otherwise its intrinsic width is used.
class BesideOrBelow extends MultiChildRenderObjectWidget {
  BesideOrBelow({
    super.key,
    Widget? leading,
    required Widget main,
    Widget? trailing,
    this.leadingGap = 14,
    this.gap = 12,
    this.spacing = 4,
    this.below = false,
    this.minMainWidth = 0,
    this.minMainFraction = 0,
    this.trailingWidth,
  }) : hasLeading = leading != null,
       hasTrailing = trailing != null,
       super(children: [?leading, main, ?trailing]);

  final bool hasLeading;
  final bool hasTrailing;

  /// Between [leading] and the text.
  final double leadingGap;

  /// Between the text and the trailing block beside it.
  final double gap;

  /// Between the text and the trailing block under it.
  final double spacing;

  final bool below;
  final double minMainWidth;
  final double minMainFraction;
  final double? trailingWidth;

  @override
  RenderBesideOrBelow createRenderObject(BuildContext context) =>
      RenderBesideOrBelow(
        hasLeading: hasLeading,
        hasTrailing: hasTrailing,
        leadingGap: leadingGap,
        gap: gap,
        spacing: spacing,
        below: below,
        minMainWidth: minMainWidth,
        minMainFraction: minMainFraction,
        trailingWidth: trailingWidth,
        textDirection: Directionality.maybeOf(context) ?? TextDirection.ltr,
      );

  @override
  void updateRenderObject(
    BuildContext context,
    RenderBesideOrBelow renderObject,
  ) {
    renderObject
      ..hasLeading = hasLeading
      ..hasTrailing = hasTrailing
      ..leadingGap = leadingGap
      ..gap = gap
      ..spacing = spacing
      ..below = below
      ..minMainWidth = minMainWidth
      ..minMainFraction = minMainFraction
      ..trailingWidth = trailingWidth
      ..textDirection = Directionality.maybeOf(context) ?? TextDirection.ltr;
  }
}

class _Data extends ContainerBoxParentData<RenderBox> {}

typedef _Layouter = Size Function(RenderBox child, BoxConstraints c);

typedef _Placement = ({
  Size size,
  Offset leading,
  Offset main,
  Offset trailing,
  bool beside,
  BoxConstraints mainConstraints,
});

/// The render object of [BesideOrBelow].
class RenderBesideOrBelow extends RenderBox
    with
        ContainerRenderObjectMixin<RenderBox, _Data>,
        RenderBoxContainerDefaultsMixin<RenderBox, _Data> {
  RenderBesideOrBelow({
    required this._hasLeading,
    required this._hasTrailing,
    required this._leadingGap,
    required this._gap,
    required this._spacing,
    required this._below,
    required this._minMainWidth,
    required this._minMainFraction,
    required this._trailingWidth,
    required this._textDirection,
  });

  bool _hasLeading;
  set hasLeading(bool v) {
    if (v == _hasLeading) return;
    _hasLeading = v;
    markNeedsLayout();
  }

  bool _hasTrailing;
  set hasTrailing(bool v) {
    if (v == _hasTrailing) return;
    _hasTrailing = v;
    markNeedsLayout();
  }

  double _leadingGap;
  set leadingGap(double v) {
    if (v == _leadingGap) return;
    _leadingGap = v;
    markNeedsLayout();
  }

  double _gap;
  set gap(double v) {
    if (v == _gap) return;
    _gap = v;
    markNeedsLayout();
  }

  double _spacing;
  set spacing(double v) {
    if (v == _spacing) return;
    _spacing = v;
    markNeedsLayout();
  }

  bool _below;
  set below(bool v) {
    if (v == _below) return;
    _below = v;
    markNeedsLayout();
  }

  double _minMainWidth;
  set minMainWidth(double v) {
    if (v == _minMainWidth) return;
    _minMainWidth = v;
    markNeedsLayout();
  }

  double _minMainFraction;
  set minMainFraction(double v) {
    if (v == _minMainFraction) return;
    _minMainFraction = v;
    markNeedsLayout();
  }

  double? _trailingWidth;
  set trailingWidth(double? v) {
    if (v == _trailingWidth) return;
    _trailingWidth = v;
    markNeedsLayout();
  }

  TextDirection _textDirection;
  set textDirection(TextDirection v) {
    if (v == _textDirection) return;
    _textDirection = v;
    markNeedsLayout();
  }

  /// Whether the trailing block sat beside the text at the last layout.
  bool get trailingBeside => _beside;
  bool _beside = true;

  RenderBox? get _leading => _hasLeading ? firstChild : null;
  RenderBox get _main => _hasLeading ? childAfter(firstChild!)! : firstChild!;
  RenderBox? get _trailing => _hasTrailing ? lastChild : null;

  @override
  void setupParentData(RenderBox child) {
    if (child.parentData is! _Data) child.parentData = _Data();
  }

  double _trailingNatural(RenderBox t) =>
      _trailingWidth ?? t.getMaxIntrinsicWidth(double.infinity);

  double get _leadingNatural =>
      _leading == null ? 0 : _leading!.getMaxIntrinsicWidth(double.infinity);

  double get _naturalWidth {
    final t = _trailing;
    return (_leading == null ? 0 : _leadingNatural + _leadingGap) +
        _main.getMaxIntrinsicWidth(double.infinity) +
        (t == null ? 0 : _gap + _trailingNatural(t));
  }

  _Placement _place(BoxConstraints c, _Layouter layout) {
    final width = c.hasBoundedWidth
        ? c.maxWidth
        : c.constrainWidth(_naturalWidth);
    final leading = _leading;
    final main = _main;
    final trailing = _trailing;
    final ls = leading == null
        ? Size.zero
        : layout(leading, BoxConstraints(maxWidth: width));
    final x0 = leading == null ? 0.0 : ls.width + _leadingGap;
    final room = math.max(0.0, width - x0);
    var beside = true;
    var ts = Size.zero;
    if (trailing != null && _below) {
      beside = false;
    } else if (trailing != null) {
      // The trailing block's real size beside the text (a switch or a
      // button reports no reliable intrinsic width), or the width its
      // owner measured.
      final besideConstraints = BoxConstraints(
        maxWidth: math.max(0.0, room - _gap),
      );
      ts = layout(trailing, besideConstraints);
      final need = [
        main.getMinIntrinsicWidth(double.infinity),
        _minMainWidth,
        room * _minMainFraction,
      ].reduce(math.max);
      final tw = math.max(ts.width, _trailingWidth ?? 0);
      beside = room - _gap - tw + 0.5 >= need;
    }
    if (trailing != null && !beside) {
      ts = layout(trailing, BoxConstraints(maxWidth: room));
    }
    final mainWidth = trailing != null && beside
        ? math.max(0.0, room - _gap - ts.width)
        : room;
    final mc = BoxConstraints.tightFor(width: mainWidth);
    final ms = layout(main, mc);
    final stacked = trailing != null && !beside;
    final contentHeight = stacked
        ? math.max(ls.height, ms.height + _spacing + ts.height)
        : [ls.height, ms.height, ts.height].reduce(math.max);
    final size = c.constrain(Size(width, contentHeight));
    double x(double left, double w) =>
        _textDirection == TextDirection.rtl ? width - left - w : left;
    double centre(double h) => (size.height - h) / 2;
    return (
      size: size,
      beside: beside,
      mainConstraints: mc,
      leading: Offset(x(0, ls.width), stacked ? 0 : centre(ls.height)),
      main: Offset(x(x0, mainWidth), stacked ? 0 : centre(ms.height)),
      trailing: Offset(
        x(width - ts.width, ts.width),
        stacked ? ms.height + _spacing : centre(ts.height),
      ),
    );
  }

  static Size _dry(RenderBox child, BoxConstraints c) => child.getDryLayout(c);

  static Size _wet(RenderBox child, BoxConstraints c) {
    child.layout(c, parentUsesSize: true);
    return child.size;
  }

  @override
  void performLayout() {
    final p = _place(constraints, _wet);
    size = p.size;
    _beside = p.beside;
    (_main.parentData! as _Data).offset = p.main;
    if (_leading case final l?) (l.parentData! as _Data).offset = p.leading;
    if (_trailing case final t?) (t.parentData! as _Data).offset = p.trailing;
  }

  @override
  Size computeDryLayout(covariant BoxConstraints constraints) =>
      _place(constraints, _dry).size;

  @override
  double? computeDryBaseline(
    covariant BoxConstraints constraints,
    TextBaseline baseline,
  ) {
    final p = _place(constraints, _dry);
    final d = _main.getDryBaseline(p.mainConstraints, baseline);
    return d == null ? null : d + p.main.dy;
  }

  @override
  double? computeDistanceToActualBaseline(TextBaseline baseline) {
    final main = _main;
    final d = main.getDistanceToActualBaseline(baseline);
    return d == null ? null : d + (main.parentData! as _Data).offset.dy;
  }

  @override
  double computeMinIntrinsicWidth(double height) {
    final t = _trailing;
    final mainMin = _main.getMinIntrinsicWidth(double.infinity);
    return (_leading == null ? 0 : _leadingNatural + _leadingGap) +
        math.max(
          mainMin,
          t == null ? 0 : t.getMinIntrinsicWidth(double.infinity),
        );
  }

  @override
  double computeMaxIntrinsicWidth(double height) => _naturalWidth;

  double _heightFor(double width) => _place(
    width.isFinite ? BoxConstraints(maxWidth: width) : const BoxConstraints(),
    _dry,
  ).size.height;

  @override
  double computeMinIntrinsicHeight(double width) => _heightFor(width);

  @override
  double computeMaxIntrinsicHeight(double width) => _heightFor(width);

  @override
  void paint(PaintingContext context, Offset offset) =>
      defaultPaint(context, offset);

  @override
  bool hitTestChildren(BoxHitTestResult result, {required Offset position}) =>
      defaultHitTestChildren(result, position: position);
}
