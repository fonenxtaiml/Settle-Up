// QA DATA round 23: durability probes around SECURITY-R21-01 (lone
// surrogates are dropped from local text and refused from peers).
//
// Every local command that takes text runs with lone surrogates in it on
// the real SQLite store; the ledger is closed and reopened on the same
// file, and the canonical snapshot, profile and device must be the same,
// with every stored string well formed.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/text_clean.dart';
import 'package:settle_up/data/repositories.dart';

import 'durability_restart_test.dart' show expectSameSnapshot;
import 'qa_data_harness.dart';

const String lone = '\uD800';
const String loneLow = '\uDC00';

bool wellFormedJson(Object? v) => switch (v) {
  final String s => TextClean.isWellFormed(s),
  final Map<Object?, Object?> m => m.entries.every(
    (e) => wellFormedJson(e.key) && wellFormedJson(e.value),
  ),
  final List<Object?> l => l.every(wellFormedJson),
  _ => true,
};

void main() {
  late FilePhone a;

  setUp(() async {
    resetKeystore();
    a = FilePhone(qaTempDir());
    await a.launch();
  });

  tearDown(() async {
    try {
      await a.close();
    } catch (_) {}
    a.dir.deleteSync(recursive: true);
  });

  test('user text with lone surrogates is stored well formed and survives '
      'a restart unchanged', () async {
    await a.settings.completeOnboarding(
      displayName: 'Al${lone}ex',
      homeCurrency: 'INR',
    );
    await a.settings.setDeviceName('Pix${loneLow}el');
    final g = await a.ledger.createGroup(
      NewGroup(
        name: 'Goa$lone trip',
        type: GroupType.trip,
        currency: 'INR',
        emoji: '🏖$lone',
        newMemberNames: ['Sa${lone}m', 'Priya'],
      ),
    );
    final gs = a.group(g);
    final ids = gs.members.keys.toList()..sort();
    final e = await a.ledger.addExpense(
      ExpenseDraft(
        groupId: g,
        description: 'Din${lone}ner\nand$loneLow drinks',
        total: 6000,
        currency: 'INR',
        paidBy: SplitSpec.single(ids.first, 6000),
        owedBy: SplitSpec.equal(ids),
        category: 'food.dining',
        date: utcFromMillis(kQaBaseMs),
        notes: 'tip$lone included',
      ),
    );
    a.clock.advance();
    final sam = gs.members.values
        .firstWhere(
          (m) =>
              m.displayName != 'Priya' &&
              m.personId != a.settings.profile!.personId,
        )
        .id;
    await a.ledger.renameMember(g, sam, 'Sam$loneLow K');
    await a.ledger.updateGroup(g, GroupPatch(name: 'Goa ${lone}2026'));
    final direct = await a.ledger.directGroupWith(
      personId: 'person-kai',
      displayName: 'Ka${lone}i',
      currency: 'INR',
    );
    final before = a.snap;
    final profile = a.settings.profile;
    final device = a.settings.device;
    for (final op in before.ops) {
      expect(wellFormedJson(op.toJson()), isTrue, reason: op.id);
    }
    expect(
      before.state.groups[g]!.expenses[e]!.description,
      'Dinner\nand drinks',
    );
    await a.restart();
    expectSameSnapshot(before, a.snap);
    expect(profile!.displayName, 'Alex');
    expect(device.deviceName, 'Pixel');
    expect(
      (a.settings.profile!.personId, a.settings.profile!.displayName),
      (profile.personId, profile.displayName),
    );
    expect(
      (a.settings.device.deviceId, a.settings.device.deviceName),
      (device.deviceId, device.deviceName),
    );
    expect(
      a.group(direct).members.values.map((m) => m.displayName),
      contains('Kai'),
    );
    for (final op in a.snap.ops) {
      expect(jsonEncode(op.toJson()), isNot(contains('�')), reason: op.id);
    }
  });
}
