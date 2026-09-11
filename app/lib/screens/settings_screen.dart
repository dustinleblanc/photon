import 'package:flutter/material.dart';

import '../state/app_state.dart';

/// App settings: cross-device tag sync, sign out.
class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.state});

  final AppState state;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        children: [
          const _Header('People'),
          ListTile(
            leading: const Icon(Icons.face),
            title: const Text('Browse people'),
            subtitle: const Text('Named people and unnamed faces'),
            onTap: () => Navigator.pop(context),
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