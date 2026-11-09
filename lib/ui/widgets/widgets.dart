// FROZEN CONTRACT (docs/SPEC.md section 5.15). Owner: ui-kit.
// Public constructors of the design-system widgets (DESIGN.md section 5).
// ui-kit implements the build() methods (one file per widget, exported
// from this barrel); ui-screens only uses these constructors.
import 'package:flutter/material.dart';

import '../../core/ids.dart';
import '../../core/models.dart';

/// Level vial (DESIGN 5.1). position in -1..1 (owe .. owed), already eased
/// by the caller via LevelVial.positionFor().
class LevelVial extends StatelessWidget {
  const LevelVial({
    super.key,
    required this.position,
    this.height = 16,
    this.showEndLabels = true,
    this.settled = false,
    this.animate = true,
  });

  final double position;
  final double height;
  final bool showEndLabels;
  final bool settled; // thick center marks + owedContainer fill
  final bool animate; // spring to new position (respects reduced motion)

  /// x = (owedToMe - iOwe) / max(owedToMe + iOwe, 1), clamped, sign*sqrt.
  static double positionFor({required int owedToMe, required int iOwe}) =>
      throw UnimplementedError();

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Overall/group balance hero (DESIGN 5.1).
class BalanceHero extends StatelessWidget {
  const BalanceHero({
    super.key,
    required this.net,
    required this.owedToMe,
    required this.iOwe,
    required this.mainCurrency,
    this.onTap,
  });

  final Map<String, int> net; // currency -> minor
  final Map<String, int> owedToMe;
  final Map<String, int> iOwe;
  final String mainCurrency; // drives the vial
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

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

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Expense or payment row (DESIGN 5.3).
class ExpenseRow extends StatelessWidget {
  const ExpenseRow({
    super.key,
    required this.expense,
    required this.memberNames, // MemberId -> display name ("You" for me)
    required this.myMemberId,
    this.unshared = false,
    this.deleted = false,
    this.onTap,
    this.onRestore,
  });

  final Expense expense;
  final Map<MemberId, String> memberNames;
  final MemberId? myMemberId;
  final bool unshared;
  final bool deleted;
  final VoidCallback? onTap;
  final VoidCallback? onRestore;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Custom numeric keypad with live display (DESIGN 5.4).
class AmountKeypad extends StatelessWidget {
  const AmountKeypad({
    super.key,
    required this.currency,
    required this.valueMinor,
    required this.onChanged,
    this.onCurrencyTap,
    this.showDisplay = true,
  });

  final String currency;
  final int valueMinor;
  final ValueChanged<int> onChanged; // capped at Money.maxMinor
  final VoidCallback? onCurrencyTap;
  final bool showDisplay;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Equally / Amounts / Percent / Shares segmented control (DESIGN 5.5).
/// Adjustment is reachable from the split editor's overflow, not a segment.
class SplitMethodSelector extends StatelessWidget {
  const SplitMethodSelector({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final SplitMethod value;
  final ValueChanged<SplitMethod> onChanged;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Remainder bar + sentence under the split selector (DESIGN 5.5).
class RemainderBar extends StatelessWidget {
  const RemainderBar({
    super.key,
    required this.method,
    required this.targetUnits,
    required this.assignedUnits,
    required this.currency,
  });

  final SplitMethod method; // percent -> units are basis points
  final int targetUnits;
  final int assignedUnits;
  final String currency;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Initials avatar with stable tone (DESIGN 5.6). Sizes 24/32/40/56.
class PersonAvatar extends StatelessWidget {
  const PersonAvatar({
    super.key,
    required this.id,
    required this.name,
    this.size = 40,
    this.isPlaceholder = false,
  });

  final String id;
  final String name;
  final double size;
  final bool isPlaceholder; // dashed ring

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Category glyph disc (DESIGN 5.3); maps Categories ids to icons.
class CategoryGlyph extends StatelessWidget {
  const CategoryGlyph({super.key, required this.categoryId, this.size = 40});

  final String categoryId;
  final double size;

  static IconData iconFor(String categoryId) => throw UnimplementedError();

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Empty state with static vial (DESIGN 5.7).
class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.headline,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  final String headline;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

enum SyncChipState { neverSynced, allShared, changesWaiting, inProgress, failed }

/// App-bar sync chip (DESIGN 5.8). Never says "offline".
class SyncStatusChip extends StatelessWidget {
  const SyncStatusChip({
    super.key,
    required this.state,
    this.pendingCount = 0,
    this.lastSyncedAt,
    this.peerName,
    this.onTap,
  });

  final SyncChipState state;
  final int pendingCount;
  final DateTime? lastSyncedAt;
  final String? peerName;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

/// Signed, formatted, tabular amount + optional direction word.
class MoneyText extends StatelessWidget {
  const MoneyText({
    super.key,
    required this.minor,
    required this.currency,
    this.style = MoneyTextStyle.row,
    this.signed = true,
    this.colored = true,
  });

  final int minor;
  final String currency;
  final MoneyTextStyle style;
  final bool signed;
  final bool colored;

  @override
  Widget build(BuildContext context) => throw UnimplementedError();
}

enum MoneyTextStyle { hero, row, keypad, inline }
