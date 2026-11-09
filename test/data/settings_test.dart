// KvSettingsRepository and the locale currency lookup (SPEC 5.11, 11.2).
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/ids.dart';
import 'package:settle_up/core/models.dart';
import 'package:settle_up/core/money.dart';
import 'package:settle_up/data/kv_settings_repository.dart';
import 'package:settle_up/data/locale_currency.dart';
import 'package:settle_up/data/memory_op_store.dart';
import 'package:settle_up/data/schema.dart';
import 'package:settle_up/data/sqlite_op_store.dart';

void main() {
  late MemoryOpStore store;

  setUp(() => store = MemoryOpStore());

  Future<KvSettingsRepository> open({
    IdGenerator? ids,
    String? locale = 'en_US',
    String name = 'Pixel 8',
  }) =>
      KvSettingsRepository.open(
        store,
        defaultDeviceName: name,
        ids: ids ?? SequentialIdGenerator(),
        localeName: locale,
      );

  group('first launch', () {
    test('creates and persists a device identity', () async {
      final s = await open();
      expect(s.device.deviceId, '00000000-0000-7000-8000-000000000001');
      expect(s.device.deviceName, 'Pixel 8');
      final stored = jsonDecode((await store.getKv(KvKeys.device))!) as Map;
      expect(stored['deviceId'], s.device.deviceId);
      expect(s.profile, isNull);
      expect(s.settings.themeMode, AppThemeMode.system);
      expect(s.settings.simplifyByDefault, isTrue);
    });

    test('later launches keep the same device id', () async {
      final first = await open();
      final again = await open(ids: SequentialIdGenerator(500), name: 'Other');
      expect(again.device.deviceId, first.device.deviceId);
      expect(again.device.deviceName, 'Pixel 8');
    });

    test('the real generator gives a UUIDv7', () async {
      final s = await KvSettingsRepository.open(store,
          defaultDeviceName: 'Pixel 8', localeName: 'en_US');
      expect(s.device.deviceId,
          matches(RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-')));
    });

    test('a blank default name falls back to "Phone"', () async {
      final s = await open(name: '  ');
      expect(s.device.deviceName, 'Phone');
    });

    test('corrupt stored values fall back to defaults', () async {
      await store.setKv(KvKeys.profile, '{not json');
      await store.setKv(KvKeys.settings, '{"vibration": "yes", "themeMode": "dark"}');
      final s = await open();
      expect(s.profile, isNull);
      expect(s.settings.vibration, isTrue);
      expect(s.settings.themeMode, AppThemeMode.dark);
    });
  });

  group('onboarding', () {
    test('creates a personId once; later calls keep it', () async {
      final ids = SequentialIdGenerator();
      final s = await open(ids: ids);
      final p1 = await s.completeOnboarding(
          displayName: '  Alex ', homeCurrency: 'inr');
      expect(p1.displayName, 'Alex');
      expect(p1.homeCurrency, 'INR');
      expect(p1.personId, '00000000-0000-7000-8000-000000000002');
      final p2 =
          await s.completeOnboarding(displayName: 'Alex K', homeCurrency: 'EUR');
      expect(p2.personId, p1.personId);
      expect(s.profile!.displayName, 'Alex K');

      final reopened = await open(ids: SequentialIdGenerator(900));
      expect(reopened.profile!.personId, p1.personId);
      expect(reopened.profile!.homeCurrency, 'EUR');
    });

    test('rejects a blank name and an unknown currency', () async {
      final s = await open();
      expect(() => s.completeOnboarding(displayName: ' ', homeCurrency: 'USD'),
          throwsArgumentError);
      expect(() => s.completeOnboarding(displayName: 'A', homeCurrency: 'ZZZ'),
          throwsArgumentError);
      expect(s.profile, isNull);
    });

    test('updateProfile keeps the personId and refuses to change it',
        () async {
      final s = await open();
      expect(
          () => s.updateProfile(const Profile(
              personId: 'p', displayName: 'A', homeCurrency: 'USD')),
          throwsStateError);
      final p = await s.completeOnboarding(displayName: 'A', homeCurrency: 'USD');
      await s.updateProfile(p.copyWith(displayName: 'Bee', homeCurrency: 'GBP'));
      expect(s.profile!.displayName, 'Bee');
      expect(s.profile!.homeCurrency, 'GBP');
      expect(
          () => s.updateProfile(const Profile(
              personId: 'other', displayName: 'A', homeCurrency: 'USD')),
          throwsArgumentError);
    });
  });

  group('streams emit the current value first', () {
    test('watchProfile', () async {
      final s = await open();
      final seen = <Profile?>[];
      final sub = s.watchProfile().listen(seen.add);
      await pumpEventQueue();
      expect(seen, [null]);
      await s.completeOnboarding(displayName: 'Alex', homeCurrency: 'USD');
      await pumpEventQueue();
      expect(seen.map((p) => p?.displayName), [null, 'Alex']);
      // A late subscriber starts from the current value.
      expect((await s.watchProfile().first)!.displayName, 'Alex');
      await sub.cancel();
    });

    test('watchSettings', () async {
      final s = await open();
      final seen = <AppSettings>[];
      final sub = s.watchSettings().listen(seen.add);
      await pumpEventQueue();
      await s.updateSettings(s.settings.copyWith(
          themeMode: AppThemeMode.dark, defaultSplit: SplitMethod.shares));
      await pumpEventQueue();
      expect(seen.map((x) => x.themeMode),
          [AppThemeMode.system, AppThemeMode.dark]);
      await sub.cancel();
      final reopened = await open();
      expect(reopened.settings.themeMode, AppThemeMode.dark);
      expect(reopened.settings.defaultSplit, SplitMethod.shares);
      expect(reopened.settings.vibration, isTrue);
    });

    test('watchDevice and setDeviceName', () async {
      final s = await open();
      final seen = <String>[];
      final sub = s.watchDevice().listen((d) => seen.add(d.deviceName));
      await pumpEventQueue();
      final id = s.device.deviceId;
      await s.setDeviceName("  Alex's Pixel  ");
      await pumpEventQueue();
      expect(seen, ['Pixel 8', "Alex's Pixel"]);
      expect(s.device.deviceId, id);
      expect(() => s.setDeviceName(''), throwsArgumentError);
      expect((await open()).device.deviceName, "Alex's Pixel");
      await sub.cancel();
    });

    test('close completes the streams', () async {
      final s = await open();
      final done = s.watchSettings().toList();
      await s.close();
      expect(await done, hasLength(1));
    });
  });

  group('home currency from the locale', () {
    test('repository exposes the locale default for onboarding', () async {
      expect((await open(locale: 'en_IN')).defaultHomeCurrency, 'INR');
      expect((await open(locale: 'de-DE')).defaultHomeCurrency, 'EUR');
      expect((await open(locale: null)).defaultHomeCurrency, isNotEmpty);
      expect((await open(locale: 'C')).defaultHomeCurrency, 'USD');
    });

    test('locale formats', () {
      expect(homeCurrencyForLocale('en_IN'), 'INR');
      expect(homeCurrencyForLocale('hi-IN'), 'INR');
      expect(homeCurrencyForLocale('en_GB.UTF-8'), 'GBP');
      expect(homeCurrencyForLocale('de_DE@euro'), 'EUR');
      expect(homeCurrencyForLocale('sr_Latn_RS'), 'RSD');
      expect(homeCurrencyForLocale('zh-Hant-TW'), 'TWD');
      expect(homeCurrencyForLocale('ja_JP'), 'JPY');
      expect(homeCurrencyForLocale('pt_BR'), 'BRL');
      expect(homeCurrencyForLocale('fr_CI'), 'XOF');
      expect(homeCurrencyForLocale('en_us'), 'USD');
      expect(homeCurrencyForLocale('ja'), 'JPY');
    });

    test('unknown or missing locales fall back to USD', () {
      for (final l in [null, '', 'C', 'POSIX', 'en', 'es_419', 'xx_QQ', '_']) {
        expect(homeCurrencyForLocale(l), kFallbackHomeCurrency, reason: '$l');
      }
      expect(kFallbackHomeCurrency, 'USD');
    });

    test('every suggestion is a known currency', () {
      const regions = 'AD AE AF AG AI AL AM AO AR AS AT AU AW AX AZ BA BB BD '
          'BE BF BG BH BI BJ BL BM BN BO BQ BR BS BT BW BY BZ CA CD CF CG CH '
          'CI CK CL CM CN CO CR CU CV CW CY CZ DE DJ DK DM DO DZ EC EE EG ER '
          'ES ET FI FJ FK FM FO FR GA GB GD GE GF GH GI GL GM GN GP GQ GR GT '
          'GU GW GY HK HN HR HT HU ID IE IL IN IQ IR IS IT JM JO JP KE KG KH '
          'KI KM KN KP KR KW KY KZ LA LB LC LI LK LR LS LT LU LV LY MA MC MD '
          'ME MG MH MK ML MM MN MO MR MT MU MV MW MX MY MZ NA NC NE NG NI NL '
          'NO NP NR NZ OM PA PE PF PG PH PK PL PR PS PT PW PY QA RE RO RS RU '
          'RW SA SB SC SD SE SG SI SK SL SM SN SO SR SS ST SV SX SY SZ TD TG '
          'TH TJ TL TM TN TO TR TT TV TW TZ UA UG US UY UZ VA VE VN VU WS YE '
          'ZA ZM ZW';
      for (final r in regions.split(' ')) {
        final code = homeCurrencyForLocale('en_$r');
        expect(Currencies.tryOf(code), isNotNull, reason: r);
        if (r != 'US' && !const {'EC', 'SV', 'PR', 'GU', 'AS', 'FM', 'MH', 'PW', 'TL', 'BQ'}.contains(r)) {
          expect(code, isNot('USD'), reason: '$r should have its own mapping');
        }
      }
    });
  });

  test('works on SqliteOpStore too', () async {
    final sql = SqliteOpStore(':memory:');
    await sql.open();
    final s = await KvSettingsRepository.open(sql,
        defaultDeviceName: 'Pixel 8',
        ids: SequentialIdGenerator(),
        localeName: 'en_IN');
    await s.completeOnboarding(displayName: 'Asha', homeCurrency: 'INR');
    final again = await KvSettingsRepository.open(sql,
        defaultDeviceName: 'x', ids: SequentialIdGenerator(77));
    expect(again.device.deviceId, s.device.deviceId);
    expect(again.profile!.personId, s.profile!.personId);
    await sql.close();
  });
}
