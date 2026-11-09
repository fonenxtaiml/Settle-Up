// QA UIFLOW round 2: probes around the round 1 fixes (deep links across
// onboarding, back stack, Members rules, Add expense discard and messages,
// Settings rename and CSV export, per-group activity), on the real Ledger,
// KvSettingsRepository and DefaultSyncEngine.
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';
import 'package:settle_up/ui/widgets/kit_strings.dart';

import 'real_harness.dart';

const _share = MethodChannel('dev.fluttercommunity.plus/share');
const _paths = MethodChannel('plugins.flutter.io/path_provider');

Finder tab(String label) =>
    find.descendant(of: find.byType(NavigationBar), matching: find.text(label));

Future<void> pushDeepLink(WidgetTester tester, String link) async {
  await tester.binding.handlePushRoute(link);
  await qaSettle(tester);
}

Future<bool> androidBack(WidgetTester tester) async {
  final handled = await tester.binding.handlePopRoute();
  await qaSettle(tester);
  return handled;
}

Future<(String, GroupId)> friendInvite({String name = 'Cabin weekend'}) async {
  final friend = await RealWorld.create(name: 'Priya', idSeed: 5000);
  final gid = await friend.seedGroup(name: name, people: const ['Arjun']);
  final link = await friend.engine.inviteLinkFor(gid, includeHost: false);
  await friend.engine.dispose();
  return (link, gid);
}

Future<ExpenseId> seedExpense(
  RealWorld w,
  GroupId gid, {
  String description = 'Dinner',
  int total = 30000,
  String currency = 'INR',
  String payer = 'Arjun',
  List<String>? among,
  String notes = '',
}) {
  final g = w.group(gid);
  final members = among == null
      ? [for (final m in g.activeMembers) m.id]
      : [for (final n in among) w.member(gid, n)];
  return w.ledger.addExpense(
    ExpenseDraft(
      groupId: gid,
      description: description,
      total: total,
      currency: currency,
      paidBy: SplitSpec.single(w.member(gid, payer), total),
      owedBy: SplitSpec.equal(members),
      category: 'general',
      date: qaNow.toUtc(),
      notes: notes,
    ),
  );
}

Future<void> promptAndSave(WidgetTester tester, String value) async {
  await tester.enterText(
    find.descendant(
      of: find.byType(AlertDialog),
      matching: find.byType(TextField),
    ),
    value,
  );
  await tester.pump();
  await qaTap(
    tester,
    find.descendant(of: find.byType(AlertDialog), matching: find.text(S.save)),
  );
}

Future<void> letIoFinish(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
}

List<Map<Object?, Object?>> stubShare(WidgetTester tester) {
  final shares = <Map<Object?, Object?>>[];
  final tmp = Directory.systemTemp.createTempSync('qa_share_r2');
  final m = tester.binding.defaultBinaryMessenger;
  m.setMockMethodCallHandler(_share, (call) async {
    shares.add(call.arguments as Map<Object?, Object?>);
    return 'dev.fluttercommunity.plus/share/success';
  });
  m.setMockMethodCallHandler(_paths, (call) async => tmp.path);
  addTearDown(() {
    m.setMockMethodCallHandler(_share, null);
    m.setMockMethodCallHandler(_paths, null);
    tmp.deleteSync(recursive: true);
  });
  return shares;
}

Finder inDialog(String text) =>
    find.descendant(of: find.byType(AlertDialog), matching: find.text(text));

Finder inSheet(String text) =>
    find.descendant(of: find.byType(BottomSheet), matching: find.text(text));

bool saveEnabled(WidgetTester tester) =>
    filledButton(tester, S.saveExpense).onPressed != null;

void main() {
  // ------------------------------------------------ deep links (R1-07) --

  testWidgets(
    'UIFLOW-R1-07c: a settleup://sync link that cold-starts a fresh install starts a sync before onboarding and leaves the user stuck on Onboarding after Get started',
    (tester) async {
      qaPhone(tester);
      const link =
          'settleup://sync?v=1&h=192.168.43.1%3A47321&d=abcdef0123456789&n=Pixel';
      tester.binding.platformDispatcher.defaultRouteNameTestValue = link;
      addTearDown(
        tester.binding.platformDispatcher.clearDefaultRouteNameTestValue,
      );
      final w = await RealWorld.create();
      await pumpReal(tester, w);
      expect(find.text(S.onboardingTitle), findsOneWidget);
      await onboardThroughUi(tester, 'Arjun');
      await tester.pump(const Duration(seconds: 6));
      await qaSettle(tester);
      expect(
        w.location.startsWith(Routes.syncScan) ||
            w.location == Routes.syncSession,
        isTrue,
        reason: 'at ${w.location}',
      );
      expect(tester.takeException(), isNull);
      await w.shutdown(tester);
    },
    skip: true,
  ); // QA UIFLOW-R1-07

  testWidgets('R2 probe: an invite for a group whose name holds & # % / '
      'and Devanagari opens with the exact name', (tester) async {
    qaPhone(tester);
    const name = 'Raj & Priya #1 / 100% गोवा';
    final (link, _) = await friendInvite(name: name);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    await pushDeepLink(tester, link);
    expect(find.text(S.joinTitle), findsOneWidget);
    expect(find.text(name), findsWidgets);
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });

  testWidgets('R2 probe: a malformed join link held across onboarding shows '
      'the bad-invite copy, and Close goes Home', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create();
    await pumpReal(tester, w);
    await pushDeepLink(tester, 'settleup://join?v=1&g=nope');
    await onboardThroughUi(tester, 'Arjun');
    expect(find.text(S.badInvite), findsWidgets);
    await qaTap(tester, find.byTooltip(S.close));
    expect(w.location, Routes.home);
    expect(tester.takeException(), isNull);
    await w.shutdown(tester);
  });

  testWidgets('R2 probe: a link held before onboarding is opened only once '
      '(no second invitation later)', (tester) async {
    qaPhone(tester);
    final (link, _) = await friendInvite();
    final w = await RealWorld.create();
    await pumpReal(tester, w);
    await pushDeepLink(tester, link);
    await onboardThroughUi(tester, 'Arjun');
    expect(find.text(S.joinTitle), findsOneWidget);
    await qaTap(tester, find.byTooltip(S.close));
    expect(w.location, Routes.home);
    // Rename in Settings refreshes the profile (and the redirect).
    w.push(Routes.settings);
    await qaSettle(tester);
    await qaTap(tester, find.text('Arjun'));
    await promptAndSave(tester, 'Arjun M');
    await androidBack(tester);
    expect(w.location, Routes.home);
    expect(find.text(S.joinTitle), findsNothing);
    await w.shutdown(tester);
  });

  // ---------------------------------------------- back stack (R1-08/06) --

  testWidgets('R2 probe: Android back on an invitation opened by deep link '
      'returns to Home (the app is not closed)', (tester) async {
    qaPhone(tester);
    final (link, _) = await friendInvite();
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    await pushDeepLink(tester, link);
    expect(find.text(S.joinTitle), findsOneWidget);
    expect(await androidBack(tester), isTrue);
    expect(w.location, Routes.home);
    await w.shutdown(tester);
  });

  testWidgets('R2 probe: Android back on the Sync tab returns to Home', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    await qaTap(tester, tab(KitStrings.sync));
    expect(w.location, Routes.sync);
    expect(await androidBack(tester), isTrue);
    expect(w.location, Routes.home);
    expect(await androidBack(tester), isFalse);
    await w.shutdown(tester);
  });

  testWidgets('R2 probe: Activity tab > expense detail > back > back: '
      'detail, then Activity, then Home', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await seedExpense(w, gid, description: 'Ferry tickets');
    await pumpReal(tester, w);
    await qaTap(tester, tab(KitStrings.activity));
    await qaTap(tester, find.textContaining('Ferry tickets').first);
    expect(w.location.startsWith('/expense/'), isTrue, reason: w.location);
    expect(await androidBack(tester), isTrue);
    expect(w.location, Routes.activity);
    expect(await androidBack(tester), isTrue);
    expect(w.location, Routes.home);
    await w.shutdown(tester);
  });

  testWidgets(
    'UIFLOW-R2-01: an invite link opened while Add expense holds a draft throws the draft away without asking',
    (tester) async {
      qaPhone(tester);
      final (link, _) = await friendInvite();
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup();
      await pumpReal(tester, w);
      w.push(Routes.newExpense(groupId: gid));
      await qaSettle(tester);
      await tester.enterText(find.byType(TextField).at(0), '4200');
      await tester.enterText(fieldLabeled(S.description), 'Houseboat');
      await tester.pump();
      await pushDeepLink(tester, link);
      expect(find.text(S.joinTitle), findsOneWidget);
      // Close the invitation: the draft should still be there (or a discard
      // prompt should have been shown first).
      final prompted = find.text(S.discardTitle).evaluate().isNotEmpty;
      if (!prompted) {
        await qaTap(tester, find.byTooltip(S.close));
        expect(find.text('Houseboat'), findsOneWidget);
      }
      await w.shutdown(tester);
    },
    skip: true,
  ); // QA UIFLOW-R2-01

  // ----------------------------------------------------- Members rules --

  testWidgets('R2 probe: Remove is blocked when the open balance is only in '
      'a second currency (R1-19 neighbour)', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya', 'Rahul']);
    // An INR expense that nets to zero for Priya, and a USD one she owes on.
    await seedExpense(
      w,
      gid,
      total: 1000,
      currency: 'USD',
      among: const ['Arjun', 'Priya'],
    );
    await pumpReal(tester, w);
    w.push(Routes.members(gid));
    await qaSettle(tester);
    await qaTap(tester, find.text('Priya'));
    await qaTap(tester, inSheet(S.remove));
    expect(find.text(S.cannotRemoveTitle('Priya')), findsOneWidget);
    await qaTap(tester, inDialog(S.ok));
    expect(w.group(gid).members[w.member(gid, 'Priya')]!.isRemoved, isFalse);
    await w.shutdown(tester);
  });

  testWidgets('R2 probe: Remove is allowed for someone with no balance', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya', 'Rahul']);
    await seedExpense(w, gid, among: const ['Arjun', 'Priya']);
    final rahul = w.member(gid, 'Rahul');
    await pumpReal(tester, w);
    w.push(Routes.members(gid));
    await qaSettle(tester);
    await qaTap(tester, find.text('Rahul'));
    await qaTap(tester, inSheet(S.remove));
    await qaTap(tester, inDialog(S.remove));
    expect(w.group(gid).members[rahul]!.isRemoved, isTrue);
    await w.shutdown(tester);
  });

  testWidgets('R2 probe: rename a member to a name already in the group is '
      'refused with copy', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya', 'Rahul']);
    await pumpReal(tester, w);
    w.push(Routes.members(gid));
    await qaSettle(tester);
    await qaTap(tester, find.text('Rahul'));
    await qaTap(tester, inSheet(S.rename));
    await promptAndSave(tester, ' priya');
    expect(snackText(tester), S.alreadyInGroup('Priya'));
    expect(
      w.group(gid).activeMembers.map((m) => m.displayName),
      containsAll(['Priya', 'Rahul']),
    );
    await w.shutdown(tester);
  });

  testWidgets('R2 probe: New group with 50 people in total is created; a '
      '51st is refused with the group-full copy', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w);
    w.push(Routes.newGroup);
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), 'Wedding');
    for (var i = 1; i <= 50; i++) {
      await tester.enterText(fieldLabeled(S.personName), 'Guest $i');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
    }
    await qaTap(tester, find.text(S.createGroup));
    // Me + 50 guests = 51: refused with copy, nothing created.
    expect(snackText(tester), S.errGroupFull);
    expect(w.state.visibleGroups, isEmpty);
    await w.shutdown(tester);
  });

  testWidgets('R2 probe: a 1:1 group cannot get a third person through the '
      'Ledger either', (tester) async {
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.ledger.directGroupWith(
      personId: 'p-priya',
      displayName: 'Priya',
      currency: 'INR',
    );
    await expectLater(
      w.ledger.addMember(gid, displayName: 'Rahul'),
      throwsA(isA<LedgerException>()),
    );
    expect(w.group(gid).activeMembers.length, 2);
    await w.engine.dispose();
  });

  // --------------------------------------------- Add expense (R1-20 &c) --

  testWidgets('R2 probe: a pristine Add expense closes on Android back with '
      'no discard prompt', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    await qaTap(tester, find.byType(FloatingActionButton));
    expect(find.text(S.addExpenseTitle), findsOneWidget);
    await androidBack(tester);
    expect(find.text(S.discardTitle), findsNothing);
    expect(w.location, Routes.group(gid));
    await w.shutdown(tester);
  });

  testWidgets('R2 probe: an untouched Edit expense closes on Android back '
      'with no discard prompt', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final eid = await seedExpense(w, gid);
    await pumpReal(tester, w);
    w.push(Routes.expense(eid));
    await qaSettle(tester);
    w.push(Routes.editExpense(eid));
    await qaSettle(tester);
    await androidBack(tester);
    expect(find.text(S.discardTitle), findsNothing);
    expect(w.location, Routes.expense(eid));
    await w.shutdown(tester);
  });

  testWidgets(
    'UIFLOW-R1-20c: Edit expense with only the note changed: Android back throws the change away without asking',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup();
      final eid = await seedExpense(w, gid);
      await pumpReal(tester, w);
      w.push(Routes.expense(eid));
      await qaSettle(tester);
      w.push(Routes.editExpense(eid));
      await qaSettle(tester);
      await tester.enterText(fieldLabeled(S.notes), 'Paid with the card');
      await tester.pump();
      await androidBack(tester);
      expect(find.text(S.discardTitle), findsOneWidget);
      await w.shutdown(tester);
    },
    skip: true,
  ); // QA UIFLOW-R1-20

  testWidgets(
    'UIFLOW-R1-20d: Add expense with only a note typed: Android back throws it away without asking',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup();
      await pumpReal(tester, w);
      w.push(Routes.newExpense(groupId: gid));
      await qaSettle(tester);
      await tester.enterText(fieldLabeled(S.notes), 'Ask Priya for the bill');
      await tester.pump();
      await androidBack(tester);
      expect(find.text(S.discardTitle), findsOneWidget);
      await w.shutdown(tester);
    },
    skip: true,
  ); // QA UIFLOW-R1-20

  testWidgets(
    'UIFLOW-R1-01b: New group accepts a person with your own name (Members refuses it), giving two members called Arjun',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      await pumpReal(tester, w);
      w.push(Routes.newGroup);
      await qaSettle(tester);
      await tester.enterText(fieldLabeled(S.groupName), 'Cabin');
      await tester.enterText(fieldLabeled(S.personName), 'arjun');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pump();
      final refusedInline = find.text(S.alreadyInGroup('Arjun')).evaluate();
      await qaTap(tester, find.text(S.createGroup));
      final g = w.state.visibleGroups.singleOrNull;
      final names = [
        for (final m in g?.activeMembers ?? const <Member>[])
          m.displayName.toLowerCase(),
      ];
      expect(
        refusedInline.isNotEmpty || names.toSet().length == names.length,
        isTrue,
        reason: '$names',
      );
      await w.shutdown(tester);
    },
    skip: true,
  ); // QA UIFLOW-R1-01

  testWidgets('R2 probe: Add expense: Keep editing keeps the draft; Discard '
      'and close leaves', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    await qaTap(tester, find.byType(FloatingActionButton));
    await tester.enterText(find.byType(TextField).at(0), '4200');
    await tester.enterText(fieldLabeled(S.description), 'Houseboat');
    await tester.pump();
    await qaTap(tester, find.byTooltip(S.close));
    expect(find.text(S.discardTitle), findsOneWidget);
    await qaTap(tester, inDialog(S.keepEditing));
    expect(find.text(S.addExpenseTitle), findsOneWidget);
    expect(find.text('Houseboat'), findsOneWidget);
    await androidBack(tester);
    await qaTap(tester, inDialog(S.discardAndClose));
    expect(w.location, Routes.group(gid));
    expect(w.group(gid).liveExpenses, isEmpty);
    await w.shutdown(tester);
  });

  testWidgets('R2 probe: after Save the editor closes without a discard '
      'prompt', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    await qaTap(tester, find.byType(FloatingActionButton));
    await tester.enterText(find.byType(TextField).at(0), '300');
    await tester.enterText(fieldLabeled(S.description), 'Dinner');
    await tester.pump();
    await qaTap(tester, find.text(S.saveExpense));
    expect(find.text(S.discardTitle), findsNothing);
    expect(w.location, Routes.group(gid));
    expect(w.group(gid).liveExpenses.length, 1);
    await w.shutdown(tester);
  });

  testWidgets(
    'UIFLOW-R2-02: typing 12000000 in IDR leaves 1,200,000 in the field with Save enabled, so a tenth of the bill can be saved',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup(name: 'Bali', currency: 'IDR');
      await pumpReal(tester, w);
      w.push(Routes.newExpense(groupId: gid));
      await qaSettle(tester);
      final amount = find.byType(TextField).at(0);
      await tester.tap(amount);
      await tester.pump();
      // Typed one key at a time, as on a phone keyboard.
      var text = '';
      for (final ch in '12000000'.split('')) {
        text = tester.widget<TextField>(amount).controller!.text + ch;
        tester.testTextInput.updateEditingValue(
          TextEditingValue(
            text: text,
            selection: TextSelection.collapsed(offset: text.length),
          ),
        );
        await tester.pump();
      }
      await tester.enterText(fieldLabeled(S.description), 'Villa');
      await tester.pump();
      final shown = tester.widget<TextField>(amount).controller!.text;
      final message = find.textContaining('Enter an amount up to');
      // Expected: no amount other than what was typed can be saved: either the
      // field keeps 12,000,000 (accepted) or Save is off until it is fixed.
      final misleading = shown == '1,200,000' && saveEnabled(tester);
      expect(message, findsOneWidget);
      expect(misleading, isFalse, reason: 'field shows "$shown"');
      await w.shutdown(tester);
    },
    skip: true,
  ); // QA UIFLOW-R2-02

  // ------------------------------------------------- Settings (R1-18 &c) --

  testWidgets('R2 probe: renaming yourself reaches archived and 1:1 groups '
      'too', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final goa = await w.seedGroup();
    final old = await w.seedGroup(name: 'Old trip');
    await w.ledger.updateGroup(old, const GroupPatch(archived: true));
    final direct = await w.ledger.directGroupWith(
      personId: 'p-meera',
      displayName: 'Meera',
      currency: 'INR',
    );
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text('Arjun'));
    await promptAndSave(tester, 'Arjun Mehta');
    final me = w.settings.profile!.personId;
    for (final g in [goa, old, direct]) {
      expect(
        w.group(g).memberForPerson(me)!.displayName,
        'Arjun Mehta',
        reason: w.group(g).group!.name,
      );
    }
    await w.shutdown(tester);
  });

  testWidgets(
    'UIFLOW-R2-03: renaming yourself in Settings to the name of someone in your group makes two indistinguishable members',
    (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup(people: const ['Priya', 'Rahul']);
      await pumpReal(tester, w, location: Routes.settings);
      await qaTap(tester, find.text('Arjun'));
      await promptAndSave(tester, 'Rahul');
      final names = [
        for (final m in w.group(gid).activeMembers) m.displayName.toLowerCase(),
      ];
      // Expected: the member names in the group stay distinct (the rename is
      // refused or flagged, as Members does for "Rahul is already in this
      // group").
      expect(names.toSet().length, names.length, reason: '$names');
      await w.shutdown(tester);
    },
    skip: true,
  ); // QA UIFLOW-R2-03

  testWidgets('R2 probe: CSV of a Devanagari-named group is shared as '
      '"<name>.csv"; an emoji-only name falls back', (tester) async {
    qaPhone(tester);
    final shares = stubShare(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await w.seedGroup(name: 'गोवा ट्रिप');
    await w.seedGroup(name: '🏖️🌴');
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text(S.exportGroupCsv));
    await qaTap(tester, inSheet('गोवा ट्रिप'));
    await letIoFinish(tester);
    await qaTap(tester, find.text(S.exportGroupCsv));
    await qaTap(tester, inSheet('🏖️🌴'));
    await letIoFinish(tester);
    final names = [
      for (final s in shares)
        (s['paths']! as List).cast<String>().single.split('/').last,
    ];
    expect(names, ['गोवा ट्रिप.csv', 'settle-up-export.csv']);
    await w.shutdown(tester);
  });

  testWidgets('R2 probe: Group menu > Export as CSV: a share error shows '
      'copy, nothing is thrown', (tester) async {
    qaPhone(tester);
    final m = tester.binding.defaultBinaryMessenger;
    final tmp = Directory.systemTemp.createTempSync('qa_share_fail_r2');
    m.setMockMethodCallHandler(_paths, (call) async => tmp.path);
    m.setMockMethodCallHandler(_share, (call) async {
      throw PlatformException(code: 'error', message: 'No activity found');
    });
    addTearDown(() {
      m.setMockMethodCallHandler(_share, null);
      m.setMockMethodCallHandler(_paths, null);
      tmp.deleteSync(recursive: true);
    });
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    await qaTap(tester, find.byTooltip(S.moreOptions));
    await qaTap(tester, find.text(S.exportCsv));
    await letIoFinish(tester);
    expect(tester.takeException(), isNull);
    expect(snackText(tester), S.errGeneric);
    await w.shutdown(tester);
  });

  testWidgets('R2 probe: Phone name is capped at 40', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text(S.phoneName));
    await promptAndSave(tester, 'P' * 90);
    expect(w.settings.device.deviceName.length, lessThanOrEqualTo(40));
    await w.shutdown(tester);
  });

  // ------------------------------------------- group activity (R1-17) --

  testWidgets('R2 probe: the group Activity shows only that group, and Back '
      'returns to the group', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final goa = await w.seedGroup();
    final flat = await w.seedGroup(name: 'Flat 4B', people: const ['Meera']);
    await seedExpense(w, goa, description: 'Ferry tickets');
    await seedExpense(w, flat, description: 'Electricity bill');
    await pumpReal(tester, w);
    w.push(Routes.group(goa));
    await qaSettle(tester);
    await qaTap(tester, find.byTooltip(S.moreOptions));
    await qaTap(tester, find.text(S.activityTitle).last);
    expect(w.location, Routes.groupActivity(goa));
    expect(find.textContaining('Ferry tickets'), findsWidgets);
    expect(find.textContaining('Electricity bill'), findsNothing);
    expect(find.text(S.filterSyncs), findsNothing);
    expect(find.byType(FloatingActionButton), findsNothing);
    await qaTap(tester, find.byTooltip(S.back));
    expect(w.location, Routes.group(goa));
    await w.shutdown(tester);
  });

  // ------------------------------------------------------- Home (R1-16) --

  testWidgets('R2 probe: with only archived groups and a 1:1 group, the '
      'Home FAB starts in the 1:1 group', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final old = await w.seedGroup(name: 'Old trip');
    await seedExpense(w, old, total: 5000);
    await w.ledger.updateGroup(old, const GroupPatch(archived: true));
    final direct = await w.ledger.directGroupWith(
      personId: 'p-meera',
      displayName: 'Meera',
      currency: 'INR',
    );
    await seedExpense(w, direct, total: 5000);
    await pumpReal(tester, w);
    await qaTap(tester, find.byType(FloatingActionButton));
    expect(find.text(S.addExpenseTitle), findsOneWidget);
    expect(find.text('Old trip'), findsNothing);
    expect(find.text('Meera'), findsWidgets);
    await w.shutdown(tester);
  });

  test('UIFLOW-R2-04: one cap for every currency (9,999,999.99) refuses an '
      'everyday Rp 12,000,000 villa bill in an IDR group', () async {
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(name: 'Bali', currency: 'IDR');
    // Rp 12,000,000.00 is about 750 USD; the cap is about 630 USD in IDR
    // and about 2,500 USD in COP, against about 120,000 USD in INR.
    await seedExpense(
      w,
      gid,
      description: 'Villa',
      total: 1200000000,
      currency: 'IDR',
    );
    expect(w.group(gid).liveExpenses.single.money.total, 1200000000);
    await w.engine.dispose();
  }, skip: true); // QA UIFLOW-R2-04
}
