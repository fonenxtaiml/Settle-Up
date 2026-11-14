// QA MONEY round 41: reverification of MONEY-R39-01 (an edit saved after
// this phone's date ran more than 7 days ahead was lost when a peer had
// edited on top of the far-ahead stamp) through the real
// Ledger(MemoryOpStore) and the Riverpod providers.
//
// The fix (lib/data/op_factory.dart _stamp/_pastHeld) follows any stored
// floor more than 7 days ahead of the wall clock, whoever wrote it. The
// defect class is "a local write to an entity whose newest op is a
// peer-adopted far-ahead stamp loses last-writer-wins", so every command
// that writes an existing entity is re-run here on such a floor: expense
// money/description edit, delete, restore, payment update, member rename,
// remove and merge, group simplify toggle and currency. Plus a three-phone
// relay chain (the far-ahead stamp adopted twice), and a seeded fuzz over
// three phones whose wall clocks jump by up to 12 days, beyond the 7-day
// adopt window the round 39 fuzz stayed within.
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/data/ledger.dart';
import 'package:settle_up/data/memory_group_key_store.dart';
import 'package:settle_up/data/repositories.dart';
import 'package:settle_up/ui/format/face_value.dart';

import 'money_harness.dart';

const int _day = 24 * 60 * 60 * 1000;
const int _ahead = 15 * _day ~/ 2; // 7.5 days

final class _World {
  _World(this.alex, this.sam, this.g, this.m, this.e, this.pay);
  final QaPhone alex;
  final QaPhone sam;
  final GroupId g;
  final Map<String, MemberId> m;
  final ExpenseId e;
  final ExpenseId pay;
  MemberId get me => m['me']!;
  MemberId get s => m['Sam']!;
  MemberId get p => m['Priya']!;
}

Future<_World> _world() async {
  final alex = await QaPhone.create(name: 'Alex', prefix: 'aaaaaaaa');
  final sam = await QaPhone.create(name: 'Sam', prefix: 'bbbbbbbb');
  addTearDown(() async {
    await alex.dispose();
    await sam.dispose();
  });
  final t = await alex.group(['Sam', 'Priya']);
  await shareGroup(alex, sam, t.g);
  final me = t.m['me']!;
  final e = await alex.add(
    t.g,
    total: 30000,
    paidBy: one(me, 30000),
    owedBy: eq(t.m.values),
  );
  final pay = await alex.pay(t.g, from: t.m['Sam']!, to: me, amount: 1000);
  await syncBoth(alex, sam, t.g);
  return _World(alex, sam, t.g, t.m, e, pay);
}

/// Alex's date runs 7.5 days ahead and he writes [first]; Sam (1 day ahead)
/// accepts it and writes [second] on top, adopting Alex's stamp; Alex sets
/// his date back to real time and writes [third], which must show at once
/// on Alex and on Sam after a sync.
Future<void> _story(
  _World w, {
  required Future<void> Function() first,
  required Future<void> Function() second,
  required Future<void> Function() third,
  required void Function(QaPhone phone, String who) shows,
}) async {
  w.alex.tick(_ahead);
  w.sam.tick(_day);
  await first();
  await pumpEventQueue();
  await syncBoth(w.alex, w.sam, w.g);
  w.sam.tick(1000);
  await second();
  await pumpEventQueue();
  await syncBoth(w.alex, w.sam, w.g);
  w.alex.tick(-_ahead);
  await third();
  await pumpEventQueue();
  shows(w.alex, 'Alex at once');
  expectMoneyInvariants(w.alex, reason: 'Alex after set-back write');
  await syncBoth(w.alex, w.sam, w.g);
  shows(w.sam, 'Sam after sync');
  expect(w.sam.state.toCanonicalJson(), w.alex.state.toCanonicalJson());
  expect(w.sam.nets(w.g), w.alex.nets(w.g));
  expectMoneyInvariants(w.sam, reason: 'Sam after sync');
}

void main() {
  group('R41 MONEY-R39-01 class: every write on a peer-adopted far-ahead '
      'floor', () {
    test('expense money edit (payer, split and currency change)', () async {
      final w = await _world();
      await _story(
        w,
        first: () => w.alex.ledger.updateExpense(
          w.e,
          _draft(w.g, 'a', 40000, one(w.me, 40000), eq([w.me, w.s])),
        ),
        second: () => w.sam.ledger.updateExpense(
          w.e,
          _draft(w.g, 'b', 50000, one(w.s, 50000), eq([w.me, w.s, w.p])),
        ),
        third: () => w.alex.ledger.updateExpense(
          w.e,
          _draft(
            w.g,
            'c',
            999,
            one(w.p, 999),
            eq([w.me, w.s]),
            currency: 'KWD',
          ),
        ),
        shows: (ph, who) {
          final x = ph.state.expense(w.e)!;
          expect(x.description, 'c', reason: who);
          expect(x.money.currency, 'KWD', reason: who);
          expect(x.money.owed, {w.me: 500, w.s: 499}, reason: who);
          expect(ph.nets(w.g)['KWD'], {
            w.p: 999,
            w.me: -500,
            w.s: -499,
          }, reason: who);
        },
      );
    });

    test('description-only edit after a peer money edit', () async {
      final w = await _world();
      await _story(
        w,
        first: () => w.alex.ledger.updateExpense(
          w.e,
          _draft(w.g, 'a', 40000, one(w.me, 40000), eq([w.me, w.s])),
        ),
        second: () => w.sam.ledger.updateExpense(
          w.e,
          _draft(w.g, 'b', 40000, one(w.me, 40000), eq([w.me, w.s])),
        ),
        third: () => w.alex.ledger.updateExpense(
          w.e,
          _draft(w.g, 'c', 40000, one(w.me, 40000), eq([w.me, w.s])),
        ),
        shows: (ph, who) =>
            expect(ph.state.expense(w.e)!.description, 'c', reason: who),
      );
    });

    test('delete after a peer edit', () async {
      final w = await _world();
      await _story(
        w,
        first: () => w.alex.ledger.updateExpense(
          w.e,
          _draft(w.g, 'a', 40000, one(w.me, 40000), eq([w.me, w.s])),
        ),
        second: () => w.sam.ledger.updateExpense(
          w.e,
          _draft(w.g, 'b', 50000, one(w.me, 50000), eq([w.me, w.s])),
        ),
        third: () => w.alex.ledger.deleteExpense(w.e),
        shows: (ph, who) {
          expect(ph.state.expense(w.e)!.isDeleted, isTrue, reason: who);
          // Only the 10.00 payment is left: Sam paid Alex.
          expect(ph.nets(w.g), {
            'INR': {w.s: 1000, w.me: -1000},
          }, reason: who);
        },
      );
    });

    test('restore after a peer delete brings back the latest edit', () async {
      final w = await _world();
      await _story(
        w,
        first: () => w.alex.ledger.updateExpense(
          w.e,
          _draft(w.g, 'a', 40000, one(w.me, 40000), eq([w.me, w.s])),
        ),
        second: () => w.sam.ledger.deleteExpense(w.e),
        third: () => w.alex.ledger.restoreExpense(w.e),
        shows: (ph, who) {
          final x = ph.state.expense(w.e)!;
          expect(x.isDeleted, isFalse, reason: who);
          expect(x.money.total, 40000, reason: who);
        },
      );
    });

    test(
      'edit after a peer delete then restore (7.2: edit vs delete)',
      () async {
        final w = await _world();
        await _story(
          w,
          first: () => w.alex.ledger.deleteExpense(w.e),
          second: () => w.sam.ledger.restoreExpense(w.e),
          third: () => w.alex.ledger.updateExpense(
            w.e,
            _draft(w.g, 'c', 777, one(w.s, 777), eq([w.me, w.p])),
          ),
          shows: (ph, who) {
            final x = ph.state.expense(w.e)!;
            expect(x.isDeleted, isFalse, reason: who);
            expect(x.money.owed, {w.me: 389, w.p: 388}, reason: who);
          },
        );
      },
    );

    test('updatePayment (direction flips) after a peer payment edit', () async {
      final w = await _world();
      await _story(
        w,
        first: () =>
            w.alex.ledger.updatePayment(w.pay, _payment(w.g, w.s, w.me, 2000)),
        second: () =>
            w.sam.ledger.updatePayment(w.pay, _payment(w.g, w.s, w.me, 3000)),
        third: () => w.alex.ledger.updatePayment(
          w.pay,
          _payment(w.g, w.me, w.p, 123, currency: 'JPY'),
        ),
        shows: (ph, who) {
          final m = ph.state.expense(w.pay)!.money;
          expect(
            [m.total, m.currency, m.paid, m.owed],
            [
              123,
              'JPY',
              {w.me: 123},
              {w.p: 123},
            ],
            reason: who,
          );
          expect(ph.nets(w.g)['JPY'], {w.me: 123, w.p: -123}, reason: who);
        },
      );
    });

    test('member rename, then remove keeps the balance', () async {
      final w = await _world();
      await _story(
        w,
        first: () => w.alex.ledger.renameMember(w.g, w.p, 'Priya A'),
        second: () => w.sam.ledger.renameMember(w.g, w.p, 'Priya S'),
        third: () => w.alex.ledger.removeMember(w.g, w.p),
        shows: (ph, who) {
          expect(
            ph.state.groups[w.g]!.members[w.p]!.isRemoved,
            isTrue,
            reason: who,
          );
          // Priya still owes her 100.00 share.
          expect(ph.nets(w.g)['INR']![w.p], -10000, reason: who);
        },
      );
    });

    test('merge members after a peer rename moves the balance', () async {
      final w = await _world();
      await _story(
        w,
        first: () => w.alex.ledger.renameMember(w.g, w.p, 'Priya A'),
        second: () => w.sam.ledger.renameMember(w.g, w.p, 'Priya S'),
        third: () => w.alex.ledger.mergeMembers(w.g, from: w.p, into: w.s),
        shows: (ph, who) {
          final nets = ph.nets(w.g)['INR']!;
          expect(nets.containsKey(w.p), isFalse, reason: who);
          // Sam: -100.00 share, -100.00 Priya's share, +10.00 paid.
          expect(nets[w.s], -19000, reason: who);
        },
      );
    });

    test(
      'group simplify toggle and currency after a peer group edit',
      () async {
        final w = await _world();
        final before = w.alex.nets(w.g);
        await _story(
          w,
          first: () =>
              w.alex.ledger.updateGroup(w.g, const GroupPatch(name: 'Trip A')),
          second: () => w.sam.ledger.updateGroup(
            w.g,
            const GroupPatch(simplifyDebts: true, currency: 'USD'),
          ),
          third: () => w.alex.ledger.updateGroup(
            w.g,
            const GroupPatch(simplifyDebts: false, currency: 'JPY'),
          ),
          shows: (ph, who) {
            final grp = ph.state.groups[w.g]!.group!;
            expect(grp.simplifyDebts, isFalse, reason: who);
            expect(grp.currency, 'JPY', reason: who);
            expect(ph.nets(w.g), before, reason: '$who nets unchanged');
          },
        );
      },
    );
  });

  test('R41 three-phone relay: the far-ahead stamp adopted twice, every '
      'causally later write wins', () async {
    final a = await QaPhone.create(name: 'Alex', prefix: 'aaaaaaaa');
    final s = await QaPhone.create(name: 'Sam', prefix: 'bbbbbbbb');
    final p = await QaPhone.create(name: 'Priya', prefix: 'cccccccc');
    addTearDown(() async {
      await a.dispose();
      await s.dispose();
      await p.dispose();
    });
    final t = await a.group(['Sam', 'Priya']);
    final g = t.g;
    await shareGroup(a, s, g);
    await shareGroup(a, p, g);
    final me = t.m['me']!;
    final e = await a.add(
      g,
      total: 900,
      paidBy: one(me, 900),
      owedBy: eq(t.m.values),
    );
    await syncBoth(a, s, g);
    await syncBoth(a, p, g);

    a.tick(_ahead);
    s.tick(_day);
    p.tick(2 * _day);
    Future<void> edit(QaPhone ph, String d, int total) async {
      await ph.ledger.updateExpense(
        e,
        _draft(g, d, total, one(me, total), eq(t.m.values)),
      );
      await pumpEventQueue();
      expect(ph.state.expense(e)!.description, d, reason: 'shows $d');
    }

    await edit(a, 'a1', 1200);
    await syncBoth(a, s, g);
    s.tick(1000);
    await edit(s, 's1', 1500);
    await syncBoth(s, p, g); // Priya holds Alex's and Sam's far-ahead ops
    p.tick(1000);
    await edit(p, 'p1', 1800);
    // Every phone sets its date back to real time, then edits in turn,
    // syncing each edit on before the next.
    a.tick(-_ahead);
    s.tick(-_day);
    p.tick(-2 * _day);
    await syncBoth(p, a, g);
    await edit(a, 'a2', 2100);
    // Peers at real time hold Alex's op (7.5 days ahead) back until their
    // dates reach it; move everyone a day on, as real time would.
    for (final ph in [a, s, p]) {
      ph.tick(_day);
    }
    await syncBoth(a, s, g);
    await edit(s, 's2', 2400);
    await syncBoth(s, p, g);
    await edit(p, 'p2', 2700);
    await syncBoth(p, a, g);
    await syncBoth(a, s, g);
    for (final ph in [a, s, p]) {
      expect(ph.state.expense(e)!.description, 'p2');
      expect(ph.state.expense(e)!.money.total, 2700);
      expectMoneyInvariants(ph);
    }
  });

  test('R41 after the app restarts, writes still win on the far-ahead '
      'entity and other entities are stamped near real time', () async {
    final w = await _world();
    final f = await w.alex.add(
      w.g,
      total: 600,
      paidBy: one(w.s, 600),
      owedBy: eq([w.me, w.s]),
    );
    await syncBoth(w.alex, w.sam, w.g);
    await _story(
      w,
      first: () => w.alex.ledger.updateExpense(
        w.e,
        _draft(w.g, 'a', 40000, one(w.me, 40000), eq([w.me, w.s])),
      ),
      second: () => w.sam.ledger.updateExpense(
        w.e,
        _draft(w.g, 'b', 50000, one(w.me, 50000), eq([w.me, w.s])),
      ),
      third: () => w.alex.ledger.updateExpense(
        w.e,
        _draft(w.g, 'c', 60000, one(w.me, 60000), eq([w.me, w.s])),
      ),
      shows: (ph, who) =>
          expect(ph.state.expense(w.e)!.description, 'c', reason: who),
    );
    // Restart Alex's app: same store and settings, clock restored from them.
    final keys = MemoryGroupKeyStore();
    for (final k in (await w.alex.ledger.groupKeys()).entries) {
      await keys.put(k.key, k.value);
    }
    var now = kBaseMs + 10 * 1000 * 1000;
    final ledger = await Ledger.open(
      store: w.alex.store,
      keys: keys,
      settings: w.alex.settings,
      ids: w.alex.ids,
      nowMillis: () => now,
    );
    addTearDown(ledger.close);
    now += 1000;
    await ledger.updateExpense(
      f,
      _draft(w.g, 'f2', 800, one(w.s, 800), eq([w.me, w.s])),
    );
    now += 1000;
    await ledger.updateExpense(
      w.e,
      _draft(w.g, 'd', 70000, one(w.p, 70000), eq([w.me, w.s])),
    );
    await pumpEventQueue();
    expect(ledger.current.state.expense(w.e)!.description, 'd');
    expect(ledger.current.state.expense(f)!.description, 'f2');
    final ops = await w.alex.store.loadAll();
    final mine = ops.where((o) => o.deviceId == w.alex.ledger.localDeviceId);
    final fOp = mine
        .where((o) => o.entityId == f)
        .reduce((a, b) => a.hlc > b.hlc ? a : b);
    // F was never far ahead: its edit is not held back by peers.
    expect(fOp.hlc.millis, lessThanOrEqualTo(now + _day));
    final stamps = ops.map((o) => o.hlc).toList();
    expect(stamps.toSet().length, stamps.length, reason: 'stamps unique');
  });

  test('R41 sameFaceValue (currency change on Add expense) keeps the face '
      'value exactly or gives null, never past maxMinor', () {
    final r = Random(41);
    final cs = [
      for (final c in ['INR', 'JPY', 'KWD']) Currencies.of(c),
    ];
    BigInt pow10(int n) => BigInt.from(10).pow(n);
    final samples = [
      0,
      1,
      9,
      10,
      999,
      1000,
      Money.maxMinor,
      Money.maxMinor ~/ 1000,
      Money.maxMinor ~/ 1000 + 1,
      Money.maxMinor ~/ 100 * 100,
      for (var i = 0; i < 400; i++) r.nextInt(1 << 32) * r.nextInt(30) + 1,
    ];
    for (final from in cs) {
      for (final to in cs) {
        for (final m in samples) {
          if (m > Money.maxMinor) continue;
          final v = sameFaceValue(m, from, to);
          final exact = BigInt.from(m) * pow10(to.minorDigits);
          final ok =
              exact % pow10(from.minorDigits) == BigInt.zero &&
              exact ~/ pow10(from.minorDigits) <= BigInt.from(Money.maxMinor);
          final why = '$m ${from.code}->${to.code}';
          if (!ok) {
            expect(v, isNull, reason: why);
            continue;
          }
          expect(BigInt.from(v!) * pow10(from.minorDigits), exact, reason: why);
          expect(sameFaceValue(-m, from, to), -v, reason: 'negative $why');
        }
      }
    }
  });

  group('R41 fuzz: three phones, wall clocks jumping up to 12 days', () {
    for (final seed in [4101, 4102, 4103, 4104, 4105, 4106, 4107, 4108]) {
      test('seed $seed', () => _fuzz(seed));
    }
  });
}

const _currencies = ['INR', 'JPY', 'KWD', 'USD'];
const _offsets = [
  0,
  0,
  -2 * _day,
  -_day,
  _day,
  3 * _day,
  6 * _day,
  15 * _day ~/ 2,
  9 * _day,
  12 * _day,
];

Future<void> _fuzz(int seed) async {
  final r = Random(seed);
  final phones = [
    await QaPhone.create(name: 'Alex', prefix: 'aaaaaaaa'),
    await QaPhone.create(name: 'Sam', prefix: 'bbbbbbbb'),
    await QaPhone.create(name: 'Priya', prefix: 'cccccccc'),
  ];
  addTearDown(() async {
    for (final ph in phones) {
      await ph.dispose();
    }
  });
  final t = await phones[0].group(['Sam', 'Priya', 'Dev']);
  final g = t.g;
  for (final ph in phones.skip(1)) {
    await shareGroup(phones[0], ph, g);
    await syncBoth(phones[0], ph, g);
  }
  final ms = t.m.values.toList()..sort();
  final expenses = <ExpenseId>[];
  final payments = <ExpenseId>[];
  final offset = {for (final ph in phones) ph: 0};
  final clock = {for (final ph in phones) ph: kBaseMs};
  void setClock(QaPhone ph, int to) {
    ph.tick(to - clock[ph]!);
    clock[ph] = to;
  }

  var real = 0;
  var commands = 0;
  for (var step = 0; step < 120; step++) {
    final ph = phones[r.nextInt(phones.length)];
    real += 1 + r.nextInt(3600000);
    if (r.nextInt(5) == 0) {
      offset[ph] = _offsets[r.nextInt(_offsets.length)];
    }
    setClock(ph, kBaseMs + real + offset[ph]!);
    final cur = _currencies[r.nextInt(_currencies.length)];
    final total = 1 + r.nextInt(r.nextBool() ? 10 : 500000);
    ExpenseDraft draft() {
      final who = (ms.toList()..shuffle(r))
          .take(1 + r.nextInt(ms.length))
          .toList();
      return _draft(
        g,
        'E$step',
        total,
        SplitSpec.single(ms[r.nextInt(ms.length)], total),
        SplitSpec.equal(who),
        currency: cur,
      );
    }

    final why = 'seed $seed step $step';
    var what = '';
    try {
      switch (r.nextInt(11)) {
        case 0 || 1:
          what = 'add';
          final d = draft();
          final id = await ph.ledger.addExpense(d);
          expenses.add(id);
          await pumpEventQueue();
          _expectShows(ph, id, d, '$why $what');
        case 2 || 3 || 4 when expenses.isNotEmpty:
          what = 'edit';
          final id = expenses[r.nextInt(expenses.length)];
          if (ph.state.expense(id) == null) break;
          final d = draft();
          await ph.ledger.updateExpense(id, d);
          await pumpEventQueue();
          _expectShows(ph, id, d, '$why $what');
        case 5 when expenses.isNotEmpty:
          what = 'delete';
          final id = expenses[r.nextInt(expenses.length)];
          if (ph.state.expense(id) == null) break;
          await ph.ledger.deleteExpense(id);
          await pumpEventQueue();
          expect(ph.state.expense(id)!.isDeleted, isTrue, reason: '$why $what');
        case 6 when expenses.isNotEmpty:
          what = 'restore';
          final id = expenses[r.nextInt(expenses.length)];
          if (ph.state.expense(id) == null) break;
          await ph.ledger.restoreExpense(id);
          await pumpEventQueue();
          expect(
            ph.state.expense(id)!.isDeleted,
            isFalse,
            reason: '$why $what',
          );
        case 7:
          what = 'pay';
          final from = ms[r.nextInt(ms.length)];
          final to = ms.firstWhere((m) => m != from);
          payments.add(
            await ph.ledger.recordPayment(
              _payment(g, from, to, total, currency: cur),
            ),
          );
        case 8 when payments.isNotEmpty:
          what = 'updatePayment';
          final id = payments[r.nextInt(payments.length)];
          if (ph.state.expense(id) == null) break;
          final a = ms[r.nextInt(ms.length)];
          final b = ms[(ms.indexOf(a) + 1) % ms.length];
          await ph.ledger.updatePayment(
            id,
            _payment(g, a, b, total, currency: cur),
          );
          await pumpEventQueue();
          final m = ph.state.expense(id)!.money;
          expect(
            [m.total, m.currency, m.paid, m.owed],
            [
              total,
              cur,
              {a: total},
              {b: total},
            ],
            reason: '$why $what',
          );
        case 9:
          what = 'simplify';
          final want = !ph.state.groups[g]!.group!.simplifyDebts;
          await ph.ledger.updateGroup(g, GroupPatch(simplifyDebts: want));
          await pumpEventQueue();
          expect(
            ph.state.groups[g]!.group!.simplifyDebts,
            want,
            reason: '$why $what',
          );
        default:
          what = 'sync';
          final other = phones.where((x) => x != ph).toList()[r.nextInt(2)];
          // A peer's clock is not moved by syncing; set it to its own.
          setClock(other, kBaseMs + real + offset[other]!);
          await syncBoth(ph, other, g);
      }
      commands++;
    } on LedgerException {
      // Random input may be refused; refusing is fine.
    }
    await pumpEventQueue();
    expectMoneyInvariants(ph, reason: '$why $what');
  }
  // Clocks agree again, past every stamp written ahead.
  real += 14 * _day;
  for (final ph in phones) {
    setClock(ph, kBaseMs + real);
  }
  for (var i = 0; i < 2; i++) {
    await syncBoth(phones[0], phones[1], g);
    await syncBoth(phones[1], phones[2], g);
    await syncBoth(phones[0], phones[2], g);
  }
  for (final ph in phones.skip(1)) {
    expect(ph.state.toCanonicalJson(), phones[0].state.toCanonicalJson());
    expect(ph.nets(g), phones[0].nets(g));
    expect(ph.transfers(g), phones[0].transfers(g));
  }
  for (final ph in phones) {
    expectMoneyInvariants(ph, reason: 'final');
    final stamps = [for (final o in await ph.store.loadAll()) o.hlc];
    expect(stamps.toSet().length, stamps.length, reason: 'stamps unique');
  }
  expect(commands, greaterThan(60));
}

void _expectShows(QaPhone p, ExpenseId id, ExpenseDraft d, String what) {
  final e = p.state.expense(id)!;
  expect(e.description, d.description, reason: '$what shows description');
  expect(e.money.total, d.total, reason: '$what shows total');
  expect(e.money.currency, d.currency, reason: '$what shows currency');
}

ExpenseDraft _draft(
  GroupId g,
  String description,
  int total,
  SplitSpec paidBy,
  SplitSpec owedBy, {
  String currency = 'INR',
}) => ExpenseDraft(
  groupId: g,
  description: description,
  total: total,
  currency: currency,
  paidBy: paidBy,
  owedBy: owedBy,
  category: 'general',
  date: utcFromMillis(kBaseMs),
);

PaymentDraft _payment(
  GroupId g,
  MemberId from,
  MemberId to,
  int amount, {
  String currency = 'INR',
}) => PaymentDraft(
  groupId: g,
  from: from,
  to: to,
  amount: amount,
  currency: currency,
  method: PaymentMethod.cash,
  date: utcFromMillis(kBaseMs),
);
