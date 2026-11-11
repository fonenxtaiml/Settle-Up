// Replaying a peer's member and group ops costs about what ordinary ops
// cost whatever names they carry within the remote limits (DATA-R15-01):
// on a relaunch and in applyRemote, for renames of a few members and for
// many members created with names NFKC makes 18 times as long, or of
// combining marks NFKC expands, which no head of a name can be cut before.
import 'dart:io';
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

/// A name of 160 units: a number, then [piece] repeated.
String Function(int) markName(String piece) => (i) {
  final b = StringBuffer('$i');
  while (b.length + piece.length <= 160) {
    b.write(piece);
  }
  return b.toString();
};

/// Names of combining marks NFKC expands, which no head of a name can be
/// cut before, by class.
const Map<String, String> markClasses = {
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

/// The CPU time this thread has run, in microseconds, from the kernel's
/// scheduler statistics: what synchronous work costs, whatever else the
/// host runs. The wall clock where the kernel does not tell.
int cpuMicros() {
  try {
    final stat = File('/proc/thread-self/schedstat').readAsStringSync();
    return int.parse(stat.split(' ').first) ~/ 1000;
  } on Object {
    return DateTime.now().microsecondsSinceEpoch;
  }
}

/// The CPU time showing [names] as the replay shows a member's name takes,
/// in ms: the fastest of three runs, each synchronous on one thread.
int showCpuMs(List<String> names) {
  var best = 1 << 62;
  for (var k = 0; k < 3; k++) {
    final t = cpuMicros();
    for (final n in names) {
      NameText.display(n, NameText.maxLength);
    }
    best = min(best, cpuMicros() - t);
  }
  return best ~/ 1000;
}

/// What 4,000 members created with names of [piece] cost against as many
/// with ordinary names: the CPU time showing the names takes, and the
/// open of each log, each open measured twice, alternately, and the
/// faster run taken.
Future<MarkCost> markCost(String piece) => nameCost(markName(piece));

/// What 4,000 members created with [name]s cost against as many with
/// ordinary names, measured as [markCost] measures it.
Future<MarkCost> nameCost(String Function(int) name) async {
  final ordinaryNames = [for (var i = 1; i <= 4000; i++) 'Person $i'];
  final names = [for (var i = 1; i <= 4000; i++) name(i)];
  var ordinary = 1 << 30, ms = 1 << 30;
  for (var k = 0; k < 2; k++) {
    ordinary = min(
      ordinary,
      await openMs(creates(4000, (i) => ordinaryNames[i - 1]), base: false),
    );
    ms = min(ms, await openMs(creates(4000, (i) => names[i - 1]), base: false));
  }
  return (
    cpuMs: showCpuMs(names) - showCpuMs(ordinaryNames),
    openMs: ms,
    ordinaryMs: ordinary,
  );
}

typedef MarkCost = ({int cpuMs, int openMs, int ordinaryMs});

/// The ms 4,000 ordinary member creates take to open on a warm host with
/// nothing else running (about 0.01 ms an op).
const int quietOrdinaryMs = 40;

/// The ms the 20k ops of the base log and 5,000 ordinary member creates
/// take to open on a warm host with nothing else running.
const int quietBaseOrdinaryMs = 700;

/// The charter: 0.1 ms an op in all; ordinary ops take about 0.01 ms of it
/// on a warm host, so such a name may add 0.075 ms: 300 ms for 4,000.
///
/// What the names add is measured in CPU time, which the load the suite
/// runs under (two test files at a time with -j 2, other work on a shared
/// host) does not change, so the bound keeps its strength there
/// (DATA-R18-02). The open of the log is measured on the wall clock,
/// which that load slows by as much again or more: it is held to twice
/// the budget, scaled by how much slower than on a quiet host the open of
/// ordinary names was, measured beside it.
void expectWithinMarkBudget(MarkCost r) {
  expect(r.cpuMs, lessThan(300)); // 4,000 x 0.075 ms
  final load = max(1.0, r.ordinaryMs / quietOrdinaryMs);
  expect(r.openMs - r.ordinaryMs, lessThan(600 * load));
}

void main() {
  test('20k ops + 20,000 renames with distinct 159 x U+FDFA names open '
      'about as fast as with ordinary names', () async {
    // Each measured twice, alternately, and the faster run taken, so a
    // burst of load on the shared host does not decide it (DATA-R18-02).
    var ordinary = 1 << 30, heavyMs = 1 << 30;
    for (var k = 0; k < 2; k++) {
      ordinary = min(
        ordinary,
        await openMs(renames(20000, (i) => 'Person $i')),
      );
      heavyMs = min(heavyMs, await openMs(renames(20000, heavy)));
    }
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
    final ordinaryNames = [for (var i = 1; i <= 5000; i++) 'Person $i'];
    final heavyNames = [for (var i = 1; i <= 5000; i++) heavy(i)];
    final ordinary = await openMs(creates(5000, (i) => ordinaryNames[i - 1]));
    final heavyMs = await openMs(creates(5000, (i) => heavyNames[i - 1]));
    final cpuMs = showCpuMs(heavyNames) - showCpuMs(ordinaryNames);
    // ignore: avoid_print
    print(
      '[perf] 20k ops + 5k member creates: ordinary $ordinary ms, '
      'heavy $heavyMs ms, the names $cpuMs ms of CPU',
    );
    // As for the marks below: what the names add in CPU time, which load
    // does not change, and the open on the wall clock with room for the
    // load the suite runs under (DATA-R18-02).
    expect(cpuMs, lessThan(500)); // 5,000 x 0.1 ms
    final load = max(1.0, ordinary / quietBaseOrdinaryMs);
    expect(heavyMs - ordinary, lessThan(1000 * load));
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

    // Each measured twice, alternately, and the faster run taken; and what
    // the names add in CPU time, which load does not change, as for the
    // opens above (DATA-R18-02): the -j 2 suite on the shared host once
    // made one heavy run 232 ms against 88.
    var ordinary = 1 << 30, heavyMs = 1 << 30;
    for (var k = 0; k < 2; k++) {
      ordinary = min(ordinary, await apply((i) => 'Person $i'));
      heavyMs = min(heavyMs, await apply(heavy));
    }
    final cpuMs =
        showCpuMs([for (var i = 1; i <= 1000; i++) heavy(i)]) -
        showCpuMs([for (var i = 1; i <= 1000; i++) 'Person $i']);
    // ignore: avoid_print
    print(
      '[perf] applyRemote of 1,000 renames: ordinary $ordinary ms, '
      'heavy $heavyMs ms, the names $cpuMs ms of CPU',
    );
    expect(cpuMs, lessThan(50)); // 1,000 x 0.05 ms
    expect(heavyMs, lessThan(ordinary * 1.5 + 100));
  }, timeout: const Timeout(Duration(minutes: 2)));

  group('4,000 members created with names of combining marks NFKC expands '
      'open within the budget of 0.1 ms an op', () {
    markClasses.forEach((label, piece) {
      test(label, () async {
        final r = await markCost(piece);
        // ignore: avoid_print
        print('[perf] 4k members, $label: $r');
        expectWithinMarkBudget(r);
      }, timeout: const Timeout(Duration(minutes: 2)));
    });
  });
}
