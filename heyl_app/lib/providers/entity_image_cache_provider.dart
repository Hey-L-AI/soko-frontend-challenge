import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/models/entity_ref.dart';

/// In-memory cache mapping `(EntityKind, id)` → `imageUrl`.
///
/// Populated whenever a detail surface resolves a non-null image for an
/// entity (venue / event / list). Shelf cards, Discovery History, and other
/// feeds read it as a fallback when their feed payload's `image_url` is
/// null — typical for cold-cache entities whose enrichment row hadn't
/// warmed yet at feed time.
///
/// Generalises the venue-only fallback shipped with PROD-1521 so events and
/// lists get the same "open Dafu, close, see the photo on the next surface"
/// continuity. The actual image bytes still go through `cached_network_image`'s
/// disk cache — this provider only propagates the URL string.
///
/// In-memory only — clears on app restart. Persisting across sessions would
/// surface stale URLs (Google Photos / CDN URLs rotate).
///
/// **Cleanup window:** once BE PROD-1565 Flow B fully populates `image_url`
/// on every feed payload, this fallback becomes dead code. It is not
/// actively harmful (no second HTTP fetch, no stale data — just unread map
/// reads), so deletion can wait for a follow-up cleanup ticket.
final entityImageCacheProvider =
    StateProvider<Map<EntityKind, Map<String, String>>>(
  (ref) => const {
    EntityKind.venue: {},
    EntityKind.event: {},
    EntityKind.list: {},
  },
);

extension EntityImageCacheRef on Ref {
  String? cachedEntityImage(EntityKind kind, String id) =>
      read(entityImageCacheProvider)[kind]?[id];

  void cacheEntityImage(EntityKind kind, String id, String url) {
    if (url.isEmpty || kind == EntityKind.unknown) return;
    final current = read(entityImageCacheProvider);
    final bucket = current[kind] ?? const {};
    if (bucket[id] == url) return;
    read(entityImageCacheProvider.notifier).state = {
      ...current,
      kind: {...bucket, id: url},
    };
  }
}

extension EntityImageCacheWidgetRef on WidgetRef {
  String? cachedEntityImage(EntityKind kind, String id) =>
      read(entityImageCacheProvider)[kind]?[id];

  void cacheEntityImage(EntityKind kind, String id, String url) {
    if (url.isEmpty || kind == EntityKind.unknown) return;
    final current = read(entityImageCacheProvider);
    final bucket = current[kind] ?? const {};
    if (bucket[id] == url) return;
    read(entityImageCacheProvider.notifier).state = {
      ...current,
      kind: {...bucket, id: url},
    };
  }
}
