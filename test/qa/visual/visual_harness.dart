// QA VISUAL harness: the real app (router, theme, screens) over the real
// data layer (Ledger on MemoryOpStore, KvSettingsRepository,
// MemoryGroupKeyStore), at a chosen phone size, text scale and theme, with
// helpers that collect layout overflows and find amounts that were cut.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ledger_state.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/app.dart';
import 'package:settle_up/ui/dev/fake_sync_engine.dart';
import 'package:settle_up/ui/providers.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';

/// Sun 9 Nov 2026, 10:00 UTC.
final DateTime kNow = DateTime.utc(2026, 11, 9, 10);

/// 40, 60 and 120 characters: the editor limits for a member (onboarding),
/// a group and a description.
const String kName40 = 'Bartholomew Alexander Fitzgerald-Johnsto';
const String kGroup60 =
    'Annual extended family reunion trip to the Western Ghats 202';
const String kDesc120 =
    'Dinner, drinks and dessert at the beach shack on the last night, '
    'including the tip and the cab back to the homestay ok';

/// Sequential ids with a fixed 8-hex prefix.
final class QaIds implements IdGenerator {
  QaIds(this.prefix);
  final String prefix;
  int _n = 0;
  @override
  String newId() {
    final n = (++_n).toRadixString(16).padLeft(12, '0');
    return '$prefix-0000-7000-8000-$n';
  }
}

/// One phone on the real data layer.
final class VisualPhone {
  VisualPhone._(this.store, this.settings, this.ledger);

  final MemoryOpStore store;
  final KvSettingsRepository settings;
  final Ledger ledger;
  late final FakeSyncEngine engine = FakeSyncEngine(step: Duration.zero);
  int _clock = kNow.millisecondsSinceEpoch - 3600 * 1000;

  /// Call inside `tester.runAsync`.
  static Future<VisualPhone> create({
    String name = 'Alex',
    String home = 'INR',
    bool onboard = true,
  }) async {
    final store = MemoryOpStore();
    await store.open();
    final settings = await KvSettingsRepository.open(
      store,
      defaultDeviceName: 'Pixel 8',
      ids: QaIds('dddd0000'),
      localeName: 'en_IN',
    );
    if (onboard) {
      await settings.completeOnboarding(displayName: name, homeCurrency: home);
    }
    late VisualPhone phone;
    final ledger = await Ledger.open(
      store: store,
      keys: MemoryGroupKeyStore(),
      settings: settings,
      ids: QaIds('aaaa0000'),
      nowMillis: () => phone._clock += 1000,
    );
    phone = VisualPhone._(store, settings, ledger);
    return phone;
  }

  PersonId get me => settings.profile!.personId;
  LedgerState get state => ledger.current.state;
  GroupState gs(GroupId g) => state.groups[g]!;

  Future<({GroupId g, Map<String, MemberId> m})> group(
    String name,
    List<String> others, {
    String currency = 'INR',
  }) async {
    final g = await ledger.createGroup(
      NewGroup(
        name: name,
        type: GroupType.trip,
        currency: currency,
        simplifyDebts: true,
        newMemberNames: others,
      ),
    );
    final m = <String, MemberId>{};
    for (final mem in gs(g).members.values) {
      m[mem.personId == me ? 'me' : mem.displayName] = mem.id;
    }
    return (g: g, m: m);
  }

  Future<ExpenseId> add(
    GroupId g, {
    required int total,
    required MemberId payer,
    List<MemberId> split = const [],
    SplitSpec? owedBy,
    String currency = 'INR',
    String description = 'Dinner',
  }) => ledger.addExpense(
    ExpenseDraft(
      groupId: g,
      description: description,
      total: total,
      currency: currency,
      paidBy: SplitSpec.single(payer, total),
      owedBy: owedBy ?? SplitSpec.equal(split),
      category: 'food.dining',
      date: kNow.subtract(const Duration(hours: 2)),
    ),
  );

  Future<ExpenseId> pay(
    GroupId g, {
    required MemberId from,
    required MemberId to,
    required int amount,
    String currency = 'INR',
  }) => ledger.recordPayment(
    PaymentDraft(
      groupId: g,
      from: from,
      to: to,
      amount: amount,
      currency: currency,
      method: PaymentMethod.cash,
      date: kNow.subtract(const Duration(hours: 1)),
    ),
  );

  Future<void> dispose() => ledger.close();
}

/// A phone size, text scale and theme.
typedef Variant = ({Size size, double scale, Brightness brightness});

String variantName(Variant v) =>
    '${v.size.width.toInt()}x${v.size.height.toInt()} '
    '@${v.scale}x ${v.brightness == Brightness.dark ? 'dark' : 'light'}';

/// Charter matrix: 320x568 and 360x640, 1.0/1.3/2.0, light and dark.
final List<Variant> kVariants = [
  for (final size in const [Size(320, 568), Size(360, 640)])
    for (final scale in const [1.0, 1.3, 2.0])
      for (final b in Brightness.values)
        (size: size, scale: scale, brightness: b),
];

/// Disables network font fetching; widget tests render with the test font
/// (each glyph a 1 em square, wider than Familjen Grotesk) unless
/// [loadFonts] is awaited, so a fit here is a conservative result.
void configureVisualTests() {
  GoogleFonts.config.allowRuntimeFetching = false;
}

void setView(WidgetTester tester, Size size) {
  tester.view.physicalSize = size * 3;
  tester.view.devicePixelRatio = 3;
  tester.view.padding = const FakeViewPadding(top: 24 * 3, bottom: 16 * 3);
  addTearDown(tester.view.reset);
}

/// Pumps the app over [phone] and returns its container.
Future<ProviderContainer> pumpVisual(
  WidgetTester tester,
  VisualPhone phone, {
  required Variant v,
  String? location,
  bool disableAnimations = false,
}) async {
  setView(tester, v.size);
  await tester.runAsync(
    () => phone.settings.updateSettings(
      phone.settings.settings.copyWith(
        themeMode: v.brightness == Brightness.dark
            ? AppThemeMode.dark
            : AppThemeMode.light,
      ),
    ),
  );
  tester.platformDispatcher.textScaleFactorTestValue = v.scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  if (disableAnimations) {
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(tester.platformDispatcher.clearAccessibilityFeaturesTestValue);
  }
  final container = ProviderContainer(
    overrides: [
      settingsRepositoryProvider.overrideWithValue(phone.settings),
      ledgerRepositoryProvider.overrideWithValue(phone.ledger),
      syncEngineProvider.overrideWithValue(phone.engine),
      clockProvider.overrideWithValue(() => kNow),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(container: container, child: const SettleUpApp()),
  );
  await settleFrames(tester);
  if (location != null) {
    container.read(routerProvider).go(location);
    await settleFrames(tester);
  }
  return container;
}

/// Lets streams deliver and animations finish without waiting on spinners.
Future<void> settleFrames(WidgetTester tester) async {
  for (var i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  await tester.pump(const Duration(milliseconds: 600));
}

/// Runs [body] with FlutterError.onError captured; returns the overflow
/// and layout errors it reported (one line each).
Future<List<String>> collectLayoutErrors(Future<void> Function() body) async {
  final errors = <String>[];
  final old = FlutterError.onError;
  FlutterError.onError = (d) {
    final text = d.exceptionAsString().split('\n').first;
    errors.add(text);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = old;
  }
  return errors;
}

/// Characters that mark a string as an amount.
final RegExp _symbols = RegExp(r'[₹$€£¥]|KD|KWD|INR|USD|EUR|JPY');
final RegExp _digits = RegExp(r'\d');

/// "+₹1,20,000", "−KD 1.250", "₹4,250": a pure amount, nothing else.
final RegExp kPureAmount = RegExp(
  r'^[+−]?\s?(?:[₹$€£¥]|US\$|KD|[A-Z]{3})\s?[\d,.  ]+$',
);

/// One amount-bearing paragraph that did not fit.
final class CutText {
  CutText(this.text, this.reason, this.width, this.needed);
  final String text;
  final String reason;
  final double width;
  final double needed;
  @override
  String toString() =>
      '"$text" $reason (box ${width.toStringAsFixed(1)} < '
      'needed ${needed.toStringAsFixed(1)})';
}

/// Every visible paragraph that holds an amount and was cut: it exceeded
/// its line limit (ellipsis or clip), or a pure amount was narrower than
/// its own text.
List<CutText> findCutAmounts(WidgetTester tester) {
  final out = <CutText>[];
  for (final e in find.byType(RichText).evaluate()) {
    final ro = e.renderObject;
    if (ro is! RenderParagraph || !ro.hasSize) continue;
    final text = ro.text.toPlainText();
    if (!_digits.hasMatch(text) || !_symbols.hasMatch(text)) continue;
    final needed = ro.getMaxIntrinsicWidth(double.infinity);
    final pure = kPureAmount.hasMatch(text.trim());
    if (ro.didExceedMaxLines) {
      out.add(CutText(text, 'exceeded maxLines', ro.size.width, needed));
    } else if (pure && needed > ro.size.width + 0.5) {
      out.add(CutText(text, 'narrower than the amount', ro.size.width, needed));
    }
  }
  return out;
}

/// All visible text, for "is this on screen" checks.
List<String> visibleTexts(WidgetTester tester) => [
  for (final e in find.byType(RichText).evaluate())
    if (e.renderObject case final RenderParagraph p) p.text.toPlainText(),
];

/// Every semantics label on screen.
List<String> semanticsLabels(WidgetTester tester) {
  final out = <String>[];
  void visit(SemanticsNode n) {
    final d = n.getSemanticsData();
    if (d.label.isNotEmpty) out.add(d.label);
    n.visitChildren((c) {
      visit(c);
      return true;
    });
  }

  final root =
      tester.binding.renderViews.first.owner?.semanticsOwner?.rootSemanticsNode;
  if (root != null) visit(root);
  return out;
}

/// Prints only when [debugPrintQa] is on (kept off for CI noise).
bool debugPrintQa = false;
void qaLog(Object o) {
  if (debugPrintQa) debugPrint('$o');
}

/// A seeded phone and the ids the tests navigate to.
final class VisualWorld {
  VisualWorld(this.phone);
  final VisualPhone phone;

  /// INR group, its KWD sibling, an expense, a payment, a person.
  late String group, kwdGroup, expense, payment, person;

  Map<String, String> get screens => {
    'home': Routes.home,
    'group': Routes.group(group),
    'group KWD': Routes.group(kwdGroup),
    'activity': Routes.activity,
    'search': Routes.search,
    'sync': Routes.sync,
    'settle': Routes.settle(groupId: group),
    'settle KWD': Routes.settle(groupId: kwdGroup),
    'person': Routes.person(person),
    'expense': Routes.expense(expense),
    'payment': Routes.expense(payment),
    'edit expense': Routes.editExpense(expense),
    'new expense': Routes.newExpense(groupId: group),
    'members': Routes.members(group),
    'settings': Routes.settings,
    'edit group': Routes.editGroup(group),
    'invite': Routes.invite(group),
  };

  /// Builds a world: [friend] owes me [inr] in group [groupName], I owe
  /// "Sam" a JPY share, a payment between the two others, and a KWD group
  /// where I owe [kwd]. Call inside `tester.runAsync`.
  static Future<VisualWorld> build({
    String friend = 'Priya Sharma',
    String groupName = 'Goa trip',
    String description = 'Dinner at the shack',
    int inr = 12000050, // ₹1,20,000.50
    int kwd = 1250750, // KD1,250.750
  }) async {
    final p = await VisualPhone.create(name: 'Arjun Mehta');
    final w = VisualWorld(p);
    final a = await p.group(groupName, [friend, 'Sam']);
    w.group = a.g;
    final me = a.m['me']!, f = a.m[friend]!, sam = a.m['Sam']!;
    w.expense = await p.add(
      a.g,
      total: inr,
      payer: me,
      owedBy: SplitSpec.single(f, inr),
      description: description,
    );
    await p.add(
      a.g,
      total: 5000,
      currency: 'JPY',
      payer: sam,
      split: [me, sam],
      description: 'Taxi',
    );
    w.payment = await p.pay(a.g, from: sam, to: f, amount: 20000);
    // Group names are 1..60 characters (SPEC 5.16).
    final kwdName = 'Kuwait $groupName';
    final b = await p.group(
      kwdName.length > 60 ? kwdName.substring(0, 60) : kwdName,
      ['Sam K'],
      currency: 'KWD',
    );
    w.kwdGroup = b.g;
    await p.add(
      b.g,
      total: kwd,
      currency: 'KWD',
      payer: b.m['Sam K']!,
      owedBy: SplitSpec.single(b.m['me']!, kwd),
      description: description,
    );
    w.person = p.gs(a.g).members[f]!.personId;
    return w;
  }

  /// Realistic: short names, lakh-sized rupees, a four-digit KWD amount.
  static Future<VisualWorld> realistic() => build();

  /// Editor maximums: 40-char member, 60-char group, 120-char description,
  /// with everyday amounts (₹12,345.50, KD125.750).
  static Future<VisualWorld> longNames() => build(
    friend: kName40,
    groupName: kGroup60,
    description: kDesc120,
    inr: 1234550,
    kwd: 125750,
  );

  /// Money.maxMinor in INR (₹99,99,99,999.99) and KWD (KD99,999,999.999).
  static Future<VisualWorld> huge() =>
      build(inr: Money.maxMinor, kwd: Money.maxMinor);
}

/// Pumps [location] over [w] and returns the layout errors and cut amounts.
Future<({List<String> errors, List<CutText> cut})> inspect(
  WidgetTester tester,
  VisualWorld w,
  Variant v,
  String location,
) async {
  final errors = await collectLayoutErrors(
    () => pumpVisual(tester, w.phone, v: v, location: location),
  );
  final cut = findCutAmounts(tester);
  // Tear the tree down so the next container starts clean.
  await tester.pumpWidget(const SizedBox.shrink());
  return (errors: errors, cut: cut);
}

/// Only cut amounts that stand alone ("+₹4,250"), not sentences.
List<CutText> pureOnly(List<CutText> cut) =>
    cut.where((c) => kPureAmount.hasMatch(c.text.trim())).toList();
