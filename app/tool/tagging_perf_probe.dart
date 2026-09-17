import 'dart:io';

import 'package:flutter/material.dart';

import 'package:photon_library/ml/detection_index.dart';

/// Times the interactive tagging operations so we can tell what blocks the UI.
///   flutter run -d macos -t tool/tagging_perf_probe.dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final index = DetectionIndex();
  await index.init();

  final unnamed = index.unnamedFaces();
  final named = <({String linkId, int faceIndex, String name})>[];
  for (final e in index.debugEntries().values) {
    for (var i = 0; i < e.faces.length; i++) {
      final f = e.faces[i];
      if (f.name != null && (f.similarity ?? 0) < 1.0) {
        named.add((linkId: e.linkId, faceIndex: i, name: f.name!));
      }
    }
  }
  stderr.writeln('probe: unnamed=${unnamed.length} autoNamed=${named.length} '
      'identities=${index.identities.length}');

  final sw = Stopwatch()..start();
  final matcher = index.faceMatcher();
  sw.stop();
  stderr.writeln('probe: faceMatcher build=${sw.elapsedMilliseconds}ms '
      'samples=${matcher.confirmedSamples.values.fold<int>(0, (a, l) => a + l.length)}');

  // One `match` over every auto-named face (what a correction sweep costs).
  sw.reset();
  var hits = 0;
  for (final n in named) {
    final entry = index.lookup(n.linkId);
    if (entry == null) continue;
    final emb = entry.faces[n.faceIndex].embedding;
    if (matcher.match(emb) != null) hits++;
  }
  sw.stop();
  stderr.writeln('probe: sweep over $named faces=${sw.elapsedMilliseconds}ms '
      'matched=$hits');

  // A full nameFace call (adds a sample + sweeps + writes).
  if (unnamed.isNotEmpty) {
    final target = unnamed.last;
    sw.reset();
    final matched = await index.nameFace(
      linkId: target.linkId,
      faceIndex: target.faceIndex,
      name: 'PERF TEST',
    );
    sw.stop();
    stderr.writeln('probe: nameFace(single)=${sw.elapsedMilliseconds}ms '
        'matched=$matched');
    // Undo so the probe is repeatable.
    await index.clearPersonFaces('PERF TEST');
    await index.removeIdentity('PERF TEST');
  }
  await index.dispose();
  exit(0);
}
