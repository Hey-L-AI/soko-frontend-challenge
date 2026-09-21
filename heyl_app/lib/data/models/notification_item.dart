// PROD-2524 T-E — DTOs mirroring the `Notifications` schemas in
// `open-api/heyl-webapp-v1.openapi.yaml` (PROD-2514 T-C backend).

/// Canonical inbox categories. Wire values are fixed by the backend's
/// `NotificationPreferencesOut` (`[reminders, async_jobs, chat, social,
/// discovery, feedback]`). Per-type sub-toggles within a category
/// (e.g. `weekly_bundle_ready` / `daily_drop_ready` under `discovery`)
/// live on `NotificationItem.type`, not here.
///
/// [marketing] is a synthetic UI-side value (PROD-2510) that surfaces the
/// nested `marketing.push` opt-in field as a single row in
/// `NotificationCategoriesSection`. It is NOT a top-level wire key —
/// the request body for a marketing toggle is `{marketing: {push: v}}`,
/// not `{marketing: v}` — so `wireName` returns the literal
/// `'marketing'` for analytics purposes only and the provider
/// special-cases the PATCH body. Never sent as a top-level key on the
/// wire and never returned by `fromWire`.
enum NotificationCategory {
  reminders,
  asyncJobs,
  chat,
  social,
  discovery,
  feedback,
  marketing,
  unknown;

  static NotificationCategory fromWire(String? raw) {
    switch (raw) {
      case 'reminders':
        return NotificationCategory.reminders;
      case 'async_jobs':
        return NotificationCategory.asyncJobs;
      case 'chat':
        return NotificationCategory.chat;
      case 'social':
        return NotificationCategory.social;
      case 'discovery':
        return NotificationCategory.discovery;
      case 'feedback':
        return NotificationCategory.feedback;
      default:
        return NotificationCategory.unknown;
    }
  }

  String get wireName {
    switch (this) {
      case NotificationCategory.reminders:
        return 'reminders';
      case NotificationCategory.asyncJobs:
        return 'async_jobs';
      case NotificationCategory.chat:
        return 'chat';
      case NotificationCategory.social:
        return 'social';
      case NotificationCategory.discovery:
        return 'discovery';
      case NotificationCategory.feedback:
        return 'feedback';
      case NotificationCategory.marketing:
        return 'marketing';
      case NotificationCategory.unknown:
        return 'unknown';
    }
  }
}

class NotificationItem {
  final String id;
  final NotificationCategory category;
  final String type;
  final String title;
  final String body;
  final String? routePath;
  final Map<String, dynamic>? data;

  /// Producer-stamped inbox-bundling key (PROD-2510). Rows sharing
  /// `(user, bundleKey)` collapse into one inbox card showing the
  /// latest member's title/body + a count badge; expanding the card
  /// reveals each child with its own per-id route. NULL keeps the row
  /// standalone (legacy rows pre-dating bundling render that way).
  final String? bundleKey;
  final DateTime? readAt;
  final DateTime? dismissedAt;
  final DateTime createdAt;

  const NotificationItem({
    required this.id,
    required this.category,
    required this.type,
    required this.title,
    required this.body,
    required this.routePath,
    required this.data,
    required this.bundleKey,
    required this.readAt,
    required this.dismissedAt,
    required this.createdAt,
  });

  bool get isUnread => readAt == null;
  bool get isDismissed => dismissedAt != null;

  factory NotificationItem.fromJson(Map<String, dynamic> json) {
    return NotificationItem(
      // Defensive nullable cast: a missing `id` (contract drift) would
      // otherwise crash the whole inbox via TypeError. Empty-id rows
      // are harmless in the list and any mutating PATCH against them
      // will surface as a 404 the caller already handles.
      id: json['id'] as String? ?? '',
      category: NotificationCategory.fromWire(json['category'] as String?),
      type: json['type'] as String? ?? 'unknown',
      title: json['title'] as String? ?? '',
      body: json['body'] as String? ?? '',
      routePath: json['route_path'] as String?,
      data: json['data'] is Map<String, dynamic>
          ? json['data'] as Map<String, dynamic>
          : null,
      bundleKey: json['bundle_key'] as String?,
      readAt: _parseTime(json['read_at']),
      dismissedAt: _parseTime(json['dismissed_at']),
      createdAt: _parseTime(json['created_at']) ?? DateTime.now().toUtc(),
    );
  }

  NotificationItem copyWith({
    DateTime? readAt,
    DateTime? dismissedAt,
    bool clearReadAt = false,
    bool clearDismissedAt = false,
  }) {
    return NotificationItem(
      id: id,
      category: category,
      type: type,
      title: title,
      body: body,
      routePath: routePath,
      data: data,
      bundleKey: bundleKey,
      readAt: clearReadAt ? null : (readAt ?? this.readAt),
      dismissedAt: clearDismissedAt ? null : (dismissedAt ?? this.dismissedAt),
      createdAt: createdAt,
    );
  }

  static DateTime? _parseTime(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    return DateTime.tryParse(raw)?.toUtc();
  }
}

/// A group of inbox rows sharing the same `bundleKey` (PROD-2510).
/// Standalone rows (no `bundleKey`) are wrapped in a one-element bundle
/// so the screen can render a uniform list of bundles. The `head` is the
/// most-recent member (what the collapsed card shows); `members` is
/// ordered newest-first.
class NotificationBundle {
  final String key;
  final List<NotificationItem> members;

  const NotificationBundle({required this.key, required this.members});

  NotificationItem get head => members.first;

  /// Newest member's timestamp drives bundle ordering on the inbox.
  DateTime get latestAt => head.createdAt;

  bool get isMulti => members.length > 1;

  /// Builds a list of bundles from a flat item list. Items are
  /// expected to be sorted newest-first (the backend returns them
  /// ordered ``created_at DESC``); we preserve that order within each
  /// bundle. Bundles themselves are sorted by their head's timestamp.
  static List<NotificationBundle> group(List<NotificationItem> items) {
    final groups = <String, List<NotificationItem>>{};
    for (final item in items) {
      // Standalone items get their own one-element group keyed on id,
      // so the rest of the screen can treat everything uniformly.
      final key = (item.bundleKey != null && item.bundleKey!.isNotEmpty)
          ? item.bundleKey!
          : 'singleton:${item.id}';
      groups.putIfAbsent(key, () => []).add(item);
    }
    final bundles = groups.entries
        .map((e) => NotificationBundle(key: e.key, members: e.value))
        .toList();
    bundles.sort((a, b) => b.latestAt.compareTo(a.latestAt));
    return bundles;
  }
}

class NotificationListPage {
  final List<NotificationItem> items;
  final int limit;
  final int offset;

  const NotificationListPage({
    required this.items,
    required this.limit,
    required this.offset,
  });

  factory NotificationListPage.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return NotificationListPage(
      items: rawItems is List
          ? rawItems
                .whereType<Map<String, dynamic>>()
                .map(NotificationItem.fromJson)
                .toList(growable: false)
          : const [],
      limit: (json['limit'] as num?)?.toInt() ?? 50,
      offset: (json['offset'] as num?)?.toInt() ?? 0,
    );
  }
}

/// PATCH /notifications/{id}/read and /dismiss share this `{id, changed}`
/// shape, as does DELETE /event-reminders/{id} (reused later in T-K3).
class NotificationChangeResult {
  final String id;
  final bool changed;

  const NotificationChangeResult({required this.id, required this.changed});

  factory NotificationChangeResult.fromJson(Map<String, dynamic> json) {
    return NotificationChangeResult(
      id: json['id'] as String? ?? '',
      changed: json['changed'] as bool? ?? false,
    );
  }
}
