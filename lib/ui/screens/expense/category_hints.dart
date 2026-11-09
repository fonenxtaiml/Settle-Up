// Category suggestion for Add expense: the core keyword table first, then a
// few everyday Indian words it does not know yet ("scooter", "auto",
// "chai"), so the suggested chip is right more often.
import '../../../core/categories.dart';

const Map<String, String> _hints = {
  'scooter': 'transport',
  'scooty': 'transport',
  'activa': 'transport',
  'bike rental': 'transport',
  'auto': 'transport.taxi',
  'rickshaw': 'transport.taxi',
  'ola': 'transport.taxi',
  'rapido': 'transport.taxi',
  'ferry': 'transport',
  'chai': 'food.dining',
  'thali': 'food.dining',
  'biryani': 'food.dining',
  'dosa': 'food.dining',
  'zomato': 'food.dining',
  'swiggy': 'food.dining',
  'kirana': 'food.groceries',
  'sabzi': 'food.groceries',
  'blinkit': 'food.groceries',
  'zepto': 'food.groceries',
  'maid': 'utilities.cleaning',
  'recharge': 'utilities.phone',
  'cylinder': 'utilities.gas',
};

final RegExp _words = RegExp(r'[^\p{L}]+', unicode: true);

/// Category id for [description], or null when nothing matches.
String? suggestCategory(String description) {
  final core = Categories.suggest(description);
  if (core != null) return core;
  final tokens = description.toLowerCase().split(_words);
  final text = ' ${tokens.where((t) => t.isNotEmpty).join(' ')} ';
  for (final e in _hints.entries) {
    if (text.contains(' ${e.key} ')) return e.value;
  }
  return null;
}
