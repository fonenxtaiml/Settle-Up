// QA DATA round 26: reverification of DATA-R24-01 and a sweep of its
// class: an op stored by an earlier build (written here or relayed) that
// holds text the remote checks of this build refuse. TextRules.canonical
// now reads every stored op in the form updated peers accept.
//
// Probed beyond the engineering tests: ops of a newer schema whose raw JSON
// holds lone surrogates outside the payload, sync in both directions with
// the legacy phone as responder, a third phone relayed through the updated
// peer, local edits of entities whose stored text is legacy, restart
// stability of the canonical form, and the open cost when every stored op
// needs cleaning.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/ops.dart';
import 'package:settle_up/core/text_clean.dart';
import 'package:settle_up/core/version_vector.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/data/text_rules.dart';
import 'package:settle_up/sync/protocol/session.dart';
import 'package:sqlite3/sqlite3.dart';

import '../../sync/support/harness.dart';
import '../../sync/support/phone.dart';
import 'qa_data_harness.dart';

/// [json] with every lone surrogate written as a \uXXXX escape, the way a
/// JSON codec stores it, so the SQLite text column stays valid UTF-8.
String escapeLone(String json) {
  final out = StringBuffer();
  final u = json.codeUnits;
  for (var i = 0; i < u.length; i++) {
    final c = u[i];
    final hi = c >= 0xD800 && c <= 0xDBFF;
    final lo = c >= 0xDC00 && c <= 0xDFFF;
    if (hi && i + 1 < u.length && u[i + 1] >= 0xDC00 && u[i + 1] <= 0xDFFF) {
      out.writeCharCode(c);
      out.writeCharCode(u[++i]);
    } else if (hi || lo) {
      out.write('\\u${c.toRadixString(16)}');
    } else {
      out.writeCharCode(c);
    }
  }
  return out.toString();
}

void rewriteJson(
  Database db,
  String opId,
  void Function(Map<String, Object?> json) edit,
) {
  final row = db.select('SELECT json FROM ops WHERE op_id = ?', [opId]);
  final json = Map<String, Object?>.from(
    jsonDecode(row.single.columnAt(0) as String) as Map,
  );
  edit(json);
  db.execute('UPDATE ops SET json = ? WHERE op_id = ?', [
    escapeLone(jsonEncode(json)),
    opId,
  ]);
  expect(db.updatedRows, 1);
}

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

  Future<(SessionResult, SessionResult)> sync(
    SyncStore initiator,
    SyncStore responder,
  ) async {
    final (ci, cr) = await channelPair();
    final r = await Future.wait([
      SyncSession(
        channel: ci,
        store: initiator,
        role: SessionRole.initiator,
        timings: fastTimings,
      ).run(),
      SyncSession(
        channel: cr,
        store: responder,
        role: SessionRole.responder,
        timings: fastTimings,
      ).run(),
    ]);
    return (r[0], r[1]);
  }

  void expectCompleted((SessionResult, SessionResult) r) {
    expect(r.$1.outcome, SyncOutcome.completed, reason: r.$1.message);
    expect(r.$2.outcome, SyncOutcome.completed, reason: r.$2.message);
  }

  Operation createOf(String id) => a
      .opsOf(t.g)
      .firstWhere((o) => o.entityId == id && o.kind == OpKind.create);

  test('legacy text in every field: the updated peer initiates, a third '
      'phone gets it relayed, local edits of the legacy entities sync, and '
      'the shown text is the same after each restart', () async {
    final e = await a.ledger.addExpense(qaDraft(t.g, [t.me, t.sam]));
    final groupOp = createOf(t.g).id;
    final samOp = createOf(t.sam).id;
    final expenseOp = createOf(e).id;
    await a.close();
    final db = sqlite3.open(a.path);
    try {
      rewriteJson(db, groupOp, (j) {
        final p = Map<String, Object?>.from(j['payload']! as Map);
        // Hangul fillers over the cap: blank once cut.
        p[GroupFields.name] = '\u3164' * 300;
        p[GroupFields.emoji] = '\uD83C';
        j['payload'] = p;
      });
      rewriteJson(db, samOp, (j) {
        final p = Map<String, Object?>.from(j['payload']! as Map);
        p[MemberFields.displayName] = '\u202ESam\u0085\u0007';
        j['payload'] = p;
      });
      rewriteJson(db, expenseOp, (j) {
        final p = Map<String, Object?>.from(j['payload']! as Map);
        p[ExpenseFields.description] = 'Din\uD800ner${'\u0301' * 700}';
        p[ExpenseFields.notes] = 'line\u2028two\u009F';
        p[ExpenseFields.paymentMethod] = 'upi\u001B';
        j['payload'] = p;
      });
    } finally {
      db.close();
    }
    await a.launch();
    final name = a.group(t.g).group!.name;
    final sam = a.group(t.g).members[t.sam]!.displayName;
    final desc = a.snap.state.expense(e)!.description;
    expect(name, TextRules.unreadableName);
    expect(sam.trim(), 'Sam');
    expect(desc.startsWith('Dinner'), isTrue);
    expect(desc.length, lessThanOrEqualTo(TextRules.description * 4));
    for (final s in [name, sam, desc]) {
      expect(TextClean.isWellFormed(s), isTrue);
    }

    // The updated phone initiates; the legacy phone answers.
    final b = await TestPhone.create('b', name: 'Priya');
    addTearDown(b.close);
    await b.ledger.registerJoinedGroup(
      t.g,
      (await a.ledger.groupKeys())[t.g]!,
      'Goa trip',
    );
    expectCompleted(await sync(b.store, a.ledger));
    expect(b.opCount(t.g), a.opsOf(t.g).length);
    expect(b.state.groups[t.g]!.group!.name, name);
    expect(b.state.groups[t.g]!.members[t.sam]!.displayName, sam);
    expect(b.state.expense(e)!.description, desc);

    // A third phone gets everything through B only.
    final c = await TestPhone.create('c', name: 'Sam');
    addTearDown(c.close);
    await c.ledger.registerJoinedGroup(
      t.g,
      (await a.ledger.groupKeys())[t.g]!,
      'Goa trip',
    );
    expectCompleted(await sync(c.store, b.store));
    expect(c.opCount(t.g), a.opsOf(t.g).length);
    expect(c.state.expense(e)!.description, desc);

    // Local edits on the legacy phone of the entities whose rows are
    // legacy, then a restart, then a sync with A initiating.
    a.clock.advance();
    await a.ledger.updateGroup(t.g, const GroupPatch(name: 'Goa'));
    await a.ledger.updateExpense(
      e,
      qaDraft(t.g, [t.me, t.sam], description: 'Dinner 2', total: 7000),
    );
    await a.restart();
    expect(a.group(t.g).group!.name, 'Goa');
    expect(a.snap.state.expense(e)!.description, 'Dinner 2');
    expectCompleted(await sync(a.ledger, b.store));
    expect(b.state.groups[t.g]!.group!.name, 'Goa');
    expect(b.state.expense(e)!.description, 'Dinner 2');
    expect(b.state.groups[t.g]!.members[t.sam]!.displayName, sam);
    expect(a.snap.unsharedCounts[t.g] ?? 0, 0);
    // The ops are byte-identical on both phones.
    final mine = {for (final o in a.opsOf(t.g)) o.id: o.toJson()};
    for (final o in b.opsOf(t.g)) {
      expect(jsonEncode(o.toJson()), jsonEncode(mine[o.id]), reason: o.id);
    }
  });

  test('a relayed op of a newer schema with lone surrogates in its payload '
      'and in raw fields outside it does not stop the group syncing', () async {
    // Stored by a pre-R21 build that relayed it from a newer phone.
    final future = Operation.fromJson({
      'id': 'future-1',
      'groupId': t.g,
      'deviceId': 'device-z',
      'counter': 1,
      'hlc': Hlc(kQaBaseMs + 500, 0, 'device-z').encode(),
      'entityType': 'receipt',
      'entityId': 'r-1',
      'kind': 'attach',
      'payload': <String, Object?>{'caption': 'x'},
      'schemaVersion': 2,
      'extra': 'top',
    });
    await a.store.insertAll([future]);
    await a.close();
    final db = sqlite3.open(a.path);
    try {
      rewriteJson(db, 'future-1', (j) {
        j['payload'] = <String, Object?>{
          'caption\uDC00': 'a\uD800b',
          'list': ['\uDBFF', 1],
        };
        j['extra'] = 'to\uD800p';
        j['entityType'] = 'rec\uDC00eipt';
      });
    } finally {
      db.close();
    }
    await a.launch();
    a.clock.advance();
    final taxi = await a.ledger.addExpense(
      qaDraft(t.g, [t.me, t.priya], description: 'Taxi', total: 900),
    );
    final b = await TestPhone.create('b', name: 'Priya');
    addTearDown(b.close);
    await b.ledger.registerJoinedGroup(
      t.g,
      (await a.ledger.groupKeys())[t.g]!,
      'Goa trip',
    );
    final r = await sync(a.ledger, b.store);
    // ignore: avoid_print
    print('[r26] newer-schema relay: ${r.$1.outcome}/${r.$1.message} | '
        '${r.$2.outcome}/${r.$2.message}');
    expectCompleted(r);
    expect(b.state.expense(taxi), isNotNull);
    expect(b.opCount(t.g), a.opsOf(t.g).length);
    expect(a.snap.unsharedCounts[t.g] ?? 0, 0);
  });

  test('open stays under 2 s when every one of 20k stored ops needs '
      'cleaning', () async {
    final ops = <Operation>[];
    for (var i = 1; i <= 20000; i++) {
      ops.add(Operation(
        id: 'legacy-$i',
        groupId: t.g,
        deviceId: 'device-y',
        counter: i,
        hlc: Hlc(kQaBaseMs + i, 0, 'device-y'),
        entityType: EntityType.expense,
        entityId: 'x-${i % 2000}',
        kind: OpKind.update,
        payload: {
          ExpenseFields.notes: 'n$i\u0007',
        },
      ));
    }
    for (var i = 0; i < ops.length; i += 1000) {
      await a.store.insertAll(ops.sublist(i, i + 1000));
    }
    await a.close();
    final db = sqlite3.open(a.path);
    try {
      // Every row as a pre-R21 build could hold it: a lone surrogate.
      db.execute(
        "UPDATE ops SET json = replace(json, '\\u0007', '\\ud800') "
        "WHERE op_id LIKE 'legacy-%'",
      );
      expect(db.updatedRows, 20000);
    } finally {
      db.close();
    }
    final sw = Stopwatch()..start();
    await a.launch();
    sw.stop();
    final missing = Stopwatch()..start();
    final offered = await a.ledger.opsMissingFor(t.g, VersionVector.empty);
    missing.stop();
    // ignore: avoid_print
    print('[r26] open with 20k legacy ops: ${sw.elapsedMilliseconds} ms; '
        'opsMissingFor ${offered.length} ops: '
        '${missing.elapsedMilliseconds} ms');
    expect(offered.every((o) => TextRules.remoteProblem(o) == null), isTrue);
    expect(sw.elapsedMilliseconds, lessThan(2000));
  });
}
