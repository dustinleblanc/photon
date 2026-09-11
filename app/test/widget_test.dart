import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:photon_library/screens/login_screen.dart';
import 'package:photon_library/state/app_state.dart';

void main() {
  testWidgets('login screen renders sign-in form', (tester) async {
    final state = AppState();
    await tester.pumpWidget(
      MaterialApp(home: LoginScreen(state: state)),
    );

    expect(find.text('Photon Library'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Proton username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
  });
}