import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../ml/detection.dart';
import '../ml/detection_index.dart';
import '../ml/faces.dart';
import '../platform/contacts.dart';
import '../state/app_state.dart';
import 'contact_picker.dart';
import 'photo_tile.dart';
import 'gallery_screen.dart';
import 'person_detail_screen.dart';
import 'unnamed_people_screen.dart';

/// Full-screen people browser: one photo tile per named person, type-ahead
/// search at the top, and combine/edit/delete via each tile's menu.
class PeopleScreen extends StatefulWidget {
  const PeopleScreen({super.key, required this.state, this.embedded = false});

  /// True when hosted inside the desktop shell (which supplies the app bar
  /// and the search field); a compact action row replaces the bar.
  final bool embedded;

  final AppState state;

  @override
  State<PeopleScreen> createState() => _PeopleScreenState();
}

class _PeopleScreenState extends State<PeopleScreen> {
  final TextEditingController _search = TextEditingController();
  String _query = '';
  bool _selecting = false;
  bool _showHidden = false;
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
    // Hidden people stay out of the list unless explicitly revealed.
    final base = _showHidden ? all : [for (final id in all) if (!id.hidden) id];
    if (q.isEmpty) return base;
    return [
      for (final id in base)
        if (id.allNames.any((n) => n.toLowerCase().contains(q))) id,
    ];
  }

  /// The tile source for [id]: its chosen cover photo when that photo still
  /// has a face for them, else the automatic best face.
  ({String linkId, Rect rect})? _coverSource(
    PersonIdentity id,
    Map<String, ({String linkId, Rect rect})> auto,
  ) {
    final chosen = id.coverLinkId;
    if (chosen != null) {
      final rect = _index.faceRectIn(chosen, id.name);
      if (rect != null) return (linkId: chosen, rect: rect);
    }
    return auto[id.name];
  }

  void _toggleSelecting() {
    setState(() {
      _selecting = !_selecting;
      _selected.clear();
    });
  }

  Future<void> _onTileTap(PersonIdentity id) async {
    if (_selecting) {
      setState(() {
        if (!_selected.add(id.name)) _selected.remove(id.name);
      });
      return;
    }
    // The tile opens the person page: cover, actions and their photos.
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PersonDetailScreen(
          state: widget.state,
          name: id.name,
        ),
      ),
    );
  }

  Future<void> _onMenuAction(String action, PersonIdentity id) async {
    switch (action) {
      case 'edit':
        await _editIdentity(id);
      case 'hide':
        await _index.setPersonHidden(id.name, true);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${id.name} hidden from the timeline')),
        );
      case 'unhide':
        await _index.setPersonHidden(id.name, false);
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('${id.name} shown in the timeline')),
        );
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
                hintText: 'Comma separated, e.g. Kim, Mom',
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
        final autoSources = _index.bestFaces();
        // A hand-picked cover wins over the automatic best-face choice.
        final sources = <String, ({String linkId, Rect rect})>{};
        for (final id in identities) {
          final src = _coverSource(id, autoSources);
          if (src != null) sources[id.name] = src;
        }
        final showUnnamed = !searching && !_selecting && unnamedCount > 0;
        final petCount = searching || _selecting
            ? 0
            : _index.linkIdsWithGroup(DetectionGroup.pets).length;
        final showPets = !searching && !_selecting;
        final hasContent = identities.isNotEmpty || showUnnamed || showPets;

        final shell = widget.embedded;
        return Scaffold(
          appBar: AppBar(
            automaticallyImplyLeading: false,
            toolbarHeight: shell ? 48 : null,
            title: shell
                ? const Text('People')
                : TextField(
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
              if (_index.hiddenNames.isNotEmpty)
                IconButton(
                  tooltip: _showHidden ? 'Hide hidden people' : 'Show hidden people',
                  icon: Icon(
                    _showHidden ? Icons.visibility_off : Icons.visibility,
                  ),
                  onPressed: () =>
                      setState(() => _showHidden = !_showHidden),
                ),
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
                  itemCount: identities.length +
                      (showPets ? 1 : 0) +
                      (showUnnamed ? 1 : 0),
                  itemBuilder: (context, i) {
                    // Layout: [Pets] then people, then [Unnamed].
                    var index = i;
                    if (showPets) {
                      if (index == 0) {
                        return _PersonCard(
                          key: const ValueKey('pets'),
                          count: petCount,
                          label: 'Pets',
                          onTap: () => Navigator.of(context).push(
                            MaterialPageRoute(
                              settings: const RouteSettings(name: 'Pets'),
                              builder: (_) => GalleryScreen(
                                state: widget.state,
                                embedded: true,
                                groups: const {DetectionGroup.pets},
                              ),
                            ),
                          ),
                        );
                      }
                      index -= 1;
                    }
                    if (index >= identities.length) {
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
                    final id = identities[index];
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
    Uint8List? bytes =
        await faceThumb(widget.state!, src.linkId, src.rect, size: 220);
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
                      ? Image.memory(_thumb!, fit: BoxFit.cover, cacheWidth: 260)
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
                if (id != null && id.hidden)
                  const Positioned(
                    top: 6,
                    left: 6,
                    child: CircleAvatar(
                      radius: 11,
                      backgroundColor: Colors.black54,
                      child: Icon(
                        Icons.visibility_off,
                        size: 13,
                        color: Colors.white,
                      ),
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
          if (identity.hidden)
            const PopupMenuItem(
              value: 'unhide',
              child: Text('Show in timeline'),
            )
          else
            const PopupMenuItem(
              value: 'hide',
              child: Text('Hide from timeline'),
            ),
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

