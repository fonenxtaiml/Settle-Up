// "Which one are you?" after joining a group: pick your name so balances
// follow you, or add yourself.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/ids.dart';
import '../../../core/ledger_state.dart';
import '../../../core/models.dart';
import '../../../theme/tokens.dart';
import '../../providers.dart';
import '../../router.dart';
import '../../strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';

class ClaimScreen extends ConsumerWidget {
  const ClaimScreen({super.key, required this.groupId});

  final GroupId groupId;

  void _finish(BuildContext context) =>
      context.pushReplacement(Routes.group(groupId));

  /// "I'm not on the list": adds me under my profile name, unless the
  /// group already lists that name (case and spaces aside). Two members
  /// with one name cannot be told apart in Paid by or the split, so a
  /// placeholder with my name is offered first ("Is that you?"), and
  /// otherwise I pick a name the group can tell apart.
  Future<void> _addMe(
    BuildContext context,
    WidgetRef ref,
    GroupState g,
    Profile profile,
  ) async {
    final ledger = ref.read(ledgerRepositoryProvider);
    final groupName = g.group!.name;
    var name = profile.displayName.trim();
    String? sameName() =>
        duplicateName(name, [for (final m in g.activeMembers) m.displayName]);
    final dup = sameName();
    if (dup != null) {
      final placeholder = [
        for (final m in g.activeMembers)
          if (m.isPlaceholder && duplicateName(name, [m.displayName]) != null)
            m,
      ].firstOrNull;
      if (placeholder != null) {
        final mine = await askChoice(
          context,
          title: S.claimSameNameTitle,
          body: S.claimSameNameBody(placeholder.displayName, groupName),
          confirmLabel: S.thatsMe,
          cancelLabel: S.notMe,
        );
        // Back or a tap outside closes the question and nothing else
        // (UIFLOW-R4-02); only "Not me" goes on to the name prompt.
        if (mine == null || !context.mounted) return;
        if (mine) {
          final ok = await runGuarded(
            context,
            () => ledger.claimMember(groupId, placeholder.id),
          );
          if (ok && context.mounted) {
            Haptics.medium(context);
            showSnack(context, S.claimed(placeholder.displayName));
            _finish(context);
          }
          return;
        }
      }
      final other = await promptText(
        context,
        title: S.yourNameIn(groupName),
        initial: name,
        helper: S.nameTakenHelper(dup),
        confirmLabel: S.addPerson,
        maxLength: kMemberNameMax,
        isName: true,
      );
      if (other == null || !context.mounted) return;
      name = other.trim();
      if (!isSavableName(name, kMemberNameMax)) return;
      final still = sameName();
      if (still != null) {
        Haptics.invalid(context);
        showSnack(context, S.alreadyInNamedGroup(still, groupName));
        return;
      }
    }
    final ok = await runGuarded(context, () async {
      final id = await ledger.addMember(
        groupId,
        displayName: name,
        personId: profile.personId,
      );
      await ledger.claimMember(groupId, id);
    });
    if (ok && context.mounted) _finish(context);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final g = ref.watch(groupProvider(groupId)).value;
    final profile = ref.watch(profileProvider).value;
    final pending = ref.watch(ledgerProvider).value?.pendingJoins[groupId];
    final ledger = ref.read(ledgerRepositoryProvider);
    final name = g?.group?.name ?? pending ?? '';

    final candidates = g == null || g.group == null
        ? const <Member>[]
        : [
            for (final m in g.activeMembers)
              if (m.isPlaceholder) m,
          ];
    final alreadyMe =
        g != null && profile != null && myMemberIn(g, profile.personId) != null;

    return Scaffold(
      appBar: screenAppBar(
        leading: BackArrow(close: true, onPressed: () => _finish(context)),
        title: const Text(S.claimTitle),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xl),
        children: [
          textGutter(
            Text(
              g?.group == null ? S.pendingGroupBody : S.claimBody(name),
              style: theme.textTheme.bodyLarge!.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          const SizedBox(height: Space.md),
          if (candidates.isNotEmpty && !alreadyMe)
            gutter(
              ListSection(
                dividerIndent: Space.avatarRowInset,
                children: [
                  for (final m in candidates)
                    KitListRow(
                      title: m.displayName,
                      subtitle: S.placeholderSub,
                      leading: PersonAvatar(
                        id: m.id,
                        name: m.displayName,
                        isPlaceholder: true,
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () async {
                        final ok = await runGuarded(
                          context,
                          () => ledger.claimMember(groupId, m.id),
                        );
                        if (ok && context.mounted) {
                          Haptics.medium(context);
                          showSnack(context, S.claimed(m.displayName));
                          _finish(context);
                        }
                      },
                    ),
                ],
              ),
            ),
          const SizedBox(height: Space.lg),
          if (g?.group != null && profile != null && !alreadyMe)
            gutter(
              FilledButton.tonal(
                onPressed: () => _addMe(context, ref, g!, profile),
                style: KitButtonStyles.block,
                child: const Text(S.notOnList),
              ),
            ),
          const SizedBox(height: Space.sm),
          Center(
            child: TextLink(S.claimLater, onPressed: () => _finish(context)),
          ),
        ],
      ),
    );
  }
}
