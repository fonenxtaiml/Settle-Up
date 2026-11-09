// Invite to a group: a full-screen QR carrying the group and its key. It
// hides itself after 2 minutes to keep the group private.
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/ids.dart';
import '../../../theme/tokens.dart';
import '../../format/dates.dart';
import '../../providers.dart';
import '../../strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';

const Duration inviteVisibleFor = Duration(minutes: 2);

class InviteScreen extends ConsumerStatefulWidget {
  const InviteScreen({super.key, required this.groupId});

  final GroupId groupId;

  @override
  ConsumerState<InviteScreen> createState() => _InviteScreenState();
}

class _InviteScreenState extends ConsumerState<InviteScreen>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker = createTicker((_) => _tick());
  String? _link;
  DateTime? _hideAt;
  int _left = 0;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _show();
  }

  Future<void> _show() async {
    setState(() {
      _error = null;
      _link = null;
      _loading = true;
    });
    try {
      final link = await ref
          .read(syncEngineProvider)
          .inviteLinkFor(widget.groupId);
      if (!mounted) return;
      setState(() {
        _link = link;
        _hideAt = ref.read(clockProvider)().add(inviteVisibleFor);
        _left = inviteVisibleFor.inSeconds;
        _loading = false;
      });
      if (!_ticker.isActive) _ticker.start();
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _error = e;
          _loading = false;
        });
      }
    }
  }

  void _tick() {
    final hideAt = _hideAt;
    if (hideAt == null) return;
    final left = hideAt.difference(ref.read(clockProvider)()).inSeconds;
    if (left <= 0) {
      _ticker.stop();
      setState(() {
        _link = null;
        _hideAt = null;
        _left = 0;
      });
    } else if (left != _left) {
      setState(() => _left = left);
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ink2 = theme.colorScheme.onSurfaceVariant;
    final g = ref.watch(groupProvider(widget.groupId)).value?.group;
    final name = g?.name ?? '';
    final link = _link;
    return Scaffold(
      appBar: screenAppBar(
        leading: const BackArrow(close: true),
        title: Text(S.inviteTitle(name)),
      ),
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: Space.text),
        children: [
          Text(
            S.inviteBody,
            style: theme.textTheme.bodyLarge!.copyWith(color: ink2),
          ),
          const SizedBox(height: Space.xl),
          if (_error != null)
            Text(errorMessage(_error!), style: theme.textTheme.bodyLarge)
          else if (link != null) ...[
            Center(
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(Radii.lg),
                ),
                child: Semantics(
                  image: true,
                  label: S.inviteQrLabel,
                  child: QrImageView(
                    data: link,
                    size: 248,
                    padding: EdgeInsets.zero,
                    eyeStyle: const QrEyeStyle(
                      eyeShape: QrEyeShape.square,
                      color: Color(0xFF16191D),
                    ),
                    dataModuleStyle: const QrDataModuleStyle(
                      dataModuleShape: QrDataModuleShape.square,
                      color: Color(0xFF16191D),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: Space.lg),
            Text(
              S.inviteHides(DateLabels.countdown(Duration(seconds: _left))),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium!.copyWith(color: ink2),
            ),
            const SizedBox(height: Space.md),
            Center(
              child: TextLink(
                S.shareLink,
                onPressed: () => SharePlus.instance.share(
                  ShareParams(text: S.inviteShareText(name, link)),
                ),
              ),
            ),
          ] else if (!_loading) ...[
            Text(S.inviteHidden, style: theme.textTheme.bodyLarge),
            const SizedBox(height: Space.lg),
            FilledButton(
              onPressed: _show,
              style: KitButtonStyles.block,
              child: const Text(S.showAgain),
            ),
          ],
        ],
      ),
    );
  }
}
