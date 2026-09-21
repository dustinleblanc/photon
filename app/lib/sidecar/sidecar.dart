import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import '../api/serve_client.dart';

/// Manages the loopback API the app talks to.
///
/// On Android the whole `photon serve` binary ships inside the APK and runs
/// as a child process on the phone itself, so no host machine or adb reverse
/// is needed. On desktop the sidecar is the repo's photon binary, spawned as
/// before.
class Sidecar {
  Sidecar({this.port = 8787, this.binaryOverride});

  static const _serveChannel = MethodChannel(
    'com.dustinleblanc.photon.library/serve',
  );
  static const _storage = FlutterSecureStorage();
  static const _sessionKey = 'photon_embedded_session';

  final int port;
  final String? binaryOverride;

  Process? _process;
  bool _startedHere = false;

  StreamSubscription<FileSystemEvent>? _sessionWatch;
  Timer? _sessionMirrorDebounce;

  String get baseUrl => 'http://127.0.0.1:$port';

  Future<bool> isHealthy() async {
    return _probe();
  }

  Future<bool> _probe() async {
    final client = ServeClient(url: baseUrl);
    try {
      return await client.health();
    } catch (_) {
      return false;
    } finally {
      client.close();
    }
  }

  Future<bool> start({
    String? sessionJson,
    required String sessionOutPath,
  }) async {
    if (Platform.isAndroid) {
      return _startEmbedded();
    }

    if (await _probe()) return true;

    final binary = _findBinary();
    if (binary == null) {
      throw ApiException(
        'photon binary not found. Set PHOTON_MIGRATE_BIN or build it first.',
      );
    }

    final env = Map<String, String>.from(Platform.environment);
    if (sessionJson != null && sessionJson.isNotEmpty) {
      env['PROTON_UPLOAD_SESSION_JSON'] = sessionJson;
    }

    _process = await Process.start(
      binary,
      ['serve', '--addr', '127.0.0.1:$port', '--session-out', sessionOutPath],
      environment: env,
      runInShell: false,
    );
    _startedHere = true;

    _process!.stderr.transform(utf8.decoder).listen((_) {});
    _process!.stdout.drain<void>().catchError((_) {});

    final healthy = await _pollHealthy(const Duration(seconds: 15));
    if (!healthy && _process != null) {
      await stop();
      throw ApiException('photon sidecar did not become healthy on $baseUrl');
    }
    return healthy;
  }

  /// Starts the embedded on-device server. The session (if any) comes from
  /// secure storage; a fresh login persists it there via [persistSession].
  Future<bool> _startEmbedded() async {
    if (await _probe()) return true;
    try {
      final sessionJson = await _storage.read(key: _sessionKey);
      final dir = await getApplicationDocumentsDirectory();
      final sessionOut = '${dir.path}/session.json';
      final ok = await _serveChannel.invokeMethod<bool>('start', {
        'sessionJson': sessionJson ?? '',
        'sessionOutPath': sessionOut,
      });
      if (ok != true) return false;
      return await _pollHealthy(const Duration(seconds: 15));
    } on PlatformException {
      return false;
    }
  }

  /// Reads the session file the embedded server writes and stores it in
  /// secure storage, so the next launch resumes without a re-login.
  Future<void> persistSession() async {
    if (!Platform.isAndroid) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/session.json');
      if (!file.existsSync()) return;
      final json = file.readAsStringSync();
      if (json.isNotEmpty) {
        await _storage.write(key: _sessionKey, value: json);
      }
    } catch (_) {}
  }

  /// Whether a Proton session has ever been persisted on this device. Used to
  /// tell "sign in again" (a stored session that no longer resumes) apart from
  /// a genuine first run, so an expired session doesn't hide local content.
  Future<bool> hasStoredSession() async {
    if (!Platform.isAndroid) return false;
    try {
      final value = await _storage.read(key: _sessionKey);
      return value != null && value.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Mirrors the embedded server's session file into secure storage whenever
  /// it changes. Proton rotates refresh tokens on every access-token refresh
  /// and the old token becomes unusable, so if a rotation is not captured the
  /// next launch resumes with a dead token and forces a fresh login.
  ///
  /// Android-only; on desktop [AppState] copies the session file directly.
  Future<void> startSessionMirror() async {
    if (!Platform.isAndroid || _sessionWatch != null) return;
    try {
      final dir = await getApplicationDocumentsDirectory();
      await dir.create(recursive: true);
      // Capture whatever the server wrote on resume/login before watching, so
      // a rotation that happened before the watcher attached isn't lost.
      await persistSession();
      _sessionWatch = dir.watch().listen((event) {
        if (!event.path.endsWith('session.json')) return;
        _sessionMirrorDebounce?.cancel();
        _sessionMirrorDebounce = Timer(
          const Duration(milliseconds: 250),
          () => unawaited(persistSession()),
        );
      });
    } catch (_) {
      // Directory watching can fail on some devices; the app lifecycle hook
      // still mirrors the session on background, so resuming stays viable.
      _sessionWatch = null;
    }
  }

  Future<void> stopSessionMirror() async {
    _sessionMirrorDebounce?.cancel();
    _sessionMirrorDebounce = null;
    final watch = _sessionWatch;
    _sessionWatch = null;
    try {
      await watch?.cancel();
    } catch (_) {}
  }

  Future<bool> _pollHealthy(Duration timeout) async {
    final client = ServeClient(url: baseUrl);
    try {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        if (await client.health()) return true;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      return false;
    } finally {
      client.close();
    }
  }

  Future<void> stop() async {
    if (Platform.isAndroid) {
      await stopSessionMirror();
      try {
        await _serveChannel.invokeMethod<void>('stop');
      } catch (_) {}
      return;
    }
    final p = _process;
    _process = null;
    if (p != null && _startedHere) {
      try {
        p.kill(ProcessSignal.sigterm);
        await p.exitCode.timeout(const Duration(seconds: 2));
      } on TimeoutException {
        try {
          p.kill(ProcessSignal.sigkill);
        } catch (_) {}
      } catch (_) {}
    }
  }

  String? _findBinary() {
    if (binaryOverride != null) return binaryOverride;
    final env = Platform.environment['PHOTON_MIGRATE_BIN'];
    if (env != null && File(env).existsSync()) return env;

    final bundled = _bundled();
    if (bundled != null) return bundled;

    final repoRoot = findRepoRoot(Directory.current);
    if (repoRoot != null) {
      final bin = File('$repoRoot/build/photon');
      if (bin.existsSync()) return bin.path;
    }

    final inPath = _which('photon');
    return inPath;
  }

  String? _bundled() {
    // When packaged, photon lives next to the app executable: in the macOS
    // bundle's Resources/, or right beside the binary in the Linux bundle.
    try {
      // Resolve symlinks so a versioned install layout (e.g. a `current`
      // symlink into versions/<tag>) still finds the photon binary that sits
      // next to the *real* executable.
      final exe = File(Platform.resolvedExecutable).resolveSymbolicLinksSync();
      final photon = Platform.isMacOS
          ? File('$exe/../Resources/photon')
          : File('$exe/../photon');
      if (photon.existsSync()) return photon.path;
    } catch (_) {}
    return null;
  }

  String? _which(String name) {
    try {
      final result = Process.runSync('which', [name]);
      if (result.exitCode == 0) {
        final path = (result.stdout as String).trim();
        if (path.isNotEmpty) return path;
      }
    } catch (_) {}
    return null;
  }
}

/// Walks up from [start] looking for the repository root: a directory that
/// contains both `go.mod` and a `core/` directory. Returns null when no such
/// ancestor exists.
///
/// Stops at the filesystem root, whose [Directory.parent] is itself — without
/// this guard the walk would loop forever calling `stat("/go.mod")` when run
/// outside the repo (e.g. a packaged app launched from the desktop), wedging
/// the UI isolate before the first frame is presented.
String? findRepoRoot(Directory start) {
  Directory? dir = start.absolute;
  while (dir != null) {
    if (File('${dir.path}/go.mod').existsSync() &&
        Directory('${dir.path}/core').existsSync()) {
      return dir.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}
