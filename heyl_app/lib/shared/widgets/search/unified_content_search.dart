// Unified search — the "content" fan-out (events · places · zines · people)
// shared by the surfaces that search Soko's catalogue (onboarding, library and
// the discovery feed). Map/chat has its own two-lane fan-out (catalogue + geo)
// and does NOT use this.
//
// Every category is queried in parallel and independently: one endpoint failing
// (or a query too short for people search) degrades that section to empty rather
// than failing the whole search. The caller supplies per-row `onTap` (routing)
// via the mapper functions, so this file stays free of GoRouter / detail-page
// knowledge.

import 'package:dio/dio.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/app_router.dart' show AppRoutes;
import '../../../data/datasources/api/people_api.dart';
import '../../../data/datasources/api/search_api.dart';
import '../../../data/datasources/interfaces/api_interfaces.dart'
    show IListsApi;
import '../../../data/models/chat_message.dart' show ItemSuggestion;
import '../../../data/models/entity_signal.dart';
import '../../../data/models/social/user_search_item.dart';
import '../../../data/models/user_list.dart';
import '../../../providers/api_provider.dart'
    show listsApiProvider, peopleApiProvider, searchApiProvider;
import 'unified_search_models.dart';

/// People search needs at least 2 characters (backend contract). Below that the
/// people lane is skipped rather than firing a rejected request.
const int kUnifiedPeopleMinQuery = 2;

/// The raw per-category results of a content fan-out, before mapping to rows.
class UnifiedContentResults {
  const UnifiedContentResults({
    this.events = const [],
    this.places = const [],
    this.zines = const [],
    this.people = const [],
  });

  final List<ItemSuggestion> events;
  final List<ItemSuggestion> places;
  final List<UserList> zines;
  final List<UserSearchItem> people;
}

/// Fan out [query] across the requested [categories] in parallel. `locations`
/// is ignored here (map/chat only). Returns whatever each lane produced; a lane
/// that throws or is cancelled contributes an empty list.
Future<UnifiedContentResults> fetchUnifiedContent({
  required SearchApi searchApi,
  required IListsApi listsApi,
  required PeopleApi peopleApi,
  required String query,
  required Set<SokoSearchCategory> categories,
  double? latitude,
  double? longitude,
  int perCategory = 8,
  CancelToken? cancelToken,
}) async {
  List<ItemSuggestion> events = const [];
  List<ItemSuggestion> places = const [];
  List<UserList> zines = const [];
  List<UserSearchItem> people = const [];

  Future<void> guard(Future<void> Function() run) async {
    try {
      await run();
    } catch (_) {
      // Per-lane failure degrades that section to empty; the others still land.
    }
  }

  final futures = <Future<void>>[
    if (categories.contains(SokoSearchCategory.events))
      guard(() async {
        final page = await searchApi.searchEventsPaged(
          query: query,
          latitude: latitude,
          longitude: longitude,
          maxResults: perCategory,
          cancelToken: cancelToken,
        );
        events = page.items;
      }),
    if (categories.contains(SokoSearchCategory.venues))
      guard(() async {
        final page = await searchApi.searchPlacesPaged(
          query: query,
          latitude: latitude,
          longitude: longitude,
          maxResults: perCategory,
          cancelToken: cancelToken,
        );
        places = page.items;
      }),
    if (categories.contains(SokoSearchCategory.zines))
      guard(() async {
        final response = await listsApi.listPublicLists(
          q: query,
          latitude: latitude,
          longitude: longitude,
          locationSource: latitude == null ? null : 'picker',
          limit: perCategory,
          cancelToken: cancelToken,
        );
        zines = response.items;
      }),
    if (categories.contains(SokoSearchCategory.people) &&
        query.length >= kUnifiedPeopleMinQuery)
      guard(() async {
        final response = await peopleApi.search(query, limit: perCategory);
        people = response.items;
      }),
  ];

  await Future.wait(futures);
  return UnifiedContentResults(
    events: events,
    places: places,
    zines: zines,
    people: people,
  );
}

// ---------------------------------------------------------------------------
// Row mappers — one per category. Each computes the title/subtitle/thumbnail
// and (where the entity supports it) the like target; the caller passes the
// per-surface [onTap].
// ---------------------------------------------------------------------------

String? _catNeighbourhoodCity(ItemSuggestion item) {
  final parts = <String>[
    if ((item.category ?? '').isNotEmpty) item.category!,
    if ((item.neighborhood ?? '').isNotEmpty)
      item.neighborhood!
    else if ((item.city ?? '').isNotEmpty)
      item.city!,
  ];
  return parts.isEmpty ? null : parts.join(' · ');
}

UnifiedSearchRow unifiedEventRow(ItemSuggestion item, {VoidCallback? onTap}) {
  final id = item.eventId;
  return UnifiedSearchRow(
    rowKey: 'event_${item.id}',
    title: item.name,
    subtitle: _catNeighbourhoodCity(item),
    imageUrl: item.imageUrl,
    seed: item.id,
    category: SokoSearchCategory.events,
    signalTarget: (id != null && id.isNotEmpty)
        ? (SignalEntityType.event, id)
        : null,
    onTap: onTap,
    payload: item,
  );
}

UnifiedSearchRow unifiedPlaceRow(ItemSuggestion item, {VoidCallback? onTap}) {
  final id = item.venueId;
  return UnifiedSearchRow(
    rowKey: 'venue_${item.id}',
    title: item.name,
    subtitle: _catNeighbourhoodCity(item),
    imageUrl: item.imageUrl,
    seed: item.id,
    category: SokoSearchCategory.venues,
    signalTarget: (id != null && id.isNotEmpty)
        ? (SignalEntityType.venue, id)
        : null,
    onTap: onTap,
    payload: item,
  );
}

UnifiedSearchRow unifiedZineRow(UserList list, {VoidCallback? onTap}) {
  final previews = list.previewImages;
  final cover =
      list.coverImageUrl ??
      ((previews != null && previews.isNotEmpty) ? previews.first : null);
  final handle = list.ownerHandle;
  final subtitle = (handle != null && handle.isNotEmpty)
      ? '@$handle'
      : (list.ownerName ?? '');
  return UnifiedSearchRow(
    rowKey: 'list_${list.id}',
    title: list.name,
    subtitle: subtitle.isEmpty ? null : subtitle,
    imageUrl: cover,
    seed: list.id,
    category: SokoSearchCategory.zines,
    onTap: onTap,
    payload: list,
  );
}

UnifiedSearchRow unifiedPersonRow(UserSearchItem user, {VoidCallback? onTap}) {
  final handle = user.handle;
  final title = (user.fullName != null && user.fullName!.isNotEmpty)
      ? user.fullName!
      : (handle != null && handle.isNotEmpty ? '@$handle' : '');
  final subtitle = (handle != null && handle.isNotEmpty)
      ? '@$handle'
      : (user.city ?? '');
  return UnifiedSearchRow(
    rowKey: 'user_${user.userId}',
    title: title,
    subtitle: subtitle.isEmpty ? null : subtitle,
    imageUrl: user.avatarUrl,
    seed: user.userId,
    category: SokoSearchCategory.people,
    onTap: onTap,
    payload: user,
  );
}

// ---------------------------------------------------------------------------
// Pluggable search source — what makes the shared overlay dynamic.
//
// The overlay chrome + grouped-result rendering ([UnifiedContentResultsView])
// are the same everywhere; only *where the rows come from* changes per surface.
// A source owns the fetch AND the per-row mapping (title/thumb/route), so a new
// context can reuse the whole search UI with entirely different data by dropping
// in its own source. The default [CatalogueUnifiedSearchSource] searches Soko's
// global catalogue; the library ships one scoped to the signed-in user's saved
// items (see `LibraryUnifiedSearchSource`).
// ---------------------------------------------------------------------------

/// Routes a row tap. Handed to each source by the results view so a source can
/// wire `onTap` without importing GoRouter — and so a host (onboarding) still
/// gets first refusal on the tap. Sources build `onTap` as
/// `() => navigate(row, route)`.
typedef UnifiedSearchNavigate =
    void Function(UnifiedSearchRow row, String route, {Object? extra});

/// A backend for the shared unified-search UI. Given a query, returns rows
/// grouped by category. Render order is the view's `categories`, not this map's;
/// a category absent from the map (or mapping to an empty list) shows no
/// section.
abstract class UnifiedContentSearchSource {
  const UnifiedContentSearchSource();

  Future<Map<SokoSearchCategory, List<UnifiedSearchRow>>> fetch({
    required WidgetRef ref,
    required String query,
    required Set<SokoSearchCategory> categories,
    required int perCategory,
    double? latitude,
    double? longitude,
    CancelToken? cancelToken,
    required UnifiedSearchNavigate navigate,
  });
}

/// Build a row via one of the [unifiedEventRow]-family mappers and wire its tap
/// to [route] (null/empty → the row is not tappable).
UnifiedSearchRow bindUnifiedRow(
  UnifiedSearchNavigate navigate,
  UnifiedSearchRow Function({VoidCallback? onTap}) make,
  String? route, {
  Object? extra,
}) {
  final hasRoute = route != null && route.isNotEmpty;
  late final UnifiedSearchRow row;
  row = make(onTap: hasRoute ? () => navigate(row, route, extra: extra) : null);
  return row;
}

/// The default source: Soko's global catalogue via [fetchUnifiedContent].
class CatalogueUnifiedSearchSource extends UnifiedContentSearchSource {
  const CatalogueUnifiedSearchSource();

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
    final raw = await fetchUnifiedContent(
      searchApi: ref.read(searchApiProvider),
      listsApi: ref.read(listsApiProvider),
      peopleApi: ref.read(peopleApiProvider),
      query: query,
      categories: categories,
      latitude: latitude,
      longitude: longitude,
      perCategory: perCategory,
      cancelToken: cancelToken,
    );
    return {
      SokoSearchCategory.events: [
        for (final e in raw.events)
          bindUnifiedRow(
            navigate,
            ({onTap}) => unifiedEventRow(e, onTap: onTap),
            '/events/${e.eventId ?? e.id}',
          ),
      ],
      SokoSearchCategory.venues: [
        for (final p in raw.places)
          bindUnifiedRow(
            navigate,
            ({onTap}) => unifiedPlaceRow(p, onTap: onTap),
            (p.venueId != null && p.venueId!.isNotEmpty)
                ? '/venues/${p.venueId}'
                : null,
          ),
      ],
      SokoSearchCategory.zines: [
        for (final l in raw.zines)
          bindUnifiedRow(
            navigate,
            ({onTap}) => unifiedZineRow(l, onTap: onTap),
            '/lists/${l.urlIdentifier}',
            extra: const {'referrer': '/'},
          ),
      ],
      SokoSearchCategory.people: [
        for (final u in raw.people)
          bindUnifiedRow(
            navigate,
            ({onTap}) => unifiedPersonRow(u, onTap: onTap),
            (u.handle != null && u.handle!.isNotEmpty)
                ? AppRoutes.publicProfilePath(u.handle!)
                : null,
          ),
      ],
    };
  }
}
