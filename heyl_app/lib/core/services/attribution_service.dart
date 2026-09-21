import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:play_install_referrer/play_install_referrer.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../data/datasources/api/attribution_api.dart';
import '../../data/models/attribution_data.dart';
import '../../providers/api_provider.dart';
import '../utils/web_referrer_stub.dart'
    if (dart.library.js_interop) '../utils/web_referrer_web.dart'
    as web_referrer;
import 'install_referrer_attribution.dart';
import 'posthog_service.dart';
import 'storage_service.dart';

/// Storage keys for attribution data
class AttributionStorageKeys {
  AttributionStorageKeys._();

  /// Visitor ID stored in secure storage (survives app reinstall on iOS)
  static const String visitorId = 'heyl_visitor_id';

  /// Current attribution data stored in shared preferences (quick access)
  static const String attributionData = 'heyl_attribution_data';

  /// Whether we've already read the Play Install Referrer for this install
  /// (PROD-2853). Play returns the same value forever, so re-reading on every
  /// launch is wasteful; the flag is only cleared on app-data reset.
  static const String installReferrerConsumed =
      'heyl_install_referrer_consumed';

  /// Whether the install referrer's acquisition attribution has reached
  /// PostHog as `acq_*` person properties (PROD-3478). Independent of
  /// [installReferrerConsumed] so installs that predate PROD-3478 get a
  /// one-time backfill re-read (Play serves the referrer for ~90 days
  /// post-install). Only set AFTER a successful PostHog capture — a silent
  /// no-op (SDK uninitialized) must not permanently lose attribution.
  static const String installReferrerPosthogConsumed =
      'heyl_install_referrer_posthog_consumed';

  /// The raw referrer string exactly as Play returned it. Persisted so the
  /// future backend decryption leg (Meta's encrypted `utm_content`) can ship
  /// it even after Play's 90-day referrer window closes.
  static const String installReferrerRaw = 'heyl_install_referrer_raw';
}

/// Service for managing visitor attribution tracking
///
/// This service:
/// 1. Generates and persists a unique visitor_id before signup
/// 2. Captures UTM parameters and referral data from deep links/URLs
/// 3. Sends touchpoints to the backend API
/// 4. Provides attribution data for registration/login
class AttributionService {
  final FlutterSecureStorage _secureStorage;
  final SharedPreferences _prefs;
  final AttributionApi _attributionApi;

  /// Fetches the Play Install Referrer. Injectable because
  /// [PlayInstallReferrer.installReferrer] is a static getter (same seam
  /// style as `MetaDestination({client})`); tests construct
  /// [ReferrerDetails] fixtures directly via its public constructor.
  final Future<ReferrerDetails> Function() _referrerFetcher;

  /// Platform gate for [readInstallReferrer]. Overridable in tests where
  /// `Platform.isAndroid` is the host platform, not the simulated one.
  final bool Function() _isAndroid;

  /// Supplies the PostHog distinct_id for the touchpoint so backend-derived
  /// acq_* person props (PROD-3480) attach to the correct person. Null fn or
  /// null result → field simply omitted from the payload.
  final Future<String?> Function()? _posthogDistinctIdFetcher;

  /// In-memory cache for visitor ID to avoid repeated storage reads
  String? _cachedVisitorId;

  /// Synchronous access to cached visitor ID (null if not yet initialized)
  String? get cachedVisitorId => _cachedVisitorId;

  AttributionService({
    required FlutterSecureStorage secureStorage,
    required SharedPreferences prefs,
    required AttributionApi attributionApi,
    Future<String?> Function()? posthogDistinctIdFetcher,
    @visibleForTesting Future<ReferrerDetails> Function()? referrerFetcher,
    @visibleForTesting bool Function()? isAndroid,
  }) : _secureStorage = secureStorage,
       _prefs = prefs,
       _attributionApi = attributionApi,
       _posthogDistinctIdFetcher = posthogDistinctIdFetcher,
       _referrerFetcher =
           referrerFetcher ?? (() => PlayInstallReferrer.installReferrer),
       _isAndroid = isAndroid ?? (() => !kIsWeb && Platform.isAndroid);

  /// Get or create a unique visitor ID
  ///
  /// The visitor ID is stored in secure storage:
  /// - iOS: Keychain (survives app reinstall)
  /// - Android: EncryptedSharedPreferences
  /// - Web: IndexedDB via flutter_secure_storage
  Future<String> getVisitorId() async {
    // Return cached value if available
    if (_cachedVisitorId != null) {
      return _cachedVisitorId!;
    }

    try {
      // Check secure storage first
      final existingId = await _secureStorage.read(
        key: AttributionStorageKeys.visitorId,
      );

      if (existingId != null && existingId.isNotEmpty) {
        _cachedVisitorId = existingId;
        return existingId;
      }

      // Generate new UUID
      const uuid = Uuid();
      final newId = uuid.v4();

      // Persist to secure storage
      await _secureStorage.write(
        key: AttributionStorageKeys.visitorId,
        value: newId,
      );

      _cachedVisitorId = newId;
      debugPrint('[AttributionService] Generated new visitor ID: $newId');
      return newId;
    } catch (e) {
      debugPrint('[AttributionService] Error getting visitor ID: $e');
      // Fallback to a session-only ID if storage fails
      const uuid = Uuid();
      final fallbackId = uuid.v4();
      _cachedVisitorId = fallbackId;
      return fallbackId;
    }
  }

  /// Get the current platform identifier
  String getPlatform() {
    if (kIsWeb) {
      return 'webapp';
    }
    if (Platform.isIOS) {
      return 'ios';
    }
    if (Platform.isAndroid) {
      return 'android';
    }
    // Fallback for other platforms (desktop)
    return 'webapp';
  }

  /// Extract attribution parameters from a URI (deep link or landing URL)
  ///
  /// Extracts:
  /// - UTM parameters: utm_source, utm_medium, utm_campaign, utm_content, utm_term
  /// - Referral parameters: ref (Short.io slug), click_id (referral click UUID)
  AttributionData? extractAttributionFromUri(Uri? uri) {
    if (uri == null) return null;

    final params = uri.queryParameters;

    // Check if there are any attribution parameters
    final hasAttribution =
        params['utm_source'] != null ||
        params['utm_medium'] != null ||
        params['utm_campaign'] != null ||
        params['utm_content'] != null ||
        params['utm_term'] != null ||
        params['ref'] != null ||
        params['click_id'] != null;

    if (!hasAttribution) return null;

    // Get visitor ID synchronously from cache (should be initialized at app start)
    final visitorId = _cachedVisitorId ?? '';

    return AttributionData(
      visitorId: visitorId,
      platform: getPlatform(),
      utmSource: params['utm_source'],
      utmMedium: params['utm_medium'],
      utmCampaign: params['utm_campaign'],
      utmContent: params['utm_content'],
      utmTerm: params['utm_term'],
      referralSlug: params['ref'],
      referralClickId: params['click_id'],
      landingUrl: uri.toString(),
      referrerUrl: getReferrerUrl(),
    );
  }

  /// Get document referrer URL (web only, null on native).
  String? getReferrerUrl() {
    return web_referrer.getDocumentReferrer();
  }

  /// Track app open with attribution data
  ///
  /// Call this when:
  /// - App launches with a deep link
  /// - App resumes from background with a new URL
  /// - Web page loads with query params
  Future<void> trackAppOpen(Uri? launchUri) async {
    try {
      // Ensure visitor ID is initialized
      final visitorId = await getVisitorId();

      // Extract attribution from URI
      final extractedData = extractAttributionFromUri(launchUri);

      // If no attribution params, nothing to track
      if (extractedData == null || !extractedData.hasAttributionData) {
        debugPrint('[AttributionService] No attribution data in URI');
        return;
      }

      // Update with current visitor ID (in case it was empty during extraction)
      final attribution = extractedData.copyWith(visitorId: visitorId);

      // Store attribution data for later use during signup
      await _storeAttributionData(attribution);

      // Send touchpoint to backend
      await _sendTouchpoint(attribution);
    } catch (e) {
      debugPrint('[AttributionService] Error tracking app open: $e');
      // Fire-and-forget - don't throw
    }
  }

  /// Send touchpoint to backend API
  Future<void> _sendTouchpoint(AttributionData data) async {
    try {
      final response = await _attributionApi.recordTouchpoint(data);
      debugPrint(
        '[AttributionService] Touchpoint recorded: '
        'id=${response.id}, touch_number=${response.touchNumber}',
      );
    } catch (e) {
      debugPrint('[AttributionService] Failed to record touchpoint: $e');
      // Don't throw - touchpoint tracking is fire-and-forget
    }
  }

  /// Store attribution data for later use during registration/login
  Future<void> _storeAttributionData(AttributionData data) async {
    try {
      final json = jsonEncode(data.toJson());
      await _prefs.setString(AttributionStorageKeys.attributionData, json);
      debugPrint('[AttributionService] Attribution data stored');
    } catch (e) {
      debugPrint('[AttributionService] Error storing attribution data: $e');
    }
  }

  /// Get stored attribution data for use during registration/login
  Future<AttributionData?> getStoredAttribution() async {
    try {
      final json = _prefs.getString(AttributionStorageKeys.attributionData);
      if (json == null) {
        // Return minimal attribution with just visitor ID and platform
        final visitorId = await getVisitorId();
        return AttributionData(visitorId: visitorId, platform: getPlatform());
      }

      final data = jsonDecode(json) as Map<String, dynamic>;
      return AttributionData.fromJson(data);
    } catch (e) {
      debugPrint('[AttributionService] Error loading stored attribution: $e');
      // Return minimal attribution
      final visitorId = await getVisitorId();
      return AttributionData(visitorId: visitorId, platform: getPlatform());
    }
  }

  /// Clear stored attribution data (call after successful signup)
  Future<void> clearStoredAttribution() async {
    try {
      await _prefs.remove(AttributionStorageKeys.attributionData);
      debugPrint('[AttributionService] Attribution data cleared');
    } catch (e) {
      debugPrint('[AttributionService] Error clearing attribution data: $e');
    }
  }

  /// Initialize the service (call on app startup)
  ///
  /// This pre-fetches the visitor ID to ensure it's available synchronously
  /// when extracting attribution from deep links.
  Future<void> initialize() async {
    await getVisitorId();
    debugPrint(
      '[AttributionService] Initialized with visitor ID: $_cachedVisitorId',
    );
  }

  /// `TouchpointRequest.utm_content` cap in the OpenAPI spec. Meta's
  /// encrypted referrer blob far exceeds it (multi-KB) and an over-long
  /// value fails backend validation — silently, because [_sendTouchpoint]
  /// swallows errors. The touchpoint ships a truncated marker; the full
  /// blob stays in [AttributionStorageKeys.installReferrerRaw] for the
  /// backend decryption leg (PROD-3478 follow-up).
  static const int _touchpointUtmContentMaxLength = 255;

  /// Read the Google Play Install Referrer and run its two attribution legs
  /// (PROD-2853 touchpoint + PROD-3478 PostHog acquisition props), each
  /// guarded by its own consumed flag:
  ///
  /// - **Touchpoint leg** ([AttributionStorageKeys.installReferrerConsumed]):
  ///   stores the attribution locally and POSTs a backend touchpoint, once
  ///   per install. Companion to soko-website's `&referrer=` encoding on the
  ///   Play Store URL — the install-referrer is the only channel Google
  ///   preserves UTM tags on across a store install.
  /// - **PostHog leg** ([AttributionStorageKeys.installReferrerPosthogConsumed]):
  ///   returns the parsed [InstallReferrerAttribution] so the caller
  ///   (app.dart `_initAttribution`) can `$set_once` the `acq_*` person
  ///   properties and seed the session UTM holder. The caller MUST call
  ///   [markPosthogAttributionConsumed] only after a successful capture —
  ///   PostHog captures silently no-op when the SDK isn't initialized, and
  ///   flagging on a no-op would permanently lose the install's attribution.
  ///   Runs even when the touchpoint flag is already set, so installs that
  ///   predate PROD-3478 backfill on their first launch of this version
  ///   (Play serves the referrer for ~90 days post-install).
  ///
  /// Returns null when there is nothing for the caller to capture: non-Android
  /// platform, both legs consumed, transient read failure (flags left unset —
  /// next launch retries), or an organic install (attributed-only decision:
  /// organic guests get no person profile; both flags are set because an
  /// empty/organic referrer is a terminal answer, not a transient failure).
  Future<InstallReferrerAttribution?> readInstallReferrer() async {
    if (!_isAndroid()) return null;

    final touchpointConsumed =
        _prefs.getBool(AttributionStorageKeys.installReferrerConsumed) ?? false;
    final posthogConsumed =
        _prefs.getBool(AttributionStorageKeys.installReferrerPosthogConsumed) ??
        false;
    if (touchpointConsumed && posthogConsumed) return null;

    final String referrer;
    try {
      final details = await _referrerFetcher();
      referrer = details.installReferrer ?? '';
    } catch (e) {
      // Play Services missing, plugin timeout, network error. Do NOT mark
      // consumed — a transient failure shouldn't permanently lose
      // attribution for this install; the next launch will retry.
      debugPrint('[AttributionService] Failed to read install referrer: $e');
      return null;
    }

    final parsed = InstallReferrerAttribution.parse(referrer);

    if (referrer.isNotEmpty) {
      await _prefs.setString(
        AttributionStorageKeys.installReferrerRaw,
        referrer,
      );
    }

    if (!parsed.hasAttribution) {
      // Organic install (empty referrer or Play's own organic stamp) —
      // terminal for both legs.
      await _prefs.setBool(
        AttributionStorageKeys.installReferrerConsumed,
        true,
      );
      await _prefs.setBool(
        AttributionStorageKeys.installReferrerPosthogConsumed,
        true,
      );
      debugPrint(
        '[AttributionService] Install referrer organic — no attribution',
      );
      return null;
    }

    if (!touchpointConsumed) {
      await _recordReferrerTouchpoint(parsed);
      await _prefs.setBool(
        AttributionStorageKeys.installReferrerConsumed,
        true,
      );
      debugPrint(
        '[AttributionService] Install referrer captured: '
        'channel=${parsed.acqChannel}',
      );
    }

    // Hand the PostHog leg to the caller only while it's still pending.
    return posthogConsumed ? null : parsed;
  }

  /// Flag the PostHog acquisition leg as done. Call ONLY after the `$set`
  /// capture actually succeeded (see [readInstallReferrer]).
  Future<void> markPosthogAttributionConsumed() async {
    await _prefs.setBool(
      AttributionStorageKeys.installReferrerPosthogConsumed,
      true,
    );
  }

  /// Store + POST the install-referrer touchpoint (PROD-2853 leg).
  /// `landing_url`'s synthetic `install.soko.fyi` host distinguishes
  /// install-referrer touchpoints from launch-URI ones when auditing;
  /// `utm_content` is truncated to the spec cap (see
  /// [_touchpointUtmContentMaxLength]) — Meta blobs otherwise fail backend
  /// validation and the whole touchpoint is silently lost.
  /// `install_referrer_raw` + `posthog_distinct_id` feed the backend
  /// decryption leg (PROD-3480): the server decrypts Meta's encrypted
  /// `utm_content` and `$set_once`s ad-level acq_* props on that distinct_id.
  /// Both fields are ignored by backends that predate PROD-3480 (Pydantic
  /// default tolerates unknown fields), so shipping order doesn't matter.
  Future<void> _recordReferrerTouchpoint(
    InstallReferrerAttribution parsed,
  ) async {
    final visitorId = await getVisitorId();
    final distinctId = await _posthogDistinctIdFetcher?.call();
    // Same synthetic-URI shape PROD-2853 sent (full referrer as the query),
    // capped so a Meta blob doesn't balloon the request. utm_* fields carry
    // the canonical values; landing_url is the audit trail.
    final landingUrl = Uri(
      scheme: 'https',
      host: 'install.soko.fyi',
      path: '/',
      query: parsed.rawReferrer.length <= 1024
          ? parsed.rawReferrer
          : parsed.rawReferrer.substring(0, 1024),
    ).toString();
    final utmContent = parsed.utmContent;
    final attribution = AttributionData(
      visitorId: visitorId,
      platform: getPlatform(),
      utmSource: parsed.utmSource,
      utmMedium: parsed.utmMedium,
      utmCampaign: parsed.utmCampaign,
      utmContent:
          utmContent != null &&
              utmContent.length > _touchpointUtmContentMaxLength
          ? utmContent.substring(0, _touchpointUtmContentMaxLength)
          : utmContent,
      utmTerm: parsed.utmTerm,
      referralSlug: parsed.referralSlug,
      referralClickId: parsed.referralClickId,
      landingUrl: landingUrl,
      referrerUrl: getReferrerUrl(),
      installReferrerRaw: parsed.rawReferrer.length <= 4096
          ? parsed.rawReferrer
          : parsed.rawReferrer.substring(0, 4096),
      posthogDistinctId: distinctId,
    );

    await _storeAttributionData(attribution);
    await _sendTouchpoint(attribution);
  }
}

/// Provider for Attribution API
final attributionApiProvider = Provider<AttributionApi>((ref) {
  final apiClient = ref.watch(apiClientProvider);
  return AttributionApi(apiClient: apiClient);
});

/// Provider for Attribution Service
final attributionServiceProvider = Provider<AttributionService>((ref) {
  final secureStorage = ref.watch(secureStorageProvider);
  final prefs = ref.watch(sharedPreferencesProvider);
  final attributionApi = ref.watch(attributionApiProvider);
  final posthogService = ref.watch(postHogServiceProvider);
  return AttributionService(
    secureStorage: secureStorage,
    prefs: prefs,
    attributionApi: attributionApi,
    posthogDistinctIdFetcher: () => posthogService.getDistinctId(),
  );
});
