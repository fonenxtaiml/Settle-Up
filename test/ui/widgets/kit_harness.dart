// Shared helpers for the design-system widget tests (SPEC 11.4).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/theme/app_theme.dart';

/// Fonts are bundled; never fetch in tests either.
void configureKitTests() {
  GoogleFonts.config.allowRuntimeFetching = false;
}

/// Wraps [child] in the app theme with the given brightness and text scale.
Widget kitApp(
  Widget child, {
  Brightness brightness = Brightness.light,
  double textScale = 1.0,
  bool disableAnimations = false,
  bool scroll = true,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.light(),
    darkTheme: AppTheme.dark(),
    themeMode: brightness == Brightness.dark ? ThemeMode.dark : ThemeMode.light,
    home: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(textScale),
          disableAnimations: disableAnimations,
        ),
        child: Scaffold(
          body: SafeArea(
            child: scroll ? SingleChildScrollView(child: child) : child,
          ),
        ),
      ),
    ),
  );
}

/// The four variants every widget is tested in (SPEC 11.4).
const List<(Brightness, double)> kitVariants = [
  (Brightness.light, 1.0),
  (Brightness.dark, 1.0),
  (Brightness.light, 2.0),
  (Brightness.dark, 2.0),
];

String variantName((Brightness, double) v) =>
    '${v.$1 == Brightness.dark ? 'dark' : 'light'} @${v.$2}x';

/// Pumps [build] in light and dark at text scale 1.0 and 2.0 on a 360 dp
/// wide phone and expects no exception (overflow included).
void testKitVariants(
  String description,
  Widget Function() build, {
  Size size = const Size(360, 800),
  bool scroll = true,
  Future<void> Function(WidgetTester tester, (Brightness, double) v)? verify,
}) {
  for (final v in kitVariants) {
    testWidgets('$description (${variantName(v)})', (tester) async {
      tester.view.physicalSize = size * 3;
      tester.view.devicePixelRatio = 3;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        kitApp(build(), brightness: v.$1, textScale: v.$2, scroll: scroll),
      );
      await tester.pump(const Duration(milliseconds: 800));
      expect(tester.takeException(), isNull);
      if (verify != null) await verify(tester, v);
    });
  }
}

/// A minimal valid expense for row tests.
Expense testExpense({
  String id = 'e1',
  String description = 'Dinner at the shack',
  String category = 'food.dining',
  ExpenseKind kind = ExpenseKind.expense,
  required Map<String, int> paid,
  required Map<String, int> owed,
  String currency = 'GBP',
}) {
  final total = paid.values.fold(0, (a, b) => a + b);
  return Expense(
    id: id,
    groupId: 'g1',
    kind: kind,
    description: description,
    category: kind == ExpenseKind.payment ? 'payment' : category,
    date: DateTime.utc(2026, 11, 9, 12),
    notes: '',
    money: MoneyBlock(
      total: total,
      currency: currency,
      paidBy: SplitSpec(SplitMethod.exact, paid),
      owedBy: SplitSpec(SplitMethod.exact, owed),
      paid: paid,
      owed: owed,
    ),
    createdBy: paid.keys.first,
    createdAt: DateTime.utc(2026, 11, 9, 12),
    updatedHlc: const Hlc(0, 0, 'device'),
    paymentMethod: kind == ExpenseKind.payment ? PaymentMethod.cash : null,
  );
}

/// Loads the bundled Atkinson Hyperlegible Next weights and the Material
/// icon font so goldens render real glyphs instead of test boxes.
Future<void> loadRealFonts() async {
  const files = {
    'regular': 'AtkinsonHyperlegibleNext-Regular.ttf',
    '600': 'AtkinsonHyperlegibleNext-SemiBold.ttf',
    '700': 'AtkinsonHyperlegibleNext-Bold.ttf',
    '800': 'AtkinsonHyperlegibleNext-ExtraBold.ttf',
  };
  Future<ByteData> asset(String name) =>
      rootBundle.load('assets/google_fonts/$name');

  // The family-variant names google_fonts asks the engine for...
  for (final e in files.entries) {
    final loader = FontLoader('AtkinsonHyperlegibleNext_${e.key}')
      ..addFont(asset(e.value));
    await loader.load();
  }
  // ...and the fallback family it lists, with every weight.
  final fallback = FontLoader('AtkinsonHyperlegibleNext');
  for (final f in files.values) {
    fallback.addFont(asset(f));
  }
  await fallback.load();

  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}
