import 'package:flutter/widgets.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../data/models/chat_message.dart';

/// Derives a small category glyph for a chat result card's subcategory row.
///
/// Chat suggestions don't carry `primaryFacet` today — it's populated only on
/// `/map/hydrate` payloads (see the doc comment on [ItemSuggestion]) — so the
/// icon is a best-effort match on the item's coarse [ItemSuggestion.type] and
/// its category / tag / types strings, bucketed into the same six live facet
/// parents the map pins use (`eat_drink`, `nightlife`, `music`, `art`,
/// `outdoors`, `shopping`). Falls back to a neutral pin when nothing matches.
///
/// When the backend starts sending `primaryFacet` on chat suggestions
/// (PROD-1676), this can switch to keying off the facet parent directly.
IconData suggestionCategoryIcon(ItemSuggestion s) {
  if ((s.type ?? '').toLowerCase() == 'event') return LucideIcons.calendar;

  final haystack = <String>[
    s.category ?? '',
    ...s.categories,
    ...s.tags,
    ...?s.types,
    s.typeLabel ?? '',
  ].join(' ').toLowerCase();

  bool has(List<String> keywords) => keywords.any(haystack.contains);

  // Order matters: the more specific nightlife/coffee buckets win over the
  // broad eat_drink bucket (a "wine bar" is nightlife, not a restaurant).
  if (has(const [
    'wine',
    'bar',
    'pub',
    'club',
    'night',
    'cocktail',
    'brewery',
    'beer',
  ])) {
    return LucideIcons.wine;
  }
  if (has(const ['coffee', 'cafe', 'café', 'tea', 'bakery', 'brunch'])) {
    return LucideIcons.coffee;
  }
  if (has(const [
    'restaurant',
    'food',
    'eat',
    'dining',
    'bistro',
    'pizza',
    'sushi',
    'burger',
    'ice cream',
    'dessert',
    'tasca',
    'petisco',
  ])) {
    return LucideIcons.utensils;
  }
  if (has(const ['music', 'concert', 'live', 'dj', 'jazz', 'gig'])) {
    return LucideIcons.music;
  }
  if (has(const [
    'art',
    'gallery',
    'museum',
    'theatre',
    'theater',
    'culture',
    'exhibition',
    'cinema',
    'film',
  ])) {
    return LucideIcons.palette;
  }
  if (has(const [
    'park',
    'garden',
    'jardim',
    'outdoor',
    'nature',
    'beach',
    'trail',
    'hike',
    'viewpoint',
    'miradouro',
  ])) {
    return LucideIcons.trees;
  }
  if (has(const ['shop', 'store', 'market', 'mercado', 'boutique', 'mall'])) {
    return LucideIcons.shopping_bag;
  }

  return LucideIcons.map_pin;
}
