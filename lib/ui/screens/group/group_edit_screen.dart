// New group / edit group: name, type, currency, emoji, simplify debts and,
// for a new group, the people in it.
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/ids.dart';
import '../../../core/models.dart';
import '../../../core/money.dart';
import '../../../data/repositories.dart';
import '../../../theme/tokens.dart';
import '../../providers.dart';
import '../../router.dart';
import '../../strings.dart';
import '../../widgets/widgets.dart';
import '../common.dart';
import '../pickers.dart';

const List<String> _emojis = ['🏖️', '🏠', '❤️', '🍽️', '🎉', '⛺', '✈️'];

String groupTypeLabel(GroupType t) => switch (t) {
  GroupType.trip => S.typeTrip,
  GroupType.home => S.typeHome,
  GroupType.couple => S.typeCouple,
  _ => S.typeOther,
};

class GroupEditScreen extends ConsumerStatefulWidget {
  const GroupEditScreen({super.key, this.groupId});

  /// Null creates a new group.
  final GroupId? groupId;

  @override
  ConsumerState<GroupEditScreen> createState() => _GroupEditScreenState();
}

class _GroupEditScreenState extends ConsumerState<GroupEditScreen> {
  final _name = TextEditingController();
  final _person = TextEditingController();
  GroupType _type = GroupType.trip;
  String? _currency;
  String? _emoji;
  bool? _simplify;
  final List<String> _newNames = [];
  final Set<PersonId> _existing = {};
  bool _loaded = false;
  bool _tried = false;
  bool _saving = false;

  /// The group as it was when the form was loaded. Save compares the form
  /// with these, not with the live group, so a field the user never
  /// touched is sent as null (left alone) even when sync brought another
  /// phone's change to it while the form was open (UIFLOW-R17-01).
  Group? _loadedGroup;
  GroupType? _loadedType;

  bool get _isNew => widget.groupId == null;

  @override
  void dispose() {
    _name.dispose();
    _person.dispose();
    super.dispose();
  }

  void _load(Group? g) {
    if (_loaded) return;
    _loaded = true;
    if (g == null) return;
    _loadedGroup = g;
    _name.text = g.name;
    _type = g.type == GroupType.direct ? GroupType.other : g.type;
    _loadedType = _type;
    _currency = g.currency;
    _emoji = g.emoji;
    _simplify = g.simplifyDebts;
  }

  /// "Priya is already in this group" when the typed name repeats one.
  String? _personError;

  /// Adds the typed person; false when the name is already in the list.
  bool _addPerson([Map<PersonId, String> people = const {}]) {
    final n = _person.text.trim();
    if (n.isEmpty) return true;
    final notName = nameInputError(n, limit: kMemberNameMax);
    if (notName != null) {
      setState(() => _personError = notName);
      return false;
    }
    // You are a member of every new group too (Members refuses your name
    // for the same reason).
    final me = ref.read(profileProvider).value?.displayName;
    final dup = duplicateName(n, [
      ?me,
      ..._newNames,
      for (final p in _existing) ?people[p],
    ]);
    if (dup != null) {
      setState(() => _personError = S.alreadyInGroup(dup));
      return false;
    }
    setState(() {
      _newNames.add(n);
      _person.clear();
      _personError = null;
    });
    return true;
  }

  /// Whether the name field still holds the name the form was loaded
  /// with. A name this phone already holds never blocks a change to
  /// anything else (UIFLOW-R8-02 for profile names, UIFLOW-R15-01): one an
  /// older phone or an earlier build gave the group may have no letter or
  /// number, or be longer than [kGroupNameMax], and is kept as it is
  /// unless the user edits it. Only a name the user types is checked. The
  /// loaded name, not the live one, is the reference: a rename another
  /// phone made while the form was open is not undone (UIFLOW-R17-01).
  bool get _nameKept {
    final loaded = _loadedGroup;
    return loaded != null && _name.text.trim() == loaded.name.trim();
  }

  Future<void> _save(Map<PersonId, String> people) async {
    setState(() => _tried = true);
    final name = _name.text.trim();
    final kept = !_isNew && _nameKept;
    if ((!kept && !isSavableName(name, kGroupNameMax)) || _saving) {
      Haptics.invalid(context);
      return;
    }
    // A name still in the field joins the list; one that repeats a name
    // already there is that person, so it is not added twice.
    if (_isNew && _person.text.trim().isNotEmpty && !_addPerson(people)) {
      _person.clear();
      _personError = null;
    }
    setState(() => _saving = true);
    final ledger = ref.read(ledgerRepositoryProvider);
    final profile = ref.read(profileProvider).value!;
    final settings = ref.read(appSettingsProvider).value ?? const AppSettings();
    final currency = _currency ?? profile.homeCurrency;
    GroupId? created;
    final ok = await runGuarded(context, () async {
      if (_isNew) {
        created = await ledger.createGroup(
          NewGroup(
            name: name,
            type: _type,
            currency: currency,
            emoji: _emoji,
            simplifyDebts: _simplify ?? settings.simplifyByDefault,
            newMemberNames: List.of(_newNames),
            existingPeople: [
              for (final p in _existing)
                (personId: p, displayName: people[p] ?? S.someone),
            ],
          ),
        );
      } else {
        // Each field is compared with the value the form was loaded with
        // (UIFLOW-R17-01): only what the user changed is sent.
        final o = _loadedGroup!;
        await ledger.updateGroup(
          widget.groupId!,
          GroupPatch(
            name: kept ? null : name,
            type: _type == _loadedType ? null : _type,
            currency: currency == o.currency ? null : currency,
            emoji: _emoji == o.emoji ? null : (_emoji ?? ''),
            simplifyDebts: _simplify == null || _simplify == o.simplifyDebts
                ? null
                : _simplify,
          ),
        );
      }
    });
    if (!mounted) return;
    setState(() => _saving = false);
    if (!ok) return;
    Haptics.medium(context);
    if (created != null) {
      showSnack(context, S.groupCreated);
      context.pushReplacement(Routes.group(created!));
    } else {
      showSnack(context, S.groupSaved);
      context.pop();
    }
  }

  Future<void> _archive(Group g) async {
    final ok = await runGuarded(
      context,
      () => ref
          .read(ledgerRepositoryProvider)
          .updateGroup(g.id, GroupPatch(archived: !g.archived)),
    );
    if (ok && mounted) {
      showSnack(context, g.archived ? S.groupSaved : S.groupArchived);
      context.pop();
    }
  }

  Future<void> _delete(Group g, int expenses) async {
    final yes = await confirmAction(
      context,
      title: S.deleteGroupTitle(g.name),
      body: S.deleteGroupBody(expenses),
      confirmLabel: S.delete,
    );
    if (!yes || !mounted) return;
    final ok = await runGuarded(
      context,
      () => ref.read(ledgerRepositoryProvider).deleteGroup(g.id),
    );
    if (ok && mounted) {
      showSnack(context, S.groupDeleted);
      context.go(Routes.home);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final profile = ref.watch(profileProvider).value;
    final snap = ref.watch(ledgerProvider).value;
    final gs = widget.groupId == null
        ? null
        : snap?.state.groups[widget.groupId];
    final original = gs?.group;
    if (profile == null || snap == null || (!_isNew && original == null)) {
      return Scaffold(
        appBar: screenAppBar(
          leading: const BackArrow(close: true),
          title: const Text(S.editGroupTitle),
        ),
      );
    }
    _load(original);
    final me = profile.personId;
    final people = <PersonId, String>{
      for (final g in snap.state.visibleGroups)
        for (final m in g.activeMembers)
          if (m.personId != me) m.personId: m.displayName,
    };
    final sortedPeople = people.entries.toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    final currency = Currencies.of(_currency ?? profile.homeCurrency);
    final simplify =
        _simplify ??
        (ref.watch(appSettingsProvider).value ?? const AppSettings())
            .simplifyByDefault;
    final ink2 = theme.colorScheme.onSurfaceVariant;

    return Scaffold(
      appBar: screenAppBar(
        leading: const BackArrow(close: true),
        title: Text(_isNew ? S.newGroupTitle : S.editGroupTitle),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: FilledButton(
            onPressed: _saving ? null : () => _save(people),
            style: KitButtonStyles.block,
            child: Text(_isNew ? S.createGroupAction : S.saveChanges),
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.only(bottom: Space.xl),
        children: [
          const SizedBox(height: Space.sm),
          gutter(
            LabeledTextField(
              label: S.groupName,
              hintText: S.groupNameHint,
              controller: _name,
              maxLength: kGroupNameMax,
              inputFormatters: nameFormatters(kGroupNameMax),
              errorText: _name.text.trim().isEmpty
                  ? (_tried ? S.nameNeeded : null)
                  : _nameKept
                  ? null
                  : nameInputError(_name.text, limit: kGroupNameMax),
              onChanged: (_) => setState(() {}),
            ),
          ),
          gutter(const SectionHeading(S.groupType)),
          gutter(
            _GroupTypePicker(
              value: _type,
              onChanged: (t) => setState(() => _type = t),
            ),
          ),
          const SizedBox(height: Space.md),
          gutter(
            PickerTile(
              label: S.currency,
              value: '${currency.name} (${currency.code})',
              leading: SymbolText(
                currency.symbol,
                style: theme.textTheme.titleMedium,
                maxWidth: SymbolText.maxLeadingWidth(context),
              ),
              onTap: () async {
                final code = await pickCurrency(
                  context,
                  selected: currency.code,
                  pinned: [profile.homeCurrency],
                );
                if (code != null) setState(() => _currency = code);
              },
            ),
          ),
          const SizedBox(height: Space.md),
          gutter(
            ListSection(
              children: [
                KitListRow(
                  title: S.emoji,
                  minHeight: Sizes.rowMinDense,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _emoji == null || _emoji!.isEmpty ? S.noEmoji : _emoji!,
                        style: theme.textTheme.bodyLarge!.copyWith(color: ink2),
                      ),
                      const SizedBox(width: Space.xs),
                      Icon(Icons.chevron_right_rounded, color: ink2),
                    ],
                  ),
                  onTap: () async {
                    final e = await pickOption<String>(
                      context,
                      title: S.emoji,
                      selected: _emoji ?? '',
                      options: [
                        ('', S.noEmoji),
                        for (final e in _emojis) (e, e),
                      ],
                    );
                    if (e == null) return;
                    setState(() => _emoji = e.isEmpty ? null : e);
                  },
                ),
                MergeSemantics(
                  child: KitListRow(
                    title: S.simplifyDebts,
                    subtitle: simplify ? S.simplifyHelpOn : S.simplifyHelpOff,
                    trailing: Switch(
                      value: simplify,
                      onChanged: (v) => setState(() => _simplify = v),
                    ),
                    onTap: () => setState(() => _simplify = !simplify),
                  ),
                ),
              ],
            ),
          ),
          if (_isNew) ...[
            gutter(const SectionHeading(S.addPeople)),
            textGutter(
              Text(
                S.youAreIncluded,
                style: theme.textTheme.bodySmall!.copyWith(color: ink2),
              ),
            ),
            const SizedBox(height: Space.sm),
            gutter(
              LabeledTextField(
                label: S.personName,
                hintText: S.personNameHint,
                controller: _person,
                maxLength: kMemberNameMax,
                inputFormatters: nameFormatters(kMemberNameMax),
                errorText: _personError,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _addPerson(people),
                onChanged: (_) => setState(() => _personError = null),
                trailing: FilledButton.tonal(
                  onPressed: !isSavableName(_person.text, kMemberNameMax)
                      ? null
                      : () => _addPerson(people),
                  style: KitButtonStyles.small(context),
                  child: const Text(S.addPerson),
                ),
              ),
            ),
            if (_newNames.isNotEmpty)
              gutter(
                Padding(
                  padding: const EdgeInsets.only(top: Space.sm),
                  child: Wrap(
                    spacing: Space.sm,
                    runSpacing: Space.xs,
                    children: [
                      for (final (i, n) in _newNames.indexed)
                        InputChip(
                          label: Text(n),
                          avatar: PersonAvatar(id: 'new-$i', name: n, size: 24),
                          onDeleted: () =>
                              setState(() => _newNames.removeAt(i)),
                        ),
                    ],
                  ),
                ),
              ),
            if (sortedPeople.isNotEmpty) ...[
              gutter(const SectionHeading(S.fromYourGroups)),
              gutter(
                Wrap(
                  spacing: Space.sm,
                  runSpacing: Space.xs,
                  children: [
                    for (final p in sortedPeople)
                      FilterChip(
                        label: Text(p.value),
                        selected: _existing.contains(p.key),
                        onSelected: (v) => setState(() {
                          if (v) {
                            _existing.add(p.key);
                          } else {
                            _existing.remove(p.key);
                          }
                        }),
                      ),
                  ],
                ),
              ),
            ],
          ] else ...[
            const SizedBox(height: Space.md),
            gutter(
              ListSection(
                children: [
                  KitListRow(
                    title: S.members,
                    minHeight: Sizes.rowMinDense,
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () => context.push(Routes.members(widget.groupId!)),
                  ),
                  KitListRow(
                    title: original!.archived
                        ? S.unarchiveGroup
                        : S.archiveGroup,
                    minHeight: Sizes.rowMinDense,
                    onTap: () => _archive(original),
                  ),
                  KitListRow(
                    title: S.deleteGroup,
                    minHeight: Sizes.rowMinDense,
                    titleStyle: theme.textTheme.titleSmall!.copyWith(
                      color: theme.colorScheme.error,
                    ),
                    onTap: () => _delete(original, gs!.liveExpenses.length),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Trip, Home, Couple, Other: a segmented control while every word fits
/// its quarter, and wrapping chips at large text or on a narrow phone, so
/// a label is never broken mid-word ("Cou/ple").
class _GroupTypePicker extends StatelessWidget {
  const _GroupTypePicker({required this.value, required this.onChanged});

  final GroupType value;
  final ValueChanged<GroupType> onChanged;

  static const _types = [
    GroupType.trip,
    GroupType.home,
    GroupType.couple,
    GroupType.other,
  ];

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final fits = segmentsFit(
        context,
        _types.map(groupTypeLabel),
        constraints.maxWidth,
        count: _types.length,
        // Text button padding (12 a side) and the segment borders.
        chrome: 24 + 2,
      );
      if (fits) {
        return SegmentedButton<GroupType>(
          showSelectedIcon: false,
          segments: [
            for (final t in _types)
              ButtonSegment(value: t, label: SegmentLabel(groupTypeLabel(t))),
          ],
          selected: {value},
          onSelectionChanged: (s) => onChanged(s.first),
        );
      }
      return Semantics(
        label: S.groupType,
        container: true,
        explicitChildNodes: true,
        child: Wrap(
          spacing: Space.sm,
          runSpacing: Space.sm,
          children: [
            for (final t in _types)
              ChoiceChip(
                label: Text(groupTypeLabel(t)),
                selected: t == value,
                showCheckmark: false,
                onSelected: (_) => onChanged(t),
              ),
          ],
        ),
      );
    },
  );
}
