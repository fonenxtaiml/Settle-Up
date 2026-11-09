// lib/theme/app_theme.dart
// Material 3 theme for the "Point to Point" direction
// (docs/design/DESIGN.md, docs/design/point-to-point-direction.md).
//
// Both colour schemes are built by hand: no seed, no dynamic colour. Ink is
// the primary role, stone is the surface, white cards are
// surfaceContainerLowest. Lagoon and Kiln live in [MoneyColors] only.
//
// Fonts: Familjen Grotesk 400/500/600/700 static instances are bundled under
// assets/google_fonts/ with the file names google_fonts resolves
// (FamiljenGrotesk-Regular.ttf ...). Runtime fetching is never enabled.
// google_fonts 9 builds on the decoupled material_ui package, so each role
// is resolved with GoogleFonts.getFont (TextStyle is shared) instead of
// GoogleFonts.getTextTheme.
import 'package:flutter/cupertino.dart' show CupertinoPageTransitionsBuilder;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

import 'tokens.dart';

const String kFontFamily = 'Familjen Grotesk';

/// Offline font setup. Call [configure] once from main() before runApp;
/// awaiting [preload] as well avoids a first frame in the fallback font.
abstract final class AppFonts {
  /// The weights bundled under assets/google_fonts/. Never use any other
  /// weight: google_fonts would look for a file that is not bundled.
  static const List<FontWeight> bundledWeights = [
    FontWeight.w400,
    FontWeight.w500,
    FontWeight.w600,
    FontWeight.w700,
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

  /// Resolves every bundled weight once and waits until they are loaded.
  static Future<void> preload() async {
    configure();
    for (final w in bundledWeights) {
      GoogleFonts.getFont(kFontFamily, fontWeight: w);
    }
    await GoogleFonts.pendingFonts();
  }
}

abstract final class AppTheme {
  static ThemeData light() => _build(lightScheme, MoneyColors.light);
  static ThemeData dark() => _build(darkScheme, MoneyColors.dark);

  /// Light scheme: every Material 3 role set explicitly.
  static const ColorScheme lightScheme = ColorScheme(
    brightness: Brightness.light,
    primary: Palette.ink,
    onPrimary: Palette.onInk,
    primaryContainer: Palette.stoneDeeper,
    onPrimaryContainer: Palette.ink,
    primaryFixed: Palette.stoneDeeper,
    primaryFixedDim: Color(0xFFC7CCCB),
    onPrimaryFixed: Palette.ink,
    onPrimaryFixedVariant: Palette.inkSecondary,
    secondary: Palette.inkSecondary,
    onSecondary: Palette.onInk,
    secondaryContainer: Palette.stoneDeep,
    onSecondaryContainer: Palette.ink,
    secondaryFixed: Palette.stoneDeep,
    secondaryFixedDim: Palette.stoneDeeper,
    onSecondaryFixed: Palette.ink,
    onSecondaryFixedVariant: Palette.inkSecondary,
    tertiary: Color(0xFF3B4247),
    onTertiary: Palette.onInk,
    tertiaryContainer: Palette.stoneDeeper,
    onTertiaryContainer: Palette.ink,
    tertiaryFixed: Palette.stoneDeeper,
    tertiaryFixedDim: Color(0xFFC7CCCB),
    onTertiaryFixed: Palette.ink,
    onTertiaryFixedVariant: Palette.inkSecondary,
    // Real errors only (a form that cannot save). Never used for debt.
    error: Color(0xFFB3261E),
    onError: Palette.onInk,
    errorContainer: Color(0xFFF9DEDC),
    onErrorContainer: Color(0xFF410E0B),
    surface: Palette.stone,
    onSurface: Palette.ink,
    surfaceDim: Color(0xFFDDE0DF),
    surfaceBright: Color(0xFFF7F8F8),
    surfaceContainerLowest: Palette.card,
    surfaceContainerLow: Color(0xFFF5F6F6),
    surfaceContainer: Palette.stoneDeep,
    surfaceContainerHigh: Palette.stoneDeeper,
    surfaceContainerHighest: Color(0xFFCED3D2),
    onSurfaceVariant: Palette.inkSecondary,
    outline: Palette.outline,
    outlineVariant: Palette.hairline,
    shadow: Color(0xFF16191D),
    scrim: Color(0xFF000000),
    inverseSurface: Color(0xFF2A2F33),
    onInverseSurface: Palette.stone,
    inversePrimary: Palette.inkDark,
    surfaceTint: Colors.transparent,
  );

  /// Dark scheme: blue-black stone tinted toward Lagoon.
  static const ColorScheme darkScheme = ColorScheme(
    brightness: Brightness.dark,
    primary: Palette.inkDark,
    onPrimary: Palette.onInkDark,
    primaryContainer: Palette.stoneDeeperDark,
    onPrimaryContainer: Palette.inkDark,
    primaryFixed: Palette.stoneDeeper,
    primaryFixedDim: Color(0xFFC7CCCB),
    onPrimaryFixed: Palette.ink,
    onPrimaryFixedVariant: Palette.inkSecondary,
    secondary: Palette.inkSecondaryDark,
    onSecondary: Palette.onInkDark,
    secondaryContainer: Palette.stoneDeepDark,
    onSecondaryContainer: Palette.inkDark,
    secondaryFixed: Palette.stoneDeep,
    secondaryFixedDim: Palette.stoneDeeper,
    onSecondaryFixed: Palette.ink,
    onSecondaryFixedVariant: Palette.inkSecondary,
    tertiary: Color(0xFFC3C9CE),
    onTertiary: Palette.onInkDark,
    tertiaryContainer: Palette.stoneDeeperDark,
    onTertiaryContainer: Palette.inkDark,
    tertiaryFixed: Palette.stoneDeeper,
    tertiaryFixedDim: Color(0xFFC7CCCB),
    onTertiaryFixed: Palette.ink,
    onTertiaryFixedVariant: Palette.inkSecondary,
    error: Color(0xFFF2B8B5),
    onError: Color(0xFF601410),
    errorContainer: Color(0xFF8C1D18),
    onErrorContainer: Color(0xFFF9DEDC),
    surface: Palette.stoneDark,
    onSurface: Palette.inkDark,
    surfaceDim: Palette.stoneDark,
    surfaceBright: Color(0xFF30393F),
    surfaceContainerLowest: Palette.cardDark,
    surfaceContainerLow: Color(0xFF13181B),
    surfaceContainer: Palette.stoneDeepDark,
    surfaceContainerHigh: Palette.stoneDeeperDark,
    surfaceContainerHighest: Color(0xFF3F4B54),
    onSurfaceVariant: Palette.inkSecondaryDark,
    outline: Palette.outlineDark,
    outlineVariant: Palette.hairlineDark,
    shadow: Color(0xFF000000),
    scrim: Color(0xFF000000),
    inverseSurface: Palette.inkDark,
    onInverseSurface: Color(0xFF1B2125),
    inversePrimary: Palette.ink,
    surfaceTint: Colors.transparent,
  );

  /// Type scale (DESIGN.md "typography", direction doc table). One family,
  /// hierarchy from size and weight; letter-spacing is never changed.
  static TextTheme typeScale() {
    const tnum = [FontFeature.tabularFigures()];
    const w4 = FontWeight.w400;
    const w5 = FontWeight.w500;
    const w6 = FontWeight.w600;
    return const TextTheme(
      // Home hero amount; the only display-size text on a screen.
      displayLarge: TextStyle(
        fontSize: 62,
        height: 1,
        fontWeight: w6,
        letterSpacing: 0,
        fontFeatures: tnum,
      ),
      // Entered amount on Add expense.
      displayMedium: TextStyle(
        fontSize: 54,
        height: 60 / 54,
        fontWeight: w6,
        letterSpacing: 0,
        fontFeatures: tnum,
      ),
      // Group position amount.
      displaySmall: TextStyle(
        fontSize: 46,
        height: 50 / 46,
        fontWeight: w6,
        letterSpacing: 0,
        fontFeatures: tnum,
      ),
      // Settle up amount riding on the tether.
      headlineLarge: TextStyle(
        fontSize: 44,
        height: 48 / 44,
        fontWeight: w6,
        letterSpacing: 0,
        fontFeatures: tnum,
      ),
      headlineMedium: TextStyle(
        fontSize: 34,
        height: 40 / 34,
        fontWeight: w6,
        letterSpacing: 0,
        fontFeatures: tnum,
      ),
      // Sync "3 changes to share".
      headlineSmall: TextStyle(
        fontSize: 30,
        height: 36 / 30,
        fontWeight: w6,
        letterSpacing: 0,
      ),
      // App bar titles.
      titleLarge: TextStyle(
        fontSize: 22,
        height: 28 / 22,
        fontWeight: w6,
        letterSpacing: 0,
      ),
      // Row titles, section headings.
      titleMedium: TextStyle(
        fontSize: 16,
        height: 22 / 16,
        fontWeight: w6,
        letterSpacing: 0,
      ),
      // Card titles, member rows.
      titleSmall: TextStyle(
        fontSize: 15,
        height: 20 / 15,
        fontWeight: w6,
        letterSpacing: 0,
      ),
      bodyLarge: TextStyle(
        fontSize: 15,
        height: 22 / 15,
        fontWeight: w4,
        letterSpacing: 0,
      ),
      bodyMedium: TextStyle(
        fontSize: 14,
        height: 20 / 14,
        fontWeight: w4,
        letterSpacing: 0,
      ),
      // Sublines and captions.
      bodySmall: TextStyle(
        fontSize: 13,
        height: 18 / 13,
        fontWeight: w4,
        letterSpacing: 0,
      ),
      // Buttons.
      labelLarge: TextStyle(
        fontSize: 15,
        height: 20 / 15,
        fontWeight: w6,
        letterSpacing: 0,
      ),
      // Direction words, date subheads, field labels.
      labelMedium: TextStyle(
        fontSize: 13,
        height: 18 / 13,
        fontWeight: w5,
        letterSpacing: 0,
      ),
      // Navigation bar labels, table heads.
      labelSmall: TextStyle(
        fontSize: 12,
        height: 16 / 12,
        fontWeight: w6,
        letterSpacing: 0,
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
    final text = _withFont(typeScale())
        .apply(bodyColor: scheme.onSurface, displayColor: scheme.onSurface);
    final isDark = scheme.brightness == Brightness.dark;
    final ink = scheme.onSurface;
    final ink2 = scheme.onSurfaceVariant;
    const pill = StadiumBorder();

    return ThemeData(
      useMaterial3: true,
      brightness: scheme.brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      cardColor: scheme.surfaceContainerLowest,
      dividerColor: scheme.outlineVariant,
      textTheme: text,
      primaryTextTheme: text,
      extensions: <ThemeExtension<dynamic>>[money],
      materialTapTargetSize: MaterialTapTargetSize.padded,
      visualDensity: VisualDensity.standard,
      splashFactory: InkRipple.splashFactory,
      iconTheme: IconThemeData(color: ink, size: 24),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: ink,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        toolbarHeight: Sizes.appBar,
        titleSpacing: Space.text,
        actionsPadding: const EdgeInsetsDirectional.only(end: Space.sm),
        titleTextStyle: text.titleLarge,
        iconTheme: IconThemeData(color: ink, size: 24),
        actionsIconTheme: IconThemeData(color: ink, size: 24),
        systemOverlayStyle: SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
          systemNavigationBarContrastEnforced: false,
          statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
          statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
          systemNavigationBarIconBrightness: isDark
              ? Brightness.light
              : Brightness.dark,
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        // Flat: AddExpenseFab paints the soft two-layer shadow itself.
        elevation: 0,
        focusElevation: 0,
        hoverElevation: 0,
        highlightElevation: 0,
        disabledElevation: 0,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(Radii.fab)),
        ),
        extendedTextStyle: text.labelLarge,
        extendedPadding: const EdgeInsetsDirectional.only(start: 16, end: 20),
        extendedIconLabelSpacing: 10,
        extendedSizeConstraints: const BoxConstraints.tightFor(
          height: Sizes.fab,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, Sizes.button),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          shape: pill,
          textStyle: text.labelLarge,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, Sizes.button),
          padding: const EdgeInsets.symmetric(horizontal: 22),
          shape: pill,
          foregroundColor: ink,
          textStyle: text.labelLarge,
          side: BorderSide(color: scheme.outline),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: ink,
          textStyle: text.labelLarge,
          shape: pill,
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          foregroundColor: ink,
          minimumSize: const Size.square(Sizes.minTap),
        ),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          backgroundColor: Colors.transparent,
          foregroundColor: ink,
          selectedBackgroundColor: scheme.surfaceContainerHigh,
          selectedForegroundColor: ink,
          side: BorderSide(color: scheme.outline),
          textStyle: text.titleSmall?.copyWith(fontSize: 14),
          minimumSize: const Size(0, 44),
          // SegmentedButton sizes itself from font size + vertical padding
          // (min 40); 14 + 2 x 15 gives the 44 dp pill of render 4.
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 15),
          shape: pill,
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainer,
        indicatorColor: scheme.surfaceContainerHigh,
        indicatorShape: pill,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: Sizes.navBar,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => text.labelSmall?.copyWith(
            color: states.contains(WidgetState.selected) ? ink : ink2,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 24,
            color: states.contains(WidgetState.selected) ? ink : ink2,
          ),
        ),
      ),
      badgeTheme: BadgeThemeData(
        backgroundColor: scheme.primary,
        textColor: scheme.onPrimary,
        largeSize: 18,
        smallSize: 6,
        padding: const EdgeInsets.symmetric(horizontal: 5),
        textStyle: GoogleFonts.getFont(
          kFontFamily,
          fontSize: 11,
          height: 18 / 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbIcon: const WidgetStatePropertyAll<Icon?>(null),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHigh,
        ),
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.outline,
        ),
        trackOutlineColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? Colors.transparent
              : scheme.outline,
        ),
        trackOutlineWidth: const WidgetStatePropertyAll(1.5),
      ),
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? scheme.primary
              : Colors.transparent,
        ),
        checkColor: WidgetStatePropertyAll(scheme.onPrimary),
        side: WidgetStateBorderSide.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? BorderSide.none
              : BorderSide(color: ink2, width: 2),
        ),
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(4)),
        ),
      ),
      chipTheme: ChipThemeData(
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.all(Radius.circular(Radii.chip)),
          side: BorderSide(color: scheme.outline),
        ),
        side: BorderSide(color: scheme.outline),
        backgroundColor: Colors.transparent,
        selectedColor: scheme.primary,
        disabledColor: scheme.surfaceContainer,
        checkmarkColor: scheme.onPrimary,
        showCheckmark: false,
        labelStyle: text.titleSmall?.copyWith(fontSize: 14, color: ink),
        secondaryLabelStyle: text.titleSmall?.copyWith(
          fontSize: 14,
          color: scheme.onPrimary,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
        labelPadding: const EdgeInsets.symmetric(horizontal: 8),
        elevation: 0,
        pressElevation: 0,
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(Radii.lg)),
        ),
      ),
      listTileTheme: ListTileThemeData(
        contentPadding: const EdgeInsets.symmetric(horizontal: Space.lg),
        minTileHeight: Sizes.rowMin,
        horizontalTitleGap: 14,
        titleTextStyle: text.titleMedium,
        subtitleTextStyle: text.bodySmall?.copyWith(color: ink2),
        iconColor: ink2,
        textColor: ink,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        thickness: 1,
        space: 1,
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLowest,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: Space.lg,
          vertical: Space.md,
        ),
        border: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(Radii.md)),
          borderSide: BorderSide.none,
        ),
        enabledBorder: const OutlineInputBorder(
          borderRadius: BorderRadius.all(Radius.circular(Radii.md)),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(Radii.md)),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: const BorderRadius.all(Radius.circular(Radii.md)),
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
        labelStyle: text.labelMedium?.copyWith(color: ink2),
        floatingLabelStyle: text.labelMedium?.copyWith(color: ink2),
        hintStyle: text.bodyLarge?.copyWith(color: ink2),
        helperStyle: text.bodySmall?.copyWith(color: ink2),
        errorStyle: text.bodySmall?.copyWith(color: scheme.error),
      ),
      textSelectionTheme: TextSelectionThemeData(
        cursorColor: ink,
        selectionColor: scheme.surfaceContainerHigh,
        selectionHandleColor: ink,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        showDragHandle: true,
        dragHandleColor: scheme.outline,
        elevation: 2,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLowest,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(Radii.lg)),
        ),
        titleTextStyle: text.titleLarge,
        contentTextStyle: text.bodyLarge?.copyWith(color: ink2),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(
          color: scheme.onInverseSurface,
        ),
        actionTextColor: scheme.inversePrimary,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(Radii.md)),
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(
        color: ink,
        linearTrackColor: scheme.surfaceContainerHigh,
        circularTrackColor: scheme.surfaceContainerHigh,
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

extension AppTextStyle on TextStyle {
  /// Tabular figures (already the font's default; stated explicitly so
  /// columns of amounts always align).
  TextStyle get tabular =>
      copyWith(fontFeatures: const [FontFeature.tabularFigures()]);

  /// Changing the weight of a theme style must re-resolve the font: each
  /// google_fonts family name ("FamiljenGrotesk_600") holds exactly one
  /// bundled weight, so `copyWith(fontWeight:)` alone would pick the wrong
  /// face. Only use [AppFonts.bundledWeights].
  TextStyle withWeight(FontWeight weight) {
    assert(AppFonts.bundledWeights.contains(weight), 'Weight not bundled');
    return GoogleFonts.getFont(
      kFontFamily,
      textStyle: copyWith(fontWeight: weight),
    );
  }
}

/// Named styles that are not plain TextTheme roles.
abstract final class AppType {
  /// Trailing balance amount: 17/22, 600, tabular.
  static TextStyle amount(BuildContext context) =>
      Theme.of(context).textTheme.titleMedium!
          .copyWith(fontSize: 17, height: 22 / 17)
          .tabular;

  /// Amount in a suggested-payment or member row: 16/22, 600, tabular.
  static TextStyle amountSmall(BuildContext context) =>
      Theme.of(context).textTheme.titleMedium!.tabular;

  /// Amount in the before/after table: 15/20, 600, tabular.
  static TextStyle amountTable(BuildContext context) =>
      Theme.of(context).textTheme.titleSmall!.tabular;

  /// Direction word above an amount: 13/18, 500.
  static TextStyle direction(BuildContext context) =>
      Theme.of(context).textTheme.labelMedium!;

  /// Section heading above a grouped list: 16/22, 600.
  static TextStyle section(BuildContext context) =>
      Theme.of(context).textTheme.titleMedium!;

  /// Underlined text link ("See all", "Pay part of it"): 14, 600.
  static TextStyle link(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Theme.of(context).textTheme.titleSmall!.copyWith(
      fontSize: 14,
      color: scheme.onSurface,
      decoration: TextDecoration.underline,
      decorationColor: scheme.outline,
      decorationThickness: 1.5,
    );
  }
}

/// Money text styles. Usage: `Text(fmt, style: MoneyStyles.row(ctx, minor))`.
abstract final class MoneyStyles {
  static TextStyle hero(BuildContext context, int minor) =>
      Theme.of(context).textTheme.displayLarge!.tabular
          .copyWith(color: _heroColor(context));

  static TextStyle row(BuildContext context, int minor) =>
      AppType.amount(context).copyWith(color: context.money.forBalance(minor));

  static TextStyle direction(BuildContext context, int minor) =>
      AppType.direction(context)
          .copyWith(color: context.money.forBalance(minor));

  static TextStyle keypad(BuildContext context) =>
      Theme.of(context).textTheme.displayMedium!.tabular;

  // The hero number is ink; its sentence carries the colour (render 1).
  static Color _heroColor(BuildContext context) =>
      Theme.of(context).colorScheme.onSurface;
}
