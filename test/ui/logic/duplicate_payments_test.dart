// SPEC 7.2: "possible duplicate" hint for two payments of the same debt.
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/screens/common.dart';

import '../../qa/money/money_harness.dart';

void main() {
  test('same from, to and amount within 24 h are both flagged', () async {
    final p = await QaPhone.create(home: 'INR');
    final t = await p.group(['Sam']);
    final me = t.m['me']!, sam = t.m['Sam']!;
    final a = await p.pay(t.g, from: sam, to: me, amount: 30000);
    final b = await p.pay(
      t.g,
      from: sam,
      to: me,
      amount: 30000,
      dateMs: kBaseMs + 23 * 3600000,
    );
    // Different amount, other direction, other currency: not duplicates.
    final c = await p.pay(t.g, from: sam, to: me, amount: 29999);
    final d = await p.pay(t.g, from: me, to: sam, amount: 30000);
    final e = await p.pay(
      t.g,
      from: sam,
      to: me,
      amount: 30000,
      currency: 'USD',
    );
    final dup = possibleDuplicatePayments(p.gs(t.g));
    expect(dup, containsAll([a, b]));
    expect(dup, isNot(contains(c)));
    expect(dup, isNot(contains(d)));
    expect(dup, isNot(contains(e)));
    await p.dispose();
  });

  test('more than 24 h apart is not flagged', () async {
    final p = await QaPhone.create(home: 'INR');
    final t = await p.group(['Sam']);
    final me = t.m['me']!, sam = t.m['Sam']!;
    await p.pay(t.g, from: sam, to: me, amount: 30000);
    await p.pay(
      t.g,
      from: sam,
      to: me,
      amount: 30000,
      dateMs: kBaseMs + 25 * 3600000,
    );
    expect(possibleDuplicatePayments(p.gs(t.g)), isEmpty);
    await p.dispose();
  });
}
