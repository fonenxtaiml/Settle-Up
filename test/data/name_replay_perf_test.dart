// Replaying a peer's member and group ops costs about what ordinary ops
// cost whatever names they carry within the remote limits (DATA-R15-01):
// on a relaunch and in applyRemote, for renames of a few members and for
// many members created with names NFKC makes 18 times as long, or of
// combining marks NFKC expands, which no head of a name can be cut before.
import 'dart:isolate';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/core/ops.dart';

import '../qa/data/qa_data_harness.dart';
import '../qa/data/r15_regression_test.dart' show logPhone, peerD, renames;
import '../support/cpu_clock.dart';

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

/// Wraps one timed sample of [alternateSamples]: [run] counts from 0,
/// [heavy] is true for the log under test; it must call [sample] once and
/// return what it measured.
typedef SampleRun<T> = Future<T> Function(
  int run,
  bool heavy,
  Future<T> Function() sample,
);

/// Wraps one timed open of [fasterOpens], as [SampleRun] does.
typedef OpenRun = SampleRun<int>;

/// How many times [fasterOpens] opens each log by default.
const int kOpenRuns = 3;

/// [runs] samples of [ordinary] and of [heavy], taken alternately
/// (ordinary, heavy, ordinary, ...), in the order taken.
///
/// The one way the suite takes the wall-clock samples it bounds
/// (DATA-R18-02, DATA-R32-02): the wall clock counts whatever else the host
/// runs (the other test file `flutter test -j 2` runs beside this one,
/// other work on a shared host), and a burst of that load over one sample
/// alone would decide a bound on a single sample. Alternating spreads the
/// samples of both logs over the same stretch of time, and the fastest of
/// each is the one load slowed least. [around] wraps each sample (for a
/// probe that loads the host over some of them). A bound on an open that
/// must be cold takes each sample in a fresh isolate ([coldSample]).
Future<({List<T> ordinary, List<T> heavy})> alternateSamples<T>(
  Future<T> Function() ordinary,
  Future<T> Function() heavy, {
  int runs = kOpenRuns,
  SampleRun<T>? around,
}) async {
  final wrap = around ?? (_, _, sample) => sample();
  final o = <T>[], h = <T>[];
  for (var k = 0; k < runs; k++) {
    o.add(await wrap(k, false, ordinary));
    h.add(await wrap(k, true, heavy));
  }
  return (ordinary: o, heavy: h);
}

/// The wall-clock ms the log of [ordinary] and that of [heavy] take to
/// open: each opened [runs] times by [alternateSamples], and the fastest
/// run of each taken.
Future<({int ordinaryMs, int heavyMs})> fasterOpens(
  List<Operation> ordinary,
  List<Operation> heavy, {
  bool base = true,
  int runs = kOpenRuns,
  OpenRun? around,
}) async {
  final r = await alternateSamples(
    () => openMs(ordinary, base: base),
    () => openMs(heavy, base: base),
    runs: runs,
    around: around,
  );
  return (ordinaryMs: r.ordinary.reduce(min), heavyMs: r.heavy.reduce(min));
}

/// The fastest of [runs] wall-clock samples of one open, for a bound on
/// that open alone (an absolute budget): [open] takes the run, counting
/// from 0, and returns its ms. One sample would let a burst of host load
/// over it decide the bound, as in [alternateSamples].
Future<int> fastestOpenMs(
  Future<int> Function(int run) open, {
  int runs = kOpenRuns,
}) async {
  var best = 1 << 30;
  for (var k = 0; k < runs; k++) {
    best = min(best, await open(k));
  }
  return best;
}

/// Runs [sample] in a fresh isolate of this isolate group and returns what
/// it measured: for a sample of an open that must be cold, as the first
/// open after a relaunch is. Every static an isolate fills on first use
/// (the tables of NormalForm and NameText among them) starts empty there,
/// whatever this isolate has shown, so such a sample can be repeated and
/// the fastest taken ([alternateSamples]); the compiled code is shared
/// within the group, so it is warm as in a running app.
Future<T> coldSample<T>(Future<T> Function() sample) => Isolate.run(sample);

/// The 20k ops of the base log and 5,000 members created with ordinary
/// names, and with distinct 159 x U+FDFA names: the logs of the creates
/// bound ([expectCreatesWithinBudget]).
({List<Operation> ordinary, List<Operation> heavy}) createsLogs() =>
    (ordinary: creates(5000, (i) => 'Person $i'), heavy: creates(5000, heavy));

/// The bound on the open of [createsLogs]: 0.1 ms an op for what the names
/// add, held on the wall clock with room for the load the suite runs under,
/// scaled by how much slower than on a quiet host the open of ordinary
/// names was ([quietBaseOrdinaryMs]). Both from [fasterOpens].
void expectCreatesWithinBudget(({int ordinaryMs, int heavyMs}) r) {
  final load = max(1.0, r.ordinaryMs / quietBaseOrdinaryMs);
  expect(
    r.heavyMs - r.ordinaryMs,
    lessThan(1000 * load),
    reason: 'ordinary ${r.ordinaryMs} ms, heavy ${r.heavyMs} ms',
  );
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

/// The CPU time this thread has run, in microseconds: what synchronous
/// work costs, whatever else the host runs ([threadCpuMicros]).
int cpuMicros() => threadCpuMicros();

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
/// open of each log, measured by [fasterOpens].
Future<MarkCost> markCost(String piece) => nameCost(markName(piece));

/// What 4,000 members created with [name]s cost against as many with
/// ordinary names, measured as [markCost] measures it.
Future<MarkCost> nameCost(String Function(int) name) async {
  final ordinaryNames = [for (var i = 1; i <= 4000; i++) 'Person $i'];
  final names = [for (var i = 1; i <= 4000; i++) name(i)];
  final r = await fasterOpens(
    creates(4000, (i) => ordinaryNames[i - 1]),
    creates(4000, (i) => names[i - 1]),
    base: false,
  );
  return (
    cpuMs: showCpuMs(names) - showCpuMs(ordinaryNames),
    openMs: r.heavyMs,
    ordinaryMs: r.ordinaryMs,
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

/// A static the [coldSample] test fills in one isolate only.
final List<int> _filledStatic = [];

void main() {
  test('fasterOpens alternates the two logs and takes the fastest run of '
      'each, so a burst of load over any one sample does not decide it '
      '(DATA-R32-02)', () async {
    final rnd = Random(3202);
    for (var trial = 0; trial < 200; trial++) {
      final runs = 1 + rnd.nextInt(4);
      final order = <(int, bool)>[];
      final times = {
        for (var k = 0; k < runs; k++)
          for (final h in [false, true]) (k, h): 100 + rnd.nextInt(2000),
      };
      final r = await fasterOpens(
        const [],
        const [],
        runs: runs,
        // Stands in for the timed open: no log is opened.
        around: (run, heavy, open) async {
          order.add((run, heavy));
          return times[(run, heavy)]!;
        },
      );
      expect(order, [
        for (var k = 0; k < runs; k++) ...[(k, false), (k, true)],
      ]);
      int best(bool h) =>
          [for (var k = 0; k < runs; k++) times[(k, h)]!].reduce(min);
      expect(r.ordinaryMs, best(false));
      expect(r.heavyMs, best(true));
    }
  });

  test('fastestOpenMs takes the fastest of its runs, in order, so a burst '
      'of load over any one sample does not decide a bound on one open '
      '(DATA-R32-02)', () async {
    final rnd = Random(3302);
    for (var trial = 0; trial < 200; trial++) {
      final runs = 1 + rnd.nextInt(4);
      final times = [for (var k = 0; k < runs; k++) 100 + rnd.nextInt(2000)];
      final seen = <int>[];
      final ms = await fastestOpenMs((run) async {
        seen.add(run);
        return times[run];
      }, runs: runs);
      expect(seen, [for (var k = 0; k < runs; k++) k]);
      expect(ms, times.reduce(min));
    }
  });

  test('coldSample runs in a fresh isolate: what this isolate has filled '
      'in (the name tables, any static) starts empty there each time, and '
      'what the sample fills stays there (DATA-R32-02)', () async {
    final fresh = await coldSample(
      () async => (NameText.astralEntries, _filledStatic.length),
    );
    // Fill this isolate's tables and a static of the test.
    for (var r = 0x1D400; r < 0x1D800; r++) {
      NameText.display('a${String.fromCharCode(r)}\u0301');
    }
    _filledStatic.add(1);
    expect(NameText.astralEntries, greaterThan(fresh.$1));
    for (var k = 0; k < 2; k++) {
      final r = await coldSample(() async {
        final before = (NameText.astralEntries, _filledStatic.length);
        _filledStatic.addAll([1, 2, 3]);
        for (var c = 0x1D400; c < 0x1D800; c++) {
          NameText.display('a${String.fromCharCode(c)}\u0301');
        }
        return before;
      });
      expect(r, fresh);
    }
    expect(_filledStatic, [1]);
  });

  test('20k ops + 20,000 renames with distinct 159 x U+FDFA names open '
      'about as fast as with ordinary names', () async {
    // Measured alternately, the fastest run of each taken, so a burst of
    // load on the shared host does not decide it (DATA-R18-02).
    final r = await fasterOpens(
      renames(20000, (i) => 'Person $i'),
      renames(20000, heavy),
    );
    final ordinary = r.ordinaryMs, heavyMs = r.heavyMs;
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
    final logs = createsLogs();
    // Measured alternately, the fastest run of each taken: one sample of
    // each once failed the -j 2 suite on a loaded host, 1282 ms against a
    // bound of 1007 ms, and passes alone at about 200 ms (DATA-R32-02).
    final r = await fasterOpens(logs.ordinary, logs.heavy);
    final cpuMs = showCpuMs(heavyNames) - showCpuMs(ordinaryNames);
    // ignore: avoid_print
    print(
      '[perf] 20k ops + 5k member creates: ordinary ${r.ordinaryMs} ms, '
      'heavy ${r.heavyMs} ms, the names $cpuMs ms of CPU',
    );
    // As for the marks below: what the names add in CPU time, which load
    // does not change, and the open on the wall clock with room for the
    // load the suite runs under (DATA-R18-02).
    expect(cpuMs, lessThan(500)); // 5,000 x 0.1 ms
    expectCreatesWithinBudget(r);
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
