// Golden gallery: the design-system widgets composed as the reference
// screens in docs/design/point-to-point/ (412 x 915 dp at 2x, like the
// reference PNGs), with the real bundled fonts.
// Regenerate with:
//   flutter test --update-goldens test/ui/widgets/gallery_golden_test.dart
@Tags(['golden'])
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/theme/app_theme.dart';

import 'gallery_screens.dart';
import 'kit_harness.dart';

const Size _phone = Size(412, 915);

Future<void> _pumpScreen(
  WidgetTester tester,
  Widget screen, {
  required Brightness brightness,
  double textScale = 1,
  Size size = _phone,
}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  // Status bar and gesture area, as on the reference renders.
  tester.view.padding = const FakeViewPadding(top: 36 * 2, bottom: 24 * 2);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light(),
      darkTheme: AppTheme.dark(),
      themeMode: brightness == Brightness.dark
          ? ThemeMode.dark
          : ThemeMode.light,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: screen,
    ),
  );
  // Let the indeterminate spinners reach a fixed frame.
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUpAll(() async {
    configureKitTests();
    await loadRealFonts();
  });

  final screens = <String, Widget Function()>{
    'home': () => const HomeScreen(),
    'group': () => const GroupScreen(),
    'add_expense': () => const AddExpenseScreen(),
    'settle_up': () => const SettleScreen(),
    'sync': () => const SyncScreen(),
  };

  for (final e in screens.entries) {
    for (final b in Brightness.values) {
      final name = '${e.key}_${b.name}';
      testWidgets('gallery $name', (tester) async {
        await _withShadows(() async {
          await _pumpScreen(tester, e.value(), brightness: b);
          expect(tester.takeException(), isNull);
          await expectLater(
            find.byType(MaterialApp),
            matchesGoldenFile('goldens/$name.png'),
          );
        });
      });
    }
  }

  testWidgets('gallery home_light_2x text scale', (tester) async {
    await _withShadows(() async {
      await _pumpScreen(
        tester,
        const HomeScreen(),
        brightness: Brightness.light,
        textScale: 2,
        size: const Size(412, 1600),
      );
      expect(tester.takeException(), isNull);
      await expectLater(
        find.byType(MaterialApp),
        matchesGoldenFile('goldens/home_light_textscale2.png'),
      );
    });
  });
}

/// Renders the FAB's soft shadow as on device instead of the solid slab
/// flutter_test draws by default; restores the flag before the test ends.
Future<void> _withShadows(Future<void> Function() body) async {
  debugDisableShadows = false;
  try {
    await body();
  } finally {
    debugDisableShadows = true;
  }
}
