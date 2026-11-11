// Replaying a peer's member and group ops costs about what ordinary ops
// cost whatever names they carry within the remote limits (DATA-R15-01):
// on a relaunch and in applyRemote, for renames of a few members and for
// many members created with names NFKC makes 18 times as long.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/core/ops.dart';

import '../qa/data/qa_data_harness.dart';
import '../qa/data/r15_regression_test.dart' show logPhone, peerD, renames;

/// 159 x U+FDFA after a number: a distinct name per [i] that NFKC makes
/// 2,862 characters long.
String heavy(int i) => '$i${'\uFDFA' * (159 - '$i'.length)}';

/// [n] members of `group-1` created by peer D with [name]s.
List<Operation> creates(int n, String Function(int) name) => [
  for (var i = 1; i <= n; i++)
    Operation(
      id: 'r16-new-$i',
      groupId: 'group-1',
      deviceId: peerD,
      counter: 100000 + i,
      hlc: Hlc(kQaBaseMs + 100000 + i, 0, peerD),
      entityType: EntityType.member,
      entityId: 'r16-m$i',
      kind: OpKind.create,
      payload: {
        MemberFields.displayName: name(i),
        MemberFields.personId: 'r16-p$i',
        MemberFields.createdAt: kQaBaseMs,
      },
    ),
];

Future<int> openMs(List<Operation> extra, {bool base = true}) async {
  final r = await logPhone(extra, base: base);
  await r.phone.close();
  r.phone.dir.deleteSync(recursive: true);
  return r.openMs;
}

void main() {
  test('20k ops + 20,000 renames with distinct 159 x U+FDFA names open '
      'about as fast as with ordinary names', () async {
    final ordinary = await openMs(renames(20000, (i) => 'Person $i'));
    final heavyMs = await openMs(renames(20000, heavy));
    // ignore: avoid_print
    print(
      '[perf] 20k ops + 20k renames: ordinary $ordinary ms, '
      'heavy $heavyMs ms',
    );
    expect(heavyMs, lessThan(ordinary * 1.5 + 200));
    expect(heavyMs, lessThan(4000)); // 40k ops, 0.1 ms an op
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('20k ops + 5,000 members created with distinct 159 x U+FDFA names '
      'open within the budget of 0.1 ms an op', () async {
    final ordinary = await openMs(creates(5000, (i) => 'Person $i'));
    final heavyMs = await openMs(creates(5000, heavy));
    // ignore: avoid_print
    print(
      '[perf] 20k ops + 5k member creates: ordinary $ordinary ms, '
      'heavy $heavyMs ms',
    );
    expect(heavyMs - ordinary, lessThan(500)); // 5,000 x 0.1 ms
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('applyRemote of 1,000 renames with such names takes about as long '
      'as of ordinary ones', () async {
    Future<int> apply(String Function(int) name) async {
      final r = await logPhone(const [], base: false);
      final sw = Stopwatch()..start();
      await r.phone.ledger.applyRemote('group-1', renames(1000, name));
      final ms = sw.elapsedMilliseconds;
      // The last rename of m4 is op 1,000.
      expect(
        r.phone.group('group-1').members['group-1-m4']!.displayName,
        NameText.display(name(1000)),
      );
      await r.phone.close();
      r.phone.dir.deleteSync(recursive: true);
      return ms;
    }

    final ordinary = await apply((i) => 'Person $i');
    final heavyMs = await apply(heavy);
    // ignore: avoid_print
    print(
      '[perf] applyRemote of 1,000 renames: ordinary $ordinary ms, '
      'heavy $heavyMs ms',
    );
    expect(heavyMs, lessThan(ordinary * 1.5 + 100));
  }, timeout: const Timeout(Duration(minutes: 2)));
}
