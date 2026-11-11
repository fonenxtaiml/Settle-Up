// Edit group sends only what the user changed (UIFLOW-R17-01): every field
// of the GroupPatch is compared with the value the form was loaded with,
// never with the live group, so a change another phone made to a field
// while the form was open survives a Save that changed some other field.
// A field the user did change is sent, even when another phone changed it
// too.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/ui/router.dart';
import 'package:settle_up/ui/strings.dart';

import '../../qa/uiflow/real_harness.dart';

const _otherPhone = 'dddddddd-0000-7000-8000-000000000171';

var _counter = 0;

Future<void> _remote(
  RealWorld w,
  GroupId gid,
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
      entityType: EntityType.group,
      entityId: gid,
      kind: OpKind.update,
      payload: payload,
    ),
  ]);
  expect(added, hasLength(1));
}

Future<void> _openEdit(WidgetTester tester, RealWorld w, GroupId gid) async {
  await pumpReal(tester, w, location: Routes.home);
  w.push(Routes.group(gid));
  await qaSettle(tester);
  w.push(Routes.editGroup(gid));
  await qaSettle(tester);
  expect(find.text(S.editGroupTitle), findsOneWidget);
}

/// One field another phone changes while the form is open, and how to
/// check that the change is still there.
typedef _Remote = ({
  String label,
  Map<String, Object?> payload,
  void Function(Group g) holds,
});

final List<_Remote> _remotes = [
  (
    label: 'name',
    payload: {GroupFields.name: 'Goa 2026'},
    holds: (g) => expect(g.name, 'Goa 2026'),
  ),
  (
    label: 'currency',
    payload: {GroupFields.currency: 'EUR'},
    holds: (g) => expect(g.currency, 'EUR'),
  ),
  (
    label: 'type',
    payload: {GroupFields.type: GroupType.couple.name},
    holds: (g) => expect(g.type, GroupType.couple),
  ),
  (
    label: 'emoji',
    payload: {GroupFields.emoji: '🎉'},
    holds: (g) => expect(g.emoji, '🎉'),
  ),
  (
    label: 'simplify',
    payload: {GroupFields.simplifyDebts: false},
    holds: (g) => expect(g.simplifyDebts, isFalse),
  ),
];

/// One field the user changes in the form, and how to check it was saved.
typedef _Local = ({
  String label,
  String skips,
  Future<void> Function(WidgetTester tester) change,
  void Function(Group g) saved,
});

final List<_Local> _locals = [
  (
    label: 'name',
    skips: 'name',
    change: (tester) async {
      await tester.enterText(fieldLabeled(S.groupName), 'Beach week');
      await tester.pump();
    },
    saved: (g) => expect(g.name, 'Beach week'),
  ),
  (
    label: 'type',
    skips: 'type',
    change: (tester) => qaTap(tester, find.text(S.typeHome)),
    saved: (g) => expect(g.type, GroupType.home),
  ),
  (
    label: 'simplify',
    skips: 'simplify',
    change: (tester) => qaTap(tester, find.byType(Switch).first),
    // The form loaded Simplify on; the user switched it off.
    saved: (g) => expect(g.simplifyDebts, isFalse),
  ),
];

void main() {
  for (final r in _remotes) {
    for (final l in _locals) {
      if (l.skips == r.label) continue;
      testWidgets('another phone changes the ${r.label} while Edit group is '
          'open; saving a ${l.label} change keeps it', (tester) async {
        qaPhone(tester);
        final w = await RealWorld.create(name: 'Arjun');
        final gid = await w.seedGroup();
        await _openEdit(tester, w, gid);
        await _remote(w, gid, r.payload);
        await qaSettle(tester);
        r.holds(w.group(gid).group!);
        await l.change(tester);
        await qaTap(tester, find.text(S.saveChanges));
        final g = w.group(gid).group!;
        l.saved(g);
        r.holds(g);
        expect(w.location, Routes.group(gid));
        await w.shutdown(tester);
      });
    }
  }

  testWidgets('a name the user typed wins over a rename another phone made '
      'while the form was open', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await _openEdit(tester, w, gid);
    await _remote(w, gid, {GroupFields.name: 'Goa 2026'});
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), 'Beach week');
    await tester.pump();
    await qaTap(tester, find.text(S.saveChanges));
    expect(w.group(gid).group!.name, 'Beach week');
    await w.shutdown(tester);
  });

  testWidgets('a name typed back to the one the form loaded is not sent: the '
      'other phone\'s rename stays', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    final loaded = w.group(gid).group!.name;
    await _openEdit(tester, w, gid);
    await _remote(w, gid, {GroupFields.name: 'Goa 2026'});
    await qaSettle(tester);
    await tester.enterText(fieldLabeled(S.groupName), 'Something');
    await tester.pump();
    await tester.enterText(fieldLabeled(S.groupName), ' $loaded ');
    await tester.pump();
    await qaTap(tester, find.byType(Switch).first);
    await qaTap(tester, find.text(S.saveChanges));
    final g = w.group(gid).group!;
    expect(g.name, 'Goa 2026');
    expect(g.simplifyDebts, isFalse);
    await w.shutdown(tester);
  });

  testWidgets('saving with nothing changed after another phone changed the '
      'currency and the name keeps both', (tester) async {
    qaPhone(tester);
    final w = await RealWorld.create(name: 'Arjun');
    final gid = await w.seedGroup();
    await _openEdit(tester, w, gid);
    await _remote(w, gid, {GroupFields.currency: 'EUR'});
    await _remote(w, gid, {GroupFields.name: 'Goa 2026'});
    await qaSettle(tester);
    // The form still shows the currency it loaded; Save sends no currency.
    expect(find.textContaining('(INR)'), findsOneWidget);
    await qaTap(tester, find.text(S.saveChanges));
    final g = w.group(gid).group!;
    expect(g.currency, 'EUR');
    expect(g.name, 'Goa 2026');
    await w.shutdown(tester);
  });
}
