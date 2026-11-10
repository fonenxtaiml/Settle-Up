// Person: where you stand with one friend overall and in each shared
// group, with Settle up per group, a 1:1 expense and a reminder.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:share_plus/share_plus.dart';

import '../../../core/balances.dart';
import '../../../core/ids.dart';
import '../../../theme/tokens.dart';
import '../../format/money_format.dart';
import '../../providers.dart';
import '../../router.dart';
import '../../strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';
import '../home/home_screen.dart' show personSubtitle;

class PersonScreen extends ConsumerWidget {
  const PersonScreen({super.key, required this.personId});

  final PersonId personId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final people = ref.watch(peopleBalancesProvider).value;
    final snap = ref.watch(ledgerProvider).value;
    final profile = ref.watch(profileProvider).value;
    final matches = people?.where((p) => p.personId == personId);
    final person = matches == null || matches.isEmpty ? null : matches.first;
    if (person == null || snap == null || profile == null) {
      return Scaffold(
        appBar: screenAppBar(
          leading: const BackArrow(),
          title: const SizedBox(),
        ),
        body: const SizedBox.shrink(),
      );
    }
    final me = profile.personId;
    final first = firstName(person.displayName);
    final main = BalanceRow.mainEntry(person.net);
    final currency = main?.key ?? profile.homeCurrency;
    final total = main?.value ?? 0;
    final label = total > 0
        ? S.personOwesYou(first)
        : total < 0
        ? S.youOwePerson(first)
        : S.settledWith(first);

    // Per group: my pair balance with them, from the suggested payments.
    final rows = <_PairRow>[];
    for (final gid in person.groupIds) {
      final g = snap.state.groups[gid];
      if (g == null || g.group == null) continue;
      final mine = myMemberIn(g, me);
      final theirs = g.memberForPerson(personId);
      if (mine == null || theirs == null) continue;
      final other = g.resolve(theirs.id);
      final net = <String, int>{};
      for (final t in BalanceCalculator.suggestedTransfers(g)) {
        if (t.from == mine && t.to == other) {
          net[t.currency] = (net[t.currency] ?? 0) - t.amount;
        } else if (t.from == other && t.to == mine) {
          net[t.currency] = (net[t.currency] ?? 0) + t.amount;
        }
      }
      net.removeWhere((_, v) => v == 0);
      rows.add(
        _PairRow(
          groupId: gid,
          name: g.group!.isDirect ? S.justYouTwo : g.group!.name,
          net: net.isEmpty ? {g.group!.currency: 0} : net,
          mine: net.isEmpty ? null : mine,
          other: net.isEmpty ? null : other,
        ),
      );
    }
    final settleTarget = rows.where((r) => r.mine != null).toList();
    // Prefer the group carrying the hero's currency.
    final heroTarget = settleTarget.where((r) => (r.net[currency] ?? 0) != 0);

    return Scaffold(
      appBar: screenAppBar(
        leading: const BackArrow(),
        title: AppBarTitle(
          person.displayName,
          subtitle: personSubtitle(person, snap.state),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xxl),
        children: [
          textGutter(
            GroupBalanceHero(minor: total, currency: currency, label: label),
          ),
          const SizedBox(height: 14),
          textGutter(
            ButtonPair(
              labels: const [S.settleUp, S.addExpense],
              first: FilledButton(
                onPressed: settleTarget.isEmpty
                    ? null
                    : () => context.push(
                        heroTarget.isNotEmpty
                            ? heroTarget.first.settleRoute(currency)
                            : settleTarget.first.settleRoute(),
                      ),
                child: const Text(S.settleUp),
              ),
              second: FilledButton.tonal(
                onPressed: () =>
                    context.push(Routes.newExpense(personId: personId)),
                child: const Text(S.addExpense),
              ),
            ),
          ),
          gutter(
            ListSection(
              title: S.inGroups,
              children: [
                for (final r in rows)
                  KitListRow(
                    title: r.name,
                    trailing: _trailing(r.net),
                    // Stack the balance before the group name loses its
                    // longest word (VISUAL-R4-05).
                    trailingWidth: _trailing(r.net).naturalWidth(context),
                    onTap: () => r.mine == null
                        ? context.push(Routes.group(r.groupId))
                        : context.push(r.settleRoute()),
                  ),
              ],
            ),
          ),
          if (total > 0)
            gutter(
              Padding(
                padding: const EdgeInsets.only(top: Space.md),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: TextLink(
                    S.remind,
                    onPressed: () => SharePlus.instance.share(
                      ShareParams(
                        text: S.remindText(
                          first,
                          MoneyFormat.format(total, currency),
                          rows
                              .where((r) => (r.net[currency] ?? 0) > 0)
                              .map((r) => r.name)
                              .join(', '),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static BalanceTrailing _trailing(Map<String, int> net) {
    final main = BalanceRow.mainEntry(net);
    final currency = main?.key ?? net.keys.first;
    final v = main?.value ?? 0;
    return BalanceTrailing(
      word: BalanceRow.wordFor(BalanceRowKind.person, v),
      minor: v,
      currency: currency,
    );
  }
}

/// My pair balance with the person in one group, per currency.
class _PairRow {
  const _PairRow({
    required this.groupId,
    required this.name,
    required this.net,
    required this.mine,
    required this.other,
  });

  final GroupId groupId;
  final String name;
  final Map<String, int> net;
  final MemberId? mine;
  final MemberId? other;

  /// Settle up in [currency] (or the only one), in that currency's
  /// direction. With several currencies and no pick, the settle screen asks.
  String settleRoute([String? currency]) {
    final cur = currency ?? (net.length == 1 ? net.keys.first : null);
    final v = cur == null ? null : net[cur];
    final iPay = v == null || v < 0;
    return Routes.settle(
      groupId: groupId,
      from: iPay ? mine : other,
      to: iPay ? other : mine,
      currency: cur,
    );
  }
}
