import 'dart:async';

import 'package:flutter/material.dart';

import '../ml/detection.dart';
import '../ml/faces.dart';
import '../state/app_state.dart';
import 'gallery_screen.dart';
import 'people_screen.dart';
import 'person_detail_screen.dart';
import 'settings_screen.dart';

/// One navigation destination. Photos/People/Settings are their own screens;
/// Pets/Objects/Illustrations are the gallery filtered to that group. The
/// same list renders as the sidebar on desktop and the bottom bar on mobile,
/// so the app has one navigation model everywhere.
class _Dest {
  const _Dest(
    this.label,
    this.icon,
    this.selectedIcon, {
    this.groups,
    this.people = false,
    this.settings = false,
  });

  final String label;
  final IconData icon;
  final IconData selectedIcon;

  /// Detection groups this destination filters the gallery to, or null for
  /// everything. Objects have no menu entry on purpose: the detector still
  /// classifies them and the search bar surfaces them by name.
  final Set<DetectionGroup>? groups;
  final bool people;
  final bool settings;
}

const List<_Dest> _dests = [
  _Dest('Photos', Icons.grid_view_outlined, Icons.grid_view),
  _Dest(
    'People & Pets',
    Icons.people_outline,
    Icons.people,
    people: true,
  ),
  _Dest(
    'Illustrations',
    Icons.brush_outlined,
    Icons.brush,
    groups: {DetectionGroup.illustrations},
  ),
  _Dest('Settings', Icons.settings_outlined, Icons.settings, settings: true),
];

/// App shell: one navigation menu (left rail on desktop, bottom bar on
/// mobile), a persistent top bar with search and a per-screen "…" context
/// menu, and a nested navigator so sub-pages (a person, settings) get a back
/// button to their section.
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

  bool _wasScanning = false;

  @override
  void initState() {
    super.initState();
    _searchFocus.addListener(() => setState(() {}));
    widget.state.detector.addListener(_onScannerChanged);
  }

  @override
  void dispose() {
    widget.state.detector.removeListener(_onScannerChanged);
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  /// Scans used to fail silently: the error was stored but never shown, so a
  /// failing scan looked like a no-op. Report the outcome when one ends.
  void _onScannerChanged() {
    final scanner = widget.state.detector;
    final running = scanner.running;
    if (_wasScanning && !running && mounted) {
      final error = scanner.error;
      final message = error != null
          ? 'Scan failed: $error'
          : scanner.scanned == 0
              ? 'Nothing to scan — ${scanner.total} photos already processed'
              : 'Scanned ${scanner.scanned} photos';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(message)),
      );
    }
    _wasScanning = running;
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

  /// Opens the photos containing a detected object label (from search).
  void _openLabel(String label) {
    _search.clear();
    _searchFocus.unfocus();
    _push(
      GalleryScreen(state: widget.state, embedded: true, label: label),
      title: label,
    );
  }

  bool _preparingScan = false;

  /// Scans the entire library (not just the pages loaded into the gallery).
  Future<void> _toggleScan() async {
    final state = widget.state;
    final scanner = state.detector;
    if (scanner.running) {
      scanner.cancel();
      return;
    }
    if (_preparingScan) return;
    setState(() => _preparingScan = true);
    try {
      final linkIds = await state.libraryLinkIds();
      if (mounted) scanner.start(linkIds);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Could not load the photo library: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _preparingScan = false);
    }
  }

  /// Turns a route change into top-bar state: whether Back is available and
  /// what the current page is called. The observer also fires while the
  /// Navigator is still building its first route, where calling setState
  /// directly throws ("setState() called during build"), so the update is
  /// deferred to the next frame.
  void _onRouteChanged(Route? route) {
    final nav = _navigator.currentState;
    if (nav == null) return;
    final canPop = nav.canPop();
    final title = canPop ? route?.settings.name : null;
    if (canPop == _canPop && title == _pushedTitle) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (canPop == _canPop && title == _pushedTitle) return;
      setState(() {
        _canPop = canPop;
        _pushedTitle = title;
      });
    });
  }

  String get _sectionTitle => _dests[_section].label;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final wide = constraints.maxWidth >= 720;
        final main = Column(
          children: [
            _TopBar(
              state: widget.state,
              title: _pushedTitle ?? _sectionTitle,
              canPop: _canPop,
              onBack: () => _navigator.currentState?.pop(),
              onScan: _toggleScan,
              scanPreparing: _preparingScan,
              search: _search,
              searchFocus: _searchFocus,
              onOpenPerson: _openPerson,
              onOpenLabel: _openLabel,
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
        );
        if (wide) {
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
                  destinations: [
                    for (final d in _dests)
                      NavigationRailDestination(
                        icon: Icon(d.icon),
                        selectedIcon: Icon(d.selectedIcon),
                        label: Text(d.label),
                      ),
                  ],
                ),
                const VerticalDivider(width: 1),
                Expanded(child: main),
              ],
            ),
          );
        }
        return Scaffold(
          body: main,
          bottomNavigationBar: NavigationBar(
            selectedIndex: _section,
            onDestinationSelected: _selectSection,
            labelBehavior:
                NavigationDestinationLabelBehavior.onlyShowSelected,
            destinations: [
              for (final d in _dests)
                NavigationDestination(
                  icon: Icon(d.icon),
                  selectedIcon: Icon(d.selectedIcon),
                  label: d.label,
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _sectionBody() {
    final dest = _dests[_section];
    if (dest.people) return PeopleScreen(state: widget.state, embedded: true);
    if (dest.settings) {
      return SettingsScreen(state: widget.state, embedded: true);
    }
    return GalleryScreen(
      state: widget.state,
      embedded: true,
      groups: dest.groups,
    );
  }
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
    required this.onScan,
    required this.scanPreparing,
    required this.search,
    required this.searchFocus,
    required this.onOpenPerson,
    required this.onOpenLabel,
  });

  final AppState state;
  final String title;
  final bool canPop;
  final VoidCallback onBack;
  final VoidCallback onScan;
  final bool scanPreparing;
  final TextEditingController search;
  final FocusNode searchFocus;
  final ValueChanged<String> onOpenPerson;
  final ValueChanged<String> onOpenLabel;

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
                    onOpenLabel: onOpenLabel,
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
                PopupMenuButton<String>(
                  tooltip: 'Menu',
                  onSelected: (action) async {
                    switch (action) {
                      case 'scan':
                        onScan();
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
                      enabled: !scanPreparing,
                      child: Text(
                        state.detector.running
                            ? 'Stop scanning'
                            : scanPreparing
                                ? 'Preparing…'
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

}

/// Top-bar search over people: type a name (or alias), pick a match, and the
/// person's page opens.
/// Search across everything the index knows: people (by name or alias) and
/// detected object labels. Picking a person opens their page; picking a label
/// opens the photos containing it — so "motorcycle" works without a menu
/// entry for objects.
class _PeopleSearch extends StatelessWidget {
  const _PeopleSearch({
    required this.state,
    required this.controller,
    required this.focusNode,
    required this.onSelected,
    required this.onOpenLabel,
  });

  final AppState state;
  final TextEditingController controller;
  final FocusNode focusNode;
  final ValueChanged<String> onSelected;
  final ValueChanged<String> onOpenLabel;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state.detectionIndex,
      builder: (context, _) => RawAutocomplete<Object>(
        textEditingController: controller,
        focusNode: focusNode,
        displayStringForOption: (o) =>
            o is PersonIdentity ? o.name : o.toString(),
        optionsBuilder: (value) {
          final q = value.text.trim();
          if (q.isEmpty) return const <Object>[];
          final lower = q.toLowerCase();
          return [
            for (final id in state.detectionIndex.identities)
              if (id.allNames.any((n) => n.toLowerCase().contains(lower))) id,
            ...state.detectionIndex.searchLabels(q),
          ];
        },
        fieldViewBuilder: (context, c, f, _) => TextField(
          controller: c,
          focusNode: f,
          decoration: InputDecoration(
            hintText: 'Search people or things…',
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
                  for (final o in options)
                    if (o is PersonIdentity)
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.person, size: 18),
                        title: Text(o.name),
                        subtitle: o.aliases.isEmpty
                            ? null
                            : Text(o.aliases.join(', ')),
                        onTap: () => onSelectedOption(o),
                      )
                    else
                      ListTile(
                        dense: true,
                        leading: const Icon(Icons.category_outlined, size: 18),
                        title: Text(o.toString()),
                        subtitle: const Text('Photos with this'),
                        onTap: () => onSelectedOption(o),
                      ),
                ],
              ),
            ),
          ),
        ),
        onSelected: (o) => o is PersonIdentity
            ? onSelected(o.name)
            : onOpenLabel(o.toString()),
      ),
    );
  }
}
