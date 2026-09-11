import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import 'package:photon_library/ml/faces.dart';

/// Smoke-test for face detection on the current host platform. Run with:
///   flutter run -d macos -t tool/macos_face_check.dart
///
/// Reads a photo (FACE_IMAGE or /tmp/two_people.jpg), runs face detection and
/// embedding, prints per-face results to stderr, and exits non-zero when no
/// faces were detected.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final path = Platform.environment['FACE_IMAGE'] ?? '/tmp/two_people.jpg';
  final bytes = await File(path).readAsBytes();
  final decoded = img.decodeImage(bytes);
  if (decoded == null) {
    stderr.writeln('macos_face_check: could not decode $path');
    exit(3);
  }
  stderr.writeln('macos_face_check: input $path ${bytes.length} bytes, '
      '${decoded.width}x${decoded.height}');
  final svc = FaceRecognitionService();
  try {
    final faces = await svc.detectFaces(
      bytes: bytes,
      imageWidth: decoded.width,
      imageHeight: decoded.height,
    );
    stderr.writeln('macos_face_check: detected ${faces.length} faces');
    var i = 0;
    for (final f in faces) {
      stderr.writeln('  face[${i++}] rect=${f.rect} '
          'emb_len=${f.embedding.length} emb_head=${f.embedding.take(4).toList()}');
    }
    if (faces.isEmpty) exit(1);
    final ok =
        faces.every((f) => f.embedding.length == 192 && f.embedding.isNotEmpty);
    exit(ok ? 0 : 2);
  } finally {
    await svc.dispose();
  }
}