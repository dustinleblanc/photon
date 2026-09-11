import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../api/serve_client.dart';
import '../ml/detection_index.dart';
import '../ml/faces.dart';

/// Syncs named people between devices through the `photon serve` host, which
/// stores one small JSON snapshot in the account's own (E2E-encrypted) Drive.
///
/// The protocol is a plain snapshot with optimistic concurrency: every device
/// pulls, merges remote identities into its local encrypted index, and pushes
/// its merged view guarded by the revision it based its write on. A 409 means
/// someone else wrote first — merge again and retry once.
///
/// What syncs: name, aliases, centroid embedding, sample count. Contact links
/// and per-face ignore flags stay device-local on purpose.
class TagsSync extends ChangeNotifier {
  TagsSync({required this.client, required this.index});

  final ServeClient client;
  final DetectionIndex index;

  static const _storage = FlutterSecureStorage();
  static const _keyEnabled = 'photon_tags_sync_enabled';

  bool _enabled = false;
  bool _loaded = false;
  bool _busy = false;
  String? _error;
  DateTime? _lastSyncedAt;
  int _revision = 0;
  Timer? _pushDebounce;
  String? _lastPushedFingerprint;

  bool get enabled => _enabled;
  bool get busy => _busy;
  String? get error => _error;
  DateTime? get lastSyncedAt => _lastSyncedAt;

  /// Loads the persisted opt-in flag and starts watching the index for
  /// changes worth pushing.
  Future<void> init() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final raw = await _storage.read(key: _keyEnabled);
      _enabled = raw == '1';
    } catch (_) {
      _enabled = false;
    }
    index.addListener(_onIndexChanged);
    if (_enabled) {
      unawaited(pullAndPush());
    }
    notifyListeners();
  }

  /// Enables or disables sync. Turning it on performs an immediate pull and
  /// push so both sides converge right away.
  Future<void> setEnabled(bool value) async {
    _enabled = value;
    _error = null;
    notifyListeners();
    try {
      await _storage.write(key: _keyEnabled, value: value ? '1' : '0');
    } catch (_) {}
    if (value) {
      await pullAndPush();
    } else {
      _pushDebounce?.cancel();
    }
  }

  /// Pulls the remote snapshot, merges it into the local index, then pushes
  /// the merged view back. Safe to call concurrently; overlapping calls
  /// collapse into the running one.
  Future<void> pullAndPush() async {
    if (_busy) return;
    _busy = true;
    _error = null;
    notifyListeners();
    try {
      final remote = await _pull();
      final merged = await index.applyRemoteIdentities(remote.persons);
      await _push(baseRevision: remote.revision, merged: merged);
      _lastSyncedAt = DateTime.now();
    } on ApiException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = e.toString();
    } finally {
      _busy = false;
      notifyListeners();
    }
  }

  Future<TagsDocument> _pull() async {
    final json = await client.getTags();
    return TagsDocument.fromJson(json);
  }

  Future<void> _push({
    required int baseRevision,
    required List<PersonIdentity> merged,
  }) async {
    final fingerprint = identitiesFingerprint(merged);
    if (fingerprint == _lastPushedFingerprint && baseRevision == _revision) {
      return;
    }
    try {
      final res = await _clientPutTags(
        baseRevision: baseRevision,
        identities: merged,
      );
      _revision = (res['revision'] as num?)?.toInt() ?? baseRevision + 1;
      _lastPushedFingerprint = fingerprint;
    } on ApiException catch (e) {
      if (e.statusCode == 409) {
        // Someone else wrote while we were merging: pull their view, merge
        // again, and retry once with the fresh revision.
        final remote = await _pull();
        final again = await index.applyRemoteIdentities(remote.persons);
        final res = await _clientPutTags(
          baseRevision: remote.revision,
          identities: again,
        );
        _revision = (res['revision'] as num?)?.toInt() ?? remote.revision + 1;
        _lastPushedFingerprint = identitiesFingerprint(again);
        return;
      }
      rethrow;
    }
  }

  Future<Map<String, dynamic>> _clientPutTags({
    required int baseRevision,
    required List<PersonIdentity> identities,
  }) {
    return client.putTags(
      baseRevision: baseRevision,
      identities: [
        for (final id in identities)
          {
            'name': id.name,
            if (id.aliases.isNotEmpty) 'aliases': id.aliases,
            'centroid': id.centroid.toList(),
            'samples': id.faceSamples,
          },
      ],
    );
  }

  /// Index mutations schedule a debounced push so a tagging burst results in
  /// one upload, not one per photo.
  void _onIndexChanged() {
    if (!_enabled || _busy) return;
    _pushDebounce?.cancel();
    _pushDebounce = Timer(const Duration(seconds: 3), () {
      if (!_enabled) return;
      unawaited(
        pullAndPush().catchError((_) {}),
      );
    });
  }
}

/// The wire document, mirroring core.TagsDocument on the host.
class TagsDocument {
  TagsDocument({required this.revision, required this.identities});

  factory TagsDocument.fromJson(Map<String, dynamic> json) => TagsDocument(
        revision: (json['revision'] as num?)?.toInt() ?? 0,
        identities: [
          for (final raw in (json['identities'] as List?) ?? const [])
            TagsIdentity.fromJson(raw as Map<String, dynamic>),
        ],
      );

  final int revision;
  final List<TagsIdentity> identities;

  /// The identities as local [PersonIdentity]s for index merging.
  List<PersonIdentity> get persons => [
        for (final id in identities)
          PersonIdentity(
            name: id.name,
            aliases: id.aliases,
            centroid: id.centroid,
            faceSamples: id.samples,
          ),
      ];
}

class TagsIdentity {
  TagsIdentity({
    required this.name,
    required this.aliases,
    required this.centroid,
    required this.samples,
  });

  factory TagsIdentity.fromJson(Map<String, dynamic> json) => TagsIdentity(
        name: json['name'] as String? ?? '',
        aliases:
            ((json['aliases'] as List?) ?? const []).cast<String>().toList(),
        centroid: Float32List.fromList(
          (json['centroid'] as List? ?? const [])
              .cast<num>()
              .map((e) => e.toDouble())
              .toList(),
        ),
        samples: (json['samples'] as num?)?.toInt() ?? 0,
      );

  final String name;
  final List<String> aliases;
  final Float32List centroid;
  final int samples;
}

/// Stable string for change detection, independent of map ordering.
String identitiesFingerprint(List<PersonIdentity> identities) {
  final parts = [
    for (final id in identities)
      '${id.name}|${id.aliases.join(',')}|${id.faceSamples}|'
          '${id.centroid.take(8).join(',')}',
  ]..sort();
  return parts.join(';');
}
