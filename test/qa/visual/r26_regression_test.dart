// QA VISUAL round 26, reverification of VISUAL-R24-01 (an expense whose
// description shows nothing). The fix routes every place that shows an
// expense description through KitStrings.expenseTitle. These probes walk
// the rest of the defect class: a peer edit that blanks a named expense
// (the edited sentence and the edit history line), a peer delete of a
// blank expense (the deleted sentence and the deleted row), the row's
// semantics label, and the layout of the group and detail screens over
// the whole charter matrix with such an expense on them.
//
// Tests named "QA VISUAL-R26-NN" with `skip: true` are failing repros for
// open findings (docs/qa/QA-REPORT.md); remove the skip once fixed.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/widgets/expense_row.dart';

import 'visual_harness.dart';

const _peer = 'eeee0000-0000-7000-8000-000000000026';
const _blank = 'eeee0000-0000-7000-8000-0000000026e1';

/// The realistic world after a peer created a second expense with a
/// description that shows nothing, then blanked the world's own expense
/// with an update, then deleted its blank expense.
Future<VisualWorld> _world() async {
  final w = await VisualWorld.realistic();
  final create = (await w.phone.store.loadAll()).firstWhere(
    (o) => o.entityId == w.expense && o.kind == OpKind.create,
  );
  final ms = create.hlc.millis + 60000;
  Operation op(int n, String entity, OpKind kind, Map<String, Object?> p) =>
      Operation(
        id: 'eeee0000-0000-7000-8000-00000000260$n',
        groupId: w.group,
        deviceId: _peer,
        counter: n,
        hlc: Hlc(ms + n * 1000, 0, _peer),
        entityType: EntityType.expense,
        entityId: entity,
        kind: kind,
        payload: p,
      );
  final added = await w.phone.ledger.applyRemote(w.group, [
    op(1, _blank, OpKind.create, {
      ...create.payload,
      ExpenseFields.description: '​',
    }),
    op(2, w.expense, OpKind.update, {ExpenseFields.description: 'ㅤ '}),
    op(3, _blank, OpKind.delete, const {}),
  ]);
  expect(added, hasLength(3));
  return w;
}

void main() {
  configureVisualTests();

  testWidgets('VISUAL-R24-01 class: a peer edit or delete of an expense '
      'whose description shows nothing names it "Untitled expense" in '
      'activity, history and the row label', (t) async {
    late VisualWorld w;
    await t.runAsync(() async => w = await _world());
    final gs = w.phone.gs(w.group);
    expect(gs.expenses[w.expense]!.isPayment, isFalse);
    final problems = <String>[];

    await pumpVisual(
      t,
      w.phone,
      v: kVariants.first,
      location: Routes.groupActivity(w.group),
    );
    final activity = visibleTexts(t);
    qaLog(activity);
    for (final verb in ['edited', 'deleted']) {
      if (!activity.any((s) => s.contains('$verb Untitled expense'))) {
        problems.add('activity: no "$verb Untitled expense" in $activity');
      }
    }
    for (final s in activity) {
      if (RegExp(r'(added|edited|deleted|restored)\s*$').hasMatch(s)) {
        problems.add('activity: sentence ends without a title: "$s"');
      }
    }
    await t.pumpWidget(const SizedBox.shrink());

    await pumpVisual(
      t,
      w.phone,
      v: kVariants.first,
      location: Routes.expense(w.expense),
    );
    final detail = [...visibleTexts(t), ...semanticsLabels(t)];
    if (!detail.contains('Untitled expense')) {
      problems.add('detail: no title in $detail');
    }
    if (!detail.any((s) => s.contains('Description: Untitled expense'))) {
      problems.add('history: no "Description: Untitled expense" in $detail');
    }
    await t.pumpWidget(const SizedBox.shrink());

    await pumpVisual(
      t,
      w.phone,
      v: kVariants.first,
      location: Routes.group(w.group),
    );
    final row = find.byWidgetPredicate(
      (x) => x is ExpenseRow && x.expense.id == w.expense,
    );
    await t.scrollUntilVisible(row, 120);
    final labels = semanticsLabels(t);
    if (!labels.any((s) => s.startsWith('Untitled expense'))) {
      problems.add('row label: none starts with the title in $labels');
    }
    for (final s in labels) {
      if (s.startsWith('Payment') || TextRules.isBlank(s)) {
        problems.add('row label: "$s"');
      }
    }
    await t.pumpWidget(const SizedBox.shrink());
    await t.runAsync(w.phone.dispose);
    expect(problems, isEmpty);
  });

  testWidgets('VISUAL-R24-01 class: the group and detail screens of an '
      'untitled expense hold their layout over the charter matrix', (t) async {
    late VisualWorld w;
    await t.runAsync(() async => w = await _world());
    final problems = <String>[];
    for (final v in kVariants) {
      for (final loc in [Routes.group(w.group), Routes.expense(w.expense)]) {
        final errors = await collectLayoutErrors(() async {
          await pumpVisual(t, w.phone, v: v, location: loc);
        });
        for (final e in errors) {
          problems.add('${variantName(v)} $loc: $e');
        }
        for (final c in findCutAmounts(t)) {
          problems.add('${variantName(v)} $loc: $c');
        }
        await t.pumpWidget(const SizedBox.shrink());
      }
    }
    await t.runAsync(w.phone.dispose);
    expect(problems, isEmpty);
  });
}
