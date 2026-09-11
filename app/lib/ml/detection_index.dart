import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';

import 'detection.dart';
import 'faces.dart';

/// On-device, encrypted-at-rest index of detection results keyed by photo
/// linkId, plus a store of named people (face-recognition identities). The
/// AES key lives in the platform secure storage; nothing in this store ever
/// leaves the device.
class DetectionIndex extends ChangeNotifier {
  static const _boxName = 'detections_v1';
  static const _identitiesBoxName = 'identities_v1';
  static const _keyName = 'photon_ml_index_key';
  static const _storage = FlutterSecureStorage();

  Box<Map>? _box;
  Box<Map>? _identitiesBox;
  Object? _openError;
  bool _initializing = false;

  bool get available => _box != null;
  Object? get error => _openError;

  static const keyName = _keyName;

  Future<void> init() async {
    if (_box != null || _initializing) return;
    _initializing = true;
    try {
      final dir = await getApplicationSupportDirectory();
      Hive.init(dir.path);
      final key = await _key();
      final cipher = HiveAesCipher(key);
      _box = await Hive.openBox<Map>(_boxName, encryptionCipher: cipher);
      _identitiesBox =
          await Hive.openBox<Map>(_identitiesBoxName, encryptionCipher: cipher);
    } catch (e) {
      _openError = e;
    } finally {
      _initializing = false;
      notifyListeners();
    }
  }

  Future<Uint8List> _key() async {
    final existing = await _storage.read(key: _keyName);
    if (existing != null) return base64Decode(existing);
    final rng = Random.secure();
    final key = Uint8List.fromList(
      List<int>.generate(32, (_) => rng.nextInt(256)),
    );
    await _storage.write(key: _keyName, value: base64Encode(key));
    return key;
  }

  DetectedEntry? lookup(String linkId) {
    final raw = _box?.get(linkId);
    if (raw == null) return null;
    try {
      final entry = DetectedEntry.fromMap(linkId, raw.cast<String, dynamic>());
      if (entry.modelVersion != DetectorService.modelVersion) return null;
      return entry;
    } catch (_) {
      return null;
    }
  }

  Future<void> put(DetectedEntry entry) async {
    await _box?.put(entry.linkId, entry.toMap());
    notifyListeners();
  }

  /// The distinct labels found across all scanned photos.
  Set<DetectionGroup> groupsFor(String linkId) =>
      lookup(linkId)?.groups ?? const {};

  /// linkIds whose detection groups include [group]. Results are excluded if
  /// they were produced by an older model than the current one.
  List<String> linkIdsWithGroup(DetectionGroup group) {
    final box = _box;
    if (box == null) return const [];
    return [
      for (final key in box.keys)
        if (lookup(key as String)?.groups.contains(group) ?? false) key,
    ];
  }

  /// The faces recorded for this photo, or an empty list when not scanned or
  /// no faces were found.
  List<DetectedFace> facesFor(String linkId) =>
      lookup(linkId)?.faces ?? const [];

  /// Named people present in this photo.
  Set<String> peopleFor(String linkId) => lookup(linkId)?.people ?? const {};

  /// True when the photo has at least one detected but unnamed face.
  bool hasUnnamedFace(String linkId) =>
      facesFor(linkId).any((f) => f.name == null);

  int get scannedCount => _box?.length ?? 0;

  Future<void> clear() async {
    await _box?.clear();
    await _identitiesBox?.clear();
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // Identities (named people)
  // ---------------------------------------------------------------------------

  /// All named identities, sorted by name.
  List<PersonIdentity> get identities {
    final box = _identitiesBox;
    if (box == null) return const [];
    final out = [
      for (final value in box.values)
        PersonIdentity.fromMap(value.cast<String, dynamic>()),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return out;
  }

  /// The identity known by any of [name] or an alias (case-insensitive), or
  /// null when [name] is new.
  PersonIdentity? identityForName(String raw) {
    final needle = raw.trim().toLowerCase();
    for (final id in identities) {
      for (final n in id.allNames) {
        if (n.toLowerCase() == needle) return id;
      }
    }
    return null;
  }

  /// Number of scanned photos per identity name, and the count of photos
  /// containing at least one unnamed face under the key `_unnamed`.
  Map<String, int> countPeople() {
    final counts = <String, int>{};
    var unnamed = 0;
    final box = _box;
    if (box != null) {
      for (final key in box.keys) {
        final entry = lookup(key as String);
        if (entry == null) continue;
        final names = entry.people;
        for (final name in names) {
          counts[name] = (counts[name] ?? 0) + 1;
        }
        if (entry.faces.any((f) => f.name == null)) unnamed++;
      }
    }
    counts[kUnnamedPeople] = unnamed;
    return counts;
  }

  static const String kUnnamedPeople = '__unnamed__';

  /// Adds or updates [name] with a new manually-assigned face embedding,
  /// returning the updated identity. Only explicitly named faces feed the
  /// centroid, so auto-matches cannot drift it. Existing aliases (and any
  /// passed in) are preserved.
  Future<PersonIdentity> upsertIdentity(
    String name,
    Float32List embedding, {
    List<String> aliases = const [],
  }) async {
    final box = _identitiesBox;
    if (box == null) throw StateError('index is not open');
    final raw = box.get(name);
    PersonIdentity next;
    if (raw == null) {
      next = PersonIdentity(
        name: name,
        aliases: aliases,
        centroid: Float32List.fromList(embedding.toList()),
        faceSamples: 1,
      );
    } else {
      final prev = PersonIdentity.fromMap(raw.cast<String, dynamic>());
      final n = prev.faceSamples;
      final centroid = Float32List(embedding.length);
      for (var i = 0; i < centroid.length; i++) {
        centroid[i] =
            (prev.centroid[i] * n + embedding[i]) / (n + 1);
      }
      final known = <String>{...prev.aliases, ...aliases}
          .where((a) => a.toLowerCase() != name.toLowerCase())
          .toList();
      next = PersonIdentity(
        name: name,
        aliases: known,
        centroid: centroid,
        faceSamples: n + 1,
      );
    }
    await box.put(name, next.toMap());
    notifyListeners();
    return next;
  }

  /// Assigns [name] to the face at [faceIndex] of [linkId] and backfills the
  /// name onto every other already-scanned photo whose face matches the
  /// identity. Typed names that belong to an existing identity (canonical or
  /// alias) resolve to that identity instead of creating a duplicate. Returns
  /// the number of newly assigned photos (excluding the one named directly),
  /// or -1 when the face is unavailable.
  Future<int> nameFace({
    required String linkId,
    required int faceIndex,
    required String name,
  }) async {
    final entry = lookup(linkId);
    if (entry == null || faceIndex < 0 || faceIndex >= entry.faces.length) {
      return -1;
    }
    final face = entry.faces[faceIndex];
    if (face.embedding.isEmpty) return -1;

    final trimmed = name.trim();
    if (trimmed.isEmpty) return -1;
    final canonical = identityForName(trimmed)?.name ?? trimmed;

    final identity = await upsertIdentity(canonical, face.embedding);
    entry.faces[faceIndex] = DetectedFace(
      rect: face.rect,
      embedding: face.embedding,
      name: canonical,
      similarity: 1.0,
    );
    await put(entry);

    var matched = 0;
    final box = _box;
    if (box != null) {
      var i = 0;
      for (final key in box.keys) {
        i++;
        final other = key == linkId ? null : lookup(key as String);
        if (other == null) continue;
        var changed = false;
        for (var j = 0; j < other.faces.length; j++) {
          final f = other.faces[j];
          if (f.name != null) continue;
          final score = faceMatchScore(f.embedding, identity.centroid);
          if (score >= kDefaultFaceMatchThreshold) {
            other.faces[j] = DetectedFace(
              rect: f.rect,
              embedding: f.embedding,
              name: canonical,
              similarity: score,
            );
            changed = true;
          }
        }
        if (changed) {
          matched++;
          await box.put(other.linkId, other.toMap());
          if (i % 25 == 0) await Future<void>.delayed(Duration.zero);
        }
      }
    }
    notifyListeners();
    return matched;
  }

  /// Clears the name from a single face (the embedding is kept, so the face
  /// can be re-matched later).
  Future<void> clearFaceName(String linkId, int faceIndex) async {
    final entry = lookup(linkId);
    if (entry == null || faceIndex < 0 || faceIndex >= entry.faces.length) {
      return;
    }
    final f = entry.faces[faceIndex];
    entry.faces[faceIndex] = DetectedFace(
      rect: f.rect,
      embedding: f.embedding,
    );
    await put(entry);
  }

  /// Changes an identity's canonical name and/or its aliases in place. Faces
/// stored under [oldName] are renamed to [newName]. Returns the number of
/// photos renamed, or -1 when the new primary name belongs to a different
/// identity (use [mergeIdentities] for that case).
  Future<int> updateIdentity({
    required String oldName,
    required String newName,
    List<String> aliases = const [],
  }) async {
    final box = _identitiesBox;
    if (box == null) return 0;
    final trimmed = newName.trim();
    if (trimmed.isEmpty) return 0;
    final raw = box.get(oldName);
    if (raw == null) return 0;
    final prev = PersonIdentity.fromMap(raw.cast<String, dynamic>());
    final existing = identityForName(trimmed);
    if (existing != null && existing.name != oldName) return -1;

    await box.delete(oldName);
    final aliasSet = <String>{...prev.aliases, ...aliases}
      ..removeWhere((a) => a.toLowerCase() == trimmed.toLowerCase());
    await box.put(
      trimmed,
      PersonIdentity(
        name: trimmed,
        aliases: aliasSet.toList()..sort(),
        centroid: prev.centroid,
        faceSamples: prev.faceSamples,
      ).toMap(),
    );
    var updated = 0;
    final detections = _box;
    if (detections != null && trimmed != oldName) {
      for (final key in detections.keys) {
        final entry = lookup(key as String);
        if (entry == null || !entry.faces.any((f) => f.name == oldName)) {
          continue;
        }
        detections.put(
          entry.linkId,
          DetectedEntry(
            linkId: entry.linkId,
            modelVersion: entry.modelVersion,
            detectedAt: entry.detectedAt,
            objects: entry.objects,
            faces: [
              for (final f in entry.faces)
                if (f.name == oldName)
                  DetectedFace(
                    rect: f.rect,
                    embedding: f.embedding,
                    name: trimmed,
                    similarity: f.similarity,
                  )
                else
                  f,
            ],
          ).toMap(),
        );
        updated++;
      }
    }
    notifyListeners();
    return updated;
  }

  /// Combines several identities into one person: all their names become
  /// aliases of the merged identity (the first person's name wins unless a
  /// [primaryName] is given) and every face named after any of them is
  /// renamed to the merged name. Returns the merged identity, or null when
  /// fewer than two identities are provided.
  Future<PersonIdentity?> mergeIdentities(
    List<PersonIdentity> people, {
    String? primaryName,
  }) async {
    final box = _identitiesBox;
    if (box == null || people.length < 2) return null;
    final valid = people.where((p) => box.containsKey(p.name)).toList();
    if (valid.length < 2) return null;

    for (final p in valid) {
      await box.delete(p.name);
    }
    final merged = mergePeople(valid, primary: primaryName);
    await box.put(merged.name, merged.toMap());

    final oldNames = {for (final p in valid) p.name};
    final detections = _box;
    if (detections != null) {
      for (final key in detections.keys) {
        final entry = lookup(key as String);
        if (entry == null || !entry.faces.any((f) => oldNames.contains(f.name))) {
          continue;
        }
        detections.put(
          entry.linkId,
          DetectedEntry(
            linkId: entry.linkId,
            modelVersion: entry.modelVersion,
            detectedAt: entry.detectedAt,
            objects: entry.objects,
            faces: [
              for (final f in entry.faces)
                oldNames.contains(f.name)
                    ? DetectedFace(
                        rect: f.rect,
                        embedding: f.embedding,
                        name: merged.name,
                        similarity: f.similarity,
                      )
                    : f,
            ],
          ).toMap(),
        );
      }
    }
    notifyListeners();
    return merged;
  }

  /// Removes an identity and unnames every face assigned to it. The faces'
  /// embeddings stay behind so they can be named again. Returns the number of
  /// photos that referenced it.
  Future<int> removeIdentity(String name) async {
    final box = _identitiesBox;
    if (box == null) return 0;
    await box.delete(name);
    var updated = 0;
    final detections = _box;
    if (detections != null) {
      for (final key in detections.keys) {
        final entry = lookup(key as String);
        if (entry == null ||
            !entry.faces.any((f) => f.name == name)) {
          continue;
        }
        detections.put(
          entry.linkId,
          DetectedEntry(
            linkId: entry.linkId,
            modelVersion: entry.modelVersion,
            detectedAt: entry.detectedAt,
            objects: entry.objects,
            faces: [
              for (final f in entry.faces)
                if (f.name == name)
                  DetectedFace(rect: f.rect, embedding: f.embedding)
                else
                  f,
            ],
          ).toMap(),
        );
        updated++;
      }
    }
    notifyListeners();
    return updated;
  }

  @override
  Future<void> dispose() async {
    await _box?.close();
    _box = null;
    await _identitiesBox?.close();
    _identitiesBox = null;
    super.dispose();
  }
}