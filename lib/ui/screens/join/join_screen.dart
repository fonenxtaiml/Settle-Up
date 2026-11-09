// settleup://join deep link: who invited you to which group, and Join.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../sync/pairing/links.dart';
import '../../../theme/tokens.dart';
import '../../strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';
import '../sync/scan_screen.dart';

class JoinScreen extends ConsumerStatefulWidget {
  const JoinScreen({super.key, required this.link});

  final String link;

  @override
  ConsumerState<JoinScreen> createState() => _JoinScreenState();
}

class _JoinScreenState extends ConsumerState<JoinScreen> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final invite = InviteLink.tryParse(widget.link);
    return Scaffold(
      appBar: screenAppBar(
        leading: const BackArrow(close: true),
        title: const Text(S.joinTitle),
      ),
      bottomNavigationBar: invite == null
          ? null
          : SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                child: FilledButton(
                  onPressed: _busy
                      ? null
                      : () async {
                          setState(() => _busy = true);
                          await handleSettleUpLink(context, ref, widget.link);
                          if (mounted) setState(() => _busy = false);
                        },
                  style: KitButtonStyles.block,
                  child: Text(_busy ? S.joining : S.joinAction),
                ),
              ),
            ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: Space.text),
        children: [
          const SizedBox(height: Space.lg),
          if (invite == null)
            Text(S.badInvite, style: theme.textTheme.bodyLarge)
          else ...[
            const Align(
              alignment: Alignment.centerLeft,
              child: TetherTransfer(
                fromId: 'inviter',
                fromName: 'Friend',
                toId: 'me',
                toName: 'You',
                toIsMe: true,
                lineLength: 96,
              ),
            ),
            const SizedBox(height: Space.xl),
            Text(invite.groupName, style: theme.textTheme.headlineMedium),
            const SizedBox(height: Space.sm),
            Text(
              S.joinBody(
                invite.fromName.isEmpty ? S.someone : invite.fromName,
                invite.groupName,
              ),
              style: theme.textTheme.bodyLarge!.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
  }
}
