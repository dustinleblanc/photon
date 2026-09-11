import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:object_detection/object_detection.dart' as od;

import 'faces.dart';

/// High-level buckets used by the library filters. Labels outside these sets
/// fall into [DetectionGroup.objects].
enum DetectionGroup {
  people('People', Icons.face),
  pets('Pets', Icons.pets),
  objects('Objects', Icons.category);

  const DetectionGroup(this.label, this.icon);
  final String label;
  final IconData icon;
}

const _petLabels = {
  'cat',
  'dog',
  'bird',
  'horse',
  'sheep',
  'cow',
  'elephant',
  'bear',
  'zebra',
  'giraffe',
};

const _humanLabels = {'person'};

/// Maps a COCO label to its [DetectionGroup].
DetectionGroup groupForLabel(String label) {
  if (_humanLabels.contains(label)) return DetectionGroup.people;
  if (_petLabels.contains(label)) return DetectionGroup.pets;
  return DetectionGroup.objects;
}

/// Distinct groups present across [labels].
Set<DetectionGroup> groupsForLabels(Iterable<String> labels) =>
    labels.map(groupForLabel).toSet();

/// A single detected object with a [0,1]-normalized bounding box.
class DetectedObjectInfo {
  const DetectedObjectInfo({
    required this.label,
    required this.score,
    required this.rect,
  });

  factory DetectedObjectInfo.fromMap(Map<String, dynamic> map) =>
      DetectedObjectInfo(
        label: map['label'] as String,
        score: (map['score'] as num).toDouble(),
        rect: Rect.fromLTRB(
          (map['x'] as num).toDouble(),
          (map['y'] as num).toDouble(),
          (map['x2'] as num).toDouble(),
          (map['y2'] as num).toDouble(),
        ),
      );

  final String label;
  final double score;
  final Rect rect;

  Map<String, dynamic> toMap() => {
        'label': label,
        'score': score,
        'x': rect.left,
        'y': rect.top,
        'x2': rect.right,
        'y2': rect.bottom,
      };
}

/// Detection results for one photo, keyed by linkId in the index.
class DetectedEntry {
  const DetectedEntry({
    required this.linkId,
    required this.modelVersion,
    required this.detectedAt,
    required this.objects,
    this.faces = const [],
  });

  factory DetectedEntry.fromMap(String linkId, Map<String, dynamic> map) =>
      DetectedEntry(
        linkId: linkId,
        modelVersion: map['modelVersion'] as int,
        detectedAt: DateTime.parse(map['detectedAt'] as String),
        objects: (map['objects'] as List)
            .map(
              (e) => DetectedObjectInfo.fromMap(
                (e as Map).cast<String, dynamic>(),
              ),
            )
            .toList(),
        faces: (map['faces'] as List? ?? const [])
            .map(
              (e) => DetectedFace.fromMap((e as Map).cast<String, dynamic>()),
            )
            .toList(),
      );

  final String linkId;
  final int modelVersion;
  final DateTime detectedAt;
  final List<DetectedObjectInfo> objects;
  final List<DetectedFace> faces;

  Set<DetectionGroup> get groups =>
      groupsForLabels(objects.map((o) => o.label));

  /// The set of named people present in this photo.
  Set<String> get people => {
        for (final f in faces)
          if (f.name != null) f.name!,
      };

  Map<String, dynamic> toMap() => {
        'modelVersion': modelVersion,
        'detectedAt': detectedAt.toIso8601String(),
        'objects': [for (final o in objects) o.toMap()],
        'faces': [for (final f in faces) f.toMap()],
      };
}

/// Wraps the on-device object detector. Inference runs in a background
/// isolate provided by the plugin; nothing leaves the phone.
class DetectorService {
  DetectorService([this._model = _defaultModel]);

  static const _defaultModel = od.ObjectDetectionModel.efficientDetLite2;

  final od.ObjectDetectionModel _model;
  od.ObjectDetector? _detector;
  bool _disposed = false;

  static const int modelVersion = 2;

  Future<void> ensureReady() async {
    final existing = _detector;
    if (existing != null) return;
    _detector = await od.ObjectDetector.create(model: _model);
  }

  Future<List<DetectedObjectInfo>> detect({
    required Uint8List bytes,
    required int imageWidth,
    required int imageHeight,
    double scoreThreshold = 0.45,
  }) async {
    await ensureReady();
    final results = await _detector!.detect(
      bytes,
      options: od.ObjectDetectorOptions(
        scoreThreshold: scoreThreshold,
        maxResults: 25,
      ),
    );
    final w = imageWidth == 0 ? 1 : imageWidth;
    final h = imageHeight == 0 ? 1 : imageHeight;
    const unit = Rect.fromLTWH(0, 0, 1, 1);
    return [
      for (final d in results)
        if (d.categoryName != '???')
          DetectedObjectInfo(
            label: d.categoryName,
            score: d.score,
            rect: Rect.fromLTRB(
              d.boundingBox.topLeft.x / w,
              d.boundingBox.topLeft.y / h,
              d.boundingBox.bottomRight.x / w,
              d.boundingBox.bottomRight.y / h,
            ).intersect(unit),
          ),
    ];
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _detector?.dispose();
    _detector = null;
  }
}