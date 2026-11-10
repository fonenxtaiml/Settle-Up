// VISUAL-R9-01 class: a kit control that speaks one label over its own
// tree (excludeSemantics) and reports itself as a button must expose the
// semantic tap, and a semantic tap must run what a finger tap runs.
//
// Three layers: a source rule over lib/ (no Semantics that says "button"
// and hides its child may lack an onTap), the ButtonSemantics contract,
// and every tappable kit control at 1.0x and 2.0x in both themes.
import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'kit_harness.dart';

/// The argument list of every `Semantics(` call in [src].
Iterable<String> _semanticsCalls(String src) sync* {
  final call = RegExp(r'(?<![A-Za-z_])Semantics\(');
  for (final m in call.allMatches(src)) {
    var depth = 0;
    for (var i = m.end - 1; i < src.length; i++) {
      final c = src[i];
      if (c == '(') depth++;
      if (c == ')' && --depth == 0) {
        yield src.substring(m.start, i + 1);
        break;
      }
    }
  }
}

/// The named arguments at the top level of a `Semantics(...)` call.
Set<String> _topLevelArgs(String call) {
  final out = <String>{};
  var depth = 0;
  final arg = RegExp(r'^\s*([a-zA-Z]+)\s*:');
  var start = call.indexOf('(') + 1;
  for (var i = start; i < call.length; i++) {
    final c = call[i];
    if ('([{'.contains(c)) depth++;
    if (')]}'.contains(c)) depth--;
    if ((c == ',' && depth == 0) || depth < 0) {
      final m = arg.firstMatch(call.substring(start, i));
      if (m != null) out.add(m.group(1)!);
      start = i + 1;
    }
  }
  return out;
}

/// Enabled nodes that say "button" and have no tap action.
List<String> _deadButtons(WidgetTester tester) {
  final out = <String>[];
  void visit(SemanticsNode n) {
    final d = n.getSemanticsData();
    final f = d.flagsCollection;
    if (f.isButton &&
        f.isEnabled != Tristate.isFalse &&
        !n.isInvisible &&
        !d.hasAction(SemanticsAction.tap)) {
      out.add('"${d.label.replaceAll('\n', ' ')}"');
    }
    n.visitChildren((c) {
      visit(c);
      return true;
    });
  }

  visit(
    tester.binding.renderViews.first.owner!.semanticsOwner!.rootSemanticsNode!,
  );
  return out;
}

void main() {
  configureKitTests();

  test('no Semantics in lib/ says "button" and hides its child without an '
      'onTap (use ButtonSemantics)', () {
    final problems = <String>[];
    for (final f in Directory('lib').listSync(recursive: true)) {
      if (f is! File || !f.path.endsWith('.dart')) continue;
      // Comments may quote the pattern; only code counts.
      final src = f.readAsStringSync().replaceAll(RegExp(r'//[^\n]*'), '');
      for (final call in _semanticsCalls(src)) {
        final args = _topLevelArgs(call);
        if (args.contains('button') &&
            args.contains('excludeSemantics') &&
            !args.contains('onTap')) {
          final line = '\n'.allMatches(src.substring(0, src.indexOf(call)));
          problems.add('${f.path}:${line.length + 1}');
        }
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  test('the source rule sees a dead button and passes a live one', () {
    const dead =
        'Semantics(button: true, label: x, excludeSemantics: true, '
        'child: InkWell(onTap: f, child: Text(y)))';
    const live =
        'Semantics(button: true, onTap: f, excludeSemantics: true, '
        'child: InkWell(onTap: f))';
    expect(_topLevelArgs(_semanticsCalls(dead).single), {
      'button',
      'label',
      'excludeSemantics',
      'child',
    });
    expect(_topLevelArgs(_semanticsCalls(live).single), contains('onTap'));
  });

  group('ButtonSemantics', () {
    Future<SemanticsData> data(WidgetTester tester, Widget w) async {
      await tester.pumpWidget(kitApp(w));
      return tester
          .getSemantics(find.byType(ButtonSemantics).first)
          .getSemanticsData();
    }

    testWidgets('an enabled button exposes tap, and a semantic tap runs '
        'the callback', (tester) async {
      final h = tester.ensureSemantics();
      var taps = 0;
      final d = await data(
        tester,
        ButtonSemantics(
          label: 'Go',
          onTap: () => taps++,
          child: const SizedBox(width: 48, height: 48),
        ),
      );
      expect(d.flagsCollection.isButton, isTrue);
      expect(d.flagsCollection.isEnabled, Tristate.isTrue);
      expect(d.hasAction(SemanticsAction.tap), isTrue);
      tester.semantics.tap(find.semantics.byLabel('Go'));
      expect(taps, 1);
      h.dispose();
    });

    testWidgets('without onTap: a disabled button, or plain text when it '
        'is not always a button; never a dead button', (tester) async {
      final h = tester.ensureSemantics();
      final disabled = await data(
        tester,
        const ButtonSemantics(
          label: 'Go',
          onTap: null,
          child: SizedBox(width: 48, height: 48),
        ),
      );
      expect(disabled.flagsCollection.isButton, isTrue);
      expect(disabled.flagsCollection.isEnabled, Tristate.isFalse);
      expect(disabled.hasAction(SemanticsAction.tap), isFalse);
      expect(_deadButtons(tester), isEmpty);

      final text = await data(
        tester,
        const ButtonSemantics(
          label: 'Note, Optional',
          alwaysButton: false,
          onTap: null,
          child: SizedBox(width: 48, height: 48),
        ),
      );
      expect(text.flagsCollection.isButton, isFalse);
      expect(text.hasAction(SemanticsAction.tap), isFalse);
      expect(_deadButtons(tester), isEmpty);
      h.dispose();
    });
  });

  testWidgets('TapTargetPadding takes a finger tap in its padding, and the '
      'chip itself still gets its own tap', (tester) async {
    var outer = 0, inner = 0;
    await tester.pumpWidget(
      kitApp(
        Center(
          child: TapTargetPadding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            onTap: () => outer++,
            child: InkWell(
              onTap: () => inner++,
              child: const SizedBox(width: 80, height: 32),
            ),
          ),
        ),
      ),
    );
    final r = tester.getRect(find.byType(TapTargetPadding));
    expect(r.height, 48);
    await tester.tapAt(Offset(r.center.dx, r.top + 2));
    await tester.tapAt(Offset(r.center.dx, r.bottom - 2));
    expect((outer, inner), (2, 0));
    await tester.tapAt(r.center);
    expect((outer, inner), (2, 1));
  });

  // Every tappable kit control that speaks one label over its own tree.
  // [label] finds its node; a semantic tap and a finger tap must each run
  // the callback once.
  final tapped = <String>[];
  final kit = <(String, Pattern, Widget Function())>[
    for (final m in SplitMethod.values)
      (
        'SplitMethodSelector ${m.name}',
        SplitMethodSelector.labelFor(m),
        () => SplitMethodSelector(
          // Another method is selected: tapping the selected one is a
          // no-op by design.
          value: m == SplitMethod.equal ? SplitMethod.exact : SplitMethod.equal,
          onChanged: (v) => tapped.add('split ${v.name}'),
        ),
      ),
    (
      'DropdownChip',
      'Group: Goa trip. Change group',
      () => DropdownChip(
        label: 'Goa trip',
        semanticLabel: 'Group: Goa trip. Change group',
        onTap: () => tapped.add('DropdownChip'),
      ),
    ),
    (
      'CategoryChip',
      KitStrings.changeCategory('Transport'),
      () => LabeledTextField(
        label: 'Description',
        trailing: CategoryChip(
          categoryId: 'transport',
          label: 'Transport',
          onTap: () => tapped.add('CategoryChip'),
        ),
      ),
    ),
    (
      'PickerTile',
      'Paid by, You',
      () => PickerTile(
        label: 'Paid by',
        value: 'You',
        onTap: () => tapped.add('PickerTile'),
      ),
    ),
    (
      'KeyValueRow',
      'Note, Optional',
      () => KeyValueRow(
        label: 'Note',
        value: null,
        placeholder: 'Optional',
        onTap: () => tapped.add('KeyValueRow'),
      ),
    ),
    (
      'NearbyPhoneRow sync',
      RegExp(KitStrings.syncWith("Priya's Pixel 8")),
      () => NearbyPhoneRow(
        name: "Priya's Pixel 8",
        subtitle: 'Wi-Fi, shares Goa trip',
        onAction: () => tapped.add('NearbyPhoneRow sync'),
      ),
    ),
    (
      'NearbyPhoneRow pair',
      RegExp(KitStrings.pairWith("Sam's phone")),
      () => NearbyPhoneRow(
        name: "Sam's phone",
        subtitle: 'Bluetooth',
        action: NearbyPhoneAction.pair,
        onAction: () => tapped.add('NearbyPhoneRow pair'),
      ),
    ),
    (
      'SyncStatusChip',
      KitStrings.changesToShare(2),
      () => SyncStatusChip(
        state: SyncChipState.changesWaiting,
        pendingCount: 2,
        onTap: () => tapped.add('SyncStatusChip'),
      ),
    ),
    (
      'BalanceHero',
      RegExp('owed overall'),
      () => BalanceHero(
        net: const {'INR': 12000050},
        owedToMe: const {'INR': 12000050},
        iOwe: const {},
        mainCurrency: 'INR',
        onTap: () => tapped.add('BalanceHero'),
      ),
    ),
    (
      'AmountField currency',
      'Indian rupee',
      () => AmountField(
        currency: 'INR',
        currencyName: 'Indian rupee',
        onChanged: (_) {},
        onCurrencyTap: () => tapped.add('AmountField currency'),
      ),
    ),
  ];

  for (final v in kitVariants) {
    for (final (name, label, build) in kit) {
      testWidgets('$name (${variantName(v)}): a semantic tap and a finger '
          'tap run the same callback, and the target meets the Android '
          'tap target guideline', (tester) async {
        final h = tester.ensureSemantics();
        // Wide enough that no chip of the split selector is scrolled
        // partly out of view (a clipped node is no full target).
        tester.view.physicalSize = const Size(600, 800) * 3;
        tester.view.devicePixelRatio = 3;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          kitApp(
            Padding(padding: const EdgeInsets.all(16), child: build()),
            brightness: v.$1,
            textScale: v.$2,
          ),
        );
        await tester.pump(const Duration(milliseconds: 300));
        expect(_deadButtons(tester), isEmpty);

        tapped.clear();
        final node = find.semantics.byLabel(label);
        tester.semantics.tap(node);
        await tester.pump();
        expect(tapped, hasLength(1), reason: 'semantic tap on $name');
        final viaSemantics = tapped.single;

        tapped.clear();
        final widget = find.byWidgetPredicate(
          (w) =>
              w is ButtonSemantics &&
              (label is String
                  ? w.label == label
                  : label.allMatches(w.label).isNotEmpty),
        );
        await tester.tap(widget);
        await tester.pump();
        expect(tapped, [viaSemantics], reason: 'finger tap on $name');

        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        h.dispose();
      });
    }
  }
}
