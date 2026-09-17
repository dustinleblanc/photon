import 'package:flutter/foundation.dart';

import 'detection.dart';
import 'detection_index.dart';
import 'faces.dart';
import 'illustration.dart';

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
  int _scanned = 0;
  int _total = 0;
  int _illustrationsFound = 0;
  String? _error;

  bool get running => _running;
  bool get cancelRequested => _cancelRequested;
  int get processed => _processed;

  /// Photos actually (re)processed, as opposed to skipped as already-scanned.
  int get scanned => _scanned;
  int get total => _total;
  double? get progress => _total == 0 ? null : _processed / _total;
  String? get error => _error;

  Future<void> start(List<String> linkIds) async {
    if (_running) return;
    _running = true;
    _cancelRequested = false;
    _processed = 0;
    _scanned = 0;
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
        // Skip only fully-processed photos. Entries whose face pass hasn't
        // run (or whose faces were cleared) are reprocessed so faces come
        // back without a full index reset.
        final existing = _index.lookup(linkId);
        if (existing != null && existing.facesChecked) {
          _processed++;
          continue;
        }
        try {
          final bytes = await _fetchPreview(linkId, size: 1600);
          // Decode + classify off the UI thread; decoding a 1600px JPEG on
          // the main isolate stalls the UI for tens of milliseconds a photo.
          final info = await compute(analysePreviewBytes, bytes);
          if (info == null) throw Exception('unable to decode image');
          final (width, height, isIllustration) = info;
          final objects = await detector.detect(
            bytes: bytes,
            imageWidth: width,
            imageHeight: height,
          );
          var detectedFaces = const <DetectedFace>[];
          // Illustrations (drawings, screenshots) would otherwise feed the
          // face detector cartoon "faces" that pollute people matching, so
          // they are categorised and skipped entirely.
          final hasPeople = !isIllustration &&
              objects
                  .any((o) => groupForLabel(o.label) == DetectionGroup.people);
          if (hasPeople) {
            final detected = await faces.detectFaces(
              bytes: bytes,
              imageWidth: width,
              imageHeight: height,
            );
            // Second line of defense against illustrations the whole-image
            // test missed: drop faces whose crop itself looks drawn.
            detectedFaces = await _withoutDrawnFaces(bytes, detected);
            autoMatchFaces(detectedFaces, matcher: _index.faceMatcher());
          }
          await _index.put(
            DetectedEntry(
              linkId: linkId,
              modelVersion: DetectorService.modelVersion,
              detectedAt: DateTime.now(),
              objects: objects,
              faces: detectedFaces,
              illustration: isIllustration,
              styleChecked: true,
              facesChecked: true,
            ),
          );
          _scanned++;
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

  /// Removes faces whose own crop looks drawn (a cartoon face in an image
  /// the whole-image classifier judged a photo). Runs off the UI thread.
  Future<List<DetectedFace>> _withoutDrawnFaces(
    Uint8List bytes,
    List<DetectedFace> faces,
  ) async {
    if (faces.isEmpty) return faces;
    final coords = <double>[
      for (final f in faces) ...[
        f.rect.left,
        f.rect.top,
        f.rect.right,
        f.rect.bottom,
      ],
    ];
    final flags = await compute(drawnFacesFromBytes, (bytes, coords));
    if (flags == null || flags.length != faces.length) return faces;
    return [
      for (var i = 0; i < faces.length; i++)
        if (!flags[i]) faces[i],
    ];
  }

  /// One-time style pass over already-scanned photos: recomputes the
  /// illustration flag (and drops auto-assigned faces from illustrations)
  /// without re-running object/face detection. Only entries whose flag is
  /// still unknown ([DetectedEntry.styleChecked] false) are revisited, so it
  /// is cheap to run repeatedly until the library is fully classified.
  /// Returns how many photos were classified and how many came out as
  /// illustrations. [force] re-evaluates photos already checked (needed
  /// after the heuristic is tuned).
  Future<({int classified, int illustrations})> classifyStyles(
    List<String> linkIds, {
    bool force = false,
  }) async {
    if (_running) return (classified: 0, illustrations: 0);
    _running = true;
    _cancelRequested = false;
    _processed = 0;
    _error = null;
    _total = 0;
    _illustrationsFound = 0;
    notifyListeners();
    try {
      final pending = [
        for (final id in linkIds)
          if (_index.lookup(id) case final e?
              when force || !e.styleChecked) id,
      ];
      _total = pending.length;
      notifyListeners();
      for (final linkId in pending) {
        if (_cancelRequested) break;
        try {
          final existing = _index.lookup(linkId);
          if (existing == null) continue;
          final bytes = await _fetchPreview(linkId, size: 1600);
          // Decode + classify off the UI thread.
          final isIllustration =
              await compute(classifyIllustrationBytes, bytes);
          if (isIllustration == null) continue;
          if (isIllustration) _illustrationsFound++;
          if (isIllustration) {
            // Illustrations contribute no faces to matching: drop every
            // auto/unnamed face, keeping only tags the user confirmed by
            // hand. (Previously unnamed faces were kept, which is why
            // cartoons kept showing up in the unnamed worklist.)
            final kept = [
              for (final f in existing.faces)
                if ((f.similarity ?? 0) >= 1.0) f,
            ];
            await _index.put(existing.copyWith(
              illustration: true,
              styleChecked: true,
              faces: kept,
            ));
          } else {
            // Not an illustration as a whole, but it may still hold drawn
            // faces (a cartoon on a screen, say). Re-check the stored faces
            // by crop and drop the drawn ones.
            final faces = await _withoutDrawnFaces(bytes, existing.faces);
            await _index.put(existing.copyWith(
              illustration: false,
              styleChecked: true,
              faces: faces,
            ));
          }
        } catch (e) {
          _error = e.toString();
        }
        _processed++;
        notifyListeners();
      }
    } finally {
      _running = false;
      notifyListeners();
    }
    return (
      classified: _processed,
      illustrations: _illustrationsFound,
    );
  }

  void cancel() {
    if (!_running) return;
    _cancelRequested = true;
    notifyListeners();
  }
}