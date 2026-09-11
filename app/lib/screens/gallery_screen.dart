import 'dart:io';

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../ml/detection.dart';
import '../ml/detection_index.dart';
import '../ml/faces.dart';
import '../ml/library_scanner.dart';
import '../platform/contacts.dart';
import '../state/app_state.dart';
import 'contact_picker.dart';
import 'lightbox_screen.dart';

class GalleryScreen extends StatefulWidget {
  const GalleryScreen({super.key, required this.state});

  final AppState state;

  @override
  State<GalleryScreen> createState() => _GalleryScreenState();
}

class _GalleryScreenState extends State<GalleryScreen> {
  final _scroll = ScrollController();
  DetectionGroup? _filter;
  String? _personName;
  bool _unnamed = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_scroll.position.extentAfter < 800) {
      widget.state.loadMore();
    }
  }

  void _toggleScan() {
    final scanner = widget.state.detector;
    if (scanner.running) {
      scanner.cancel();
      return;
    }
    final linkIds = widget.state.photos.map((p) => p.linkId).toList();
    scanner.start(linkIds);
  }

  @override
  Widget build(BuildContext context) {
    final state = widget.state;
    final index = state.detectionIndex;
    final scanner = state.detector;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Photon Library'),
        actions: [
          if (Platform.isAndroid)
            IconButton(
              tooltip: scanner.running ? 'Stop scanning' : 'Scan for objects',
              icon: Icon(scanner.running ? Icons.stop : Icons.psychology),
              onPressed: _toggleScan,
            ),
          IconButton(
            tooltip: 'Sign out',
            icon: const Icon(Icons.logout),
            onPressed: () => state.logout(),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([state, index, scanner]),
        builder: (context, _) {
          final photos = state.photos;
          if (state.error != null) {
            return _ErrorView(
              message: state.error!,
              onRetry: () => state.loadMore(),
            );
          }
          if (photos.isEmpty && state.loading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (photos.isEmpty) {
            return const Center(child: Text('No photos yet.'));
          }

          final filtered = [
            for (final p in photos)
              if (_matches(index, p.linkId)) p,
          ];

          return Column(
            children: [
              if (scanner.running) _ScanProgress(scanner: scanner),
              if (Platform.isAndroid) _FilterBar(
                selected: _filter,
                personName: _personName,
                unnamed: _unnamed,
                scannedCount: index.scannedCount,
                onSelected: (g) => setState(() {
                  _filter = g;
                  _personName = null;
                  _unnamed = false;
                }),
                onPeople: _showPeopleSheet,
              ),
              Expanded(
                child: filtered.isEmpty
                    ? _EmptyFilter(
                        group: _filter,
                        personName: _personName,
                        unnamed: _unnamed,
                        scannedCount: index.scannedCount,
                        onScan: _filter == null && _personName == null
                            ? null
                            : _toggleScan,
                      )
                    : GridView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.all(2),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 240,
                              mainAxisSpacing: 2,
                              crossAxisSpacing: 2,
                            ),
                        itemCount:
                            filtered.length + (state.hasMore ? 1 : 0),
                        itemBuilder: (context, i) {
                          if (i >= filtered.length) {
                            return const Center(
                              child: Padding(
                                padding: EdgeInsets.all(16),
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              ),
                            );
                          }
                          final photo = filtered[i];
                          return _PhotoTile(
                            state: state,
                            linkId: photo.linkId,
                            onTap: () => _openLightbox(photo),
                          );
                        },
                      ),
              ),
            ],
          );
        },
      ),
    );
  }

  bool _matches(DetectionIndex index, String linkId) {
    if (_personName != null) return index.peopleFor(linkId).contains(_personName);
    if (_unnamed) return index.hasUnnamedFace(linkId);
    if (_filter != null) return index.groupsFor(linkId).contains(_filter);
    return true;
  }

  Future<void> _showPeopleSheet() async {
    final index = widget.state.detectionIndex;
    final selection = await showModalBottomSheet<_PeopleSelection>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (_) => _PeopleSheet(index: index),
    );
    if (selection == null || !mounted) return;
    setState(() {
      _filter = null;
      _personName = selection.name;
      _unnamed = selection.unnamed;
    });
  }

  void _openLightbox(Photo photo) {
    final index =
        widget.state.photos.indexWhere((p) => p.linkId == photo.linkId);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => LightboxScreen(
          state: widget.state,
          initialIndex: index < 0 ? 0 : index,
        ),
      ),
    );
  }
}

class _ScanProgress extends StatelessWidget {
  const _ScanProgress({required this.scanner});

  final LibraryScanner scanner;

  @override
  Widget build(BuildContext context) {
    final progress = scanner.progress;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        LinearProgressIndicator(
          value: progress,
          minHeight: 2,
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Text(
              scanner.cancelRequested
                  ? 'Stopping…'
                  : 'Scanning ${scanner.processed}/${scanner.total}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ),
      ],
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.selected,
    required this.personName,
    required this.unnamed,
    required this.scannedCount,
    required this.onSelected,
    required this.onPeople,
  });

  final DetectionGroup? selected;
  final String? personName;
  final bool unnamed;
  final int scannedCount;
  final ValueChanged<DetectionGroup?> onSelected;
  final VoidCallback onPeople;

  @override
  Widget build(BuildContext context) {
    final personActive = personName != null || unnamed;
    final chips = <Widget>[
      Padding(
        padding: const EdgeInsets.only(left: 12),
        child: FilterChip(
          label: const Text('All'),
          selected: !personActive && selected == null,
          onSelected: (_) => onSelected(null),
        ),
      ),
      Padding(
        padding: const EdgeInsets.only(left: 8),
        child: FilterChip(
          avatar: const Icon(Icons.face, size: 18),
          label: Text(
            personName ?? (unnamed ? 'Unnamed' : 'People'),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          selected: personActive,
          onSelected: (_) => onPeople(),
          tooltip: 'Filter by person',
        ),
      ),
      for (final g in DetectionGroup.values)
        if (g != DetectionGroup.people) ...[
          Padding(
            padding: const EdgeInsets.only(left: 8),
            child: FilterChip(
              avatar: Icon(g.icon, size: 18),
              label: Text(g.label),
              selected: !personActive && selected == g,
              onSelected: (_) => onSelected(g),
            ),
          ),
        ],
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Wrap(spacing: 4, runSpacing: 4, children: chips),
      ),
    );
  }
}

class _PhotoTile extends StatelessWidget {
  const _PhotoTile({
    required this.state,
    required this.linkId,
    required this.onTap,
  });

  final AppState state;
  final String linkId;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: FutureBuilder(
        future: state.preview(linkId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.done &&
              snapshot.hasData) {
            return Image.memory(
              snapshot.data!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            );
          }
          final theme = Theme.of(context);
          return Container(
            color: theme.colorScheme.surfaceContainerHighest,
            child: Center(
              child: snapshot.hasError
                  ? Icon(
                      Icons.broken_image_outlined,
                      color: theme.colorScheme.outline,
                    )
                  : const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
            ),
          );
        },
      ),
    );
  }
}

class _EmptyFilter extends StatelessWidget {
  const _EmptyFilter({
    this.group,
    this.personName,
    this.unnamed = false,
    required this.scannedCount,
    required this.onScan,
  });

  final DetectionGroup? group;
  final String? personName;
  final bool unnamed;
  final int scannedCount;
  final VoidCallback? onScan;

  @override
  Widget build(BuildContext context) {
    if (scannedCount == 0 && (group != null || personName != null)) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('No photos scanned yet.'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onScan,
              icon: const Icon(Icons.psychology),
              label: const Text('Scan library'),
            ),
          ],
        ),
      );
    }
    final message = personName != null
        ? 'No photos of $personName yet.'
        : unnamed
            ? 'No photos with unnamed faces yet.'
            : 'No ${group?.label.toLowerCase()} photos yet.';
    return Center(child: Text(message));
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(message, textAlign: TextAlign.center),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PeopleSelection {
  const _PeopleSelection({this.name, this.unnamed = false});

  final String? name;
  final bool unnamed;
}

/// Lists named people with photo counts, plus an "unnamed people" row.
/// Tap to filter by a person; edit names/aliases via the row menu, or select
/// several people and combine them into one.
class _PeopleSheet extends StatefulWidget {
  const _PeopleSheet({required this.index});

  final DetectionIndex index;

  @override
  State<_PeopleSheet> createState() => _PeopleSheetState();
}

class _PeopleSheetState extends State<_PeopleSheet> {
  bool _selecting = false;
  final Set<String> _selected = {};

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.index,
      builder: (context, _) {
        final identities = widget.index.identities;
        final counts = widget.index.countPeople();
        final unnamedCount = counts[DetectionIndex.kUnnamedPeople] ?? 0;
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.only(left: 12, right: 12, bottom: 12),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        'People',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                    ),
                    IconButton(
                      tooltip: _selecting
                          ? 'Cancel selection'
                          : 'Combine people',
                      icon: Icon(
                        _selecting ? Icons.close : Icons.merge_type,
                      ),
                      onPressed: () => setState(() {
                        _selecting = !_selecting;
                        _selected.clear();
                      }),
                    ),
                    if (_selecting)
                      FilledButton.tonalIcon(
                        onPressed: _selected.length >= 2 ? _merge : null,
                        icon: const Icon(Icons.merge),
                        label: Text('Combine (${_selected.length})'),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                Flexible(
                  child: SingleChildScrollView(
                    child: Column(
                      children: [
                        for (final id in identities)
                          ListTile(
                            leading: _selecting
                                ? Checkbox(
                                    value: _selected.contains(id.name),
                                    onChanged: (v) => setState(() {
                                      if (v == true) {
                                        _selected.add(id.name);
                                      } else {
                                        _selected.remove(id.name);
                                      }
                                    }),
                                  )
                                : id.linkedToContact
                                    ? ContactAvatar(
                                        contact: PhoneContact(
                                          id: id.contactId!,
                                          name: id.contactDisplayName ??
                                              id.name,
                                          photoUri: id.contactPhotoUri,
                                        ),
                                      )
                                    : CircleAvatar(
                                        child: Text(
                                          id.name.isEmpty
                                              ? '?'
                                              : id.name[0].toUpperCase(),
                                        ),
                                      ),
                            title: Text(id.name),
                            subtitle: Text(_subtitle(id, counts)),
                            onTap: _selecting
                                ? () => setState(() {
                                      if (!_selected.add(id.name)) {
                                        _selected.remove(id.name);
                                      }
                                    })
                                : () => Navigator.pop(
                                    context,
                                    _PeopleSelection(name: id.name),
                                  ),
                            trailing: _selecting
                                ? null
                                : _identityMenu(context, id),
                          ),
                        if (!_selecting && unnamedCount > 0)
                          ListTile(
                            leading: const CircleAvatar(
                              child: Icon(Icons.face_outlined, size: 20),
                            ),
                            title: const Text('Unnamed people'),
                            subtitle: Text(
                              '$unnamedCount '
                              '${unnamedCount == 1 ? 'photo' : 'photos'}',
                            ),
                            onTap: () => Navigator.pop(
                              context,
                              const _PeopleSelection(unnamed: true),
                            ),
                          ),
                        if (identities.isEmpty && unnamedCount == 0)
                          const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 24,
                            ),
                            child: Text(
                              'No known people yet. Open a photo, tap '
                              '“People”, and name a face to start filtering.',
                            ),
                          ),
                        if (_selecting)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 8),
                            child: Text(
                              'Select the people that are actually the same '
                              'person, then tap Combine.',
                              style: TextStyle(fontSize: 12),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _subtitle(PersonIdentity id, Map<String, int> counts) {
    final n = counts[id.name] ?? 0;
    final photos = '$n ${n == 1 ? 'photo' : 'photos'}';
    final contact =
        id.linkedToContact ? ' · ${id.contactDisplayName ?? 'contact'}' : '';
    final alias = id.aliases.isEmpty ? '' : ' · also ${id.aliases.join(', ')}';
    return '$photos$alias$contact';
  }

  Future<void> _merge() async {
    final all = widget.index.identities;
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
    await widget.index.mergeIdentities(people);
    if (!mounted) return;
    setState(() {
      _selecting = false;
      _selected.clear();
    });
  }

  Widget _identityMenu(BuildContext context, PersonIdentity id) {
    return PopupMenuButton<String>(
      onSelected: (action) async {
        switch (action) {
          case 'edit':
            await _editIdentity(id);
          case 'link':
            await _linkContact(id);
          case 'unlink':
            await widget.index.unlinkContact(id.name);
            if (!context.mounted) return;
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
            if (ok == true) await widget.index.removeIdentity(id.name);
        }
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'edit', child: Text('Edit names')),
        id.linkedToContact
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
    );
  }

  Future<void> _linkContact(PersonIdentity id) async {
    final contact = await ContactPicker.pick(context);
    if (contact == null || !mounted) return;
    await widget.index.linkContact(
      forName: id.name,
      contactId: contact.id,
      contactDisplayName: contact.name,
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${id.name} linked to ${contact.name}'),
      ),
    );
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
    final renamed = await widget.index.updateIdentity(
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
}