// QA VISUAL: the Point to Point rules (docs/design/DESIGN.md and renders
// 1-6) checked on the real screens: colour only for money direction,
// settled never green, tabular figures on amounts, the 20 dp text gutter,
// no leading tile on group rows, and the bundled Familjen Grotesk.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/theme/tokens.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'visual_harness.dart';

const Variant light412 = (
  size: Size(412, 915),
  scale: 1.0,
  brightness: Brightness.light,
);

/// Every (text, colour, tabular) span of the visible paragraphs.
List<(String, Color?, bool)> spans(WidgetTester tester) {
  final out = <(String, Color?, bool)>[];
  for (final e in find.byType(RichText).evaluate()) {
    final ro = e.renderObject;
    if (ro is! RenderParagraph) continue;
    void walk(InlineSpan s, TextStyle? inherited) {
      if (s is! TextSpan) return;
      final style = inherited?.merge(s.style) ?? s.style;
      final tab =
          style?.fontFeatures?.any(
            (f) => f == const FontFeature.tabularFigures(),
          ) ??
          false;
      if (s.text != null && s.text!.trim().isNotEmpty) {
        out.add((s.text!, style?.color, tab));
      }
      for (final c in s.children ?? const <InlineSpan>[]) {
        walk(c, style);
      }
    }

    walk(ro.text, null);
  }
  return out;
}

bool isGreen(Color c) {
  final hsv = HSVColor.fromColor(c);
  return hsv.saturation > 0.2 && hsv.hue >= 75 && hsv.hue <= 165;
}

/// Text allowed in a direction colour: amounts and direction words or
/// sentences.
final RegExp directionText = RegExp(
  r'^(?:[+−]?\s?(?:[₹$€¥]|KD)\s?[\d,.]+'
  r'|[+−]?\s?(?:[₹$€¥]|KD)\s?'
  r'|[\d,.]+'
  r"|you owe|you're owed|owes you|you lent|you borrowed|you pay|pays you"
  r"|You owe overall|You're owed overall|You owe in this group"
  r"|You're owed in this group|You owe .+ overall|.+ owes you overall"
  r'|gets back|owes)$',
);

void main() {
  configureVisualTests();

  test('the bundled font is Familjen Grotesk in both themes', () {
    for (final t in [AppTheme.light(), AppTheme.dark()]) {
      for (final s in [
        t.textTheme.displayLarge!,
        t.textTheme.titleMedium!,
        t.textTheme.bodySmall!,
      ]) {
        expect(s.fontFamily, startsWith('FamiljenGrotesk'));
      }
    }
    for (final f in ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      expect(
        File('assets/google_fonts/FamiljenGrotesk-$f.ttf').existsSync(),
        isTrue,
        reason: f,
      );
    }
    expect(File('assets/google_fonts/OFL.txt').existsSync(), isTrue);
  });

  test('settled is never green and owed/owe are not green either', () {
    for (final m in [MoneyColors.light, MoneyColors.dark]) {
      expect(isGreen(m.settled), isFalse);
      expect(isGreen(m.owed), isFalse);
      expect(isGreen(m.owe), isFalse);
      expect(m.forBalance(0), m.settled);
      expect(m.forDirection(MoneyDirection.settled), m.settled);
    }
  });

  for (final b in Brightness.values) {
    testWidgets('colour is used only for money direction (${b.name})', (
      tester,
    ) async {
      late VisualWorld w;
      await tester.runAsync(() async => w = await VisualWorld.realistic());
      final money = b == Brightness.dark ? MoneyColors.dark : MoneyColors.light;
      final wrong = <String>[];
      var colored = 0;
      for (final s in [
        'home',
        'group',
        'group KWD',
        'activity',
        'settle',
        'person',
        'expense',
        'sync',
      ]) {
        await pumpVisual(
          tester,
          w.phone,
          v: (size: light412.size, scale: 1.0, brightness: b),
          location: w.screens[s]!,
        );
        for (final (text, color, _) in spans(tester)) {
          if (color == null) continue;
          if (color == money.owed || color == money.owe) {
            colored++;
            if (!directionText.hasMatch(text.trim())) {
              wrong.add('$s: "$text"');
            }
          }
          expect(isGreen(color), isFalse, reason: '$s: "$text" is green');
        }
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.runAsync(w.phone.dispose);
      expect(colored, greaterThan(10));
      expect(wrong, isEmpty);
    });
  }

  testWidgets('a settled group shows its zero in settled ink, unsigned', (
    tester,
  ) async {
    late VisualPhone p;
    late String g;
    await tester.runAsync(() async {
      p = await VisualPhone.create();
      final t = await p.group('Cabin weekend', ['Sam']);
      g = t.g;
      await p.add(
        g,
        total: 10000,
        payer: t.m['me']!,
        split: [t.m['me']!, t.m['Sam']!],
      );
      await p.pay(g, from: t.m['Sam']!, to: t.m['me']!, amount: 5000);
    });
    for (final b in Brightness.values) {
      await pumpVisual(
        tester,
        p,
        v: (size: light412.size, scale: 1.0, brightness: b),
        location: Routes.group(g),
      );
      final money = b == Brightness.dark ? MoneyColors.dark : MoneyColors.light;
      final zero = spans(tester).where((s) => s.$1 == '0' || s.$1 == '₹0');
      expect(zero, isNotEmpty);
      for (final z in zero) {
        expect(z.$2, money.settled, reason: '${b.name} "${z.$1}"');
      }
      expect(find.textContaining('+₹0'), findsNothing);
      expect(find.textContaining('−₹0'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await pumpVisual(
        tester,
        p,
        v: (size: light412.size, scale: 1.0, brightness: b),
        location: Routes.home,
      );
      expect(find.text('settled up'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    }
    await tester.runAsync(p.dispose);
  });

  testWidgets('stand-alone amounts use tabular figures', (tester) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());
    final proportional = <String>[];
    for (final s in [
      'home',
      'group',
      'activity',
      'settle',
      'person',
      'expense',
    ]) {
      await pumpVisual(tester, w.phone, v: light412, location: w.screens[s]!);
      for (final (text, _, tab) in spans(tester)) {
        if (kPureAmount.hasMatch(text.trim()) && !tab) {
          proportional.add('$s: "$text"');
        }
      }
      await tester.pumpWidget(const SizedBox.shrink());
    }
    await tester.runAsync(w.phone.dispose);
    expect(proportional, isEmpty);
  });

  testWidgets('headings and the hero sit on the 20 dp text gutter', (
    tester,
  ) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());
    await pumpVisual(tester, w.phone, v: light412, location: Routes.home);
    expect(tester.getTopLeft(find.byType(BalanceHero)).dx, 20);
    expect(tester.getTopLeft(find.text('Groups')).dx, 20);
    expect(tester.getTopLeft(find.text('People')).dx, 20);
    await tester.pumpWidget(const SizedBox.shrink());
    await pumpVisual(
      tester,
      w.phone,
      v: light412,
      location: Routes.group(w.group),
    );
    expect(tester.getTopLeft(find.byType(GroupBalanceHero)).dx, 20);
    expect(tester.getTopLeft(find.text('Expenses')).dx, 20);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(w.phone.dispose);
  });

  testWidgets('group rows on Home have no leading tile; people have faces', (
    tester,
  ) async {
    late VisualWorld w;
    await tester.runAsync(() async => w = await VisualWorld.realistic());
    await pumpVisual(tester, w.phone, v: light412, location: Routes.home);
    final rows = find.byType(BalanceRow);
    var groups = 0, people = 0;
    for (final e in rows.evaluate()) {
      final row = e.widget as BalanceRow;
      final avatars = find.descendant(
        of: find.byWidget(row),
        matching: find.byType(PersonAvatar),
      );
      if (row.kind == BalanceRowKind.group) {
        groups++;
        expect(avatars, findsNothing, reason: row.title);
        expect(
          find.descendant(of: find.byWidget(row), matching: find.byType(Icon)),
          findsNothing,
          reason: row.title,
        );
      } else {
        people++;
        expect(avatars, findsOneWidget, reason: row.title);
      }
    }
    expect(groups, 2);
    expect(people, greaterThanOrEqualTo(2));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.runAsync(w.phone.dispose);
  });
}
