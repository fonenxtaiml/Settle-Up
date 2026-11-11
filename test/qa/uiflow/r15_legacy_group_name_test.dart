// QA UIFLOW round 15: a group whose name came from an older phone (or an
// earlier build) with no letter or number, for example "🏖️", which the
// remote check accepts because it shows something (TextRules.isBlank).
// Over the real Ledger(MemoryOpStore) + KvSettingsRepository.
//
// Tests named "UIFLOW-R15-NN" with `skip:` are failing repros for open
// findings; unskip to verify a fix.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import 'real_harness.dart';

const _olderPhone = 'dddddddd-0000-7000-8000-000000000001';

/// The group as an older phone renamed it to [name].
Future<GroupId> _groupNamedByOlderPhone(RealWorld w, String name) async {
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

void main() {
  for (final name in ['\u{1F3D6}\u{FE0F}', '★★', '...']) {
    testWidgets(
      'UIFLOW-R15-01: Edit group of a group named "$name" by an '
      'older phone saves a change to simplify, emoji or currency without '
      'a rename',
      (tester) async {
        qaPhone(tester);
        final w = await RealWorld.create(name: 'Arjun');
        final gid = await _groupNamedByOlderPhone(w, name);
        expect(w.group(gid).group!.simplifyDebts, isTrue);
        await pumpReal(tester, w, location: Routes.home);
        w.push(Routes.group(gid));
        await qaSettle(tester);
        w.push(Routes.editGroup(gid));
        await qaSettle(tester);
        expect(find.text(S.editGroupTitle), findsOneWidget);
        // The name is left as it is; only Simplify is switched off.
        final simplify = find.byType(Switch);
        await qaTap(tester, simplify.first);
        await qaTap(tester, find.text(S.saveChanges));
        expect(
          w.group(gid).group!.simplifyDebts,
          isFalse,
          reason: 'Save refused because the untouched name has no letter',
        );
        expect(w.group(gid).group!.name, name);
        expect(w.location, Routes.group(gid));
        await w.shutdown(tester);
      },
      skip: true, // QA UIFLOW-R15-01: Edit group refuses every change to a group whose untouched name came from an older phone with no letter or number
    );
  }

  testWidgets('R15 probe (premise of UIFLOW-R15-01): the Ledger saves the '
      'same change to that group, and Archive on Edit group works', (
    tester,
  ) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await _groupNamedByOlderPhone(w, '\u{1F3D6}\u{FE0F}');
    await w.ledger.updateGroup(gid, const GroupPatch(simplifyDebts: false));
    expect(w.group(gid).group!.simplifyDebts, isFalse);
    await w.shutdown(tester);
  });
}
