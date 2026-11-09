// lib/theme/tokens.dart
// Design tokens for Settle Up. Source of truth: docs/design/DESIGN.md.
// Widgets read colors via Theme.of(context).colorScheme and context.money,
// never from Palette directly.
import 'package:flutter/material.dart';

/// Raw named palette (section 2.2 to 2.4).
abstract final class Palette {
  // Brand
  static const plumb = Color(0xFF3A3478);
  static const plumbInk = Color(0xFF1D1B2E);
  static const vial = Color(0xFFF2C230);
  static const fog = Color(0xFFF7F7FA);
  static const night = Color(0xFF16151F);

  // Money, light
  static const fern = Color(0xFF1B6B3A);
  static const brick = Color(0xFFA63A1C);
  static const pewter = Color(0xFF5E5B70);

  // Money, dark
  static const fernDark = Color(0xFF7DDA97);
  static const brickDark = Color(0xFFFFA284);
  static const pewterDark = Color(0xFFB5B2C6);
}

/// 4 pt spacing grid (section 4.2).
abstract final class Space {
  static const double x1 = 4;
  static const double x2 = 8;
  static const double x3 = 12;
  static const double x4 = 16;
  static const double x5 = 20;
  static const double x6 = 24;
  static const double x8 = 32;
  static const double x10 = 40;
  static const double x12 = 48;
  static const double x16 = 64;

  static const double gutter = x4;
  static const double rowInset = 72; // divider start: 16 + 40 avatar + 16
}

/// Radius follows hierarchy (section 4.1).
abstract final class Radii {
  static const double input = 12;
  static const double key = 14;
  static const double button = 14;
  static const double fab = 20;
  static const double hero = 24;
  static const double sheet = 28;
}

/// Motion (section 4.4).
abstract final class Motion {
  static const quick = Duration(milliseconds: 120);
  static const standard = Duration(milliseconds: 240);
  static const emphasis = Duration(milliseconds: 420);
  static const signature = Duration(milliseconds: 700);

  static const enter = Curves.easeOutCubic;
  static const exit = Curves.easeInCubic;

  /// Bubble spring: slightly underdamped, one small overshoot.
  static const bubbleSpring = SpringDescription(
    mass: 1,
    stiffness: 180,
    damping: 14,
  );
}

/// Sizes used by components (section 5).
abstract final class Sizes {
  static const double avatarSm = 24;
  static const double avatarMd = 32;
  static const double avatarLg = 40;
  static const double avatarXl = 56;
  static const double rowMin1 = 64;
  static const double rowMin2 = 72;
  static const double keypadKey = 64;
  static const double buttonHeight = 52;
  static const double vialHeight = 16;
  static const double bubble = 20;
}

/// Use on any TextStyle that shows money: `style.tabular`.
extension TabularFigures on TextStyle {
  TextStyle get tabular =>
      copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
}

/// Money semantics (section 2.3 and 2.4). Always pair with a sign and a word.
@immutable
class MoneyColors extends ThemeExtension<MoneyColors> {
  const MoneyColors({
    required this.owed,
    required this.owedContainer,
    required this.onOwedContainer,
    required this.owe,
    required this.oweContainer,
    required this.onOweContainer,
    required this.settled,
    required this.settledContainer,
    required this.vial,
    required this.onVial,
    required this.vialTrack,
  });

  final Color owed;
  final Color owedContainer;
  final Color onOwedContainer;
  final Color owe;
  final Color oweContainer;
  final Color onOweContainer;
  final Color settled;
  final Color settledContainer;
  final Color vial;
  final Color onVial;
  final Color vialTrack;

  static const light = MoneyColors(
    owed: Palette.fern,
    owedContainer: Color(0xFFD7F0DD),
    onOwedContainer: Color(0xFF0A3A1C),
    owe: Palette.brick,
    oweContainer: Color(0xFFFBE2D9),
    onOweContainer: Color(0xFF4A1405),
    settled: Palette.pewter,
    settledContainer: Color(0xFFE6E5EC),
    vial: Palette.vial,
    onVial: Palette.plumbInk,
    vialTrack: Color(0xFFDCDCE6),
  );

  static const dark = MoneyColors(
    owed: Palette.fernDark,
    owedContainer: Color(0xFF1C4A2B),
    onOwedContainer: Color(0xFFC9F2D3),
    owe: Palette.brickDark,
    oweContainer: Color(0xFF5C2412),
    onOweContainer: Color(0xFFFFDCD0),
    settled: Palette.pewterDark,
    settledContainer: Color(0xFF2C2A38),
    vial: Palette.vial,
    onVial: Palette.plumbInk,
    vialTrack: Color(0xFF373544),
  );

  /// Color for a signed balance in minor units (>0 owed to you, <0 you owe).
  Color forBalance(int minorUnits) => minorUnits > 0
      ? owed
      : minorUnits < 0
      ? owe
      : settled;

  @override
  MoneyColors copyWith({
    Color? owed,
    Color? owedContainer,
    Color? onOwedContainer,
    Color? owe,
    Color? oweContainer,
    Color? onOweContainer,
    Color? settled,
    Color? settledContainer,
    Color? vial,
    Color? onVial,
    Color? vialTrack,
  }) {
    return MoneyColors(
      owed: owed ?? this.owed,
      owedContainer: owedContainer ?? this.owedContainer,
      onOwedContainer: onOwedContainer ?? this.onOwedContainer,
      owe: owe ?? this.owe,
      oweContainer: oweContainer ?? this.oweContainer,
      onOweContainer: onOweContainer ?? this.onOweContainer,
      settled: settled ?? this.settled,
      settledContainer: settledContainer ?? this.settledContainer,
      vial: vial ?? this.vial,
      onVial: onVial ?? this.onVial,
      vialTrack: vialTrack ?? this.vialTrack,
    );
  }

  @override
  MoneyColors lerp(ThemeExtension<MoneyColors>? other, double t) {
    if (other is! MoneyColors) return this;
    return MoneyColors(
      owed: Color.lerp(owed, other.owed, t)!,
      owedContainer: Color.lerp(owedContainer, other.owedContainer, t)!,
      onOwedContainer: Color.lerp(onOwedContainer, other.onOwedContainer, t)!,
      owe: Color.lerp(owe, other.owe, t)!,
      oweContainer: Color.lerp(oweContainer, other.oweContainer, t)!,
      onOweContainer: Color.lerp(onOweContainer, other.onOweContainer, t)!,
      settled: Color.lerp(settled, other.settled, t)!,
      settledContainer: Color.lerp(
        settledContainer,
        other.settledContainer,
        t,
      )!,
      vial: Color.lerp(vial, other.vial, t)!,
      onVial: Color.lerp(onVial, other.onVial, t)!,
      vialTrack: Color.lerp(vialTrack, other.vialTrack, t)!,
    );
  }
}

extension MoneyThemeX on BuildContext {
  MoneyColors get money => Theme.of(this).extension<MoneyColors>()!;
}

/// Avatar tones (section 2.6). No red or green hues.
@immutable
class AvatarTone {
  const AvatarTone(this.lightBg, this.lightFg, this.darkBg, this.darkFg);
  final Color lightBg;
  final Color lightFg;
  final Color darkBg;
  final Color darkFg;

  Color background(Brightness b) => b == Brightness.dark ? darkBg : lightBg;
  Color foreground(Brightness b) => b == Brightness.dark ? darkFg : lightFg;
}

abstract final class AvatarTones {
  static const all = <AvatarTone>[
    AvatarTone(
      Color(0xFFE3E0FA),
      Color(0xFF221D52),
      Color(0xFF3A3478),
      Color(0xFFE3E0FA),
    ), // violet
    AvatarTone(
      Color(0xFFF6E2A6),
      Color(0xFF3D2E00),
      Color(0xFF5A4500),
      Color(0xFFF6E2A6),
    ), // ochre
    AvatarTone(
      Color(0xFFD6E6F7),
      Color(0xFF0F2C4A),
      Color(0xFF1E4670),
      Color(0xFFD6E6F7),
    ), // sky
    AvatarTone(
      Color(0xFFF1DDF0),
      Color(0xFF4A1846),
      Color(0xFF66285F),
      Color(0xFFF1DDF0),
    ), // orchid
    AvatarTone(
      Color(0xFFEDE3D3),
      Color(0xFF3B2C17),
      Color(0xFF56442A),
      Color(0xFFEDE3D3),
    ), // sand
    AvatarTone(
      Color(0xFFDEE1E8),
      Color(0xFF22283A),
      Color(0xFF3B4256),
      Color(0xFFDEE1E8),
    ), // slate
    AvatarTone(
      Color(0xFFD9DEFA),
      Color(0xFF1A2869),
      Color(0xFF2F3F8F),
      Color(0xFFD9DEFA),
    ), // cornflower
    AvatarTone(
      Color(0xFFE6E2DF),
      Color(0xFF33302D),
      Color(0xFF4D4844),
      Color(0xFFE6E2DF),
    ), // stone
  ];

  /// Stable across runs, platforms and devices (FNV-1a 32-bit).
  /// Do not use String.hashCode here.
  static AvatarTone forId(String id) {
    var hash = 0x811C9DC5;
    for (final unit in id.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0xFFFFFFFF;
    }
    return all[hash % all.length];
  }
}
