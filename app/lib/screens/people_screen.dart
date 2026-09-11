import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import '../ml/detection_index.dart';
import '../ml/faces.dart';
import '../platform/contacts.dart';
import '../state/app_state.dart';
import 'contact_picker.dart';
import 'unnamed_people_screen.dart';

/// Result returned to the gallery when the user picks a filter target.
class PeopleSelection {
  const PeopleSelection({this.name});

  final String? name;
}

/// Full-screen people browser: one photo tile per named person, type-ahead
/// search at the top, and combine/edit/delete via each tile's menu.
class PeopleScreen extends StatefulWidget {
  const PeopleScreen({super.key, required this.state});

  final AppState state;

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool _selecting = false;
  final Set<String> _selected = {};

  DetectionIndex get _index => widget.state.detectionIndex;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<PersonIdentity> get _visibleIdentities {
    final q = _query.trim().toLowerCase();
    final all = _index.identities;
    if (q.isEmpty) return all;
    return [
      for (final id in all)
        if (id.allNames.any((n) => n.toLowerCase().contains(q))) id,
    ];
  }

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      _selected.clear();
    });
  }

  void _onTileTap(PersonIdentity id) {
    if (_selecting) {
      setState(() {
        if (!_selected.add(id.name)) _selected.remove(id.name);
      });
      return;
    }
    Navigator.pop(context, PeopleSelection(name: id.name));
  }

  Future<void> _onMenuAction(String action, PersonIdentity id) async {
    switch (action) {
      case 'edit':
        await _editIdentity(id);
      case 'link':
        await _linkContact(id);
      case 'unlink':
        await _index.unlinkContact(id.name);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Unlinked ${id.name} from contacts')),
        );
      case 'delete':
        final ok = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text('Remove ${id.name}?'),
            content: const Text(
              'Their name will be cleared from matching faces. Faces '
              'stay indexed and can be named again.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('Remove'),
              ),
            ],
          ),
        );
        if (ok == true) await _index.removeIdentity(id.name);
    }
  }

  Future<void> _merge() async {
    final all = _index.identities;
    final people = all.where((i) => _selected.contains(i.name)).toList();
    if (people.length < 2 || !mounted) return;
    final preview = mergePeople(people);
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Combine into one person?'),
        content: Text(
          '${preview.name} will be the name, and ${preview.aliases.join(', ')} '
          'will be kept as other names. Every photo of them is grouped '
          'together.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Combine'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await _index.mergeIdentities(people);
    if (!mounted) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  Future<void> _editIdentity(PersonIdentity id) async {
    final name = TextEditingController(text: id.name);
    final aliases = TextEditingController(text: id.aliases.join(', '));
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Edit ${id.name}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: name,
              autofocus: true,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: aliases,
              textCapitalization: TextCapitalization.words,
              decoration: const InputDecoration(
                labelText: 'Other names',
                hintText: 'Comma separated, e.g. Karen, Mom',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final trimmed = name.text.trim();
              if (trimmed.isNotEmpty) Navigator.pop(dialogContext, trimmed);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (result == null || result.trim().isEmpty || !mounted) return;
    final aliasList = aliases.text
        .split(',')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
    final renamed = await _index.updateIdentity(
      oldName: id.name,
      newName: result,
      aliases: aliasList,
    );
    if (renamed != -1 || !mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'That name already belongs to another person — use Combine instead.',
        ),
      ),
    );
  }

  Future<void> _linkContact(PersonIdentity id) async {
    final contact = await ContactPicker.pick(context);
    if (contact == null || !mounted) return;
    await _index.linkContact(
      forName: id.name,
      contactId: contact.id,
      contactDisplayName: contact.name,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${id.name} linked to ${contact.name}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _index,
      builder: (context, _) {
        final identities = _visibleIdentities;
        final counts = _index.countPeople();
        final unnamedCount = counts[DetectionIndex.kUnnamedPeople] ?? 0;
        final searching = _query.trim().isNotEmpty;
        final sources = _index.bestFaces();
        final showUnnamed = !searching && !_selecting && unnamedCount > 0;
        final hasContent = identities.isNotEmpty || showUnnamed;

        return Scaffold(
          appBar: AppBar(
            title: TextField(
              controller: _search,
              onChanged: (v) => setState(() => _query = v),
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                hintText: 'Search people…',
                prefixIcon: const Icon(Icons.search),
                isDense: true,
                filled: true,
                fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
                suffixIcon: searching
                    ? IconButton(
                        tooltip: 'Clear search',
                        icon: const Icon(Icons.clear),
                        onPressed: () {
                          _search.clear();
                          setState(() => _query = '');
                        },
                      )
                    : null,
              ),
            ),
            actions: [
              IconButton(
                tooltip: _selecting ? 'Cancel selection' : 'Combine people',
                icon: Icon(_selecting ? Icons.close : Icons.merge_type),
                onPressed: _toggleSelecting,
              ),
              if (_selecting)
                FilledButton.tonalIcon(
                  onPressed: _selected.length >= 2 ? _merge : null,
                  icon: const Icon(Icons.merge),
                  label: Text('Combine (${_selected.length})'),
                ),
              const SizedBox(width: 8),
            ],
          ),
          body: !hasContent
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      searching
                          ? 'No people match "$_query".'
                          : 'No known people yet. Open a photo, tap '
                              '"People", and name a face to start filtering.',
                      textAlign: TextAlign.center,
                    ),
                  ),
                )
              : GridView.builder(
                  padding: const EdgeInsets.all(12),
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                        maxCrossAxisExtent: 180,
                        mainAxisSpacing: 12,
                        crossAxisSpacing: 12,
                        childAspectRatio: 0.78,
                      ),
                  itemCount: identities.length + (showUnnamed ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i >= identities.length) {
                      return _PersonCard(
                        key: const ValueKey('unnamed'),
                        count: unnamedCount,
                        label: 'Unnamed',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) =>
                                UnnamedPeopleScreen(state: widget.state),
                          ),
                        ),
                      );
                    }
                    final id = identities[i];
                    return _PersonCard(
                      key: ValueKey(
                        '${id.name}:${sources[id.name]?.linkId ?? '-'}',
                      ),
                      state: widget.state,
                      identity: id,
                      source: sources[id.name],
                      label: id.name,
                      count: counts[id.name] ?? 0,
                      selecting: _selecting,
                      selected: _selected.contains(id.name),
                      onTap: () => _onTileTap(id),
                      onMenuAction: (action) => _onMenuAction(action, id),
                    );
                  },
                ),
        );
      },
    );
  }
}

class _PersonCard extends StatefulWidget {
  const _PersonCard({
    super.key,
    this.state,
    this.identity,
    this.source,
    required this.count,
    required this.label,
    this.selecting = false,
    this.selected = false,
    this.onTap,
    this.onMenuAction,
  });

  final AppState? state;
  final PersonIdentity? identity;
  final ({String linkId, Rect rect})? source;
  final int count;
  final String label;
  final bool selecting;
  final bool selected;
  final VoidCallback? onTap;
  final void Function(String action)? onMenuAction;

  @override
  State<_PersonCard> createState() => _PersonCardState();
}

class _PersonCardState extends State<_PersonCard> {
  Uint8List? _thumb;
  var _loadedFor = const Object();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final id = widget.identity;
    final src = widget.source;
    if (id == null || src == null) return;
    _loadedFor = src.linkId;
    Uint8List? bytes;
    final decoded = await decodedPreviewFor(widget.state!, src.linkId);
    if (decoded != null) {
      bytes = cropFaceJpegFromDecoded(decoded, src.rect, size: 220);
    }
    if (bytes == null && Platform.isAndroid && id.linkedToContact) {
      bytes = await contactPhoto(id.contactId!);
    }
    if (!mounted || _loadedFor != src.linkId) return;
    setState(() => _thumb = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.identity;
    final scheme = Theme.of(context).colorScheme;
    final fallback = CircleAvatar(
      radius: 28,
      child: Text(
        widget.label.isEmpty ? '?' : widget.label[0].toUpperCase(),
        style: const TextStyle(fontSize: 24),
      ),
    );
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: widget.onTap,
      child: Column(
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: _thumb != null
                      ? Image.memory(_thumb!, fit: BoxFit.cover)
                      : Container(
                          color: scheme.surfaceContainerHighest,
                          child: Center(child: fallback),
                        ),
                ),
                if (widget.selecting)
                  Positioned(
                    top: 6,
                    left: 6,
                    child: Checkbox(
                      value: widget.selected,
                      onChanged: (_) => widget.onTap?.call(),
                    ),
                  )
                else if (widget.onMenuAction != null && id != null)
                  Positioned(
                    top: 2,
                    right: 2,
                    child: _TileMenu(
                      identity: id,
                      onSelected: widget.onMenuAction!,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(
            widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.titleSmall,
          ),
          Text(
            '${widget.count} ${widget.count == 1 ? 'photo' : 'photos'}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class _TileMenu extends StatelessWidget {
  const _TileMenu({required this.identity, required this.onSelected});

  final PersonIdentity identity;
  final void Function(String action) onSelected;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Colors.black38,
        shape: BoxShape.circle,
      ),
      child: PopupMenuButton<String>(
        onSelected: onSelected,
        icon: const Icon(Icons.more_vert, size: 18, color: Colors.white),
        iconSize: 18,
        padding: EdgeInsets.zero,
        itemBuilder: (context) => [
          const PopupMenuItem(value: 'edit', child: Text('Edit names')),
          if (Platform.isAndroid)
            identity.linkedToContact
                ? const PopupMenuItem(
                    value: 'unlink',
                    child: Text('Unlink from contact'),
                  )
                : const PopupMenuItem(
                    value: 'link',
                    child: Text('Link a contact…'),
                  ),
          const PopupMenuItem(value: 'delete', child: Text('Delete')),
        ],
      ),
    );
  }
}

/// Decoded preview cache shared by all tiles: one fetch per source photo no
/// matter how many people appear in it.
final Map<String, img.Image?> decodedPreviewCache = {};

Future<img.Image?> decodedPreviewFor(AppState state, String linkId) async {
  if (decodedPreviewCache.containsKey(linkId)) {
    return decodedPreviewCache[linkId];
  }
  img.Image? decoded;
  try {
    final bytes = await state.preview(linkId, size: 800);
    decoded = img.decodeImage(bytes);
  } catch (_) {}
  decodedPreviewCache[linkId] = decoded;
  return decoded;
}