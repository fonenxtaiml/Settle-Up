// Onboarding (one screen): your name and home currency. The currency is
// preselected from the phone's region (INR in India).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/money.dart';
import '../../../core/name_text.dart';
import '../../../theme/tokens.dart';
import '../../providers.dart';
import '../../strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';
import '../pickers.dart';

/// The currency of [locale]'s region, e.g. en_IN -> INR; [fallback] when
/// the region is missing or unknown.
String currencyForLocale(Locale locale, {String fallback = 'INR'}) {
  final country = locale.countryCode;
  if (country == null || country.isEmpty) return fallback;
  try {
    final code = NumberFormat.simpleCurrency(
      locale: '${locale.languageCode}_$country',
    ).currencyName;
    if (code != null && Currencies.tryOf(code) != null) return code;
  } on Object {
    // Unsupported locale: fall through.
  }
  return fallback;
}

class OnboardingScreen extends ConsumerStatefulWidget {
  const OnboardingScreen({super.key, this.locale});

  /// Overrides the phone's locale (tests).
  final Locale? locale;

  @override
  ConsumerState<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends ConsumerState<OnboardingScreen> {
  final _name = TextEditingController();
  late String _currency = currencyForLocale(
    widget.locale ?? WidgetsBinding.instance.platformDispatcher.locale,
  );
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _start() async {
    // The name Settings saves: a letter or number is needed (DATA-R6-02).
    if (!NameText.isValid(_name.text) || _saving) return;
    setState(() => _saving = true);
    await runGuarded(
      context,
      () => ref
          .read(settingsRepositoryProvider)
          .completeOnboarding(
            displayName: _name.text,
            homeCurrency: _currency,
          ),
    );
    if (mounted) setState(() => _saving = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink2 = theme.colorScheme.onSurfaceVariant;
    final c = Currencies.of(_currency);
    final helper = theme.textTheme.bodySmall!.copyWith(color: ink2);
    final valid = NameText.isValid(_name.text);
    final name = valid ? NameText.normalize(_name.text) : '';
    return Scaffold(
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              FilledButton(
                onPressed: !valid || _saving ? null : _start,
                style: KitButtonStyles.block,
                child: const Text(S.getStarted),
              ),
              const SizedBox(height: Space.xs),
              Wrap(
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: Space.xs,
                children: [
                  Text(S.alreadyUse, style: helper),
                  TextLink(
                    S.syncIt,
                    onPressed: () => showSnack(context, S.comingSoon),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.only(top: Space.xxl, bottom: Space.lg),
          children: [
            textGutter(
              Align(
                alignment: Alignment.centerLeft,
                child: TetherTransfer(
                  fromId: 'me',
                  fromName: name.isEmpty ? S.you : name,
                  fromIsMe: true,
                  toId: 'friend',
                  toName: '',
                  lineLength: 96,
                ),
              ),
            ),
            const SizedBox(height: Space.xl),
            textGutter(
              Text(S.onboardingTitle, style: theme.textTheme.headlineMedium),
            ),
            const SizedBox(height: Space.sm),
            textGutter(
              Text(
                S.onboardingBody,
                style: theme.textTheme.bodyLarge!.copyWith(color: ink2),
              ),
            ),
            const SizedBox(height: Space.xl),
            gutter(
              LabeledTextField(
                label: S.yourName,
                hintText: S.yourNameHint,
                controller: _name,
                maxLength: 40,
                errorText: nameInputError(_name.text),
                textInputAction: TextInputAction.done,
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _start(),
              ),
            ),
            textGutter(
              Padding(
                padding: const EdgeInsets.only(top: Space.xs),
                child: Text(S.yourNameHelper, style: helper),
              ),
            ),
            const SizedBox(height: Space.lg),
            gutter(
              PickerTile(
                label: S.homeCurrency,
                value: '${c.name} (${c.code})',
                leading: Text(c.symbol, style: theme.textTheme.titleMedium),
                onTap: () async {
                  final code = await pickCurrency(context, selected: _currency);
                  if (code != null) setState(() => _currency = code);
                },
              ),
            ),
            textGutter(
              Padding(
                padding: const EdgeInsets.only(top: Space.xs),
                child: Text(S.homeCurrencyHelper, style: helper),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
