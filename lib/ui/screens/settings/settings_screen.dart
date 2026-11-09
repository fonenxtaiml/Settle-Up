// Settings: your name, home currency, default split, theme, vibration,
// this phone's name and CSV export.
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/csv_export.dart';
import '../../../core/models.dart';
import '../../../core/money.dart';
import '../../../theme/tokens.dart';
import '../../providers.dart';
import '../../strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';
import '../pickers.dart';

const String appVersion = '1.0.0 (1)';

String themeLabel(AppThemeMode m) => switch (m) {
  AppThemeMode.system => S.themeSystem,
  AppThemeMode.light => S.themeLight,
  AppThemeMode.dark => S.themeDark,
};

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.read(settingsRepositoryProvider);
    final profile = ref.watch(profileProvider).value;
    final settings =
        ref.watch(appSettingsProvider).value ?? const AppSettings();
    final device = ref.watch(deviceIdentityProvider).value;
    final theme = Theme.of(context);
    if (profile == null) {
      return Scaffold(
        appBar: screenAppBar(
          leading: const BackArrow(),
          title: const Text(S.settingsTitle),
        ),
      );
    }
    final currency = Currencies.of(profile.homeCurrency);

    Future<void> update(AppSettings next) =>
        runGuarded(context, () => repo.updateSettings(next));

    Widget switchRow(String title, bool value, ValueChanged<bool> onChanged) =>
        MergeSemantics(
          child: KitListRow(
            title: title,
            minHeight: Sizes.rowMinDense,
            trailing: Switch(value: value, onChanged: onChanged),
            onTap: () => onChanged(!value),
          ),
        );

    return Scaffold(
      appBar: screenAppBar(
        leading: const BackArrow(),
        title: const Text(S.settingsTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          gutter(
            ListSection(
              dividerIndent: Space.avatarRowInset,
              children: [
                KitListRow(
                  title: profile.displayName,
                  subtitle: device == null
                      ? null
                      : S.thisPhoneLine(device.deviceName),
                  leading: PersonAvatar(
                    id: profile.personId,
                    name: profile.displayName,
                    isMe: true,
                  ),
                  trailing: const Icon(Icons.edit_outlined, size: 20),
                  onTap: () async {
                    final name = await promptText(
                      context,
                      title: S.editName,
                      initial: profile.displayName,
                      helper: S.yourNameHelper,
                    );
                    if (name == null || !context.mounted) return;
                    await runGuarded(
                      context,
                      () => repo.updateProfile(
                        profile.copyWith(displayName: name),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          gutter(
            ListSection(
              title: S.sectionMoney,
              children: [
                _ValueRow(
                  title: S.homeCurrency,
                  value: '${currency.symbol} ${currency.code}',
                  onTap: () async {
                    final code = await pickCurrency(
                      context,
                      selected: profile.homeCurrency,
                    );
                    if (code == null || !context.mounted) return;
                    await runGuarded(
                      context,
                      () => repo.updateProfile(
                        profile.copyWith(homeCurrency: code),
                      ),
                    );
                  },
                ),
                _ValueRow(
                  title: S.defaultSplit,
                  value: SplitMethodSelector.labelFor(settings.defaultSplit),
                  onTap: () async {
                    final m = await pickOption<SplitMethod>(
                      context,
                      title: S.defaultSplit,
                      selected: settings.defaultSplit,
                      options: [
                        for (final m in SplitMethod.values)
                          (m, SplitMethodSelector.labelFor(m)),
                      ],
                    );
                    if (m != null) {
                      await update(settings.copyWith(defaultSplit: m));
                    }
                  },
                ),
                switchRow(
                  S.simplifyNewGroups,
                  settings.simplifyByDefault,
                  (v) => update(settings.copyWith(simplifyByDefault: v)),
                ),
              ],
            ),
          ),
          gutter(
            ListSection(
              title: S.sectionAppearance,
              children: [
                _ValueRow(
                  title: S.theme,
                  value: themeLabel(settings.themeMode),
                  onTap: () async {
                    final m = await pickOption<AppThemeMode>(
                      context,
                      title: S.theme,
                      selected: settings.themeMode,
                      options: [
                        for (final m in AppThemeMode.values) (m, themeLabel(m)),
                      ],
                    );
                    if (m != null) {
                      await update(settings.copyWith(themeMode: m));
                    }
                  },
                ),
                switchRow(
                  S.vibration,
                  settings.vibration,
                  (v) => update(settings.copyWith(vibration: v)),
                ),
              ],
            ),
          ),
          gutter(
            ListSection(
              title: S.sectionSync,
              children: [
                _ValueRow(
                  title: S.phoneName,
                  value: device?.deviceName,
                  onTap: () async {
                    final name = await promptText(
                      context,
                      title: S.phoneName,
                      initial: device?.deviceName ?? '',
                      helper: S.phoneNameHelp,
                    );
                    if (name == null || !context.mounted) return;
                    await runGuarded(context, () => repo.setDeviceName(name));
                  },
                ),
              ],
            ),
          ),
          gutter(
            ListSection(
              title: S.sectionData,
              children: [
                KitListRow(
                  title: S.exportGroupCsv,
                  minHeight: Sizes.rowMinDense,
                  trailing: const Icon(Icons.ios_share_rounded, size: 20),
                  onTap: () => _export(context, ref),
                ),
              ],
            ),
          ),
          gutter(
            ListSection(
              title: S.sectionAbout,
              children: [
                KitListRow(
                  title: S.licenses,
                  minHeight: Sizes.rowMinDense,
                  trailing: Icon(
                    Icons.chevron_right_rounded,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: S.appName,
                    applicationVersion: appVersion,
                  ),
                ),
                KitListRow(
                  title: S.version,
                  minHeight: Sizes.rowMinDense,
                  trailing: Text(appVersion, style: theme.textTheme.bodyMedium),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _export(BuildContext context, WidgetRef ref) async {
    final snap = ref.read(ledgerProvider).value;
    final me = ref.read(profileProvider).value?.personId;
    if (snap == null || me == null) return;
    final groups = snap.state.visibleGroups.toList()
      ..sort((a, b) => groupTitle(a, me).compareTo(groupTitle(b, me)));
    if (groups.isEmpty) {
      showSnack(context, S.noGroupsToExport);
      return;
    }
    final id = await pickOption<String>(
      context,
      title: S.exportPick,
      selected: null,
      options: [for (final g in groups) (g.groupId, groupTitle(g, me))],
    );
    if (id == null) return;
    final g = snap.state.groups[id]!;
    final title = groupTitle(g, me);
    await SharePlus.instance.share(
      ShareParams(
        subject: S.csvSubject(title),
        files: [
          XFile.fromData(
            utf8.encode(CsvExport.group(g)),
            mimeType: 'text/csv',
            name: '${title.replaceAll(RegExp(r'[^\w\- ]'), '')}.csv',
          ),
        ],
      ),
    );
  }
}

/// "Theme            Light ›": a setting with its current value.
class _ValueRow extends StatelessWidget {
  const _ValueRow({required this.title, required this.value, this.onTap});

  final String title;
  final String? value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink2 = theme.colorScheme.onSurfaceVariant;
    return KitListRow(
      title: title,
      minHeight: Sizes.rowMinDense,
      onTap: onTap,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (value != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                value!,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyLarge!.copyWith(color: ink2),
              ),
            ),
          const SizedBox(width: Space.xs),
          Icon(Icons.chevron_right_rounded, color: ink2),
        ],
      ),
    );
  }
}
