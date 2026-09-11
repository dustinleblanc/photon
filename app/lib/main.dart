import 'package:flutter/cupertino.dart';

import 'screens/gallery_screen.dart';
import 'screens/login_screen.dart';
import 'state/app_state.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final state = AppState()..init();
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
            const CupertinoPageScaffold(
              child: Center(child: CupertinoActivityIndicator()),
            ),
          AppPhase.loggedOut => LoginScreen(state: state),
          AppPhase.ready => GalleryScreen(state: state),
        };
        return CupertinoApp(
          title: 'Photon Library',
          debugShowCheckedModeBanner: false,
          theme: const CupertinoThemeData(
            primaryColor: Color(0xFF6D4AFF),
            brightness: Brightness.light,
          ),
          home: home,
        );
      },
    );
  }
}