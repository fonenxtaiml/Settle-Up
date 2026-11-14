// VISUAL-R38-01 regressions: your own name and this phone's name read in
// full on Settings (the profile row and the Phone name value wrap, never
// cut) and in full in their editor (a one-line prompt wraps on screen
// instead of scrolling sideways), at every charter size, scale and theme.
// The editor stays one line: the action key saves and a pasted line break
// is left out, as before.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import '../../qa/visual/visual_harness.dart';

bool _shownInFull(String text) => find.byType(RichText).evaluate().any((e) {
  final p = e.renderObject;
  return p is RenderParagraph &&
      p.hasSize &&
      p.text.toPlainText().contains(text) &&
      !p.didExceedMaxLines;
});

Variant _tall(Variant v) =>
    (size: Size(v.size.width, 3200), scale: v.scale, brightness: v.brightness);

const _phone40 = 'Bartholomew Fitzgerald-Johnston Pixel 8a';
const _phone40b = 'Bartholomew Fitzgerald-Johnston Pixel 9';

Rect _rectOf(WidgetTester t, Finder f) {
  final b = t.renderObject<RenderBox>(f);
  return b.localToGlobal(Offset.zero) & b.size;
}

void main() {
  configureVisualTests();

  for (final (name, phone) in [
    (kName40, _phone40),
    (kName40, _phone40b),
    ('W' * 40, 'W' * 40),
    ('Ana', 'Pixel 8'),
  ]) {
    testWidgets('Settings shows "$name" and "$phone" in full at every '
        'variant, the row inside the screen', (t) async {
      late VisualPhone p;
      await t.runAsync(() async {
        p = await VisualPhone.create(name: name);
        await p.settings.setDeviceName(phone);
      });
      final problems = <String>[];
      for (final v in kVariants) {
        final at = variantName(v);
        final errors = await collectLayoutErrors(
          () => pumpVisual(t, p, v: _tall(v), location: Routes.settings),
        );
        problems.addAll(errors.map((e) => '$at: $e'));
        if (!_shownInFull(name)) problems.add('$at: "$name" is cut');
        if (!_shownInFull(S.thisPhoneLine(phone))) {
          problems.add('$at: "This phone: $phone" is cut');
        }
        // The Phone name row's value, on its own, in full and on screen.
        // (The last one: your name may be the same text, above it.)
        final value = find.text(phone);
        if (value.evaluate().length != (name == phone ? 2 : 1)) {
          problems.add('$at: ${value.evaluate().length} "$phone" values');
        } else {
          final r = _rectOf(t, value.last);
          if (r.left < -0.5 || r.right > v.size.width + 0.5) {
            problems.add('$at: "$phone" at $r is off screen');
          }
        }
        // The app's own values are still shown in full too.
        for (final s in [S.phoneName, S.theme, S.homeCurrency]) {
          if (!_shownInFull(s)) problems.add('$at: "$s" is cut');
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
      await t.runAsync(() => p.dispose());
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }

  testWidgets('a short value still sits beside its title on a 360 dp phone '
      'at 1.0x', (t) async {
    late VisualPhone p;
    await t.runAsync(() async => p = await VisualPhone.create());
    const v = (size: Size(360, 640), scale: 1.0, brightness: Brightness.light);
    await pumpVisual(t, p, v: v, location: Routes.settings);
    for (final (title, value) in [(S.phoneName, 'Pixel 8')]) {
      final tr = _rectOf(t, find.text(title));
      final vr = _rectOf(t, find.text(value));
      expect(vr.left, greaterThan(tr.right), reason: '$value beside $title');
      expect((vr.center.dy - tr.center.dy).abs(), lessThan(4));
    }
    await t.pumpWidget(const SizedBox.shrink());
    await t.runAsync(() => p.dispose());
  });

  testWidgets('the Phone name and Edit name prompts show a 40-character '
      'name in full: wrapped, never scrolled sideways', (t) async {
    late VisualPhone p;
    await t.runAsync(() async {
      p = await VisualPhone.create(name: kName40);
      await p.settings.setDeviceName(_phone40);
    });
    final problems = <String>[];
    for (final v in kVariants) {
      final at = variantName(v);
      for (final (row, text) in [(S.phoneName, _phone40), (kName40, kName40)]) {
        final errors = await collectLayoutErrors(() async {
          await pumpVisual(t, p, v: v, location: Routes.settings);
          await t.scrollUntilVisible(
            find.text(row),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await t.pump();
          await t.tap(find.text(row).first);
          await settleFrames(t);
        });
        problems.addAll(errors.map((e) => '$at $row: $e'));
        final field = find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byType(EditableText),
        );
        if (field.evaluate().length != 1) {
          problems.add('$at $row: no editor');
        } else {
          final editable = t.widget<EditableText>(field);
          if (editable.controller.text != text) {
            problems.add(
              '$at $row: editor holds "${editable.controller.text}"',
            );
          }
          final scroll = find.descendant(
            of: field,
            matching: find.byType(Scrollable),
          );
          final pos = t.state<ScrollableState>(scroll).position;
          if (pos.axis != Axis.vertical || pos.maxScrollExtent > 0.5) {
            problems.add(
              '$at $row: the name scrolls ${pos.axis.name} '
              '(${pos.maxScrollExtent} dp out of view)',
            );
          }
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    await t.runAsync(() => p.dispose());
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('the wrapped prompt stays one line: a pasted line break is '
      'left out and the action key saves', (t) async {
    late VisualPhone p;
    await t.runAsync(() async {
      p = await VisualPhone.create(name: kName40);
      await p.settings.setDeviceName(_phone40);
    });
    const v = (size: Size(320, 568), scale: 1.0, brightness: Brightness.light);
    await pumpVisual(t, p, v: v, location: Routes.settings);
    await t.scrollUntilVisible(
      find.text(S.phoneName),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await t.pump();
    await t.tap(find.text(S.phoneName).first);
    await settleFrames(t);
    final field = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    final tf = t.widget<TextField>(field);
    expect(tf.keyboardType, TextInputType.text);
    expect(tf.textInputAction, TextInputAction.done);
    // As a one-line field has it (its single-line formatter): 'AnaPixel 9'.
    await t.enterText(field, 'Ana\nPixel 9');
    await t.pump();
    expect(t.widget<TextField>(field).controller!.text, 'AnaPixel 9');
    await t.enterText(field, 'Ana Pixel 9');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await settleFrames(t);
    expect(find.byType(AlertDialog), findsNothing);
    await t.runAsync(() async {});
    expect(p.settings.device.deviceName, 'Ana Pixel 9');
    await t.pumpWidget(const SizedBox.shrink());
    await t.runAsync(() => p.dispose());
  });
}
