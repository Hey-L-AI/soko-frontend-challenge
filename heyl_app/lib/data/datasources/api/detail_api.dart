import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/entity_signal.dart' show SignalEntityType;
import '../../models/social_proof.dart';
import 'api_client.dart';

/// API client for event/venue detail endpoints (social proof data)
class DetailApi {
  final ApiClient _apiClient;

  DetailApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  /// Get event detail with social proof.
  ///
  /// [source] tags the navigation origin (e.g. `discovery`, `list`). The
  /// backend only counts a detail open as a memory interest signal when it came
  /// from a discovery surface — opens from inside a zine/list don't count (only
  /// following the zine or saving an item does). Omit for non-navigation
  /// fetches (social proof, prefetch) so they never count.
  Future<EventDetailResponse2> getEventDetail(
    String eventId, {
    String? source,
  }) async {
    final response = await _dio.get(
      ApiConstants.eventDetail(eventId),
      queryParameters: source != null ? {'source': source} : null,
    );
    return EventDetailResponse2.fromJson(response.data as Map<String, dynamic>);
  }

  /// Get venue detail with social proof and upcoming events.
  ///
  /// See [getEventDetail] for [source] semantics.
  Future<VenueDetailResponse> getVenueDetail(
    String venueId, {
    String? source,
  }) async {
    final response = await _dio.get(
      ApiConstants.venueDetail(venueId),
      queryParameters: source != null ? {'source': source} : null,
    );
    return VenueDetailResponse.fromJson(response.data as Map<String, dynamic>);
  }

  /// List everyone who shared an event, paginated (PROD-3161 / PROD-3162).
  ///
  /// Backs the "and others" popup. Ordered creator-first then most-recent
  /// share; page forward with `offset` from the prior page's `next_offset`
  /// (stop when [EventSharersPage.hasMore] is false). Public — auth optional.
  Future<EventSharersPage> getEventSharedBy(
    String eventId, {
    int limit = 20,
    int offset = 0,
  }) async {
    final response = await _dio.get(
      ApiConstants.eventSharedBy(eventId),
      queryParameters: {'limit': limit, 'offset': offset},
    );
    return EventSharersPage.fromJson(response.data as Map<String, dynamic>);
  }

  /// List everyone who liked an entity, paginated (PROD-3779).
  ///
  /// Backs the "Liked by" row's popup. Ordered follows-first then most recent;
  /// page forward with `offset` from the prior page's `next_offset` (stop when
  /// [LikersPage.hasMore] is false).
  ///
  /// The response is viewer-relative — the backend filters blocks in both
  /// directions and ranks the caller's follows first — so it must not be
  /// cached across users.
  Future<LikersPage> getLikedBy(
    SignalEntityType type,
    String id, {
    int limit = 20,
    int offset = 0,
  }) async {
    final response = await _dio.get(
      type == SignalEntityType.event
          ? ApiConstants.eventLikedBy(id)
          : ApiConstants.venueLikedBy(id),
      queryParameters: {'limit': limit, 'offset': offset},
    );
    return LikersPage.fromJson(response.data as Map<String, dynamic>);
  }

  /// List everyone who liked OR saved an entity, paginated.
  ///
  /// Backs the "… têm interesse" row's popup. Deduped server-side — someone who
  /// both liked and saved comes back as ONE item carrying both flags, which is
  /// why this can't be assembled here from `/liked-by` plus a saver list.
  ///
  /// Ordered follows-first then most recent signal; page forward with `offset`
  /// from the prior page's `next_offset` (stop when [InterestedPage.hasMore] is
  /// false).
  ///
  /// Viewer-relative twice over — blocks are filtered both ways, and a private
  /// account's Saved-list entry only names them to a follower — so the response
  /// must not be cached across users.
  Future<InterestedPage> getInterestedBy(
    SignalEntityType type,
    String id, {
    int limit = 20,
    int offset = 0,
  }) async {
    final response = await _dio.get(
      type == SignalEntityType.event
          ? ApiConstants.eventInterestedBy(id)
          : ApiConstants.venueInterestedBy(id),
      queryParameters: {'limit': limit, 'offset': offset},
    );
    return InterestedPage.fromJson(response.data as Map<String, dynamic>);
  }

  /// List events at a venue with cursor pagination (PROD-1680).
  /// Pass `cursor` from the prior page's `next_cursor`; stop paging when
  /// `has_more` is false.
  Future<VenueEventsPage> listVenueEvents(
    String venueId, {
    int limit = 20,
    String? cursor,
  }) async {
    final response = await _dio.get(
      ApiConstants.venueEvents(venueId),
      queryParameters: {'limit': limit, if (cursor != null) 'cursor': cursor},
    );
    return VenueEventsPage.fromJson(response.data as Map<String, dynamic>);
  }
}
