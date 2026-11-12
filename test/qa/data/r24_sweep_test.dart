// QA DATA round 24: final regression sweep.
//
// SECURITY-R21-01 made the reducer and the edit history drop lone UTF-16
// surrogates from text "an op stored earlier may hold" (SPEC 5.16), and
// made every phone refuse a peer batch with any string that is not well
// formed. An op stored before that check is still offered to peers as it
// is stored: jsonEncode escapes a lone surrogate ("\ud800"), so the peer
// decodes it, refuses the batch, and the session fails, on every sync.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/text_clean.dart';
import 'package:settle_up/sync/protocol/session.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../sync/support/harness.dart';
import '../../sync/support/phone.dart';
import 'qa_data_harness.dart';

const String kLegacyTitle =
    'QA DATA-R24-01: an op stored before SECURITY-R21-01 with a lone '
    'surrogate in its text fails every sync of its phone with updated peers, '
    'and none of its group\'s later ops ever reach them';

void main() {
  late FilePhone a;
  late Trip t;

  setUp(() async {
    resetKeystore();
    a = FilePhone(qaTempDir());
    await a.launch();
    await a.settings.completeOnboarding(
      displayName: 'Alex',
      homeCurrency: 'INR',
    );
    t = await qaTrip(a);
  });

  tearDown(() async {
    try {
      await a.close();
    } catch (_) {}
    a.dir.deleteSync(recursive: true);
  });

  /// One session with [a] as initiator and [b] as responder.
  Future<(SessionResult, SessionResult)> sync(TestPhone b) async {
    final (ci, cr) = await channelPair();
    final si = SyncSession(
      channel: ci,
      store: a.ledger,
      role: SessionRole.initiator,
      timings: fastTimings,
    );
    final sr = SyncSession(
      channel: cr,
      store: b.store,
      role: SessionRole.responder,
      timings: fastTimings,
    );
    final r = await Future.wait([si.run(), sr.run()]);
    return (r[0], r[1]);
  }

  test(kLegacyTitle, () async {
    final e = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.sam], description: 'Dinner'),
    );
    final create = a
        .opsOf(t.g)
        .firstWhere((o) => o.entityId == e && o.kind == OpKind.create);
    // The row as a build before SECURITY-R21-01 stored it: the text held a
    // lone surrogate (JSON "\ud800", which every JSON codec reads back).
    await a.close();
    final db = sqlite3.open(a.path);
    try {
      db.execute(
        "UPDATE ops SET json = replace(json, '\"Dinner\"', ?) "
        'WHERE op_id = ?',
        [r'"Din\ud800ner"', create.id],
      );
      expect(db.updatedRows, 1);
    } finally {
      db.close();
    }
    await a.launch();

    // This phone keeps the row and shows it well formed (the R21 fix).
    final shown = a.snap.state.expense(e)!.description;
    expect(TextClean.isWellFormed(shown), isTrue);
    expect(shown, 'Dinner');
    // Later edits of the group, written by the fixed build.
    a.clock.advance();
    final taxi = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.priya], description: 'Taxi', total: 900),
    );
    final mine = a.mineIn(t.g).length;

    // Priya's phone, on the fixed build, joins by invite and syncs twice.
    final b = await TestPhone.create('b', name: 'Priya');
    addTearDown(b.close);
    await b.ledger.registerJoinedGroup(
      t.g,
      (await a.ledger.groupKeys())[t.g]!,
      'Goa trip',
    );
    for (var round = 1; round <= 2; round++) {
      final (ri, rr) = await sync(b);
      // ignore: avoid_print
      print(
        '[r24] sync $round: ${ri.outcome}/${ri.failure} '
        '"${ri.message}" | ${rr.outcome}/${rr.failure} "${rr.message}"; '
        'B holds ${b.opCount(t.g)} of $mine ops, '
        'A unshared ${a.snap.unsharedCounts[t.g]}',
      );
      expect(rr.outcome, SyncOutcome.completed, reason: rr.message);
      expect(ri.outcome, SyncOutcome.completed, reason: ri.message);
    }
    // Both phones show the same group: every op of A reached B, the
    // legacy text shown well formed on both, and A has nothing unshared.
    expect(b.opCount(t.g), mine);
    expect(b.state.expense(taxi), isNotNull);
    expect(b.state.expense(e)?.description, shown);
    expect(a.snap.unsharedCounts[t.g] ?? 0, 0);
  }, skip: kLegacyTitle);
}
