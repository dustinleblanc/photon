import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import 'package:photon_library/ml/detection_index.dart';

/// Verifies the encrypted index opens and roundtrips identities on the host.
/// Run: flutter run -d macos -t tool/macos_index_check.dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final index = DetectionIndex();
  await index.init();
  stderr.writeln('macos_index_check: available=${index.available} '
      'error=${index.error}');
  if (!index.available) {
    stderr.writeln('macos_index_check: INDEX DID NOT OPEN');
    exit(1);
  }
  try {
    final emb = Float32List.fromList(
      List<double>.filled(192, 0.0),
    );
    emb[0] = 1;
    await index.upsertIdentity('Me', emb);
  } catch (e) {
    stderr.writeln('macos_index_check: upsert failed: $e');
    exit(2);
  }
  stderr.writeln('macos_index_check: identities=${index.identities.length} '
      'first=${index.identities.isEmpty ? null : index.identities.first.name}');
  await index.clear();
  exit(index.identities.isEmpty ? 0 : 3);
}