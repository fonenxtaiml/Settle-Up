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
  static List<Category> get all => throw UnimplementedError();

  /// Unknown ids return the `general` category (never throws).
  static Category byId(String id) => throw UnimplementedError();

  /// Best keyword match on lower-cased word tokens of [description],
  /// longest keyword wins, ties by category id; null if no match.
  static String? suggest(String description) => throw UnimplementedError();
}
