import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/ui/widgets/widgets.dart';

import 'kit_harness.dart';

void main() {
  setUpAll(configureKitTests);

  test('initials', () {
    expect(PersonAvatar.initialsFor('Sam Patel'), 'SP');
    expect(PersonAvatar.initialsFor('priya'), 'P');
    expect(PersonAvatar.initialsFor('  Ana  María  de la Cruz '), 'AC');
    expect(PersonAvatar.initialsFor('🙂 Jo'), '🙂');
    expect(PersonAvatar.initialsFor(''), '?');
    expect(PersonAvatar.initialsFor('Élodie Ölm'), 'ÉÖ');
  });

  test('category icons fall back to parent, then to general', () {
    expect(CategoryGlyph.iconFor('transport.taxi'), Icons.local_taxi_rounded);
    expect(
      CategoryGlyph.iconFor('food.something_new'),
      CategoryGlyph.iconFor('food'),
    );
    expect(CategoryGlyph.iconFor('nope'), CategoryGlyph.iconFor('general'));
    expect(CategoryGlyph.iconFor('payment'), Icons.handshake_rounded);
  });

  testKitVariants(
    'avatars, group glyphs and category glyphs',
    () => const Padding(
      padding: EdgeInsets.all(16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          PersonAvatar(id: 'a', name: 'Alex Lee', size: 56),
          PersonAvatar(id: 'b', name: 'Priya', size: 40),
          PersonAvatar(id: 'c', name: 'Sam Patel', size: 32),
          PersonAvatar(id: 'd', name: 'Ravi', size: 24),
          PersonAvatar(id: 'e', name: 'Jo Marsh', isPlaceholder: true),
          GroupGlyph(id: 'g', name: 'Flat 4B'),
          GroupGlyph(id: 'h', name: 'Goa', emoji: '🏖'),
          CategoryGlyph(categoryId: 'food.dining'),
          CategoryGlyph(categoryId: 'payment', size: 32),
        ],
      ),
    ),
    verify: (tester, v) async {
      expect(find.text('AL'), findsOneWidget);
      expect(find.text('F4'), findsOneWidget);
    },
  );

  testWidgets('placeholder avatar says it is not on Settle Up yet', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await tester.pumpWidget(
      kitApp(const PersonAvatar(id: 'x', name: 'Jo', isPlaceholder: true)),
    );
    expect(find.bySemanticsLabel('Jo, not on Settle Up yet'), findsOneWidget);
    handle.dispose();
  });
}
