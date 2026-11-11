// QA UIFLOW round 23: reverification of UIFLOW-R21-01 (a name prompt saved
// as it opened sends nothing) across the defect class, beyond the inputs
// the fix was tested on: a profile name an earlier build saved unchecked
// (longer than the limit, not normalised) whose prompt opens with a cut or
// cleaned form, and Members > Rename on my own member.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/schema.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import 'real_harness.dart';

const _otherPhone = 'dddddddd-0000-7000-8000-000000002301';

var _counter = 0;

Future<void> _remoteRename(
  RealWorld w,
  GroupId gid,
  MemberId id,
  String name,
) async {
  _counter++;
  final added = await w.ledger.applyRemote(gid, [
    Operation(
      id: '$gid/$_otherPhone/$_counter',
      groupId: gid,
      deviceId: _otherPhone,
      counter: _counter,
      hlc: Hlc(qaNow.millisecondsSinceEpoch + 60000, _counter, _otherPhone),
      entityType: EntityType.member,
      entityId: id,
      kind: OpKind.update,
      payload: {MemberFields.displayName: name},
    ),
  ]);
  expect(added, hasLength(1));
}

String _letters(int n) =>
    List.generate(n, (i) => String.fromCharCode(0x61 + i % 26)).join();

/// A phone whose profile row an earlier build wrote unchecked.
Future<RealWorld> _legacy(String legacyName) async {
  final store = MemoryOpStore();
  await store.open();
  await store.setKv(
    KvKeys.profile,
    jsonEncode({
      'personId': 'p-legacy',
      'displayName': legacyName,
      'homeCurrency': 'INR',
    }),
  );
  return RealWorld.create(store: store);
}

final _dialogField = find.descendant(
  of: find.byType(AlertDialog),
  matching: find.byType(TextField),
);

Future<void> _dialogSave(WidgetTester tester) => qaTap(
  tester,
  find.descendant(of: find.byType(AlertDialog), matching: find.text(S.save)),
);

void main() {
  for (final (label, legacy) in [
    ('45 letters', 'Arjun ${_letters(39)}'),
    ('spaces around and doubled', '  Arjun   Kumar  '),
    ('a hidden character', 'Arjun​ Kumar'),
  ]) {
    testWidgets('R23 probe UIFLOW-R21-01: Settings, Your name with a legacy '
        'profile name ($label) saved as it opened renames no member', (
      tester,
    ) async {
      qaPhone(tester);
      final w = await _legacy(legacy);
      final goa = await w.seedGroup();
      final office = await w.seedGroup(name: 'Office', people: ['Meera']);
      final mine = w.group(office).memberForPerson('p-legacy')!.id;
      await _remoteRename(w, office, mine, 'Arjun (Pune)');
      final goaName = w.group(goa).memberForPerson('p-legacy')!.displayName;
      final officeBefore = w.state.groups[office];
      final goaBefore = w.state.groups[goa];
      await pumpReal(tester, w, location: Routes.settings);
      await qaTap(tester, find.byIcon(Icons.edit_outlined));
      expect(find.byType(AlertDialog), findsOneWidget);
      // Save as it opened, then again with a space added.
      await _dialogSave(tester);
      expect(find.byType(AlertDialog), findsNothing);
      await qaTap(tester, find.byIcon(Icons.edit_outlined));
      final opened = tester.widget<TextField>(_dialogField).controller!.text;
      // A full field takes no more characters: the 45-letter name opens
      // cut to 40, so only the shorter names get spaces added.
      final full = opened.characters.length >= NameText.maxLength;
      await tester.enterText(_dialogField, full ? opened : ' $opened  ');
      await tester.pump();
      await _dialogSave(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(w.settings.profile!.displayName, legacy);
      expect(w.group(office).members[mine]!.displayName, 'Arjun (Pune)');
      expect(w.group(goa).memberForPerson('p-legacy')!.displayName, goaName);
      expect(identical(w.state.groups[office], officeBefore), isTrue);
      expect(identical(w.state.groups[goa], goaBefore), isTrue);
      await w.shutdown(tester);
    });
  }

  testWidgets('R23 probe UIFLOW-R21-01: a real change of a legacy profile '
      'name is still saved and given to my member everywhere', (tester) async {
    qaPhone(tester);
    final w = await _legacy('Arjun ${_letters(39)}');
    final office = await w.seedGroup(name: 'Office', people: ['Meera']);
    final mine = w.group(office).memberForPerson('p-legacy')!.id;
    await pumpReal(tester, w, location: Routes.settings);
    await qaTap(tester, find.byIcon(Icons.edit_outlined));
    await tester.enterText(_dialogField, 'Arjun Kumar');
    await tester.pump();
    await _dialogSave(tester);
    expect(w.settings.profile!.displayName, 'Arjun Kumar');
    expect(w.group(office).members[mine]!.displayName, 'Arjun Kumar');
    await w.shutdown(tester);
  });

  for (final typed in ['Arjun (Pune) ', 'Arjun　(Pune)', 'Ａｒｊｕｎ (Pune)']) {
    testWidgets('R23 probe UIFLOW-R21-01: Members, Rename on my own member '
        'saved as ${typed.runes.map((r) => r.toRadixString(16))} keeps the '
        'name and writes nothing', (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await w.seedGroup(name: 'Office', people: ['Meera']);
      final me = w.settings.profile!.personId;
      final mine = w.group(gid).memberForPerson(me)!.id;
      await _remoteRename(w, gid, mine, 'Arjun (Pune)');
      final before = w.state.groups[gid];
      await pumpReal(tester, w, location: Routes.members(gid));
      await qaTap(tester, find.text(S.you));
      await qaTap(
        tester,
        find.descendant(
          of: find.byType(BottomSheet),
          matching: find.text(S.rename),
        ),
      );
      expect(
        tester.widget<TextField>(_dialogField).controller!.text,
        'Arjun (Pune)',
      );
      await tester.enterText(_dialogField, typed);
      await tester.pump();
      await _dialogSave(tester);
      expect(find.byType(AlertDialog), findsNothing);
      expect(w.group(gid).members[mine]!.displayName, 'Arjun (Pune)');
      expect(identical(w.state.groups[gid], before), isTrue);
      expect(NameText.fit(typed), 'Arjun (Pune)');
      await w.shutdown(tester);
    });
  }
}
