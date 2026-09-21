import 'package:dio/dio.dart';

import '../../../core/constants/api_constants.dart';
import '../../models/notification_item.dart';
import '../../models/notification_preferences.dart';
import 'api_client.dart';

/// PROD-2524 T-E — thin wrapper over the inbox endpoints defined in
/// `open-api/heyl-webapp-v1.openapi.yaml` (PROD-2514 T-C). Stateless;
/// the Riverpod notifier in `notifications_provider.dart` owns the
/// in-memory list + unread count, and re-fetches on every screen open
/// per the delivery plan ("fetch fresh on open — no resume-poll dedupe
/// needed").
class NotificationsApi {
  final ApiClient _apiClient;

  NotificationsApi({required ApiClient apiClient}) : _apiClient = apiClient;

  Dio get _dio => _apiClient.dio;

  /// GET /api/v1/app/notifications
  ///
  /// Defaults to the "inbox" view: only unread, non-dismissed rows.
  /// Pass both `includeRead: true` and `includeDismissed: true` for
  /// the "history" view.
  Future<NotificationListPage> list({
    bool includeRead = false,
    bool includeDismissed = false,
    int limit = 50,
    int offset = 0,
  }) async {
    final response = await _dio.get(
      ApiConstants.notifications,
      queryParameters: {
        'include_read': includeRead,
        'include_dismissed': includeDismissed,
        'limit': limit,
        'offset': offset,
      },
    );
    return NotificationListPage.fromJson(response.data as Map<String, dynamic>);
  }

  /// GET /api/v1/app/notifications/unread-count
  Future<int> unreadCount() async {
    final response = await _dio.get(ApiConstants.notificationsUnreadCount);
    final body = response.data as Map<String, dynamic>;
    return (body['count'] as num?)?.toInt() ?? 0;
  }

  /// PATCH /api/v1/app/notifications/{id}/read (idempotent).
  Future<NotificationChangeResult> markRead(String id) async {
    final response = await _dio.patch(ApiConstants.notificationRead(id));
    return NotificationChangeResult.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// POST /api/v1/app/notifications/read-all. Returns affected rowcount.
  Future<int> markAllRead() async {
    final response = await _dio.post(ApiConstants.notificationsReadAll);
    final body = response.data as Map<String, dynamic>;
    return (body['count'] as num?)?.toInt() ?? 0;
  }

  /// POST /api/v1/app/notifications/bundles/{bundle_key}/read (PROD-2781 B3).
  /// Flips every row of one inbox bundle to read in a single round-trip;
  /// idempotent, returns the newly-flipped rowcount.
  Future<int> markBundleRead(String bundleKey) async {
    final response = await _dio.post(
      ApiConstants.notificationBundleRead(bundleKey),
    );
    final body = response.data as Map<String, dynamic>;
    return (body['updated'] as num?)?.toInt() ?? 0;
  }

  /// PATCH /api/v1/app/notifications/{id}/dismiss (idempotent).
  Future<NotificationChangeResult> dismiss(String id) async {
    final response = await _dio.patch(ApiConstants.notificationDismiss(id));
    return NotificationChangeResult.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// GET /api/v1/app/notifications/preferences (PROD-2526 T-L).
  Future<NotificationPreferences> getPreferences() async {
    final response = await _dio.get(ApiConstants.notificationsPreferences);
    return NotificationPreferences.fromJson(
      response.data as Map<String, dynamic>,
    );
  }

  /// PATCH /api/v1/app/notifications/preferences — partial update.
  /// Only the keys present in [changes] are sent; omitted keys are
  /// left untouched server-side.
  ///
  /// Values are typically [bool] for flat category keys (`reminders`,
  /// `async_jobs`, …) but the marketing channels nest under a single
  /// `marketing` key whose value is a `Map<String, bool>` (PROD-2510),
  /// e.g. `{'marketing': {'push': true}}`. The looser map value type
  /// supports both shapes.
  Future<NotificationPreferences> updatePreferences(
    Map<String, dynamic> changes,
  ) async {
    final response = await _dio.patch(
      ApiConstants.notificationsPreferences,
      data: changes,
    );
    return NotificationPreferences.fromJson(
      response.data as Map<String, dynamic>,
    );
  }
}
