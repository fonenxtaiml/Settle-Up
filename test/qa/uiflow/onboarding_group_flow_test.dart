// QA UIFLOW: onboarding -> empty Home -> create group -> members, on the
// real Ledger(MemoryOpStore) + KvSettingsRepository.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import 'real_harness.dart';

void main() {
  testWidgets('fresh install: onboarding saves the profile and lands on the '
      'empty Home without a FAB', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create();
    await pumpReal(tester, w);

    expect(w.location, Routes.onboarding);
    final start = filledButton(tester, S.getStarted);
    expect(start.onPressed, isNull);

    // Whitespace only keeps Get started disabled.
    await tester.enterText(find.byType(TextField).first, '   ');
    await tester.pump();
    expect(filledButton(tester, S.getStarted).onPressed, isNull);

    await onboardThroughUi(tester, '  Arjun  ');
    expect(w.settings.profile, isNotNull);
    expect(w.settings.profile!.displayName, 'Arjun');
    expect(w.location, Routes.home);
    expect(find.text(S.homeEmptyHeadline), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsNothing);
    await w.shutdown(tester);
  });

  testWidgets('onboarding name is capped at 40 characters', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create();
    await pumpReal(tester, w);
    await onboardThroughUi(tester, 'A' * 60);
    expect(w.settings.profile!.displayName.length, 40);
    await w.shutdown(tester);
  });

  testWidgets('create group from the empty state: name required, type, '
      'currency, emoji and simplify are saved', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    expect(find.text(S.homeEmptyHeadline), findsOneWidget);

    await qaTap(tester, find.text(S.createGroup).last);
    expect(w.location, Routes.newGroup);

    // Empty name: Create shows the error copy and writes nothing.
    await qaTap(tester, find.text(S.createGroupAction).last);
    expect(find.text(S.nameNeeded), findsOneWidget);
    expect(w.state.visibleGroups, isEmpty);

    // 61 characters: the field keeps 60.
    await tester.enterText(fieldLabeled(S.groupName), 'G' * 61);
    await tester.pump();
    expect(
      tester.widget<TextField>(fieldLabeled(S.groupName)).controller!.text,
      hasLength(60),
    );
    await tester.enterText(fieldLabeled(S.groupName), 'Flat 4B');
    await tester.pump();

    await qaTap(tester, find.text(S.typeHome));

    // Currency picker: search and pick EUR.
    await qaTap(tester, find.text(S.currency));
    await tester.enterText(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(TextField),
      ),
      'EUR',
    );
    await qaSettle(tester);
    await qaTap(tester, find.widgetWithText(ListTile, 'EUR').first);

    // Emoji.
    await qaTap(tester, find.text(S.emoji));
    await qaTap(
      tester,
      find.descendant(of: find.byType(BottomSheet), matching: find.text('🏠')),
    );

    // Simplify off.
    await qaTap(tester, find.text(S.simplifyDebts));

    // People: one typed and left in the field is still added on Create.
    await tester.enterText(fieldLabeled(S.personName), 'Priya');
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    await tester.enterText(fieldLabeled(S.personName), 'Rahul');
    await tester.pump();

    await qaTap(tester, find.text(S.createGroupAction).last);

    final g = w.groupNamed('Flat 4B');
    expect(g.group!.type, GroupType.home);
    expect(g.group!.currency, 'EUR');
    expect(g.group!.emoji, '🏠');
    expect(g.group!.simplifyDebts, isFalse);
    expect(
      g.activeMembers.map((m) => m.displayName).toSet(),
      {'Arjun', 'Priya', 'Rahul'},
    );
    expect(w.location, Routes.group(g.groupId));
    // FAB on Group detail.
    expect(find.byType(FloatingActionButton), findsOneWidget);

    // Back from the new group lands on Home with the group listed.
    await qaTap(tester, find.byTooltip(S.back));
    expect(w.location, Routes.home);
    expect(find.text('Flat 4B'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('edit group: rename, remove emoji and archive', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    w.push(Routes.editGroup(gid));
    await qaSettle(tester);

    await tester.enterText(fieldLabeled(S.groupName), '  Goa 2026 ');
    await tester.pump();
    await qaTap(tester, find.text(S.saveChanges));
    expect(w.group(gid).group!.name, 'Goa 2026');
    expect(w.location, Routes.group(gid));

    // Clearing the name on edit is refused with the copy, nothing written.
    w.push(Routes.editGroup(gid));
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), '');
    await tester.pump();
    await qaTap(tester, find.text(S.saveChanges));
    expect(find.text(S.nameNeeded), findsOneWidget);
    expect(w.group(gid).group!.name, 'Goa 2026');

    await qaTap(tester, find.text(S.archiveGroup));
    expect(w.group(gid).group!.archived, isTrue);
    await w.shutdown(tester);
  });

  testWidgets('members: add, rename and remove through the screen', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya']);
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.members(gid));
    await qaSettle(tester);

    await tester.enterText(fieldLabeled(S.personName), 'Meera');
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    expect(snackText(tester), S.memberAdded);
    expect(
      w.group(gid).activeMembers.map((m) => m.displayName),
      contains('Meera'),
    );

    await qaTap(tester, find.text('Meera'));
    await qaTap(tester, find.text(S.rename));
    await tester.enterText(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
      'Meera K',
    );
    await tester.pump();
    await qaTap(tester, find.text(S.save));
    expect(
      w.group(gid).activeMembers.map((m) => m.displayName),
      contains('Meera K'),
    );

    await qaTap(tester, find.text('Meera K'));
    await qaTap(tester, find.text(S.remove));
    await qaTap(
      tester,
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(S.remove),
      ),
    );
    expect(
      w.group(gid).activeMembers.map((m) => m.displayName),
      isNot(contains('Meera K')),
    );
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-01: adding the same person name twice to a new '
      'group creates two indistinguishable members', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.newGroup);
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), 'Cabin');
    for (final n in ['Priya', 'priya ', 'Priya']) {
      await tester.enterText(fieldLabeled(S.personName), n);
      await tester.pump();
      await qaTap(tester, find.text(S.addPerson));
    }
    await qaTap(tester, find.text(S.createGroupAction).last);
    final names = w
        .groupNamed('Cabin')
        .activeMembers
        .map((m) => m.displayName.toLowerCase())
        .toList();
    // Expected: a duplicate is refused or flagged, so the group never holds
    // three people called Priya that nobody can tell apart in pickers.
    expect(names.where((n) => n == 'priya').length, 1);
    await w.shutdown(tester);
  }, skip: true); // QA UIFLOW-R1-01

  testWidgets('UIFLOW-R1-02: Members screen accepts a 51st active member '
      '(SPEC 5.16 caps a group at 50)', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(
      people: [for (var i = 1; i <= 49; i++) 'Person $i'],
    );
    expect(w.group(gid).activeMembers.length, 50);
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.members(gid));
    await qaSettle(tester);
    await qaReveal(tester, fieldLabeled(S.personName));
    await tester.enterText(fieldLabeled(S.personName), 'One too many');
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    expect(w.group(gid).activeMembers.length, 50);
    expect(snackText(tester), isNot(S.memberAdded));
    await w.shutdown(tester);
  });

  testWidgets('UIFLOW-R1-03: member and person names have no 40 character '
      'limit in the UI (SPEC 5.16: member name 1..40)', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya']);
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.members(gid));
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.personName), 'N' * 80);
    await tester.pump();
    await qaTap(tester, find.text(S.addPerson));
    for (final m in w.group(gid).activeMembers) {
      expect(m.displayName.length, lessThanOrEqualTo(40));
    }
    await w.shutdown(tester);
  }, skip: true); // QA UIFLOW-R1-03

  testWidgets('UIFLOW-R1-19: Members lets you remove someone who still owes '
      'money (SPEC 6.7: the UI blocks Remove when the net is non-zero)', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya']);
    final me = w.member(gid, 'Arjun');
    final priya = w.member(gid, 'Priya');
    await w.ledger.addExpense(
      ExpenseDraft(
        groupId: gid,
        description: 'Flight',
        total: 800000,
        currency: 'INR',
        paidBy: SplitSpec.single(me, 800000),
        owedBy: SplitSpec.equal([me, priya]),
        category: 'general',
        date: qaNow.toUtc(),
      ),
    );
    await pumpReal(tester, w);
    w.push(Routes.members(gid));
    await qaSettle(tester);
    await qaTap(tester, find.text('Priya'));
    final remove = find.descendant(
      of: find.byType(BottomSheet),
      matching: find.text(S.remove),
    );
    if (remove.evaluate().isNotEmpty) {
      await qaTap(tester, remove);
      final confirm = find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text(S.remove),
      );
      if (confirm.evaluate().isNotEmpty) await qaTap(tester, confirm);
    }
    // Expected: Priya (owes ₹4,000) is still a member.
    expect(w.group(gid).members[priya]!.isRemoved, isFalse);
    await w.shutdown(tester);
  }, skip: true); // QA UIFLOW-R1-19
}
