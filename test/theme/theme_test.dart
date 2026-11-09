import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/theme/tokens.dart';

double _luminance(Color c) {
  double ch(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * ch(c.r) + 0.7152 * ch(c.g) + 0.0722 * ch(c.b);
}

double contrast(Color a, Color b) {
  final la = _luminance(a);
  final lb = _luminance(b);
  return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  group('AppTheme', () {
    for (final (name, build, brightness) in [
      ('light', AppTheme.light, Brightness.light),
      ('dark', AppTheme.dark, Brightness.dark),
    ]) {
      test('$name builds with MoneyColors and the brand roles', () {
        final t = build();
        expect(t.useMaterial3, isTrue);
        expect(t.brightness, brightness);
        expect(t.extension<MoneyColors>(), isNotNull);
        expect(t.colorScheme.tertiaryContainer, Palette.vial);
        expect(t.floatingActionButtonTheme.backgroundColor, Palette.vial);
        expect(
          t.scaffoldBackgroundColor,
          brightness == Brightness.light ? Palette.fog : Palette.night,
        );
      });

      test('$name type scale uses the bundled family and weights only', () {
        final t = build().textTheme;
        final styles = [
          t.displayLarge,
          t.displayMedium,
          t.displaySmall,
          t.headlineLarge,
          t.headlineMedium,
          t.headlineSmall,
          t.titleLarge,
          t.titleMedium,
          t.titleSmall,
          t.bodyLarge,
          t.bodyMedium,
          t.bodySmall,
          t.labelLarge,
          t.labelMedium,
          t.labelSmall,
        ];
        for (final s in styles) {
          expect(s, isNotNull);
          expect(s!.fontFamily, startsWith('AtkinsonHyperlegibleNext'));
          expect(AppFonts.bundledWeights, contains(s.fontWeight));
        }
        expect(t.displayMedium!.fontSize, 44);
        expect(t.displayMedium!.fontWeight, FontWeight.w800);
        expect(
          t.displayMedium!.fontFeatures,
          contains(const FontFeature.tabularFigures()),
        );
        expect(t.bodyMedium!.fontFeatures ?? const [], isEmpty);
      });

      test('$name money colors meet AA on every surface tier', () {
        final t = build();
        final m = t.extension<MoneyColors>()!;
        final s = t.colorScheme;
        for (final bg in [
          s.surface,
          s.surfaceContainerLowest,
          s.surfaceContainer,
          s.surfaceContainerHigh,
        ]) {
          expect(contrast(m.owed, bg), greaterThanOrEqualTo(4.5));
          expect(contrast(m.owe, bg), greaterThanOrEqualTo(4.5));
          expect(contrast(m.settled, bg), greaterThanOrEqualTo(4.5));
        }
        expect(contrast(m.onVial, m.vial), greaterThanOrEqualTo(7));
        expect(contrast(s.onSurface, s.surface), greaterThanOrEqualTo(7));
        expect(
          contrast(s.onSurfaceVariant, s.surface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(m.onOwedContainer, m.owedContainer),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(m.onOweContainer, m.oweContainer),
          greaterThanOrEqualTo(4.5),
        );
      });
    }

    test('withWeight re-resolves the font file for the new weight', () {
      final row = AppTheme.light().textTheme.titleMedium!;
      final bold = row.withWeight(FontWeight.w700);
      expect(bold.fontWeight, FontWeight.w700);
      expect(bold.fontFamily, isNot(row.fontFamily));
    });
  });

  group('MoneyColors', () {
    test('forBalance maps sign to color', () {
      const m = MoneyColors.light;
      expect(m.forBalance(1), m.owed);
      expect(m.forBalance(-1), m.owe);
      expect(m.forBalance(0), m.settled);
    });

    test('lerp and copyWith', () {
      final mid = MoneyColors.light.lerp(MoneyColors.dark, 0.5);
      expect(mid.vial, Palette.vial);
      expect(MoneyColors.light.lerp(null, 0.5), same(MoneyColors.light));
      expect(MoneyColors.light.copyWith(owe: Palette.plumb).owe, Palette.plumb);
    });
  });

  group('AvatarTones', () {
    test('FNV-1a is stable and spreads across tones', () {
      // FNV-1a 32 of "a" is 0xE40C292C; 0xE40C292C % 8 == 4 (sand).
      expect(AvatarTones.forId('a'), same(AvatarTones.all[4]));
      final used = {
        for (var i = 0; i < 64; i++) AvatarTones.forId('person-$i'),
      };
      expect(used.length, AvatarTones.all.length);
      expect(
        AvatarTones.forId('00000000-0000-7000-8000-000000000001'),
        same(AvatarTones.forId('00000000-0000-7000-8000-000000000001')),
      );
    });

    test('every tone pair is readable', () {
      for (final t in AvatarTones.all) {
        expect(contrast(t.lightFg, t.lightBg), greaterThanOrEqualTo(7));
        expect(contrast(t.darkFg, t.darkBg), greaterThanOrEqualTo(7));
      }
    });
  });
}
