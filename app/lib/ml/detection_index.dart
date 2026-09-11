import 'dart:ui' show Rect;

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:hive_ce/hive.dart';
import 'package:path_provider/path_provider.dart';

import '../platform/index_key_store.dart';
import 'detection.dart';
import 'faces.dart';

/// On-device, encrypted-at-rest index of detection results keyed by photo
/// linkId, plus a store of named people (face-recognition identities). The
/// AES key lives in the platform secure storage (or a 0600 file on desktop);
/// nothing in this store ever leaves the device.
class DetectionIndex extends ChangeNotifier {
  static const _boxName = 'detections_v1';
  static const _identitiesBoxName = 'identities_v1';

  Box<Map>? _box;
  Box<Map>? _identitiesBox;
  Object? _openError;
  bool _initializing = false;

  bool get available => _box != null;
  Object? get error => _openError;

  static const keyName = 'photon_ml_index_key';

  /// Opens the boxes. [dirOverride] and [keyOverride] exist for tests; when
  /// null the app-support directory and the platform key store are used.
  Future<void> init({Directory? dirOverride, List<int>? keyOverride}) async {
    if (_box != null || _initializing) return;
    _initializing = true;
    try {
      final dir = dirOverride ?? await getApplicationSupportDirectory();
      Hive.init(dir.path);
      final key = keyOverride ?? await IndexKeyStore.getOrCreate();
      final cipher = HiveAesCipher(key);
      _box = await Hive.openBox<Map>(_boxName, encryptionCipher: cipher);
      _identitiesBox =
          await Hive.openBox<Map>(_identitiesBoxName, encryptionCipher: cipher);
      await clearLowConfidenceAssignments();
    } catch (e) {
      _openError = e;
    } finally {
      _initializing = false;
      notifyListeners();
    }
  }

  /// Removes names that were auto-assigned below the current match threshold
  /// (manual assignments carry similarity 1.0 and are never touched). This
  /// undoes mistaggings left behind when the threshold used to be looser.
  /// Idempotent and cheap; runs on every open.
  Future<void> clearLowConfidenceAssignments() async {
    final box = _box;
    if (box == null) return;
    var changed = false;
    for (final key in box.keys) {
      final entry = lookup(key as String);
      if (entry == null) continue;
      final needsFix = entry.faces.any(
        (f) => f.name != null &&
            f.similarity != null &&
            f.similarity! < kDefaultFaceMatchThreshold,
      );
      if (!needsFix) continue;
      await box.put(
        entry.linkId,
        DetectedEntry(
          linkId: entry.linkId,
          modelVersion: entry.modelVersion,
          detectedAt: entry.detectedAt,
          objects: entry.objects,
          faces: [
            for (final f in entry.faces)
              f.name != null &&
                      f.similarity != null &&
                      f.similarity! < kDefaultFaceMatchThreshold
                  ? DetectedFace(
                      rect: f.rect,
                      embedding: f.embedding,
                      ignored: f.ignored,
                    )
                  : f,
          ],
        ).toMap(),
      );
      changed = true;
    }
    if (changed) notifyListeners();
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
      facesFor(linkId).any((f) => f.name == null && !f.ignored);

  int get scannedCount => _box?.length ?? 0;

  /// All stored entries, for diagnostics tooling only.
  Map<String, DetectedEntry> debugEntries() {
    final box = _box;
    if (box == null) return const {};
    return {
      for (final key in box.keys) key: ?lookup(key as String),
    };
  }

  /// For every named identity, the largest stored face across the library —
  /// the best thumbnail source — keyed by identity name. Pure lookup over the
  /// detection box; callers fetch and crop the photo themselves.
  Map<String, ({String linkId, Rect rect})> bestFaces() {
    final box = _box;
    if (box == null) return const {};
    final best = <String, ({String linkId, Rect rect, double area})>{};
    for (final key in box.keys) {
      final entry = lookup(key as String);
      if (entry == null) continue;
      for (final f in entry.faces) {
        final name = f.name;
        if (name == null) continue;
        final area = f.rect.width * f.rect.height;
        final cur = best[name];
        if (cur == null || area > cur.area) {
          best[name] = (linkId: key, rect: f.rect, area: area);
        }
      }
    }
    return {
      for (final e in best.entries)
        e.key: (linkId: e.value.linkId, rect: e.value.rect),
    };
  }

  /// Every detected-but-unnamed, non-ignored face across the library, in
  /// photo order. This is the worklist for the unnamed-people page.
  List<({String linkId, int faceIndex, Rect rect})> unnamedFaces() {
    final box = _box;
    if (box == null) return const [];
    final out = <({String linkId, int faceIndex, Rect rect})>[];
    for (final key in box.keys) {
      final entry = lookup(key as String);
      if (entry == null) continue;
      for (var i = 0; i < entry.faces.length; i++) {
        final f = entry.faces[i];
        if (f.name == null && !f.ignored) {
          out.add((linkId: key, faceIndex: i, rect: f.rect));
        }
      }
    }
    return out;
  }

  /// Marks the face at [faceIndex] of [linkId] as ignored: it stops counting
  /// as unnamed and drops out of the unnamed-people worklist. The embedding
  /// is kept so the face can still be named later from the photo's panel.
  Future<void> ignoreFace(String linkId, int faceIndex) async {    final entry = lookup(linkId);
    if (entry == null || faceIndex < 0 || faceIndex >= entry.faces.length) {
      return;
    }
    final f = entry.faces[faceIndex];
    entry.faces[faceIndex] = DetectedFace(
      rect: f.rect,
      embedding: f.embedding,
      name: f.name,
      similarity: f.similarity,
      ignored: true,
    );
    await put(entry);
  }

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
        if (entry.faces.any((f) => f.name == null && !f.ignored)) unnamed++;
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
        contactId: prev.contactId,
        contactDisplayName: prev.contactDisplayName,
        contactPhotoUri: prev.contactPhotoUri,
      );
    }
    await box.put(name, next.toMap());
    notifyListeners();
    return next;
  }

  /// Assigns [name] to the face at [faceIndex] of [linkId] and backfills the
  /// name onto every other already-scanned photo whose face matches the
  /// identity. Typed names that belong to an existing identity (canonical or
  /// alias) resolve to that identity instead of creating a duplicate. When
  /// [contactId] is given the identity is linked to that device contact.
  /// Returns the number of newly assigned photos (excluding the one named
  /// directly), or -1 when the face is unavailable.
  Future<int> nameFace({
    required String linkId,
    required int faceIndex,
    required String name,
    String? contactId,
    String? contactDisplayName,
    String? contactPhotoUri,
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
    if (contactId != null && contactId.isNotEmpty) {
      await linkContact(
        forName: canonical,
        contactId: contactId,
        contactDisplayName: contactDisplayName ?? canonical,
        contactPhotoUri: contactPhotoUri,
      );
    }
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
        contactId: prev.contactId,
        contactDisplayName: prev.contactDisplayName,
        contactPhotoUri: prev.contactPhotoUri,
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

  /// Links an identity to a device contact, storing its id, display name and
  /// (optional) photo URI on the identity. Resolution is name/alias aware.
  Future<void> linkContact({
    required String forName,
    required String contactId,
    required String contactDisplayName,
    String? contactPhotoUri,
  }) async {
    final box = _identitiesBox;
    if (box == null) return;
    final canonical = identityForName(forName)?.name ?? forName.trim();
    final raw = box.get(canonical);
    if (raw == null) return;
    final prev = PersonIdentity.fromMap(raw.cast<String, dynamic>());
    await box.put(
      canonical,
      PersonIdentity(
        name: canonical,
        aliases: prev.aliases,
        centroid: prev.centroid,
        faceSamples: prev.faceSamples,
        contactId: contactId,
        contactDisplayName: contactDisplayName,
        contactPhotoUri: contactPhotoUri ?? prev.contactPhotoUri,
      ).toMap(),
    );
    notifyListeners();
  }

  /// Removes an identity's contact link (the identity itself is kept).
  Future<void> unlinkContact(String forName) async {
    final box = _identitiesBox;
    if (box == null) return;
    final canonical = identityForName(forName)?.name ?? forName.trim();
    final raw = box.get(canonical);
    if (raw == null) return;
    final prev = PersonIdentity.fromMap(raw.cast<String, dynamic>());
    await box.put(
      canonical,
      PersonIdentity(
        name: canonical,
        aliases: prev.aliases,
        centroid: prev.centroid,
        faceSamples: prev.faceSamples,
      ).toMap(),
    );
    notifyListeners();
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

  /// Merges identities synced from another device into the local store and
  /// backfills names across stored faces. Matching is by any name (canonical
  /// or alias); unmatched remote identities are inserted as new people, and
  /// matches are merged with a sample-weighted centroid — the side with more
  /// manually-named samples supplies the canonical name. Returns the merged
  /// identity list.
  Future<List<PersonIdentity>> applyRemoteIdentities(
    List<PersonIdentity> remote,
  ) async {
    final box = _identitiesBox;
    if (box == null) return identities;
    final incoming = [
      for (final id in remote)
        if (id.name.trim().isNotEmpty && id.centroid.isNotEmpty) id,
    ];
    if (incoming.isEmpty) return identities;

    final renamedFaces = <String, String>{};
    for (final r in incoming) {
      final local = identityForName(r.name) ??
          _identityForAnyName(r.aliases);
      if (local == null) {
        await box.put(
          r.name,
          PersonIdentity(
            name: r.name,
            aliases: r.aliases,
            centroid: r.centroid,
            faceSamples: r.faceSamples,
          ).toMap(),
        );
        continue;
      }
      final remoteView = PersonIdentity(
        name: r.name,
        aliases: r.aliases,
        centroid: r.centroid,
        faceSamples: r.faceSamples,
      );
      // The side with more manually-named samples wins the canonical name;
      // the local identity goes first so its contact link survives.
      final primary =
          local.faceSamples >= remoteView.faceSamples ? local : remoteView;
      final merged = mergePeople([local, remoteView], primary: primary.name);
      if (local.name != merged.name) {
        await box.delete(local.name);
        renamedFaces[local.name] = merged.name;
      }
      await box.put(merged.name, merged.toMap());
    }
    if (renamedFaces.isNotEmpty) {
      await _renameFaces(renamedFaces);
    }
    await rematchUnnamed();
    return identities;
  }

  PersonIdentity? _identityForAnyName(List<String> names) {
    for (final n in names) {
      final id = identityForName(n);
      if (id != null) return id;
    }
    return null;
  }

  /// Renames faces across all stored entries per the [renames] map.
  Future<void> _renameFaces(Map<String, String> renames) async {
    final detections = _box;
    if (detections == null) return;
    for (final key in detections.keys) {
      final entry = lookup(key as String);
      if (entry == null ||
          !entry.faces.any((f) => renames.containsKey(f.name))) {
        continue;
      }
      await detections.put(
        entry.linkId,
        DetectedEntry(
          linkId: entry.linkId,
          modelVersion: entry.modelVersion,
          detectedAt: entry.detectedAt,
          objects: entry.objects,
          faces: [
            for (final f in entry.faces)
              renames.containsKey(f.name)
                  ? DetectedFace(
                      rect: f.rect,
                      embedding: f.embedding,
                      name: renames[f.name],
                      similarity: f.similarity,
                      ignored: f.ignored,
                    )
                  : f,
          ],
        ).toMap(),
      );
    }
  }

  /// Runs identity matching over every stored unnamed face (ignored faces
  /// are skipped) and assigns names where the centroid similarity clears the
  /// threshold. Returns the number of photos updated.
  Future<int> rematchUnnamed() async {
    final box = _box;
    final ids = identities;
    if (box == null || ids.isEmpty) return 0;
    var updated = 0;
    for (final key in box.keys) {
      final entry = lookup(key as String);
      if (entry == null) continue;
      var changed = false;
      final faces = [
        for (final f in entry.faces)
          if (f.name == null && !f.ignored)
            () {
              final name = matchIdentity(f.embedding, identities: ids);
              if (name == null) return f;
              changed = true;
              return DetectedFace(
                rect: f.rect,
                embedding: f.embedding,
                name: name,
                similarity: faceMatchScore(
                  f.embedding,
                  ids.firstWhere((i) => i.name == name).centroid,
                ),
                ignored: f.ignored,
              );
            }()
          else
            f,
      ];
      if (changed) {
        updated++;
        await box.put(
          entry.linkId,
          DetectedEntry(
            linkId: entry.linkId,
            modelVersion: entry.modelVersion,
            detectedAt: entry.detectedAt,
            objects: entry.objects,
            faces: faces,
          ).toMap(),
        );
      }
    }
    if (updated > 0) notifyListeners();
    return updated;
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