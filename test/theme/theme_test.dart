// Theme checks (SPEC 11.4) for the Point to Point design.
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/theme/tokens.dart';

import '../ui/widgets/kit_harness.dart';

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
  setUpAll(configureKitTests);

  group('colour schemes', () {
    test('both themes build, Material 3, hand-built schemes', () {
      final light = AppTheme.light();
      final dark = AppTheme.dark();
      expect(light.useMaterial3, isTrue);
      expect(light.colorScheme, AppTheme.lightScheme);
      expect(dark.colorScheme, AppTheme.darkScheme);
      expect(light.brightness, Brightness.light);
      expect(dark.brightness, Brightness.dark);
    });

    test('ink on stone, white cards, Point to Point tokens', () {
      const l = AppTheme.lightScheme;
      expect(l.primary, const Color(0xFF16191D));
      expect(l.surface, const Color(0xFFEEF0EF));
      expect(l.surfaceContainerLowest, const Color(0xFFFFFFFF));
      expect(l.surfaceContainer, const Color(0xFFE4E7E6));
      expect(l.surfaceContainerHigh, const Color(0xFFD9DDDC));
      expect(l.onSurfaceVariant, const Color(0xFF5A6066));
      expect(l.outlineVariant, const Color(0xFFDCE0DF));
      const d = AppTheme.darkScheme;
      expect(d.primary, const Color(0xFFE9EBEC));
      expect(d.onPrimary, const Color(0xFF0F1316));
      expect(d.surface, const Color(0xFF0F1316));
      expect(d.surfaceContainerLowest, const Color(0xFF171C20));
      expect(d.surfaceContainerHigh, const Color(0xFF36424B));
    });

    test('money colours never leak into ColorScheme roles', () {
      for (final (scheme, money) in [
        (AppTheme.lightScheme, MoneyColors.light),
        (AppTheme.darkScheme, MoneyColors.dark),
      ]) {
        final roles = <Color>[
          scheme.primary,
          scheme.secondary,
          scheme.tertiary,
          scheme.primaryContainer,
          scheme.secondaryContainer,
          scheme.tertiaryContainer,
          scheme.surfaceTint,
          scheme.inversePrimary,
        ];
        for (final c in [money.owed, money.owe]) {
          expect(roles, isNot(contains(c)));
        }
      }
    });

    test('no surface tint (flat, tone not shadow)', () {
      expect(AppTheme.lightScheme.surfaceTint, Colors.transparent);
      expect(AppTheme.darkScheme.surfaceTint, Colors.transparent);
    });
  });

  group('MoneyColors', () {
    test('present in both themes with Lagoon and Kiln', () {
      final l = AppTheme.light().extension<MoneyColors>()!;
      final d = AppTheme.dark().extension<MoneyColors>()!;
      expect(l.owed, const Color(0xFF0B5C8E));
      expect(l.owe, const Color(0xFFA3460B));
      expect(l.settled, const Color(0xFF5A6066));
      expect(d.owed, const Color(0xFF86BDEB));
      expect(d.owe, const Color(0xFFF2A673));
      expect(l.owedContainer, const Color(0xFFE2EEF6));
      expect(l.oweContainer, const Color(0xFFFBEADF));
    });

    test('direction helpers', () {
      const m = MoneyColors.light;
      expect(m.forBalance(5), m.owed);
      expect(m.forBalance(-5), m.owe);
      expect(m.forBalance(0), m.settled);
      expect(m.forDirection(MoneyDirection.neutral), m.neutral);
      expect(m.containerFor(MoneyDirection.owe), m.oweContainer);
      expect(m.containerFor(MoneyDirection.settled), m.settledContainer);
      expect(MoneyDirection.of(1), MoneyDirection.owed);
      expect(MoneyDirection.of(-1), MoneyDirection.owe);
      expect(MoneyDirection.of(0), MoneyDirection.settled);
    });

    test('copyWith and lerp', () {
      const m = MoneyColors.light;
      expect(m.copyWith(owed: Colors.black).owed, Colors.black);
      expect(m.lerp(MoneyColors.dark, 0).owed, m.owed);
      expect(m.lerp(MoneyColors.dark, 1).owe, MoneyColors.dark.owe);
      expect(m.lerp(null, 0.5), m);
    });
  });

  group('contrast (WCAG AA)', () {
    for (final (name, scheme, money) in [
      ('light', AppTheme.lightScheme, MoneyColors.light),
      ('dark', AppTheme.darkScheme, MoneyColors.dark),
    ]) {
      test('$name: money and text colours on cards and stone', () {
        for (final bg in [scheme.surface, scheme.surfaceContainerLowest]) {
          expect(contrast(money.owed, bg), greaterThanOrEqualTo(4.5));
          expect(contrast(money.owe, bg), greaterThanOrEqualTo(4.5));
          expect(contrast(money.settled, bg), greaterThanOrEqualTo(4.5));
          expect(contrast(scheme.onSurface, bg), greaterThanOrEqualTo(7));
          expect(
            contrast(scheme.onSurfaceVariant, bg),
            greaterThanOrEqualTo(4.5),
          );
        }
        expect(
          contrast(scheme.onPrimary, scheme.primary),
          greaterThanOrEqualTo(7),
        );
      });
    }

    test('light outline reaches 3:1 on stone (chip and segment borders)', () {
      expect(
        contrast(AppTheme.lightScheme.outline, AppTheme.lightScheme.surface),
        greaterThanOrEqualTo(3),
      );
    });
  });

  group('type', () {
    test('one family, no letter-spacing changes', () {
      final t = AppTheme.light().textTheme;
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
        expect(s!.fontFamily, startsWith('FamiljenGrotesk'));
        expect(s.letterSpacing, 0);
      }
    });

    test('scale follows the direction doc', () {
      final t = AppTheme.light().textTheme;
      expect(t.displayLarge!.fontSize, 62);
      expect(t.displayLarge!.fontWeight, FontWeight.w600);
      expect(t.displaySmall!.fontSize, 46);
      expect(t.headlineLarge!.fontSize, 44);
      expect(t.titleLarge!.fontSize, 22);
      expect(t.titleMedium!.fontSize, 16);
      expect(t.bodyLarge!.fontSize, 15);
      expect(t.bodySmall!.fontSize, 13);
      expect(t.labelSmall!.fontSize, 12);
      expect(
        t.displayLarge!.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );
    });

    testWidgets('amount style is 17/22, 600, tabular', (tester) async {
      late TextStyle amount;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: Builder(
            builder: (context) {
              amount = AppType.amount(context);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(amount.fontSize, 17);
      expect(amount.fontWeight, FontWeight.w600);
      expect(amount.fontFeatures, contains(const FontFeature.tabularFigures()));
    });

    test('withWeight re-resolves the bundled face', () {
      final s = AppTheme.light().textTheme.bodySmall!.withWeight(
        FontWeight.w700,
      );
      expect(s.fontFamily, 'FamiljenGrotesk_700');
      expect(s.fontWeight, FontWeight.w700);
    });
  });

  group('bundled fonts', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('all four weights and the licence are bundled', () async {
      expect(AppFonts.bundledWeights, [
        FontWeight.w400,
        FontWeight.w500,
        FontWeight.w600,
        FontWeight.w700,
      ]);
      for (final f in [
        'FamiljenGrotesk-Regular.ttf',
        'FamiljenGrotesk-Medium.ttf',
        'FamiljenGrotesk-SemiBold.ttf',
        'FamiljenGrotesk-Bold.ttf',
      ]) {
        final data = await rootBundle.load('assets/google_fonts/$f');
        expect(data.lengthInBytes, greaterThan(50000), reason: f);
      }
      final ofl = await rootBundle.loadString(AppFonts.licenseAsset);
      expect(ofl, contains('SIL OPEN FONT LICENSE'));
      expect(ofl, contains('Familjen Grotesk'));
    });

    test('rupee sign, tabular figures and the weights render', () async {
      await loadRealFonts();
      double width(String text, String family, {double size = 40}) {
        final p = TextPainter(
          text: TextSpan(
            text: text,
            style: TextStyle(fontFamily: family, fontSize: size),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        return p.width;
      }

      // The test font draws every glyph as a 1 em square; Familjen
      // Grotesk's own ₹ is narrower, so it really comes from the font.
      final rupee = width('₹', 'FamiljenGrotesk_600');
      expect(rupee, greaterThan(10));
      expect(rupee, lessThan(36));
      // Tabular figures: every digit has the same advance.
      for (final w in ['regular', '500', '600', '700']) {
        final f = 'FamiljenGrotesk_$w';
        expect(width('1111', f), closeTo(width('0000', f), 0.01));
        expect(width('7777', f), closeTo(width('4444', f), 0.01));
      }
      // Weights are real, different faces.
      final regular = width('Settle up together', 'FamiljenGrotesk_regular');
      final medium = width('Settle up together', 'FamiljenGrotesk_500');
      final semi = width('Settle up together', 'FamiljenGrotesk_600');
      final bold = width('Settle up together', 'FamiljenGrotesk_700');
      expect({regular, medium, semi, bold}.length, 4);
    });
  });
}
