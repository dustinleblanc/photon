import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' show Rect;

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:photon_library/ml/detection.dart';
import 'package:photon_library/ml/detection_index.dart';
import 'package:photon_library/ml/faces.dart';

void main() {
  late Directory tmp;
  late DetectionIndex index;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('photon_tags_test');
    index = DetectionIndex();
    await index.init(
      dirOverride: tmp,
      keyOverride: List<int>.filled(32, 7),
    );
  });

  tearDown(() async {
    await index.clear();
    try {
      await tmp.delete(recursive: true);
    } on FileSystemException {
      // Hive's lock-file cleanup can race the recursive delete; the temp
      // dir is throwaway either way.
    }
  });

  Float32List emb(double seed) => Float32List.fromList(
        List<double>.generate(192, (i) => (i + seed) / 1000),
      );

  DetectedEntry entryWithFace(String linkId, Float32List embedding,
      {String? name}) {
    return DetectedEntry(
      linkId: linkId,
      modelVersion: DetectorService.modelVersion,
      detectedAt: DateTime(2026, 9, 11),
      objects: const [],
      faces: [
        DetectedFace(
          rect: const Rect.fromLTWH(0.1, 0.1, 0.2, 0.2),
          embedding: embedding,
          name: name,
        ),
      ],
    );
  }

  test('unseen remote identities are inserted as new people', () async {
    await index.applyRemoteIdentities([
      PersonIdentity(
        name: 'Logan',
        centroid: emb(1),
        faceSamples: 4,
      ),
    ]);

    final id = index.identityForName('logan');
    expect(id, isNotNull);
    expect(id!.faceSamples, 4);
  });

  test('matching identities merge centroids weighted by samples', () async {
    await index.upsertIdentity('Mom', emb(10));
    final merged = await index.applyRemoteIdentities([
      PersonIdentity(
        name: 'Mom',
        aliases: ['Mother'],
        centroid: emb(20),
        faceSamples: 3,
      ),
    ]);

    expect(merged.length, 1);
    final id = index.identityForName('Mom')!;
    expect(id.faceSamples, 4);
    expect(id.aliases, contains('Mother'));
    // 1 local sample + 3 remote samples: (0.010 + 3*0.020)/4 = 0.0175
    expect(id.centroid[0], closeTo(0.0175, 1e-6));
  });

  test('the side with more samples supplies the canonical name', () async {
    // Local "Mom" has 1 sample; remote "Karen" has 5 and lists Mom as alias.
    await index.upsertIdentity('Mom', emb(1));
    await index.applyRemoteIdentities([
      PersonIdentity(
        name: 'Karen',
        aliases: ['Mom'],
        centroid: emb(2),
        faceSamples: 5,
      ),
    ]);

    expect(index.identityForName('Karen'), isNotNull);
    expect(index.identityForName('Mom')!.name, 'Karen');
    // The face stored under the old canonical name was renamed.
    expect(index.identityForName('Karen')!.allNames, contains('Mom'));
  });

  test('remote identities backfill names onto unnamed stored faces',
      () async {
    final local = emb(1);
    await index.put(entryWithFace('photo1', local));
    // No local identities yet: the face is unnamed.
    expect(index.facesFor('photo1').single.name, isNull);

    await index.applyRemoteIdentities([
      PersonIdentity(name: 'Dad', centroid: local, faceSamples: 2),
    ]);

    expect(index.facesFor('photo1').single.name, 'Dad');
    expect(index.facesFor('photo1').single.similarity, closeTo(1.0, 1e-6));
  });

  test('ignored faces are never backfilled', () async {
    final local = emb(1);
    final e = entryWithFace('photo2', local);
    e.faces[0].ignored = true;
    await index.put(e);

    await index.applyRemoteIdentities([
      PersonIdentity(name: 'Dad', centroid: local, faceSamples: 2),
    ]);

    expect(index.facesFor('photo2').single.name, isNull);
    expect(index.facesFor('photo2').single.ignored, isTrue);
  });

  test('empty or malformed remote identities are skipped', () async {
    await index.upsertIdentity('Mom', emb(1));
    final merged = await index.applyRemoteIdentities([
      PersonIdentity(name: '', centroid: emb(2), faceSamples: 1),
      PersonIdentity(
        name: 'NoCentroid',
        centroid: Float32List(0),
        faceSamples: 0,
      ),
    ]);
    expect(merged.length, 1);
    expect(merged.single.name, 'Mom');
  });

  test('reconciliation clears auto-tags below threshold, keeps manual ones',
      () async {
    // Manual tag: embedding matches the identity exactly (similarity 1.0).
    // Loose auto-tag: orthogonal embedding stored with a 0.55 score from
    // the looser-threshold era — re-deriving clears it.
    final e0 = Float32List(192)..[0] = 1;
    final orthogonal = Float32List(192)..[1] = 1;
    await index.upsertIdentity('Mom', e0);

    final manual = entryWithFace('photo-manual', e0, name: 'Mom');
    manual.faces[0].similarity = 1.0;
    await index.put(manual);
    final loose = entryWithFace('photo-loose', orthogonal, name: 'Mom');
    loose.faces[0].similarity = 0.55;
    await index.put(loose);

    await index.reconcileAutoAssignedNames();

    expect(index.facesFor('photo-manual').single.name, 'Mom');
    expect(index.facesFor('photo-loose').single.name, isNull);
    // The embedding is kept so the face can be re-matched.
    expect(index.facesFor('photo-loose').single.embedding.length, 192);
  });

  test('reconciliation clears auto-tags that are now ambiguous', () async {
    // Two orthogonal identities; the face sits equidistant between them —
    // above threshold for both, but not decisively closer to either.
    final a = Float32List(192)..[0] = 1;
    final b = Float32List(192)..[1] = 1;
    await index.upsertIdentity('A', a);
    await index.upsertIdentity('B', b);
    final between = Float32List(192)
      ..[0] = 0.70710678
      ..[1] = 0.70710678;
    final e = entryWithFace('photo-ambiguous', between, name: 'A');
    e.faces[0].similarity = 0.65;
    await index.put(e);

    await index.reconcileAutoAssignedNames();

    expect(index.facesFor('photo-ambiguous').single.name, isNull);
  });

  test('reconciliation keeps auto-tags that still match decisively',
      () async {
    final a = Float32List(192)..[0] = 1;
    final b = Float32List(192)..[1] = 1;
    await index.upsertIdentity('A', a);
    await index.upsertIdentity('B', b);
    // Strongly closer to A than to B.
    final face = Float32List(192)
      ..[0] = 0.97
      ..[1] = 0.24;
    final e = entryWithFace('photo-clear', face, name: 'A');
    e.faces[0].similarity = 0.7;
    await index.put(e);

    await index.reconcileAutoAssignedNames();

    expect(index.facesFor('photo-clear').single.name, 'A');
  });

  test('a runner-up below its own threshold does not block a match',
      () async {
    // A is well confirmed (threshold 0.55), B has a single sample (0.60).
    // The face scores 0.62 vs A and 0.59 vs B: A is a valid match, B is not
    // a valid match on its own, so B is not a real rival despite the small
    // 0.03 gap.
    final a = Float32List(192)..[0] = 1;
    final b = Float32List(192)..[1] = 1;
    for (var i = 0; i < 6; i++) {
      await index.upsertIdentity('A', a);
    }
    await index.upsertIdentity('B', b);
    final face = Float32List(192)
      ..[0] = 0.75
      ..[1] = 0.59
      ..[2] = 0.2990; // unit: 0.75² + 0.59² + 0.299² ≈ 1
    await index.put(entryWithFace('photo-close', face));

    await index.rematchUnnamed();

    expect(index.facesFor('photo-close').single.name, 'A');
  });

  test('rematchUnnamed never auto-names tiny crowd faces', () async {
    final e0 = Float32List(192)..[0] = 1;
    await index.upsertIdentity('A', e0);
    final tiny = entryWithFace('photo-tiny', e0);
    tiny.faces[0] = DetectedFace(
      rect: const Rect.fromLTWH(0.9, 0.08, 0.05, 0.065),
      embedding: tiny.faces[0].embedding,
    );
    await index.put(tiny);

    await index.rematchUnnamed();

    expect(index.facesFor('photo-tiny').single.name, isNull);
  });

  test('reconciliation clears auto-names from now-tiny faces', () async {
    final e0 = Float32List(192)..[0] = 1;
    await index.upsertIdentity('A', e0);
    final tiny = entryWithFace('photo-tiny', e0, name: 'A');
    tiny.faces[0] = DetectedFace(
      rect: const Rect.fromLTWH(0.9, 0.08, 0.05, 0.065),
      embedding: tiny.faces[0].embedding,
      name: 'A',
      similarity: 0.65,
    );
    await index.put(tiny);

    await index.reconcileAutoAssignedNames();

    expect(index.facesFor('photo-tiny').single.name, isNull);
  });

  test('a strong broad match wins over a close lookalike', () async {
    // A is a very strong match (peak 0.85, centroid 0.85) but a lookalike
    // B is only 0.03 behind — inside the ambiguity margin. At this
    // confidence the best match is accepted (relatives score high against
    // each other, which used to veto correct photos).
    final a = Float32List(192)..[0] = 1;
    final q = Float32List(192)
      ..[0] = 0.85
      ..[1] = 0.5268; // unit: 0.85² + 0.5268² ≈ 1
    final b = Float32List(192)
      ..[0] = 0.82 * 0.85
      ..[1] = 0.82 * 0.5268
      ..[2] = 0.5723; // unit, cos(q, b) = 0.82
    await index.upsertIdentity('A', a);
    await index.upsertIdentity('B', b);
    expect(faceMatchScore(q, b), closeTo(0.82, 1e-3));

    await index.put(entryWithFace('q-photo', q));
    await index.rematchUnnamed();

    expect(index.facesFor('q-photo').single.name, 'A');
  });

  test('repair keeps a coherent pair and drops the outlier', () async {
    // Two genuine confirmations of one person plus one wrong face.
    final a = Float32List(192)..[0] = 1;
    final nearA = Float32List(192)
      ..[0] = 0.98
      ..[1] = 0.199; // very similar to a
    final wrong = Float32List(192)..[5] = 1; // unrelated
    await index.upsertIdentity('Aimee', a);
    await index.upsertIdentity('Aimee', nearA);
    await index.upsertIdentity('Aimee', wrong);
    for (final e in [
      entryWithFace('aimee-1', a, name: 'Aimee'),
      entryWithFace('aimee-2', nearA, name: 'Aimee'),
      entryWithFace('aimee-3', wrong, name: 'Aimee'),
    ]) {
      e.faces[0].similarity = 1.0;
      await index.put(e);
    }

    final result = await index.repairIdentities();

    expect(result.identitiesRepaired, 1);
    expect(result.facesCleared, 1);
    // The genuine pair survives; the unrelated face is untagged.
    expect(index.facesFor('aimee-1').single.name, 'Aimee');
    expect(index.facesFor('aimee-2').single.name, 'Aimee');
    expect(index.facesFor('aimee-3').single.name, isNull);
    expect(index.identityForName('Aimee')!.faceSamples, 2);
  });

  test('ignoring a face untags and ignores it in every photo', () async {
    final aliFace = Float32List(192)..[0] = 1;
    final sadieFace = Float32List(192)..[1] = 1;
    await index.upsertIdentity('Ali', aliFace);
    await index.upsertIdentity('Sadie', sadieFace);
    // Several photos of the same unknown face, wrongly auto-tagged Ali.
    for (var i = 0; i < 3; i++) {
      final e = entryWithFace('stranger-$i', sadieFace, name: 'Ali');
      e.faces[0].similarity = 0.65;
      await index.put(e);
    }
    // An unrelated Ali face that must be left alone.
    final keep = entryWithFace('ali-photo', aliFace, name: 'Ali');
    keep.faces[0].similarity = 0.8;
    await index.put(keep);

    final count = await index.ignoreFaceEverywhere('stranger-0', 0);

    expect(count, 3);
    for (var i = 0; i < 3; i++) {
      final f = index.facesFor('stranger-$i').single;
      expect(f.ignored, isTrue);
      expect(f.name, isNull);
    }
    // A different face stays tagged.
    final other = index.facesFor('ali-photo').single;
    expect(other.ignored, isFalse);
    expect(other.name, 'Ali');
    // Ignored faces are not unnamed work.
    expect(
      index.unnamedFaces().map((f) => f.linkId),
      isNot(contains('stranger-0')),
    );
  });

  test('correcting a name retags near-identical auto-tagged photos', () async {
    final aliFace = Float32List(192)..[0] = 1;
    final sadieFace = Float32List(192)..[1] = 1;
    await index.upsertIdentity('Ali', aliFace);
    await index.upsertIdentity('Sadie', sadieFace);
    // A batch of near-identical Sadie photos wrongly auto-tagged as Ali.
    final wrong1 = entryWithFace('sadie-1', sadieFace, name: 'Ali');
    wrong1.faces[0].similarity = 0.62;
    await index.put(wrong1);
    final wrong2 = entryWithFace('sadie-2', sadieFace, name: 'Ali');
    wrong2.faces[0].similarity = 0.60;
    await index.put(wrong2);
    // The photo the user corrects by hand.
    await index.put(entryWithFace('sadie-3', sadieFace));

    await index.nameFace(linkId: 'sadie-3', faceIndex: 0, name: 'Sadie');

    expect(index.facesFor('sadie-1').single.name, 'Sadie');
    expect(index.facesFor('sadie-2').single.name, 'Sadie');
    expect(index.facesFor('sadie-3').single.name, 'Sadie');
  });

  test('correction never overrides a manually confirmed tag', () async {
    final aliFace = Float32List(192)..[0] = 1;
    final sadieFace = Float32List(192)..[1] = 1;
    await index.upsertIdentity('Ali', aliFace);
    await index.upsertIdentity('Sadie', sadieFace);
    final manual = entryWithFace('manual-ali', sadieFace, name: 'Ali');
    manual.faces[0].similarity = 1.0;
    await index.put(manual);
    await index.put(entryWithFace('sadie-3', sadieFace));

    await index.nameFace(linkId: 'sadie-3', faceIndex: 0, name: 'Sadie');

    expect(index.facesFor('manual-ali').single.name, 'Ali');
  });

  test('correcting one person leaves unrelated auto-tags alone', () async {
    final a = Float32List(192)..[0] = 1;
    final b = Float32List(192)..[1] = 1;
    final c = Float32List(192)..[2] = 1;
    await index.upsertIdentity('A', a);
    await index.upsertIdentity('B', b);
    await index.upsertIdentity('C', c);
    // An auto-tag that genuinely belongs to C.
    final cee = entryWithFace('c-photo', c, name: 'A');
    cee.faces[0].similarity = 0.7;
    await index.put(cee);
    await index.put(entryWithFace('b-photo', b));

    await index.nameFace(linkId: 'b-photo', faceIndex: 0, name: 'B');

    expect(index.facesFor('c-photo').single.name, 'A');
  });

  test('a person can only be named once per photo', () async {
    final e0 = Float32List(192)..[0] = 1;
    await index.upsertIdentity('A', e0);
    final e = entryWithFace('group-photo', e0, name: null);
    e.faces.add(
      DetectedFace(
        rect: const Rect.fromLTWH(0.5, 0.5, 0.2, 0.2),
        embedding: Float32List(192)..[1] = 1,
      ),
    );
    await index.put(e);

    final first = await index.nameFace(
      linkId: 'group-photo',
      faceIndex: 0,
      name: 'A',
    );
    expect(first, greaterThanOrEqualTo(0));
    final second = await index.nameFace(
      linkId: 'group-photo',
      faceIndex: 1,
      name: 'A',
    );
    expect(second, -2);
    expect(index.facesFor('group-photo')[1].name, isNull);
  });

  test('tiny faces are excluded from the unnamed worklist', () async {
    final big = entryWithFace('photo-big', emb(1));
    big.faces[0] = DetectedFace(
      rect: const Rect.fromLTWH(0.2, 0.2, 0.3, 0.3),
      embedding: big.faces[0].embedding,
    );
    await index.put(big);
    final tiny = entryWithFace('photo-tiny', emb(2));
    tiny.faces[0] = DetectedFace(
      rect: const Rect.fromLTWH(0.9, 0.08, 0.05, 0.065),
      embedding: tiny.faces[0].embedding,
    );
    await index.put(tiny);

    final links = index.unnamedFaces().map((f) => f.linkId).toList();

    expect(links, contains('photo-big'));
    expect(links, isNot(contains('photo-tiny')));
    // The tiny face still counts as unnamed work if named later... it
    // doesn't, by design: it's manual-only via the photo's panel.
    expect(index.hasUnnamedFace('photo-tiny'), isFalse);
  });

  test('autoMatchFaces assigns each person at most once per photo', () async {
    // Two faces both matching A; the stronger one wins the slot.
    final e0 = Float32List(192)..[0] = 1;
    await index.upsertIdentity('A', e0);
    final weak = Float32List(192)
      ..[0] = 0.98
      ..[1] = 0.199;
    final faces = [
      DetectedFace(
        rect: const Rect.fromLTWH(0.0, 0.0, 0.3, 0.3),
        embedding: weak,
      ),
      DetectedFace(
        rect: const Rect.fromLTWH(0.4, 0.0, 0.3, 0.3),
        embedding: e0,
      ),
    ];
    autoMatchFaces(faces, matcher: index.faceMatcher());

    final names = faces.map((f) => f.name).toList();
    expect(names.where((n) => n == 'A').length, 1);
    // The exact match (cosine 1.0) is the one that got the slot.
    expect(faces[1].name, 'A');
    expect(faces[0].name, isNull);
  });

  test('autoMatchFaces never auto-assigns tiny faces', () async {
    final e0 = Float32List(192)..[0] = 1;
    await index.upsertIdentity('A', e0);
    final tiny = DetectedFace(
      rect: const Rect.fromLTWH(0.9, 0.08, 0.05, 0.065),
      embedding: e0,
    );
    autoMatchFaces([tiny], matcher: index.faceMatcher());
    expect(tiny.name, isNull);
  });

  test('hiding a person excludes their photos and survives rewrites',
      () async {
    final e0 = Float32List(192)..[0] = 1;
    await index.upsertIdentity('Ex', e0);
    final entry = entryWithFace('photo-ex', e0, name: 'Ex');
    entry.faces[0].similarity = 1.0;
    await index.put(entry);

    expect(index.hasHiddenPerson('photo-ex'), isFalse);

    await index.setPersonHidden('Ex', true);

    expect(index.hiddenNames, contains('Ex'));
    expect(index.hasHiddenPerson('photo-ex'), isTrue);

    // Other rewrite paths must not silently drop the flag.
    await index.upsertIdentity('Ex', e0);
    expect(index.identityForName('Ex')!.hidden, isTrue);

    await index.setPersonHidden('Ex', false);
    expect(index.hasHiddenPerson('photo-ex'), isFalse);
  });

  test('clearPersonFaces untags their photos and resets the centroid',
      () async {
    final e0 = Float32List(192)..[0] = 1;
    await index.upsertIdentity('Ex', e0);
    final tagged = entryWithFace('photo-a', e0, name: 'Ex');
    tagged.faces[0].similarity = 1.0;
    await index.put(tagged);
    final other = entryWithFace('photo-b', emb(2), name: 'Someone');
    other.faces[0].similarity = 1.0;
    await index.put(other);

    final count = await index.clearPersonFaces('Ex');

    expect(count, 1);
    expect(index.facesFor('photo-a').single.name, isNull);
    // Other people are untouched.
    expect(index.facesFor('photo-b').single.name, 'Someone');
    // The identity survives but its matching profile is reset.
    final id = index.identityForName('Ex');
    expect(id, isNotNull);
    expect(id!.faceSamples, 0);
    expect(index.faceMatcher().confirmedSamples.containsKey('Ex'), isFalse);
  });

  test('clearAllFaces removes every tag and identity but keeps detections',
      () async {
    final e0 = Float32List(192)..[0] = 1;
    await index.upsertIdentity('Ex', e0);
    final a = entryWithFace('photo-a', e0, name: 'Ex');
    a.faces[0].similarity = 1.0;
    await index.put(a);
    final b = entryWithFace('photo-b', emb(3));
    await index.put(b);

    await index.clearAllFaces();

    expect(index.identities, isEmpty);
    // Faces are kept but unnamed, so the unnamed queue stays populated.
    expect(index.facesFor('photo-a').single.name, isNull);
    expect(index.facesFor('photo-a').single.embedding, isNotEmpty);
    // A face that was never named is untouched.
    expect(index.facesFor('photo-b').single.name, isNull);
    expect(index.lookup('photo-a'), isNotNull);
  });

  test('setPersonCover is used and survives an unrelated rewrite', () async {
    final e0 = Float32List(192)..[0] = 1;
    await index.upsertIdentity('Mom', e0);
    final a = entryWithFace('cover-photo', e0, name: 'Mom');
    a.faces[0].similarity = 1.0;
    await index.put(a);

    await index.setPersonCover('Mom', 'cover-photo');
    expect(index.identityForName('Mom')!.coverLinkId, 'cover-photo');
    expect(index.faceRectIn('cover-photo', 'Mom'), isNotNull);

    // An unrelated identity rewrite (aliases) must not drop the cover.
    await index.updateIdentity(
      oldName: 'Mom',
      newName: 'Mom',
      aliases: ['Mother'],
    );
    expect(index.identityForName('Mom')!.coverLinkId, 'cover-photo');

    await index.setPersonCover('Mom', null);
    expect(index.identityForName('Mom')!.coverLinkId, isNull);
  });

  test('bestFaces prefers confirmed faces over large low-confidence ones',
      () async {
    // Logan's real (manual, small) face vs a big mis-tagged auto face.
    final real = entryWithFace(
      'photo-real',
      emb(1),
      name: 'Logan',
    );
    real.faces[0].similarity = 1.0;
    real.faces[0] = DetectedFace(
      rect: const Rect.fromLTWH(0.44, 0.38, 0.08, 0.06),
      embedding: real.faces[0].embedding,
      name: 'Logan',
      similarity: 1.0,
    );
    await index.put(real);
    final wrong = entryWithFace('photo-wrong', emb(2), name: 'Logan');
    wrong.faces[0] = DetectedFace(
      rect: const Rect.fromLTWH(0.1, 0.02, 0.49, 0.41),
      embedding: wrong.faces[0].embedding,
      name: 'Logan',
      similarity: 0.678,
    );
    await index.put(wrong);

    final best = index.bestFaces()['Logan'];

    expect(best, isNotNull);
    expect(best!.linkId, 'photo-real');
  });

  test('a match needs the centroid to be broadly close, not one outlier sample',
      () async {
    // A has two orthogonal confirmed samples, so its centroid is their mean.
    // q matches one sample at 0.75 but sits far from the centroid — the
    // "broad" gate refuses it, which is what stops a single odd sample from
    // naming faces on its own.
    final e0 = Float32List(192)..[0] = 1;
    final s = Float32List(192)..[1] = 1;
    await index.upsertIdentity('A', e0);
    await index.upsertIdentity('A', s);
    await index.put(
      entryWithFace('e0-photo', e0, name: 'A')..faces[0].similarity = 1.0,
    );
    await index.put(
      entryWithFace('s-photo', s, name: 'A')..faces[0].similarity = 1.0,
    );

    // q = 0.75*s + 0.661*t (orthogonal to both e0 and s).
    final q = Float32List(192)
      ..[1] = 0.75
      ..[2] = 0.6614;
    expect(cosineSimilarity(q, s), closeTo(0.75, 1e-3));

    await index.put(entryWithFace('q-photo', q));
    await index.rematchUnnamed();

    expect(index.facesFor('q-photo').single.name, isNull);
  });

  test('auto-assigned faces never become matcher samples', () async {
    // w is an auto-tagged face at 60 degrees from the centroid e0; q sits
    // 0.65 from w but -0.33 from e0. If w counted as a sample, q would
    // match; confirmed-only samples keep it unnamed.
    final e0 = Float32List(192)..[0] = 1;
    final w = Float32List(192)
      ..[0] = 0.5
      ..[1] = 0.8660254;
    final q = Float32List(192)
      ..[0] = -0.334
      ..[1] = 0.9427;
    expect(cosineSimilarity(q, w), closeTo(0.65, 1e-3));
    expect(cosineSimilarity(q, e0), closeTo(-0.334, 1e-3));

    await index.upsertIdentity('A', e0);
    final auto = entryWithFace('auto-photo', w, name: 'A');
    auto.faces[0].similarity = 0.65;
    await index.put(auto);
    await index.put(entryWithFace('q-photo', q));

    await index.rematchUnnamed();

    expect(index.facesFor('q-photo').single.name, isNull);
  });

  test('confirming more faces does not loosen the threshold', () async {
    // A is very well confirmed, but 0.575 is below the strict bar: the
    // threshold no longer eases with sample count (that shortcut let
    // lookalikes through).
    final e0 = Float32List(192)..[0] = 1;
    final q = Float32List(192)
      ..[0] = 0.575
      ..[1] = 0.8181;
    for (var i = 0; i < 4; i++) {
      await index.upsertIdentity('A', e0);
    }
    await index.put(
      entryWithFace('e0-photo', e0, name: 'A')..faces[0].similarity = 1.0,
    );
    await index.put(entryWithFace('q-photo', q));

    await index.rematchUnnamed();

    expect(index.facesFor('q-photo').single.name, isNull);
  });
}