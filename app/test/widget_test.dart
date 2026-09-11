import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:photon_library/screens/login_screen.dart';
import 'package:photon_library/state/app_state.dart';

void main() {
  testWidgets('login screen renders sign-in form without TOTP by default', (
    tester,
  ) async {
    final state = AppState();
    await tester.pumpWidget(MaterialApp(home: LoginScreen(state: state)));

    expect(find.text('Photon Library'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('Proton username'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('Two-factor code'), findsNothing);
  });

  testWidgets('login screen shows TOTP field and hides credentials when required', (
    tester,
  ) async {
    final state = AppState();
    state.requireTotpForTest();
    await tester.pumpWidget(MaterialApp(home: LoginScreen(state: state)));

    expect(find.text('6-digit code from your authenticator app'), findsOneWidget);
    expect(find.text('Verify'), findsOneWidget);
    expect(find.text('Proton username'), findsNothing);
    expect(find.text('Password'), findsNothing);
  });
}