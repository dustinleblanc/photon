import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../api/models.dart';
import '../api/serve_client.dart';
import '../ml/detection_index.dart';
import '../ml/library_scanner.dart';
import '../sidecar/sidecar.dart';

enum AppPhase { booting, loggedOut, ready }

class AppState extends ChangeNotifier {
  AppState({ServeClient? client, Sidecar? sidecar})
      : _client = client ?? ServeClient(),
        _sidecar = sidecar ?? Sidecar() {
    detector = LibraryScanner(
      detectionIndex,
      (String linkId, {int size = 512}) => preview(linkId, size: size),
    );
  }

  final ServeClient _client;
  final Sidecar _sidecar;

  /// On-device, encrypted-at-rest detection index. Android only.
  final DetectionIndex detectionIndex = DetectionIndex();

  /// Batch object-detection job over the loaded library.
  late final LibraryScanner detector;

  AppPhase _phase = AppPhase.booting;
  AppPhase get phase => _phase;

  String? _error;
  String? get error => _error;

  bool _totpRequired = false;
  bool get totpRequired => _totpRequired;

  @visibleForTesting
  void requireTotpForTest() {
    _totpRequired = true;
    _phase = AppPhase.loggedOut;
  }

  final List<Photo> _photos = [];
  List<Photo> get photos => List.unmodifiable(_photos);

  String? _nextCursor;
  bool get hasMore => _nextCursor != null;

  bool _loading = false;
  bool get loading => _loading;

  final Map<String, Uint8List> _previewCache = {};
  final Map<String, Future<Uint8List>> _inFlight = {};

  String _sessionOutPath = '';
  String? _savedSessionJson;

  Future<void> init() async {
    try {
      _prepareSessionFiles();
      final healthy = await _sidecar.start(
        sessionJson: _savedSessionJson,
        sessionOutPath: _sessionOutPath,
      );
      if (healthy) {
        final authenticated = await _client.session();
        _phase = authenticated ? AppPhase.ready : AppPhase.loggedOut;
      } else {
        _error = 'photon sidecar is not running';
        _phase = AppPhase.loggedOut;
      }
    } catch (e) {
      _error = e.toString();
      _phase = AppPhase.loggedOut;
    }
    notifyListeners();
    if (_phase == AppPhase.ready) {
      await loadMore();
      if (Platform.isAndroid) {
        unawaited(detectionIndex.init());
      }
    }
  }

  void _prepareSessionFiles() {
    if (Platform.isAndroid) {
      _sessionOutPath = '';
      _savedSessionJson = null;
      return;
    }
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    final dir = Directory(
      '$home/Library/Application Support/photon-library',
    );
    dir.createSync(recursive: true);
    _sessionOutPath = '${dir.path}/session.out.json';
    try {
      final f = File('${dir.path}/session.json');
      if (f.existsSync()) _savedSessionJson = f.readAsStringSync();
    } catch (_) {
      _savedSessionJson = null;
    }
  }

  Future<void> login({
    required String username,
    required String password,
    String? totp,
  }) async {
    _error = null;
    _totpRequired = false;
    notifyListeners();
    try {
      final json = await _client.login(
        username: username,
        password: password,
        totp: totp,
      );
      final result = LoginResult.fromJson(json);
      switch (result.outcome) {
        case LoginOutcome.ok:
          _persistRotatedSession();
          _phase = AppPhase.ready;
          notifyListeners();
          await loadMore();
        case LoginOutcome.hvRequired:
          _error =
              'Human verification required (${result.hvMethods?.join(', ') ?? 'captcha'}). '
              'Solve it in a browser and pass hvToken/hvMethod.';
          notifyListeners();
        case LoginOutcome.totpRequired:
          _totpRequired = true;
          notifyListeners();
        case LoginOutcome.error:
          _error = result.error ?? 'Login failed';
          notifyListeners();
      }
    } on ApiException catch (e) {
      _error = e.message;
      notifyListeners();
    }
  }

  Future<void> logout() async {
    try {
      await _client.logout();
    } catch (_) {}
    _cleanupSessionFiles();
    _photos.clear();
    _nextCursor = null;
    _phase = AppPhase.loggedOut;
    notifyListeners();
  }

  Future<void> loadMore() async {
    if (_loading) return;
    _loading = true;
    notifyListeners();
    try {
      final page = await _client.listAssets(cursor: _nextCursor, pageSize: 200);
      for (final p in page.assets) {
        if (!_photos.any((e) => e.linkId == p.linkId)) _photos.add(p);
      }
      _nextCursor = page.nextCursor;
    } on ApiException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = e.toString();
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<Uint8List> preview(String linkId, {int size = 512}) {
    final cached = _previewCache['$linkId@$size'];
    if (cached != null) return Future.value(cached);
    final inFlight = _inFlight['$linkId@$size'];
    if (inFlight != null) return inFlight;

    final future = _fetchPreview(linkId, size);
    _inFlight['$linkId@$size'] = future;
    return future;
  }

  Future<Uint8List> _fetchPreview(String linkId, int size) async {
    try {
      final bytes = await _client.preview(linkId, size: size);
      _previewCache['$linkId@$size'] = bytes;
      if (_previewCache.length > 300) {
        _previewCache.remove(_previewCache.keys.first);
      }
      return bytes;
    } finally {
      _inFlight.remove('$linkId@$size');
    }
  }

  Future<Uint8List> original(String linkId) => _client.original(linkId);

  void _persistRotatedSession() {
    if (_sessionOutPath.isEmpty) return;
    try {
      final f = File(_sessionOutPath);
      if (f.existsSync()) {
        final home = Platform.environment['HOME'] ?? Directory.current.path;
        final dest = File(
          '$home/Library/Application Support/photon-library/session.json',
        );
        dest.writeAsStringSync(f.readAsStringSync(), flush: true);
      }
    } catch (_) {}
  }

  void _cleanupSessionFiles() {
    if (_sessionOutPath.isEmpty) return;
    try {
      final home = Platform.environment['HOME'] ?? Directory.current.path;
      final dir = Directory(
        '$home/Library/Application Support/photon-library',
      );
      for (final name in ['session.json', 'session.out.json']) {
        final f = File('${dir.path}/$name');
        if (f.existsSync()) f.deleteSync();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _sidecar.stop();
    _client.close();
    detector.dispose();
    detectionIndex.dispose();
    super.dispose();
  }
}