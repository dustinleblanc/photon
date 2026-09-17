import 'dart:io';

import 'package:flutter/material.dart';

import 'package:photon_library/ml/detection_index.dart';

/// Times the expensive paths to find the slowdown.
///   flutter run -d macos -t tool/perf_probe.dart
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final index = DetectionIndex();
  final sw = Stopwatch()..start();
  await index.init();
  sw.stop();
  final entries = index.debugEntries();
  stderr.writeln('perf: init=${sw.elapsedMilliseconds}ms '
      'entries=${entries.length} identities=${index.identities.length}');

  // faceMatcher build + sample volume
  final m1 = Stopwatch()..start();
  final matcher = index.faceMatcher();
  m1.stop();
  var samples = 0;
  for (final list in matcher.confirmedSamples.values) {
    samples += list.length;
  }
  stderr.writeln('perf: faceMatcher()=${m1.elapsedMilliseconds}ms '
      'confirmedSamples=$samples');

  // replay reconciliation cost
  final m2 = Stopwatch()..start();
  await index.reconcileAutoAssignedNames();
  m2.stop();
  final m3 = Stopwatch()..start();
  await index.rematchUnnamed();
  m3.stop();
  stderr.writeln('perf: reconcileAutoAssigned=${m2.elapsedMilliseconds}ms '
      'rematchUnnamed=${m3.elapsedMilliseconds}ms');

  final c1 = Stopwatch()..start();
  index.countPeople();
  c1.stop();
  final c2 = Stopwatch()..start();
  index.countPeople();
  c2.stop();
  stderr.writeln('perf: countPeople cold=${c1.elapsedMilliseconds}ms '
      'warm=${c2.elapsedMilliseconds}ms');

  final hp = Stopwatch()..start();
  var named = 0;
  for (final e in entries.values) {
    if (index.hasPerson(e.linkId, 'Ali Costonis')) named++;
  }
  hp.stop();
  stderr.writeln('perf: hasPerson over all entries=${hp.elapsedMilliseconds}ms '
      'named=$named');

  // gallery-style matching over every entry (one build's worth)
  final m4 = Stopwatch()..start();
  var hit = 0;
  for (final e in entries.values) {
    if (index.peopleFor(e.linkId).isNotEmpty) hit++;
  }
  m4.stop();
  stderr.writeln('perf: all-entries peopleFor=${m4.elapsedMilliseconds}ms '
      'hits=$hit');
  exit(0);
}
