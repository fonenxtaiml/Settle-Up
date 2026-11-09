// Phase 0 placeholder. WP-F replaces this with
// runApp(ProviderScope(overrides: await bootstrap(), child: SettleUpApp())).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  runApp(const ProviderScope(child: _PlaceholderApp()));
}

class _PlaceholderApp extends StatelessWidget {
  const _PlaceholderApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'Settle Up',
      home: Scaffold(body: Center(child: Text('Settle Up'))),
    );
  }
}
