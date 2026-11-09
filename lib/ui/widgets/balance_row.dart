import 'package:flutter/material.dart';

import '../../theme/app_theme.dart';
import '../../theme/tokens.dart';
import '../format/money_format.dart';
import 'kit_strings.dart';
import 'money_text.dart';
import 'person_avatar.dart';
import 'row_layout.dart';

enum BalanceRowKind { person, group, member }

/// Person / group / group-member row with signed amount + direction word
/// (DESIGN 5.2). Uses the largest-|amount| currency, "+N more" for others.
class BalanceRow extends StatelessWidget {
  const BalanceRow({
    super.key,
    required this.kind,
    required this.id, // personId / groupId / memberId (avatar tone seed)
    required this.title,
    required this.subtitle,
    required this.net,
    this.emoji,
    this.isPlaceholder = false,
    this.onTap,
    this.onLongPress,
  });

  final BalanceRowKind kind;
  final String id;
  final String title;
  final String subtitle;
  final Map<String, int> net; // + = owes you / you're owed / gets back
  final String? emoji;
  final bool isPlaceholder;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// The currency shown on the row: largest |amount|, ties by code.
  static MapEntry<String, int>? leadingEntry(Map<String, int> net) {
    MapEntry<String, int>? best;
    for (final e in net.entries) {
      if (e.value == 0) continue;
      if (best == null ||
          e.value.abs() > best.value.abs() ||
          (e.value.abs() == best.value.abs() &&
              e.key.compareTo(best.key) < 0)) {
        best = e;
      }
    }
    return best;
  }

  /// Fixed direction word for [kind] and the sign of [minor] (DESIGN 7.2).
  static String directionWord(BalanceRowKind kind, int minor) {
    if (minor == 0) return KitStrings.even;
    final positive = minor > 0;
    return switch (kind) {
      BalanceRowKind.person =>
        positive ? KitStrings.owesYou : KitStrings.youOwe,
      BalanceRowKind.group =>
        positive ? KitStrings.youreOwed : KitStrings.youOwe,
      BalanceRowKind.member => positive ? KitStrings.getsBack : KitStrings.owes,
    };
  }

  String _semantics(MapEntry<String, int>? lead, int more) {
    final parts = <String>[title];
    if (lead == null) {
      parts.add(KitStrings.even);
    } else {
      final amount = MoneyFormat.spoken(lead.value, lead.key);
      final positive = lead.value > 0;
      parts.add(switch (kind) {
        BalanceRowKind.person =>
          positive ? 'owes you $amount' : 'you owe $amount',
        BalanceRowKind.group =>
          positive ? "you're owed $amount" : 'you owe $amount',
        BalanceRowKind.member =>
          positive ? 'gets back $amount' : 'owes $amount',
      });
      if (more > 0) parts.add(KitStrings.moreCurrencies(more));
    }
    if (subtitle.isNotEmpty) parts.add(subtitle);
    if (isPlaceholder) parts.add(KitStrings.notOnSettleUp);
    return parts.join(', ');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final money = context.money;
    final lead = leadingEntry(net);
    final more = net.entries
        .where((e) => e.value != 0 && e.key != lead?.key)
        .length;

    final leading = kind == BalanceRowKind.group
        ? GroupGlyph(id: id, name: title, emoji: emoji)
        : PersonAvatar(id: id, name: title, isPlaceholder: isPlaceholder);

    final Widget trailing;
    if (lead == null) {
      trailing = Text(
        KitStrings.even,
        style: theme.textTheme.labelLarge!.copyWith(color: money.settled),
      );
    } else {
      trailing = TrailingColumn(
        children: [
          MoneyText(minor: lead.value, currency: lead.key),
          Text(
            directionWord(kind, lead.value),
            style: MoneyStyles.direction(context, lead.value),
          ),
          if (more > 0)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                KitStrings.moreCurrencies(more),
                style: theme.textTheme.bodySmall!.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
        ],
      );
    }

    return Semantics(
      label: _semantics(lead, more),
      button: onTap != null,
      onTap: onTap,
      onLongPress: onLongPress,
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: KitRow(
          leading: leading,
          title: Text(
            title,
            style: theme.textTheme.titleMedium,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: Text(
            subtitle,
            style: theme.textTheme.bodyMedium!.copyWith(
              color: scheme.onSurfaceVariant,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          trailing: trailing,
          minHeight: Sizes.rowMin2,
        ),
      ),
    );
  }
}
