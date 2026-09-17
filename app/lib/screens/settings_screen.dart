import 'dart:async';

import 'package:flutter/material.dart';

import '../state/app_state.dart';

/// App settings: cross-device tag sync, sign out.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.state, this.embedded = false});

  final AppState state;

  /// True when hosted inside the desktop shell, which supplies the app bar.
  final bool embedded;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: embedded ? null : AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _Header('People'),
          ListTile(
            leading: const Icon(Icons.face),
            title: const Text('Browse people'),
            subtitle: const Text('Named people and unnamed faces'),
            onTap: () => Navigator.pop(context),
          ),
          ListenableBuilder(
            listenable: state.detector,
            builder: (context, _) {
              final scanner = state.detector;
              return Column(
                children: [
                  ListTile(
                    leading: const Icon(Icons.brush),
                    title: const Text('Classify illustrations'),
                    subtitle: Text(
                      scanner.running && scanner.total > 0
                          ? 'Classifying ${scanner.processed}/${scanner.total}…'
                          : 'Find drawings, screenshots and memes in photos '
                              'not checked yet',
                    ),
                    trailing: scanner.running
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          )
                        : null,
                    onTap: scanner.running
                        ? null
                        : () => _classify(context, state),
                  ),
                  ListTile(
                    leading: const Icon(Icons.refresh),
                    title: const Text('Re-classify illustrations'),
                    subtitle: const Text(
                      'Re-check every photo (slower) after the detector is '
                      'tuned',
                    ),
                    enabled: !scanner.running,
                    onTap: scanner.running
                        ? null
                        : () => _classify(context, state, force: true),
                  ),
                ],
              );
            },
          ),
          const _Header('Tag sync'),
          ListenableBuilder(
            listenable: state.tagsSync,
            builder: (context, _) {
              final sync = state.tagsSync;
              return Column(
                children: [
                  SwitchListTile(
                    secondary: Icon(
                      sync.enabled ? Icons.sync : Icons.sync_disabled,
                    ),
                    title: const Text('Sync people across devices'),
                    subtitle: const Text(
                      'Shares names (not photos) between your Mac and phone '
                      'through an encrypted file in your own Proton Drive.',
                    ),
                    value: sync.enabled,
                    onChanged: (v) async {
                      await sync.setEnabled(v);
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            v
                                ? (sync.error == null
                                    ? 'Tag sync on'
                                    : 'Tag sync failed: ${sync.error}')
                                : 'Tag sync off',
                          ),
                        ),
                      );
                    },
                  ),
                  if (sync.enabled)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Row(
                        children: [
                          if (sync.busy)
                            const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          else
                            Icon(
                              sync.error == null
                                  ? Icons.check_circle
                                  : Icons.error,
                              size: 16,
                              color: sync.error == null ? Colors.green : null,
                            ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              sync.error ??
                                  (sync.lastSyncedAt == null
                                      ? 'Not synced yet'
                                      : 'Last synced '
                                          '${_time(sync.lastSyncedAt!)}'),
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ),
                          TextButton(
                            onPressed: sync.busy
                                ? null
                                : () => sync.pullAndPush(),
                            child: const Text('Sync now'),
                          ),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
          const _Header('Face data'),
          ListTile(
            leading: const Icon(Icons.healing),
            title: const Text('Repair people profiles'),
            subtitle: const Text(
              'Drop wrong-looking confirmations and rebuild each person\'s '
              'matching profile. Fixes both missed matches and bad ones.',
            ),
            onTap: () => _repair(context, state),
          ),
          ListTile(
            leading: const Icon(Icons.cleaning_services),
            title: const Text('Clear all face tags'),
            subtitle: const Text(
              'Untag every face and remove all named people, keeping object '
              'detection. Faces can be scanned and named again.',
            ),
            onTap: () => _clearAllFaces(context, state),
          ),
          ListTile(
            leading: const Icon(Icons.restart_alt),
            title: const Text('Reset ML index'),
            subtitle: const Text(
              'Wipe everything — object detections, face tags and people — '
              'and start from zero. Run "Scan library" afterwards to rebuild.',
            ),
            onTap: () => _resetIndex(context, state),
          ),
          const _Header('Account'),
          ListTile(
            leading: const Icon(Icons.logout),
            title: const Text('Sign out'),
            onTap: () {
              final confirmed = showDialog<bool>(
                context: context,
                builder: (dialogContext) => AlertDialog(
                  title: const Text('Sign out?'),
                  content: const Text(
                    'You will need to sign in again to browse the library.',
                  ),
                  actions: [
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext, false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext, true),
                      child: const Text('Sign out'),
                    ),
                  ],
                ),
              );
              confirmed.then((ok) {
                if (ok == true) state.logout();
              });
            },
          ),
        ],
      ),
    );
  }

  String _time(DateTime t) =>
      '${t.hour.toString().padLeft(2, '0')}:'
      '${t.minute.toString().padLeft(2, '0')}';

  Future<void> _classify(BuildContext context, AppState state,
      {bool force = false}) async {
    final ids = await state.libraryLinkIds();
    if (state.detector.running) return;
    final wasUnchecked = force
        ? ids.length
        : ids
            .where((id) => !(state.detectionIndex.lookup(id)?.styleChecked ?? false))
            .length;
    if (wasUnchecked == 0) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Every photo is already classified'),
          ),
        );
      }
      return;
    }
    final result = await state.detector.classifyStyles(ids, force: force);
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Classified ${result.classified} photos · '
          '${result.illustrations} illustrations',
        ),
      ),
    );
  }

  Future<void> _repair(BuildContext context, AppState state) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Repair people profiles?'),
        content: const Text(
          'For each person, confirmations that don\'t look like the rest are '
          'un-tagged (they are wrong names) and their matching profile is '
          'rebuilt from the consistent ones. Photos that were wrongly tagged '
          'return to the unnamed queue.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Repair'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final result = await state.detectionIndex.repairIdentities();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Repaired ${result.identitiesRepaired} people · '
          '${result.facesCleared} wrong tags cleared',
        ),
      ),
    );
  }

  Future<void> _resetIndex(BuildContext context, AppState state) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Reset the ML index?'),
        content: const Text(
          'Object detections, every face tag and all named people are '
          'deleted. This cannot be undone — run "Scan library" afterwards to '
          're-index from scratch.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Reset'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final removed = await state.detectionIndex.resetIndex();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Index reset — removed $removed photos')),
    );
  }

  Future<void> _clearAllFaces(BuildContext context, AppState state) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Clear all face tags?'),
        content: const Text(
          'Every face tag is removed and every named person deleted. This '
          'cannot be undone, though faces can be scanned and named again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Clear all'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final count = await state.detectionIndex.clearAllFaces();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Cleared face tags from $count photos')),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          title,
          style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
        ),
      );
}