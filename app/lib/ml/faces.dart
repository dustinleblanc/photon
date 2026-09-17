import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:face_detection_tflite/face_detection_tflite.dart' as fdt;
import 'package:image/image.dart' as img;

/// Cosine similarity between two normalized embeddings, in [-1, 1].
double cosineSimilarity(Float32List a, Float32List b) {
  if (a.length != b.length || a.isEmpty) return 0;
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  final denominator = sqrt(na) * sqrt(nb);
  if (denominator == 0) return 0;
  return (dot / denominator).clamp(-1.0, 1.0);
}

/// Similarity score produced by the embedding model's comparison metric
/// (MobileFaceNet). The same people are typically > 0.6, "probably same"
/// above 0.5, different below 0.3.
double faceMatchScore(Float32List a, Float32List b) =>
    fdt.FaceDetector.compareFaces(a, b);

/// Below this score two faces are treated as different people. Raised to
/// 0.70 after auditing a real library: half of the automatic assignments
/// landed below 0.70 and accounted for nearly all the surprising matches.
/// The plugin's guidance only calls > 0.6 "very likely same", but in practice
/// relatives cluster there, so automatic naming now demands 0.70.
const double kDefaultFaceMatchThreshold = 0.70;

/// Minimum similarity to an identity's medoid sample for that sample to be
/// kept when building its centroid. Confirmed samples of one person should
/// cluster tightly; a "confirmed" face far from the cluster is a wrong name
/// and must not drag the centroid (which caused both misses for the real
/// person and matches for the wrong one).
const double kSampleConsensusFloor = 0.45;

/// Indices of the largest coherent cluster in [samples]: the medoid (the
/// sample with the highest mean similarity to the rest) plus everything
/// within [floor] of it. Returns all indices when there are too few samples
/// to judge.
List<int> coherentSamples(
  List<Float32List> samples, {
  double floor = kSampleConsensusFloor,
}) {
  if (samples.length < 3) {
    return [for (var i = 0; i < samples.length; i++) i];
  }
  var bestIdx = 0;
  var bestMean = -2.0;
  for (var i = 0; i < samples.length; i++) {
    var sum = 0.0;
    for (var j = 0; j < samples.length; j++) {
      if (i == j) continue;
      sum += faceMatchScore(samples[i], samples[j]);
    }
    final mean = sum / (samples.length - 1);
    if (mean > bestMean) {
      bestMean = mean;
      bestIdx = i;
    }
  }
  final medoid = samples[bestIdx];
  return [
    for (var i = 0; i < samples.length; i++)
      if (faceMatchScore(samples[i], medoid) >= floor) i,
  ];
}

/// The coherent subset of [samples] (see [coherentSamples]).
List<Float32List> trimSamples(
  List<Float32List> samples, {
  double floor = kSampleConsensusFloor,
}) =>
    [for (final i in coherentSamples(samples, floor: floor)) samples[i]];

/// Minimum average similarity among an identity's confirmed samples for the
/// set to be trusted. Below this the samples are mixed (wrong names), and a
/// centroid built from them matches nobody reliably.
const double kMinIdentityCohesion = 0.45;

/// How far an identity's *centroid* similarity may sit below the threshold
/// while a single confirmed sample still clears it. Max-over-samples gives
/// recall for pose/angle variation, but without this a face that only matches
/// one outlier sample could be named; the centroid must be broadly close too.
const double kCentroidFloorDelta = 0.05;

/// Upper bound on a plausible sample count. Nothing in the app produces more,
/// but a corrupt sync document did: using those values as merge weights
/// exploded a centroid to ~1e36, after which every face scored as a
/// non-match. Counts outside `[0, kMaxFaceSamples]` are treated as 0.
const int kMaxFaceSamples = 1000000;

/// Clamps a raw stored/synced sample count to a plausible value.
int sanitizeSamples(Object? raw) {
  final value = raw is int ? raw : (raw is num ? raw.toInt() : 0);
  return value < 0 || value > kMaxFaceSamples ? 0 : value;
}

/// How much better the best identity match must be than the runner-up for an
/// automatic assignment. Lookalikes (siblings, kids) routinely clear the
/// absolute threshold for more than one person; requiring a margin keeps
/// ambiguous faces unnamed instead of confidently wrong.
const double kFaceMatchMargin = 0.05;

/// Faces smaller than this fraction of the photo's area are treated as
/// background crowd: detected but not auto-tagged, not shown in the
/// unnamed-people worklist, and not stored as identity samples. They remain
/// visible in the photo's People panel where they can be named manually —
/// the manual path is how genuinely small but important faces get tagged.
const double kMinAutoFaceArea = 0.015;

/// Matches face embeddings against identities using each identity's centroid
/// plus every confirmed (manually named) sample embedding, taking the best
/// score. Two effects grow with confirmation:
///
/// - Recall: max-over-samples catches pose/angle variation that the mean
///   blurs away, so a profile shot matches the one stored profile.
/// - Certainty: the effective threshold eases down slightly per confirmed
///   sample (bounded), so a well-confirmed person matches more of their own
///   faces while brand-new identities stay strict.
///
/// Auto-assigned faces are deliberately excluded from the sample set: a
/// wrong auto-tag would otherwise vote for itself and cascade.
class FaceMatcher {
  FaceMatcher({required this.identities, this.confirmedSamples = const {}});

  final List<PersonIdentity> identities;
  final Map<String, List<Float32List>> confirmedSamples;
  final Map<String, Float32List> _centroidCache = {};

  PersonIdentity identityFor(String name) =>
      identities.firstWhere((i) => i.name == name);

  /// The centroid used for matching: derived from the identity's coherent
  /// confirmed samples when there are enough of them, falling back to the
  /// stored centroid. This keeps a contaminated sample set from dragging the
  /// mean, which caused both misses and bad matches.
  Float32List effectiveCentroid(PersonIdentity id) {
    final cached = _centroidCache[id.name];
    if (cached != null) return cached;
    final list = confirmedSamples[id.name];
    if (list == null || list.length < 3) {
      _centroidCache[id.name] = id.centroid;
      return id.centroid;
    }
    final kept = trimSamples(list);
    if (kept.length < 2) {
      _centroidCache[id.name] = id.centroid;
      return id.centroid;
    }
    final centroid = Float32List(id.centroid.length);
    for (final sample in kept) {
      for (var i = 0; i < centroid.length; i++) {
        centroid[i] += sample[i];
      }
    }
    for (var i = 0; i < centroid.length; i++) {
      centroid[i] /= kept.length;
    }
    _centroidCache[id.name] = centroid;
    return centroid;
  }

  /// Best similarity between [embedding] and any of [id]'s references (the
  /// effective centroid or any coherent confirmed sample).
  double scoreFor(Float32List embedding, PersonIdentity id) {
    final list = confirmedSamples[id.name];
    final coherent = (list != null && list.length >= 3)
        ? trimSamples(list)
        : (list ?? const <Float32List>[]);
    var best = faceMatchScore(embedding, effectiveCentroid(id));
    for (final sample in coherent) {
      final s = faceMatchScore(embedding, sample);
      if (s > best) best = s;
    }
    return best;
  }

  /// The identity [embedding] belongs to, or null when nothing matches
  /// strictly enough.
  ///
  /// Three gates must all pass:
  /// - **Peak**: the best match (centroid or any confirmed sample) clears the
  ///   threshold — this gives recall for pose/angle variation.
  /// - **Broad**: that identity's centroid is also close, so a single outlier
  ///   sample can't name a face on its own.
  /// - **Decisive**: no other identity's centroid is within the margin, so
  ///   lookalikes stay unnamed instead of being guessed.
  String? match(Float32List embedding) {
    PersonIdentity? bestId;
    var bestPeak = 0.0;
    var bestCentroid = 0.0;
    for (final id in identities) {
      final peak = scoreFor(embedding, id);
      final centroid = faceMatchScore(embedding, effectiveCentroid(id));
      if (bestId == null || peak > bestPeak) {
        bestId = id;
        bestPeak = peak;
        bestCentroid = centroid;
      }
    }
    if (bestId == null) return null;
    if (bestPeak < kDefaultFaceMatchThreshold) return null;
    if (bestCentroid < kDefaultFaceMatchThreshold - kCentroidFloorDelta) {
      return null;
    }
    for (final id in identities) {
      if (id.name == bestId.name) continue;
      final centroid = faceMatchScore(embedding, effectiveCentroid(id));
      if (centroid >= kDefaultFaceMatchThreshold &&
          bestPeak - centroid < kFaceMatchMargin) {
        return null;
      }
    }
    return bestId.name;
  }
}

/// A detected face within a photo, with a [0,1]-normalized bounding box and
/// the 192-dim embedding used for identity matching. Persisted in the index.
class DetectedFace {
  DetectedFace({
    required this.rect,
    required this.embedding,
    this.name,
    this.similarity,
    this.ignored = false,
  });

  factory DetectedFace.fromMap(Map<String, dynamic> map) => DetectedFace(
        rect: Rect.fromLTRB(
          (map['x'] as num).toDouble(),
          (map['y'] as num).toDouble(),
          (map['x2'] as num).toDouble(),
          (map['y2'] as num).toDouble(),
        ),
        embedding: Float32List.fromList(
          (map['emb'] as List).cast<num>().map((e) => e.toDouble()).toList(),
        ),
        name: map['name'] as String?,
        similarity: (map['sim'] as num?)?.toDouble(),
        ignored: map['ign'] as bool? ?? false,
      );

  final Rect rect;
  final Float32List embedding;

  /// Populated when the face was matched to a known [PersonIdentity].
  String? name;
  double? similarity;

  /// True when the user opted this face out of naming entirely; ignored
  /// faces never count as unnamed and are skipped by auto-matching.
  bool ignored;

  Map<String, dynamic> toMap() => {
        'x': rect.left,
        'y': rect.top,
        'x2': rect.right,
        'y2': rect.bottom,
        'emb': embedding.toList(),
        'name': name,
        'sim': similarity,
        if (ignored) 'ign': true,
      };
}

/// A named person. [name] is the canonical name; [aliases] are other names
/// the same person goes by. [centroid] is the running mean of the embeddings
/// of the faces the user has explicitly assigned to this identity. When the
/// person is linked to a device contact, the contact's id and display name
/// (and photo URI, if any) are stored alongside everything else.
class PersonIdentity {
  PersonIdentity({
    required this.name,
    this.aliases = const [],
    required this.centroid,
    required this.faceSamples,
    this.contactId,
    this.contactDisplayName,
    this.contactPhotoUri,
    this.coverLinkId,
    this.hidden = false,
  });

  factory PersonIdentity.fromMap(Map<String, dynamic> map) => PersonIdentity(
        name: map['name'] as String,
        aliases: ((map['aliases'] as List?) ?? const [])
            .cast<String>()
            .toList(),
        centroid: Float32List.fromList(
          (map['centroid'] as List)
              .cast<num>()
              .map((e) => e.toDouble())
              .toList(),
        ),
        faceSamples: sanitizeSamples(map['samples']),
        contactId: map['contactId'] as String?,
        contactDisplayName: map['contactDisplayName'] as String?,
        contactPhotoUri: map['contactPhotoUri'] as String?,
        coverLinkId: map['coverLinkId'] as String?,
        hidden: map['hidden'] as bool? ?? false,
      );

  final String name;
  final List<String> aliases;
  final Float32List centroid;
  final int faceSamples;
  final String? contactId;
  final String? contactDisplayName;
  final String? contactPhotoUri;

  /// Photo the user chose to represent this person in the app. Local
  /// preference; falls back to the largest confirmed face when unset.
  final String? coverLinkId;

  /// Local preference: hidden people are left out of the default timeline
  /// and People list, and are only shown when explicitly sought out.
  final bool hidden;

  /// Every name this person is known by, canonical first.
  List<String> get allNames => [name, ...aliases];

  bool get linkedToContact => contactId != null && contactId!.isNotEmpty;

  Map<String, dynamic> toMap() => {
        'name': name,
        'aliases': aliases,
        'centroid': centroid.toList(),
        'samples': faceSamples,
        'contactId': contactId,
        'contactDisplayName': contactDisplayName,
        'contactPhotoUri': contactPhotoUri,
        if (coverLinkId != null) 'coverLinkId': coverLinkId,
        if (hidden) 'hidden': true,
      };

  /// Same identity with selected fields replaced. Rewrite paths use this so
  /// local-only preferences like [hidden] and contact links are never
  /// silently dropped.
  PersonIdentity copyWith({
    String? name,
    List<String>? aliases,
    Float32List? centroid,
    int? faceSamples,
    String? contactId,
    String? contactDisplayName,
    String? contactPhotoUri,
    String? coverLinkId,
    bool? hidden,
  }) =>
      PersonIdentity(
        name: name ?? this.name,
        aliases: aliases ?? this.aliases,
        centroid: centroid ?? this.centroid,
        faceSamples: faceSamples ?? this.faceSamples,
        contactId: contactId ?? this.contactId,
        contactDisplayName: contactDisplayName ?? this.contactDisplayName,
        contactPhotoUri: contactPhotoUri ?? this.contactPhotoUri,
        coverLinkId: coverLinkId ?? this.coverLinkId,
        hidden: hidden ?? this.hidden,
      );
}

/// Combines several identities into one: centroid is the sample-weighted mean,
/// names are unioned (the first person's canonical name wins unless [primary]
/// is given), and [faceSamples] is the total. Pure and testable; the index
/// uses this when two named people turn out to be the same person.
PersonIdentity mergePeople(
  List<PersonIdentity> people, {
  String? primary,
}) {
  final n = people.isEmpty ? 0 : people.first.centroid.length;
  final centroid = Float32List(n);
  var samples = 0;
  final collected = <String>{};
  for (final p in people) {
    final usableCentroid = p.centroid.length == n && _saneCentroid(p.centroid);
    if (usableCentroid) {
      // Never let an out-of-range sample count act as a merge weight; treat it
      // as a single sample instead. Using the raw value is what exploded
      // centroids to ~1e36.
      final weight = p.faceSamples <= 0 || p.faceSamples > kMaxFaceSamples
          ? 1
          : p.faceSamples;
      samples += weight;
      for (var i = 0; i < n; i++) {
        centroid[i] += p.centroid[i] * weight;
      }
    }
    for (final name in p.allNames) {
      if (name.trim().isNotEmpty) collected.add(name.trim());
    }
  }
  if (samples > 0) {
    for (var i = 0; i < n; i++) {
      centroid[i] /= samples;
    }
  } else if (people.isNotEmpty && people.first.centroid.length == n) {
    // Nothing usable to average: fall back to the primary person's centroid.
    centroid.setAll(0, people.first.centroid);
  }
  final names = collected.toList();
  var primaryName = primary?.trim() ?? '';
  if (primaryName.isEmpty && names.isNotEmpty) primaryName = names.first;
  if (primaryName.isEmpty) primaryName = 'Unnamed';
  final aliases =
      names.where((e) => e.toLowerCase() != primaryName.toLowerCase()).toList()
        ..sort();
  // Keep the first person's contact link (if any) across the merge.
  final src = people.isNotEmpty ? people.first : null;
  // Hiding is honoured if any merged person was hidden, so merging can't
  // accidentally surface someone the user chose to hide.
  final hidden = people.any((p) => p.hidden);
  String? cover;
  for (final p in people) {
    if (p.coverLinkId != null) {
      cover = p.coverLinkId;
      break;
    }
  }
  return PersonIdentity(
    name: primaryName,
    aliases: aliases,
    centroid: centroid,
    faceSamples: samples,
    contactId: src?.contactId,
    contactDisplayName: src?.contactDisplayName,
    contactPhotoUri: src?.contactPhotoUri,
    coverLinkId: cover,
    hidden: hidden,
  );
}

/// True when [v] looks like a real embedding centroid: finite components at
/// embedding scale. A corrupted (exploded) centroid fails this and must not
/// pollute a merge.
bool _saneCentroid(Float32List v) {
  var sum = 0.0;
  for (final x in v) {
    if (!x.isFinite || x.abs() > 1e3) return false;
    sum += x * x;
  }
  return sum <= 1e6;
}

/// Assigns names to every face in [faces] that [matcher] matches decisively.
/// A person is assigned at most once per photo — the highest-scoring face
/// wins, later (weaker) faces of the same person are left unnamed. Faces
/// smaller than [kMinAutoFaceArea] are background crowd and are never
/// auto-assigned. Mutates [faces] in place.
void autoMatchFaces(
  List<DetectedFace> faces, {
  required FaceMatcher matcher,
}) {
  final taken = <String>{};
  // Highest score first so the best face of a person claims the slot.
  final order = [
    for (var i = 0; i < faces.length; i++) i,
  ]..sort((a, b) {
      final sa = _bestScore(faces[a], matcher);
      final sb = _bestScore(faces[b], matcher);
      return sb.compareTo(sa);
    });
  for (final i in order) {
    final face = faces[i];
    final tiny = face.rect.width * face.rect.height < kMinAutoFaceArea;
    final name = tiny ? null : matcher.match(face.embedding);
    if (name == null || taken.contains(name)) {
      face.name = null;
      face.similarity = null;
      continue;
    }
    taken.add(name);
    face.name = name;
    face.similarity =
        matcher.scoreFor(face.embedding, matcher.identityFor(name));
  }
}

double _bestScore(DetectedFace face, FaceMatcher matcher) {
  var best = 0.0;
  for (final id in matcher.identities) {
    final s = matcher.scoreFor(face.embedding, id);
    if (s > best) best = s;
  }
  return best;
}

/// Wraps the on-device face detector + MobileFaceNet embedder. All inference
/// runs in a background isolate provided by the plugin.
class FaceRecognitionService {
  fdt.FaceDetector? _detector;
  bool _disposed = false;

  Future<fdt.FaceDetector> ensureReady() async {
    final existing = _detector;
    if (existing != null) return existing;
    final detector = await fdt.FaceDetector.create();
    _detector = detector;
    return detector;
  }

  /// Per-face detector and mesh confidence for [bytes]. Used by style
  /// calibration tooling; the normal matching path stores embeddings only.
  Future<List<({double detection, double mesh})>> faceScores(
    Uint8List bytes,
  ) async {
    final detector = await ensureReady();
    final faces = await detector.detectFacesFromBytes(
      bytes,
      mode: fdt.FaceDetectionMode.standard,
    );
    return [
      for (final f in faces)
        (
          detection: f.detectionData.score,
          mesh: f.mesh?.score ?? 0.0,
        ),
    ];
  }

  /// Detects faces and computes each one's embedding. Embedded faces with a
  /// missing embedding are dropped. [imageWidth]/[imageHeight] are the pixel
  /// dimensions of the encoded [bytes].
  Future<List<DetectedFace>> detectFaces({
    required Uint8List bytes,
    required int imageWidth,
    required int imageHeight,
  }) async {
    final detector = await ensureReady();
    final faces = await detector.detectFacesFromBytes(
      bytes,
      mode: fdt.FaceDetectionMode.standard,
    );
    if (faces.isEmpty) return const [];
    final embeddings = await detector.getFaceEmbeddings(faces, bytes);
    final w = imageWidth == 0 ? 1 : imageWidth;
    final h = imageHeight == 0 ? 1 : imageHeight;
    const unit = Rect.fromLTWH(0, 0, 1, 1);
    final out = <DetectedFace>[];
    for (var i = 0; i < faces.length; i++) {
      final embedding = embeddings[i];
      if (embedding == null || embedding.isEmpty) continue;
      final bb = faces[i].boundingBox;
      out.add(
        DetectedFace(
          rect: Rect.fromLTRB(
            bb.topLeft.x / w,
            bb.topLeft.y / h,
            bb.bottomRight.x / w,
            bb.bottomRight.y / h,
          ).intersect(unit),
          embedding: embedding,
        ),
      );
    }
    return out;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _detector?.dispose();
    _detector = null;
  }
}

/// Crops [rect] (normalized, relative to the decoded dimensions of [bytes])
/// out of the image and returns a small JPEG, for face thumbnails. The crop
/// is padded by [padding] on every side (relative to the face size) so tight
/// or tiny faces keep some context.
Uint8List cropFaceJpeg(Uint8List bytes, Rect rect, {int size = 96}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return Uint8List(0);
  return _cropFaceJpegFrom(decoded, rect, size: size);
}

/// Same as [cropFaceJpeg] but decodes/inspects an existing image once first;
/// pass the result of [decodeForCrop].
Uint8List cropFaceJpegFromDecoded(img.Image image, Rect rect, {int size = 96}) =>
    _cropFaceJpegFrom(image, rect, size: size);

Uint8List _cropFaceJpegFrom(
  img.Image image,
  Rect rect, {
  required int size,
  double padding = 0.35,
}) {
  final iw = image.width;
  final ih = image.height;
  final pw = rect.width * padding;
  final ph = rect.height * padding;
  final padded = Rect.fromLTRB(
    (rect.left - pw).clamp(0.0, 1.0),
    (rect.top - ph).clamp(0.0, 1.0),
    (rect.right + pw).clamp(0.0, 1.0),
    (rect.bottom + ph).clamp(0.0, 1.0),
  );
  final x = (padded.left * iw).round().clamp(0, iw - 1);
  final y = (padded.top * ih).round().clamp(0, ih - 1);
  var w = (padded.width * iw).round();
  var h = (padded.height * ih).round();
  w = w.clamp(1, iw - x);
  h = h.clamp(1, ih - y);
  final cropped = img.copyResize(
    img.copyCrop(image, x: x, y: y, width: w, height: h),
    width: size,
  );
  return Uint8List.fromList(img.encodeJpg(cropped, quality: 80));
}