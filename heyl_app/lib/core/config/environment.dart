import 'package:flutter/foundation.dart'
    show kDebugMode, kIsWeb, visibleForTesting;

import '../constants/api_constants.dart';

/// Environment types for the app
enum Environment { dev, prod }

/// Configuration based on current environment
class EnvironmentConfig {
  EnvironmentConfig._();

  /// Get current environment from compile-time variable
  /// Use: flutter run --dart-define=ENV=prod
  static Environment get current {
    const envString = String.fromEnvironment('ENV', defaultValue: 'dev');
    return envString == 'prod' ? Environment.prod : Environment.dev;
  }

  /// Check if running in development mode
  static bool get isDev => current == Environment.dev;

  /// Check if running in production mode
  static bool get isProd => current == Environment.prod;

  /// Get the API base URL for current environment
  static String get baseUrl => current == Environment.prod
      ? ApiConstants.prodBaseUrl
      : ApiConstants.devBaseUrl;

  /// Analytics environment tag: 'dev' | 'staging' | 'prod' (PROD-3207 §1.1).
  ///
  /// `ENV=prod` alone can't distinguish staging from production —
  /// `render-build.sh` passes it for BOTH Render services (they differ only
  /// by the compiled `API_BASE_URL`). So staging is detected from the base
  /// URL, the same trick Firebase's `_getEnvironment()` has always used.
  /// Keeps the historical PostHog vocabulary (`prod`/`dev`, adding
  /// `staging`) so existing `environment=prod` insight filters stay valid;
  /// Firebase maps this to its own GA4 vocabulary — see
  /// `analytics_service.dart`.
  static String get analyticsEnvironment {
    if (kDebugMode || isDev) return 'dev';
    final url = baseUrl;
    if (url.contains('staging')) return 'staging';
    if (url.contains('localhost') || url.contains('127.0.0.1')) return 'dev';
    return 'prod';
  }

  /// Whether the Klaviyo mobile SDK may boot (PROD-3112).
  ///
  /// Non-production builds must never touch Klaviyo. [klaviyoPublicApiKey] is
  /// a hardcoded default shared by every build, so a dev build logging in as a
  /// real production UUID would link the developer's device to the real
  /// production Klaviyo profile — device push tokens and profile writes land
  /// on it. That is PROD-3104's "Path C": it bypasses PostHog entirely, so the
  /// Events-destination environment filter cannot help. Web is already a no-op
  /// stub via the conditional import in `klaviyo_service.dart`.
  ///
  /// Gated on [analyticsEnvironment] rather than the compile-time `ENV`
  /// define, because `ENV=prod` alone cannot tell staging from production.
  static bool get klaviyoEnabled => klaviyoEnabledFor(
    environment: analyticsEnvironment,
    apiKey: klaviyoPublicApiKey,
  );

  /// Pure form of [klaviyoEnabled], so the `prod` branch is reachable from a
  /// test: [analyticsEnvironment] collapses to `'dev'` under `kDebugMode` and
  /// `flutter test` always runs in debug. Same pattern as
  /// `PushPermissionService.deriveState`.
  ///
  /// Deliberately an allow-list (`== 'prod'`), not a deny-list — an
  /// unrecognised environment fails closed.
  @visibleForTesting
  static bool klaviyoEnabledFor({
    required String environment,
    required String apiKey,
  }) => environment == 'prod' && apiKey.isNotEmpty;

  /// Whether PostHog session replay may record. Production only — dev/local and
  /// staging never upload session recordings (noise + privacy + wasted quota).
  /// Mirrors [klaviyoEnabled]: an allow-list on [analyticsEnvironment] that
  /// fails closed. Gates the NATIVE flag only (`config.sessionReplay`); web
  /// recording is governed separately by `web/index.html`.
  static bool get sessionReplayEnabled =>
      sessionReplayEnabledFor(analyticsEnvironment);

  /// Pure form of [sessionReplayEnabled], so the `prod` branch is reachable
  /// from a test ([analyticsEnvironment] collapses to `'dev'` under
  /// `kDebugMode`, and `flutter test` always runs in debug). Allow-list
  /// (`== 'prod'`), not a deny-list — an unrecognised environment fails closed.
  @visibleForTesting
  static bool sessionReplayEnabledFor(String environment) =>
      environment == 'prod';

  /// Google OAuth server client ID (Web client ID from Google Cloud Console)
  /// This is used as the `serverClientId` for google_sign_in on mobile
  /// so the returned ID token has the correct audience for backend verification.
  /// Use: flutter run --dart-define=GOOGLE_SERVER_CLIENT_ID=xxx.apps.googleusercontent.com
  static const String googleServerClientId = String.fromEnvironment(
    'GOOGLE_SERVER_CLIENT_ID',
    defaultValue:
        '144109223679-qfmv2phs9gugluab8rkv97kmolmh1dcq.apps.googleusercontent.com',
  );

  /// Mapbox access token
  /// Use: flutter run --dart-define=MAPBOX_ACCESS_TOKEN=pk.xxx
  static const String mapboxAccessToken = String.fromEnvironment(
    'MAPBOX_ACCESS_TOKEN',
    defaultValue:
        'pk.eyJ1IjoiZ3JhY2Fqb2FvIiwiYSI6ImNtazVoNnhydjBoeDczZHIyeWU1b3pybGkifQ.1ruqaUXYJSbuM94YLt8I5Q',
  );

  /// Map style URLs - Mapbox styles for all platforms.
  ///
  /// [mapboxActiveStyle] is the style every map surface actually renders.
  /// Point it back at [mapboxLightStyle] to instantly revert to the stock
  /// Mapbox basemap — those stock styles are Mapbox-owned defaults that can
  /// never be deleted, so they are a permanent, always-available fallback
  /// target. (One-line revert; no runtime auto-fallback is wired.)
  static const String mapboxLightStyle = 'mapbox://styles/mapbox/light-v11';
  static const String mapboxDarkStyle = 'mapbox://styles/mapbox/dark-v11';

  /// Custom Soko basemap (designer restyle) — a Mapbox Standard (v3) style
  /// hosted on the `gracajoao` account. Private, but readable by the account's
  /// public token ([mapboxAccessToken]). Re-publishes by the designer flow in
  /// automatically as long as this style ID is unchanged.
  static const String mapboxCustomStyle =
      'mapbox://styles/gracajoao/cmrdnkryt000401r3fx3oa8kv';

  /// The single style all maps render (Option A: one theme-independent style
  /// for both light + dark). Swap to [mapboxLightStyle] to fall back.
  static const String mapboxActiveStyle = mapboxCustomStyle;

  /// PostHog API key (starts with phc_...)
  /// Use: flutter run --dart-define=POSTHOG_API_KEY=phc_xxx
  /// Interview default: disabled. Supply only a separate sandbox project token.
  static const String posthogApiKey = String.fromEnvironment(
    'POSTHOG_API_KEY',
    defaultValue: '',
  );

  /// PostHog host URL
  /// Use: flutter run --dart-define=POSTHOG_HOST=https://us.i.posthog.com
  static const String posthogHost = String.fromEnvironment(
    'POSTHOG_HOST',
    defaultValue: 'https://us.i.posthog.com',
  );

  /// Klaviyo public API key (Site ID / Company ID) for mobile push.
  /// 6-character public identifier — safe to embed in client builds, same
  /// trust class as the Mapbox and PostHog keys above. NOT the Private API
  /// Key (`pk_<siteId>_<hash>`), which must never ship in a client binary.
  /// Use: flutter run --dart-define=KLAVIYO_PUBLIC_API_KEY=XXXXXX
  static const String klaviyoPublicApiKey = String.fromEnvironment(
    'KLAVIYO_PUBLIC_API_KEY',
    defaultValue: '',
  );

  /// Soko's public-user handle. Powers the Discovery "Recomendado" shelf
  /// (PROD-1522), which fetches Soko's public lists via
  /// `GET /api/v1/app/users/by-handle/{handle}/lists/public`. Override per
  /// environment if Soko's handle differs in staging or prod.
  /// Use: flutter run --dart-define=SOKO_HANDLE=soko
  static const String sokoHandle = String.fromEnvironment(
    'SOKO_HANDLE',
    defaultValue: 'soko',
  );

  /// Toggle the Meta App Events SDK on mobile. Defaults to **true in release
  /// builds** (App Store / Play / TestFlight) so shipped binaries emit events
  /// without a manual flag, and **false in debug/profile** so local dev and CI
  /// builds stay inert — no SDK boot against the `REPLACE_WITH_*` placeholder
  /// credentials. Native config (Info.plist on iOS, AndroidManifest on Android)
  /// supplies the actual App ID / Client Token when enabled.
  ///
  /// Override explicitly either way — e.g. to exercise Meta from a debug build
  /// against staging: flutter run --dart-define=META_ENABLED=true
  static const bool metaEnabled = bool.fromEnvironment(
    'META_ENABLED',
    defaultValue: false,
  );

  /// Toggle the TikTok Business SDK on mobile (PROD-2919). Same rules as
  /// [metaEnabled]: on in release, off in debug/profile so local dev doesn't
  /// call TikTok with placeholder credentials.
  /// Use: flutter run --dart-define=TIKTOK_ENABLED=true
  static const bool tiktokEnabled = bool.fromEnvironment(
    'TIKTOK_ENABLED',
    defaultValue: false,
  );

  /// TikTok App ID (a.k.a. `ttAppId`) issued by Business Center — public
  /// per-app identifier, safe to embed. Overridable to point at a test app.
  /// Use: flutter run --dart-define=TIKTOK_TT_APP_ID=xxx
  static const String tiktokTtAppId = String.fromEnvironment(
    'TIKTOK_TT_APP_ID',
    defaultValue: '7659733711974957064',
  );

  /// TikTok `appId` — the platform bundle identifier passed to the SDK.
  /// TikTok's SDK expects this to match the store bundle: `ai.heyl.heyl_app`
  /// on Android, `ai.heyl.heylApp` on iOS. Overridable if the bundle diverges
  /// across build flavours.
  static const String tiktokAppId = String.fromEnvironment(
    'TIKTOK_APP_ID',
    defaultValue: 'ai.heyl.heyl_app',
  );

  /// TikTok access token for the Events API. Write-capable — treat as a
  /// credential. Committed to the repo in `dart_defines/tiktok.json` (private
  /// repo, same posture as Meta's creds in `Release.xcconfig`, PROD-2919) and
  /// loaded at build time via `--dart-define-from-file`. A per-dev override
  /// can live in `dart_defines/*.local.json`, which is gitignored. Rotating
  /// means issuing a new token, not scrubbing git history.
  /// Empty string = no access token wired = SDK inits but events don't leave
  /// the device (Events Manager will still show them via app-side attribution).
  static const String tiktokAccessToken = String.fromEnvironment(
    'TIKTOK_ACCESS_TOKEN',
  );

  /// TikTok Pixel code for the web build. Public identifier — safe to embed.
  /// When empty, the pixel loader in `web/index.html` short-circuits and no
  /// TikTok Pixel network calls are made. Web build uses this at compile time
  /// via a placeholder in `web/index.html`.
  static const String tiktokPixelCode = String.fromEnvironment(
    'TIKTOK_PIXEL_CODE',
  );

  /// Toggle the AppsFlyer SDK on mobile (PROD-3533). Same rules as
  /// [metaEnabled]/[tiktokEnabled]: on in release, off in debug/profile so
  /// local dev doesn't call AppsFlyer with placeholder credentials.
  /// Use: flutter run --dart-define=APPSFLYER_ENABLED=true
  static const bool appsflyerEnabled = bool.fromEnvironment(
    'APPSFLYER_ENABLED',
    defaultValue: false,
  );

  /// AppsFlyer dev key — write-capable, treat as a credential. Loaded at build
  /// time via --dart-define-from-file (dart_defines/appsflyer.json, private
  /// repo — same posture as TikTok's access token). Empty = SDK constructs
  /// inert (no-op), so contributors without the key still build cleanly.
  static const String appsflyerDevKey = String.fromEnvironment(
    'APPSFLYER_DEV_KEY',
  );

  /// iOS App Store numeric ID, required by the AppsFlyer iOS SDK. Public
  /// (it's the App Store ID, visible to anyone), so it ships as an inline
  /// default like the other public identifiers. Verified via Apple's iTunes
  /// lookup: id 6758462678 = "Soko.fyi: Local Discovery", bundle
  /// ai.heyl.heylApp, seller Hey L, Inc. (PROD-3533).
  static const String appsflyerIosAppId = String.fromEnvironment(
    'APPSFLYER_IOS_APP_ID',
    defaultValue: '6758462678',
  );

  /// Branded OneLink domain (PROD-3533, OQ2). Dedicated subdomain — must NOT
  /// collide with the apex soko.fyi or the app-claimed l./share. hosts.
  static const String appsflyerOneLinkDomain = String.fromEnvironment(
    'APPSFLYER_ONELINK_DOMAIN',
    defaultValue: 'go.soko.fyi',
  );

  /// Toggle verbose API request/response logging in dev (the wall of
  /// `[API]` lines). Off by default — drowns out actual app errors.
  /// Bearer token is masked when on, so it's safe to enable in dev
  /// without leaking credentials into Sentry session-replay.
  /// Use: flutter run --dart-define=API_LOGS=true
  static const bool apiLogsEnabled = bool.fromEnvironment(
    'API_LOGS',
    defaultValue: false,
  );

  /// Kill switch for the light/dark theme switcher.
  /// When false, the app is locked to light mode and every user-facing
  /// theme toggle is hidden. Both `ThemeData.light` and `ThemeData.dark`
  /// stay in the codebase so we can flip this back on once dark mode
  /// is polished. Hardcoded on purpose — flipping it requires a build
  /// anyway, so a remote flag would buy nothing.
  static const bool themeSwitchingEnabled = false;

  /// Kill switch for the Discovery History grid (PROD-1521).
  /// When false the grid widget is never instantiated, so
  /// `historyGridProvider` is never watched and `GET /users/me/activity`
  /// is never called. The widget + provider + analytics wiring all stay
  /// in the codebase so the grid can be brought back by flipping this
  /// to `true` (single-line change, then rebuild). See
  /// [`docs/features/discovery.md`](../../../../docs/features/discovery.md)
  /// § "History grid" for the rationale.
  static const bool discoveryHistoryGridEnabled = false;

  /// Removal of guest mode on native (iOS/Android). Web ALWAYS keeps guest
  /// mode ("Continue as guest"); this flag controls native only:
  ///   false = native requires sign-in (the value this ships with since
  ///           2026-07-21): the "Continue as guest" button is hidden and the
  ///           router walls unauthenticated visitors to `/login`. Public item
  ///           share links (`/events/:id`, `/venues/:id`, `/lists/:id`) still
  ///           preview — they ride the anonymous bootstrap token, which is
  ///           left untouched.
  ///   true  = guest mode available on native (pre-2026-07-21 behavior).
  ///
  /// To RE-ADD guest on native (e.g. an App Store reviewer requires it under
  /// Guideline 5.1.1(v)): flip [defaultValue] back to `true`, rebuild,
  /// resubmit. Kept as a compile-time const on purpose (flipping requires a
  /// build anyway), mirroring [discoveryHistoryGridEnabled] — it is a
  /// build+resubmit, NOT an instant remote flip. The `GUEST_MODE_NATIVE`
  /// dart-define exercises the restored state without changing what ships:
  /// `flutter build ios --dart-define=GUEST_MODE_NATIVE=true`.
  static const bool guestModeEnabledOnNative = bool.fromEnvironment(
    'GUEST_MODE_NATIVE',
    defaultValue: false,
  );

  /// Whether guest mode ("Continue as guest" / guest browsing) is available on
  /// this build. Web is unconditional; native is gated by
  /// [guestModeEnabledOnNative]. Read THIS getter — not the raw const — at
  /// call sites so the web/native split stays in one place.
  static bool get guestModeEnabled => kIsWeb || guestModeEnabledOnNative;

  /// PROD-2168 Phase 2 — kill switch for the cross-tab inflight refresh
  /// sync (Web Locks API + BroadcastChannel + storage event fallback).
  ///
  /// When `false` (default) the *cross-tab coordination* never initializes —
  /// no `navigator.locks` calls, no `BroadcastChannel` construction, no
  /// `storage` listeners.
  ///
  /// NOTE: this is NOT byte-for-byte pre-Phase-2 behavior.
  /// `RefreshCoordinator.getRefreshedAccessToken` always routes through
  /// `_doRefreshCrossTab`, and the disabled stub's `withLock` runs the
  /// callback inline — so the atomic `saveRotatedTokens` (`token_generation`
  /// commit marker) and the in-tab pre/post double-check synthesis still run
  /// on every refresh, on all platforms. Only the cross-tab
  /// serialization / notification / cooldown-propagation layer is gated by
  /// this flag.
  ///
  /// Flipped to `true` via a Render env var change AFTER Phase 1 (BE
  /// precedence flip) has a 24-48h clean monitoring read, so any anomaly
  /// during the Phase 1 soak cannot be attributed to Phase 2.
  ///
  /// Use: `flutter build web --dart-define=AUTH_INFLIGHT_SYNC=true`
  static const bool authInflightSyncEnabled = bool.fromEnvironment(
    'AUTH_INFLIGHT_SYNC',
    defaultValue: false,
  );

  /// PROD-3496 — local-dev override for the Map page's v2 search bar +
  /// focused search mode. The shipped gate is the PostHog `map-search-v2`
  /// flag ([ExperimentState.enableMapSearchV2]); this dart-define exists
  /// because PostHog is disabled in local dev (flags always resolve to
  /// their defaults), and the old debug-panel reveal toggle was removed
  /// with the v1 keyword bar (Decision #23).
  ///
  /// Use: `flutter run --dart-define=MAP_SEARCH_V2=true`
  static const bool mapSearchV2Enabled = bool.fromEnvironment(
    'MAP_SEARCH_V2',
    defaultValue: false,
  );

  /// PROD-3656 — local-dev override for the map's pin auto-promotion. The
  /// shipped gate is the PostHog `map-pin-auto-promotion` flag
  /// ([ExperimentState.enableMapPinAutoPromotion]); this dart-define exists
  /// because PostHog is disabled in local dev, so the flag would always
  /// resolve to its (off) default and the behaviour could not be tuned.
  ///
  /// Use: `flutter run --dart-define=MAP_PIN_AUTO_PROMOTION=true`
  static const bool mapPinAutoPromotionEnabled = bool.fromEnvironment(
    'MAP_PIN_AUTO_PROMOTION',
    defaultValue: false,
  );

  /// PROD-3657 — local-dev override for the map's `/map/pins` pool cache
  /// (pre-paint on pan/zoom back over covered ground). The shipped gate is the
  /// PostHog `map-pins-cache` flag ([ExperimentState.enableMapPinsCache]);
  /// same reasoning as [mapPinAutoPromotionEnabled].
  ///
  /// Use: `flutter run --dart-define=MAP_PINS_CACHE=true`
  static const bool mapPinsCacheEnabled = bool.fromEnvironment(
    'MAP_PINS_CACHE',
    defaultValue: false,
  );

  /// Local-dev override for the redesigned map-based location-scope sheet. The
  /// shipped gate is the PostHog `location-scope-sheet` flag (admin-targeted;
  /// [ExperimentState.enableLocationScopeSheet]); this dart-define lets local
  /// dev (PostHog disabled) run the new sheet. `start-dev-server.sh` defaults it
  /// on so developers always see the new sheet.
  ///
  /// Use: `flutter run --dart-define=LOCATION_SCOPE_SHEET=true`
  static const bool locationScopeSheetEnabled = bool.fromEnvironment(
    'LOCATION_SCOPE_SHEET',
    defaultValue: false,
  );

  /// PROD-3950 — force the Daily Drop page's tip slot on locally. The shipped
  /// gate is the PostHog `daily-drop-tip` flag (admin-targeted;
  /// [ExperimentState.enableDailyDropTip]); this dart-define lets local dev
  /// (PostHog disabled) see the slot.
  ///
  /// Use: `flutter run --dart-define=DAILY_DROP_TIP=true`
  static const bool dailyDropTipEnabled = bool.fromEnvironment(
    'DAILY_DROP_TIP',
    defaultValue: false,
  );

  /// PROD-3888 — force the NEW onboarding (chat gate + no Siga) on locally,
  /// without an admin account. The shipped gate is SOLELY the PostHog
  /// `unskippable-onboarding-v1` flag ([ExperimentState.enableNewOnboarding],
  /// targeted at the `is_admin` person property) — there is deliberately NO
  /// `role == admin` fallback in code (see [newOnboardingCohortProvider]). This
  /// dart-define is OR-ed with that flag so local dev (PostHog disabled) can
  /// exercise the new flow without depending on the flag resolving.
  ///
  /// Use: `flutter run --dart-define=NEW_ONBOARDING=true`
  static const bool newOnboardingEnabled = bool.fromEnvironment(
    'NEW_ONBOARDING',
    defaultValue: false,
  );
}
