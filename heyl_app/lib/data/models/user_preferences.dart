class UserPreferences {
  final bool emailMarketingOptIn;
  final DateTime? emailMarketingOptInAt;
  final String? emailMarketingOptInSource;
  final String? emailMarketingOptInBasis;
  final bool smsMarketingOptIn;
  final DateTime? smsMarketingOptInAt;
  final String? smsMarketingOptInSource;
  final bool whatsappMarketingOptIn;
  final DateTime? whatsappMarketingOptInAt;
  final String? whatsappMarketingOptInSource;

  /// PROD-2111 — nullable per OpenAPI. `null` = client never reported a
  /// push state (treat as "unknown"). `true` = verified push token.
  /// `false` = permission denied or token revoked.
  final bool? pnOptin;

  /// Server-stamped timestamp of the latest push-consent write. Mirrors
  /// the other channels' `*_at` pattern so the Siga gate can use a
  /// uniform null check across all channels. Absent from the response
  /// when `X-Client-Platform: web` (push is mobile-only).
  final DateTime? pushNotificationOptInAt;

  /// PROD-2285 — mobile-only location consent. `null` = client never
  /// reported a state. `true` = user opted in. `false` = explicit
  /// decline. Mirrors the `pnOptin` pattern.
  final bool? locationOptIn;
  final DateTime? locationOptInAt;
  final String? locationOptInSource;
  final String? locationOptInPlatform;
  final DateTime? termsAcceptedAt;
  final DateTime? privacyAcceptedAt;

  /// Server-derived Siga gate signal. `true` when any applicable
  /// `*_at` key in the response is present but null — meaning the
  /// channel applies to this user/platform but consent has never been
  /// recorded. The backend strips `*_at` keys for inapplicable
  /// channels (auth-method or platform mismatch), so we don't need
  /// any client-side reachability check here.
  ///
  /// Computed once at parse time from the raw JSON map because Dart
  /// loses the "key present vs key absent" distinction once the value
  /// is hoisted into a nullable field.
  final bool hasUnrecordedConsent;

  /// PROD-2438 — explicit per-channel reachability surfaced by the
  /// backend (mirrors the `*_at` strip rules). Drives the Siga consent
  /// copy and PATCH payload so phone-only users don't see "email" copy
  /// and don't write `email_marketing_opt_in` to an account with no
  /// email channel.
  ///
  /// Default `true` when the `applicability` block (or a specific
  /// channel key inside it) is absent from the response — back-compat
  /// with pre-PROD-2438 backends and a safe degradation (current
  /// "ask all channels" behavior is preserved).
  final bool emailApplicable;
  final bool smsApplicable;
  final bool pushApplicable;
  final bool locationApplicable;

  /// PROD-2525 T-K3 — per-user default reminder offsets in minutes.
  /// `null` (or absent) ⇒ the server falls back to the system default
  /// `[60, 1440]` (1 h + 1 day). `[]` ⇒ the user has explicitly opted
  /// out of auto-seeded reminders. Each value satisfies `1 ≤ x ≤ 40320`.
  final List<int>? defaultReminderOffsetsMinutes;

  const UserPreferences({
    required this.emailMarketingOptIn,
    this.emailMarketingOptInAt,
    this.emailMarketingOptInSource,
    this.emailMarketingOptInBasis,
    required this.smsMarketingOptIn,
    this.smsMarketingOptInAt,
    this.smsMarketingOptInSource,
    required this.whatsappMarketingOptIn,
    this.whatsappMarketingOptInAt,
    this.whatsappMarketingOptInSource,
    this.pnOptin,
    this.pushNotificationOptInAt,
    this.locationOptIn,
    this.locationOptInAt,
    this.locationOptInSource,
    this.locationOptInPlatform,
    this.termsAcceptedAt,
    this.privacyAcceptedAt,
    this.hasUnrecordedConsent = false,
    this.emailApplicable = true,
    this.smsApplicable = true,
    this.pushApplicable = true,
    this.locationApplicable = true,
    this.defaultReminderOffsetsMinutes,
  });

  factory UserPreferences.fromJson(Map<String, dynamic> json) {
    final applicability = json['applicability'] as Map<String, dynamic>?;
    return UserPreferences(
      emailMarketingOptIn: json['email_marketing_opt_in'] as bool? ?? false,
      emailMarketingOptInAt: _parseDate(json['email_marketing_opt_in_at']),
      emailMarketingOptInSource:
          json['email_marketing_opt_in_source'] as String?,
      emailMarketingOptInBasis: json['email_marketing_opt_in_basis'] as String?,
      smsMarketingOptIn: json['sms_marketing_opt_in'] as bool? ?? false,
      smsMarketingOptInAt: _parseDate(json['sms_marketing_opt_in_at']),
      smsMarketingOptInSource: json['sms_marketing_opt_in_source'] as String?,
      whatsappMarketingOptIn:
          json['whatsapp_marketing_opt_in'] as bool? ?? false,
      whatsappMarketingOptInAt: _parseDate(
        json['whatsapp_marketing_opt_in_at'],
      ),
      whatsappMarketingOptInSource:
          json['whatsapp_marketing_opt_in_source'] as String?,
      pnOptin: json['pn_optin'] as bool?,
      pushNotificationOptInAt: _parseDate(json['push_notification_opt_in_at']),
      locationOptIn: json['location_opt_in'] as bool?,
      locationOptInAt: _parseDate(json['location_opt_in_at']),
      locationOptInSource: json['location_opt_in_source'] as String?,
      locationOptInPlatform: json['location_opt_in_platform'] as String?,
      termsAcceptedAt: _parseDate(json['terms_accepted_at']),
      privacyAcceptedAt: _parseDate(json['privacy_accepted_at']),
      hasUnrecordedConsent: _computeHasUnrecordedConsent(json),
      emailApplicable: _applicable(applicability, 'email_marketing'),
      smsApplicable: _applicable(applicability, 'sms_marketing'),
      pushApplicable: _applicable(applicability, 'push_notification'),
      locationApplicable: _applicable(applicability, 'location'),
      defaultReminderOffsetsMinutes: _parseOffsets(
        json['default_reminder_offsets_minutes'],
      ),
    );
  }

  /// Parses the `default_reminder_offsets_minutes` field, preserving the
  /// three-state contract from the OpenAPI spec
  /// (`UserPreferences.default_reminder_offsets_minutes`):
  ///
  /// - JSON `null` (or missing) → returns `null` — "never set". The
  ///   server falls back to the system default `[60, 1440]` at seed time.
  /// - JSON `[]` → returns `[]` — explicit opt-out; backend seeds nothing.
  /// - JSON non-empty array → parsed list. Entries are clamped to the
  ///   spec's `1 ≤ x ≤ 40320` range; anything out-of-range is silently
  ///   dropped (defensive — the backend already enforces this).
  static List<int>? _parseOffsets(Object? raw) {
    if (raw == null) return null;
    if (raw is! List) return null;
    return raw
        .whereType<num>()
        .map((n) => n.toInt())
        .where((v) => v >= 1 && v <= 40320)
        .toList(growable: false);
  }

  static const _gateAtKeys = [
    'email_marketing_opt_in_at',
    'sms_marketing_opt_in_at',
    'push_notification_opt_in_at',
    'location_opt_in_at',
  ];

  static bool _computeHasUnrecordedConsent(Map<String, dynamic> json) {
    for (final key in _gateAtKeys) {
      if (json.containsKey(key) && json[key] == null) return true;
    }
    return false;
  }

  // Missing block, missing key, or non-bool value all default to `true` —
  // back-compat with pre-PROD-2438 backends and a safe failure mode (preserves
  // current "ask all channels" UX rather than silently hiding the toggle).
  static bool _applicable(Map<String, dynamic>? block, String channel) {
    if (block == null) return true;
    final v = block[channel];
    return v is bool ? v : true;
  }

  static DateTime? _parseDate(Object? value) {
    if (value is! String || value.isEmpty) return null;
    return DateTime.tryParse(value);
  }
}

class UpdatePreferencesRequest {
  final bool? emailMarketingOptIn;
  final bool? smsMarketingOptIn;
  final bool? pnOptin;

  /// Klaviyo/APNs/FCM push token for this install. Required by the backend
  /// when `pnOptin=true` (else 422 per PROD-2178); optional when
  /// `pnOptin=false` — include the last-known token on opt-out so the
  /// backend can remove it from the Klaviyo subscription.
  final String? pushNotificationToken;

  /// Platform that produced the token (`ios` | `android`). Required by the
  /// backend when `pnOptin=true` because Klaviyo's bulk-jobs push payload
  /// rejects bare-string tokens — each `subscriptions.push.tokens[]`
  /// element must carry `platform` + `vendor`. Backend derives `vendor`
  /// server-side from this (`ios` → `apns`, `android` → `fcm`). Optional
  /// when `pnOptin=false`.
  final String? pushNotificationPlatform;

  /// PROD-2511 — FCM registration token for the HeyL notifications
  /// pipeline, registered independently of `pushNotificationToken`
  /// (which is Klaviyo's marketing token; raw APNs on iOS). On iOS
  /// Firebase exchanges the APNs token for an FCM token so the backend
  /// can use it with FCM `messaging.send()` — the Klaviyo APNs token
  /// can't. Vendor is fixed to `fcm` server-side; not gated by
  /// `pnOptin` because the token should be registered as soon as
  /// Firebase yields it (opt-in still gates whether we send).
  final String? fcmToken;
  final bool? termsAccepted;
  final bool? privacyAccepted;

  /// PROD-2285 — mobile-only location consent. Web clients must NOT
  /// send this field (leave NULL server-side so a later mobile login
  /// still trips Siga, mirroring how `pn_optin` is handled for web).
  final bool? locationOptIn;
  final String? locationOptInSource;
  final String? locationOptInPlatform;

  /// PROD-2525 T-K3 — per-user default reminder offsets. Three-state
  /// contract (see OpenAPI spec
  /// § `UpdatePreferencesRequest.default_reminder_offsets_minutes`):
  ///
  /// - `null` ⇒ field omitted from the body — no change to server state.
  /// - `[]` ⇒ explicit opt-out; backend stops seeding reminders on save.
  /// - non-empty array ⇒ replaces existing defaults wholesale (no merge),
  ///   stored canonical (sorted, deduped). Up to 8 values, each
  ///   `1 ≤ x ≤ 40320`.
  final List<int>? defaultReminderOffsetsMinutes;

  const UpdatePreferencesRequest({
    this.emailMarketingOptIn,
    this.smsMarketingOptIn,
    this.pnOptin,
    this.pushNotificationToken,
    this.pushNotificationPlatform,
    this.fcmToken,
    this.termsAccepted,
    this.privacyAccepted,
    this.locationOptIn,
    this.locationOptInSource,
    this.locationOptInPlatform,
    this.defaultReminderOffsetsMinutes,
  });

  Map<String, dynamic> toJson() {
    return {
      if (emailMarketingOptIn != null)
        'email_marketing_opt_in': emailMarketingOptIn,
      if (smsMarketingOptIn != null) 'sms_marketing_opt_in': smsMarketingOptIn,
      if (pnOptin != null) 'pn_optin': pnOptin,
      if (pushNotificationToken != null)
        'push_notification_token': pushNotificationToken,
      if (pushNotificationPlatform != null)
        'push_notification_platform': pushNotificationPlatform,
      if (fcmToken != null) 'fcm_token': fcmToken,
      if (termsAccepted != null) 'terms_accepted': termsAccepted,
      if (privacyAccepted != null) 'privacy_accepted': privacyAccepted,
      if (locationOptIn != null) 'location_opt_in': locationOptIn,
      if (locationOptInSource != null)
        'location_opt_in_source': locationOptInSource,
      if (locationOptInPlatform != null)
        'location_opt_in_platform': locationOptInPlatform,
      if (defaultReminderOffsetsMinutes != null)
        'default_reminder_offsets_minutes': defaultReminderOffsetsMinutes,
    };
  }
}
