import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../api/serve_client.dart';

class Sidecar {
  Sidecar({this.port = 8787, this.binaryOverride});

  final int port;
  final String? binaryOverride;

  Process? _process;
  bool _startedHere = false;

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
      // No local sidecar on Android: run `photon serve` on the host and
      // expose it via `adb reverse tcp:8787 tcp:8787`.
      final healthy = await _probe();
      if (!healthy) {
        throw ApiException(
          'No photon server reachable. Run `photon serve` on your Mac, then '
          'forward it: adb reverse tcp:8787 tcp:8787',
        );
      }
      return true;
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

  Future<bool> _pollHealthy(Duration timeout) async {
    final client = ServeClient(url: baseUrl);
    try {
      final deadline = DateTime.now().add(timeout);
      while (DateTime.now().isBefore(deadline)) {
        if (await client.health()) return true;
        if (_process == null) return false;
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      return false;
    } finally {
      client.close();
    }
  }

  Future<void> stop() async {
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

    final repoRoot = _repoRoot();
    if (repoRoot != null) {
      final bin = File('$repoRoot/build/photon');
      if (bin.existsSync()) return bin.path;
    }

    final inPath = _which('photon');
    return inPath;
  }

  String? _bundled() {
    // When packaged, photon lives next to the app executable in Resources.
    try {
      final exe = Platform.resolvedExecutable;
      final resources = File('$exe/../Resources/photon');
      if (resources.existsSync()) return resources.path;
    } catch (_) {}
    return null;
  }

  String? _repoRoot() {
    final cwd = Directory.current.absolute;
    Directory? dir = cwd;
    while (dir != null) {
      if (File('${dir.path}/go.mod').existsSync() &&
          Directory('${dir.path}/core').existsSync()) {
        return dir.path;
      }
      dir = dir.parent;
    }
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