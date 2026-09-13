import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:hive_ce/hive.dart';

import 'package:photon_library/ml/detection.dart';
import 'package:photon_library/ml/detection_index.dart';
import 'package:photon_library/ml/faces.dart';

/// Host-side probe for the encrypted detection index. Run:
///   flutter run -d linux -t tool/index_probe.dart
/// Env: `NAME=<identity>` to score every other face against its centroid.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Use DetectionIndex so its open-time reconcile runs (and can be shown to
  // heal a corrupt centroid), then read the raw boxes.
  final index = DetectionIndex();
  await index.init();
  stderr.writeln(
      'probe: available=${index.available} error=${index.error}');
  final idBox = Hive.box<Map>('identities_v1');
  final detBox = Hive.box<Map>('detections_v1');
  stderr.writeln('probe: identities=${idBox.length} detections=${detBox.length}');

  stderr.writeln('probe: raw identity maps:');
  for (final k in idBox.keys) {
    final raw = idBox.get(k);
    if (raw is! Map) {
      stderr.writeln('  $k -> ${raw.runtimeType} $raw');
      continue;
    }
    final name = raw['name'];
    final samples = raw['samples'];
    stderr.writeln(
        '  $name | samples=$samples (${samples.runtimeType}) keys=${raw.keys.toList()}');
  }

  final ids = <PersonIdentity>[];
  for (final k in idBox.keys) {
    try {
      ids.add(
          PersonIdentity.fromMap((idBox.get(k) as Map).cast<String, dynamic>()));
    } catch (e) {
      stderr.writeln('probe: identity $k failed to decode: $e');
    }
  }

  final target = Platform.environment['NAME'] ?? 'Dustin LeBlanc';
  final matches = ids.where((i) => i.name == target).toList();
  if (matches.isEmpty) {
    stderr.writeln('probe: target "$target" not found');
    exit(2);
  }
  final id = matches.first;

  final entries = <DetectedEntry>[];
  for (final k in detBox.keys) {
    try {
      entries.add(DetectedEntry.fromMap(
          k as String, (detBox.get(k) as Map).cast<String, dynamic>()));
    } catch (_) {}
  }

  var faces = 0, unnamed = 0, namedTarget = 0;
  final scored = <({double sim, String linkId, int idx, String? name})>[];
  for (final e in entries) {
    for (var i = 0; i < e.faces.length; i++) {
      final f = e.faces[i];
      faces++;
      if (f.name == null) unnamed++;
      if (f.name == target) {
        namedTarget++;
        continue;
      }
      scored.add((
        sim: faceMatchScore(f.embedding, id.centroid),
        linkId: e.linkId,
        idx: i,
        name: f.name,
      ));
    }
  }
  scored.sort((a, b) => b.sim.compareTo(a.sim));

  final hist = <String, int>{};
  for (final s in scored) {
    final b = s.sim >= 0.7
        ? '>=0.70'
        : s.sim >= 0.65
            ? '0.65-0.70'
            : s.sim >= 0.60
                ? '0.60-0.65'
                : s.sim >= 0.55
                    ? '0.55-0.60'
                    : s.sim >= 0.50
                        ? '0.50-0.55'
                        : '<0.50';
    hist[b] = (hist[b] ?? 0) + 1;
  }

  stderr.writeln('probe: target=$target samples=${id.faceSamples} '
      'centroidLen=${id.centroid.length}');
  stderr.writeln('probe: faces=$faces unnamed=$unnamed namedTarget=$namedTarget');
  stderr.writeln('probe: sim histogram vs $target (other faces): $hist');
  stderr.writeln('probe: top 15 nearest:');
  for (final s in scored.take(15)) {
    stderr.writeln('  sim=${s.sim.toStringAsFixed(3)} name=${s.name} '
        'link=${s.linkId} face=${s.idx}');
  }

  // Compare the stored centroid with one rebuilt from manually-named faces.
  final manual = <Float32List>[];
  for (final e in entries) {
    for (final f in e.faces) {
      if (f.name == target && (f.similarity ?? 0) >= 0.999) {
        manual.add(f.embedding);
      }
    }
  }
  final storedNorm = _norm(id.centroid);
  final nonFinite = id.centroid.where((v) => !v.isFinite).length;
  stderr.writeln('probe: stored centroid norm=${storedNorm.toStringAsFixed(3)} '
      'nonFinite=$nonFinite head=${id.centroid.take(4).toList()}');

  if (manual.isNotEmpty) {
    final rebuilt = Float32List(id.centroid.length);
    for (final m in manual) {
      for (var i = 0; i < rebuilt.length; i++) {
        rebuilt[i] += m[i];
      }
    }
    for (var i = 0; i < rebuilt.length; i++) {
      rebuilt[i] /= manual.length;
    }
    final cos = _cosine(rebuilt, id.centroid);
    stderr.writeln('probe: manualFaces=${manual.length} '
        'rebuiltNorm=${_norm(rebuilt).toStringAsFixed(3)} '
        'cos(stored,rebuilt)=${cos.toStringAsFixed(4)}');

    final rebuiltHist = <String, int>{};
    for (final s in scored) {
      // Recompute against the rebuilt centroid rather than the stored one.
      final f = entries
          .firstWhere((e) => e.linkId == s.linkId)
          .faces[s.idx];
      final sim = faceMatchScore(f.embedding, rebuilt);
      final b = sim >= 0.7
          ? '>=0.70'
          : sim >= 0.65
              ? '0.65-0.70'
              : sim >= 0.60
                  ? '0.60-0.65'
                  : sim >= 0.55
                      ? '0.55-0.60'
                      : sim >= 0.50
                          ? '0.50-0.55'
                          : '<0.50';
      rebuiltHist[b] = (rebuiltHist[b] ?? 0) + 1;
    }
    stderr.writeln('probe: sim histogram vs REBUILT $target: $rebuiltHist');
  }

  await idBox.close();
  await detBox.close();
  exit(0);
}

double _norm(Float32List v) {
  var s = 0.0;
  for (final x in v) {
    s += x * x;
  }
  return s.isFinite ? math.sqrt(s) : double.nan;
}

double _cosine(Float32List a, Float32List b) {
  var dot = 0.0, na = 0.0, nb = 0.0;
  for (var i = 0; i < a.length && i < b.length; i++) {
    dot += a[i] * b[i];
    na += a[i] * a[i];
    nb += b[i] * b[i];
  }
  final d = (na <= 0 ? 0.0 : na) * (nb <= 0 ? 0.0 : nb);
  if (d <= 0) return 0;
  return dot / d;
}

