import 'package:flutter/material.dart';

import 'data/event_repository.dart';
import 'data/saved_store.dart';
import 'domain/event.dart';
import 'l10n/app_localizations.dart';
import 'screens/event_detail.dart';
import 'theme.dart';
import 'widgets/event_card.dart';
import 'widgets/soko_button.dart';

class SokoApp extends StatelessWidget {
  const SokoApp({
    super.key,
    required this.repository,
    required this.savedStore,
  });
  final EventRepository repository;
  final SavedStore savedStore;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Soko · Interview demo',
    debugShowCheckedModeBanner: false,
    theme: buildTheme(),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: DiscoveryScreen(repository: repository, savedStore: savedStore),
  );
}

class DiscoveryScreen extends StatefulWidget {
  const DiscoveryScreen({
    super.key,
    required this.repository,
    required this.savedStore,
  });
  final EventRepository repository;
  final SavedStore savedStore;

  @override
  State<DiscoveryScreen> createState() => _DiscoveryScreenState();
}

class _DiscoveryScreenState extends State<DiscoveryScreen> {
  List<Event> _events = [];
  Set<String> _saved = {};
  bool _loading = true;
  bool _failed = false;
  int _tab = 0;
  String _query = '';
  final _search = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final events = await widget.repository.load();
      final saved = await widget.savedStore.read();
      if (!mounted) return;
      setState(() {
        _events = events;
        _saved = saved;
        _loading = false;
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _failed = true;
          _loading = false;
        });
      }
    }
  }

  Future<bool> _toggleSave(Event event) async {
    final next = {..._saved};
    final saved = next.add(event.id);
    if (!saved) {
      next.remove(event.id);
    }
    await widget.savedStore.write(next);
    if (mounted) setState(() => _saved = next);
    return saved;
  }

  void _open(Event event) => Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => EventDetail(
        event: event,
        isSaved: _saved.contains(event.id),
        onToggleSave: () => _toggleSave(event),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final strings = AppLocalizations.of(context);
    final visible = _events
        .where(
          (event) =>
              (_tab == 0 || _saved.contains(event.id)) && event.matches(_query),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'soko',
          style: TextStyle(
            fontSize: 32,
            fontWeight: FontWeight.w800,
            letterSpacing: -2,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 24),
            child: Text(strings.city),
          ),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (tab) => setState(() {
          _tab = tab;
          _query = '';
          _search.clear();
        }),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.explore_outlined),
            selectedIcon: const Icon(Icons.explore),
            label: strings.discover,
          ),
          NavigationDestination(
            icon: const Icon(Icons.bookmark_border),
            selectedIcon: const Icon(Icons.bookmark),
            label: strings.saved,
          ),
        ],
      ),
      body: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1040),
          child: CustomScrollView(
            slivers: [
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
                sliver: SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        strings.demoLabel,
                        style: Theme.of(context).textTheme.labelMedium,
                      ),
                      const SizedBox(height: 20),
                      Text(
                        _tab == 0 ? strings.discoveryTitle : strings.savedTitle,
                        style: Theme.of(context).textTheme.headlineLarge,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        _tab == 0
                            ? strings.discoverySubtitle
                            : strings.savedSubtitle,
                      ),
                      const SizedBox(height: 24),
                      TextField(
                        controller: _search,
                        onChanged: (value) => setState(() => _query = value),
                        decoration: InputDecoration(
                          labelText: strings.search,
                          prefixIcon: const Icon(Icons.search),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_loading)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(40),
                    child: Center(
                      child: CircularProgressIndicator(
                        semanticsLabel: strings.loading,
                      ),
                    ),
                  ),
                )
              else if (_failed)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      children: [
                        Text(strings.loadError),
                        const SizedBox(height: 16),
                        SokoButton(label: strings.retry, onPressed: _load),
                      ],
                    ),
                  ),
                )
              else if (visible.isEmpty)
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      _query.isNotEmpty
                          ? strings.noMatches
                          : _tab == 1
                          ? strings.noSaved
                          : strings.noEvents,
                    ),
                  ),
                )
              else
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                  sliver: SliverLayoutBuilder(
                    builder: (context, constraints) {
                      final columns = constraints.crossAxisExtent >= 850
                          ? 3
                          : constraints.crossAxisExtent >= 560
                          ? 2
                          : 1;
                      // Rows let cards grow with titles and text scaling.
                      return SliverList.builder(
                        itemCount: (visible.length / columns).ceil(),
                        itemBuilder: (context, row) => Padding(
                          padding: const EdgeInsets.only(bottom: 20),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (
                                var column = 0;
                                column < columns;
                                column++
                              ) ...[
                                if (column > 0) const SizedBox(width: 20),
                                Expanded(
                                  child: row * columns + column < visible.length
                                      ? EventCard(
                                          event:
                                              visible[row * columns + column],
                                          isSaved: _saved.contains(
                                            visible[row * columns + column].id,
                                          ),
                                          onTap: () => _open(
                                            visible[row * columns + column],
                                          ),
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ],
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
