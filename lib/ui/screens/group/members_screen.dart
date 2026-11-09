// Members: invite by QR, add people by name, and per person rename,
// "This is me", merge and remove.
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
import '../pickers.dart';

enum _Action { rename, claim, merge, remove }

class MembersScreen extends ConsumerStatefulWidget {
  const MembersScreen({super.key, required this.groupId});

  final GroupId groupId;

  @override
  ConsumerState<MembersScreen> createState() => _MembersScreenState();
}

class _MembersScreenState extends ConsumerState<MembersScreen> {
  final _name = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _add() async {
    final n = _name.text.trim();
    if (n.isEmpty) return;
    final ok = await runGuarded(
      context,
      () => ref
          .read(ledgerRepositoryProvider)
          .addMember(widget.groupId, displayName: n),
    );
    if (ok && mounted) {
      _name.clear();
      setState(() {});
      showSnack(context, S.memberAdded);
    }
  }

  Future<void> _actions(GroupState g, Member m, MemberId? myId) async {
    final ledger = ref.read(ledgerRepositoryProvider);
    final isMe = m.id == myId;
    final action = await pickOption<_Action>(
      context,
      title: isMe ? S.you : m.displayName,
      selected: null,
      options: [
        (_Action.rename, S.rename),
        if (!isMe && myId == null && m.isPlaceholder)
          (_Action.claim, S.thisIsMe),
        if (!isMe) (_Action.merge, S.mergeInto),
        if (!isMe) (_Action.remove, S.remove),
      ],
    );
    if (action == null || !mounted) return;
    switch (action) {
      case _Action.rename:
        final name = await promptText(
          context,
          title: S.renameTitle,
          initial: m.displayName,
        );
        if (name != null && mounted) {
          await runGuarded(
            context,
            () => ledger.renameMember(g.groupId, m.id, name),
          );
        }
      case _Action.claim:
        await runGuarded(context, () => ledger.claimMember(g.groupId, m.id));
      case _Action.merge:
        final into = await pickOption<MemberId>(
          context,
          title: S.mergeTitle(m.displayName),
          subtitle: S.mergeBody(m.displayName),
          selected: null,
          options: [
            for (final o in g.activeMembers)
              if (o.id != m.id) (o.id, o.id == myId ? S.you : o.displayName),
          ],
        );
        if (into != null && mounted) {
          await runGuarded(
            context,
            () => ledger.mergeMembers(g.groupId, from: m.id, into: into),
          );
        }
      case _Action.remove:
        final yes = await confirmAction(
          context,
          title: S.removeTitle(m.displayName),
          body: S.removeBody,
          confirmLabel: S.remove,
        );
        if (yes && mounted) {
          await runGuarded(context, () => ledger.removeMember(g.groupId, m.id));
        }
    }
  }

  @override
  Widget build(BuildContext context) {
    final g = ref.watch(groupProvider(widget.groupId)).value;
    final profile = ref.watch(profileProvider).value;
    if (g == null || g.group == null || profile == null) {
      return Scaffold(
        appBar: screenAppBar(
          leading: const BackArrow(),
          title: const Text(S.membersTitle),
        ),
      );
    }
    final myId = myMemberIn(g, profile.personId);
    final members = [...g.activeMembers]
      ..sort((a, b) => (a.id == myId ? 0 : 1).compareTo(b.id == myId ? 0 : 1));
    return Scaffold(
      appBar: screenAppBar(
        leading: const BackArrow(),
        title: AppBarTitle(S.membersTitle, subtitle: g.group!.name),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xl),
        children: [
          const SizedBox(height: Space.sm),
          if (!g.group!.isDirect)
            gutter(
              ListSection(
                children: [
                  KitListRow(
                    title: S.inviteByQr,
                    subtitle: S.inviteByQrBody,
                    leading: const SizedBox.square(
                      dimension: Sizes.avatar,
                      child: Icon(Icons.qr_code_2_rounded),
                    ),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => context.push(Routes.invite(widget.groupId)),
                  ),
                ],
              ),
            ),
          gutter(
            ListSection(
              title: S.people(members.length),
              dividerIndent: Space.avatarRowInset,
              children: [
                for (final m in members)
                  KitListRow(
                    title: m.id == myId ? S.you : m.displayName,
                    subtitle: m.id == myId
                        ? S.youSub
                        : m.isPlaceholder
                        ? S.placeholderSub
                        : S.onSettleUp,
                    leading: PersonAvatar(
                      id: m.id,
                      name: m.id == myId ? profile.displayName : m.displayName,
                      isMe: m.id == myId,
                      isPlaceholder: m.isPlaceholder && m.id != myId,
                    ),
                    trailing: const Icon(Icons.more_horiz_rounded),
                    onTap: () => _actions(g, m, myId),
                  ),
              ],
            ),
          ),
          gutter(const SectionHeading(S.addMember)),
          gutter(
            LabeledTextField(
              label: S.personName,
              hintText: S.personNameHint,
              controller: _name,
              textInputAction: TextInputAction.done,
              onSubmitted: (_) => _add(),
              onChanged: (_) => setState(() {}),
              trailing: FilledButton.tonal(
                onPressed: _name.text.trim().isEmpty ? null : _add,
                style: KitButtonStyles.small(context),
                child: const Text(S.addPerson),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
