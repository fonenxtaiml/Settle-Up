import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

import '../../theme/tokens.dart';
import 'kit_strings.dart';

/// Level vial (DESIGN 5.1). position in -1..1 (owe .. owed), already eased
/// by the caller via LevelVial.positionFor().
class LevelVial extends StatelessWidget {
  const LevelVial({
    super.key,
    required this.position,
    this.height = 16,
    this.showEndLabels = true,
    this.settled = false,
    this.animate = true,
  });

  final double position;
  final double height;
  final bool showEndLabels;
  final bool settled; // thick center marks + owedContainer fill
  final bool animate; // spring to new position (respects reduced motion)

  /// x = (owedToMe - iOwe) / max(owedToMe + iOwe, 1), clamped, sign*sqrt.
  static double positionFor({required int owedToMe, required int iOwe}) {
    final total = owedToMe + iOwe;
    // Geometry only (SPEC 0.5): the vial position is the one place money
    // becomes a double.
    final x = ((owedToMe - iOwe) / math.max(total, 1)).clamp(-1.0, 1.0);
    if (x == 0) return 0;
    return x.sign * math.sqrt(x.abs());
  }

  @override
  Widget build(BuildContext context) {
    final p = position.isNaN ? 0.0 : position.clamp(-1.0, 1.0);
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    final vial = _AnimatedVial(
      position: p,
      height: height,
      settled: settled,
      animate: animate && !reduceMotion,
    );
    if (!showEndLabels) return ExcludeSemantics(child: vial);

    final money = context.money;
    final label = Theme.of(context).textTheme.labelMedium!;
    return ExcludeSemantics(
      child: Row(
        children: [
          Text(KitStrings.vialOwe, style: label.copyWith(color: money.owe)),
          const SizedBox(width: Space.x2),
          Expanded(child: vial),
          const SizedBox(width: Space.x2),
          Text(KitStrings.vialOwed, style: label.copyWith(color: money.owed)),
        ],
      ),
    );
  }
}

class _AnimatedVial extends StatefulWidget {
  const _AnimatedVial({
    required this.position,
    required this.height,
    required this.settled,
    required this.animate,
  });

  final double position;
  final double height;
  final bool settled;
  final bool animate;

  @override
  State<_AnimatedVial> createState() => _AnimatedVialState();
}

class _AnimatedVialState extends State<_AnimatedVial>
    with TickerProviderStateMixin {
  late final AnimationController _bubble = AnimationController.unbounded(
    vsync: this,
    value: widget.position,
  );
  late final AnimationController _marks = AnimationController(
    vsync: this,
    duration: Motion.standard,
    value: widget.settled ? 1 : 0,
  );

  @override
  void didUpdateWidget(_AnimatedVial old) {
    super.didUpdateWidget(old);
    if (old.position != widget.position) {
      if (widget.animate) {
        _bubble.animateWith(
          SpringSimulation(
            Motion.bubbleSpring,
            _bubble.value,
            widget.position,
            _bubble.velocity,
          ),
        );
      } else {
        _bubble.value = widget.position;
      }
    }
    if (old.settled != widget.settled) {
      final target = widget.settled ? 1.0 : 0.0;
      if (widget.animate) {
        _marks.animateTo(target, curve: Motion.enter);
      } else {
        _marks.value = target;
      }
    }
  }

  @override
  void dispose() {
    _bubble.dispose();
    _marks.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final money = context.money;
    final scheme = Theme.of(context).colorScheme;
    final bubble = widget.height * (Sizes.bubble / Sizes.vialHeight);
    return SizedBox(
      height: bubble,
      width: double.infinity,
      child: CustomPaint(
        painter: _VialPainter(
          bubbleX: _bubble,
          settledT: _marks,
          trackHeight: widget.height,
          bubbleSize: bubble,
          track: money.vialTrack,
          settledFill: money.owedContainer,
          mark: scheme.outline,
          vial: money.vial,
          onVial: money.onVial,
          isDark: Theme.of(context).brightness == Brightness.dark,
          rtl: Directionality.of(context) == TextDirection.rtl,
        ),
      ),
    );
  }
}

class _VialPainter extends CustomPainter {
  _VialPainter({
    required this.bubbleX,
    required this.settledT,
    required this.trackHeight,
    required this.bubbleSize,
    required this.track,
    required this.settledFill,
    required this.mark,
    required this.vial,
    required this.onVial,
    required this.isDark,
    required this.rtl,
  }) : super(repaint: Listenable.merge([bubbleX, settledT]));

  final Animation<double> bubbleX;
  final Animation<double> settledT;
  final double trackHeight;
  final double bubbleSize;
  final Color track;
  final Color settledFill;
  final Color mark;
  final Color vial;
  final Color onVial;
  final bool isDark;
  final bool rtl;

  @override
  void paint(Canvas canvas, Size size) {
    final t = settledT.value.clamp(0.0, 1.0);
    final cy = size.height / 2;
    final scale = trackHeight / Sizes.vialHeight;

    // Tube.
    final tube = RRect.fromRectAndRadius(
      Rect.fromLTWH(0, cy - trackHeight / 2, size.width, trackHeight),
      Radius.circular(trackHeight / 2),
    );
    canvas.drawRRect(tube, Paint()..color = Color.lerp(track, settledFill, t)!);

    // A hairline of light along the top of the glass.
    final glint = Paint()
      ..color = Colors.white.withValues(alpha: isDark ? 0.06 : 0.55)
      ..strokeWidth = math.max(1, scale)
      ..strokeCap = StrokeCap.round;
    final glintY = cy - trackHeight / 2 + 3 * scale;
    canvas.drawLine(
      Offset(trackHeight * 0.75, glintY),
      Offset(size.width - trackHeight * 0.75, glintY),
      glint,
    );

    // Center marks, 24 dp apart, etched slightly past the tube.
    final markWidth = 1 + 2 * t;
    final markPaint = Paint()
      ..color = mark
      ..strokeWidth = markWidth;
    final half = 12 * scale;
    final overhang = 2 * scale;
    for (final dx in [-half, half]) {
      final x = size.width / 2 + dx;
      canvas.drawLine(
        Offset(x, cy - trackHeight / 2 - overhang),
        Offset(x, cy + trackHeight / 2 + overhang),
        markPaint,
      );
    }

    // Bubble.
    final r = bubbleSize / 2;
    final travel = math.max(0.0, size.width / 2 - r);
    final p = bubbleX.value * (rtl ? -1 : 1);
    final cx = size.width / 2 + p.clamp(-1.25, 1.25) * travel;
    final center = Offset(cx.clamp(r, math.max(r, size.width - r)), cy);
    canvas.drawCircle(center, r, Paint()..color = vial);
    canvas.drawCircle(
      center,
      r - 0.5,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = onVial.withValues(alpha: 0.2),
    );
    // Inner highlight: a short arc near the top-left, not a drop shadow.
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: r * 0.62),
      math.pi * 1.08,
      math.pi * 0.5,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = math.max(1.5, 2 * scale)
        ..color = Colors.white.withValues(alpha: 0.7),
    );
  }

  @override
  bool shouldRepaint(_VialPainter old) =>
      old.trackHeight != trackHeight ||
      old.bubbleSize != bubbleSize ||
      old.track != track ||
      old.settledFill != settledFill ||
      old.mark != mark ||
      old.vial != vial ||
      old.onVial != onVial ||
      old.isDark != isDark ||
      old.rtl != rtl ||
      old.bubbleX != bubbleX ||
      old.settledT != settledT;
}
