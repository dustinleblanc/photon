import 'dart:async';

import 'package:flutter/material.dart';

import '../ml/faces.dart';
import '../state/app_state.dart';
import 'gallery_screen.dart';
import 'people_screen.dart';
import 'person_detail_screen.dart';
import 'settings_screen.dart';

/// Desktop shell: a persistent left navigation rail, a persistent top bar
/// (search, background-task progress, settings, context menu) and a nested
/// navigator so sub-pages get a back button that returns to their section
/// (a person page comes back to all people, settings to the section it came
/// from, and so on).
///
/// Mobile keeps the existing per-screen design; this is chosen in main().
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.state});

  final AppState state;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  final GlobalKey<NavigatorState> _navigator = GlobalKey<NavigatorState>();
  final TextEditingController _search = TextEditingController();
  final FocusNode _searchFocus = FocusNode();

  int _section = 0;
  bool _canPop = false;
  String? _pushedTitle;

  @override
  void initState() {
    super.initState();
    _searchFocus.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  void _selectSection(int index) {
    final nav = _navigator.currentState;
    if (index == _section) {
      // Re-tapping the current section returns to its root.
      nav?.popUntil((r) => r.isFirst);
      return;
    }
    setState(() {
      _section = index;
      _pushedTitle = null;
    });
    // The root route was built for the previous section; replace it so the
    // new section's screen is what shows.
    nav?.pushAndRemoveUntil(
      MaterialPageRoute(
        settings: RouteSettings(name: _sectionTitle),
        builder: (_) => _sectionBody(),
      ),
      (route) => false,
    );
  }

  void _push(Widget page, {required String title}) {
    _navigator.currentState?.push(
      MaterialPageRoute(
        builder: (_) => page,
        settings: RouteSettings(name: title),
      ),
    );
  }

  void _openPerson(String name) {
    _search.clear();
    _searchFocus.unfocus();
    _push(
      PersonDetailScreen(state: widget.state, name: name, embedded: true),
      title: name,
    );
  }

  Future<void> _openSettings() async {
    _push(
      SettingsScreen(state: widget.state, embedded: true),
      title: 'Settings',
    );
  }

  /// Turns a route change into top-bar state: whether Back is available and
  /// what the current page is called.
  void _onRouteChanged(Route? route) {
    final nav = _navigator.currentState;
    if (nav == null) return;
    final canPop = nav.canPop();
    setState(() {
      _canPop = canPop;
      _pushedTitle = canPop ? route?.settings.name : null;
    });
  }

  String get _sectionTitle =>
      switch (_section) { 0 => 'Library', 1 => 'People', _ => 'Photon Library' };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _section,
            onDestinationSelected: _selectSection,
            labelType: NavigationRailLabelType.all,
            leading: const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Icon(Icons.photo_library, size: 28),
            ),
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.grid_view_outlined),
                selectedIcon: Icon(Icons.grid_view),
                label: Text('Library'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.people_outline),
                selectedIcon: Icon(Icons.people),
                label: Text('People'),
              ),
            ],
          ),
          const VerticalDivider(width: 1),
          Expanded(
            child: Column(
              children: [
                _TopBar(
                  state: widget.state,
                  title: _pushedTitle ?? _sectionTitle,
                  canPop: _canPop,
                  onBack: () => _navigator.currentState?.pop(),
                  search: _search,
                  searchFocus: _searchFocus,
                  onOpenPerson: _openPerson,
                  onOpenSettings: _openSettings,
                ),
                const Divider(height: 1),
                Expanded(
                  child: Navigator(
                    key: _navigator,
                    // Every base route is named so the top bar can label it.
                    observers: [_ShellObserver(_onRouteChanged)],
                    onGenerateRoute: (settings) => MaterialPageRoute(
                      settings: settings,
                      builder: (_) => _sectionBody(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionBody() => switch (_section) {
        0 => GalleryScreen(state: widget.state, embedded: true),
        1 => PeopleScreen(state: widget.state, embedded: true),
        _ => GalleryScreen(state: widget.state, embedded: true),
      };
}

class _ShellObserver extends NavigatorObserver {
  _ShellObserver(this.onChange);

  final ValueChanged<Route?> onChange;

  @override
  void didPush(Route route, Route? previousRoute) => onChange(route);

  @override
  void didPop(Route route, Route? previousRoute) => onChange(previousRoute);

  @override
  void didRemove(Route route, Route? previousRoute) => onChange(previousRoute);

  @override
  void didReplace({Route? newRoute, Route? oldRoute}) => onChange(newRoute);
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.state,
    required this.title,
    required this.canPop,
    required this.onBack,
    required this.search,
    required this.searchFocus,
    required this.onOpenPerson,
    required this.onOpenSettings,
  });

  final AppState state;
  final String title;
  final bool canPop;
  final VoidCallback onBack;
  final TextEditingController search;
  final FocusNode searchFocus;
  final ValueChanged<String> onOpenPerson;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      child: Column(
        children: [
          SizedBox(
            height: 56,
            child: Row(
              children: [
                if (canPop)
                  IconButton(
                    tooltip: 'Back',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: onBack,
                  )
                else
                  const SizedBox(width: 8),
                const SizedBox(width: 4),
                Expanded(
                  flex: 3,
                  child: Text(
                    title,
                    style: Theme.of(context).textTheme.titleMedium,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: _PeopleSearch(
                    state: state,
                    controller: search,
                    focusNode: searchFocus,
                    onSelected: onOpenPerson,
                  ),
                ),
                const SizedBox(width: 8),
                ListenableBuilder(
                  listenable: state.detector,
                  builder: (context, _) {
                    final scanner = state.detector;
                    if (!scanner.running) return const SizedBox.shrink();
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Row(
                        children: [
                          SizedBox(
                            width: 90,
                            child: LinearProgressIndicator(
                              value: scanner.progress,
                              minHeight: 4,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${scanner.processed}/${scanner.total}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                          IconButton(
                            tooltip: 'Stop',
                            icon: const Icon(Icons.stop_circle_outlined),
                            onPressed: scanner.cancel,
                          ),
                        ],
                      ),
                    );
                  },
                ),
                IconButton(
                  tooltip: 'Settings',
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: onOpenSettings,
                ),
                PopupMenuButton<String>(
                  tooltip: 'Menu',
                  onSelected: (action) async {
                    switch (action) {
                      case 'scan':
                        _toggleScan(state);
                      case 'classify':
                        final ids = await state.libraryLinkIds();
                        if (state.detector.running) return;
                        final result =
                            await state.detector.classifyStyles(ids);
                        if (!context.mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              result.classified == 0
                                  ? 'Every photo is already classified'
                                  : 'Classified ${result.classified} photos · '
                                      '${result.illustrations} illustrations',
                            ),
                          ),
                        );
                      case 'sync':
                        await state.tagsSync.pullAndPush();
                      case 'signout':
                        state.logout();
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: 'scan',
                      child: Text(
                        state.detector.running
                            ? 'Stop scanning'
                            : 'Scan library',
                      ),
                    ),
                    const PopupMenuItem(
                      value: 'classify',
                      child: Text('Classify illustrations'),
                    ),
                    if (state.tagsSync.enabled)
                      const PopupMenuItem(
                        value: 'sync',
                        child: Text('Sync people now'),
                      ),
                    const PopupMenuDivider(),
                    const PopupMenuItem(
                      value: 'signout',
                      child: Text('Sign out'),
                    ),
                  ],
                ),
                const SizedBox(width: 8),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _toggleScan(AppState state) {
    final scanner = state.detector;
    if (scanner.running) {
      scanner.cancel();
      return;
    }
    unawaited(scanner.start([for (final p in state.photos) p.linkId]));
  }
}

/// Top-bar search over people: type a name (or alias), pick a match, and the
/// person's page opens.
class _PeopleSearch extends StatelessWidget {
  const _PeopleSearch({
    required this.state,
    required this.controller,
    required this.focusNode,
    required this.onSelected,
  });

  final AppState state;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state.detectionIndex,
      builder: (context, _) => RawAutocomplete<PersonIdentity>(
        textEditingController: controller,
        focusNode: focusNode,
        displayStringForOption: (id) => id.name,
        optionsBuilder: (value) {
          final q = value.text.trim().toLowerCase();
          if (q.isEmpty) return const <PersonIdentity>[];
          return [
            for (final id in state.detectionIndex.identities)
              if (id.allNames.any((n) => n.toLowerCase().contains(q))) id,
          ];
        },
        fieldViewBuilder: (context, c, f, _) => TextField(
          controller: c,
          focusNode: f,
          decoration: InputDecoration(
            hintText: 'Search people…',
            prefixIcon: const Icon(Icons.search, size: 20),
            isDense: true,
            filled: true,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(20),
              borderSide: BorderSide.none,
            ),
            contentPadding: const EdgeInsets.symmetric(vertical: 8),
            suffixIcon: c.text.isEmpty
                ? null
                : IconButton(
                    icon: const Icon(Icons.clear, size: 18),
                    onPressed: () => c.clear(),
                  ),
          ),
        ),
        optionsViewBuilder: (context, onSelectedOption, options) => Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            borderRadius: BorderRadius.circular(8),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 300, maxWidth: 360),
              child: ListView(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                children: [
                  for (final id in options)
                    ListTile(
                      dense: true,
                      leading: const Icon(Icons.person, size: 18),
                      title: Text(id.name),
                      subtitle: id.aliases.isEmpty
                          ? null
                          : Text(id.aliases.join(', ')),
                      onTap: () => onSelectedOption(id),
                    ),
                ],
              ),
            ),
          ),
        ),
        onSelected: (id) => onSelected(id.name),
      ),
    );
  }
}
