import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../ml/detection_index.dart';
import '../ml/faces.dart';
import '../state/app_state.dart';
import 'people_screen.dart';

/// Worklist for getting unknown faces dealt with: a grid of face captures,
/// each with a quick naming field and an ignore action. Naming (or ignoring)
/// a face removes it from the page immediately.
class UnnamedPeopleScreen extends StatelessWidget {
  const UnnamedPeopleScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    final index = state.detectionIndex;
    return Scaffold(
      appBar: AppBar(title: const Text('Unnamed people')),
      body: ListenableBuilder(
        listenable: index,
        builder: (context, _) {
          final faces = index.unnamedFaces();
          if (faces.isEmpty) {
            return const Center(
              child: Text('Everyone is named. Nice work.'),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 170,
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 0.72,
            ),
            itemCount: faces.length,
            itemBuilder: (context, i) => _UnnamedFaceTile(
              key: ValueKey('${faces[i].linkId}:${faces[i].faceIndex}'),
              state: state,
              face: faces[i],
            ),
          );
        },
      ),
    );
  }
}

class _UnnamedFaceTile extends StatefulWidget {
  const _UnnamedFaceTile({
    super.key,
    required this.state,
    required this.face,
  });

  final AppState state;
  final ({String linkId, int faceIndex, Rect rect}) face;

  @override
  State<_UnnamedFaceTile> createState() => _UnnamedFaceTileState();
}

class _UnnamedFaceTileState extends State<_UnnamedFaceTile> {
  Uint8List? _thumb;
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
    final decoded = await decodedPreviewFor(widget.state, widget.face.linkId);
    if (!mounted) return;
    Uint8List? thumb;
    if (decoded != null) {
      thumb = cropFaceJpegFromDecoded(decoded, widget.face.rect, size: 200);
    }
    if (!mounted) return;
    setState(() => _thumb = thumb);
  }

  Future<void> _submit() async {
    final name = _name.text.trim();
    if (name.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      await _index.nameFace(
        linkId: widget.face.linkId,
        faceIndex: widget.face.faceIndex,
        name: name,
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _ignore() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _index.ignoreFace(widget.face.linkId, widget.face.faceIndex);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Opacity(
      opacity: _busy ? 0.5 : 1,
      child: Column(
        children: [
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: _thumb != null
                  ? Image.memory(_thumb!, fit: BoxFit.cover)
                  : Container(color: scheme.surfaceContainerHighest),
            ),
          ),
          const SizedBox(height: 6),
          RawAutocomplete<String>(
            textEditingController: _name,
            focusNode: _focus,
            optionsBuilder: (value) {
              final q = value.text.trim().toLowerCase();
              final people = _index.identities;
              if (q.isEmpty) return const <String>[];
              return [
                for (final id in people)
                  if (id.allNames.any((n) => n.toLowerCase().contains(q)))
                    id.name,
              ];
            },
            fieldViewBuilder: (context, controller, focusNode, onSelected) {
              return TextField(
                controller: controller,
                focusNode: focusNode,
                enabled: !_busy,
                textCapitalization: TextCapitalization.words,
                style: const TextStyle(fontSize: 13),
                decoration: const InputDecoration(
                  hintText: 'Name…',
                  isDense: true,
                  border: OutlineInputBorder(),
                  contentPadding:
                      EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                ),
                onSubmitted: (_) => _submit(),
              );
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
            onSelected: (name) {
              _name.text = name;
              _submit();
            },
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 28,
            child: Row(
              children: [
                Expanded(
                  child: TextButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Icons.check, size: 16),
                    label: const Text('Name', style: TextStyle(fontSize: 12)),
                    style: TextButton.styleFrom(padding: EdgeInsets.zero),
                  ),
                ),
                IconButton(
                  tooltip: "Don't tag this person",
                  onPressed: _ignore,
                  icon: const Icon(Icons.person_off, size: 18),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}