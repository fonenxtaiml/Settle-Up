// VISUAL-R31-01 and VISUAL-R31-02 as a class: text that says why a value
// was refused or what the user should do is never cut with an ellipsis.
//
// - Every field's helper and error text wraps in full (the app theme sets
//   no practical line cap; Flutter's own default keeps them to one line).
// - The text prompt gives its field the dialog's full width.
// - A notice row (any KitListRow without a line cap: the Settings clock
//   notice, the sync radio issues) wraps its title and its help in full;
//   list entries that set a cap keep it.
// - The sync banner's "stopped" line wraps in full.
//
// The property tests draw seeded random texts, widths and text scales.
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/theme/app_theme.dart';
import 'package:settle_up/ui/screens/common.dart';
import 'package:settle_up/ui/screens/sync/radios.dart';
import 'package:settle_up/ui/widgets/list_row.dart';
import 'package:settle_up/ui/widgets/sync_status.dart';

import 'kit_harness.dart';

const _words = [
  'a',
  'is',
  'the',
  'phone',
  'name',
  'already',
  'taken',
  'here',
  'Use',
  'people',
  'can',
  'tell',
  'apart',
  'Check',
  'date',
  'and',
  'time',
  'synced',
  'Konstantinopoulou-Rasmussen',
  'Maximiliana',
  'hotspot',
  'permission',
  'Bluetooth',
  'settings',
  'हिन्दी',
  'नाम',
  'தமிழ்',
  '名前',
  'ஆ',
  '!!',
  '…',
]; // dart format off

String _text(Random r, {int maxWords = 40}) => [
  for (var i = 0, n = 1 + r.nextInt(maxWords); i < n; i++)
    _words[r.nextInt(_words.length)],
].join(' ');

const _scales = [1.0, 1.15, 1.3, 1.5, 1.75, 2.0];

/// The paragraphs under [of] cut with an ellipsis.
List<String> _cut(WidgetTester t, Finder of) => [
  for (final e in find
      .descendant(of: of, matching: find.byType(RichText))
      .evaluate())
    if (e.renderObject case final RenderParagraph p when p.didExceedMaxLines)
      p.text.toPlainText(),
];

void main() {
  configureKitTests();
  setUpAll(loadRealFonts);

  test('both themes let a field helper and error wrap in full', () {
    for (final theme in [AppTheme.light(), AppTheme.dark()]) {
      final d = theme.inputDecorationTheme;
      expect(d.helperMaxLines, AppTheme.fieldNoteMaxLines);
      expect(d.errorMaxLines, AppTheme.fieldNoteMaxLines);
      // In practice no cap: far more lines than any phone shows.
      expect(AppTheme.fieldNoteMaxLines, greaterThan(10000));
    }
  });

  testWidgets('property: a field never cuts its helper or error, whatever '
      'the text, width, text scale or counter', (t) async {
    final r = Random(3101);
    final problems = <String>[];
    for (var i = 0; i < 120; i++) {
      final width = 240.0 + r.nextInt(173);
      final scale = _scales[r.nextInt(_scales.length)];
      final note = _text(r);
      final error = r.nextBool();
      final counter = r.nextBool();
      t.view.physicalSize = Size(width, 900) * 3;
      t.view.devicePixelRatio = 3;
      await t.pumpWidget(
        kitApp(
          TextField(
            decoration: InputDecoration(
              helperText: error ? null : note,
              errorText: error ? note : null,
              counterText: counter ? '40/40' : null,
            ),
          ),
          textScale: scale,
          brightness: r.nextBool() ? Brightness.dark : Brightness.light,
        ),
      );
      final cut = _cut(t, find.byType(TextField));
      if (cut.isNotEmpty) {
        problems.add('${width.round()} dp @${scale}x: cut "${cut.first}"');
      }
      expect(find.text(note), findsOneWidget);
      expect(t.takeException(), isNull);
    }
    t.view.reset();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('property: a text prompt never cuts its helper or its error, '
      'and its field takes the dialog width', (t) async {
    final r = Random(3102);
    final problems = <String>[];
    for (var i = 0; i < 40; i++) {
      final width = 320.0 + r.nextInt(93);
      final scale = _scales[r.nextInt(_scales.length)];
      final helper = _text(r, maxWords: 24);
      // '!!!' has no letter or number: the error line shows.
      final initial = r.nextBool() ? '!!!' : 'Priya Sharma';
      t.view.physicalSize = Size(width, 900) * 3;
      t.view.devicePixelRatio = 3;
      await t.pumpWidget(
        kitApp(
          Builder(
            builder: (context) => TextButton(
              onPressed: () => promptText(
                context,
                title: 'Your name',
                initial: initial,
                helper: helper,
                maxLength: 40,
                isName: true,
              ),
              child: const Text('open'),
            ),
          ),
          textScale: scale,
        ),
      );
      await t.tap(find.text('open'));
      await t.pumpAndSettle();
      final dialog = find.byType(AlertDialog);
      final cut = _cut(t, dialog);
      if (cut.isNotEmpty) {
        problems.add('${width.round()} dp @${scale}x: cut "${cut.first}"');
      }
      // The field spans the dialog's content width (less its padding),
      // not the 280 dp a dialog takes from a bare field.
      final field = t.getRect(find.byType(TextField));
      final box = t.getRect(
        find.descendant(of: dialog, matching: find.byType(Material)).first,
      );
      if (box.width - field.width > 49) {
        problems.add(
          '${width.round()} dp: field ${field.width.round()} dp in a '
          '${box.width.round()} dp dialog',
        );
      }
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
    }
    t.view.reset();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  testWidgets('property: a notice row wraps its title and help in full; a '
      'list entry keeps its one-line cap', (t) async {
    final r = Random(3103);
    final problems = <String>[];
    for (var i = 0; i < 120; i++) {
      final width = 280.0 + r.nextInt(133);
      final scale = _scales[r.nextInt(_scales.length)];
      final title = _text(r, maxWords: 12);
      final help = _text(r);
      final button = r.nextBool();
      t.view.physicalSize = Size(width, 1600) * 3;
      t.view.devicePixelRatio = 3;
      await t.pumpWidget(
        kitApp(
          Column(
            children: [
              KitListRow(
                key: const Key('notice'),
                title: title,
                subtitle: help,
                leading: r.nextBool() ? const Icon(Icons.schedule) : null,
                keepTrailingBeside: button,
                trailing: button
                    ? FilledButton.tonal(
                        onPressed: () {},
                        child: const Text('Settings'),
                      )
                    : const Icon(Icons.schedule),
              ),
              KitListRow(
                key: const Key('entry'),
                title: 'Maximiliana Konstantinopoulou-Rasmussen ' * 4,
                titleLines: 1,
                subtitle: 'Paid back in cash at the station ' * 6,
                subtitleLines: 1,
              ),
            ],
          ),
          textScale: scale,
        ),
      );
      final cut = _cut(t, find.byKey(const Key('notice')));
      if (cut.isNotEmpty) {
        problems.add('${width.round()} dp @${scale}x: cut "${cut.first}"');
      }
      // A list entry is still capped, as before.
      expect(_cut(t, find.byKey(const Key('entry'))), isNotEmpty);
      expect(t.takeException(), isNull);
    }
    t.view.reset();
    expect(problems, isEmpty, reason: problems.join('\n'));
  });

  for (final size in const [Size(320, 568), Size(360, 640), Size(412, 915)]) {
    for (final scale in const [1.0, 1.3, 2.0]) {
      final at = '${size.width.round()} dp @${scale}x';
      testWidgets('the sync radio issues show their help in full at $at', (
        t,
      ) async {
        t.view.physicalSize = size * 3;
        t.view.devicePixelRatio = 3;
        addTearDown(t.view.reset);
        await t.pumpWidget(
          kitApp(
            // In the sync screen's 16 dp gutter.
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: RadioIssuesCard(
                issues: RadioIssue.values,
                onAllow: () {},
              ),
            ),
            textScale: scale,
          ),
        );
        expect(_cut(t, find.byType(RadioIssuesCard)), isEmpty);
        expect(t.takeException(), isNull);
      });

      testWidgets('a stopped sync says what to do in full at $at', (t) async {
        t.view.physicalSize = size * 3;
        t.view.devicePixelRatio = 3;
        addTearDown(t.view.reset);
        await t.pumpWidget(
          kitApp(
            SyncBanner(
              state: SyncChipState.failed,
              peerName: 'Maximiliana Konstantinopoulou-Rasmussen',
              onSync: () {},
            ),
            textScale: scale,
          ),
        );
        expect(_cut(t, find.byType(SyncBanner)), isEmpty);
        expect(t.takeException(), isNull);
      });
    }
  }
}
