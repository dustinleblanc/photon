import 'dart:ui' show Rect;

import 'dart:async';
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
  /// Decoded-entry cache. lookup() is called per photo on every gallery
  /// rebuild, and DetectedEntry.fromMap decodes embeddings; without this,
  /// rebuilds during a scan (which notifies per photo) re-decode the whole
  /// library repeatedly and the UI crawls.
  final Map<String, DetectedEntry> _entryCache = {};

  /// Decoded-identity cache. The gallery asks for the hidden-person set per
  /// photo while filtering, which would otherwise re-decode every identity
  /// thousands of times per rebuild. Cleared on every notify (see [_notify]),
  /// so it can never go stale.
  List<PersonIdentity>? _identitiesCache;

  /// Memoized [countPeople] result; dropped on every index change.
  Map<String, int>? _peopleCounts;

  /// Memoized [bestFaces] result; dropped on every index change. It walks the
  /// whole library, so recomputing it on every People-page build (tab
  /// switches, scroll rebuilds) was a noticeable lag.
  Map<String, ({String linkId, Rect rect})>? _bestFacesCache;

  /// Memoized distinct object labels; dropped on every index change.
  Set<String>? _labelsCache;
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
      await reconcileAutoAssignedNames();
      await reconcileIdentities();
      // Name any unnamed faces that now match (e.g. after a corrupt centroid
      // was healed above). Idempotent and respects the threshold + margin.
      await rematchUnnamed();
    } catch (e) {
      _openError = e;
    } finally {
      _initializing = false;
      _notify();
    }
  }

  /// Re-derives every auto-assigned face name against the current identities
  /// and the current matching rules (threshold + ambiguity margin), clearing
  /// names that no longer hold. Manual assignments (similarity 1.0) are
  /// never touched. This undoes mistaggings left behind by looser rules —
  /// e.g. a lookalike auto-named during backfill — and runs on every open.
  /// Idempotent and cheap: a few hundred faces times a handful of identities.
  Future<void> reconcileAutoAssignedNames() async {
    final box = _box;
    if (box == null) return;
    if (identities.isEmpty) return;
    final matcher = faceMatcher();
    var changed = false;
    for (final key in box.keys.toList()) {
      final entry = lookup(key as String);
      if (entry == null) continue;
      final needsCheck = entry.faces.any(
        (f) =>
            f.name != null &&
            !f.ignored &&
            (f.similarity == null || f.similarity! < 1.0),
      );
      if (!needsCheck) continue;
      await _writeEntry(
        entry.copyWith(
          faces: [
            for (final f in entry.faces)
              if (f.name != null &&
                  !f.ignored &&
                  (f.similarity == null || f.similarity! < 1.0))
                () {
                  final resolved = matcher.match(f.embedding);
                  final autoMatchable = _isAutoMatchable(f);
                  if (resolved == f.name && autoMatchable) {
                    return f;
                  }
                  changed = true;
                  if (resolved == null || !autoMatchable) {
                    return DetectedFace(
                      rect: f.rect,
                      embedding: f.embedding,
                      ignored: f.ignored,
                    );
                  }
                  // The rules changed since this tag was written; reassign
                  // to whoever matches now instead of just clearing.
                  return DetectedFace(
                    rect: f.rect,
                    embedding: f.embedding,
                    name: resolved,
                    similarity: matcher.scoreFor(
                      f.embedding,
                      matcher.identityFor(resolved),
                    ),
                    ignored: f.ignored,
                  );
                }()
              else
                f,
          ],
        ),
      );
    }
    if (changed) _notify();
  }

  /// Rebuilds centroids and sample counts that were corrupted. A bad sync
  /// document supplied out-of-range sample counts; used as merge weights they
  /// exploded a centroid to ~1e36, after which every face scored as a
  /// non-match (e.g. Dustin had 0 auto-matches despite dozens of photos).
  ///
  /// For an identity with locally, manually named faces (similarity 1.0) whose
  /// stored centroid is unusable, the centroid is re-derived as the mean of
  /// those embeddings and the sample count set to their number. Identities
  /// with no local manual faces are left alone (their centroid may be a valid
  /// merged result from another device); only an out-of-range sample count is
  /// reset. Runs on every open; cheap and idempotent.
  Future<void> reconcileIdentities() async {
    final idBox = _identitiesBox;
    if (idBox == null) return;

    final manual = <String, List<Float32List>>{};
    final box = _box;
    if (box != null) {
      for (final key in box.keys.toList()) {
        final entry = lookup(key as String);
        if (entry == null) continue;
        for (final f in entry.faces) {
          final name = f.name;
          if (name == null || (f.similarity ?? 0) < 1.0) continue;
          (manual[name] ??= <Float32List>[]).add(f.embedding);
        }
      }
    }

    var changed = false;
    for (final key in idBox.keys.toList()) {
      final raw = idBox.get(key);
      if (raw is! Map) continue;
      final map = raw.cast<String, dynamic>();
      final name = map['name'] as String? ?? '$key';
      final stored = (map['centroid'] as List?) ?? const [];
      final samplesRaw = map['samples'];
      final samplesBad =
          samplesRaw is! int || samplesRaw != sanitizeSamples(samplesRaw);

      final faces = manual[name];
      final canRebuild =
          faces != null && faces.isNotEmpty && _centroidUnusable(stored);

      if (canRebuild) {
        final length = faces.first.length;
        if (length == 0 || faces.any((f) => f.length != length)) continue;
        final rebuilt = Float32List(length);
        for (final f in faces) {
          for (var i = 0; i < length; i++) {
            rebuilt[i] += f[i];
          }
        }
        for (var i = 0; i < length; i++) {
          rebuilt[i] /= faces.length;
        }
        await _putIdentity(
          key,
          PersonIdentity(
            name: name,
            aliases: ((map['aliases'] as List?) ?? const [])
                .cast<String>()
                .toList(),
            centroid: rebuilt,
            faceSamples: faces.length,
            contactId: map['contactId'] as String?,
            contactDisplayName: map['contactDisplayName'] as String?,
            contactPhotoUri: map['contactPhotoUri'] as String?,
            coverLinkId: map['coverLinkId'] as String?,
            hidden: map['hidden'] as bool? ?? false,
          ),
        );
        changed = true;
      } else if (samplesBad) {
        await _putIdentity(
          key,
          PersonIdentity(
            name: name,
            aliases: ((map['aliases'] as List?) ?? const [])
                .cast<String>()
                .toList(),
            centroid: Float32List.fromList(
              stored.map((e) => (e as num).toDouble()).toList(),
            ),
            faceSamples: sanitizeSamples(samplesRaw),
            contactId: map['contactId'] as String?,
            contactDisplayName: map['contactDisplayName'] as String?,
            contactPhotoUri: map['contactPhotoUri'] as String?,
            coverLinkId: map['coverLinkId'] as String?,
            hidden: map['hidden'] as bool? ?? false,
          ),
        );
        changed = true;
      }
    }
    if (changed) _notify();
  }

  DetectedEntry? lookup(String linkId) {
    final cached = _entryCache[linkId];
    if (cached != null) return cached;
    final raw = _box?.get(linkId);
    if (raw == null) return null;
    try {
      final entry = DetectedEntry.fromMap(linkId, raw.cast<String, dynamic>());
      if (entry.modelVersion != DetectorService.modelVersion) return null;
      _entryCache[linkId] = entry;
      return entry;
    } catch (_) {
      return null;
    }
  }

  /// Notify listeners, dropping the identity cache first so a rebuild always
  /// sees current data. Every mutation path calls this (directly or via
  /// put/notifyListeners).
  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _notifyTimer;

  /// Coalesced change notification. During a scan the index changes once per
  /// photo; notifying on each one made every screen (and the People grid)
  /// rebuild dozens of times a minute, which is what made scrolling and tab
  /// switches jittery. Bursts are collapsed to at most one notification per
  /// [_notifyInterval].
  static const _notifyInterval = Duration(milliseconds: 120);

  void _notify() {
    _identitiesCache = null;
    _peopleCounts = null;
    _bestFacesCache = null;
    final elapsed = DateTime.now().difference(_lastNotify);
    if (elapsed >= _notifyInterval) {
      _lastNotify = DateTime.now();
      notifyListeners();
      return;
    }
    _notifyTimer ??= Timer(_notifyInterval - elapsed, () {
      _notifyTimer = null;
      _lastNotify = DateTime.now();
      notifyListeners();
    });
  }

  /// Identity write that invalidates the decoded-identity cache. Used instead
  /// of touching the identities box directly, so the cache can't go stale
  /// even when a write happens without an immediate notify.
  Future<void> _putIdentity(String key, PersonIdentity id) async {
    await _identitiesBox?.put(key, id.toMap());
    _identitiesCache = null;
  }

  Future<void> _deleteIdentity(String key) async {
    await _identitiesBox?.delete(key);
    _identitiesCache = null;
  }

  Future<void> put(DetectedEntry entry) async {
    await _box?.put(entry.linkId, entry.toMap());
    _entryCache[entry.linkId] = entry;
    _notify();
  }

  /// Raw write that keeps the decode cache coherent. Used by the batch
  /// rewrite paths that defer their notifyListeners to the end.
  Future<void> _writeEntry(DetectedEntry entry) async {
    await _box?.put(entry.linkId, entry.toMap());
    _entryCache[entry.linkId] = entry;
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
      facesFor(linkId).any(_isUnnamedWorkable);

  /// A face counts as unnamed work when it has no name, isn't ignored, and
  /// is big enough to plausibly be a subject rather than background crowd
  /// (tiny faces are handled through the photo's People panel instead).
  bool _isUnnamedWorkable(DetectedFace f) =>
      f.name == null && !f.ignored && _isAutoMatchable(f);

  /// Faces this size or larger are eligible for automatic naming; smaller
  /// ones are background crowd and are named only by hand.
  bool _isAutoMatchable(DetectedFace f) =>
      f.rect.width * f.rect.height >= kMinAutoFaceArea;

  int get scannedCount => _box?.length ?? 0;

  /// All stored entries, for diagnostics tooling only.
  Map<String, DetectedEntry> debugEntries() {
    final box = _box;
    if (box == null) return const {};
    return {
      for (final key in box.keys) key: ?lookup(key as String),
    };
  }

  /// For every named identity, the best stored face across the library for a
  /// thumbnail — keyed by identity name. Faces the user confirmed manually
  /// (similarity 1.0) always win; among auto-assigned faces, higher
  /// similarity wins, with area as the tiebreaker, so a large but
  /// low-confidence mis-tag never becomes someone's portrait. Pure lookup
  /// over the detection box; callers fetch and crop the photo themselves.
  Map<String, ({String linkId, Rect rect})> bestFaces() {
    final cached = _bestFacesCache;
    if (cached != null) return cached;
    final box = _box;
    if (box == null) return const {};
    final best = <String, ({String linkId, Rect rect, double area, double sim})>{};
    for (final key in box.keys.toList()) {
      final entry = lookup(key as String);
      if (entry == null) continue;
      for (final f in entry.faces) {
        final name = f.name;
        if (name == null) continue;
        final area = f.rect.width * f.rect.height;
        final sim = f.similarity ?? 0.0;
        final cur = best[name];
        final better = cur == null ||
            sim > cur.sim + 0.001 ||
            (sim > cur.sim - 0.001 && area > cur.area);
        if (better) {
          best[name] = (linkId: key, rect: f.rect, area: area, sim: sim);
        }
      }
    }
    final out = {
      for (final e in best.entries)
        e.key: (linkId: e.value.linkId, rect: e.value.rect),
    };
    _bestFacesCache = out;
    return out;
  }

  /// Every detected-but-unnamed, non-ignored face across the library, in
  /// photo order. This is the worklist for the unnamed-people page.
  List<({String linkId, int faceIndex, Rect rect})> unnamedFaces() {
    final box = _box;
    if (box == null) return const [];
    final out = <({String linkId, int faceIndex, Rect rect})>[];
    for (final key in box.keys.toList()) {
      final entry = lookup(key as String);
      if (entry == null || entry.illustration) continue;
      for (var i = 0; i < entry.faces.length; i++) {
        final f = entry.faces[i];
        if (_isUnnamedWorkable(f)) {
          out.add((linkId: key, faceIndex: i, rect: f.rect));
        }
      }
    }
    return out;
  }

  /// Groups unnamed faces that look like the same unknown person, so the
  /// worklist shows one tile per person instead of one per photo. Greedy
  /// medoid clustering at [threshold] (conservative: relatives are the risk,
  /// and a merged tile names every member when confirmed).
  List<List<({String linkId, int faceIndex, Rect rect})>> unnamedClusters({
    double threshold = 0.72,
  }) {
    final faces = unnamedFaces();
    final clusters = <List<({String linkId, int faceIndex, Rect rect})>>[];
    final medoids = <Float32List>[];
    for (final f in faces) {
      final entry = lookup(f.linkId);
      if (entry == null || f.faceIndex >= entry.faces.length) continue;
      final emb = entry.faces[f.faceIndex].embedding;
      if (emb.isEmpty) continue;
      var placed = false;
      for (var i = 0; i < medoids.length; i++) {
        if (faceMatchScore(emb, medoids[i]) >= threshold) {
          clusters[i].add(f);
          placed = true;
          break;
        }
      }
      if (!placed) {
        medoids.add(emb);
        clusters.add([f]);
      }
    }
    return clusters;
  }

  /// Marks the face at [faceIndex] of [linkId] as ignored: it stops counting
  /// as unnamed and drops out of the unnamed-people worklist. The embedding
  /// is kept so the face can still be named later from the photo's panel.
  /// Marks or unmarks a photo as an illustration by hand, overriding the
  /// image heuristic. Marking drops auto-assigned faces (manual tags stay)
  /// and excludes the photo from face matching; unmarking makes it eligible
  /// again.
  Future<void> setIllustration(String linkId, bool illustration) async {
    final entry = lookup(linkId);
    if (entry == null) return;
    final faces = illustration
        ? [
            for (final f in entry.faces)
              if (f.name == null || (f.similarity ?? 0) >= 1.0) f,
          ]
        : entry.faces;
    await put(entry.copyWith(
      illustration: illustration,
      styleChecked: true,
      faces: faces,
    ));
  }

  /// Ignores this face *wherever it appears*: every stored face whose
  /// embedding matches it within [threshold] is marked ignored and any tag
  /// (auto or manual) is dropped, so a person wrongly matched to a face is
  /// removed from all their photos at once and the face stops appearing as
  /// unnamed work. Returns how many faces were ignored.
  Future<int> ignoreFaceEverywhere(
    String linkId,
    int faceIndex, {
    double threshold = kDefaultFaceMatchThreshold,
  }) async {
    final box = _box;
    final source = lookup(linkId)?.faces;
    if (box == null ||
        source == null ||
        faceIndex < 0 ||
        faceIndex >= source.length) {
      return 0;
    }
    final target = source[faceIndex].embedding;
    if (target.isEmpty) return 0;
    var count = 0;
    final keys = box.keys.toList();
    for (var k = 0; k < keys.length; k++) {
      final key = keys[k];
      // Yield periodically so a library-wide ignore keeps the UI responsive.
      if (k % 200 == 0) await Future<void>.delayed(Duration.zero);
      final entry = lookup(key as String);
      if (entry == null) continue;
      var changed = false;
      final faces = [
        for (final f in entry.faces)
          if (!f.ignored &&
              f.embedding.isNotEmpty &&
              faceMatchScore(f.embedding, target) >= threshold)
            () {
              changed = true;
              count++;
              return DetectedFace(
                rect: f.rect,
                embedding: f.embedding,
                ignored: true,
              );
            }()
          else
            f,
      ];
      if (changed) await _writeEntry(entry.copyWith(faces: faces));
    }
    _notify();
    return count;
  }

  Future<void> clear() async {
    await _box?.clear();
    await _identitiesBox?.clear();
    _entryCache.clear();
    _notify();
  }

  // ---------------------------------------------------------------------------
  // Identities (named people)
  // ---------------------------------------------------------------------------

  /// All named identities, sorted by name.
  List<PersonIdentity> get identities {
    final cached = _identitiesCache;
    if (cached != null) return cached;
    final box = _identitiesBox;
    if (box == null) return const [];
    final out = [
      for (final value in box.values)
        PersonIdentity.fromMap(value.cast<String, dynamic>()),
    ]..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    _identitiesCache = out;
    return out;
  }

  /// Names of identities the user chose to hide from the default timeline.
  Set<String> get hiddenNames => {
        for (final id in identities)
          if (id.hidden) id.name,
      };

  /// True when this photo has a named face belonging to a hidden person.
  bool hasHiddenPerson(String linkId) =>
      peopleFor(linkId).any(hiddenNames.contains);

  /// Hides or unhides a person. Hidden people are omitted from the default
  /// grid and People list; their photos remain reachable by explicitly
  /// filtering on the person.
  Future<void> setPersonHidden(String name, bool hidden) async {
    final box = _identitiesBox;
    if (box == null) return;
    final existing = identityForName(name);
    if (existing == null) return;
    await _putIdentity(existing.name, existing.copyWith(hidden: hidden));
    _notify();
  }

  /// Chooses the photo that represents [name] in the app. Passing null
  /// reverts to the automatic choice (largest confirmed face).
  Future<void> setPersonCover(String name, String? linkId) async {
    final existing = identityForName(name);
    if (existing == null) return;
    final updated = PersonIdentity(
      name: existing.name,
      aliases: existing.aliases,
      centroid: existing.centroid,
      faceSamples: existing.faceSamples,
      contactId: existing.contactId,
      contactDisplayName: existing.contactDisplayName,
      contactPhotoUri: existing.contactPhotoUri,
      coverLinkId: linkId,
      hidden: existing.hidden,
    );
    await _putIdentity(existing.name, updated);
    _notify();
  }

  /// Photos in which [name] has a detected face, for the cover picker.
  /// Largest faces first (best crops), capped so the sheet stays snappy.
  List<String> coversFor(String name) {
    final box = _box;
    if (box == null) return const [];
    final scored = <({String linkId, double area})>[];
    for (final key in box.keys.toList()) {
      final entry = lookup(key as String);
      if (entry == null || entry.illustration) continue;
      var best = 0.0;
      for (final f in entry.faces) {
        if (f.name != name) continue;
        final area = f.rect.width * f.rect.height;
        if (area > best) best = area;
      }
      if (best > 0) scored.add((linkId: key, area: best));
    }
    scored.sort((a, b) => b.area.compareTo(a.area));
    return [for (final s in scored.take(60)) s.linkId];
  }

  /// The rect of the first face named [name] in [linkId], for rendering a
  /// chosen cover photo. Null when the photo has no such face.
  Rect? faceRectIn(String linkId, String name) {
    final entry = lookup(linkId);
    if (entry == null) return null;
    for (final f in entry.faces) {
      if (f.name == name) return f.rect;
    }
    return null;
  }

  /// Removes [name]'s tag from every face and resets the identity's centroid
  /// so a contaminated sample set can't keep mis-matching. The identity
  /// itself (and its aliases/contact/cover) is kept, ready to be re-taught.
  Future<int> clearPersonFaces(String name) async {
    final box = _box;
    final idBox = _identitiesBox;
    if (box == null) return 0;
    var updated = 0;
    for (final key in box.keys.toList()) {
      final entry = lookup(key as String);
      if (entry == null || !entry.faces.any((f) => f.name == name)) continue;
      await _writeEntry(entry.copyWith(
        faces: [
          for (final f in entry.faces)
            if (f.name == name)
              DetectedFace(rect: f.rect, embedding: f.embedding, ignored: f.ignored)
            else
              f,
        ],
      ));
      updated++;
    }
    final existing = identityForName(name);
    if (idBox != null && existing != null) {
      await _putIdentity(
        existing.name,
        PersonIdentity(
          name: existing.name,
          aliases: existing.aliases,
          centroid: Float32List(existing.centroid.length),
          faceSamples: 0,
          contactId: existing.contactId,
          contactDisplayName: existing.contactDisplayName,
          contactPhotoUri: existing.contactPhotoUri,
          coverLinkId: existing.coverLinkId,
          hidden: existing.hidden,
        ),
      );
    }
    _notify();
    return updated;
  }

  /// Repairs every identity whose confirmed samples are incoherent: keeps
  /// the largest tight cluster around the identity's medoid, unnames the
  /// outlier faces (they are wrong names), and rebuilds the centroid and
  /// sample count from the kept cluster. This is what removes the
  /// contaminated samples that caused both missed matches for the real
  /// person and bad matches for others.
  Future<({int identitiesRepaired, int facesCleared})> repairIdentities() async {
    final det = _box;
    final idBox = _identitiesBox;
    if (det == null || idBox == null) {
      return (identitiesRepaired: 0, facesCleared: 0);
    }
    // Gather manually-confirmed samples with their location.
    final byName = <String, List<({String linkId, int index, Float32List emb})>>{};
    for (final key in det.keys.toList()) {
      final entry = lookup(key as String);
      if (entry == null) continue;
      for (var i = 0; i < entry.faces.length; i++) {
        final f = entry.faces[i];
        final n = f.name;
        if (n == null || f.ignored) continue;
        if ((f.similarity ?? 0) < 1.0) continue;
        (byName[n] ??= []).add((linkId: entry.linkId, index: i, emb: f.embedding));
      }
    }

    var repaired = 0;
    var cleared = 0;
    var processed = 0;
    for (final id in identities) {
      // Keep the UI painting across a whole-library repair.
      if (processed++ % 5 == 0) await Future<void>.delayed(Duration.zero);
      final list = byName[id.name];
      if (list == null || list.length < 3) continue;
      final keepList = coherentSamples([for (final s in list) s.emb]);
      final keep = keepList.toSet();
      // Is the kept cluster actually coherent? If the "confirmed" samples
      // don't agree (a person's samples scoring ~0.38 against each other
      // means the set is mixed), there is no trustworthy profile to build:
      // better to clear it so the person can be re-taught from good photos.
      final keptEmb = [for (final i in keepList) list[i].emb];
      var cohesion = 1.0;
      if (keptEmb.length >= 2) {
        var sum = 0.0;
        var pairs = 0;
        for (var i = 0; i < keptEmb.length; i++) {
          for (var j = i + 1; j < keptEmb.length; j++) {
            sum += faceMatchScore(keptEmb[i], keptEmb[j]);
            pairs++;
          }
        }
        cohesion = sum / pairs;
      }
      // Keep a coherent cluster of as few as two confirmations: with only a
      // handful of confirmations, a single wrong face used to drop the whole
      // set below the "three samples" bar and wipe genuine tags as well.
      // Now the good pair survives and only the outlier is dropped.
      final incoherent =
          keptEmb.length < 2 || cohesion < kMinIdentityCohesion;
      if (incoherent) {
        // Clear every confirmation for this person.
        for (final s in list) {
          final entry = lookup(s.linkId);
          if (entry == null) continue;
          await _writeEntry(entry.copyWith(
            faces: [
              for (var i = 0; i < entry.faces.length; i++)
                if (i == s.index)
                  DetectedFace(
                    rect: entry.faces[i].rect,
                    embedding: entry.faces[i].embedding,
                    ignored: entry.faces[i].ignored,
                  )
                else
                  entry.faces[i],
            ],
          ));
        }
        cleared += list.length;
        await _putIdentity(
          id.name,
          PersonIdentity(
            name: id.name,
            aliases: id.aliases,
            centroid: Float32List(id.centroid.length),
            faceSamples: 0,
            contactId: id.contactId,
            contactDisplayName: id.contactDisplayName,
            contactPhotoUri: id.contactPhotoUri,
            coverLinkId: id.coverLinkId,
            hidden: id.hidden,
          ),
        );
        repaired++;
        continue;
      }
      final dropped = [
        for (var i = 0; i < list.length; i++)
          if (!keep.contains(i)) list[i],
      ];
      if (dropped.isEmpty && keep.length == list.length) continue;

      // Unname the outliers, entry by entry.
      final byLink = <String, List<int>>{};
      for (final d in dropped) {
        (byLink[d.linkId] ??= []).add(d.index);
      }
      for (final e in byLink.entries) {
        final entry = lookup(e.key);
        if (entry == null) continue;
        final drop = e.value.toSet();
        await _writeEntry(entry.copyWith(
          faces: [
            for (var i = 0; i < entry.faces.length; i++)
              if (drop.contains(i))
                DetectedFace(
                  rect: entry.faces[i].rect,
                  embedding: entry.faces[i].embedding,
                  ignored: entry.faces[i].ignored,
                )
              else
                entry.faces[i],
          ],
        ));
        cleared += drop.length;
      }

      // Rebuild the centroid from the kept cluster.
      final centroid = Float32List(id.centroid.length);
      var kept = 0;
      for (var i = 0; i < list.length; i++) {
        if (!keep.contains(i)) continue;
        kept++;
        for (var j = 0; j < centroid.length; j++) {
          centroid[j] += list[i].emb[j];
        }
      }
      if (kept > 0) {
        for (var j = 0; j < centroid.length; j++) {
          centroid[j] /= kept;
        }
      }
      await _putIdentity(
        id.name,
        PersonIdentity(
          name: id.name,
          aliases: id.aliases,
          centroid: centroid,
          faceSamples: kept,
          contactId: id.contactId,
          contactDisplayName: id.contactDisplayName,
          contactPhotoUri: id.contactPhotoUri,
          coverLinkId: id.coverLinkId,
          hidden: id.hidden,
        ),
      );
      repaired++;
    }
    _notify();
    return (identitiesRepaired: repaired, facesCleared: cleared);
  }

  /// Clears every face name and every named identity while KEEPING the
  /// detected faces (and their embeddings) and object detections. The
  /// unnamed-people queue therefore stays populated with everything that was
  /// previously tagged, ready to be named again. Use [resetIndex] to drop
  /// detections entirely.
  Future<int> clearAllFaces() async {
    final box = _box;
    final idBox = _identitiesBox;
    final keys = box?.keys.toList() ?? const [];
    var updated = 0;
    for (var i = 0; i < keys.length; i++) {
      final entry = lookup(keys[i] as String);
      if (entry == null || !entry.faces.any((f) => f.name != null)) continue;
      await _writeEntry(entry.copyWith(
        faces: [
          for (final f in entry.faces)
            // Unname but keep the embedding so the face can be re-matched.
            DetectedFace(rect: f.rect, embedding: f.embedding, ignored: f.ignored),
        ],
      ));
      updated++;
      // Yield periodically so the UI keeps painting on a big library.
      if (i % 200 == 0) await Future<void>.delayed(Duration.zero);
    }
    await idBox?.clear();
    _identitiesCache = null;
    _notify();
    return updated;
  }

  /// Wipes the entire on-device ML index — object detections, face tags and
  /// named people — so scanning can start from zero. Unlike [clearAllFaces]
  /// this deletes the boxes outright (no per-entry rewrite), so it is
  /// instant even on a huge library.
  Future<int> resetIndex() async {
    final box = _box;
    final idBox = _identitiesBox;
    final removed = box?.length ?? 0;
    await box?.clear();
    await idBox?.clear();
    _entryCache.clear();
    _identitiesCache = null;
    _peopleCounts = null;
    _notify();
    return removed;
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
  /// Photo counts per person (plus [kUnnamedPeople]). Immutable and
  /// memoized: it walks the whole library, and the person page asks for it
  /// on every rebuild. Invalidated whenever the index changes.
  Map<String, int> countPeople() {
    final cached = _peopleCounts;
    if (cached != null) return cached;
    final counts = <String, int>{};
    var unnamed = 0;
    final box = _box;
    if (box != null) {
      for (final key in box.keys.toList()) {
        final entry = lookup(key as String);
        if (entry == null) continue;
        final names = entry.people;
        for (final name in names) {
          counts[name] = (counts[name] ?? 0) + 1;
        }
        if (entry.faces.any(_isUnnamedWorkable)) unnamed++;
      }
    }
    counts[kUnnamedPeople] = unnamed;
    _peopleCounts = counts;
    return counts;
  }

  /// True when [linkId] has a face named exactly [name]. Allocation-free
  /// (unlike peopleFor, which builds a Set per photo per rebuild).
  bool hasPerson(String linkId, String name) {
    final entry = lookup(linkId);
    if (entry == null) return false;
    for (final f in entry.faces) {
      if (f.name == name) return true;
    }
    return false;
  }

  /// True when [linkId] has a face named any of [names].
  bool hasAnyPerson(String linkId, Set<String> names) {
    if (names.isEmpty) return false;
    final entry = lookup(linkId);
    if (entry == null) return false;
    for (final f in entry.faces) {
      final n = f.name;
      if (n != null && names.contains(n)) return true;
    }
    return false;
  }

  /// True when [linkId] contains an object detected as [label] (exact match).
  bool hasLabel(String linkId, String label) {
    final entry = lookup(linkId);
    if (entry == null) return false;
    for (final o in entry.objects) {
      if (o.label == label) return true;
    }
    return false;
  }

  /// Distinct object labels present in the library, memoized (dropped on
  /// every index change). Used by the search bar so a label like
  /// "motorcycle" can surface photos without needing its own menu entry.
  Set<String> get labels {
    final cached = _labelsCache;
    if (cached != null) return cached;
    final box = _box;
    if (box == null) return const {};
    final out = <String>{};
    for (final key in box.keys) {
      final entry = lookup(key as String);
      if (entry == null) continue;
      for (final o in entry.objects) {
        out.add(o.label);
      }
    }
    _labelsCache = out;
    return out;
  }

  /// Labels matching [query] (case-insensitive substring), for search.
  List<String> searchLabels(String query) {
    final q = query.trim().toLowerCase();
    if (q.isEmpty) return const [];
    final out = [for (final l in labels) if (l.toLowerCase().contains(q)) l]
      ..sort();
    return out;
  }

  /// True when [linkId] belongs to [group], without building a group Set.
  bool hasGroup(String linkId, DetectionGroup group) {
    final entry = lookup(linkId);
    if (entry == null) return false;
    if (group == DetectionGroup.illustrations) return entry.illustration;
    for (final o in entry.objects) {
      if (groupForLabel(o.label) == group) return true;
    }
    return false;
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
      // Clamp the prior count so a corrupt value can't skew the running mean.
      final n = prev.faceSamples <= 0 || prev.faceSamples > kMaxFaceSamples
          ? 0
          : prev.faceSamples;
      final centroid = Float32List(embedding.length);
      for (var i = 0; i < centroid.length; i++) {
        centroid[i] =
            (prev.centroid[i] * n + embedding[i]) / (n + 1);
      }
      final known = <String>{...prev.aliases, ...aliases}
          .where((a) => a.toLowerCase() != name.toLowerCase())
          .toList();
      next = prev.copyWith(
        name: name,
        aliases: known,
        centroid: centroid,
        faceSamples: n + 1,
      );
    }
    await _putIdentity(name, next);
    _notify();
    return next;
  }

  /// Assigns [name] to the face at [faceIndex] of [linkId] and backfills the
  /// name onto every other already-scanned photo whose face matches the
  /// identity. Typed names that belong to an existing identity (canonical or
  /// alias) resolve to that identity instead of creating a duplicate. When
  /// [contactId] is given the identity is linked to that device contact.
  ///
  /// A person appears at most once per photo: when another face in this
  /// photo is already [canonical], this call is refused with -2 rather than
  /// silently creating a double-tagged photo.
  ///
  /// Returns the number of newly assigned photos (excluding the one named
  /// directly), -1 when the face is unavailable, or -2 on the duplicate rule.
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

    final duplicate = entry.faces
        .where((f) => f.name == canonical && !f.ignored)
        .length;
    if (duplicate > 0) return -2;

    await upsertIdentity(canonical, face.embedding);
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
      final matcher = faceMatcher();
      var i = 0;
      for (final key in box.keys.toList()) {
        i++;
        final other = key == linkId ? null : lookup(key as String);
        if (other == null) continue;
        var changed = false;
        // One identity per photo: knowing whether this photo already has
        // [canonical] decides if a correction may move a face here.
        var hasCanonical = other.faces.any(
          (f) => f.name == canonical && !f.ignored,
        );
        for (var j = 0; j < other.faces.length; j++) {
          final f = other.faces[j];
          if (f.ignored) continue;
          if (f.name == null) {
            final name = matcher.match(f.embedding);
            if (name == null) continue;
            other.faces[j] = DetectedFace(
              rect: f.rect,
              embedding: f.embedding,
              name: name,
              similarity: matcher.scoreFor(
                f.embedding,
                matcher.identityFor(name),
              ),
            );
            if (name == canonical) hasCanonical = true;
            changed = true;
            continue;
          }
          if (f.name == canonical) continue;
          // Correction propagation: a face already tagged as someone else
          // but which now matches [canonical] more strongly is a mis-tag.
          // Manually confirmed faces are never overridden, and the new name
          // must beat the old one by the ambiguity margin.
          if ((f.similarity ?? 0) >= 1.0) continue;
          if (hasCanonical) continue;
          if (matcher.match(f.embedding) != canonical) continue;
          final target = matcher.identityFor(canonical);
          final current = identityForName(f.name!);
          final newScore = matcher.scoreFor(f.embedding, target);
          final oldScore =
              current == null ? 0.0 : matcher.scoreFor(f.embedding, current);
          if (newScore - oldScore < kFaceMatchMargin) continue;
          other.faces[j] = DetectedFace(
            rect: f.rect,
            embedding: f.embedding,
            name: canonical,
            similarity: newScore,
          );
          hasCanonical = true;
          changed = true;
        }
        if (changed) {
          matched++;
          await _writeEntry(other);
          if (i % 25 == 0) await Future<void>.delayed(Duration.zero);
        }
      }
    }
    _notify();
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

    await _deleteIdentity(oldName);
    final aliasSet = <String>{...prev.aliases, ...aliases}
      ..removeWhere((a) => a.toLowerCase() == trimmed.toLowerCase());
    await _putIdentity(
      trimmed,
      prev.copyWith(name: trimmed, aliases: aliasSet.toList()..sort()),
    );
    var updated = 0;
    final detections = _box;
    if (detections != null && trimmed != oldName) {
      for (final key in detections.keys.toList()) {
        final entry = lookup(key as String);
        if (entry == null || !entry.faces.any((f) => f.name == oldName)) {
          continue;
        }
        await _writeEntry(
          entry.copyWith(
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
          ),
        );
        updated++;
      }
    }
    _notify();
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
    await _putIdentity(
      canonical,
      prev.copyWith(
        name: canonical,
        contactId: contactId,
        contactDisplayName: contactDisplayName,
        contactPhotoUri: contactPhotoUri ?? prev.contactPhotoUri,
      ),
    );
    _notify();
  }

  /// Removes an identity's contact link (the identity itself is kept).
  Future<void> unlinkContact(String forName) async {
    final box = _identitiesBox;
    if (box == null) return;
    final canonical = identityForName(forName)?.name ?? forName.trim();
    final raw = box.get(canonical);
    if (raw == null) return;
    final prev = PersonIdentity.fromMap(raw.cast<String, dynamic>());
    await _putIdentity(
      canonical,
      PersonIdentity(
        name: canonical,
        aliases: prev.aliases,
        centroid: prev.centroid,
        faceSamples: prev.faceSamples,
        coverLinkId: prev.coverLinkId,
        hidden: prev.hidden,
      ),
    );
    _notify();
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
      await _deleteIdentity(p.name);
    }
    final merged = mergePeople(valid, primary: primaryName);
    await _putIdentity(merged.name, merged);

    final oldNames = {for (final p in valid) p.name};
    final detections = _box;
    if (detections != null) {
      for (final key in detections.keys.toList()) {
        final entry = lookup(key as String);
        if (entry == null || !entry.faces.any((f) => oldNames.contains(f.name))) {
          continue;
        }
        await _writeEntry(
          entry.copyWith(
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
          ),
        );
      }
    }
    _notify();
    return merged;
  }

  /// Builds a [FaceMatcher] over the current identities, gathering confirmed
  /// (manually named, similarity 1.0, non-ignored) face embeddings from the
  /// detection box as per-identity samples. Auto-assigned faces are excluded
  /// so a wrong auto-tag can't vote for itself.
  FaceMatcher faceMatcher() {
    final ids = identities;
    final samples = <String, List<Float32List>>{};
    final box = _box;
    if (box != null) {
      for (final key in box.keys.toList()) {
        final entry = lookup(key as String);
        if (entry == null) continue;
        for (final f in entry.faces) {
          final name = f.name;
          if (name == null || f.ignored) continue;
          if (f.similarity == null || f.similarity! < 1.0) continue;
          // Tiny faces have weak, poorly-separating embeddings (audited: a
          // person's small faces scored ~0.38 against each other), so they
          // are not evidence. Contaminated larger samples are filtered
          // downstream by the matcher's medoid-consensus trimming.
          if (f.rect.width * f.rect.height < kMinAutoFaceArea) continue;
          (samples[name] ??= []).add(f.embedding);
        }
      }
    }
    return FaceMatcher(identities: ids, confirmedSamples: samples);
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
        await _putIdentity(
          r.name,
          PersonIdentity(
            name: r.name,
            aliases: r.aliases,
            centroid: r.centroid,
            faceSamples: r.faceSamples,
          ),
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
        await _deleteIdentity(local.name);
        renamedFaces[local.name] = merged.name;
      }
      await _putIdentity(merged.name, merged);
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
    for (final key in detections.keys.toList()) {
      final entry = lookup(key as String);
      if (entry == null ||
          !entry.faces.any((f) => renames.containsKey(f.name))) {
        continue;
      }
      await _writeEntry(
        entry.copyWith(
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
        ),
      );
    }
  }

  /// Runs identity matching over every stored unnamed face (ignored faces
  /// are skipped) and assigns names where the matcher is decisive. Returns
  /// the number of photos updated.
  Future<int> rematchUnnamed() async {
    final box = _box;
    if (box == null || identities.isEmpty) return 0;
    final matcher = faceMatcher();
    var updated = 0;
    for (final key in box.keys.toList()) {
      final entry = lookup(key as String);
      if (entry == null || entry.illustration) continue;
      var changed = false;
      final faces = [
        for (final f in entry.faces)
          if (f.name == null && !f.ignored && _isAutoMatchable(f))
            () {
              final name = matcher.match(f.embedding);
              if (name == null) return f;
              changed = true;
              return DetectedFace(
                rect: f.rect,
                embedding: f.embedding,
                name: name,
                similarity: matcher.scoreFor(
                  f.embedding,
                  matcher.identityFor(name),
                ),
                ignored: f.ignored,
              );
            }()
          else
            f,
      ];
      if (changed) {
        updated++;
        await _writeEntry(entry.copyWith(faces: faces));
      }
    }
    if (updated > 0) _notify();
    return updated;
  }

  /// Removes an identity and unnames every face assigned to it. The faces'
  /// embeddings stay behind so they can be named again. Returns the number of
  /// photos that referenced it.
  Future<int> removeIdentity(String name) async {
    final box = _identitiesBox;
    if (box == null) return 0;
    await _deleteIdentity(name);
    var updated = 0;
    final detections = _box;
    if (detections != null) {
      for (final key in detections.keys.toList()) {
        final entry = lookup(key as String);
        if (entry == null ||
            !entry.faces.any((f) => f.name == name)) {
          continue;
        }
        await _writeEntry(
          entry.copyWith(
            faces: [
              for (final f in entry.faces)
                if (f.name == name)
                  DetectedFace(rect: f.rect, embedding: f.embedding)
                else
                  f,
            ],
          ),
        );
        updated++;
      }
    }
    _notify();
    return updated;
  }

  @override
  Future<void> dispose() async {
    _notifyTimer?.cancel();
    _notifyTimer = null;
    await _box?.close();
    _box = null;
    await _identitiesBox?.close();
    _identitiesBox = null;
    super.dispose();
  }
}

/// True when a stored centroid is missing, non-numeric, non-finite, or at a
/// magnitude no real embedding centroid reaches (it is a mean of unit-ish
/// vectors, so components stay around [-1, 1]).
bool _centroidUnusable(List<dynamic> stored) {
  if (stored.isEmpty) return true;
  var sum = 0.0;
  for (final v in stored) {
    if (v is! num) return true;
    final d = v.toDouble();
    if (!d.isFinite || d.abs() > 1e3) return true;
    sum += d * d;
  }
  return !sum.isFinite || sum > 1e6;
}