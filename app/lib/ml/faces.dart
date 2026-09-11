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

/// Below this score two faces are treated as different people. The plugin's
/// guidance calls > 0.6 "very likely same person" and > 0.5 "probably same
/// person"; we err on the permissive side so named people are picked up even
/// from varying angles and lighting.
const double kDefaultFaceMatchThreshold = 0.5;

/// A detected face within a photo, with a [0,1]-normalized bounding box and
/// the 192-dim embedding used for identity matching. Persisted in the index.
class DetectedFace {
  DetectedFace({
    required this.rect,
    required this.embedding,
    this.name,
    this.similarity,
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
      );

  final Rect rect;
  final Float32List embedding;

  /// Populated when the face was matched to a known [PersonIdentity].
  String? name;
  double? similarity;

  Map<String, dynamic> toMap() => {
        'x': rect.left,
        'y': rect.top,
        'x2': rect.right,
        'y2': rect.bottom,
        'emb': embedding.toList(),
        'name': name,
        'sim': similarity,
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
        faceSamples: map['samples'] as int,
        contactId: map['contactId'] as String?,
        contactDisplayName: map['contactDisplayName'] as String?,
        contactPhotoUri: map['contactPhotoUri'] as String?,
      );

  final String name;
  final List<String> aliases;
  final Float32List centroid;
  final int faceSamples;
  final String? contactId;
  final String? contactDisplayName;
  final String? contactPhotoUri;

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
      };
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
    samples += p.faceSamples;
    for (var i = 0; i < n; i++) {
      centroid[i] += p.centroid[i] * p.faceSamples;
    }
    for (final name in p.allNames) {
      if (name.trim().isNotEmpty) collected.add(name.trim());
    }
  }
  if (samples > 0) {
    for (var i = 0; i < n; i++) {
      centroid[i] /= samples;
    }
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
  return PersonIdentity(
    name: primaryName,
    aliases: aliases,
    centroid: centroid,
    faceSamples: samples,
    contactId: src?.contactId,
    contactDisplayName: src?.contactDisplayName,
    contactPhotoUri: src?.contactPhotoUri,
  );
}

/// Returns the best-matching identity for [embedding], or null when nothing
/// is above the threshold. Ties prefer the higher score; a higher
/// [threshold] makes matching stricter.
String? matchIdentity(
  Float32List embedding, {
  required List<PersonIdentity> identities,
  double threshold = kDefaultFaceMatchThreshold,
}) {
  String? bestName;
  var bestScore = threshold;
  for (final id in identities) {
    final score = faceMatchScore(embedding, id.centroid);
    if (score >= bestScore) {
      bestScore = score;
      bestName = id.name;
    }
  }
  return bestName;
}

/// Assigns [name] to every face in [faces] that matches [identities] above
/// the threshold. Mutates [faces] in place.
void autoMatchFaces(
  List<DetectedFace> faces, {
  required List<PersonIdentity> identities,
  double threshold = kDefaultFaceMatchThreshold,
}) {
  if (identities.isEmpty) return;
  for (final face in faces) {
    final name = matchIdentity(
      face.embedding,
      identities: identities,
      threshold: threshold,
    );
    if (name != null) {
      final score = faceMatchScore(face.embedding,
          identities.firstWhere((i) => i.name == name).centroid);
      face.name = name;
      face.similarity = score;
    } else {
      face.name = null;
      face.similarity = null;
    }
  }
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
/// out of the image and returns a small JPEG, for face thumbnails.
Uint8List cropFaceJpeg(Uint8List bytes, Rect rect, {int size = 96}) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return Uint8List(0);
  return _cropFaceJpegFrom(decoded, rect, size: size);
}

/// Same as [cropFaceJpeg] but decodes/inspects an existing image once first;
/// pass the result of [decodeForCrop].
Uint8List cropFaceJpegFromDecoded(img.Image image, Rect rect, {int size = 96}) =>
    _cropFaceJpegFrom(image, rect, size: size);

Uint8List _cropFaceJpegFrom(img.Image image, Rect rect, {required int size}) {
  final iw = image.width;
  final ih = image.height;
  final x = (rect.left * iw).round().clamp(0, iw - 1);
  final y = (rect.top * ih).round().clamp(0, ih - 1);
  var w = (rect.width * iw).round();
  var h = (rect.height * ih).round();
  w = w.clamp(1, iw - x);
  h = h.clamp(1, ih - y);
  final cropped = img.copyResize(
    img.copyCrop(image, x: x, y: y, width: w, height: h),
    width: size,
  );
  return Uint8List.fromList(img.encodeJpg(cropped, quality: 80));
}