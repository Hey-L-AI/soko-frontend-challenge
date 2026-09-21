import 'notification_item.dart';

/// PROD-2526 T-L (+ PROD-2510) — per-category opt-in state mirroring
/// `NotificationPreferencesOut` in `open-api/heyl-webapp-v1.openapi.yaml`.
/// All six canonical categories are always present per the spec ("the
/// response always carries all six keys so the client doesn't need to
/// maintain its own canonical list out of band").
///
/// PROD-2510 hierarchical preferences: each category exposes
/// `{enabled, types}` where `types` carries per-notification-type
/// sub-toggles (e.g. `weekly_bundle_ready`, `daily_drop_ready` for
/// `discovery`; later `follow_me`, `liked_by_list` for `social`).
/// `enabled` is the category-wide opt-out; `types[X]` is the resolved
/// state for notification type X (per-type override wins, else
/// inherits from `enabled`).
///
/// PROD-2510 unified the marketing channels under this endpoint too —
/// they ship as a nested `marketing: {email, sms, whatsapp, push}` object
/// with opt-IN semantics (default `false`). Only `marketing.push` is
/// exposed in the per-category list UI; the other channels stay in the
/// legacy Marketing section (email / SMS rows) for now.
class NotificationPreferences {
  final CategoryPreference reminders;
  final CategoryPreference asyncJobs;
  final CategoryPreference chat;
  final CategoryPreference social;
  final CategoryPreference discovery;
  final CategoryPreference feedback;
  final MarketingChannels marketing;

  const NotificationPreferences({
    required this.reminders,
    required this.asyncJobs,
    required this.chat,
    required this.social,
    required this.discovery,
    required this.feedback,
    this.marketing = MarketingChannels.allOff,
  });

  /// Opt-out model for the transactional categories: a category the
  /// user has never toggled defaults to enabled with no per-type
  /// overrides. Mirror that on the client so the initial state of a
  /// fresh user reads as "all on" rather than "all off pending fetch".
  static const allEnabled = NotificationPreferences(
    reminders: CategoryPreference.allEnabled,
    asyncJobs: CategoryPreference.allEnabled,
    chat: CategoryPreference.allEnabled,
    social: CategoryPreference.allEnabled,
    discovery: CategoryPreference.allEnabled,
    feedback: CategoryPreference.allEnabled,
    marketing: MarketingChannels.allOff,
  );

  factory NotificationPreferences.fromJson(Map<String, dynamic> json) {
    return NotificationPreferences(
      reminders: CategoryPreference.fromJson(
        json['reminders'] as Map<String, dynamic>?,
      ),
      asyncJobs: CategoryPreference.fromJson(
        json['async_jobs'] as Map<String, dynamic>?,
      ),
      chat: CategoryPreference.fromJson(json['chat'] as Map<String, dynamic>?),
      social: CategoryPreference.fromJson(
        json['social'] as Map<String, dynamic>?,
      ),
      discovery: CategoryPreference.fromJson(
        json['discovery'] as Map<String, dynamic>?,
      ),
      feedback: CategoryPreference.fromJson(
        json['feedback'] as Map<String, dynamic>?,
      ),
      marketing: MarketingChannels.fromJson(
        json['marketing'] as Map<String, dynamic>?,
      ),
    );
  }

  /// Resolves [category] to its current category-wide bool. Sub-toggle
  /// (per-type) state is exposed via `categoryFor(category).types`.
  /// The synthetic [NotificationCategory.marketing] resolves to
  /// `marketing.push` — the only marketing channel surfaced in the
  /// per-category list UI today.
  bool valueFor(NotificationCategory category) {
    if (category == NotificationCategory.marketing) return marketing.push;
    if (category == NotificationCategory.unknown) return true;
    return categoryFor(category).enabled;
  }

  /// Returns the `CategoryPreference` for [category], or
  /// [CategoryPreference.allEnabled] for the synthetic / unknown
  /// values (which the per-category list UI special-cases).
  CategoryPreference categoryFor(NotificationCategory category) {
    switch (category) {
      case NotificationCategory.reminders:
        return reminders;
      case NotificationCategory.asyncJobs:
        return asyncJobs;
      case NotificationCategory.chat:
        return chat;
      case NotificationCategory.social:
        return social;
      case NotificationCategory.discovery:
        return discovery;
      case NotificationCategory.feedback:
        return feedback;
      case NotificationCategory.marketing:
      case NotificationCategory.unknown:
        return CategoryPreference.allEnabled;
    }
  }

  NotificationPreferences copyWith({
    CategoryPreference? reminders,
    CategoryPreference? asyncJobs,
    CategoryPreference? chat,
    CategoryPreference? social,
    CategoryPreference? discovery,
    CategoryPreference? feedback,
    MarketingChannels? marketing,
  }) {
    return NotificationPreferences(
      reminders: reminders ?? this.reminders,
      asyncJobs: asyncJobs ?? this.asyncJobs,
      chat: chat ?? this.chat,
      social: social ?? this.social,
      discovery: discovery ?? this.discovery,
      feedback: feedback ?? this.feedback,
      marketing: marketing ?? this.marketing,
    );
  }
}

/// PROD-2510 — one transactional category's state. `enabled` is the
/// category-wide opt-out row; `types` carries per-notification-type
/// sub-toggles. A type missing from `types` means the category has no
/// registered notification types under it yet (server's TemplateSpec
/// registry is empty for it).
class CategoryPreference {
  final bool enabled;

  /// Resolved per-type state, keyed by wire `notification_type` (e.g.
  /// `weekly_bundle_ready`, `daily_drop_ready`). Empty when the
  /// category has no registered notification types. Each value is the
  /// resolved enabled state for that type — per-type override row wins
  /// over the category-wide row.
  final Map<String, bool> types;

  const CategoryPreference({required this.enabled, required this.types});

  static const CategoryPreference allEnabled = CategoryPreference(
    enabled: true,
    types: {},
  );

  factory CategoryPreference.fromJson(Map<String, dynamic>? json) {
    if (json == null) return allEnabled;
    final rawTypes = json['types'];
    final types = <String, bool>{};
    if (rawTypes is Map) {
      for (final entry in rawTypes.entries) {
        final key = entry.key;
        final value = entry.value;
        if (key is String && value is bool) {
          types[key] = value;
        }
      }
    }
    return CategoryPreference(
      enabled: json['enabled'] as bool? ?? true,
      types: Map.unmodifiable(types),
    );
  }

  CategoryPreference copyWith({bool? enabled, Map<String, bool>? types}) {
    return CategoryPreference(
      enabled: enabled ?? this.enabled,
      types: types ?? this.types,
    );
  }

  CategoryPreference withType(String type, bool value) {
    final updated = Map<String, bool>.from(types);
    updated[type] = value;
    return copyWith(types: Map.unmodifiable(updated));
  }
}

/// PROD-2510 — per-channel marketing opt-IN state nested under
/// `NotificationPreferencesOut.marketing`. Default `false` for every
/// channel (a channel the user has never toggled is treated as not
/// opted in). Reachability is reported separately on
/// `NotificationPreferencesOut.applicability` (not currently mirrored
/// in this client model — the UI gates the only marketing channel it
/// shows — `push` — on `notificationsAvailable` instead).
class MarketingChannels {
  final bool email;
  final bool sms;
  final bool whatsapp;
  final bool push;

  const MarketingChannels({
    required this.email,
    required this.sms,
    required this.whatsapp,
    required this.push,
  });

  static const allOff = MarketingChannels(
    email: false,
    sms: false,
    whatsapp: false,
    push: false,
  );

  factory MarketingChannels.fromJson(Map<String, dynamic>? json) {
    if (json == null) return allOff;
    return MarketingChannels(
      email: json['email'] as bool? ?? false,
      sms: json['sms'] as bool? ?? false,
      whatsapp: json['whatsapp'] as bool? ?? false,
      push: json['push'] as bool? ?? false,
    );
  }

  MarketingChannels copyWith({
    bool? email,
    bool? sms,
    bool? whatsapp,
    bool? push,
  }) {
    return MarketingChannels(
      email: email ?? this.email,
      sms: sms ?? this.sms,
      whatsapp: whatsapp ?? this.whatsapp,
      push: push ?? this.push,
    );
  }
}
