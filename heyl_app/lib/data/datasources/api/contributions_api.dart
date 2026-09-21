import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/event_contribution.dart';
import 'api_client.dart';

/// API client for the user event-contribution flow (PROD-2147 backend,
/// PROD-2404 webapp). All endpoints live under `/api/v1/app/contributions/*`.
///
/// Error handling is delegated to the central `ErrorInterceptor` — callers
/// catch `ContentBlockedException` / `ModerationUnavailableException` /
/// `ValidationException` / `ApiException` instead of raw [DioException].
class ContributionsApi {
  final ApiClient _apiClient;

  ContributionsApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  /// Submit a photo for event extraction.
  ///
  /// [bytes] / [filename] / [contentType] are the picked image's body and
  /// MIME — the widget layer converts the picker output (web blob vs native
  /// path) to bytes before calling this. Mirrors the backend contract:
  /// JPEG / PNG / WebP, ≤10 MB enforced server-side (we also pre-check
  /// client-side at the UI layer to avoid the wasted upload).
  ///
  /// [city] is required by the contract (1–120 chars) — the backend uses it
  /// as the authoritative `city` hint for venue resolution when the vision
  /// extractor doesn't return one. [country] is the ISO-3166-1 alpha-2 code
  /// of that city; the pair disambiguates ambiguous city names for the
  /// venue resolver and downstream search-scope filtering.
  ///
  /// [note] is an optional free-text hint (≤500 chars) passed to the vision
  /// agent. [venueId] is an optional pre-resolved venue UUID; when present
  /// the worker pins `EventOccurrence.venue_id` and skips text resolution.
  /// [link] is an optional `https://` URL (≤2048 chars) attached to the
  /// submission — typically a ticket page or the event's official site
  /// (PROD-2430); screened server-side via Google Web Risk.
  ///
  /// Returns the freshly-created [EventContributionOut] with `status='pending'`.
  Future<EventContributionOut> submitContribution({
    required Uint8List bytes,
    required String filename,
    required String contentType,
    required String city,
    required String country,
    String? note,
    String? venueId,
    String? link,
  }) async {
    final formData = FormData.fromMap({
      'file': MultipartFile.fromBytes(
        bytes,
        filename: filename,
        contentType: DioMediaType.parse(contentType),
      ),
      'city': city,
      'country': country,
      if (note != null) 'note': note,
      if (venueId != null) 'venue_id': venueId,
      if (link != null) 'link': link,
    });

    final response = await _dio.post(
      ApiConstants.contributionEvents,
      data: formData,
      options: Options(
        contentType: 'multipart/form-data',
        sendTimeout: ApiConstants.uploadTimeout,
        receiveTimeout: ApiConstants.uploadTimeout,
      ),
    );

    return EventContributionOut.fromJson(response.data as Map<String, dynamic>);
  }

  /// Poll a single contribution by id. Owner-scoped on the backend (403 on
  /// non-owner, 404 on missing).
  Future<EventContributionOut> getContribution(String contributionId) async {
    final response = await _dio.get(
      ApiConstants.contributionEventById(contributionId),
    );
    return EventContributionOut.fromJson(response.data as Map<String, dynamic>);
  }

  /// Cursor-paginated list of the caller's own contributions, newest first.
  Future<PaginatedEventContributionOut> listContributions({
    int? limit,
    String? cursor,
  }) async {
    final qp = <String, dynamic>{
      if (limit != null) 'limit': limit,
      if (cursor != null) 'cursor': cursor,
    };
    final response = await _dio.get(
      ApiConstants.contributionEvents,
      queryParameters: qp.isEmpty ? null : qp,
    );
    return PaginatedEventContributionOut.fromJson(
      response.data as Map<String, dynamic>,
    );
  }
}
