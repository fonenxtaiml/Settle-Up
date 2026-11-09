import 'package:flutter_test/flutter_test.dart';
import 'package:settle_up/core/categories.dart';

void main() {
  group('taxonomy', () {
    test('ids are unique, parents come before their children', () {
      final ids = Categories.all.map((c) => c.id).toList();
      expect(ids.toSet().length, ids.length);
      final seen = <String>{};
      for (final c in Categories.all) {
        if (c.parentId == null) {
          expect(c.id.contains('.'), isFalse, reason: c.id);
        } else {
          expect(seen, contains(c.parentId), reason: c.id);
          expect(c.id.startsWith('${c.parentId}.'), isTrue, reason: c.id);
        }
        for (final k in c.keywords) {
          expect(k, k.toLowerCase());
          expect(k.trim(), k);
        }
        seen.add(c.id);
      }
    });

    test('has exactly the SPEC 5.9 ids', () {
      const expected = {
        'entertainment': ['games', 'movies', 'music', 'sports'],
        'food': ['dining', 'groceries', 'liquor'],
        'home': [
          'rent',
          'mortgage',
          'household',
          'furniture',
          'electronics',
          'maintenance',
          'pets',
        ],
        'life': [
          'childcare',
          'clothing',
          'education',
          'gifts',
          'insurance',
          'medical',
          'taxes',
        ],
        'transport': [
          'bicycle',
          'bus_train',
          'car',
          'fuel',
          'hotel',
          'parking',
          'plane',
          'taxi',
        ],
        'utilities': [
          'cleaning',
          'electricity',
          'gas',
          'heat',
          'internet',
          'phone',
          'trash',
          'water',
        ],
        'general': <String>[],
        'payment': <String>[],
      };
      final all = <String>{
        for (final e in expected.entries) ...[
          e.key,
          for (final c in e.value) '${e.key}.$c',
        ],
      };
      expect(Categories.all.map((c) => c.id).toSet(), all);
      expect(Categories.byId('food').label, 'Food and drink');
      expect(Categories.byId('transport.bus_train').label, 'Bus and train');
      expect(Categories.byId('home.household').label, 'Household supplies');
      expect(Categories.byId(Categories.general).label, 'Uncategorized');
      expect(Categories.byId(Categories.payment).label, 'Payment');
      expect(Categories.byId('food.groceries').parentId, 'food');
    });

    test('unknown id returns general', () {
      expect(Categories.byId('nope').id, Categories.general);
      expect(Categories.byId('').id, Categories.general);
      expect(Categories.byId('food.unknown').id, Categories.general);
    });
  });

  group('suggest', () {
    test('SPEC examples', () {
      expect(Categories.suggest('Uber to airport'), 'transport.taxi');
      expect(Categories.suggest('Tesco'), 'food.groceries');
    });

    test('case-insensitive, tokenized on non-letters', () {
      expect(Categories.suggest('PIZZA!!'), 'food.dining');
      expect(Categories.suggest('dinner@the-shack'), 'food.dining');
      expect(Categories.suggest('2x beer'), 'food.liquor');
      expect(Categories.suggest('Netflix (March)'), 'entertainment.movies');
    });

    test('matches whole tokens only', () {
      expect(Categories.suggest('carpet'), isNull, reason: 'not "car"');
      expect(Categories.suggest('Barbecue'), isNull, reason: 'not "bar"');
      expect(Categories.suggest('rental'), isNull, reason: 'not "rent"');
    });

    test('multi-word keywords match as phrases', () {
      expect(Categories.suggest('Gas bill March'), 'utilities.gas');
      expect(Categories.suggest('gas'), isNull);
      expect(Categories.suggest('bill gas'), isNull);
      expect(Categories.suggest('Car hire at the airport'), 'transport.car');
      expect(Categories.suggest('Mobile recharge'), 'utilities.phone');
    });

    test('longest keyword wins', () {
      // "phone case" (10) beats "phone" which is not a keyword anyway, and
      // "cleaning supplies" (17) beats "cleaner"-less "cleaning".
      expect(Categories.suggest('new phone case'), 'home.electronics');
      expect(Categories.suggest('cleaning supplies'), 'home.household');
      // "supermarket" (11) beats "coffee" (6).
      expect(Categories.suggest('coffee from the supermarket'),
          'food.groceries');
      // "restaurant" (10) beats "bar" (3).
      expect(Categories.suggest('bar restaurant'), 'food.dining');
    });

    test('ties go to the smaller category id', () {
      // "pub" (food.liquor) and "gym" (entertainment.sports), both 3 chars.
      expect(Categories.suggest('pub gym'), 'entertainment.sports');
      // "tax" (life.taxes) vs "cab" (transport.taxi).
      expect(Categories.suggest('cab tax'), 'life.taxes');
    });

    test('no match', () {
      expect(Categories.suggest(''), isNull);
      expect(Categories.suggest('   '), isNull);
      expect(Categories.suggest('Misc'), isNull);
      expect(Categories.suggest('1234'), isNull);
    });

    test('never suggests payment or general', () {
      expect(Categories.suggest('payment'), isNull);
      expect(Categories.suggest('general'), isNull);
    });
  });
}
