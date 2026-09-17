import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../api/models.dart';
import '../api/serve_client.dart';
import '../ml/detection_index.dart';
import '../ml/library_scanner.dart';
import '../platform/preview_cache.dart';
import '../sidecar/sidecar.dart';
import '../sync/tags_sync.dart';

enum AppPhase { booting, loggedOut, ready }

/// Per-user app data directory: ~/Library/Application Support on macOS (as
/// before), $XDG_DATA_HOME (default ~/.local/share) on Linux. Returns null on
/// Android, where results live in the app sandbox instead.
String? _appDataDir() {
  if (Platform.isAndroid) return null;
  if (Platform.isMacOS) {
    final home = Platform.environment['HOME'] ?? Directory.current.path;
    return '$home/Library/Application Support/photon-library';
  }
  final home = Platform.environment['HOME'] ?? Directory.current.path;
  final xdg = Platform.environment['XDG_DATA_HOME'];
  if (xdg != null && xdg.isNotEmpty) return '$xdg/photon-library';
  return '$home/.local/share/photon-library';
}

class AppState extends ChangeNotifier {
  AppState({ServeClient? client, Sidecar? sidecar, PreviewCache? previewCache})
      : _client = client ?? ServeClient(),
        _sidecar = sidecar ?? Sidecar(),
        _previewDisk = previewCache ?? PreviewCache() {
    detector = LibraryScanner(
      detectionIndex,
      (String linkId, {int size = 512}) => preview(linkId, size: size),
    );
  }

  final ServeClient _client;
  final Sidecar _sidecar;
  final PreviewCache _previewDisk;

  /// On-device, encrypted-at-rest detection index. Android only.
  final DetectionIndex detectionIndex = DetectionIndex();

  /// Cross-device people-tag sync through the host (opt-in).
  late final TagsSync tagsSync = TagsSync(client: _client, index: detectionIndex);

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
      await _previewDisk.init();
      final healthy = await _sidecar.start(
        sessionJson: _savedSessionJson,
        sessionOutPath: _sessionOutPath,
      );
      if (healthy) {
        // The sidecar refreshes the Proton session as it runs and writes it to
        // sessionOutPath; persist that so the next launch resumes with the
        // current tokens instead of the ones from the last explicit login.
        _persistRotatedSession();
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
      unawaited(detectionIndex.init());
      unawaited(tagsSync.init());
    }
  }

  void _prepareSessionFiles() {
    if (Platform.isAndroid) {
      _sessionOutPath = '';
      _savedSessionJson = null;
      return;
    }
    final dirPath = _appDataDir() ?? Directory.current.path;
    final dir = Directory(dirPath);
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
          // The embedded on-device server writes its session to a file;
          // copy it into secure storage so the next launch resumes.
          await _sidecar.persistSession();
          _phase = AppPhase.ready;
          notifyListeners();
          await loadMore();
          unawaited(detectionIndex.init());
          unawaited(tagsSync.init());
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

  /// Every asset linkId in the library, fetched by paging through `/assets`.
  /// Scans use this so they cover the whole library, not just the pages the
  /// gallery has scrolled into view.
  Future<List<String>> libraryLinkIds() async {
    final ids = <String>{};
    String? cursor;
    while (true) {
      final page = await _client.listAssets(cursor: cursor, pageSize: 500);
      ids.addAll(page.assets.map((p) => p.linkId));
      final next = page.nextCursor;
      if (next == null || next == cursor) break;
      cursor = next;
    }
    return ids.toList();
  }

  /// Fetches every remaining page of the library. Filters run over the
  /// loaded photo list, so a filtered view over a partially-loaded library
  /// undercounts and never reaches the photos that would match; callers
  /// (person/group filters) use this to make counts and grids agree.
  Future<void> loadAll() async {
    while (hasMore) {
      await loadMore();
      if (_error != null) return;
    }
  }

  Future<Uint8List> preview(String linkId, {int size = 512}) {
    final key = '$linkId@$size';
    final cached = _previewCache[key];
    if (cached != null) return Future.value(cached);
    final inFlight = _inFlight[key];
    if (inFlight != null) return inFlight;

    final future = _loadPreview(linkId, size, key);
    _inFlight[key] = future;
    return future;
  }

  /// Memory first, then the encrypted disk cache, then the server.
  Future<Uint8List> _loadPreview(String linkId, int size, String key) async {
    try {
      final disk = await _previewDisk.get(linkId, size);
      if (disk != null) {
        _rememberPreview(key, disk);
        return disk;
      }
      final bytes = await _client.preview(linkId, size: size);
      _rememberPreview(key, bytes);
      await _previewDisk.put(linkId, size, bytes);
      return bytes;
    } finally {
      _inFlight.remove(key);
    }
  }

  void _rememberPreview(String key, Uint8List bytes) {
    _previewCache[key] = bytes;
    if (_previewCache.length > 300) {
      _previewCache.remove(_previewCache.keys.first);
    }
  }

  Future<Uint8List> original(String linkId) => _client.original(linkId);

  /// A persisted derived thumbnail (e.g. a face crop), stored in the same
  /// encrypted on-disk cache as previews. Lets the People page paint face
  /// tiles from disk instead of re-fetching and re-decoding a preview on
  /// every launch.
  Future<Uint8List?> cachedThumb(String key, int size) =>
      _previewDisk.get(key, size);

  Future<void> putThumb(String key, int size, Uint8List bytes) =>
      _previewDisk.put(key, size, bytes);

  void _persistRotatedSession() {
    if (_sessionOutPath.isEmpty) return;
    try {
      final f = File(_sessionOutPath);
      if (f.existsSync()) {
        final dest = File('${_appDataDir() ?? Directory.current.path}/session.json');
        dest.writeAsStringSync(f.readAsStringSync(), flush: true);
      }
    } catch (_) {}
  }

  void _cleanupSessionFiles() {
    if (_sessionOutPath.isEmpty) return;
    try {
      final dir = Directory(_appDataDir() ?? Directory.current.path);
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