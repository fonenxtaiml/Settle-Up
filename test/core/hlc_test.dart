import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/hlc.dart';

void main() {
  const dev = 'dev-a';

  group('tick', () {
    test('is strictly monotonic under a frozen clock', () {
      final clock = HlcClock(deviceId: dev, nowMillis: () => 1000);
      Hlc? prev;
      for (var i = 0; i < 500; i++) {
        final t = clock.tick();
        expect(t.millis, 1000);
        expect(t.counter, i);
        expect(t.deviceId, dev);
        if (prev != null) expect(t > prev, isTrue);
        prev = t;
      }
    });

    test('is strictly monotonic when the wall clock goes backwards', () {
      var now = 5000;
      final clock = HlcClock(deviceId: dev, nowMillis: () => now);
      final a = clock.tick();
      now = 1000; // clock jumped back
      final b = clock.tick();
      final c = clock.tick();
      expect(b > a, isTrue);
      expect(c > b, isTrue);
      expect(b.millis, 5000);
      expect(b.counter, 1);
      now = 6000;
      final d = clock.tick();
      expect(d, const Hlc(6000, 0, dev));
    });

    test('resets the counter when physical time advances', () {
      var now = 1000;
      final clock = HlcClock(deviceId: dev, nowMillis: () => now);
      clock.tick();
      clock.tick();
      now = 1001;
      expect(clock.tick(), const Hlc(1001, 0, dev));
    });

    test('continues from a restored last value', () {
      final clock = HlcClock(
          deviceId: dev, last: const Hlc(9000, 7, dev), nowMillis: () => 10);
      expect(clock.tick(), const Hlc(9000, 8, dev));
    });

    test('counter overflow rolls into the next millisecond', () {
      final clock = HlcClock(
        deviceId: dev,
        last: const Hlc(1000, Hlc.maxCounter, dev),
        nowMillis: () => 1000,
      );
      final t = clock.tick();
      expect(t, const Hlc(1001, 0, dev));
      expect(clock.tick(), const Hlc(1001, 1, dev));
    });
  });

  group('receive', () {
    test('branch 1: local, remote and now tie on millis -> max counter + 1',
        () {
      final clock = HlcClock(
          deviceId: dev, last: const Hlc(1000, 3, dev), nowMillis: () => 1000);
      expect(clock.receive(const Hlc(1000, 9, 'x')), const Hlc(1000, 10, dev));
      final clock2 = HlcClock(
          deviceId: dev, last: const Hlc(1000, 9, dev), nowMillis: () => 1000);
      expect(clock2.receive(const Hlc(1000, 3, 'x')), const Hlc(1000, 10, dev));
    });

    test('branch 2: local is ahead -> local counter + 1', () {
      final clock = HlcClock(
          deviceId: dev, last: const Hlc(2000, 4, dev), nowMillis: () => 1000);
      expect(clock.receive(const Hlc(1500, 99, 'x')), const Hlc(2000, 5, dev));
    });

    test('branch 3: remote is ahead -> remote counter + 1', () {
      final clock = HlcClock(
          deviceId: dev, last: const Hlc(1000, 4, dev), nowMillis: () => 1000);
      expect(clock.receive(const Hlc(3000, 7, 'x')), const Hlc(3000, 8, dev));
      expect(clock.skewDetected, isFalse);
    });

    test('branch 4: wall clock is ahead of both -> counter 0', () {
      final clock = HlcClock(
          deviceId: dev, last: const Hlc(1000, 4, dev), nowMillis: () => 5000);
      expect(clock.receive(const Hlc(2000, 7, 'x')), const Hlc(5000, 0, dev));
    });

    test('result is greater than both local and remote', () {
      final rnd = math.Random(7);
      for (var i = 0; i < 1000; i++) {
        final now = 1000000 + rnd.nextInt(1000);
        final last = Hlc(1000000 + rnd.nextInt(1000), rnd.nextInt(5), dev);
        final remote = Hlc(1000000 + rnd.nextInt(1000), rnd.nextInt(5), 'r');
        final clock =
            HlcClock(deviceId: dev, last: last, nowMillis: () => now);
        final t = clock.receive(remote);
        expect(t > last, isTrue);
        expect(t.compareTo(Hlc(remote.millis, remote.counter, dev)) > 0,
            isTrue);
        expect(t.millis, greaterThanOrEqualTo(now));
      }
    });

    test('counter overflow on receive rolls millis', () {
      final clock = HlcClock(
          deviceId: dev, last: const Hlc(1000, 1, dev), nowMillis: () => 1000);
      expect(clock.receive(const Hlc(1000, Hlc.maxCounter, 'x')),
          const Hlc(1001, 0, dev));
    });

    test('skew guard: far-future remote is not adopted', () {
      const now = 10000000;
      final clock = HlcClock(deviceId: dev, nowMillis: () => now);
      final remote =
          const Hlc(now + HlcClock.maxForwardDriftMs + 1, 0, 'x');
      final t = clock.receive(remote);
      expect(clock.skewDetected, isTrue);
      expect(t, const Hlc(now, 0, dev));
      expect(t < remote, isTrue);
    });

    test('skew guard boundary: exactly the max drift is adopted', () {
      const now = 10000000;
      final clock = HlcClock(deviceId: dev, nowMillis: () => now);
      final t = clock
          .receive(const Hlc(now + HlcClock.maxForwardDriftMs, 2, 'x'));
      expect(clock.skewDetected, isFalse);
      expect(t, const Hlc(now + HlcClock.maxForwardDriftMs, 3, dev));
    });
  });

  group('encoding', () {
    test('encode/parse round trip', () {
      const h = Hlc(1762700000000, 0x1a, '00000000-0000-7000-8000-000000000001');
      expect(h.encode(),
          '001762700000000-001a-00000000-0000-7000-8000-000000000001');
      expect(Hlc.parse(h.encode()), h);
      expect(h.toString(), h.encode());
      expect(Hlc.zero('d'), const Hlc(0, 0, 'd'));
    });

    test('malformed input throws FormatException', () {
      for (final bad in [
        '',
        'abc',
        '001762700000000-001a-',
        '1762700000000-001a-dev',
        '001762700000000-1a-dev',
        '001762700000000_001a_dev',
        '00176270000000x-001a-dev',
        '001762700000000-zzzz-dev',
      ]) {
        expect(() => Hlc.parse(bad), throwsFormatException, reason: bad);
      }
    });

    test('string order equals compareTo for 1,000 random pairs', () {
      final rnd = math.Random(42);
      const devices = ['a', 'b', 'dev-1', 'dev-2', 'zz'];
      Hlc random() => Hlc(
            rnd.nextBool()
                ? 1762700000000 + rnd.nextInt(3)
                : rnd.nextInt(1 << 32) * 1000,
            rnd.nextInt(3) == 0 ? rnd.nextInt(Hlc.maxCounter + 1) : rnd.nextInt(3),
            devices[rnd.nextInt(devices.length)],
          );
      for (var i = 0; i < 1000; i++) {
        final a = random();
        final b = random();
        expect(a.encode().compareTo(b.encode()).sign, a.compareTo(b).sign,
            reason: '$a vs $b');
        expect(Hlc.parse(a.encode()), a);
      }
    });

    test('equality and hashCode', () {
      expect(const Hlc(1, 2, 'd'), const Hlc(1, 2, 'd'));
      expect(const Hlc(1, 2, 'd').hashCode, const Hlc(1, 2, 'd').hashCode);
      expect(const Hlc(1, 2, 'd') == const Hlc(1, 2, 'e'), isFalse);
      expect(const Hlc(1, 2, 'd') < const Hlc(1, 2, 'e'), isTrue);
      expect(const Hlc(1, 3, 'a') > const Hlc(1, 2, 'z'), isTrue);
    });
  });

  group('tickAfter (SYNC-R1-01)', () {
    const h = 60 * 60 * 1000;
    const now = 1000000000000;

    test('moves past a floor ahead of the skew guard and keeps it', () {
      final clock = HlcClock(deviceId: dev, nowMillis: () => now);
      const floor = Hlc(now + 2 * h, 5, 'dev-z');
      final t = clock.tickAfter(floor);
      expect(t > floor, isTrue);
      expect(t, const Hlc(now + 2 * h, 6, dev));
      expect(clock.last, t);
      expect(clock.skewDetected, isTrue);
      expect(clock.tick() > t, isTrue, reason: 'later ticks stay monotonic');
    });

    test('this phone\'s own floor ahead is adopted without a skew flag '
        '(DATA-R31-01: no peer clock was ahead)', () {
      final clock = HlcClock(deviceId: dev, nowMillis: () => now);
      const floor = Hlc(now + 2 * h, 5, dev);
      final t = clock.tickAfter(floor);
      expect(t > floor, isTrue);
      expect(clock.skewDetected, isFalse);
      // Another phone's floor as far ahead still sets it.
      clock.tickAfter(const Hlc(now + 3 * h, 0, 'dev-z'));
      expect(clock.skewDetected, isTrue);
    });

    test('a floor equal up to the device id still loses', () {
      final clock = HlcClock(deviceId: 'dev-a', nowMillis: () => now);
      const floor = Hlc(now + 10, 3, 'dev-z');
      expect(clock.tickAfter(floor) > floor, isTrue);
    });

    test('a floor behind the clock is a plain tick', () {
      final a = HlcClock(deviceId: dev, nowMillis: () => now);
      final b = HlcClock(deviceId: dev, nowMillis: () => now);
      a.tick();
      b.tick();
      expect(a.tickAfter(const Hlc(now - h, 9, 'dev-z')), b.tick());
      expect(a.skewDetected, isFalse);
    });

    test('a floor within the skew guard is passed without a skew flag', () {
      final clock = HlcClock(deviceId: dev, nowMillis: () => now);
      const floor = Hlc(now + 1000, 0, 'dev-z');
      expect(clock.tickAfter(floor) > floor, isTrue);
      expect(clock.skewDetected, isFalse);
    });

    test('exactly maxAdoptDriftMs ahead is adopted, beyond is not', () {
      final edge = HlcClock(deviceId: dev, nowMillis: () => now);
      const at = Hlc(now + HlcClock.maxAdoptDriftMs, 0, 'dev-z');
      expect(edge.tickAfter(at) > at, isTrue);

      final far = HlcClock(deviceId: dev, nowMillis: () => now);
      const beyond = Hlc(now + HlcClock.maxAdoptDriftMs + 1, 0, 'dev-z');
      final t = far.tickAfter(beyond);
      expect(t, const Hlc(now, 0, dev), reason: 'not adopted');
    });

    test('counter overflow at the floor rolls millis', () {
      final clock = HlcClock(deviceId: dev, nowMillis: () => now);
      const floor = Hlc(now + 5, Hlc.maxCounter, 'dev-z');
      final t = clock.tickAfter(floor);
      expect(t, const Hlc(now + 6, 0, dev));
    });
  });
}
