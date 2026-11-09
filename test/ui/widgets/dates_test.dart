import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/format/dates.dart';

void main() {
  final now = DateTime(2026, 11, 9, 15, 30);

  group('DateLabels.dayHeader', () {
    test('today, yesterday, weekday date, other year', () {
      expect(DateLabels.dayHeader(DateTime(2026, 11, 9, 1), now: now), 'Today');
      expect(
        DateLabels.dayHeader(DateTime(2026, 11, 8, 23), now: now),
        'Yesterday',
      );
      expect(
        DateLabels.dayHeader(DateTime(2026, 11, 8), now: now),
        'Yesterday',
      );
      expect(
        DateLabels.dayHeader(DateTime(2026, 3, 4), now: now),
        'Wed, 4 Mar',
      );
      expect(
        DateLabels.dayHeader(DateTime(2025, 3, 4), now: now),
        'Tue, 4 Mar 2025',
      );
    });

    test('UTC model dates are shown in local time', () {
      final utc = now.toUtc();
      expect(DateLabels.dayHeader(utc, now: now), 'Today');
    });
  });

  group('DateLabels.ago', () {
    test('minutes, hours, yesterday, weekday, date', () {
      expect(
        DateLabels.ago(now.subtract(const Duration(seconds: 20)), now: now),
        'just now',
      );
      expect(
        DateLabels.ago(now.subtract(const Duration(minutes: 5)), now: now),
        '5 min ago',
      );
      expect(
        DateLabels.ago(now.subtract(const Duration(hours: 2)), now: now),
        '2 h ago',
      );
      expect(DateLabels.ago(DateTime(2026, 11, 8, 9), now: now), 'yesterday');
      expect(DateLabels.ago(DateTime(2026, 11, 6, 9), now: now), 'Fri');
      expect(DateLabels.ago(DateTime(2026, 10, 2, 9), now: now), '2 Oct');
    });
  });

  test('picker date reads "Today, 9 Nov" (render 3, 4)', () {
    expect(
      DateLabels.pickerDate(DateTime(2026, 11, 9), now: now),
      'Today, 9 Nov',
    );
    expect(
      DateLabels.pickerDate(DateTime(2026, 11, 8), now: now),
      'Yesterday, 8 Nov',
    );
    expect(
      DateLabels.pickerDate(DateTime(2026, 11, 1), now: now),
      'Sun, 1 Nov',
    );
  });

  test('12 h clock is lower case', () {
    expect(DateLabels.clock12(DateTime(2026, 11, 8, 21, 12)), '9:12 pm');
    expect(DateLabels.clock12(DateTime(2026, 11, 8, 9, 5)), '9:05 am');
  });

  test('time, short date and countdown', () {
    expect(DateLabels.time(DateTime(2026, 11, 9, 14, 2)), '14:02');
    expect(DateLabels.shortDate(DateTime(2026, 11, 2), now: now), '2 Nov');
    expect(
      DateLabels.countdown(const Duration(minutes: 4, seconds: 32)),
      '4:32',
    );
    expect(DateLabels.countdown(const Duration(seconds: -3)), '0:00');
  });
}
