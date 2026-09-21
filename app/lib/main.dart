import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'screens/home_shell.dart';
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

class PhotonLibraryApp extends StatefulWidget {
  const PhotonLibraryApp({super.key, required this.state});

  final AppState state;

  @override
  State<PhotonLibraryApp> createState() => _PhotonLibraryAppState();
}

class _PhotonLibraryAppState extends State<PhotonLibraryApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Proton rotates refresh tokens as the session runs; flush the latest
    // before the process is suspended so the next launch can resume.
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.detached) {
      unawaited(widget.state.flushSession());
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.state,
      builder: (context, _) {
        final Widget home = switch (widget.state.phase) {
          AppPhase.booting =>
            const Scaffold(body: Center(child: CircularProgressIndicator())),
          AppPhase.onboarding => LoginScreen(state: widget.state),
          AppPhase.ready => HomeShell(state: widget.state),
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
