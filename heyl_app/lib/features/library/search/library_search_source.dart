// Library-scoped search source for the shared unified-search overlay.
//
// The overlay chrome + grouped-result rendering are the same everywhere; this
// swaps the *data lane* so that searching from `/library` returns only the
// signed-in user's saved items.
//
// Scope is the overlay's OWN category chips, exactly as on the feed and in
// onboarding — the library's filter bar (Eventos/Sítios/Zines/Pessoas +
// Futuros/Passados/Data + zine membership) is deliberately NOT carried in.
// Searching the library means searching the whole library: the tab you opened
// search from never hides a saved item from the results, and search never
// mutates that tab.

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/app_router.dart' show AppRoutes;
import '../../../data/models/entity_signal.dart';
import '../../../data/models/library_feed.dart';
import '../../../providers/api_provider.dart' show libraryApiProvider;
import '../../../shared/widgets/search/unified_content_search.dart';
import '../../../shared/widgets/search/unified_search_models.dart';

/// `GET /users/me/library` caps at 50 rows. Search asks for the max in one
/// call, then buckets the mixed items into per-type sections (each section
/// still collapses to [kUnifiedSearchCollapsedCount] with a "view other" pop).
const int kLibrarySearchResultLimit = 50;

/// The overlay's category → the `types` value `GET /users/me/library` wants.
///
/// Deliberately not `libraryFeedTypeFor`: that one maps `LibraryCategory`, the
/// filter bar's vocabulary, which search no longer speaks.
/// `locations` is map/chat-only and has no library equivalent → null, which
/// reads as "don't narrow".
LibraryFeedItemType? _libraryTypeFor(SokoSearchCategory c) => switch (c) {
  SokoSearchCategory.events => LibraryFeedItemType.event,
  SokoSearchCategory.venues => LibraryFeedItemType.place,
  SokoSearchCategory.zines => LibraryFeedItemType.zine,
  SokoSearchCategory.people => LibraryFeedItemType.person,
  SokoSearchCategory.locations => null,
};

/// Searches the user's saved library, scoped only by the overlay's chips.
class LibraryUnifiedSearchSource extends UnifiedContentSearchSource {
  const LibraryUnifiedSearchSource();

  @override
  Future<Map<SokoSearchCategory, List<UnifiedSearchRow>>> fetch({
    required WidgetRef ref,
    required String query,
    required Set<SokoSearchCategory> categories,
    required int perCategory,
    double? latitude,
    double? longitude,
    CancelToken? cancelToken,
    required UnifiedSearchNavigate navigate,
  }) async {
    final api = ref.read(libraryApiProvider);
    // A selected chip narrows [categories] to that single lane (the results
    // view's `_wanted`), so one chip ⇒ one `types`; no chip ⇒ every type.
    final out = await api.getLibrary(
      limit: kLibrarySearchResultLimit,
      q: query,
      types: categories.length == 1
          ? _libraryTypeFor(categories.single)?.wire
          : null,
    );

    final events = <UnifiedSearchRow>[];
    final places = <UnifiedSearchRow>[];
    final zines = <UnifiedSearchRow>[];
    final people = <UnifiedSearchRow>[];
    for (final item in out.items) {
      switch (item) {
        case LibraryFeedEvent e:
          events.add(_eventRow(navigate, e));
        case LibraryFeedPlace p:
          places.add(_placeRow(navigate, p));
        case LibraryFeedZine z:
          zines.add(_zineRow(navigate, z));
        case LibraryFeedPerson u:
          people.add(_personRow(navigate, u));
      }
    }
    return {
      SokoSearchCategory.events: events,
      SokoSearchCategory.venues: places,
      SokoSearchCategory.zines: zines,
      SokoSearchCategory.people: people,
    };
  }

  static String? _join(Iterable<String?> parts) {
    final kept = parts.whereType<String>().where((s) => s.isNotEmpty).toList();
    return kept.isEmpty ? null : kept.join(' · ');
  }

  UnifiedSearchRow _eventRow(
    UnifiedSearchNavigate navigate,
    LibraryFeedEvent e,
  ) {
    return bindUnifiedRow(
      navigate,
      ({onTap}) => UnifiedSearchRow(
        rowKey: 'event_${e.id}',
        title: e.title,
        subtitle: _join([e.category, e.venueName]),
        imageUrl: e.imageUrl,
        seed: e.id,
        category: SokoSearchCategory.events,
        signalTarget: (SignalEntityType.event, e.id),
        onTap: onTap,
        payload: e,
      ),
      '/events/${e.id}',
    );
  }

  UnifiedSearchRow _placeRow(
    UnifiedSearchNavigate navigate,
    LibraryFeedPlace p,
  ) {
    return bindUnifiedRow(
      navigate,
      ({onTap}) => UnifiedSearchRow(
        rowKey: 'venue_${p.id}',
        title: p.name,
        subtitle: _join([p.category, p.address ?? p.city]),
        imageUrl: p.imageUrl,
        seed: p.id,
        category: SokoSearchCategory.venues,
        signalTarget: (SignalEntityType.venue, p.id),
        onTap: onTap,
        payload: p,
      ),
      '/venues/${p.id}',
    );
  }

  UnifiedSearchRow _zineRow(UnifiedSearchNavigate navigate, LibraryFeedZine z) {
    final handle = z.owner.handle;
    final cover =
        z.coverImageUrl ??
        (z.previewImages.isNotEmpty ? z.previewImages.first : null);
    final subtitle = handle.isNotEmpty ? '@$handle' : (z.owner.fullName ?? '');
    return bindUnifiedRow(
      navigate,
      ({onTap}) => UnifiedSearchRow(
        rowKey: 'list_${z.id}',
        title: z.name,
        subtitle: subtitle.isEmpty ? null : subtitle,
        imageUrl: cover,
        seed: z.id,
        category: SokoSearchCategory.zines,
        onTap: onTap,
        payload: z,
      ),
      '/lists/${z.id}',
    );
  }

  UnifiedSearchRow _personRow(
    UnifiedSearchNavigate navigate,
    LibraryFeedPerson u,
  ) {
    final handle = u.handle.replaceFirst(RegExp(r'^@'), '');
    final title = u.displayName.isNotEmpty
        ? u.displayName
        : (handle.isNotEmpty ? '@$handle' : '');
    return bindUnifiedRow(
      navigate,
      ({onTap}) => UnifiedSearchRow(
        rowKey: 'user_${u.id}',
        title: title,
        subtitle: handle.isEmpty ? null : '@$handle',
        imageUrl: u.avatarUrl,
        seed: u.id,
        category: SokoSearchCategory.people,
        onTap: onTap,
        payload: u,
      ),
      handle.isEmpty ? null : AppRoutes.publicProfilePath(handle),
    );
  }
}
