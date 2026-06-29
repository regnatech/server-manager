// Smoke test: the app boots and mounts the router.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:server_manager_ui/main.dart';

void main() {
  testWidgets('app boots and mounts MaterialApp.router', (WidgetTester tester) async {
    await tester.pumpWidget(const ProviderScope(child: ServerManagerApp()));
    await tester.pump();
    expect(find.byType(MaterialApp), findsOneWidget);
  });
}
