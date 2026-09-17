import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../ml/detection_index.dart';
import '../ml/faces.dart';
import '../state/app_state.dart';

/// Full-screen view of one face, zoomed to its crop with surrounding
/// context, for confirming or naming faces that are too small to judge from
/// a grid tile — background-crowd faces that are actually someone you care
/// about. Naming here tags the face and backfills across the library; the
/// one-identity-per-photo rule applies.
class FaceDetailScreen extends StatefulWidget {
  const FaceDetailScreen({
    super.key,
    required this.state,
    required this.linkId,
    required this.faceIndex,
  });

  final AppState state;
  final String linkId;
  final int faceIndex;

  @override
  State<FaceDetailScreen> createState() => _FaceDetailScreenState();
}

class _FaceDetailScreenState extends State<FaceDetailScreen> {
  Uint8List? _crop;
  Uint8List? _context;
  bool _busy = false;
  final TextEditingController _name = TextEditingController();
  final FocusNode _focus = FocusNode();

  DetectionIndex get _index => widget.state.detectionIndex;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final bytes = await widget.state.preview(widget.linkId, size: 1600);
    final decoded = img.decodeImage(bytes);
    if (!mounted) return;
    final face = _index.lookup(widget.linkId)?.faces;
    if (face == null || widget.faceIndex >= face.length) return;
    setState(() {
      _crop = cropFaceJpegFromDecoded(decoded!, face[widget.faceIndex].rect, size: 320);
      _context = bytes;
    });
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() => _busy = true);
    final matched = await _index.nameFace(
      linkId: widget.linkId,
      faceIndex: widget.faceIndex,
      name: name,
    );
    if (!mounted) return;
    setState(() => _busy = false);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          switch (matched) {
            -2 => 'That person is already tagged in this photo.',
            -1 => 'Could not name this face.',
            _ => matched <= 0
                ? 'Named $name'
                : 'Named $name · matched in $matched other '
                    '${matched == 1 ? 'photo' : 'photos'}',
          },
        ),
      ),
    );
  }

  Future<void> _ignore() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final count =
          await _index.ignoreFaceEverywhere(widget.linkId, widget.faceIndex);
      if (!mounted) return;
      Navigator.pop(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            count <= 1
                ? 'Face ignored'
                : 'Face ignored in $count photos',
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _clear() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _index.clearFaceName(widget.linkId, widget.faceIndex);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final entry = _index.lookup(widget.linkId);
    if (entry == null || widget.faceIndex >= entry.faces.length) {
      return const Scaffold(body: Center(child: Text('Face unavailable.')));
    }
    final face = entry.faces[widget.faceIndex];
    return Scaffold(
      appBar: AppBar(title: const Text('Who is this?')),
      body: ListView(
        children: [
          if (_context != null)
            InteractiveViewer(
              maxScale: 6,
              child: Image.memory(_context!, fit: BoxFit.contain),
            ),
          if (_crop != null)
            Padding(
              padding: const EdgeInsets.all(16),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: Image.memory(
                  _crop!,
                  height: 220,
                  fit: BoxFit.cover,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: RawAutocomplete<String>(
              textEditingController: _name,
              focusNode: _focus,
              optionsBuilder: (value) {
                final q = value.text.trim().toLowerCase();
                final people = _index.identities;
                if (q.isEmpty) return const <String>[];
                return [
                  for (final id in people)
                    if (id.allNames
                        .any((n) => n.toLowerCase().contains(q)))
                      id.name,
                ];
              },
              fieldViewBuilder:
                  (context, controller, focusNode, onSelected) {
                return TextField(
                  controller: controller,
                  focusNode: focusNode,
                  autofocus: true,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(
                    labelText: 'Name',
                    hintText: 'e.g. Casey',
                  ),
                  onSubmitted: (_) => _submit(),
                );
              },
              onSelected: (name) {
                _name.text = name;
                _submit();
              },
              optionsViewBuilder: (context, onSelected, options) => Align(
                alignment: Alignment.topLeft,
                child: Material(
                  elevation: 4,
                  borderRadius: BorderRadius.circular(8),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 180),
                    child: ListView(
                      shrinkWrap: true,
                      padding: EdgeInsets.zero,
                      children: [
                        for (final name in options)
                          ListTile(
                            dense: true,
                            visualDensity: VisualDensity.compact,
                            leading: const Icon(Icons.person, size: 18),
                            title: Text(
                              name,
                              style: const TextStyle(fontSize: 13),
                            ),
                            onTap: () => onSelected(name),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Row(
              children: [
                Expanded(
                  child: FilledButton.tonalIcon(
                    onPressed: _busy ? null : _ignore,
                    icon: const Icon(Icons.person_off),
                    label: Text(_busy ? 'Working…' : 'Ignore this face'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Icons.check),
                    label: const Text('Save'),
                  ),
                ),
                if (face.name != null || face.ignored)
                  IconButton(
                    tooltip: 'Clear name',
                    onPressed: _busy ? null : _clear,
                    icon: const Icon(Icons.person_remove),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}