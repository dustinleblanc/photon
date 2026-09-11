import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../ml/detection.dart';
import '../ml/detection_index.dart';
import '../ml/faces.dart';
import '../state/app_state.dart';

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
  bool _naming = false;
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
        autoMatchFaces(faces, identities: _index.identities);
        if (faces.isNotEmpty) {
          final existing = _index.lookup(widget.linkId);
          await _index.put(
            DetectedEntry(
              linkId: widget.linkId,
              modelVersion: DetectorService.modelVersion,
              detectedAt: existing?.detectedAt ?? DateTime.now(),
              objects: existing?.objects ?? const [],
              faces: faces,
            ),
          );
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

  Future<void> _nameFace(int index) async {
    final faces = _faces;
    if (faces == null) return;
    final face = faces[index];
    final controller = TextEditingController(text: face.name ?? '');
    final known = _index.identities;
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Who is this?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (known.isNotEmpty) ...[
                Text(
                  face.name == null
                      ? 'Choose a person:'
                      : 'Currently “${face.name}”. Choose a person:',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final id in known)
                      ActionChip(
                        avatar: CircleAvatar(
                          child: Text(
                            id.name.isEmpty ? '?' : id.name[0].toUpperCase(),
                          ),
                        ),
                        label: Text(
                          id.aliases.isEmpty
                              ? id.name
                              : '${id.name} (${id.aliases.join(', ')})',
                        ),
                        onPressed: () => Navigator.pop(dialogContext, id.name),
                      ),
                  ],
                ),
                const Divider(height: 24),
                Text(
                  '…or type a new name:',
                  style: Theme.of(dialogContext).textTheme.bodySmall,
                ),
                const SizedBox(height: 8),
              ],
              TextField(
                controller: controller,
                autofocus: known.isEmpty,
                textCapitalization: TextCapitalization.words,
                decoration: const InputDecoration(
                  labelText: 'Name',
                  hintText: 'e.g. Mom',
                ),
                onSubmitted: (v) {
                  final trimmed = v.trim();
                  if (trimmed.isNotEmpty) Navigator.pop(dialogContext, trimmed);
                },
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final trimmed = controller.text.trim();
              if (trimmed.isNotEmpty) Navigator.pop(dialogContext, trimmed);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (name == null || name.isEmpty || !mounted) return;
    setState(() => _naming = true);
    final matched = await _index.nameFace(
      linkId: widget.linkId,
      faceIndex: index,
      name: name,
    );
    if (!mounted) return;
    setState(() {
      _naming = false;
      _faces = _index.facesFor(widget.linkId);
    });
    final resolved = _index.identityForName(name)?.name ?? name;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          matched <= 0
              ? 'Named $resolved'
              : 'Named $resolved · matched in $matched other ${matched == 1 ? 'photo' : 'photos'}',
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
                    onTap: () => _nameFace(i),
                    onClear: _faces![i].name == null
                        ? null
                        : () => _clearName(i),
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
  });

  final DetectedFace face;
  final img.Image? image;
  final bool busy;
  final VoidCallback onTap;
  final VoidCallback? onClear;

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
                  Flexible(
                    child: Text(
                      face.name ?? 'Name…',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontSize: 12),
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