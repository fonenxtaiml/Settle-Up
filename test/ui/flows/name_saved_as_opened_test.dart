// A name prompt or field saved with the name it opened with sends nothing
// (UIFLOW-R21-01, the class of UIFLOW-R17-01): not when the text is left
// as it opened, and not when it differs only by what is not kept in the
// saved name (spaces at the ends or doubled, characters that show
// nothing, a compatibility form). Covers every name editor that renames:
// Settings > Your name, Settings > Phone name, Members > Rename and the
// Edit group name. A real change is still saved.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import '../../qa/uiflow/real_harness.dart';

const _otherPhone = 'dddddddd-0000-7000-8000-000000002201';

var _counter = 0;

Future<void> _remote(
  RealWorld w,
  GroupId gid,
  EntityType type,
  String id,
  Map<String, Object?> payload,
) async {
  _counter++;
  final added = await w.ledger.applyRemote(gid, [
    Operation(
      id: '$gid/$_otherPhone/$_counter',
      groupId: gid,
      deviceId: _otherPhone,
      counter: _counter,
      hlc: Hlc(qaNow.millisecondsSinceEpoch + 60000, _counter, _otherPhone),
      entityType: type,
      entityId: id,
      kind: OpKind.update,
      payload: payload,
    ),
  ]);
  expect(added, hasLength(1));
}

final _dialogField = find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

Future<void> _dialogSave(WidgetTester tester) => qaTap(
  tester,
  find.descendant(of: find.byType(AlertDialog), matching: find.text(S.save)),
);

/// Texts that save as "Arjun": the profile name with only what the saved
/// name drops added.
const _sameAsArjun = [
  'Arjun ',
  '  Arjun',
  'Arjun​',
  'Arjunㅤ',
  '⁠Arjun­',
  'Arjun　',
  'Ａｒｊｕｎ',
];

void main() {
  group('Settings > Your name', () {
    for (final typed in _sameAsArjun) {
      testWidgets('saved as ${typed.runes.map((r) => r.toRadixString(16))} '
          'renames no member and keeps a friend\'s rename', (tester) async {
        qaPhone(tester);
        final w = await RealWorld.create(name: 'Arjun');
        final goa = await w.seedGroup();
        final office = await w.seedGroup(name: 'Office', people: ['Meera']);
        final me = w.settings.profile!.personId;
        final mine = w.group(office).memberForPerson(me)!.id;
        await _remote(w, office, EntityType.member, mine, {
          MemberFields.displayName: 'Arjun (Pune)',
        });
        final ops = w.ledger.current.state.groups[office]!;
        await pumpReal(tester, w, location: Routes.settings);
        await qaTap(tester, find.text('Arjun'));
        await tester.enterText(_dialogField, typed);
        await tester.pump();
        await _dialogSave(tester);
        expect(find.byType(AlertDialog), findsNothing);
        expect(w.settings.profile!.displayName, 'Arjun');
        expect(w.group(office).members[mine]!.displayName, 'Arjun (Pune)');
        expect(w.group(goa).memberForPerson(me)!.displayName, 'Arjun');
        expect(
          identical(w.ledger.current.state.groups[office], ops),
          isTrue,
          reason: 'nothing was written to Office',
        );
        await w.shutdown(tester);
      });
    }

    testWidgets('a case change is a change and renames me everywhere', (
      tester,
    ) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final office = await w.seedGroup(name: 'Office', people: ['Meera']);
      final me = w.settings.profile!.personId;
      final mine = w.group(office).memberForPerson(me)!.id;
      await w.ledger.renameMember(office, mine, 'Arjun K');
      await pumpReal(tester, w, location: Routes.settings);
      await qaTap(tester, find.text('Arjun'));
      await tester.enterText(_dialogField, 'ARJUN');
      await tester.pump();
      await _dialogSave(tester);
      expect(w.settings.profile!.displayName, 'ARJUN');
      expect(w.group(office).members[mine]!.displayName, 'ARJUN');
      await w.shutdown(tester);
    });

    testWidgets('a name with only spaces or hidden characters is still '
        'refused, not taken as unchanged', (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      await pumpReal(tester, w, location: Routes.settings);
      await qaTap(tester, find.text('Arjun'));
      await tester.enterText(_dialogField, 'ㅤ​');
      await tester.pump();
      expect(find.text(S.nameNeedsLetter), findsOneWidget);
      await _dialogSave(tester);
      // Save is off: the prompt stays open and nothing is saved.
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(w.settings.profile!.displayName, 'Arjun');
      await w.shutdown(tester);
    });
  });

  testWidgets('Settings > Phone name saved with a space added keeps the '
      'phone name', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final before = w.settings.device;
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.text(before.deviceName));
    await tester.enterText(_dialogField, '${before.deviceName}  ');
    await tester.pump();
    await _dialogSave(tester);
    expect(find.byType(AlertDialog), findsNothing);
    expect(identical(w.settings.device, before), isTrue);
    await w.shutdown(tester);
  });

  testWidgets('Members > Rename saved with a space added sends no rename, so '
      'a rename another phone made meanwhile stays', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup(people: const ['Priya']);
    final priya = w.member(gid, 'Priya');
    await pumpReal(tester, w, location: Routes.members(gid));
    await qaTap(tester, find.text('Priya'));
    await qaTap(
      tester,
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text(S.rename),
      ),
    );
    await tester.enterText(_dialogField, 'Priya​ ');
    await tester.pump();
    await _remote(w, gid, EntityType.member, priya, {
      MemberFields.displayName: 'Priya Shah',
    });
    await qaSettle(tester);
    await _dialogSave(tester);
    expect(w.group(gid).members[priya]!.displayName, 'Priya Shah');
    await w.shutdown(tester);
  });

  testWidgets('Edit group with a space added to the name sends no rename, so '
      'a rename another phone made meanwhile stays', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await pumpReal(tester, w, location: Routes.home);
    w.push(Routes.group(gid));
    await qaSettle(tester);
    w.push(Routes.editGroup(gid));
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), 'Goa  trip ');
    await tester.pump();
    await _remote(w, gid, EntityType.group, gid, {
      GroupFields.name: 'Goa 2026',
    });
    await qaSettle(tester);
    await qaTap(tester, find.text(S.saveChanges));
    expect(w.group(gid).group!.name, 'Goa 2026');
    await w.shutdown(tester);
  });
}
