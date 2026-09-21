import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import '../config/environment.dart';
import '../config/research_invitation.dart';

/// Provider for the PostHog analytics service
final postHogServiceProvider = Provider<PostHogService>((ref) {
  return PostHogService();
});

/// Low-level wrapper around the PostHog Flutter SDK.
///
/// This service handles SDK initialization, event capture, user identity,
/// and feature flag reads. It does NOT decide which events to send —
/// that's [UnifiedAnalyticsService]'s responsibility.
///
/// Uses a static [_initialized] flag because the underlying [Posthog] SDK
/// is a singleton — initialization in main.dart applies globally, and all
/// PostHogService instances (including the one from the Riverpod provider)
/// share the same initialized state.
///
/// Without configuration, captures/flag reads are inert. Identity operations
/// report failure to the unified facade, which isolates that destination and
/// keeps authentication usable. Feature flags still default to control.
class PostHogService {
  /// Static so all instances share the init state (Posthog SDK is a singleton)
  static bool _initialized = false;
  static bool _identified = false;

  /// Cached visitor ID for re-registration after reset() clears super properties.
  /// Static because PostHogService is instantiated in both main.dart and the
  /// Riverpod provider — all instances must share the same cached value.
  static String? _visitorId;

  /// Whether PostHog is enabled (API key is configured)
  bool get isEnabled => EnvironmentConfig.posthogApiKey.isNotEmpty;

  /// Initialize the PostHog SDK.
  ///
  /// Safe to call even if PostHog is not configured — will no-op.
  /// Should be called during app startup (e.g., in main.dart Future.wait).
  Future<void> initialize() async {
    if (_initialized) return;
    if (!isEnabled) {
      debugPrint('[PostHog] Disabled (no API key configured)');
      return;
    }

    try {
      final config = PostHogConfig(EnvironmentConfig.posthogApiKey);
      config.host = EnvironmentConfig.posthogHost;
      config.debug = kDebugMode;
      // PROD-3210 (tracking-spec §Lifecycle): canonical `app_open` (app.dart)
      // is the sole reach denominator. SDK lifecycle autocapture ("Application
      // Opened/Backgrounded/Installed/Updated", native-only) double-counted it
      // — 6,358 users on the SDK event vs 5,250 on app_open. Web $pageview is
      // configured separately in web/index.html and stays on.
      config.captureApplicationLifecycleEvents = false;

      // PROD-3479: session replay, NATIVE iOS/Android ONLY. Defaults to false in
      // posthog_flutter 5.24.2, so without this the SDK never records — which is
      // why `app_open` arrived from the Flutter SDK with almost no accompanying
      // mobile recordings. Requires the `PostHogWidget` wrapper in main.dart to
      // actually capture frames; the flag alone does nothing.
      //
      // PRODUCTION ONLY: gated on [EnvironmentConfig.sessionReplayEnabled] so
      // dev/local and staging never upload recordings (they were noise + a
      // privacy/quota cost). Mirrors the klaviyoEnabled prod-only gate.
      //
      // This does NOT affect web. On web the Dart SDK is a thin wrapper over the
      // same window.posthog instance, and recording there is disabled entirely
      // in the posthog.init(...) snippet in web/index.html (Flutter renders into
      // a WebGL <canvas> that rrweb can't capture, and web is a tiny audience).
      config.sessionReplay = EnvironmentConfig.sessionReplayEnabled;

      // Global masking OFF: 5.24.2 defaults both flags to true, which blanks
      // almost the whole Flutter UI (nearly every pixel is text or an image) —
      // recordings came back effectively black. We want visible native
      // recordings to see real behavior. The SDK only exposes these two
      // all-or-nothing flags, so identity/credential surfaces are instead
      // masked selectively at the widget level with `PostHogMaskWidget`:
      //   - the whole auth funnel (phone/email/OTP) — auth_shell.dart
      //   - the account screen's phone + email rows — account_screen.dart
      //   - the profile photo (edit + crop) — edit_profile_screen.dart,
      //     crop_avatar_screen.dart
      // Chat content and uploaded images elsewhere ARE visible in prod
      // recordings by design; keep that in mind if new PII surfaces are added.
      config.sessionReplayConfig.maskAllTexts = false;
      config.sessionReplayConfig.maskAllImages = false;

      // PROD-3152: ad click-id params (gclid/fbclid/…) are captured by posthog-js
      // and stripped in web/index.html's before_send. Don't re-add a Dart-side
      // filter — on web this SDK is a thin wrapper over the same window.posthog
      // instance (config.beforeSend doesn't run on the web path), and native never
      // captures URL click-ids.
      await Posthog().setup(config);

      // PROD-3207 (tracking-spec §1.1): register `environment` as a SUPER
      // property so SDK-autocaptured events ($pageview, Application lifecycle,
      // $web_vitals…) carry it too — before this ~28% of events/week arrived
      // without it and every unfiltered number was inflated by dev/staging.
      // The per-capture stamp in capture() stays as belt-and-braces.
      await _registerSuperProperties();

      _initialized = true;
      debugPrint(
        '[PostHog] Initialized (host: ${EnvironmentConfig.posthogHost})',
      );
    } catch (e) {
      debugPrint('[PostHog] Initialization failed: $e');
      // Don't rethrow — PostHog failure should never block the app
    }
  }

  /// Identify a user (link anonymous → authenticated).
  ///
  /// Call after successful login/signup. Optionally pass [userProperties]
  /// to set person properties used for feature flag targeting.
  ///
  /// Awaits [identify] + [flush] so person properties reach PostHog's
  /// server before any subsequent [reloadFeatureFlags] call evaluates them.
  Future<void> identify(
    String userId, {
    Map<String, Object>? userProperties,
  }) async {
    if (!_initialized) throw StateError('PostHog identity is not initialized');

    try {
      await Posthog().identify(userId: userId, userProperties: userProperties);
      // The Flutter SDK swallows native PlatformExceptions. Verify the local
      // identity before treating the operation as successful.
      if (await Posthog().getDistinctId() != userId) {
        throw StateError('PostHog identification was not applied');
      }
      await Posthog().flush();
      _identified = true;
      debugPrint('[PostHog] Identified user: $userId (props: $userProperties)');
    } catch (e) {
      debugPrint('[PostHog] identify failed: $e');
      rethrow; // UnifiedAnalyticsService isolates this destination until retry.
    }
  }

  /// Reload feature flags from PostHog after identity change.
  ///
  /// Call after [identify] so flags are re-evaluated for the new user.
  Future<void> reloadFeatureFlags() async {
    if (!_initialized) return;

    try {
      await Posthog().reloadFeatureFlags();
      debugPrint('[PostHog] Feature flags reloaded');
    } catch (e) {
      debugPrint('[PostHog] reloadFeatureFlags failed: $e');
    }
  }

  Future<void> setPersonProperties(Map<String, Object> properties) async {
    if (!_initialized || !_identified || properties.isEmpty) return;

    try {
      await Posthog().capture(eventName: r'$set', userProperties: properties);
      await Posthog().flush();
      debugPrint('[PostHog] Set person properties: $properties');
    } catch (e) {
      debugPrint('[PostHog] setPersonProperties failed: $e');
    }
  }

  /// Register the visitor ID as a super property on all future PostHog events.
  ///
  /// Uses [register] to attach `visitor_id` to every event automatically,
  /// without calling [identify] — this avoids creating person profiles for
  /// guests (preserving `personProfiles: identifiedOnly` billing behavior).
  ///
  /// Call once during app startup, after both PostHog and AttributionService
  /// are initialized.
  Future<void> registerVisitorId(String visitorId) async {
    _visitorId = visitorId;
    if (!_initialized) return;

    try {
      await Posthog().register('visitor_id', visitorId);
      debugPrint('[PostHog] Registered visitor_id super property: $visitorId');
    } catch (e) {
      debugPrint('[PostHog] registerVisitorId failed: $e');
    }
  }

  /// Register every super property we own. Called from [initialize] and
  /// again from [reset], because `Posthog().reset()` clears ALL super
  /// properties — before PROD-3207 only `visitor_id` was re-registered, so
  /// any SDK-autocaptured event after logout arrived without `environment`
  /// until the next cold start.
  Future<void> _registerSuperProperties() async {
    await Posthog().register(
      'environment',
      EnvironmentConfig.analyticsEnvironment,
    );
    if (_visitorId != null) {
      await Posthog().register('visitor_id', _visitorId!);
    }
    if (_entryId != null) {
      await Posthog().register('entry_id', _entryId!);
    }
  }

  static String? _entryId;

  /// `entry_id` of the current `app_entry` (analytics/app_entry.dart). A
  /// super property, so every later event carries it until the next entry
  /// — the join key from any action back to the door it came through.
  /// Re-registered after [reset] like the other super properties.
  Future<void> registerEntryId(String entryId) async {
    _entryId = entryId;
    try {
      await Posthog().register('entry_id', entryId);
    } catch (e) {
      debugPrint('[PostHog] registerEntryId failed: $e');
    }
  }

  /// Reset identity (clear user association).
  ///
  /// Call on logout to disassociate future events from the user.
  /// Re-registers all super properties afterward because [reset] clears
  /// them (see [_registerSuperProperties]).
  Future<void> reset() async {
    if (!_initialized) throw StateError('PostHog identity is not initialized');

    try {
      final previousId = await Posthog().getDistinctId();
      await Posthog().reset();
      final nextId = await Posthog().getDistinctId();
      if (previousId.isEmpty || nextId.isEmpty || nextId == previousId) {
        throw StateError('PostHog reset was not applied');
      }
      _identified = false;
      debugPrint('[PostHog] Reset identity');
      // Awaited: the next event after logout must already carry the super
      // properties (environment, visitor_id, entry_id) — `reset()` cleared
      // them, and `register` is async on every platform.
      await _registerSuperProperties();
    } catch (e) {
      debugPrint('[PostHog] reset failed: $e');
      rethrow; // Never capture the next account under stale SDK identity.
    }
  }

  /// Read the variant and payload together without logging a false exposure.
  Future<ResearchInvitation?> getResearchInvitation() async {
    if (!_initialized || !_identified) return null;
    final flagKey = ResearchInvitation.flagKeyFor(
      EnvironmentConfig.analyticsEnvironment,
    );
    if (flagKey == null) return null;
    try {
      final before = await Posthog().getDistinctId();
      final result = await Posthog().getFeatureFlagResult(
        flagKey,
        sendEvent: false,
      );
      final after = await Posthog().getDistinctId();
      if (!_identified || before != after || result?.enabled != true) {
        return null;
      }
      return ResearchInvitation.parse(
        variant: result!.variant,
        payload: result.payload,
        distinctId: after,
      );
    } catch (e) {
      debugPrint('[PostHog] research invitation unavailable: $e');
      return null;
    }
  }

  /// Read a boolean feature flag value.
  ///
  /// Returns [defaultValue] if PostHog is not initialized or the flag
  /// doesn't exist. This ensures the app always has a safe fallback.
  ///
  /// [key] - Feature flag key (e.g., 'homepage-prompt-carousel')
  /// [defaultValue] - Fallback value if flag can't be read (default: true)
  Future<bool> getFeatureFlag(String key, {bool defaultValue = true}) async {
    if (!_initialized) return defaultValue;

    try {
      final value = await Posthog().getFeatureFlag(key);
      if (value == null) return defaultValue;
      if (value is bool) return value;
      // Handle string values ('true'/'false')
      if (value is String) return value.toLowerCase() == 'true';
      return defaultValue;
    } catch (e) {
      debugPrint('[PostHog] getFeatureFlag($key) failed: $e');
      return defaultValue;
    }
  }

  /// PROD-4433 — the nullable truth behind [getFeatureFlag]: `null` means
  /// **PostHog has no value for this flag**, as distinct from a resolved
  /// `false`.
  ///
  /// [getFeatureFlag] returns `Future<bool>` and maps a missing flag onto the
  /// caller's `defaultValue`, so every consumer reads "no answer" and "answered
  /// false" as the same thing. For a flag gating a button that is the right
  /// trade — it keeps call sites simple and a moment of default costs nothing.
  /// For one that fixes a whole page for a session it is not: a reader assigned
  /// to the treatment arm rendered the control feed, and the analytics said we
  /// knew the flag.
  ///
  /// Deliberately a SEPARATE method rather than a change to [getFeatureFlag]:
  /// every other consumer in the app relies on the collapsing behaviour and
  /// none of them should change here. Reach for this one only where the
  /// difference between "absent" and "false" actually changes a decision.
  ///
  /// Returns `null` when PostHog is uninitialised, when the SDK has no value,
  /// or when the read throws — all three mean the same thing to a caller: **we
  /// do not have an answer.**
  Future<bool?> getFeatureFlagOrNull(String key) async {
    if (!_initialized) return null;
    try {
      final value = await Posthog().getFeatureFlag(key);
      if (value == null) return null;
      if (value is bool) return value;
      if (value is String) {
        final v = value.toLowerCase();
        if (v == 'true') return true;
        if (v == 'false') return false;
      }
      // A multivariate string or an unexpected shape. It IS an answer, but not
      // one this boolean accessor can represent — treat as no answer rather
      // than guessing a direction.
      return null;
    } catch (_) {
      return null;
    }
  }

  /// PROD-4433 — **TEMPORARY diagnostic. Remove with the debug logging.**
  ///
  /// The raw SDK value, unnormalised, so a staging log can show the actual
  /// shape (`true` / `false` / a variant string / `null`) rather than the
  /// boolean projection of it.
  Future<Object?> debugRawFeatureFlag(String key) async {
    if (!_initialized) return null;
    try {
      return await Posthog().getFeatureFlag(key);
    } catch (_) {
      return null;
    }
  }

  /// PROD-4433 — **TEMPORARY.** Raw values for several unrelated flags at once.
  ///
  /// Answers the question a single flag read cannot: **is the SDK holding
  /// nothing, or is this one flag genuinely off?** If `discovery-feed-v2` and
  /// two flags known to be on in staging all come back `null`, the SDK has no
  /// flags — a different failure from the flag evaluating false, and the two
  /// are indistinguishable through [getFeatureFlag].
  ///
  /// The SDK exposes no bulk accessor (only `getFeatureFlag`,
  /// `getFeatureFlagPayload`, `reloadFeatureFlags`), so this probes key by key.
  Future<Map<String, Object?>> debugProbeFlags(List<String> keys) async {
    final out = <String, Object?>{};
    for (final key in keys) {
      out[key] = await debugRawFeatureFlag(key);
    }
    return out;
  }

  /// Set initial attribution properties (UTMs) as PostHog person properties.
  ///
  /// Uses `userPropertiesSetOnce` so these are only set on the person's
  /// first visit — subsequent calls with different values are ignored.
  /// This matches PostHog's `$initial_*` property convention.
  ///
  /// Call when UTM params are extracted from a deep link or landing URL.
  void setInitialAttribution({
    String? utmSource,
    String? utmMedium,
    String? utmCampaign,
    String? utmContent,
    String? utmTerm,
    String? referringDomain,
  }) {
    if (!_initialized) return;

    final setOnceProps = <String, Object>{
      if (utmSource != null) r'$initial_utm_source': utmSource,
      if (utmMedium != null) r'$initial_utm_medium': utmMedium,
      if (utmCampaign != null) r'$initial_utm_campaign': utmCampaign,
      if (utmContent != null) r'$initial_utm_content': utmContent,
      if (utmTerm != null) r'$initial_utm_term': utmTerm,
      if (referringDomain != null)
        r'$initial_referring_domain': referringDomain,
    };

    if (setOnceProps.isEmpty) return;

    try {
      Posthog().capture(
        eventName: r'$set',
        userPropertiesSetOnce: setOnceProps,
      );
      if (kDebugMode) {
        debugPrint('[PostHog] Set initial attribution: $setOnceProps');
      }
    } catch (e) {
      debugPrint('[PostHog] setInitialAttribution failed: $e');
    }
  }

  /// Set install-acquisition person properties (`acq_*`) via `$set_once`
  /// (PROD-3478). Fed from the Play Install Referrer — see
  /// `install_referrer_attribution.dart` for the property set and
  /// `attribution_service.dart` for the consumed-flag contract.
  ///
  /// Unlike [setInitialAttribution] this REPORTS success: the caller must
  /// only mark the referrer's PostHog leg consumed when the capture really
  /// went out — a silent no-op while the SDK is uninitialized would
  /// otherwise permanently lose the install's attribution.
  ///
  /// Mobile-only semantics: on Android/iOS a `$set_once` capture from an
  /// anonymous user creates the person profile and the props survive the
  /// later identify() merge. (On web the same call is dropped by posthog-js
  /// for anonymous users — irrelevant here, the referrer is Android-only.)
  Future<bool> setAcquisitionAttribution(Map<String, Object> acqProps) async {
    if (!_initialized || acqProps.isEmpty) return false;

    try {
      await Posthog().capture(
        eventName: r'$set',
        userPropertiesSetOnce: acqProps,
      );
      await Posthog().flush();
      debugPrint('[PostHog] Set acquisition attribution: $acqProps');
      return true;
    } catch (e) {
      debugPrint('[PostHog] setAcquisitionAttribution failed: $e');
      return false;
    }
  }

  /// The SDK's current distinct_id (anonymous UUID until identify()).
  /// Null when the SDK isn't initialized or the read fails. Used by the
  /// install-attribution touchpoint (PROD-3478) so backend-derived acq_*
  /// person props (PROD-3480) attach to the correct person.
  Future<String?> getDistinctId() async {
    if (!_initialized) return null;

    try {
      return await Posthog().getDistinctId();
    } catch (e) {
      debugPrint('[PostHog] getDistinctId failed: $e');
      return null;
    }
  }

  /// The runtime platform label injected into every event.
  static String get _platform {
    if (kIsWeb) return 'web';
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return 'ios';
      case TargetPlatform.android:
        return 'android';
      default:
        return defaultTargetPlatform.name;
    }
  }

  /// Capture a custom event with optional properties.
  ///
  /// Automatically injects `environment` ('dev' | 'staging' | 'prod'), `platform`
  /// ('web', 'ios', 'android'), and `emitted_from: 'frontend'` into every
  /// event. `emitted_from` is the emitter-attribution property (PROD-3213):
  /// the backend's PostHogDestination stamps `'backend'` on its captures, so
  /// any event can be broken down by emitter. Placed AFTER the spread so a
  /// caller-supplied value can never mislabel a client capture.
  ///
  /// Fire-and-forget — never throws.
  Future<void> capture(String event, {Map<String, Object>? properties}) async {
    if (!_initialized) return;

    try {
      final enriched = <String, Object>{
        'environment': EnvironmentConfig.analyticsEnvironment,
        'platform': _platform,
        ...?properties,
        'emitted_from': 'frontend',
        if (_visitorId != null) 'visitor_id': _visitorId!,
        if (_entryId != null) 'entry_id': _entryId!,
      };
      await Posthog().capture(eventName: event, properties: enriched);
      if (kDebugMode) {
        debugPrint('[PostHog] capture: $event ${properties ?? ''}');
      }
    } catch (e) {
      debugPrint('[PostHog] capture($event) failed: $e');
    }
  }
}
