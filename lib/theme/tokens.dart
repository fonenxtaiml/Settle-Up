// lib/theme/tokens.dart
// Design tokens for the "Point to Point" direction
// (docs/design/DESIGN.md and docs/design/point-to-point-direction.md).
//
// Ink on cool stone. Colour only ever means money direction: Lagoon is
// money coming to you, Kiln is money you pay. Every action is ink.
import 'package:flutter/material.dart';

/// Raw colour values. Widgets read colours from the [ColorScheme] and
/// [MoneyColors]; only the theme should touch this class.
abstract final class Palette {
  // Light.
  static const ink = Color(0xFF16191D);
  static const onInk = Color(0xFFFFFFFF);
  static const stone = Color(0xFFEEF0EF); // background
  static const card = Color(0xFFFFFFFF); // grouped lists
  static const stoneDeep = Color(0xFFE4E7E6); // nav bar, tonal button
  static const stoneDeeper = Color(0xFFD9DDDC); // nav indicator, selection
  static const inkSecondary = Color(0xFF5A6066);
  static const hairline = Color(0xFFDCE0DF);
  // 3:1 on stone. DESIGN.md's front matter still lists #8A9096; the
  // direction doc raised it to #767D83 in its accessibility pass.
  static const outline = Color(0xFF767D83);
  static const lagoon = Color(0xFF0B5C8E);
  static const lagoonContainer = Color(0xFFE2EEF6);
  static const kiln = Color(0xFFA3460B);
  static const kilnContainer = Color(0xFFFBEADF);

  // Dark.
  static const inkDark = Color(0xFFE9EBEC);
  static const onInkDark = Color(0xFF0F1316);
  static const stoneDark = Color(0xFF0F1316);
  static const cardDark = Color(0xFF171C20);
  static const stoneDeepDark = Color(0xFF222A2F);
  static const stoneDeeperDark = Color(0xFF36424B);
  static const inkSecondaryDark = Color(0xFFA1A8AE);
  static const hairlineDark = Color(0xFF263036);
  static const outlineDark = Color(0xFF6B7379);
  static const lagoonDark = Color(0xFF86BDEB);
  static const lagoonContainerDark = Color(0xFF16324A);
  static const kilnDark = Color(0xFFF2A673);
  static const kilnContainerDark = Color(0xFF44270F);
}

/// 4 pt spacing grid (DESIGN.md "spacing").
abstract final class Space {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double gutter = 20;
  static const double xl = 24;
  static const double xxl = 32;

  /// Side gutter for containers (grouped lists, buttons, cards).
  static const double screen = 16;

  /// Side gutter for free text, so headings line up with text in cards.
  static const double text = 20;

  /// Section heading: 18 above, 8 below.
  static const double sectionTop = 18;
  static const double sectionBottom = 8;

  /// Row content inset inside a grouped list.
  static const double rowInset = 16;

  /// Divider start for rows with a 40 dp avatar: 16 + 40 + 14.
  static const double avatarRowInset = 70;
}

/// Corner radii: grouped lists large, inputs medium, controls full pills.
abstract final class Radii {
  static const double sm = 8; // category chip, checkbox-adjacent bits
  static const double md = 12; // inputs, pickers, QR tile
  static const double lg = 20; // grouped lists and cards
  static const double fab = 16; // extended FAB, as in M3
  static const double chip = 10; // split-method chips
  static const double full = 999;
}

/// Fixed sizes taken from the reference renders.
abstract final class Sizes {
  static const double rowMin = 62; // two-line list row
  static const double rowMinDense = 58;
  static const double avatar = 40;
  static const double avatarSmall = 32;
  static const double avatarTiny = 26;
  static const double avatarHero = 56;
  static const Size tetherInline = Size(26, 10);
  static const double tetherRowLine = 56;
  static const double buttonBlock = 52;
  static const double button = 48;
  static const double buttonSmall = 36;
  static const double fab = 56;
  static const double navBar = 80;
  static const double appBar = 64;
  static const double qr = 124;
  static const double minTap = 48;
}

/// Motion (direction doc, "Motion moment"). Compositor properties only.
abstract final class Motion {
  /// The ink dot travelling along the tether on Settle up.
  static const travel = Duration(milliseconds: 280);
  static const travelCurve = Curves.easeOutCubic;

  /// The receiving ring filling when the dot arrives.
  static const fill = Duration(milliseconds: 120);

  /// "Now" to "After" crossfade; also the only motion under reduce-motion.
  static const crossfade = Duration(milliseconds: 150);

  /// One loop of the sync dots travelling along the dashed line.
  static const syncLoop = Duration(milliseconds: 1400);
}

/// Which way money moves, from the viewer's point of view.
enum MoneyDirection {
  /// Money coming to you (Lagoon, "+").
  owed,

  /// Money you pay (Kiln, "−").
  owe,

  /// Nothing outstanding (secondary ink, "settled", slack tether).
  settled,

  /// An amount between other people, or a plain total (ink, no sign).
  neutral;

  /// Direction of a signed balance: + owed to you, − you owe, 0 settled.
  static MoneyDirection of(int minor) => minor > 0
      ? MoneyDirection.owed
      : minor < 0
      ? MoneyDirection.owe
      : MoneyDirection.settled;
}

/// Money colours. Kept out of [ColorScheme] so Material widgets never pick
/// Lagoon or Kiln up by themselves.
@immutable
class MoneyColors extends ThemeExtension<MoneyColors> {
  const MoneyColors({
    required this.owed,
    required this.owedContainer,
    required this.owe,
    required this.oweContainer,
    required this.settled,
    required this.settledContainer,
    required this.neutral,
  });

  final Color owed;
  final Color owedContainer;
  final Color owe;
  final Color oweContainer;
  final Color settled;
  final Color settledContainer;

  /// Ink, for amounts that belong to other people.
  final Color neutral;

  static const light = MoneyColors(
    owed: Palette.lagoon,
    owedContainer: Palette.lagoonContainer,
    owe: Palette.kiln,
    oweContainer: Palette.kilnContainer,
    settled: Palette.inkSecondary,
    settledContainer: Palette.stoneDeep,
    neutral: Palette.ink,
  );

  static const dark = MoneyColors(
    owed: Palette.lagoonDark,
    owedContainer: Palette.lagoonContainerDark,
    owe: Palette.kilnDark,
    oweContainer: Palette.kilnContainerDark,
    settled: Palette.inkSecondaryDark,
    settledContainer: Palette.stoneDeepDark,
    neutral: Palette.inkDark,
  );

  Color forDirection(MoneyDirection d) => switch (d) {
    MoneyDirection.owed => owed,
    MoneyDirection.owe => owe,
    MoneyDirection.settled => settled,
    MoneyDirection.neutral => neutral,
  };

  Color containerFor(MoneyDirection d) => switch (d) {
    MoneyDirection.owed => owedContainer,
    MoneyDirection.owe => oweContainer,
    MoneyDirection.settled || MoneyDirection.neutral => settledContainer,
  };

  /// Colour of a signed balance (+ owed, − owe, 0 settled).
  Color forBalance(int minor) => forDirection(MoneyDirection.of(minor));

  @override
  MoneyColors copyWith({
    Color? owed,
    Color? owedContainer,
    Color? owe,
    Color? oweContainer,
    Color? settled,
    Color? settledContainer,
    Color? neutral,
  }) => MoneyColors(
    owed: owed ?? this.owed,
    owedContainer: owedContainer ?? this.owedContainer,
    owe: owe ?? this.owe,
    oweContainer: oweContainer ?? this.oweContainer,
    settled: settled ?? this.settled,
    settledContainer: settledContainer ?? this.settledContainer,
    neutral: neutral ?? this.neutral,
  );

  @override
  MoneyColors lerp(ThemeExtension<MoneyColors>? other, double t) {
    if (other is! MoneyColors) return this;
    return MoneyColors(
      owed: Color.lerp(owed, other.owed, t)!,
      owedContainer: Color.lerp(owedContainer, other.owedContainer, t)!,
      owe: Color.lerp(owe, other.owe, t)!,
      oweContainer: Color.lerp(oweContainer, other.oweContainer, t)!,
      settled: Color.lerp(settled, other.settled, t)!,
      settledContainer: Color.lerp(
        settledContainer,
        other.settledContainer,
        t,
      )!,
      neutral: Color.lerp(neutral, other.neutral, t)!,
    );
  }
}

extension MoneyColorsContext on BuildContext {
  /// The theme's [MoneyColors]; falls back to the light set.
  MoneyColors get money =>
      Theme.of(this).extension<MoneyColors>() ?? MoneyColors.light;
}
