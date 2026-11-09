// The tether (DESIGN.md "Components", direction doc "Signature element"):
// two points joined by a line. A filled point is you or this phone, a ring
// is the other party. One chevron near the receiving end shows which way
// money (or data) moves. Dashed means suggested or waiting, solid means
// recorded or connected, a slack line with no chevron means settled.
//
// One painter ([TetherPainter]) draws every size:
//   [TetherGlyph]     inline 26 x 10 before direction words
//   [TetherTransfer]  avatar to avatar, suggested payments
//   [SettleTether]    the Settle up hero, amount riding on the line
//   [SyncTether]      this phone to nearby phones on Sync
import 'dart:math' as math;
import 'dart:ui' show PathMetric;

import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../format/money_format.dart';
import 'kit_layout.dart';
import 'kit_strings.dart';
import 'person_avatar.dart';

/// An end of the tether.
enum TetherPoint {
  /// You, or this phone.
  filled,

  /// The other party.
  ring,

  /// No point drawn: an avatar or icon sits at that end instead.
  none,
}

/// How the line between the two points is drawn.
enum TetherLine {
  /// Recorded or connected. Has a chevron.
  solid,

  /// Suggested or waiting. Has a chevron.
  dashed,

  /// Settled: plain line, no chevron.
  slack,
}

/// Paints a tether into its box. Points sit at the left and right ends,
/// vertically centred; money always moves left to right (flipped by the
/// widgets for right-to-left text).
class TetherPainter extends CustomPainter {
  const TetherPainter({
    required this.from,
    required this.to,
    required this.color,
    this.line = TetherLine.solid,
    this.strokeWidth = 1.5,
    this.pointRadius = 3.5,
    this.chevronHalfHeight = 2.8,
    this.chevronTipFromEnd,
    this.lineEndInset = 0,
    this.lineStartOvershoot = 0,
    this.dash = const [3, 4],
    this.chevronStrokeWidth,
  });

  final TetherPoint from;
  final TetherPoint to;
  final Color color;
  final TetherLine line;
  final double strokeWidth;

  /// Radius of a filled point. A ring is drawn a quarter pixel smaller so
  /// both read as the same size.
  final double pointRadius;

  /// Half the chevron's height; its depth is 1:1 with this.
  final double chevronHalfHeight;

  /// Distance from the right edge of the box to the chevron tip. Null puts
  /// the tip 71 % along the line, as in the inline glyph.
  final double? chevronTipFromEnd;

  /// Gap between the end of the line and the right edge when no point is
  /// drawn there (the chevron then reaches past the line end).
  final double lineEndInset;

  /// Extra length drawn to the left of the box when no point is drawn.
  final double lineStartOvershoot;

  /// Dash on/off lengths for [TetherLine.dashed].
  final List<double> dash;

  final double? chevronStrokeWidth;

  double get _pointInset => pointRadius + 0.5;

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2;
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokeWidth
      ..strokeCap = StrokeCap.butt;
    final fill = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final fromX = _pointInset;
    final toX = size.width - _pointInset;
    final start = from == TetherPoint.none
        ? -lineStartOvershoot
        : fromX + pointRadius;
    final end = to == TetherPoint.none
        ? size.width - lineEndInset
        : toX - pointRadius;

    if (end > start) {
      final path = Path()
        ..moveTo(start, cy)
        ..lineTo(end, cy);
      if (line == TetherLine.dashed) {
        canvas.drawPath(_dashed(path), stroke);
      } else {
        canvas.drawPath(path, stroke);
      }
    }

    _point(canvas, from, Offset(fromX, cy), stroke, fill);
    _point(canvas, to, Offset(toX, cy), stroke, fill);

    if (line != TetherLine.slack && end > start) {
      final tip = chevronTipFromEnd == null
          ? start + (end - start) * 0.71
          : size.width - chevronTipFromEnd!;
      final h = chevronHalfHeight;
      final chevron = Path()
        ..moveTo(tip - h, cy - h)
        ..lineTo(tip, cy)
        ..lineTo(tip - h, cy + h);
      canvas.drawPath(
        chevron,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = chevronStrokeWidth ?? strokeWidth
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round,
      );
    }
  }

  void _point(Canvas c, TetherPoint p, Offset o, Paint stroke, Paint fill) {
    switch (p) {
      case TetherPoint.filled:
        c.drawCircle(o, pointRadius, fill);
      case TetherPoint.ring:
        c.drawCircle(o, pointRadius - 0.25, stroke);
      case TetherPoint.none:
        break;
    }
  }

  Path _dashed(Path source) {
    final out = Path();
    for (final PathMetric m in source.computeMetrics()) {
      var d = 0.0;
      var i = 0;
      while (d < m.length) {
        final len = dash[i % dash.length];
        if (i.isEven) {
          out.addPath(
            m.extractPath(d, math.min(d + len, m.length)),
            Offset.zero,
          );
        }
        d += len;
        i++;
      }
    }
    return out;
  }

  @override
  bool shouldRepaint(TetherPainter old) =>
      old.from != from ||
      old.to != to ||
      old.color != color ||
      old.line != line ||
      old.strokeWidth != strokeWidth ||
      old.pointRadius != pointRadius ||
      old.chevronHalfHeight != chevronHalfHeight ||
      old.chevronTipFromEnd != chevronTipFromEnd ||
      old.lineEndInset != lineEndInset ||
      old.lineStartOvershoot != lineStartOvershoot ||
      old.chevronStrokeWidth != chevronStrokeWidth;
}

/// Flips its child horizontally in right-to-left text, so money still
/// travels in reading direction.
class _ReadingDirection extends StatelessWidget {
  const _ReadingDirection({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (Directionality.of(context) == TextDirection.ltr) return child;
    return Transform.flip(flipX: true, child: child);
  }
}

/// Inline tether glyph (26 x 10 at text scale 1) placed before a direction
/// word. ○→● money comes to you, ●→○ you pay, ○–○ settled.
///
/// Decorative by default (the word next to it says the same); pass
/// [semanticLabel] when it stands alone, for example as a row's leading
/// icon.
class TetherGlyph extends StatelessWidget {
  const TetherGlyph({
    super.key,
    required this.direction,
    this.color,
    this.semanticLabel,
    this.scale = 1,
  });

  /// [MoneyDirection.neutral] draws ring to ring with a chevron (a payment
  /// between two other people).
  final MoneyDirection direction;

  /// Defaults to the inherited text colour.
  final Color? color;
  final String? semanticLabel;

  /// Multiplies the 26 x 10 box. The glyph follows the text scale up to
  /// 1.5x so it stays in proportion with the word beside it.
  final double scale;

  @override
  Widget build(BuildContext context) {
    final textScale = MediaQuery.textScalerOf(context).scale(1).clamp(1, 1.5);
    final s = scale * textScale;
    final (from, to, line) = switch (direction) {
      MoneyDirection.owed => (
        TetherPoint.ring,
        TetherPoint.filled,
        TetherLine.solid,
      ),
      MoneyDirection.owe => (
        TetherPoint.filled,
        TetherPoint.ring,
        TetherLine.solid,
      ),
      MoneyDirection.settled => (
        TetherPoint.ring,
        TetherPoint.ring,
        TetherLine.slack,
      ),
      MoneyDirection.neutral => (
        TetherPoint.ring,
        TetherPoint.ring,
        TetherLine.solid,
      ),
    };
    final paint = CustomPaint(
      size: Size(Sizes.tetherInline.width * s, Sizes.tetherInline.height * s),
      painter: TetherPainter(
        from: from,
        to: to,
        line: line,
        color: color ?? DefaultTextStyle.of(context).style.color!,
        strokeWidth: 1.5 * s,
        pointRadius: 3.5 * s,
        chevronHalfHeight: 2.8 * s,
      ),
    );
    final glyph = _ReadingDirection(child: paint);
    if (semanticLabel == null) return ExcludeSemantics(child: glyph);
    return Semantics(label: semanticLabel, image: true, child: glyph);
  }
}

/// Avatar to avatar transfer (suggested payments): 32 dp avatar, 56 dp
/// dashed line with a chevron, 32 dp avatar. You are always the filled
/// avatar; everyone else is a ring.
class TetherTransfer extends StatelessWidget {
  const TetherTransfer({
    super.key,
    required this.fromId,
    required this.fromName,
    required this.toId,
    required this.toName,
    this.fromIsMe = false,
    this.toIsMe = false,
    this.line = TetherLine.dashed,
    this.lineLength = Sizes.tetherRowLine,
  });

  final String fromId;
  final String fromName;
  final String toId;
  final String toName;
  final bool fromIsMe;
  final bool toIsMe;
  final TetherLine line;
  final double lineLength;

  @override
  Widget build(BuildContext context) {
    final ink = Theme.of(context).colorScheme.onSurface;
    final from = fromIsMe ? KitStrings.you : KitStrings.firstName(fromName);
    final to = toIsMe ? 'you' : KitStrings.firstName(toName);
    return Semantics(
      label: KitStrings.pays(from, to),
      container: true,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PersonAvatar(
            id: fromId,
            name: fromName,
            size: Sizes.avatarSmall,
            isMe: fromIsMe,
            ring: !fromIsMe,
          ),
          _ReadingDirection(
            child: CustomPaint(
              size: Size(lineLength, 10),
              painter: TetherPainter(
                from: TetherPoint.none,
                to: TetherPoint.none,
                line: line,
                color: ink,
                chevronHalfHeight: 3.5,
                chevronStrokeWidth: 1.6,
                chevronTipFromEnd: 3,
                lineEndInset: 5,
              ),
            ),
          ),
          PersonAvatar(
            id: toId,
            name: toName,
            size: Sizes.avatarSmall,
            isMe: toIsMe,
            ring: !toIsMe,
          ),
        ],
      ),
    );
  }
}

/// The Settle up hero: a 56 dp avatar for the payer, a full-width solid
/// line in the direction colour with a chevron, a 56 dp ring for the
/// receiver, and the amount riding on the line.
///
/// Set [recorded] to true when the payment is saved: a 6 dp ink dot leaves
/// the payer and travels to the receiver (280 ms), then the ring fills
/// (120 ms). With reduce motion on, only the fill plays.
class SettleTether extends StatefulWidget {
  const SettleTether({
    super.key,
    required this.fromId,
    required this.fromName,
    required this.toId,
    required this.toName,
    required this.amountMinor,
    required this.currency,
    this.fromIsMe = false,
    this.toIsMe = false,
    this.question,
    this.fromLabel,
    this.toLabel,
    this.action,
    this.recorded = false,
    this.onRecordedAnimationEnd,
  });

  final String fromId;
  final String fromName;
  final String toId;
  final String toName;
  final int amountMinor; // > 0, the amount being paid
  final String currency;
  final bool fromIsMe;
  final bool toIsMe;

  /// Line above the stage, for example "You pay Priya".
  final String? question;

  /// Names under the avatars; default "You" / the person's name.
  final String? fromLabel;
  final String? toLabel;

  /// Shown centred under the stage, for example a "Pay part of it" link.
  final Widget? action;

  final bool recorded;
  final VoidCallback? onRecordedAnimationEnd;

  @override
  State<SettleTether> createState() => _SettleTetherState();
}

class _SettleTetherState extends State<SettleTether>
    with TickerProviderStateMixin {
  late final AnimationController _travel = AnimationController(
    vsync: this,
    duration: Motion.travel,
  );
  late final AnimationController _fill = AnimationController(
    vsync: this,
    duration: Motion.fill,
    value: widget.recorded ? 1 : 0,
  );

  @override
  void didUpdateWidget(SettleTether old) {
    super.didUpdateWidget(old);
    if (widget.recorded && !old.recorded) _play();
    if (!widget.recorded && old.recorded) {
      _travel.value = 0;
      _fill.value = 0;
    }
  }

  Future<void> _play() async {
    final reduce = MediaQuery.disableAnimationsOf(context);
    if (!reduce) {
      await _travel
          .animateTo(1, curve: Motion.travelCurve)
          .orCancel
          .catchError((Object _) {});
    }
    if (!mounted) return;
    _fill.duration = reduce ? Motion.crossfade : Motion.fill;
    await _fill.forward().orCancel.catchError((Object _) {});
    if (mounted) widget.onRecordedAnimationEnd?.call();
  }

  @override
  void dispose() {
    _travel.dispose();
    _fill.dispose();
    super.dispose();
  }

  // The direction colour comes from the viewer: paying is Kiln, being paid
  // is Lagoon, a payment between two other people is ink.
  MoneyDirection get _direction => widget.fromIsMe
      ? MoneyDirection.owe
      : widget.toIsMe
      ? MoneyDirection.owed
      : MoneyDirection.neutral;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final color = context.money.forDirection(_direction);
    final scaler = MediaQuery.textScalerOf(context);
    final amountStyle = theme.textTheme.headlineLarge!.copyWith(color: color);
    final amount = MoneyFormat.format(widget.amountMinor, widget.currency);
    final fromLabel =
        widget.fromLabel ??
        (widget.fromIsMe ? KitStrings.you : widget.fromName);
    final toLabel =
        widget.toLabel ?? (widget.toIsMe ? KitStrings.you : widget.toName);
    final partyStyle = theme.textTheme.titleSmall!.copyWith(fontSize: 14);

    // The amount box overlaps the top 10 dp of the stage, as in render 4.
    final amountBox = scaler.scale(amountStyle.fontSize!) * amountStyle.height!;
    const overlap = 10.0;

    Widget party(String id, String name, String label, bool isMe, bool end) {
      final avatar = PersonAvatar(
        id: id,
        name: name,
        size: Sizes.avatarHero,
        isMe: isMe,
        ring: !isMe,
      );
      return SizedBox(
        width: 92,
        child: Column(
          children: [
            if (end)
              AnimatedBuilder(
                animation: _fill,
                builder: (context, child) => Stack(
                  alignment: Alignment.center,
                  children: [
                    child!,
                    if (_fill.value > 0)
                      Opacity(
                        opacity: _fill.value,
                        child: PersonAvatar(
                          id: id,
                          name: name,
                          size: Sizes.avatarHero,
                          isMe: true,
                        ),
                      ),
                  ],
                ),
                child: avatar,
              )
            else
              avatar,
            const SizedBox(height: Space.sm),
            Text(
              label,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: partyStyle,
            ),
          ],
        ),
      );
    }

    final wire = Expanded(
      child: SizedBox(
        height: Sizes.avatarHero,
        child: LayoutBuilder(
          builder: (context, c) => Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: -6,
                right: -6,
                top: 0,
                bottom: 0,
                child: _ReadingDirection(
                  child: CustomPaint(
                    painter: TetherPainter(
                      from: TetherPoint.none,
                      to: TetherPoint.none,
                      line: TetherLine.solid,
                      color: color,
                      strokeWidth: 2,
                      chevronHalfHeight: 7,
                      chevronTipFromEnd: 13,
                    ),
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: Sizes.avatarHero - overlap,
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(amount, maxLines: 1, style: amountStyle),
                  ),
                ),
              ),
              AnimatedBuilder(
                animation: _travel,
                builder: (context, _) {
                  if (_travel.value == 0 || _travel.value == 1) {
                    return const SizedBox.shrink();
                  }
                  final rtl = Directionality.of(context) == TextDirection.rtl;
                  final t = rtl ? 1 - _travel.value : _travel.value;
                  return Positioned(
                    left: -3,
                    top: Sizes.avatarHero / 2 - 3,
                    child: Transform.translate(
                      offset: Offset(t * c.maxWidth, 0),
                      child: SizedBox.square(
                        dimension: 6,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.onSurface,
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );

    final from = widget.fromIsMe
        ? KitStrings.you
        : KitStrings.firstName(widget.fromName);
    final to = widget.toIsMe ? 'you' : KitStrings.firstName(widget.toName);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          container: true,
          label:
              '${KitStrings.pays(from, to)} ${MoneyFormat.spoken(widget.amountMinor, widget.currency)}',
          excludeSemantics: true,
          child: Column(
            children: [
              if (widget.question != null) ...[
                Text(
                  widget.question!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall!
                      .withWeight(FontWeight.w500)
                      .copyWith(color: scheme.onSurfaceVariant),
                ),
                const SizedBox(height: 18),
              ],
              SizedBox(height: math.max(0, amountBox - overlap)),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  party(
                    widget.fromId,
                    widget.fromName,
                    fromLabel,
                    widget.fromIsMe,
                    false,
                  ),
                  wire,
                  party(
                    widget.toId,
                    widget.toName,
                    toLabel,
                    widget.toIsMe,
                    true,
                  ),
                ],
              ),
            ],
          ),
        ),
        if (widget.action != null) ...[
          const SizedBox(height: Space.xs),
          widget.action!,
        ],
      ],
    );
  }
}

/// "This phone → nearby phones" on Sync: a filled phone, a dashed line
/// with a chevron, and a ring of nearby phones. [connected] makes the line
/// solid; [active] sends small dots along it in both directions while a
/// session runs (skipped with reduce motion, paused by [TickerMode]).
class SyncTether extends StatefulWidget {
  const SyncTether({
    super.key,
    this.connected = false,
    this.active = false,
    this.thisPhoneLabel = KitStrings.thisPhone,
    this.otherLabel = KitStrings.nearbyPhones,
    this.semanticLabel,
  });

  final bool connected;
  final bool active;
  final String thisPhoneLabel;
  final String otherLabel;
  final String? semanticLabel;

  @override
  State<SyncTether> createState() => _SyncTetherState();
}

class _SyncTetherState extends State<SyncTether>
    with SingleTickerProviderStateMixin {
  late final AnimationController _loop = AnimationController(
    vsync: this,
    duration: Motion.syncLoop,
  );

  void _sync(bool reduce) {
    final run = widget.active && !reduce;
    if (run && !_loop.isAnimating) _loop.repeat();
    if (!run && _loop.isAnimating) _loop.stop();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync(MediaQuery.disableAnimationsOf(context));
  }

  @override
  void didUpdateWidget(SyncTether old) {
    super.didUpdateWidget(old);
    _sync(MediaQuery.disableAnimationsOf(context));
  }

  @override
  void dispose() {
    _loop.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final labelStyle = theme.textTheme.labelMedium!.copyWith(
      fontWeight: FontWeight.w600,
      color: scheme.onSurface,
    );
    final stacked = isLargeText(context);

    Widget end(IconData icon, bool me) => SizedBox.square(
      dimension: 32,
      child: DecoratedBox(
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: me ? scheme.primary : null,
          border: me ? null : Border.all(color: scheme.onSurface, width: 1.5),
        ),
        child: Icon(
          icon,
          size: 18,
          color: me ? scheme.onPrimary : scheme.onSurface,
        ),
      ),
    );

    final wire = Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: Space.sm),
        child: SizedBox(
          height: 10,
          child: ClipRect(
            child: LayoutBuilder(
              builder: (context, c) => Stack(
                children: [
                  Positioned.fill(
                    child: _ReadingDirection(
                      child: CustomPaint(
                        painter: TetherPainter(
                          from: TetherPoint.none,
                          to: TetherPoint.none,
                          line: widget.connected
                              ? TetherLine.solid
                              : TetherLine.dashed,
                          color: scheme.onSurface,
                          chevronHalfHeight: 3.5,
                          chevronStrokeWidth: 1.6,
                          chevronTipFromEnd: 3,
                          lineEndInset: 5,
                        ),
                      ),
                    ),
                  ),
                  if (widget.active)
                    AnimatedBuilder(
                      animation: _loop,
                      builder: (context, _) {
                        final w = c.maxWidth;
                        final t = _loop.value;
                        Widget dot(double x) => Positioned(
                          left: 0,
                          top: 2,
                          child: Transform.translate(
                            offset: Offset(x, 0),
                            child: SizedBox.square(
                              dimension: 6,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  color: scheme.onSurface,
                                  shape: BoxShape.circle,
                                ),
                              ),
                            ),
                          ),
                        );
                        return Stack(
                          children: [
                            dot(t * (w - 6)),
                            dot((1 - ((t + 0.5) % 1)) * (w - 6)),
                          ],
                        );
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );

    final row = stacked
        ? Column(
            children: [
              Row(
                children: [
                  end(Icons.smartphone_rounded, true),
                  wire,
                  end(Icons.devices_rounded, false),
                ],
              ),
              const SizedBox(height: Space.xs),
              Row(
                children: [
                  Expanded(
                    child: Text(widget.thisPhoneLabel, style: labelStyle),
                  ),
                  Expanded(
                    child: Text(
                      widget.otherLabel,
                      textAlign: TextAlign.end,
                      style: labelStyle,
                    ),
                  ),
                ],
              ),
            ],
          )
        : Row(
            children: [
              end(Icons.smartphone_rounded, true),
              const SizedBox(width: Space.sm),
              Text(widget.thisPhoneLabel, style: labelStyle),
              wire,
              Text(widget.otherLabel, style: labelStyle),
              const SizedBox(width: Space.sm),
              end(Icons.devices_rounded, false),
            ],
          );

    return Semantics(
      label:
          widget.semanticLabel ??
          '${widget.thisPhoneLabel} to ${widget.otherLabel.toLowerCase()}',
      container: true,
      excludeSemantics: true,
      child: row,
    );
  }
}
