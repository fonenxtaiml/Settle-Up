// Settings: your name, home currency, default split, theme, vibration,
// this phone's name and CSV export.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/ids.dart';
import '../../../core/models.dart';
import '../../../core/money.dart';
import '../../../core/name_text.dart';
import '../../../theme/tokens.dart';
import '../../providers.dart';
import '../../strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';
import '../csv_share.dart';
import '../pickers.dart';
import '../../app_version.dart';

// The version of the running build (pubspec.yaml via the Flutter tool).
export '../../app_version.dart' show appVersion;

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
    // Kept live while Settings is open (CSV export, rename): Riverpod pauses
    // what only the covered Home screen watches.
    ref.watch(ledgerProvider);
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
                      maxLength: kMemberNameMax,
                    );
                    if (name == null || !context.mounted) return;
                    // Two members with one name cannot be told apart in
                    // Paid by or the split (the Members rule).
                    final clash = nameClashForMe(ref, profile.personId, name);
                    if (clash != null) {
                      Haptics.invalid(context);
                      showSnack(context, clash);
                      return;
                    }
                    await runGuarded(context, () async {
                      await repo.updateProfile(
                        profile.copyWith(displayName: name),
                      );
                      // "Friends see this when you sync": my member in
                      // every group takes the new name.
                      await renameMeEverywhere(ref, profile.personId, name);
                    });
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
                      // SPEC 8.9: the mDNS service name, at most 40.
                      maxLength: kDeviceNameMax,
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
    // The ledger as it is now: Settings watches it, so this is never a
    // snapshot paused while Settings covered Home.
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
    if (!context.mounted) return;
    await shareGroupCsv(context, g, groupTitle(g, me));
  }
}

/// SPEC 8.9: the phone name is the mDNS service name, at most 40.
const int kDeviceNameMax = 40;

/// The refusal copy when [name] is already someone else's name in a group
/// I am in ("Rahul is already in Goa trip"; for a 1:1, whose stored name is
/// the friend's, "You already have a friend called Rahul"), or null when
/// it is free.
String? nameClashForMe(WidgetRef ref, PersonId me, String name) {
  final ledger = ref.read(ledgerRepositoryProvider);
  for (final g in ledger.current.state.visibleGroups) {
    final mine = myMemberIn(g, me);
    if (mine == null) continue;
    final dup = duplicateName(name, [
      for (final m in g.activeMembers)
        if (g.resolve(m.id) != mine) m.displayName,
    ]);
    if (dup == null) continue;
    return g.group!.isDirect
        ? S.alreadyAFriend(dup)
        : S.alreadyInNamedGroup(dup, g.group!.name);
  }
  return null;
}

/// Renames my member in every group I am in to [name] (merges followed),
/// so friends see it after the next sync.
Future<void> renameMeEverywhere(WidgetRef ref, PersonId me, String name) async {
  final ledger = ref.read(ledgerRepositoryProvider);
  final trimmed = NameText.normalize(name);
  for (final g in ledger.current.state.visibleGroups) {
    final mine = myMemberIn(g, me);
    if (mine == null) continue;
    if (g.members[mine]?.displayName == trimmed) continue;
    await ledger.renameMember(g.groupId, mine, trimmed);
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
