// Edit group with a name this phone already holds (UIFLOW-R15-01): a
// name an older phone gave the group is kept as it is and never blocks a
// change to anything else; only a name the user types is checked.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import '../../qa/uiflow/real_harness.dart';

const _olderPhone = 'dddddddd-0000-7000-8000-000000000002';

Future<GroupId> _heldName(RealWorld w, String name) async {
  final gid = await w.seedGroup();
  final added = await w.ledger.applyRemote(gid, [
    Operation(
      id: '$gid/$_olderPhone/1',
      groupId: gid,
      deviceId: _olderPhone,
      counter: 1,
      hlc: Hlc(qaNow.millisecondsSinceEpoch + 60000, 0, _olderPhone),
      entityType: EntityType.group,
      entityId: gid,
      kind: OpKind.update,
      payload: {GroupFields.name: name},
    ),
  ]);
  expect(added, hasLength(1));
  expect(w.group(gid).group!.name, name);
  return gid;
}

Future<void> _openEdit(WidgetTester tester, RealWorld w, GroupId gid) async {
  await pumpReal(tester, w, location: Routes.home);
  w.push(Routes.group(gid));
  await qaSettle(tester);
  w.push(Routes.editGroup(gid));
  await qaSettle(tester);
  expect(find.text(S.editGroupTitle), findsOneWidget);
}

void main() {
  // Names the remote check accepts but a typed name would not: no letter
  // or number (symbols, emoji, a flag, punctuation).
  final held = <String>[
    '\u{1F3D6}\u{FE0F}',
    '★★',
    '...',
    '\u{1F1EE}\u{1F1F3}',
    '+-+',
    '© ®',
  ];
  for (final name in held) {
    testWidgets('a held name "$name" shows no error and every other setting '
        'saves without a rename', (tester) async {
      qaPhone(tester);
      final w = await RealWorld.create(name: 'Arjun');
      final gid = await _heldName(w, name);
      await _openEdit(tester, w, gid);
      expect(find.text(S.nameNeedsLetter), findsNothing);
      expect(find.text(S.errTooLong), findsNothing);
      await qaTap(tester, find.byType(Switch).first);
      await qaTap(tester, find.text(S.typeHome));
      await qaTap(tester, find.text(S.saveChanges));
      final g = w.group(gid).group!;
      expect(g.simplifyDebts, isFalse);
      expect(g.type, GroupType.home);
      expect(g.name, name);
      expect(w.location, Routes.group(gid));
      await w.shutdown(tester);
    });
  }

  testWidgets('a held name typed over with another name that is no name is '
      'still refused', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _heldName(w, '★★');
    await _openEdit(tester, w, gid);
    await tester.enterText(fieldLabeled(S.groupName), '★★★');
    await tester.pump();
    expect(find.text(S.nameNeedsLetter), findsOneWidget);
    await qaTap(tester, find.byType(Switch).first);
    await qaTap(tester, find.text(S.saveChanges));
    expect(w.group(gid).group!.name, '★★');
    expect(w.group(gid).group!.simplifyDebts, isTrue);
    expect(find.text(S.editGroupTitle), findsOneWidget);
    await w.shutdown(tester);
  });

  testWidgets('a held name typed back to itself after an edit is kept and '
      'saves', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _heldName(w, '...');
    await _openEdit(tester, w, gid);
    await tester.enterText(fieldLabeled(S.groupName), '..');
    await tester.pump();
    expect(find.text(S.nameNeedsLetter), findsOneWidget);
    await tester.enterText(fieldLabeled(S.groupName), '...');
    await tester.pump();
    expect(find.text(S.nameNeedsLetter), findsNothing);
    await qaTap(tester, find.byType(Switch).first);
    await qaTap(tester, find.text(S.saveChanges));
    expect(w.group(gid).group!.simplifyDebts, isFalse);
    expect(w.group(gid).group!.name, '...');
    await w.shutdown(tester);
  });

  testWidgets('a held name renamed to a real name saves the rename', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _heldName(w, '★★');
    await _openEdit(tester, w, gid);
    await tester.enterText(fieldLabeled(S.groupName), 'Stars');
    await tester.pump();
    await qaTap(tester, find.text(S.saveChanges));
    expect(w.group(gid).group!.name, 'Stars');
    await w.shutdown(tester);
  });

  testWidgets('a held name cleared is refused with "name needed"', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _heldName(w, '★★');
    await _openEdit(tester, w, gid);
    await tester.enterText(fieldLabeled(S.groupName), '');
    await tester.pump();
    await qaTap(tester, find.text(S.saveChanges));
    expect(find.text(S.nameNeeded), findsOneWidget);
    expect(w.group(gid).group!.name, '★★');
    await w.shutdown(tester);
  });
}
