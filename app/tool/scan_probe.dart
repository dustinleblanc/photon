import 'dart:io';

import 'package:flutter/material.dart';

import 'package:photon_library/api/serve_client.dart';
import 'package:photon_library/ml/detection_index.dart';
import 'package:photon_library/ml/library_scanner.dart';

/// Runs the real scan pipeline over a handful of photos to isolate failures.
///   COUNT=5 flutter run -d macos -t tool/scan_probe.dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final count = int.tryParse(Platform.environment['COUNT'] ?? '5') ?? 5;
  final index = DetectionIndex();
  await index.init();

  final entries = index.debugEntries();
  var unchecked = 0;
  for (final e in entries.values) {
    if (!e.facesChecked) unchecked++;
  }
  stderr.writeln('scan_probe: entries=${entries.length} '
      'facesCheckedPending=$unchecked');
  final ids = entries.keys.take(count).toList();
  stderr.writeln('scan_probe: testing ${ids.length} photos');

  final client = ServeClient();
  final scanner = LibraryScanner(
    index,
    (linkId, {int size = 512}) => client.preview(linkId, size: size),
  );

  // Fetch check first, so a network/session problem is obvious.
  for (final id in ids.take(2)) {
    try {
      final bytes = await client.preview(id, size: 1600);
      stderr.writeln('scan_probe: fetch $id ok (${bytes.length} bytes)');
    } catch (e) {
      stderr.writeln('scan_probe: fetch $id FAILED: $e');
    }
  }

  await scanner.start(ids);
  stderr.writeln('scan_probe: processed=${scanner.processed} '
      'total=${scanner.total} error=${scanner.error}');
  for (final id in ids) {
    final e = index.lookup(id);
    stderr.writeln('scan_probe: $id objects=${e?.objects.length} '
        'faces=${e?.faces.length} illustration=${e?.illustration} '
        'facesChecked=${e?.facesChecked}');
  }
  await index.dispose();
  exit(0);
}
