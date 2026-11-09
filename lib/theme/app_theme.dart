// lib/theme/app_theme.dart
// Theme for Settle Up (docs/design/DESIGN.md section 8.2).
//
// Adapted for Flutter 3.47 / google_fonts 9: google_fonts 9 builds on the
// decoupled `material_ui` package, so its TextTheme type is not the one in
// package:flutter/material.dart. We therefore resolve each role with
// GoogleFonts.getFont (TextStyle is shared by both libraries) instead of
// GoogleFonts.getTextTheme. The Material helper class for money styles is
// named MoneyStyles so it does not clash with the MoneyText widget.
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

const String kFontFamily = 'Atkinson Hyperlegible Next';

/// Offline font setup (DESIGN 3.2). Call once from main() before runApp.
abstract final class AppFonts {
  /// The weights bundled under assets/google_fonts/. Never use any other
  /// weight: google_fonts would look for a file that is not bundled.
  static const List<FontWeight> bundledWeights = [
    FontWeight.w400,
    FontWeight.w600,
    FontWeight.w700,
    FontWeight.w800,
  ];

  static const String licenseAsset = 'assets/google_fonts/OFL.txt';

  static bool _licenseRegistered = false;

  /// Disables runtime fetching (fonts are bundled) and registers the OFL
  /// license with the Licenses page. Safe to call more than once.
  static void configure() {
    GoogleFonts.config.allowRuntimeFetching = false;
    if (_licenseRegistered) return;
    _licenseRegistered = true;
    LicenseRegistry.addLicense(() async* {
      final license = await rootBundle.loadString(licenseAsset);
      yield LicenseEntryWithLineBreaks(<String>['google_fonts'], license);
    });
  }
}

abstract final class AppTheme {
  static ThemeData light() => _build(_lightScheme, MoneyColors.light);
  static ThemeData dark() => _build(_darkScheme, MoneyColors.dark);

  static final ColorScheme _lightScheme =
      ColorScheme.fromSeed(
        seedColor: Palette.plumb,
        brightness: Brightness.light,
        dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
      ).copyWith(
        primary: Palette.plumb,
        onPrimary: const Color(0xFFFFFFFF),
        primaryContainer: const Color(0xFFE3E0FA),
        onPrimaryContainer: const Color(0xFF221D52),
        secondary: const Color(0xFF5C5873),
        onSecondary: const Color(0xFFFFFFFF),
        secondaryContainer: const Color(0xFFE5E3EF),
        onSecondaryContainer: const Color(0xFF1F1C33),
        tertiary: const Color(0xFF6E5200),
        onTertiary: const Color(0xFFFFFFFF),
        tertiaryContainer: Palette.vial,
        onTertiaryContainer: Palette.plumbInk,
        error: const Color(0xFFBA1A1A),
        onError: const Color(0xFFFFFFFF),
        errorContainer: const Color(0xFFFFDAD6),
        onErrorContainer: const Color(0xFF410002),
        surface: Palette.fog,
        onSurface: Palette.plumbInk,
        onSurfaceVariant: const Color(0xFF4D4A60),
        surfaceContainerLowest: const Color(0xFFFFFFFF),
        surfaceContainerLow: const Color(0xFFF1F1F6),
        surfaceContainer: const Color(0xFFEBEBF2),
        surfaceContainerHigh: const Color(0xFFE4E4EC),
        surfaceContainerHighest: const Color(0xFFDCDCE6),
        outline: const Color(0xFF77748A),
        outlineVariant: const Color(0xFFC9C7D6),
        inverseSurface: const Color(0xFF312F42),
        onInverseSurface: const Color(0xFFF2F0FA),
        inversePrimary: const Color(0xFFC5BFFF),
        shadow: const Color(0xFF000000),
        scrim: const Color(0xFF000000),
        surfaceTint: Colors.transparent,
      );

  static final ColorScheme _darkScheme =
      ColorScheme.fromSeed(
        seedColor: Palette.plumb,
        brightness: Brightness.dark,
        dynamicSchemeVariant: DynamicSchemeVariant.fidelity,
      ).copyWith(
        primary: const Color(0xFFC5BFFF),
        onPrimary: const Color(0xFF262060),
        primaryContainer: const Color(0xFF413B80),
        onPrimaryContainer: const Color(0xFFE3E0FF),
        secondary: const Color(0xFFC9C5DD),
        onSecondary: const Color(0xFF312E43),
        secondaryContainer: const Color(0xFF48455B),
        onSecondaryContainer: const Color(0xFFE5E1F9),
        tertiary: const Color(0xFFF5CB4C),
        onTertiary: const Color(0xFF3D2E00),
        tertiaryContainer: Palette.vial,
        onTertiaryContainer: Palette.plumbInk,
        error: const Color(0xFFFFB4AB),
        onError: const Color(0xFF690005),
        errorContainer: const Color(0xFF93000A),
        onErrorContainer: const Color(0xFFFFDAD6),
        surface: Palette.night,
        onSurface: const Color(0xFFE7E5F2),
        onSurfaceVariant: const Color(0xFFC8C5D8),
        surfaceContainerLowest: const Color(0xFF110F19),
        surfaceContainerLow: const Color(0xFF1D1B27),
        surfaceContainer: const Color(0xFF22202D),
        surfaceContainerHigh: const Color(0xFF2C2A38),
        surfaceContainerHighest: const Color(0xFF373544),
        outline: const Color(0xFF918EA3),
        outlineVariant: const Color(0xFF46435A),
        inverseSurface: const Color(0xFFE7E5F2),
        onInverseSurface: const Color(0xFF312F42),
        inversePrimary: Palette.plumb,
        shadow: const Color(0xFF000000),
        scrim: const Color(0xFF000000),
        surfaceTint: Colors.transparent,
      );

  /// Type scale (section 3.3). Display roles carry tabular figures because
  /// they only ever show amounts and codes.
  static TextTheme _typeScale() {
    const tnum = [FontFeature.tabularFigures()];
    return const TextTheme(
      displayLarge: TextStyle(
        fontSize: 56,
        height: 60 / 56,
        fontWeight: FontWeight.w800,
        letterSpacing: -1.2,
        fontFeatures: tnum,
      ),
      displayMedium: TextStyle(
        fontSize: 44,
        height: 48 / 44,
        fontWeight: FontWeight.w800,
        letterSpacing: -0.8,
        fontFeatures: tnum,
      ),
      displaySmall: TextStyle(
        fontSize: 36,
        height: 40 / 36,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.5,
        fontFeatures: tnum,
      ),
      headlineLarge: TextStyle(
        fontSize: 30,
        height: 36 / 30,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.3,
      ),
      headlineMedium: TextStyle(
        fontSize: 26,
        height: 32 / 26,
        fontWeight: FontWeight.w700,
        letterSpacing: -0.2,
      ),
      headlineSmall: TextStyle(
        fontSize: 22,
        height: 28 / 22,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      titleLarge: TextStyle(
        fontSize: 20,
        height: 26 / 20,
        fontWeight: FontWeight.w700,
        letterSpacing: 0,
      ),
      titleMedium: TextStyle(
        fontSize: 17,
        height: 24 / 17,
        fontWeight: FontWeight.w600,
        letterSpacing: 0,
      ),
      titleSmall: TextStyle(
        fontSize: 15,
        height: 20 / 15,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.1,
      ),
      bodyLarge: TextStyle(
        fontSize: 17,
        height: 26 / 17,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
      ),
      bodyMedium: TextStyle(
        fontSize: 15,
        height: 22 / 15,
        fontWeight: FontWeight.w400,
        letterSpacing: 0,
      ),
      bodySmall: TextStyle(
        fontSize: 13,
        height: 18 / 13,
        fontWeight: FontWeight.w400,
        letterSpacing: 0.1,
      ),
      labelLarge: TextStyle(
        fontSize: 15,
        height: 20 / 15,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.1,
      ),
      labelMedium: TextStyle(
        fontSize: 13,
        height: 16 / 13,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
      labelSmall: TextStyle(
        fontSize: 12,
        height: 16 / 12,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.2,
      ),
    );
  }

  static TextStyle? _font(TextStyle? style) =>
      style == null ? null : GoogleFonts.getFont(kFontFamily, textStyle: style);

  static TextTheme _withFont(TextTheme t) => TextTheme(
    displayLarge: _font(t.displayLarge),
    displayMedium: _font(t.displayMedium),
    displaySmall: _font(t.displaySmall),
    headlineLarge: _font(t.headlineLarge),
    headlineMedium: _font(t.headlineMedium),
    headlineSmall: _font(t.headlineSmall),
    titleLarge: _font(t.titleLarge),
    titleMedium: _font(t.titleMedium),
    titleSmall: _font(t.titleSmall),
    bodyLarge: _font(t.bodyLarge),
    bodyMedium: _font(t.bodyMedium),
    bodySmall: _font(t.bodySmall),
    labelLarge: _font(t.labelLarge),
    labelMedium: _font(t.labelMedium),
    labelSmall: _font(t.labelSmall),
  );

  static ThemeData _build(ColorScheme scheme, MoneyColors money) {
    final text = _withFont(_typeScale())
        .apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);

    final buttonShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(Radii.button),
    );
    const buttonSize = Size(64, Sizes.buttonHeight);

    return ThemeData(
      useMaterial3: true,
      brightness: scheme.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      textTheme: text,
      extensions: <ThemeExtension<dynamic>>[money],
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      splashFactory: InkSparkle.splashFactory,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle: text.titleLarge,
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: money.vial,
        foregroundColor: money.onVial,
        elevation: 2,
        focusElevation: 2,
        hoverElevation: 3,
        highlightElevation: 1,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.fab),
        ),
        extendedTextStyle: text.labelLarge,
        extendedPadding: const EdgeInsets.symmetric(horizontal: Space.x5),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: buttonSize,
          shape: buttonShape,
          textStyle: text.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: buttonSize,
          shape: buttonShape,
          textStyle: text.labelLarge,
          side: BorderSide(color: scheme.outline),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(textStyle: text.labelLarge),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          selectedBackgroundColor: scheme.primaryContainer,
          selectedForegroundColor: scheme.onPrimaryContainer,
          side: BorderSide(color: scheme.outline),
          textStyle: text.labelLarge,
          minimumSize: const Size(0, 48),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.secondaryContainer,
        surfaceTintColor: Colors.transparent,
        height: 72,
        labelTextStyle: WidgetStatePropertyAll(text.labelMedium),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(Radii.sheet),
          ),
        ),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: Space.x4),
        minVerticalPadding: Space.x3,
        horizontalTitleGap: Space.x4,
        titleTextStyle: text.titleMedium,
        subtitleTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onSurfaceVariant,
        ),
        iconColor: scheme.onSurfaceVariant,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      chipTheme: ChipThemeData(
        shape: StadiumBorder(side: BorderSide(color: scheme.outlineVariant)),
        labelStyle: text.labelMedium,
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: scheme.primaryContainer,
        side: BorderSide.none,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Space.x4,
          vertical: Space.x4,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.input),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.input),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.input),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(Radii.input),
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
        hintStyle: text.bodyLarge?.copyWith(color: scheme.onSurfaceVariant),
        helperStyle: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        actionTextColor: scheme.inversePrimary,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(Radii.input),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: scheme.primary,
        linearTrackColor: scheme.surfaceContainerHighest,
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: <TargetPlatform, PageTransitionsBuilder>{
          TargetPlatform.android: PredictiveBackPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
    );
  }
}

/// Changing the weight of a theme style must re-resolve the font: each
/// google_fonts family name ("AtkinsonHyperlegibleNext_600") holds exactly
/// one bundled weight, so `copyWith(fontWeight:)` alone would fake the
/// weight. Only use [AppFonts.bundledWeights].
extension FontWeightSwap on TextStyle {
  TextStyle withWeight(FontWeight weight) {
    assert(AppFonts.bundledWeights.contains(weight), 'Weight not bundled');
    return GoogleFonts.getFont(
      kFontFamily,
      textStyle: copyWith(fontWeight: weight),
    );
  }
}

/// Money text helpers (section 3.3). Usage:
///   Text(fmt, style: MoneyStyles.row(context, balanceMinor))
abstract final class MoneyStyles {
  static TextStyle hero(BuildContext context, int minor) =>
      Theme.of(context).textTheme.displayMedium!.tabular
          .copyWith(color: context.money.forBalance(minor));

  static TextStyle row(BuildContext context, int minor) =>
      Theme.of(context).textTheme.titleMedium!.tabular
          .withWeight(FontWeight.w700)
          .copyWith(color: context.money.forBalance(minor));

  static TextStyle direction(BuildContext context, int minor) =>
      Theme.of(context).textTheme.labelMedium!
          .copyWith(color: context.money.forBalance(minor));

  static TextStyle keypad(BuildContext context) =>
      Theme.of(context).textTheme.displaySmall!.tabular;
}
