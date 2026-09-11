import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'detection.dart';
import 'detection_index.dart';
import 'faces.dart';

/// Batch-scans a photo library on-device: for each photo it fetches the
/// (already-decrypted) preview bytes, runs object detection in a background
/// isolate, detects faces + embeddings when people are present, and stores
/// the results in the [DetectionIndex]. Progress is exposed via listeners.
class LibraryScanner extends ChangeNotifier {
  LibraryScanner(this._index, this._fetchPreview);

  final DetectionIndex _index;
  final Future<Uint8List> Function(String linkId, {int size}) _fetchPreview;

  DetectorService? _detector;
  FaceRecognitionService? _faces;
  bool _running = false;
  bool _cancelRequested = false;
  int _processed = 0;
  int _total = 0;
  String? _error;

  bool get running => _running;
  bool get cancelRequested => _cancelRequested;
  int get processed => _processed;
  int get total => _total;
  double? get progress => _total == 0 ? null : _processed / _total;
  String? get error => _error;

  Future<void> start(List<String> linkIds) async {
    if (_running) return;
    _running = true;
    _cancelRequested = false;
    _processed = 0;
    _error = null;
    _total = linkIds.length;
    notifyListeners();
    try {
      final detector = DetectorService();
      _detector = detector;
      final faces = FaceRecognitionService();
      _faces = faces;
      for (final linkId in linkIds) {
        if (_cancelRequested) break;
        if (_index.lookup(linkId) != null) {
          _processed++;
          continue;
        }
        try {
          final bytes = await _fetchPreview(linkId, size: 1600);
          final decoded = img.decodeImage(bytes);
          if (decoded == null) throw Exception('unable to decode image');
          final width = decoded.width;
          final height = decoded.height;
          final objects = await detector.detect(
            bytes: bytes,
            imageWidth: width,
            imageHeight: height,
          );
          var detectedFaces = const <DetectedFace>[];
          final hasPeople = objects
              .any((o) => groupForLabel(o.label) == DetectionGroup.people);
          if (hasPeople) {
            detectedFaces = await faces.detectFaces(
              bytes: bytes,
              imageWidth: width,
              imageHeight: height,
            );
            autoMatchFaces(detectedFaces, identities: _index.identities);
          }
          await _index.put(
            DetectedEntry(
              linkId: linkId,
              modelVersion: DetectorService.modelVersion,
              detectedAt: DateTime.now(),
              objects: objects,
              faces: detectedFaces,
            ),
          );
        } catch (e) {
          _error = e.toString();
        }
        _processed++;
        notifyListeners();
      }
    } finally {
      await _detector?.dispose();
      _detector = null;
      await _faces?.dispose();
      _faces = null;
      _running = false;
      notifyListeners();
    }
  }

  void cancel() {
    if (!_running) return;
    _cancelRequested = true;
    notifyListeners();
  }
}