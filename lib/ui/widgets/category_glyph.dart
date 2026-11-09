import 'package:flutter/material.dart';

/// Category glyph disc (DESIGN 5.3); maps Categories ids to icons.
class CategoryGlyph extends StatelessWidget {
  const CategoryGlyph({super.key, required this.categoryId, this.size = 40});

  final String categoryId;
  final double size;

  static const Map<String, IconData> _icons = {
    'entertainment': Icons.theater_comedy_rounded,
    'entertainment.games': Icons.sports_esports_rounded,
    'entertainment.movies': Icons.movie_rounded,
    'entertainment.music': Icons.music_note_rounded,
    'entertainment.sports': Icons.sports_tennis_rounded,
    'food': Icons.restaurant_rounded,
    'food.dining': Icons.restaurant_rounded,
    'food.groceries': Icons.local_grocery_store_rounded,
    'food.liquor': Icons.local_bar_rounded,
    'home': Icons.home_rounded,
    'home.rent': Icons.key_rounded,
    'home.mortgage': Icons.account_balance_rounded,
    'home.household': Icons.soap_rounded,
    'home.furniture': Icons.chair_rounded,
    'home.electronics': Icons.tv_rounded,
    'home.maintenance': Icons.handyman_rounded,
    'home.pets': Icons.pets_rounded,
    'life': Icons.spa_rounded,
    'life.childcare': Icons.child_friendly_rounded,
    'life.clothing': Icons.checkroom_rounded,
    'life.education': Icons.school_rounded,
    'life.gifts': Icons.card_giftcard_rounded,
    'life.insurance': Icons.health_and_safety_rounded,
    'life.medical': Icons.medical_services_rounded,
    'life.taxes': Icons.request_quote_rounded,
    'transport': Icons.commute_rounded,
    'transport.bicycle': Icons.pedal_bike_rounded,
    'transport.bus_train': Icons.train_rounded,
    'transport.car': Icons.directions_car_rounded,
    'transport.fuel': Icons.local_gas_station_rounded,
    'transport.hotel': Icons.hotel_rounded,
    'transport.parking': Icons.local_parking_rounded,
    'transport.plane': Icons.flight_rounded,
    'transport.taxi': Icons.local_taxi_rounded,
    'utilities': Icons.lightbulb_rounded,
    'utilities.cleaning': Icons.local_laundry_service_rounded,
    'utilities.electricity': Icons.bolt_rounded,
    'utilities.gas': Icons.local_fire_department_rounded,
    'utilities.heat': Icons.thermostat_rounded,
    'utilities.internet': Icons.wifi_rounded,
    'utilities.phone': Icons.smartphone_rounded,
    'utilities.trash': Icons.delete_rounded,
    'utilities.water': Icons.water_drop_rounded,
    'general': Icons.receipt_long_rounded,
    'payment': Icons.handshake_rounded,
  };

  /// Unknown children fall back to their parent's icon, unknown parents to
  /// the "Uncategorized" receipt.
  static IconData iconFor(String categoryId) {
    final exact = _icons[categoryId];
    if (exact != null) return exact;
    final dot = categoryId.indexOf('.');
    if (dot > 0) {
      final parent = _icons[categoryId.substring(0, dot)];
      if (parent != null) return parent;
    }
    return Icons.receipt_long_rounded;
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isPayment = categoryId == 'payment';
    return ExcludeSemantics(
      child: SizedBox.square(
        dimension: size,
        child: DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: isPayment ? scheme.primary : scheme.surfaceContainerHigh,
          ),
          child: Icon(
            iconFor(categoryId),
            size: size * 0.6,
            color: isPayment ? scheme.onPrimary : scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
