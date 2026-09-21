import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../utils/map_seed.dart';

/// Holds the FIXED, already-hydrated list the map should render instead of the
/// live `/map/pins` pipeline — the chat map. Set by the chat's "view on map"
/// action before `context.push('/chat-map')` and cleared in the `finally` after
/// the route pops; `null` everywhere else (the standalone `/map`).
///
/// The seed lives at the ROOT container (not a nested `ProviderScope` override)
/// on purpose: the pipeline providers (`mapSelectionProvider`,
/// `mapSettledSelectionProvider`, `mapGridProvider`) branch on it at the top and
/// return the seeded shapes when it's set. A root read avoids Riverpod's scoped-
/// override rule (every transitive dependent — `mapMarkersProvider`,
/// `mapHighlightProvider`, … — would otherwise need `dependencies: [...]`), and
/// keeps `/map` byte-identical: the branch is a `null` check that falls through.
final mapSeedProvider = StateProvider<SeededMapData?>((ref) => null);

/// True while the map is showing a seeded (chat) list — derived from
/// [mapSeedProvider]. Read by the separate `const` results-sheet widgets (which
/// can't take a constructor flag) to hide the live-search chrome (the
/// What/From/When filter footer). `MapScreen` uses its own `seeded` flag.
final mapSeededModeProvider = Provider<bool>(
  (ref) => ref.watch(mapSeedProvider) != null,
);
