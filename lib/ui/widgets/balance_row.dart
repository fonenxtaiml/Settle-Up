import 'package:flutter/material.dart';

import '../../theme/tokens.dart';
import '../format/money_format.dart';
import 'kit_strings.dart';
import 'list_row.dart';
import 'money_text.dart';
import 'person_avatar.dart';

enum BalanceRowKind {
  /// A person on Home: avatar, "owes you" / "you owe" / "settled up".
  person,

  /// A group on Home: no leading tile, "you're owed" / "you owe".
  group,

  /// A group member in a group's balances: third person, "gets back" /
  /// "owes", in ink (it is not money moving to or from you).
  member,
}

/// Person, group or group-member row with the trailing balance block
/// (render 1). Uses the largest-|amount| currency and "+N more" for others.
/// Groups have names, people have faces: group rows never get a leading
/// tile.
class BalanceRow extends StatelessWidget {
  const BalanceRow({
    super.key,
    required this.kind,
    required this.id, // personId / groupId / memberId
    required this.title,
    required this.subtitle,
    required this.net,
    this.isMe = false,
    this.isPlaceholder = false,
    this.onTap,
    this.onLongPress,
  });

  final BalanceRowKind kind;
  final String id;
  final String title;
  final String subtitle;
  final Map<String, int> net; // + = owes you / you're owed / gets back
  final bool isMe; // member rows: you, as the filled avatar
  final bool isPlaceholder;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// The currency with the largest absolute balance (ties by code), or
  /// null when everything is zero.
  static MapEntry<String, int>? mainEntry(Map<String, int> net) {
    final nonZero = net.entries.where((e) => e.value != 0).toList()
      ..sort((a, b) {
        final c = b.value.abs().compareTo(a.value.abs());
        return c != 0 ? c : a.key.compareTo(b.key);
      });
    return nonZero.isEmpty ? null : nonZero.first;
  }

  static String wordFor(BalanceRowKind kind, int minor) {
    if (minor == 0) return KitStrings.settledUp;
    return switch (kind) {
      BalanceRowKind.person =>
        minor > 0 ? KitStrings.owesYou : KitStrings.youOwe,
      BalanceRowKind.group =>
        minor > 0 ? KitStrings.youreOwed : KitStrings.youOwe,
      BalanceRowKind.member =>
        minor > 0 ? KitStrings.getsBack : KitStrings.owes,
    };
  }

  @override
  Widget build(BuildContext context) {
    final main = mainEntry(net);
    final currency =
        main?.key ??
        (net.keys.isEmpty ? 'INR' : (net.keys.toList()..sort()).first);
    final minor = main?.value ?? 0;
    final others = net.entries
        .where((e) => e.value != 0 && e.key != main?.key)
        .length;
    final word = wordFor(kind, minor);
    final direction = minor == 0
        ? MoneyDirection.settled
        : kind == BalanceRowKind.member
        ? MoneyDirection.neutral
        : MoneyDirection.of(minor);
    final memberValue = kind == BalanceRowKind.member ? minor.abs() : minor;

    final trailing = BalanceTrailing(
      word: word,
      minor: memberValue,
      currency: currency,
      direction: direction,
      footnote: others > 0 ? KitStrings.moreCurrencies(others) : null,
    );

    final leading = kind == BalanceRowKind.group
        ? null
        : PersonAvatar(
            id: id,
            name: title,
            isMe: isMe,
            isPlaceholder: isPlaceholder,
          );

    final spoken = [
      title,
      subtitle,
      if (minor == 0) word else '$word ${MoneyFormat.spoken(minor, currency)}',
      if (others > 0) KitStrings.moreCurrencies(others),
      if (isPlaceholder) KitStrings.notOnSettleUp,
    ].join(', ');

    return Semantics(
      container: true,
      button: onTap != null,
      label: spoken,
      excludeSemantics: true,
      onTap: onTap,
      onLongPress: onLongPress,
      child: KitListRow(
        title: title,
        subtitle: subtitle,
        leading: leading,
        trailing: trailing,
        // Stack the balance under the name before the name loses its
        // longest word (VISUAL-R4-05), as ExpenseRow and ActivityRow do.
        trailingWidth: trailing.naturalWidth(context),
        leadingWidth: leading == null ? 0 : Sizes.avatar,
        onTap: onTap,
        onLongPress: onLongPress,
      ),
    );
  }
}
