// FROZEN CONTRACT (docs/SPEC.md section 5.9). Owner: core (icons: ui).
import 'package:meta/meta.dart';

@immutable
final class Category {
  const Category({
    required this.id,
    required this.label,
    this.parentId,
    this.keywords = const [],
  });

  final String id; // stable, dotted: 'food.groceries'; top level: 'food'
  final String label; // 'Groceries'
  final String? parentId; // 'food'
  final List<String> keywords; // lower case, for suggest()
}

abstract final class Categories {
  static const String general = 'general'; // "Uncategorized" fallback
  static const String payment = 'payment'; // reserved for payments

  /// Splitwise-like two-level taxonomy (SPEC 5.9), parents before children.
  static List<Category> get all => _all;

  static const List<Category> _all = <Category>[
    Category(id: 'entertainment', label: 'Entertainment'),
    Category(
      id: 'entertainment.games',
      label: 'Games',
      parentId: 'entertainment',
      keywords: ['game', 'games', 'arcade', 'bowling'],
    ),
    Category(
      id: 'entertainment.movies',
      label: 'Movies',
      parentId: 'entertainment',
      keywords: ['movie', 'cinema', 'film', 'netflix'],
    ),
    Category(
      id: 'entertainment.music',
      label: 'Music',
      parentId: 'entertainment',
      keywords: ['concert', 'gig', 'spotify', 'music'],
    ),
    Category(
      id: 'entertainment.sports',
      label: 'Sports',
      parentId: 'entertainment',
      keywords: ['gym', 'football', 'tennis', 'match', 'swim'],
    ),
    Category(id: 'food', label: 'Food and drink'),
    Category(
      id: 'food.dining',
      label: 'Dining out',
      parentId: 'food',
      keywords: [
        'dinner',
        'lunch',
        'breakfast',
        'brunch',
        'restaurant',
        'cafe',
        'coffee',
        'pizza',
        'burger',
        'takeaway',
      ],
    ),
    Category(
      id: 'food.groceries',
      label: 'Groceries',
      parentId: 'food',
      keywords: [
        'grocery',
        'groceries',
        'supermarket',
        'tesco',
        'aldi',
        'lidl',
        'walmart',
        'bigbasket',
        'market',
      ],
    ),
    Category(
      id: 'food.liquor',
      label: 'Liquor',
      parentId: 'food',
      keywords: ['beer', 'wine', 'bar', 'pub', 'drinks', 'liquor'],
    ),
    Category(id: 'home', label: 'Home'),
    Category(
      id: 'home.rent',
      label: 'Rent',
      parentId: 'home',
      keywords: ['rent'],
    ),
    Category(
      id: 'home.mortgage',
      label: 'Mortgage',
      parentId: 'home',
      keywords: ['mortgage'],
    ),
    Category(
      id: 'home.household',
      label: 'Household supplies',
      parentId: 'home',
      keywords: ['detergent', 'toilet', 'cleaning supplies', 'household'],
    ),
    Category(
      id: 'home.furniture',
      label: 'Furniture',
      parentId: 'home',
      keywords: ['furniture', 'ikea', 'sofa'],
    ),
    Category(
      id: 'home.electronics',
      label: 'Electronics',
      parentId: 'home',
      keywords: ['tv', 'laptop', 'phone case', 'electronics'],
    ),
    Category(
      id: 'home.maintenance',
      label: 'Maintenance',
      parentId: 'home',
      keywords: ['plumber', 'repair', 'electrician'],
    ),
    Category(
      id: 'home.pets',
      label: 'Pets',
      parentId: 'home',
      keywords: ['vet', 'pet', 'dog', 'cat'],
    ),
    Category(id: 'life', label: 'Life'),
    Category(
      id: 'life.childcare',
      label: 'Childcare',
      parentId: 'life',
      keywords: ['babysitter', 'nursery', 'daycare'],
    ),
    Category(
      id: 'life.clothing',
      label: 'Clothing',
      parentId: 'life',
      keywords: ['clothes', 'shoes', 'shirt'],
    ),
    Category(
      id: 'life.education',
      label: 'Education',
      parentId: 'life',
      keywords: ['books', 'course', 'tuition'],
    ),
    Category(
      id: 'life.gifts',
      label: 'Gifts',
      parentId: 'life',
      keywords: ['gift', 'present', 'birthday'],
    ),
    Category(
      id: 'life.insurance',
      label: 'Insurance',
      parentId: 'life',
      keywords: ['insurance'],
    ),
    Category(
      id: 'life.medical',
      label: 'Medical',
      parentId: 'life',
      keywords: ['doctor', 'pharmacy', 'medicine', 'hospital'],
    ),
    Category(
      id: 'life.taxes',
      label: 'Taxes',
      parentId: 'life',
      keywords: ['tax'],
    ),
    Category(id: 'transport', label: 'Transportation'),
    Category(
      id: 'transport.bicycle',
      label: 'Bicycle',
      parentId: 'transport',
      keywords: ['bike', 'cycle'],
    ),
    Category(
      id: 'transport.bus_train',
      label: 'Bus and train',
      parentId: 'transport',
      keywords: ['bus', 'train', 'metro', 'tube', 'subway', 'tram'],
    ),
    Category(
      id: 'transport.car',
      label: 'Car',
      parentId: 'transport',
      keywords: ['car hire', 'rental car', 'toll'],
    ),
    Category(
      id: 'transport.fuel',
      label: 'Fuel',
      parentId: 'transport',
      keywords: ['petrol', 'diesel', 'fuel'],
    ),
    Category(
      id: 'transport.hotel',
      label: 'Hotel',
      parentId: 'transport',
      keywords: ['hotel', 'airbnb', 'hostel', 'stay'],
    ),
    Category(
      id: 'transport.parking',
      label: 'Parking',
      parentId: 'transport',
      keywords: ['parking'],
    ),
    Category(
      id: 'transport.plane',
      label: 'Plane',
      parentId: 'transport',
      keywords: ['flight', 'flights', 'airline', 'plane'],
    ),
    Category(
      id: 'transport.taxi',
      label: 'Taxi',
      parentId: 'transport',
      keywords: ['taxi', 'cab', 'uber', 'lyft', 'ola', 'bolt', 'rickshaw'],
    ),
    Category(id: 'utilities', label: 'Utilities'),
    Category(
      id: 'utilities.cleaning',
      label: 'Cleaning',
      parentId: 'utilities',
      keywords: ['cleaner', 'laundry'],
    ),
    Category(
      id: 'utilities.electricity',
      label: 'Electricity',
      parentId: 'utilities',
      keywords: ['electricity', 'power bill'],
    ),
    Category(
      id: 'utilities.gas',
      label: 'Gas',
      parentId: 'utilities',
      keywords: ['gas bill'],
    ),
    Category(
      id: 'utilities.heat',
      label: 'Heat',
      parentId: 'utilities',
      keywords: ['heating'],
    ),
    Category(
      id: 'utilities.internet',
      label: 'Internet',
      parentId: 'utilities',
      keywords: ['internet', 'wifi', 'broadband'],
    ),
    Category(
      id: 'utilities.phone',
      label: 'Phone',
      parentId: 'utilities',
      keywords: ['phone bill', 'mobile recharge', 'recharge'],
    ),
    Category(
      id: 'utilities.trash',
      label: 'Trash',
      parentId: 'utilities',
      keywords: ['trash', 'garbage', 'bins'],
    ),
    Category(
      id: 'utilities.water',
      label: 'Water',
      parentId: 'utilities',
      keywords: ['water bill'],
    ),
    Category(id: general, label: 'Uncategorized'),
    Category(id: payment, label: 'Payment'),
  ];

  static final Map<String, Category> _byId = {for (final c in _all) c.id: c};

  /// Keywords as token lists, longest first, then by category id, so the
  /// first phrase that matches is the answer.
  static final List<(List<String>, String, String)> _phrases = () {
    final out = <(List<String>, String, String)>[
      for (final c in _all)
        for (final k in c.keywords) (_tokens(k), k, c.id),
    ];
    out.sort((a, b) {
      final c = b.$2.length.compareTo(a.$2.length);
      return c != 0 ? c : a.$3.compareTo(b.$3);
    });
    return out;
  }();

  static final RegExp _nonLetters = RegExp(r'[^\p{L}]+', unicode: true);

  static List<String> _tokens(String text) =>
      text.toLowerCase().split(_nonLetters).where((t) => t.isNotEmpty).toList();

  /// Unknown ids return the `general` category (never throws).
  static Category byId(String id) => _byId[id] ?? _byId[general]!;

  /// Best keyword match on lower-cased word tokens of [description],
  /// longest keyword wins, ties by category id; null if no match.
  ///
  /// Multi-word keywords match as consecutive tokens ("gas bill").
  static String? suggest(String description) {
    final tokens = _tokens(description);
    if (tokens.isEmpty) return null;
    for (final (phrase, _, id) in _phrases) {
      if (_containsRun(tokens, phrase)) return id;
    }
    return null;
  }

  static bool _containsRun(List<String> tokens, List<String> phrase) {
    if (phrase.isEmpty) return false;
    for (var i = 0; i + phrase.length <= tokens.length; i++) {
      var ok = true;
      for (var j = 0; j < phrase.length; j++) {
        if (tokens[i + j] != phrase[j]) {
          ok = false;
          break;
        }
      }
      if (ok) return true;
    }
    return false;
  }
}
