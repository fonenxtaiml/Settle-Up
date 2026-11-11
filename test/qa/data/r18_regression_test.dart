// QA DATA-R18: open findings from the reverification of DATA-R15-01.
//
// Tests named "QA <id>" with `skip:` are failing repros for open findings;
// they pass once the finding is fixed.
import 'dart:io';
import 'dart:isolate';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/name_text.dart';
import 'package:settle_up/core/normal_form.dart';

import '../../data/name_replay_perf_test.dart' show creates, openMs;
import 'r15_regression_test.dart' show logPhone;
import 'r17_regression_test.dart' show memberCreates;

/// A member name of 80 astral code points (160 units, the remote limit of
/// a member name): the [i]th run of 80 of the 1,048,576 astral code points.
String astralName(int i) {
  final b = StringBuffer();
  for (var k = 0; k < 80; k++) {
    final r = 0x10000 + (i * 80 + k) % 0x100000;
    // Noncharacters (U+xFFFE, U+xFFFF) are code points like any other here.
    b.writeCharCode(r);
  }
  return b.toString();
}

/// A member name of the same shape as [astralName] (80 code points outside
/// the BMP, 160 units) drawn from the first 256 of them only: names as long
/// and as costly to store, decode and normalise, that touch few entries of
/// any per-code-point table.
String fewAstralName(int i) {
  final b = StringBuffer();
  for (var k = 0; k < 80; k++) {
    b.writeCharCode(0x10000 + (i * 80 + k) % 256);
  }
  return b.toString();
}

void main() {
  test('QA DATA-R18-01: peer member names holding distinct astral code points '
      'grow the normaliser caches without bound (~130 MiB) and open 13k ops '
      'in ~4 s, on every launch', () async {
    const n = 0x100000 ~/ 80; // 13,107 ops cover every astral code point
    // What showing the names keeps, measured before anything has shown
    // them: the per-code-point tables would keep it for the whole process.
    // Against as many names of the same length and kind first (twice, so
    // the code is warm), so the growth is the tables, not the names.
    // (RSS across a whole open, against 'Person $i' names, measured the
    // log and the size of the names too: 13k names of 160 ASCII letters,
    // which no table is kept for, grew it by about 60 MiB more, and it
    // moved by tens of MiB from run to run with the heap.)
    int grows(String Function(int) name) {
      final names = [for (var i = 1; i <= n; i++) name(i)];
      final before = ProcessInfo.currentRss;
      for (final raw in names) {
        NameText.display(raw);
        NameText.key(raw);
      }
      return ProcessInfo.currentRss - before;
    }

    grows(fewAstralName);
    final ordinaryGrowth = grows(fewAstralName);
    final tables = NormalForm.astralEntries;
    final growth = grows(astralName);

    final r = await logPhone(memberCreates(n, astralName), base: false);
    final members = r.phone.group('group-1').members;
    final accepted = members.keys.where((m) => m.startsWith('r17-m')).length;
    await r.phone.close();
    r.phone.dir.deleteSync(recursive: true);
    // ignore: avoid_print
    print(
      '[mem] $n peer member names: of 256 code points grow RSS by '
      '${ordinaryGrowth >> 20} MiB, of all astral ones by ${growth >> 20} '
      'MiB (open ${r.openMs} ms; $accepted members shown)',
    );
    expect(accepted, n); // the ops are within the remote limits
    // The normaliser's per-code-point tables should be bounded, like
    // NameText's marks cache (4,096 entries).
    expect(growth - ordinaryGrowth, lessThan(32 << 20));
    // They hold the code points that have properties, read once, and the
    // few that decompose: not every code point a name holds.
    expect(NormalForm.astralEntries, tables);
    var decompose = 0;
    for (var c = 0x10000; c <= 0x10FFFF; c++) {
      if (NormalForm.decomposes(c)) decompose++;
    }
    expect(NameText.astralEntries, lessThanOrEqualTo(2 * decompose));
    // The charter: 20k ops open in < 2 s on the host whatever names they
    // carry within the remote limits; these are 13k.
    expect(r.openMs, lessThan(2000));
  }, timeout: const Timeout(Duration(minutes: 5)));

  test(
    'QA DATA-R18-02: the DATA-R15-01 perf tests fail under the load of the '
    'full suite (-j 2): 4k members with marks after spaces or split by soft '
    'hyphens add 320-370 ms against a bound of 300',
    () async {
      // Four busy isolates stand in for the other test process the full
      // suite runs beside this one with -j 2, and the other work on the
      // shared 4-CPU host.
      final stops = <Isolate>[
        for (var k = 0; k < 4; k++)
          await Isolate.spawn((_) {
            var x = 0;
            while (true) {
              x = (x * 31 + 7) & 0xFFFFFF;
            }
          }, null),
      ];
      String Function(int) of(String piece) => (i) {
        final b = StringBuffer('$i');
        while (b.length + piece.length <= 160) {
          b.write(piece);
        }
        return b.toString();
      };
      final rows = <String>[];
      var worst = 0;
      try {
        for (final piece in ['ཷ ', 'ཷ­']) {
          var ordinary = 1 << 30, ms = 1 << 30;
          for (var k = 0; k < 2; k++) {
            ordinary = min(
              ordinary,
              await openMs(creates(4000, (i) => 'Person $i'), base: false),
            );
            ms = min(ms, await openMs(creates(4000, of(piece)), base: false));
          }
          rows.add(
            '${piece.codeUnits.last.toRadixString(16)}: '
            '${ms - ordinary} ms',
          );
          worst = max(worst, ms - ordinary);
        }
      } finally {
        for (final i in stops) {
          i.kill(priority: Isolate.immediate);
        }
      }
      // ignore: avoid_print
      print('[perf] under load, added by 4k mark-heavy members: $rows');
      // The bound name_replay_perf_test.dart asserts; the suite must stay
      // green on the shared host it runs on.
      expect(worst, lessThan(300));
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip:
        'QA DATA-R18-02: the DATA-R15-01 perf tests fail under the load of '
        'the full suite',
  );
}
