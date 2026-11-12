// QA VISUAL round 31: reverification of VISUAL-R29-01 (confirmation
// dialogs did not scroll) as a class. Every dialog the app opens is walked
// in the app itself with the longest inputs it can carry (40-character
// member, 60-character group, 120-character description, a long note) at
// 320x568 and 360x640, 2.0x, light and dark, and the text prompts again
// with the keyboard up. For each one:
//
// - no overflow or other layout error;
// - every button lies whole on the screen (above the keyboard when it is
//   up), so the task can be finished at that text size;
// - the title and the body can be scrolled into view in full (top of the
//   title, bottom of the body) and no paragraph is cut;
// - androidTapTargetGuideline, labeledTapTargetGuideline and
//   textContrastGuideline hold.
//
// Tests named "QA VISUAL-R31-NN" with `skip:` are failing repros for open
// findings (docs/qa/QA-REPORT.md); remove the skip once fixed.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/strings.dart';

import 'visual_harness.dart';

/// A second 40-character member, with no balance, so Remove asks to
/// confirm instead of refusing.
const _free40 = 'Maximiliana Konstantinopoulou-Rasmussenx';

/// A 1000-character note (kNotesMax), in sentences.
final String _note1000 = () {
  final s = StringBuffer();
  while (s.length < kNotesMax) {
    s.write('Paid back in cash at the station before the train left. ');
  }
  return s.toString().substring(0, kNotesMax);
}();

typedef _Opener = ({
  String location,
  Future<void> Function(WidgetTester t) open,
  bool keyboard,
});

Future<void> _tapIn(WidgetTester t, Finder f) async {
  await t.scrollUntilVisible(f, 100, scrollable: find.byType(Scrollable).first);
  await settleFrames(t);
  await t.tap(f.first);
  await settleFrames(t);
}

/// Checks the open AlertDialog; returns one line per problem.
Future<List<String>> _checkDialog(
  WidgetTester t,
  Size screen, {
  required double keyboard,
  bool fieldText = true,
}) async {
  final out = <String>[];
  final dialog = find.byType(AlertDialog);
  if (dialog.evaluate().isEmpty) return ['dialog did not open'];
  final bottom = screen.height - keyboard;
  final buttons = find.descendant(
    of: dialog,
    matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
  );
  if (buttons.evaluate().isEmpty) out.add('no buttons');
  for (final b in buttons.evaluate()) {
    final r = t.getRect(find.byWidget(b.widget));
    if (r.top < 0 || r.bottom > bottom + 0.5 || r.left < 0) {
      out.add(
        'button "${(b.widget as ButtonStyleButton).child}" at '
        '${r.top.round()}-${r.bottom.round()}, visible area ends at '
        '${bottom.round()}',
      );
    }
    if (r.right > screen.width + 0.5) {
      out.add('button past the right edge (${r.right.round()})');
    }
  }
  // The outer scroll view: the title and body scroll above the buttons.
  final scroll = find.descendant(of: dialog, matching: find.byType(Scrollable));
  if (scroll.evaluate().isEmpty) {
    out.add('title and body do not scroll');
    return out;
  }
  final state = t.state<ScrollableState>(scroll.first);
  final viewport = t.getRect(scroll.first);
  final content = find.descendant(
    of: scroll.first,
    matching: find.byType(RichText),
  );
  if (content.evaluate().isEmpty) {
    out.add('empty dialog body');
    return out;
  }
  state.position.jumpTo(0);
  await t.pump();
  final firstTop = t.getRect(content.first).top;
  if (firstTop < viewport.top - 0.5) {
    out.add('title top hidden above the scroll view');
  }
  state.position.jumpTo(state.position.maxScrollExtent);
  await t.pump();
  // Every paragraph of the title and body reaches the viewport at some
  // scroll position; the last one ends inside it at the end.
  final last = t.getRect(content.last);
  if (last.bottom > viewport.bottom + 0.5) {
    out.add(
      'body end at ${last.bottom.round()} below the scroll view end '
      '${viewport.bottom.round()} at its furthest scroll',
    );
  }
  if (viewport.bottom > bottom + 0.5) {
    out.add(
      'scroll view ends at ${viewport.bottom.round()} under the '
      'visible area (${bottom.round()})',
    );
  }
  // [fieldText] false leaves out a text field's helper, error and counter
  // (VISUAL-R31-01, fixed: every sweep now checks them too).
  final inField = find
      .descendant(of: dialog, matching: find.byType(InputDecorator))
      .evaluate()
      .expand(
        (d) => find
            .descendant(
              of: find.byWidget(d.widget),
              matching: find.byType(RichText),
            )
            .evaluate(),
      )
      .toSet();
  for (final e
      in find
          .descendant(of: dialog, matching: find.byType(RichText))
          .evaluate()) {
    if (!fieldText && inField.contains(e)) continue;
    final p = e.renderObject;
    if (p is RenderParagraph && p.didExceedMaxLines) {
      out.add('cut paragraph "${p.text.toPlainText()}"');
    }
  }
  state.position.jumpTo(0);
  await t.pump();
  for (final (name, g) in [
    ('androidTapTargetGuideline', androidTapTargetGuideline),
    ('labeledTapTargetGuideline', labeledTapTargetGuideline),
    ('textContrastGuideline', textContrastGuideline),
  ]) {
    final res = await g.evaluate(t);
    if (!res.passed) out.add('$name: ${res.reason}');
  }
  return out;
}

void main() {
  configureVisualTests();

  testWidgets('R31 sweep: every dialog the app opens fits or scrolls with '
      'the longest inputs at 320x568 and 360x640 @2.0x in both themes, '
      'keyboard up for the text prompts: buttons on screen, title and body '
      'readable in full, tap targets, labels and contrast', (t) async {
    final handle = t.ensureSemantics();
    late VisualWorld w;
    late String freeGroup;
    await t.runAsync(() async {
      w = await VisualWorld.longNames();
      freeGroup = (await w.phone.group(kGroup60, [_free40])).g;
    });
    expect(_free40.length, 40);
    String idOf(String name) => w.phone
        .gs(w.group)
        .members
        .values
        .firstWhere((m) => m.displayName == name)
        .id;

    final openers = <String, _Opener>{
      'Delete expense': (
        location: Routes.expense(w.expense),
        keyboard: false,
        open: (t) async {
          await t.tap(find.byTooltip('More options'));
          await settleFrames(t);
          await t.tap(find.text('Delete expense'));
          await settleFrames(t);
        },
      ),
      'Delete payment': (
        location: Routes.expense(w.payment),
        keyboard: false,
        open: (t) async {
          await t.tap(find.byTooltip('More options'));
          await settleFrames(t);
          await t.tap(find.text('Delete payment'));
          await settleFrames(t);
        },
      ),
      'Delete group': (
        location: Routes.editGroup(w.group),
        keyboard: false,
        open: (t) => _tapIn(t, find.text('Delete group')),
      ),
      "Can't remove": (
        location: Routes.members(w.group),
        keyboard: false,
        open: (t) async {
          await _tapIn(t, find.text(kName40));
          await t.tap(find.text('Remove').last);
          await settleFrames(t);
        },
      ),
      'Remove member': (
        location: Routes.members(freeGroup),
        keyboard: false,
        open: (t) async {
          await _tapIn(t, find.text(_free40));
          await t.tap(find.text('Remove').last);
          await settleFrames(t);
        },
      ),
      'Rename member': (
        location: Routes.members(w.group),
        keyboard: true,
        open: (t) async {
          await _tapIn(t, find.text(kName40));
          await t.tap(find.text('Rename').last);
          await settleFrames(t);
        },
      ),
      'Share link': (
        location: Routes.invite(w.group),
        keyboard: false,
        open: (t) => _tapIn(t, find.text('Share link')),
      ),
      'Discard expense': (
        location: Routes.group(w.group),
        keyboard: false,
        open: (t) async {
          // Pushed over the group, as Add expense opens it.
          unawaited(
            GoRouter.of(t.element(find.byType(Scaffold).first))
                .push(Routes.newExpense(groupId: w.group)),
          );
          await settleFrames(t);
          // The amount field is the first.
          await t.enterText(find.byType(TextField).first, '12');
          await settleFrames(t);
          await t.tap(find.byTooltip(S.close).last);
          await settleFrames(t);
        },
      ),
      'Your name': (
        location: Routes.settings,
        keyboard: true,
        open: (t) async {
          await _tapIn(t, find.text('Arjun Mehta'));
          await t.enterText(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            ),
            kName40,
          );
          await settleFrames(t);
        },
      ),
      'Settle up note (1000 characters)': (
        location: Routes.settle(
          groupId: w.group,
          from: idOf(kName40),
          to: w.phone
              .gs(w.group)
              .members
              .values
              .firstWhere((m) => m.personId == w.phone.me)
              .id,
          currency: 'INR',
        ),
        keyboard: true,
        open: (t) async {
          await _tapIn(t, find.text('Note'));
          await t.enterText(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            ),
            _note1000,
          );
          await settleFrames(t);
        },
      ),
      'Phone name': (
        location: Routes.settings,
        keyboard: true,
        open: (t) async {
          await _tapIn(t, find.text('Phone name'));
          await t.enterText(
            find.descendant(
              of: find.byType(AlertDialog),
              matching: find.byType(TextField),
            ),
            _free40,
          );
          await settleFrames(t);
        },
      ),
      'How sync works': (
        location: Routes.sync,
        keyboard: false,
        open: (t) async {
          await t.tap(find.byTooltip('How sync works'));
          await settleFrames(t);
        },
      ),
    };

    final problems = <String>[];
    var checked = 0;
    for (final size in const [Size(320, 568), Size(360, 640)]) {
      for (final b in Brightness.values) {
        final v = (size: size, scale: 2.0, brightness: b);
        for (final e in openers.entries) {
          for (final kb in [false, if (e.value.keyboard) true]) {
            final at = '${variantName(v)} ${e.key}${kb ? ' (keyboard)' : ''}';
            final keyboard = kb ? 280.0 : 0.0;
            final errors = await collectLayoutErrors(() async {
              await pumpVisual(t, w.phone, v: v, location: e.value.location);
              await e.value.open(t);
              if (kb) {
                t.view.viewInsets = FakeViewPadding(bottom: keyboard * 3);
                await settleFrames(t);
              }
            });
            for (final x in errors) {
              problems.add('$at: $x');
            }
            final found = await collectLayoutErrors(() async {
              for (final p in await _checkDialog(
                t,
                size,
                keyboard: keyboard,
                fieldText: true,
              )) {
                problems.add('$at: $p');
              }
            });
            for (final x in found) {
              problems.add('$at: $x');
            }
            checked++;
            t.view.resetViewInsets();
            await t.pumpWidget(const SizedBox.shrink());
          }
        }
      }
    }
    handle.dispose();
    await t.runAsync(w.phone.dispose);
    qaLog('checked $checked dialogs');
    expect(checked, greaterThan(40));
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // The claim screen's "Your name in <group>" prompt, opened when the name
  // typed is taken, carries the 60-character group in its title and the
  // 40-character name in its helper. Opened here directly with the strings
  // the claim screen passes, over the charter matrix, keyboard down and up:
  // buttons on screen, title and body scroll, no field text cut
  // (VISUAL-R31-01).
  testWidgets('R31 sweep: the name-taken prompt of the claim screen, with a '
      '60-character group and a 40-character name, fits or scrolls over the '
      'charter matrix with the keyboard down and up', (t) async {
    final problems = <String>[];
    for (final v in kVariants) {
      for (final kb in [false, true]) {
        problems.addAll(
          await _prompt(
            t,
            v,
            keyboard: kb,
            title: S.yourNameIn(kGroup60),
            initial: kName40,
            helper: S.nameTakenHelper(kName40),
            fieldText: true,
          ),
        );
      }
    }
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  // The Settings clock notice (new with DATA-R29-02): shown in About once
  // a peer's stamp was more than an hour ahead. Walked over the whole
  // charter matrix: no overflow and its contrast in both themes (its cut
  // text is open as VISUAL-R31-02).
  testWidgets(
    'R31 sweep: the Settings clock notice holds its layout and '
    'its contrast over the charter matrix',
    (t) => _clockNotice(t, cut: false),
  );

  // ------------------------------------------------------------------
  // VISUAL-R31-02: the Settings clock notice cuts its own text. Its help
  // line is held to 3 lines and its title to 1 below 2.0x, so with the
  // bundled font the title ends "looks wr..." at 1.3x on 320 and 360 dp
  // phones and the help loses "Check this phone's date and time." at
  // 1.3x (320) and 2.0x (320 and 360).
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R31-02: the Settings clock notice cuts its title at 1.3x and '
    'its help text at 1.3x and 2.0x with an ellipsis',
    (t) => _clockNotice(t, cut: true),
    skip: true, // QA VISUAL-R31-02: Settings clock notice text cut
  );

  // ------------------------------------------------------------------
  // VISUAL-R31-01: a text prompt's helper or error line is cut with an
  // ellipsis after 3 lines. The prompt dialog takes the width of its
  // content (about 280 dp) and the field's counter takes part of the row,
  // so the helper has 100 to 140 dp: the claim screen's name-taken helper
  // loses its end at 1.3x with a 12-character name on every phone size
  // (and at 1.0x with a 40-character name), the Your name and Phone name
  // helpers and the "Use at least one letter or number" error at 2.0x.
  // ------------------------------------------------------------------

  testWidgets(
    'QA VISUAL-R31-01: a text prompt cuts its helper or error text with an '
    'ellipsis (claim name-taken helper at 1.3x, Your name, Phone name and '
    'the name error at 2.0x)',
    (t) async {
      final cases = <(String, Variant, String, String, String)>[
        for (final v in kVariants)
          if (v.scale >= 1.3) ...[
            (
              'name taken, 12-character name',
              v,
              S.yourNameIn('Goa trip'),
              'Priya Sharma',
              S.nameTakenHelper('Priya Sharma'),
            ),
          ],
        for (final v in kVariants) ...[
          (
            'name taken, 40-character name',
            v,
            S.yourNameIn(kGroup60),
            kName40,
            S.nameTakenHelper(kName40),
          ),
        ],
        for (final v in kVariants)
          if (v.scale == 2.0) ...[
            ('Your name', v, S.editName, kName40, S.yourNameHelper),
            ('Phone name', v, S.phoneName, 'Pixel 7', S.phoneNameHelp),
            // No letter or number: the error line replaces the helper.
            ('name error', v, S.editName, '!!!', S.yourNameHelper),
          ],
      ];
      final problems = <String>[];
      for (final (name, v, title, initial, helper) in cases) {
        for (final p in await _prompt(
          t,
          v,
          keyboard: false,
          title: title,
          initial: initial,
          helper: helper,
          fieldText: true,
        )) {
          problems.add('$name $p');
        }
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    },
  );
}

/// Opens [promptText] as the name prompts do, at [v], and checks it.
Future<List<String>> _prompt(
  WidgetTester t,
  Variant v, {
  required bool keyboard,
  required String title,
  required String initial,
  required String helper,
  required bool fieldText,
}) async {
  setView(t, v.size);
  t.platformDispatcher.textScaleFactorTestValue = v.scale;
  addTearDown(t.platformDispatcher.clearTextScaleFactorTestValue);
  final out = <String>[];
  final at = '${variantName(v)}${keyboard ? ' (keyboard)' : ''}';
  final errors = await collectLayoutErrors(() async {
    await t.pumpWidget(
      MaterialApp(
        theme: v.brightness == Brightness.dark
            ? AppTheme.dark()
            : AppTheme.light(),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => promptText(
                  context,
                  title: title,
                  initial: initial,
                  helper: helper,
                  maxLength: kMemberNameMax,
                  isName: true,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await t.tap(find.text('open'));
    await t.pumpAndSettle();
    if (keyboard) {
      t.view.viewInsets = const FakeViewPadding(bottom: 280 * 3);
      await t.pumpAndSettle();
    }
  });
  for (final x in errors) {
    out.add('$at: $x');
  }
  for (final p in await _checkDialog(
    t,
    v.size,
    keyboard: keyboard ? 280 : 0,
    fieldText: fieldText,
  )) {
    out.add('$at: $p');
  }
  t.view.resetViewInsets();
  await t.pumpWidget(const SizedBox.shrink());
  return out;
}

/// Shows the Settings clock notice over the charter matrix and returns the
/// problems: layout errors and contrast, and with [cut] a cut title or help.
Future<void> _clockNotice(WidgetTester t, {required bool cut}) async {
  final handle = t.ensureSemantics();
  late VisualPhone phone;
  await t.runAsync(() async {
    phone = await VisualPhone.create(name: 'Arjun Mehta');
    final store = MemoryOpStore();
    await store.open();
    final settings = await KvSettingsRepository.open(
      store,
      defaultDeviceName: 'Far',
      ids: QaIds('eeee0000'),
      localeName: 'en_IN',
    );
    await settings.completeOnboarding(displayName: 'Far', homeCurrency: 'INR');
    var clock = kNow.millisecondsSinceEpoch + 3 * 3600 * 1000;
    final far = await Ledger.open(
      store: store,
      keys: MemoryGroupKeyStore(),
      settings: settings,
      ids: QaIds('ffff0000'),
      nowMillis: () => clock += 1000,
    );
    final g = await far.createGroup(
      const NewGroup(
        name: 'Far trip',
        type: GroupType.trip,
        currency: 'INR',
        newMemberNames: ['Sam'],
      ),
    );
    await phone.ledger.registerJoinedGroup(
      g,
      (await far.groupKeys())[g]!,
      'Far trip',
    );
    await phone.ledger.applyRemote(g, far.current.ops.toList());
    await far.close();
  });
  expect(phone.ledger.clockSkewDetected, isTrue);
  final problems = <String>[];
  for (final v in kVariants) {
    final at = variantName(v);
    final errors = await collectLayoutErrors(() async {
      await pumpVisual(t, phone, v: v, location: Routes.settings);
      await t.scrollUntilVisible(
        find.text(S.clockLooksWrongHelp),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await settleFrames(t);
    });
    for (final x in errors) {
      problems.add('$at: $x');
    }
    for (final text in [S.clockLooksWrong, S.clockLooksWrongHelp]) {
      final f = find.text(text);
      if (f.evaluate().isEmpty) {
        problems.add('$at: "$text" not shown');
        continue;
      }
      final p = t.renderObject<RenderParagraph>(
        find.descendant(of: f, matching: find.byType(RichText)),
      );
      if (cut && p.didExceedMaxLines) problems.add('$at: cut "$text"');
    }
    final res = await textContrastGuideline.evaluate(t);
    if (!res.passed) problems.add('$at: ${res.reason}');
    await t.pumpWidget(const SizedBox.shrink());
  }
  handle.dispose();
  await t.runAsync(phone.dispose);
  expect(problems, isEmpty, reason: problems.join('\n'));
}
