import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../ml/detection.dart';
import '../ml/detection_index.dart';
import '../ml/faces.dart';
import '../ml/illustration.dart';
import '../state/app_state.dart';
import 'face_detail_screen.dart';

/// A sheet listing the detected faces in one photo. Tapping a face names it,
/// which also backfills the name onto every other already-scanned photo that
/// matches the new identity.
class PeoplePanel extends StatefulWidget {
  const PeoplePanel({
    super.key,
    required this.state,
    required this.linkId,
  });

  final AppState state;
  final String linkId;

  @override
  State<PeoplePanel> createState() => _PeoplePanelState();
}

class _PeoplePanelState extends State<PeoplePanel> {
  List<DetectedFace>? _faces;
  img.Image? _decoded;
  bool _loading = true;
  final bool _naming = false;
  String? _error;

  DetectionIndex get _index => widget.state.detectionIndex;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final previewBytes = await widget.state.preview(widget.linkId, size: 1600);
      final decoded = img.decodeImage(previewBytes);

      var faces = _index.lookup(widget.linkId)?.faces ?? const <DetectedFace>[];
      if (faces.isEmpty && decoded != null) {
        // Illustrations have no real faces to tag; flag the photo so the
        // filter can separate it and skip detection entirely.
        final style = analyseIllustration(decoded);
        if (style.isIllustration) {
          final existing = _index.lookup(widget.linkId);
          if (existing != null) {
            await _index.put(existing.copyWith(
              illustration: true,
              styleChecked: true,
              faces: const [],
            ));
          }
        } else {
          final svc = FaceRecognitionService();
          try {
            faces = await svc.detectFaces(
              bytes: previewBytes,
              imageWidth: decoded.width,
              imageHeight: decoded.height,
            );
          } finally {
            await svc.dispose();
          }
          autoMatchFaces(faces, matcher: _index.faceMatcher());
          if (faces.isNotEmpty || _index.lookup(widget.linkId) != null) {
            final existing = _index.lookup(widget.linkId);
            await _index.put(
              existing?.copyWith(faces: faces, styleChecked: true, facesChecked: true) ??
                  DetectedEntry(
                    linkId: widget.linkId,
                    modelVersion: DetectorService.modelVersion,
                    detectedAt: DateTime.now(),
                    objects: const [],
                    faces: faces,
                    styleChecked: true,
                    facesChecked: true,
                  ),
            );
          }
        }
      }
      if (!mounted) return;
      setState(() {
        _faces = faces;
        _decoded = decoded;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }


  Future<void> _openFaceDetail(int index) async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FaceDetailScreen(
          state: widget.state,
          linkId: widget.linkId,
          faceIndex: index,
        ),
      ),
    );
    if (!mounted) return;
    setState(() => _faces = _index.facesFor(widget.linkId));
  }

  Future<void> _ignoreFace(int index) async {
    final count = await _index.ignoreFaceEverywhere(widget.linkId, index);
    if (!mounted) return;
    setState(() => _faces = _index.facesFor(widget.linkId));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          count <= 1
              ? 'Face ignored'
              : 'Face ignored in $count photos',
        ),
      ),
    );
  }

  Future<void> _clearName(int index) async {
    await _index.clearFaceName(widget.linkId, index);
    if (!mounted) return;
    setState(() => _faces = _index.facesFor(widget.linkId));
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('People', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(32),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Text('Could not scan faces: $_error'),
              )
            else if ((_faces ?? []).isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No faces detected in this photo.'),
              )
            else
              SizedBox(
                height: 280,
                child: GridView.builder(
                  gridDelegate:
                      const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 3,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                      ),
                  itemCount: _faces!.length,
                  itemBuilder: (context, i) => _FaceTile(
                    face: _faces![i],
                    image: _decoded,
                    busy: _naming,
                    onTap: () => _openFaceDetail(i),
                    onClear: _faces![i].name == null
                        ? null
                        : () => _clearName(i),
                    onIgnore: _faces![i].ignored ? null : () => _ignoreFace(i),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _FaceTile extends StatelessWidget {
  const _FaceTile({
    required this.face,
    required this.image,
    required this.busy,
    required this.onTap,
    this.onClear,
    this.onIgnore,
  });

  final DetectedFace face;
  final img.Image? image;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback? onClear;
  final VoidCallback? onIgnore;

  @override
  Widget build(BuildContext context) {
    final thumb = image == null
        ? null
        : cropFaceJpegFromDecoded(image!, face.rect, size: 120);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: busy ? null : onTap,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: thumb != null && thumb.isNotEmpty
                ? Image.memory(thumb, fit: BoxFit.cover)
                : Container(color: Theme.of(context).colorScheme.surfaceContainerHighest),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: const BorderRadius.vertical(
                  bottom: Radius.circular(8),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (face.rect.width * face.rect.height < kMinAutoFaceArea &&
                      face.name == null)
                    const Padding(
                      padding: EdgeInsets.only(right: 4),
                      child: Icon(
                        Icons.zoom_in,
                        size: 12,
                        color: Colors.white70,
                      ),
                    ),
                  Flexible(
                    child: Text(
                      face.ignored
                          ? 'Ignored'
                          : face.name ?? 'Name…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: face.ignored ? Colors.white60 : Colors.white,
                        fontSize: 12,
                      ),
                    ),
                  ),
                  if (onClear != null)
                    GestureDetector(
                      onTap: onClear,
                      child: const Padding(
                        padding: EdgeInsets.only(left: 4),
                        child: Icon(
                          Icons.person_remove,
                          size: 14,
                          color: Colors.white,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}