import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/gallery_screen.dart';
import 'screens/login_screen.dart';
import 'screens/settings_screen.dart';
import 'state/app_state.dart';

final navigatorKey = GlobalKey<NavigatorState>();

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState()..init();

  // macOS native menu: Settings… (⌘,) arrives over this channel.
  const appChannel = MethodChannel('photon/app');
  appChannel.setMethodCallHandler((call) async {
    debugPrint('app channel: ${call.method}');
    if (call.method == 'openSettings') {
      navigatorKey.currentState?.push(
        MaterialPageRoute(builder: (_) => SettingsScreen(state: state)),
      );
    }
  });

  runApp(PhotonLibraryApp(state: state));
}

class PhotonLibraryApp extends StatelessWidget {
  const PhotonLibraryApp({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final Widget home = switch (state.phase) {
          AppPhase.booting =>
            const Scaffold(body: Center(child: CircularProgressIndicator())),
          AppPhase.loggedOut => LoginScreen(state: state),
          AppPhase.ready => GalleryScreen(state: state),
        };
        return MaterialApp(
          navigatorKey: navigatorKey,
          title: 'Photon Library',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xFF6D4AFF)),
          ),
          darkTheme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF6D4AFF),
              brightness: Brightness.dark,
            ),
          ),
          home: home,
        );
      },
    );
  }
}