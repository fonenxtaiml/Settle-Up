// Replaying a peer's member and group ops costs about what ordinary ops
// cost whatever names they carry within the remote limits (DATA-R15-01):
// on a relaunch and in applyRemote, for renames of a few members and for
// many members created with names NFKC makes 18 times as long, or of
// combining marks NFKC expands, which no head of a name can be cut before.
import 'dart:math';

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

  group('4,000 members created with names of combining marks NFKC expands '
      'open within the budget of 0.1 ms an op', () {
    /// A name of 160 units: a number, then [piece] repeated.
    String Function(int) of(String piece) => (i) {
      final b = StringBuffer('$i');
      while (b.length + piece.length <= 160) {
        b.write(piece);
      }
      return b.toString();
    };

    final classes = <String, String>{
      'U+0344 (two marks each)': '\u0344',
      'U+0F73 (a starter, two marks)': '\u0F73',
      'U+0F75 (a starter, two marks)': '\u0F75',
      'U+0F77 (three marks)': '\u0F77',
      'U+0F79 (three marks)': '\u0F79',
      'halfwidth voiced marks': '\uFF9E\uFF9F',
      'marks of falling classes': '\u0345\u0301\u0316\u0334',
      'supplementary marks': '\u{1D165}\u{1D16E}',
      'marks split by soft hyphens': '\u0F77\u00AD',
      'marks split by zero-width spaces': '\u0344\u200B',
      'marks after spaces': '\u0F77 ',
      'letters with marks between': 'e\u0F77\u0301',
    };
    classes.forEach((label, piece) {
      test(label, () async {
        // Each measured twice, alternately, and the faster run taken, so
        // a burst of load on a shared machine does not decide it.
        var ordinary = 1 << 30, ms = 1 << 30;
        for (var k = 0; k < 2; k++) {
          ordinary = min(
            ordinary,
            await openMs(creates(4000, (i) => 'Person $i'), base: false),
          );
          ms = min(ms, await openMs(creates(4000, of(piece)), base: false));
        }
        // ignore: avoid_print
        print('[perf] 4k members, $label: $ms ms (ordinary $ordinary ms)');
        // The charter: 0.1 ms an op in all; ordinary ops take about 0.01 ms
        // of it on a warm host, so such a name may add 0.075 ms.
        expect(ms - ordinary, lessThan(300)); // 4,000 x 0.075 ms
      }, timeout: const Timeout(Duration(minutes: 2)));
    });
  });
}
