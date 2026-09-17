import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../ml/detection_index.dart';
import '../ml/faces.dart';
import '../state/app_state.dart';
import 'contact_picker.dart';
import 'lightbox_screen.dart';
import 'photo_tile.dart';

/// One page for a person: cover, stats and every action (rename, aliases,
/// cover choice, clearing tags, hide, delete), with their photos right
/// below — the person-filtered gallery folded into the person page.
class PersonDetailScreen extends StatefulWidget {
  const PersonDetailScreen({
    super.key,
    required this.state,
    required this.name,
    this.embedded = false,
  });

  final AppState state;
  final String name;

  /// True when hosted inside the desktop shell, which supplies the app bar
  /// and back button.
  final bool embedded;

  @override
  State<PersonDetailScreen> createState() => _PersonDetailScreenState();
}

class _PersonDetailScreenState extends State<PersonDetailScreen> {
  final ScrollController _scroll = ScrollController();
  var _loadingAll = false;

  DetectionIndex get _index => widget.state.detectionIndex;
  AppState get _state => widget.state;

  PersonIdentity? get _identity => _index.identityForName(widget.name);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    // Filters run over loaded photos, so fetch the rest so the grid is
    // complete rather than only showing the first page.
    WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_loadAll()));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 800) {
      unawaited(_state.loadMore());
    }
  }

  Future<void> _loadAll() async {
    if (_loadingAll || !_state.hasMore) return;
    setState(() => _loadingAll = true);
    await _state.loadAll();
    if (mounted) setState(() => _loadingAll = false);
  }

  bool _matches(String linkId) => _index.hasPerson(linkId, widget.name);

  void _openPhoto(String linkId) {
    final index =
        _state.photos.indexWhere((p) => p.linkId == linkId);
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => LightboxScreen(
          state: _state,
          initialIndex: index < 0 ? 0 : index,
        ),
      ),
    );
  }

  Future<void> _rename() async {
    final id = _identity;
    if (id == null) return;
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
    if (!mounted) return;
    if (renamed == -1) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'That name already belongs to another person — use Combine instead.',
          ),
        ),
      );
      return;
    }
    setState(() {});
  }

  Future<void> _clearFaceTags() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Clear ${widget.name}\'s face tags?'),
        content: const Text(
          'Every photo of them is untagged and their matching profile is '
          'reset, so past mistakes stop repeating. The person stays in your '
          'list and can be re-taught by tagging a few photos.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear tags'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    final count = await _index.clearPersonFaces(widget.name);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Cleared $count tagged photos')),
    );
    setState(() {});
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Remove ${widget.name}?'),
        content: const Text(
          'Their name will be cleared from matching faces. Faces stay '
          'indexed and can be named again.',
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
    if (ok != true || !mounted) return;
    await _index.removeIdentity(widget.name);
    if (!mounted) return;
    Navigator.pop(context);
  }

  Future<void> _pickCover() async {
    final id = _identity;
    if (id == null) return;
    final candidates = _index.coversFor(id.name);
    if (candidates.isEmpty) return;
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Choose a photo for ${id.name}',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              const SizedBox(height: 8),
              Flexible(
                child: GridView.builder(
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 120,
                    mainAxisSpacing: 8,
                    crossAxisSpacing: 8,
                  ),
                  itemCount: candidates.length,
                  itemBuilder: (context, i) => _CoverOption(
                    state: _state,
                    linkId: candidates[i],
                    name: id.name,
                    selected: id.coverLinkId == candidates[i],
                    onTap: () => Navigator.pop(sheetContext, candidates[i]),
                  ),
                ),
              ),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: () => Navigator.pop(sheetContext, ''),
                  child: const Text('Use automatic choice'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    await _index.setPersonCover(id.name, chosen.isEmpty ? null : chosen);
    if (!mounted) return;
    setState(() {});
  }

  Future<void> _toggleContact() async {
    final id = _identity;
    if (id == null) return;
    if (id.linkedToContact) {
      await _index.unlinkContact(id.name);
      if (mounted) setState(() {});
      return;
    }
    final contact = await ContactPicker.pick(context);
    if (contact == null) return;
    await _index.linkContact(
      forName: id.name,
      contactId: contact.id,
      contactDisplayName: contact.name,
    );
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([_index, _state]),
      builder: (context, _) {
        final id = _identity;
        if (id == null) {
          return const Scaffold(body: Center(child: Text('Person removed.')));
        }
        final count = _index.countPeople()[id.name] ?? 0;
        final hidden = _index.hiddenNames;
        final photos = _state.photos;
        final filtered = [
          for (final p in photos)
            if (_matches(p.linkId)) p,
        ];
        final actionsMenu = Padding(
          padding: const EdgeInsets.only(left: 8),
          child: PopupMenuButton<String>(
            tooltip: 'Person actions',
            onSelected: (action) async {
                  switch (action) {
                    case 'rename':
                      await _rename();
                    case 'cover':
                      await _pickCover();
                    case 'contact':
                      await _toggleContact();
                    case 'clear':
                      await _clearFaceTags();
                    case 'hide':
                      await _index.setPersonHidden(id.name, !id.hidden);
                      if (mounted) setState(() {});
                    case 'delete':
                      await _delete();
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'rename',
                    child: Text('Rename & aliases'),
                  ),
                  const PopupMenuItem(
                    value: 'cover',
                    child: Text('Choose cover photo'),
                  ),
                  if (Platform.isAndroid)
                    PopupMenuItem(
                      value: 'contact',
                      child: Text(
                        id.linkedToContact
                            ? 'Unlink contact'
                            : 'Link a contact…',
                      ),
                    ),
                  const PopupMenuItem(
                    value: 'clear',
                    child: Text('Clear face tags'),
                  ),
                  PopupMenuItem(
                    value: 'hide',
                    child: Text(
                      id.hidden ? 'Show in timeline' : 'Hide from timeline',
                    ),
                  ),
            const PopupMenuItem(
              value: 'delete',
              child: Text('Delete person'),
            ),
          ],
        ),
        );
        return Scaffold(
          appBar: widget.embedded ? null : AppBar(
            title: Text(id.name),
            actions: [actionsMenu],
          ),
          body: CustomScrollView(
            controller: _scroll,
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _CoverImage(state: _state, identity: id, height: 200),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '$count ${count == 1 ? 'photo' : 'photos'}'
                              '${id.aliases.isEmpty ? '' : ' · also ${id.aliases.join(', ')}'}',
                              style: Theme.of(context).textTheme.bodyMedium,
                            ),
                          ),
                          if (id.hidden)
                            const Padding(
                              padding: EdgeInsets.only(left: 8),
                              child: Icon(Icons.visibility_off, size: 16),
                            ),
                          if (widget.embedded) actionsMenu,
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                  ],
                ),
              ),
              if (filtered.isEmpty)
                SliverFillRemaining(
                  hasScrollBody: false,
                  child: Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _loadingAll || _state.hasMore
                            ? 'Loading photos…'
                            : 'No photos of ${id.name} yet.',
                      ),
                    ),
                  ),
                )
              else
                SliverGrid.builder(
                  gridDelegate:
                      const SliverGridDelegateWithMaxCrossAxisExtent(
                    maxCrossAxisExtent: 240,
                    mainAxisSpacing: 2,
                    crossAxisSpacing: 2,
                  ),
                  itemCount: filtered.length + (_state.hasMore ? 1 : 0),
                  itemBuilder: (context, i) {
                    if (i >= filtered.length) {
                      return const Center(
                        child: Padding(
                          padding: EdgeInsets.all(16),
                          child: SizedBox(
                            width: 24,
                            height: 24,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      );
                    }
                    final photo = filtered[i];
                    return PhotoTile(
                      state: _state,
                      linkId: photo.linkId,
                      onTap: () => _openPhoto(photo.linkId),
                    );
                  },
                ),
              if (hidden.contains(id.name))
                const SliverToBoxAdapter(
                  child: Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(
                      'This person is hidden from the default timeline.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// Renders the person's cover: their chosen photo, else the automatic
/// best-face choice, else a placeholder.
class _CoverImage extends StatefulWidget {
  const _CoverImage({
    required this.state,
    required this.identity,
    required this.height,
  });

  final AppState state;
  final PersonIdentity identity;
  final double height;

  @override
  State<_CoverImage> createState() => _CoverImageState();
}

class _CoverImageState extends State<_CoverImage> {
  Uint8List? _crop;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final index = widget.state.detectionIndex;
    final id = widget.identity;
    ({String linkId, Rect rect})? source;
    final chosen = id.coverLinkId;
    if (chosen != null) {
      final rect = index.faceRectIn(chosen, id.name);
      if (rect != null) source = (linkId: chosen, rect: rect);
    }
    source ??= index.bestFaces()[id.name];
    if (source == null) return;
    final bytes =
        await faceThumb(widget.state, source.linkId, source.rect, size: 400);
    if (!mounted) return;
    setState(() => _crop = bytes);
  }

  @override
  Widget build(BuildContext context) {
    final crop = _crop;
    return Container(
      height: widget.height,
      width: double.infinity,
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: crop == null
          ? Center(
              child: Text(
                'No photo yet',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            )
          : Image.memory(crop, fit: BoxFit.cover),
    );
  }
}

class _CoverOption extends StatefulWidget {
  const _CoverOption({
    required this.state,
    required this.linkId,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final AppState state;
  final String linkId;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_CoverOption> createState() => _CoverOptionState();
}

class _CoverOptionState extends State<_CoverOption> {
  Uint8List? _crop;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final index = widget.state.detectionIndex;
    final rect = index.faceRectIn(widget.linkId, widget.name);
    if (rect == null) return;
    final bytes =
        await faceThumb(widget.state, widget.linkId, rect, size: 160);
    if (!mounted) return;
    setState(() => _crop = bytes);
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: widget.onTap,
      child: Container(
        decoration: BoxDecoration(
          border: widget.selected
              ? Border.all(
                  color: Theme.of(context).colorScheme.primary,
                  width: 3,
                )
              : null,
          borderRadius: BorderRadius.circular(8),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: _crop == null
              ? Container(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                )
              : Image.memory(_crop!, fit: BoxFit.cover),
        ),
      ),
    );
  }
}
