// QA UIFLOW round 39: final regression sweep on the real Ledger around the
// code changed since dev (VISUAL-R34-01/02, R36-01, R38-01): the add
// expense group chip that now leaves the app bar for a line of its own
// when the group name does not fit, the TitleCutScope / CutTitleHeading on
// Settle up, Members, Group (pending) and the other app bar screens, and
// the Settings profile and value rows that now wrap. Each probe walks the
// functional flow through the changed widget (tap, pick, save) and checks
// the Ledger, not only the layout, on a small phone and at a large text
// scale, where the new code paths are taken.
// Tests named "QA UIFLOW-R39-NN" with `skip: true` are failing repros of an
// open finding.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/app_chrome.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

import 'real_harness.dart';

/// A 60-character group name (the limit) and a 40-character person name.
const String _long60 =
    'Annual offsite in the Western Ghats with family and friends!';
const String _name40 = 'Bartholomew Fitzgerald-Johnston Junior';

void _smallPhone(WidgetTester tester, {double scale = 1.3}) {
  qaPhone(tester, size: const Size(320, 640));
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
}

Finder _chip() => find.byType(DropdownChip);

bool _chipInAppBar() => find
    .descendant(of: find.byType(AppBar), matching: _chip())
    .evaluate()
    .isNotEmpty;

Future<void> _pickGroupNamed(WidgetTester tester, String name) async {
  await qaTap(tester, _chip());
  expect(find.text(S.pickGroup), findsOneWidget);
  final option = find.text(name).last;
  await qaTap(tester, option);
}

void main() {
  setUpAll(() {
    expect(_long60.characters.length, 60);
    expect(_name40.characters.length, lessThanOrEqualTo(40));
  });

  testWidgets('R39 sweep: Add expense: the group chip moves out of the app '
      'bar for a 60-character group and back, opens the picker from either '
      'place, and keeps what was typed', (tester) async {
    // 412 dp: "Goa" fits beside the title, 60 characters do not.
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final short = await w.seedGroup(name: 'Goa');
    await w.seedGroup(name: _long60, people: const ['Priya', 'Meera']);
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.newExpense(groupId: short));
    await qaSettle(tester);
    expect(find.text(S.addExpenseTitle), findsOneWidget);
    expect(_chip(), findsOneWidget);
    expect(_chipInAppBar(), isTrue, reason: '"Goa" fits in the bar');

    await tester.enterText(find.byType(TextField).at(0), '300');
    await tester.pump();
    await tester.enterText(fieldLabeled(S.description), 'Houseboat');
    await tester.pump();
    await tester.enterText(fieldLabeled(S.notes), 'Paid in cash');
    await tester.pump();

    await _pickGroupNamed(tester, _long60);
    expect(_chip(), findsOneWidget);
    expect(
      _chipInAppBar(),
      isFalse,
      reason: 'a 60-character name does not fit the bar',
    );
    expect(find.text(_long60), findsOneWidget);
    expect(
      tester.widget<TextField>(fieldLabeled(S.description)).controller!.text,
      'Houseboat',
    );
    await qaReveal(tester, fieldLabeled(S.notes));
    expect(
      tester.widget<TextField>(fieldLabeled(S.notes)).controller!.text,
      'Paid in cash',
    );
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 2000));
    await qaSettle(tester);

    // Back to the short group via the chip in the body (tapping it there
    // still opens the picker), then to the long one again: the chip
    // follows each time.
    await _pickGroupNamed(tester, 'Goa');
    expect(_chipInAppBar(), isTrue);
    await _pickGroupNamed(tester, _long60);
    expect(_chipInAppBar(), isFalse);
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });

  testWidgets('R39 sweep: Add expense opened in a 60-character group: the '
      'chip has a line of its own, and the expense saves there split '
      'equally', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await w.seedGroup(name: 'Goa');
    final long = await w.seedGroup(
      name: _long60,
      people: const ['Priya', 'Meera'],
    );
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(long));
    await qaSettle(tester);
    await qaTap(tester, find.byType(FloatingActionButton));
    expect(find.text(S.addExpenseTitle), findsOneWidget);
    expect(_chipInAppBar(), isFalse);
    // The picker opens from the chip in the body; keeping the same group
    // changes nothing.
    await _pickGroupNamed(tester, _long60);
    await tester.enterText(find.byType(TextField).at(0), '300');
    await tester.pump();
    await tester.enterText(fieldLabeled(S.description), 'Houseboat');
    await tester.pump();
    expect(find.text(S.eachSummary('₹100', 3)), findsOneWidget);
    await qaTap(tester, find.text(S.saveExpense));
    final e = w.group(long).liveExpenses.single;
    expect(e.description, 'Houseboat');
    expect(e.money.total, 30000);
    expect(e.money.owed.values.toSet(), {10000});
    expect(w.location, Routes.group(long));
    expect(snackText(tester), S.expenseAdded);
    await w.shutdown(tester);
  });

  testWidgets(
    'QA UIFLOW-R39-01: Add expense, change the group with the chip: the '
    'split lists only the new group\'s people and Save adds the expense',
    // QA UIFLOW-R39-01: Changing the group on Add expense keeps the old
    // group's people in the split, so Save is refused
    skip: true,
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final goa = await w.seedGroup(
        name: 'Goa',
        people: const ['Priya', 'Rahul'],
      );
      final flat = await w.seedGroup(name: 'Flat', people: const ['Meera']);
      await pumpReal(tester, w, location: Routes.home);
      // Home's + opens Add expense in the first group; the user picks the
      // group the bill belongs to (Goa, then the Flat).
      await qaTap(tester, find.byType(FloatingActionButton));
      expect(find.text(S.addExpenseTitle), findsOneWidget);
      await _pickGroupNamed(tester, 'Goa');
      await tester.enterText(find.byType(TextField).at(0), '300');
      await tester.pump();
      await tester.enterText(fieldLabeled(S.description), 'Rent');
      await tester.pump();
      await _pickGroupNamed(tester, 'Flat');

      // Expected: the split is the Flat's two people, ₹150 each. Actual:
      // 5 of 5, Goa's three people listed as "Someone", ₹60 each.
      expect(find.text(S.someone), findsNothing);
      expect(find.text(S.eachSummary('₹150', 2)), findsOneWidget);

      // Expected: Save adds the expense to the Flat. Actual: the snack bar
      // says "That person is no longer in this group." and nothing saves.
      await qaTap(tester, find.text(S.saveExpense));
      expect(snackText(tester), S.expenseAdded);
      expect(w.group(goa).liveExpenses, isEmpty);
      final e = w.group(flat).liveExpenses.single;
      expect(e.money.owed.keys.toSet(), {
        for (final m in w.group(flat).activeMembers) m.id,
      });
      expect(e.money.owed.values.toSet(), {15000});
      await w.shutdown(tester);
    },
  );

  testWidgets('R39 sweep: Edit an expense in a 60-character group at 1.3x '
      'keeps untouched fields and saves', (tester) async {
    _smallPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(name: _long60);
    final me = w.member(gid, 'Arjun');
    final eid = await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Fuel',
        notes: 'Two tanks',
        total: 30000,
        currency: 'INR',
        paidBy: SplitSpec(SplitMethod.exact, {me: 30000}),
        owedBy: SplitSpec(SplitMethod.equal, {
          for (final m in w.group(gid).activeMembers) m.id: 1,
        }),
        date: qaNow.toUtc(),
        category: 'transport',
      ),
    );
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.editExpense(eid, groupId: gid));
    await qaSettle(tester);
    // Editing shows the group as text, not a chip.
    expect(_chip(), findsNothing);
    expect(find.text(_long60), findsOneWidget);
    await tester.enterText(find.byType(TextField).at(0), '360');
    await tester.pump();
    final save = find.text(S.saveExpense).evaluate().isNotEmpty
        ? find.text(S.saveExpense)
        : find.text(S.save);
    await qaTap(tester, save.first);
    final e = w.group(gid).liveExpenses.single;
    expect(e.money.total, 36000);
    expect(e.description, 'Fuel');
    expect(e.notes, 'Two tanks');
    expect(e.category, 'transport');
    await w.shutdown(tester);
  });

  testWidgets('R39 sweep: Settle up in a 60-character group at 320 dp, '
      '1.3x: the group reads in full, Record payment saves, the group and '
      'the Home hero follow', (tester) async {
    _smallPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(name: _long60);
    final me = w.member(gid, 'Arjun');
    final priya = w.member(gid, 'Priya');
    await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Villa',
        total: 30000,
        currency: 'INR',
        paidBy: SplitSpec(SplitMethod.exact, {me: 30000}),
        owedBy: SplitSpec(SplitMethod.equal, {
          for (final m in w.group(gid).activeMembers) m.id: 1,
        }),
        category: 'transport',
        date: qaNow.toUtc(),
      ),
    );
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    // The picker of who pays first, then the payment.
    w.push(Routes.settle(groupId: gid));
    await qaSettle(tester);
    expect(find.text(S.whoIsPaying), findsOneWidget);
    expect(find.text(_long60), findsWidgets);
    w.router.pop();
    await qaSettle(tester);
    w.push(Routes.settle(groupId: gid, from: priya, to: me));
    await qaSettle(tester);
    // The cut subline is read in full at the top of the body.
    expect(find.byType(CutTitleHeading), findsOneWidget);
    expect(find.text(_long60), findsWidgets);
    await qaTap(tester, find.text(S.recordPayment('₹100')));
    await tester.pump(const Duration(seconds: 2));
    await qaSettle(tester);
    expect(w.location, Routes.group(gid));
    expect(snackText(tester), S.paymentRecorded);
    expect(
      w.group(gid).liveExpenses.where((e) => e.isPayment).single.money.total,
      10000,
    );
    w.go(Routes.home);
    await qaSettle(tester);
    // Rahul still owes 100: the hero says you are owed.
    expect(find.text(KitStrings.heroOwed), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('R39 sweep: Members of a 60-character group at 320 dp, 1.3x: '
      'Add person works under the cut-title heading', (tester) async {
    _smallPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(name: _long60);
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.members(gid));
    await qaSettle(tester);
    expect(find.text(S.membersTitle), findsWidgets);
    expect(find.text(_long60), findsWidgets);
    final field = find.byType(TextField);
    await qaReveal(tester, field);
    await tester.enterText(field.first, _name40);
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson).last);
    expect(
      w.group(gid).activeMembers.map((m) => m.displayName),
      contains(_name40),
    );
    await w.shutdown(tester);
  });

  testWidgets('R39 sweep: Settings at 320 dp, 1.3x with a 40-character name: '
      'tapping the wrapped profile row renames you everywhere', (tester) async {
    _smallPhone(tester);
    final w = await RealWorld.create(name: _name40);
    final gid = await w.seedGroup();
    await w.settings.setDeviceName('Bartholomew Fitzgerald-Johnston Pixel 8a');
    await pumpReal(tester, w, location: Routes.settings);
    expect(find.text(_name40), findsWidgets);
    await qaTap(tester, find.text(_name40).first);
    final dialogField = find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    );
    expect(dialogField, findsOneWidget);
    await tester.enterText(dialogField, 'Arjun Mehta');
    await tester.pump();
    await qaTap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(S.save),
      ),
    );
    final profile = w.settings.profile;
    expect(profile?.displayName, 'Arjun Mehta');
    final mine = w
        .group(gid)
        .activeMembers
        .where((m) => m.personId == profile!.personId);
    expect(mine.single.displayName, 'Arjun Mehta');
    // The phone name row still opens its editor.
    await qaReveal(tester, find.text(S.phoneName));
    await qaTap(tester, find.text(S.phoneName));
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      findsOneWidget,
    );
    await w.shutdown(tester);
  });

  testWidgets('R39 sweep: an invite to a 60-character group opened before '
      'onboarding survives onboarding, joins, and the pending group screen '
      'reads its name in full', (tester) async {
    _smallPhone(tester);
    final friend = await RealWorld.create(name: 'Priya', idSeed: 5000);
    final fgid = await friend.seedGroup(name: _long60, people: const ['Arjun']);
    final link = await friend.engine.inviteLinkFor(fgid, includeHost: false);
    await friend.engine.dispose();
    final w = await RealWorld.create();
    await pumpReal(tester, w);
    await tester.binding.handlePushRoute(link);
    await qaSettle(tester);
    expect(find.text(S.onboardingTitle), findsOneWidget);
    await qaReveal(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField).first, 'Arjun');
    await tester.pump();
    await qaTap(tester, find.text(S.getStarted));
    expect(find.text(S.joinTitle), findsOneWidget);
    await qaTap(tester, find.text(S.joinAction));
    // Pending (no sync yet): the group screen names it in full.
    if (find.text(S.claimLater).evaluate().isNotEmpty) {
      await qaTap(tester, find.text(S.claimLater));
    }
    w.go(Routes.group(fgid));
    await qaSettle(tester);
    expect(find.text(S.pendingGroupTitle), findsOneWidget);
    expect(find.text(_long60), findsWidgets);
    await w.shutdown(tester);
  });

  // Every app bar screen with a 60-character group and a 40-character
  // member at 320 dp and 1.3x and 2.0x: nothing throws (the debug check
  // that an app bar line is cut with nowhere to read it, layout overflow).
  for (final scale in [1.3, 2.0]) {
    testWidgets('R39 sweep: every deep screen with the longest names at '
        '${scale}x builds without an error', (tester) async {
      _smallPhone(tester, scale: scale);
      final w = await RealWorld.create(name: _name40);
      final gid = await w.seedGroup(
        name: _long60,
        people: const ['Bartholomew Fitzgerald-Johnston Senior'],
      );
      final me = w.state.groups[gid]!.activeMembers
          .firstWhere((m) => m.personId == w.settings.profile!.personId)
          .id;
      final other = w.state.groups[gid]!.activeMembers
          .firstWhere((m) => m.id != me)
          .id;
      final eid = await w.ledger.addExpense(
        ExpenseDraft(
          groupId: gid,
          description: 'A description that is long enough to wrap twice',
          total: 30000,
          currency: 'INR',
          paidBy: SplitSpec(SplitMethod.exact, {me: 30000}),
          owedBy: SplitSpec(SplitMethod.equal, {me: 1, other: 1}),
          category: 'transport',
          date: qaNow.toUtc(),
        ),
      );
      final pid = await w.ledger.recordPayment(
        PaymentDraft(
          groupId: gid,
          from: other,
          to: me,
          amount: 5000,
          currency: 'INR',
          method: PaymentMethod.upi,
          date: qaNow.toUtc(),
        ),
      );
      final person = w.state.groups[gid]!.members[other]!;
      await pumpReal(tester, w, location: Routes.home);
      final routes = [
        Routes.group(gid),
        Routes.editGroup(gid),
        Routes.members(gid),
        Routes.groupActivity(gid),
        Routes.invite(gid),
        Routes.newExpense(groupId: gid),
        Routes.newExpense(),
        Routes.expense(eid, groupId: gid),
        Routes.editExpense(eid, groupId: gid),
        Routes.expense(pid, groupId: gid),
        Routes.editExpense(pid, groupId: gid),
        Routes.settle(groupId: gid),
        Routes.settle(groupId: gid, from: other, to: me),
        Routes.person(person.personId),
        Routes.search,
        Routes.settings,
        Routes.activity,
        Routes.sync,
      ];
      for (final r in routes) {
        w.go(Routes.home);
        await qaSettle(tester);
        w.push(r);
        await qaSettle(tester);
        expect(tester.takeException(), isNull, reason: r);
      }
      await w.shutdown(tester);
    });
  }
}
