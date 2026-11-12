// QA VISUAL round 24, final regression sweep. Product code changed since
// round 21 in the places text is shown: the reducer and the edit history
// drop lone UTF-16 surrogates an op stored earlier may hold
// (SECURITY-R21-01, lib/core/reducer/materialize.dart, lib/core/
// activity.dart), and the name prompts skip a name saved as it opened
// (UIFLOW-R21-01). These probes load ops written straight to the store
// (as a phone stored them before the fix) and check every screen that
// shows the text: the words are shown without the halves, every painted
// string is well formed, nothing reads U+FFFD, and the layout holds at
// every charter size, scale and theme.
//
// Tests named "QA VISUAL-R24-NN" with `skip: true` are failing repros for
// open findings (docs/qa/QA-REPORT.md); remove the skip once fixed.
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/text_clean.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/widgets/expense_row.dart';

import 'visual_harness.dart';

const String _lone = '\uD800';
const String _loneLow = '\uDC00';

/// Every painted string and semantics label that is not well formed or
/// holds U+FFFD.
List<String> _badText(WidgetTester t) => [
  for (final s in [...visibleTexts(t), ...semanticsLabels(t)])
    if (!TextClean.isWellFormed(s) || s.contains('�')) s.codeUnits.join(','),
];

/// A copy of the world on the same phone after [ops] were written to its
/// store directly and the ledger reopened.
Future<VisualWorld> _withStored(VisualWorld w, List<Operation> ops) async {
  await w.phone.store.insertAll(ops);
  final p = await w.phone.reopen();
  return VisualWorld(p)
    ..group = w.group
    ..kwdGroup = w.kwdGroup
    ..expense = w.expense
    ..payment = w.payment
    ..person = w.person;
}

/// Update ops by this phone's own device, stamped after everything it has.
Future<List<Operation>> _ownUpdates(
  VisualWorld w,
  List<(EntityType, String, Map<String, Object?>)> edits,
) async {
  final me = w.phone.settings.device.deviceId;
  var counter = await w.phone.store.maxCounter(w.group, me);
  final all = await w.phone.store.loadAll();
  var ms = all.map((o) => o.hlc.millis).reduce((a, b) => a > b ? a : b);
  return [
    for (final (type, entity, payload) in edits)
      Operation(
        id: 'cccc0000-0000-7000-8000-${(++counter).toString().padLeft(12, '0')}',
        groupId: w.group,
        deviceId: me,
        counter: counter,
        hlc: Hlc(ms += 1000, 0, me),
        entityType: type,
        entityId: entity,
        kind: OpKind.update,
        payload: payload,
      ),
  ];
}

void main() {
  configureVisualTests();

  testWidgets('names, a description and notes stored with lone surrogates '
      'show without them on every screen, at every size, scale and theme', (
    t,
  ) async {
    final handle = t.ensureSemantics();
    late VisualWorld w;
    await t.runAsync(() async {
      final base = await VisualWorld.longNames();
      final friend = base.phone
          .gs(base.group)
          .members
          .values
          .firstWhere((m) => m.personId == base.person);
      final ops = await _ownUpdates(base, [
        (EntityType.group, base.group, {GroupFields.name: 'Goa$_lone trip'}),
        (
          EntityType.member,
          friend.id,
          {MemberFields.displayName: 'Pri${_loneLow}ya'},
        ),
        (
          EntityType.expense,
          base.expense,
          {
            ExpenseFields.description: 'Din${_lone}ner at the shack',
            ExpenseFields.notes: 'tip$_lone included',
          },
        ),
      ]);
      w = await _withStored(base, ops);
    });
    final g = w.phone.gs(w.group);
    expect(g.group!.name, 'Goa trip');
    expect(g.expenses[w.expense]!.description, 'Dinner at the shack');
    final screens = {
      'home': Routes.home,
      'group': Routes.group(w.group),
      'activity': Routes.activity,
      'group activity': Routes.groupActivity(w.group),
      'expense': Routes.expense(w.expense),
      'person': Routes.person(w.person),
      'settle': Routes.settle(groupId: w.group),
      'members': Routes.members(w.group),
      'edit expense': Routes.editExpense(w.expense),
      'edit group': Routes.editGroup(w.group),
    };
    final problems = <String>[];
    for (final MapEntry(key: name, value: loc) in screens.entries) {
      for (final v in kVariants) {
        final errors = await collectLayoutErrors(
          () => pumpVisual(t, w.phone, v: v, location: loc),
        );
        final bad = _badText(t);
        final cut = pureOnly(findCutAmounts(t));
        if (errors.isNotEmpty || bad.isNotEmpty || cut.isNotEmpty) {
          problems.add('$name ${variantName(v)}: ${errors.toSet()} $bad $cut');
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    // The cleaned words are what is shown.
    await pumpVisual(
      t,
      w.phone,
      v: kVariants.first,
      location: screens['expense'],
    );
    expect(
      visibleTexts(t).any((s) => s.contains('Dinner at the shack')),
      isTrue,
    );
    expect(visibleTexts(t).any((s) => s.contains('tip included')), isTrue);
    await t.pumpWidget(const SizedBox.shrink());
    await t.runAsync(w.phone.dispose);
    handle.dispose();
    expect(problems, isEmpty);
  });

  testWidgets('search finds a description stored with a lone surrogate by '
      'its cleaned words and shows it whole', (t) async {
    final handle = t.ensureSemantics();
    late VisualWorld w;
    await t.runAsync(() async {
      final base = await VisualWorld.realistic();
      final ops = await _ownUpdates(base, [
        (
          EntityType.expense,
          base.expense,
          {ExpenseFields.description: 'Kayak$_lone hire'},
        ),
      ]);
      w = await _withStored(base, ops);
    });
    final problems = <String>[];
    for (final v in kVariants) {
      final errors = await collectLayoutErrors(() async {
        await pumpVisual(t, w.phone, v: v, location: Routes.search);
        await t.enterText(find.byType(EditableText).first, 'kayak hire');
        await settleFrames(t);
      });
      final bad = _badText(t);
      final shown = visibleTexts(t).any((s) => s.contains('Kayak hire'));
      if (errors.isNotEmpty || bad.isNotEmpty || !shown) {
        problems.add('${variantName(v)}: ${errors.toSet()} $bad shown=$shown');
      }
      await t.pumpWidget(const SizedBox.shrink());
    }
    await t.runAsync(w.phone.dispose);
    handle.dispose();
    expect(problems, isEmpty);
  });

  testWidgets('an edit history line of a description edit stored with a '
      'lone surrogate reads the cleaned words', (t) async {
    late VisualWorld w;
    await t.runAsync(() async {
      final base = await VisualWorld.realistic();
      final ops = await _ownUpdates(base, [
        (
          EntityType.expense,
          base.expense,
          {ExpenseFields.description: 'Lunch$_loneLow by the sea'},
        ),
      ]);
      w = await _withStored(base, ops);
    });
    await pumpVisual(
      t,
      w.phone,
      v: kVariants.first,
      location: Routes.expense(w.expense),
    );
    for (var i = 0; i < 10; i++) {
      final s = find.byType(Scrollable);
      if (s.evaluate().isEmpty) break;
      final pos = t.state<ScrollableState>(s.first).position;
      pos.jumpTo(pos.maxScrollExtent);
      await t.pump(const Duration(milliseconds: 100));
    }
    final texts = visibleTexts(t);
    expect(
      texts.where((s) => s.contains('Lunch by the sea')),
      isNotEmpty,
      reason: '$texts',
    );
    expect(_badText(t), isEmpty);
    await t.pumpWidget(const SizedBox.shrink());
    await t.runAsync(w.phone.dispose);
  });

  // VISUAL-R24-01. An expense (not a payment) whose description shows
  // nothing reaches the screen two ways: a peer's op with an empty or
  // blank description (the remote check lets an empty description through,
  // as payments carry one, and does not check expenses for blank text),
  // or a description stored with only a lone surrogate before
  // SECURITY-R21-01, which the reducer now cleans to ''. ExpenseRow then
  // titles the expense "Payment" (lib/ui/widgets/expense_row.dart:133),
  // or shows a blank title, next to the expense's category glyph and
  // "you lent".
  testWidgets(
    'QA VISUAL-R24-01: An expense whose description shows nothing is '
    'titled "Payment" or left untitled in the expense list',
    skip: true, // QA VISUAL-R24-01: open, failing repro
    (t) async {
      late VisualWorld w;
      late String fromPeer, blankFromPeer;
      await t.runAsync(() async {
        final base = await VisualWorld.realistic();
        final ops = await _ownUpdates(base, [
          (
            EntityType.expense,
            base.expense,
            {ExpenseFields.description: _lone},
          ),
        ]);
        w = await _withStored(base, ops);
        // A peer's two expenses, as its op carries them: one with an empty
        // description, one with a Hangul filler (blank on screen).
        final create = (await w.phone.store.loadAll()).firstWhere(
          (o) => o.entityId == w.expense && o.kind == OpKind.create,
        );
        const peer = 'eeee0000-0000-7000-8000-000000000001';
        fromPeer = 'eeee0000-0000-7000-8000-0000000000e1';
        blankFromPeer = 'eeee0000-0000-7000-8000-0000000000e2';
        final ms = create.hlc.millis + 60000;
        final added = await w.phone.ledger.applyRemote(w.group, [
          for (final (n, id, d) in [(1, fromPeer, ''), (2, blankFromPeer, 'ㅤ')])
            Operation(
              id: 'eeee0000-0000-7000-8000-00000000010$n',
              groupId: w.group,
              deviceId: peer,
              counter: n,
              hlc: Hlc(ms + n, 0, peer),
              entityType: EntityType.expense,
              entityId: id,
              kind: OpKind.create,
              payload: {...create.payload, ExpenseFields.description: d},
            ),
        ]);
        expect(added, hasLength(2));
      });
      final expenses = w.phone.gs(w.group).expenses;
      for (final id in [w.expense, fromPeer, blankFromPeer]) {
        expect(expenses[id]!.isPayment, isFalse, reason: id);
      }
      await pumpVisual(
        t,
        w.phone,
        v: kVariants.first,
        location: Routes.group(w.group),
      );
      final titles = <String, String>{};
      for (final id in [w.expense, fromPeer, blankFromPeer]) {
        final row = find.byWidgetPredicate(
          (x) => x is ExpenseRow && x.expense.id == id,
        );
        await t.scrollUntilVisible(row, 120);
        // The row's first paragraph that is not its category glyph.
        final texts = [
          for (final e
              in find
                  .descendant(of: row, matching: find.byType(RichText))
                  .evaluate())
            if (e.renderObject case final RenderParagraph p)
              p.text.toPlainText(),
        ];
        titles[id] = texts.firstWhere(
          (s) =>
              s.runes.every((r) => r < 0xE000 || r > 0xF8FF) &&
              !s.runes.any((r) => r >= 0xF0000),
          orElse: () => '',
        );
      }
      qaLog(titles);
      final problems = [
        for (final MapEntry(:key, :value) in titles.entries)
          if (value == 'Payment' || TextRules.isBlank(value)) '$key: "$value"',
      ];
      await t.pumpWidget(const SizedBox.shrink());
      await t.runAsync(w.phone.dispose);
      expect(problems, isEmpty);
    },
  );
}
