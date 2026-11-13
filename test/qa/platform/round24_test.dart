// QA PLATFORM round 24: final regression sweep of what reached the startup
// path and the release build after round 21: the app-wide Material
// localizations delegate (VISUAL-R11-01) that every screen now loads on
// the first frame, and the new pure-Dart unorm_dart dependency.
//
// The delegate runs before any screen draws, so a throw here is a launch
// crash on every phone whose locale it mishandles. These probes pump it
// the way SettleUpApp does (no flutter_localizations, default
// supportedLocales) under device locales the engineering tests do not
// use, and check the date strings need no intl locale initialisation.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/format/app_material_localizations.dart';

const _deviceLocales = [
  Locale('en', 'IN'),
  Locale('hi', 'IN'),
  Locale('ar', 'EG'),
  Locale('he'),
  Locale('ja', 'JP'),
  Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant'),
  Locale('de', 'DE'),
  Locale('und'),
];

void main() {
  group('Material localizations delegate on the first frame', () {
    for (final locale in _deviceLocales) {
      testWidgets('device locale $locale loads the day-first strings', (
        tester,
      ) async {
        late MaterialLocalizations loc;
        await tester.pumpWidget(
          MaterialApp(
            locale: locale,
            localizationsDelegates: const [AppMaterialLocalizations.delegate],
            home: Builder(
              builder: (context) {
                loc = MaterialLocalizations.of(context);
                return const SizedBox.shrink();
              },
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        expect(loc, isA<AppMaterialLocalizations>());
        final d = DateTime(2026, 11, 9);
        expect(loc.formatCompactDate(d), '09/11/2026');
        expect(loc.formatMediumDate(d), 'Mon, 9 Nov');
        expect(loc.formatFullDate(d), 'Monday, 9 November 2026');
        expect(loc.parseCompactDate('9/11/2026'), d);
        // The app's own strings stay left to right: no RTL locale is
        // supported, so the app resolves to its English default.
        expect(
          tester
              .widget<Directionality>(find.byType(Directionality).first)
              .textDirection,
          TextDirection.ltr,
        );
      });
    }

    testWidgets('a date picker opens under a non-English device locale', (
      tester,
    ) async {
      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('hi', 'IN'),
          localizationsDelegates: const [AppMaterialLocalizations.delegate],
          home: Builder(
            builder: (context) {
              ctx = context;
              return const Scaffold();
            },
          ),
        ),
      );
      unawaited(
        showDatePicker(
          context: ctx,
          initialDate: DateTime(2026, 11, 9),
          firstDate: DateTime(2000),
          lastDate: DateTime(2100),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Mon, 9 Nov'), findsOneWidget);
    });
  });

  group('unorm_dart', () {
    test('is pinned and has no platform code of its own', () {
      final pubspec = File('pubspec.yaml').readAsStringSync();
      expect(
        RegExp(r'^  unorm_dart: 0\.3\.3\b', multiLine: true).hasMatch(pubspec),
        isTrue,
        reason: 'an exact pin: NFKC output feeds stored names',
      );
      final plugins = File('.flutter-plugins-dependencies');
      if (plugins.existsSync()) {
        expect(
          plugins.readAsStringSync(),
          isNot(contains('unorm_dart')),
          reason: 'a plugin would need R8 keep rules',
        );
      }
    });
  });
}
