import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'zine_cover_recipe.dart';

/// A tiny, already-known summary of a zine's COVER — enough to paint the cover
/// card (the recipe-driven `ListZineCover` + its title) the instant the user
/// taps a Library zine row, before `unifiedListProvider` has loaded the list.
///
/// Originally this existed to give the Library → zine cover `Hero` a
/// destination laid out on frame 1. That flight was reverted, but the seed
/// earns its keep on its own: without it the first (uncached) open paints a
/// blank cover until `unifiedListProvider` lands. `ListPageScreen` renders the
/// cover from this seed during the `state.list == null` loading frame. It is
/// the cover-side analogue of [DetailSeed] (which does the same for the
/// event/venue collage).
class ZineCoverSeed {
  final ZineCoverRecipe recipe;
  final String title;

  const ZineCoverSeed({required this.recipe, required this.title});
}

/// Max entries kept in the in-memory cover-seed cache. Oldest are evicted
/// (insertion order) so the map can't grow without bound as the user browses.
const int _kZineCoverSeedCacheMax = 96;

/// In-memory `listId -> ZineCoverSeed` cache. Bounded + LRU-ish, mirroring
/// `detailSeedCacheProvider`. Ephemeral UI state — clears on restart.
final zineCoverSeedProvider = StateProvider<Map<String, ZineCoverSeed>>(
  (ref) => const {},
);

extension ZineCoverSeedWidgetRef on WidgetRef {
  ZineCoverSeed? zineCoverSeed(String listId) =>
      read(zineCoverSeedProvider)[listId];

  void cacheZineCoverSeed(String listId, ZineCoverSeed seed) {
    final current = read(zineCoverSeedProvider);
    // Rebuild with the newest key last (insertion order = recency).
    final next = <String, ZineCoverSeed>{...current}..remove(listId);
    next[listId] = seed;
    while (next.length > _kZineCoverSeedCacheMax) {
      next.remove(next.keys.first);
    }
    read(zineCoverSeedProvider.notifier).state = next;
  }
}
