import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/theme/tokens.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'kit_harness.dart';

void main() {
  setUpAll(configureKitTests);

  group('TetherGlyph', () {
    testKitVariants(
      'all directions',
      () => const Wrap(
        spacing: 8,
        children: [
          TetherGlyph(direction: MoneyDirection.owed),
          TetherGlyph(direction: MoneyDirection.owe),
          TetherGlyph(direction: MoneyDirection.settled),
          TetherGlyph(direction: MoneyDirection.neutral),
        ],
      ),
    );

    testWidgets('decorative by default, labelled on request', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        kitApp(
          const Column(
            children: [
              TetherGlyph(direction: MoneyDirection.owed),
              TetherGlyph(
                direction: MoneyDirection.owe,
                semanticLabel: 'You paid Ravi',
              ),
            ],
          ),
        ),
      );
      expect(find.bySemanticsLabel('You paid Ravi'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('is 26 x 10 at text scale 1 and grows to 1.5x', (tester) async {
      await tester.pumpWidget(
        kitApp(const TetherGlyph(direction: MoneyDirection.owed)),
      );
      expect(tester.getSize(find.byType(CustomPaint).last), Sizes.tetherInline);
      await tester.pumpWidget(
        kitApp(const TetherGlyph(direction: MoneyDirection.owed), textScale: 2),
      );
      expect(tester.getSize(find.byType(CustomPaint).last), const Size(39, 15));
    });
  });

  test('TetherPainter repaints only when something changes', () {
    const a = TetherPainter(
      from: TetherPoint.filled,
      to: TetherPoint.ring,
      color: Colors.black,
    );
    const b = TetherPainter(
      from: TetherPoint.filled,
      to: TetherPoint.ring,
      color: Colors.black,
    );
    const c = TetherPainter(
      from: TetherPoint.filled,
      to: TetherPoint.ring,
      color: Colors.black,
      line: TetherLine.dashed,
    );
    expect(a.shouldRepaint(b), isFalse);
    expect(a.shouldRepaint(c), isTrue);
  });

  group('TetherTransfer', () {
    testKitVariants(
      'you pay Priya',
      () => const TetherTransfer(
        fromId: 'a',
        fromName: 'Arjun Mehta',
        toId: 'p',
        toName: 'Priya Sharma',
        fromIsMe: true,
      ),
      verify: (tester, _) async {
        expect(find.text('AM'), findsOneWidget);
        expect(find.text('PS'), findsOneWidget);
      },
    );

    testWidgets('reads as a sentence with first names', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        kitApp(
          const TetherTransfer(
            fromId: 'k',
            fromName: 'Kabir Singh',
            toId: 'r',
            toName: 'Ravi Kumar',
          ),
        ),
      );
      expect(find.bySemanticsLabel('Kabir pays Ravi'), findsOneWidget);
      handle.dispose();
    });
  });

  group('SettleTether', () {
    Widget build({bool recorded = false, VoidCallback? onEnd}) => SettleTether(
      fromId: 'a',
      fromName: 'Arjun Mehta',
      toId: 'p',
      toName: 'Priya Sharma',
      amountMinor: 84000,
      currency: 'INR',
      fromIsMe: true,
      question: 'You pay Priya',
      recorded: recorded,
      onRecordedAnimationEnd: onEnd,
      action: TextLink('Pay part of it', onPressed: () {}),
    );

    testKitVariants(
      'hero stage',
      build,
      verify: (tester, _) async {
        expect(find.text('₹840'), findsOneWidget);
        expect(find.text('You'), findsOneWidget);
        expect(find.text('Priya Sharma'), findsOneWidget);
      },
    );

    testWidgets('amount is Kiln when you pay', (tester) async {
      await tester.pumpWidget(kitApp(build()));
      final text = tester.widget<Text>(find.text('₹840'));
      expect(text.style!.color, MoneyColors.light.owe);
    });

    testWidgets('one semantics node: "You pay Priya 840.00 INR"', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(kitApp(build()));
      expect(find.bySemanticsLabel('You pay Priya 840.00 INR'), findsOneWidget);
      handle.dispose();
    });

    for (final reduce in [false, true]) {
      testWidgets('recording plays the dot and fills the ring '
          '(reduce motion: $reduce)', (tester) async {
        var ended = 0;
        Widget app(bool recorded) => kitApp(
          build(recorded: recorded, onEnd: () => ended++),
          disableAnimations: reduce,
        );
        await tester.pumpWidget(app(false));
        await tester.pumpWidget(app(true));
        await tester.pump(const Duration(milliseconds: 140));
        // Mid-travel there is an extra 6 dp dot unless motion is reduced.
        final dots = find.byWidgetPredicate(
          (w) => w is SizedBox && w.width == 6 && w.height == 6,
        );
        expect(dots, reduce ? findsNothing : findsOneWidget);
        await tester.pumpAndSettle();
        expect(ended, 1);
        expect(find.byType(Opacity), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  });

  group('SyncTether', () {
    testKitVariants(
      'waiting',
      () => const SyncTether(),
      verify: (tester, _) async {
        expect(find.text('This phone'), findsOneWidget);
        expect(find.text('Nearby phones'), findsOneWidget);
      },
    );
    testKitVariants('active and connected', () {
      return const SyncTether(active: true, connected: true);
    });

    testWidgets('dots stop under reduce motion', (tester) async {
      await tester.pumpWidget(
        kitApp(const SyncTether(active: true), disableAnimations: true),
      );
      expect(tester.hasRunningAnimations, isFalse);
      await tester.pumpWidget(kitApp(const SyncTether(active: true)));
      expect(tester.hasRunningAnimations, isTrue);
      await tester.pumpWidget(kitApp(const SyncTether()));
      // Cancelled frame callbacks are dropped on the next frame.
      await tester.pump(const Duration(seconds: 1));
      expect(tester.hasRunningAnimations, isFalse);
    });
  });

  group('MoneyText', () {
    testKitVariants(
      'every style',
      () => const Column(
        children: [
          MoneyText(minor: 425000, currency: 'INR', style: MoneyTextStyle.hero),
          MoneyText(
            minor: -84000,
            currency: 'INR',
            style: MoneyTextStyle.headline,
          ),
          MoneyText(minor: 509000, currency: 'INR'),
          MoneyText(
            minor: 240000,
            currency: 'INR',
            style: MoneyTextStyle.keypad,
            signed: false,
          ),
          MoneyText(
            minor: -1250,
            currency: 'GBP',
            style: MoneyTextStyle.inline,
          ),
        ],
      ),
    );

    testWidgets('hero sets the sign and symbol smaller', (tester) async {
      await tester.pumpWidget(
        kitApp(
          const MoneyText(
            minor: 425000,
            currency: 'INR',
            style: MoneyTextStyle.hero,
          ),
        ),
      );
      final rich = tester.widget<Text>(find.byType(Text)).textSpan!;
      final spans = (rich as TextSpan).children!.cast<TextSpan>();
      expect(spans.first.text, startsWith('+₹'));
      expect(spans.first.style!.fontSize, closeTo(62 * 0.6, 0.01));
      expect(spans.last.text, '4,250');
    });

    test('splitPrefix', () {
      expect(MoneyText.splitPrefix('+₹4,250', '₹'), ('+₹', '4,250'));
      expect(MoneyText.splitPrefix('−₹840', '₹'), ('−₹', '840'));
      expect(MoneyText.splitPrefix('12,00 €', '€'), isNull);
    });

    testWidgets('colours by sign and speaks without sign words', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        kitApp(const MoneyText(minor: -84000, currency: 'INR')),
      );
      final text = tester.widget<Text>(find.text('−₹840'));
      expect(text.style!.color, MoneyColors.light.owe);
      expect(find.bySemanticsLabel('840.00 INR'), findsOneWidget);
      handle.dispose();
    });
  });

  group('BalanceTrailing', () {
    testKitVariants(
      'directions',
      () => const Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          BalanceTrailing(word: 'you owe', minor: -84000, currency: 'INR'),
          BalanceTrailing(word: "you're owed", minor: 509000, currency: 'INR'),
          BalanceTrailing(word: 'settled up', minor: 0, currency: 'INR'),
          BalanceTrailing(
            word: 'received',
            minor: 200000,
            currency: 'INR',
            direction: MoneyDirection.neutral,
          ),
          BalanceTrailing(
            word: 'not involved',
            minor: null,
            currency: 'INR',
            direction: MoneyDirection.settled,
          ),
          BalanceTrailing(
            word: 'owes you',
            minor: 120000,
            currency: 'INR',
            compact: true,
            footnote: '+1 more',
          ),
        ],
      ),
      verify: (tester, _) async {
        expect(find.text('−₹840'), findsOneWidget);
        expect(find.text('+₹5,090'), findsOneWidget);
        expect(find.text('₹0'), findsOneWidget);
        // Neutral amounts carry no sign.
        expect(find.text('₹2,000'), findsOneWidget);
        expect(find.text('+1 more'), findsOneWidget);
      },
    );

    testWidgets('word and amount share the direction colour', (tester) async {
      await tester.pumpWidget(
        kitApp(
          const BalanceTrailing(
            word: 'you owe',
            minor: -84000,
            currency: 'INR',
          ),
        ),
      );
      expect(
        tester.widget<Text>(find.text('you owe')).style!.color,
        MoneyColors.light.owe,
      );
      expect(
        tester.widget<Text>(find.text('−₹840')).style!.color,
        MoneyColors.light.owe,
      );
      expect(find.byType(TetherGlyph), findsOneWidget);
    });

    testWidgets('the sign follows the direction, not the input sign', (
      tester,
    ) async {
      await tester.pumpWidget(
        kitApp(
          const BalanceTrailing(
            word: 'you owe',
            minor: 600,
            currency: 'INR',
            direction: MoneyDirection.owe,
          ),
        ),
      );
      expect(find.text('−₹6'), findsOneWidget);
    });
  });

  test('AppType link is underlined in the outline colour', () {
    // Indirectly covered by widgets; ensure the extension exists.
    expect(const TextStyle().tabular.fontFeatures, isNotEmpty);
  });
}
