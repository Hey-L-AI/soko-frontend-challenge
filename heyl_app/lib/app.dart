import 'dart:async';
import 'dart:io' show Platform;

import 'package:app_links/app_links.dart';
import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import 'core/notifications/fcm_handler_service.dart';
import 'core/notifications/fcm_token_service.dart';
import 'core/notifications/notification_tap_resume.dart';
import 'core/router/app_router.dart';
import 'core/router/short_link_fallback.dart';
import 'core/services/analytics/app_entry.dart';
import 'core/services/analytics/app_entry_providers.dart';
import 'core/router/short_link_resolver.dart';
import 'core/services/attribution_service.dart';
import 'core/services/connectivity_service.dart';
import 'core/utils/deep_link_redaction.dart';
import 'core/services/klaviyo_service.dart';
import 'core/services/push_permission_service.dart';
import 'core/services/posthog_service.dart';
import 'core/services/session_utm_holder.dart';
import 'core/session/user_scoped_state.dart';
import 'core/services/auth_event_service.dart';
import 'core/services/experiment_service.dart';
import 'core/services/referral_service.dart';
import 'core/services/share_intent_service.dart';
import 'core/services/unified_analytics_service.dart';
import 'core/services/token_refresh_service.dart';
import 'core/utils/instagram_url.dart';
import 'features/daily_drop/providers/daily_drop_provider.dart';
import 'core/config/environment.dart';
import 'core/constants/api_constants.dart';
import 'core/services/app_group_bridge.dart';
import 'core/services/storage_service.dart';
import 'data/datasources/api/instagram_share_failure.dart';
import 'data/models/instagram_share.dart';
import 'features/contributions/providers/contribution_polling_provider.dart';
import 'features/instagram_share/instagram_share_open_helpers.dart';
import 'features/guest/providers/guest_quota_provider.dart';
import 'features/library/providers/library_warm.dart';
import 'features/onboarding/providers/location_opt_in_migration.dart';
import 'features/instagram_share/providers/instagram_share_polling_provider.dart';
import 'features/instagram_share/providers/instagram_share_provider.dart';
import 'features/instagram_share/widgets/instagram_share_list_picker_sheet.dart';
import 'features/instagram_share/widgets/instagram_share_review_sheet.dart';
import 'features/notifications/providers/notifications_provider.dart';
import 'features/onboarding_chat/providers/needs_onboarding_provider.dart';
import 'l10n/generated/l10n.dart';
import 'core/theme/app_theme.dart';
import 'core/constants/app_constants.dart';
import 'providers/auth_provider.dart';
import 'providers/detected_country_provider.dart';
import 'providers/session_provider.dart';
import 'providers/lists_provider.dart';
import 'providers/backend_locale_refresh.dart';
import 'providers/locale_provider.dart';
import 'providers/theme_provider.dart';
import 'shared/notifications/heyl_notification.dart';
import 'shared/notifications/notification_host.dart';
import 'shared/notifications/notification_state.dart';
import 'shared/widgets/soko_splash_view.dart';

/// Root app widget for Soko
class SokoApp extends ConsumerStatefulWidget {
  const SokoApp({super.key});

  @override
  ConsumerState<SokoApp> createState() => _SokoAppState();
}

class _SokoAppState extends ConsumerState<SokoApp> with WidgetsBindingObserver {
  late AppLinks _appLinks;
  StreamSubscription<Uri>? _linkSubscription;
  ShareIntentService? _shareIntentService;
  bool _didInitialLocaleSync = false;
  bool _didProcessPendingReferral = false;
  bool _didTriggerCountryDetection = false;
  bool _didTrackAppOpen = false;

  /// Breaks the Android short-link relaunch loop — see short_link_fallback.dart.
  late final ShortLinkFallbackCoordinator _shortLinkFallback =
      ShortLinkFallbackCoordinator(
        trackFailed: (shortUri, errorKind) => unawaited(
          ref
              .read(unifiedAnalyticsProvider)
              .trackShortLinkResolveFailed(
                sourceHost: shortUri.host,
                shortUrl: redactDeepLinkForLogging(shortUri),
                errorKind: errorKind,
              ),
        ),
      );

  /// Track the last processed deep link to avoid re-processing on app resume
  /// This prevents spurious navigation when user switches browser tabs
  Uri? _lastProcessedDeepLink;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Tier 2: arm the cold-start `app_entry` before any door can report in.
    // The deep link / push / share intent all land in post-frame callbacks,
    // inside the tracker's grace window.
    final entryTracker = ref.read(appEntryTrackerProvider)..onBoot();
    if (!kIsWeb) {
      // The FCM cold-start message check only runs once the remote flags
      // have loaded (see the listener below), which can outlast the grace.
      // Hold the cold-start entry until that check has run — or the flags
      // load with the engine off, in which case there is nothing to wait
      // for. The tracker's hard cap bounds both.
      entryTracker.hold(_kPushCheckEntryHold);
      void releaseIfEngineOff() {
        if (!ref.read(experimentServiceProvider).notificationsEngineEnabled) {
          entryTracker.release(_kPushCheckEntryHold);
        }
      }

      if (ref.read(experimentServiceProvider).loaded) {
        releaseIfEngineOff();
      } else {
        // Not `fireImmediately`: Riverpod invokes that synchronously, before
        // `listenManual` returns, so closing the subscription from inside the
        // callback would read an unassigned `late` field.
        ProviderSubscription<bool>? flagsLoadedSub;
        flagsLoadedSub = ref.listenManual<bool>(
          experimentServiceProvider.select((s) => s.loaded),
          (_, loaded) {
            if (!loaded) return;
            releaseIfEngineOff();
            flagsLoadedSub?.close();
            flagsLoadedSub = null;
          },
        );
      }
    }
    _appLinks = AppLinks();
    _initAttribution();
    _initMetaAnalytics();
    _initTikTokAnalytics();
    _initAppsflyerAnalytics();
    _logAttStatusAtLaunch();
    _initDeepLinks();
    _initShareIntentListener();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _syncAppGroupOnStartup();
      _consumeShareInFlightFromAppGroup();
      // PROD-2285 Phase 2 — ATT was previously fired here on cold launch.
      // It now fires from Siga + Location-Ask's `_onContinue` so the user
      // has product context before the system dialog. iOS caches the
      // resolution and the Meta buffer (PROD-2137) covers the deferral.
      // Touch the guest quota provider so its auth-flip listener is wired
      // up before any sign-in can happen. Without this read, the provider
      // is only instantiated on first chat-screen visit, and a user who
      // signs in before opening chat would leave a stale quota on disk.
      ref.read(guestQuotaProvider);

      // Warm the `/library` landing page so its first open paints from cache.
      // Costs one `GET /users/me/library` in the boot burst; buys away the
      // spinner on the tab users reach for most after Home. The listener
      // covers a sign-in later in this session, exactly like the migration
      // below — the startup call early-returns while signed out.
      warmLibraryLanding(ref);
      ref.listenManual<bool>(
        authStateProvider.select((s) => s.isAuthenticated),
        (prev, next) {
          if (next && prev != true) warmLibraryLanding(ref);
        },
      );

      // PROD-2285 Phase 1 — one-time backfill of locationOptIn for
      // users with the legacy SharedPreferences flag set. Idempotent;
      // silent on failure (retries next launch + on auth flip).
      // The startup call covers users who launched already-authed; the
      // listener below covers users who sign in during this session
      // (the startup call early-returns on `!isAuthenticated`).
      // [codex P2]
      // ignore: unawaited_futures
      runLocationOptInMigrationIfNeeded(ref);
      ref.listenManual<bool>(
        authStateProvider.select((s) => s.isAuthenticated),
        (prev, next) {
          if (next && prev != true) {
            // ignore: unawaited_futures
            runLocationOptInMigrationIfNeeded(ref);
          }
        },
      );
      // PROD-2511 — gate the FCM engine init behind the
      // `notifications_engine_enabled` PostHog kill-switch. Wait for flags
      // to load (state.loaded) before deciding. Default of `true` keeps
      // the engine on if PostHog is unreachable. Both services are
      // idempotent, so re-attaching after a mid-session flag flip
      // false→true is safe; the false→true case only matters next
      // launch in practice because the handlers / token services are
      // not designed to be torn down mid-session.
      ref.listenManual<bool>(
        experimentServiceProvider.select(
          (s) => s.loaded && s.notificationsEngineEnabled,
        ),
        (prev, next) {
          if (next && prev != true) {
            // PROD-2523 T-D: register FCM foreground / opened-app /
            // cold-start handlers. Background isolate is registered in
            // `main.dart`. Idempotent.
            // Tier 2: `initialise` runs the cold-start message check; the
            // entry tracker holds the boot entry until it has (or the cap).
            unawaited(
              ref
                  .read(fcmHandlerServiceProvider)
                  .initialise()
                  .whenComplete(
                    () => ref
                        .read(appEntryTrackerProvider)
                        .release(_kPushCheckEntryHold),
                  ),
            );
            // PROD-2511 — register the FCM registration token with the
            // backend so the HeyL notifications pipeline can target this
            // device. Separate from the Klaviyo APNs/marketing token
            // managed by PushPermissionService.
            // ignore: unawaited_futures
            ref.read(fcmTokenServiceProvider).initialise();
          }
        },
        fireImmediately: true,
      );
    });
  }

  /// Read the share-extension's in-flight payload from the App Group and,
  /// if present, kick off the in-app polling banner. The extension persists
  /// `soko.share.in_flight.v1` immediately after `POST /instagram/share` so
  /// the host app can pick up the same shared_post_id whether or not the
  /// extension's polling loop completed.
  ///
  /// Safe to call repeatedly — `startPolling` no-ops on duplicate ids.
  Future<void> _consumeShareInFlightFromAppGroup() async {
    try {
      final raw = await AppGroupBridge.instance.readShareInFlight();
      if (raw == null) return;
      final sharedPostId = raw['sharedPostId'] as String?;
      if (sharedPostId == null || sharedPostId.isEmpty) return;
      final listId = raw['listId'] as String?;
      ref
          .read(instagramSharePollingProvider.notifier)
          .startPolling(sharedPostId, listId: listId);
      // Don't clear the App Group key here — the polling provider's own
      // `_persist` mirrors it into `active_instagram_share`, and the
      // extension itself overwrites this key on its next run. Clearing
      // would risk losing in-flight state if the extension is re-entered.
      debugPrint(
        '[SokoApp] consumed share-in-flight from AppGroup: $sharedPostId',
      );
    } catch (e) {
      debugPrint('[SokoApp] consumeShareInFlightFromAppGroup failed: $e');
    }
  }

  /// One-shot push of auth/locale/lists into the App Group on app launch.
  ///
  /// `StorageService.saveAccessToken` already mirrors to the App Group on every
  /// login/refresh, but a user who was already authenticated when this code
  /// shipped would never have triggered that write — so the iOS Share
  /// Extension would falsely render "Sign in to Soko". Same for locale: the
  /// `LocaleNotifier` constructor runs before the Flutter engine bridge fires,
  /// so its early `writeLocale` call silently no-ops.
  ///
  /// This runs once after the first frame, when the method channel is ready,
  /// and pushes whatever's currently in storage.
  Future<void> _syncAppGroupOnStartup() async {
    try {
      final bridge = AppGroupBridge.instance;
      final storage = ref.read(storageServiceProvider);

      // Always re-write baseUrl on launch — cheap and avoids stale builds
      // that point the extension at the wrong backend.
      await bridge.writeBaseUrl(EnvironmentConfig.baseUrl);

      final token = await storage.getAccessToken();
      final expiresAt = await storage.getTokenExpiresAt();
      if (token != null && token.isNotEmpty) {
        await bridge.writeAuth(token: token, expiresAt: expiresAt);
      }

      final locale = ref.read(localeProvider);
      if (locale != null) {
        final tag = locale.countryCode != null
            ? '${locale.languageCode}-${locale.countryCode}'
            : locale.languageCode;
        await bridge.writeLocale(tag);
      }

      // If we're authenticated but the in-memory lists are empty (the user
      // hasn't opened the Lists tab yet on this install), force-fetch them
      // so the extension's picker isn't empty on a fresh share. The
      // notifier's _persistToStorage hook mirrors the result to the App
      // Group automatically. Cheap when the cache is warm — short-circuits
      // immediately. We don't await failures: an offline launch shouldn't
      // delay the rest of the sync.
      //
      // ⚠️ This fetch is NOT iOS-only, and that is load-bearing. Every
      // `AppGroupBridge` call above no-ops off iOS, but `loadLists()` runs on
      // web and Android too — and there it still warms `listsProvider`, which
      // the save drawer paints from optimistically on open
      // (`add_to_list_sheet.dart` → `_armAutoListsOptimistically`).
      // `loadLists()` never short-circuits; it branches on whether state is
      // already warm (`isLoading` when cold vs `isRefreshingScope` when warm),
      // so a cold provider puts that drawer behind a spinner. Wrapping this in
      // a `Platform.isIOS` guard to save a boot request would silently
      // regress the drawer on two of three platforms.
      final hasToken = token != null && token.isNotEmpty;
      var lists = ref.read(listsProvider).lists;
      if (hasToken && lists.isEmpty) {
        try {
          await ref.read(listsProvider.notifier).loadLists();
        } catch (e) {
          debugPrint('[SokoApp] AppGroup startup sync: loadLists failed: $e');
        }
        lists = ref.read(listsProvider).lists;
      }
      if (lists.isNotEmpty) {
        await bridge.writeLists(
          lists
              .map(
                (l) => AppGroupListSnapshot(
                  id: l.id,
                  name: l.name,
                  isSystemManaged: l.isSystemManaged,
                ),
              )
              .toList(),
        );
      }

      debugPrint(
        '[SokoApp] AppGroup startup sync: token=${hasToken ? "yes" : "no"}, '
        'lists=${lists.length}, locale=$locale',
      );
    } catch (e) {
      debugPrint('[SokoApp] AppGroup startup sync failed: $e');
    }
  }

  /// Initialize attribution service (generates visitor ID) and register
  /// the visitor ID as a PostHog super property for guest identity tracking.
  void _initAttribution() {
    try {
      final attributionService = ref.read(attributionServiceProvider);
      final posthogService = ref.read(postHogServiceProvider);

      // Initialize attribution (generates/loads visitor ID), then register
      // visitor_id as a PostHog super property so every event carries it.
      // This enables query-time guest deduplication without calling identify()
      // (which would create billable person profiles for guests).
      attributionService.initialize().then((_) {
        final visitorId = attributionService.cachedVisitorId;
        if (visitorId != null) {
          posthogService.registerVisitorId(visitorId);
        }
        // PROD-2853: read the Play Install Referrer on Android so a
        // UTM-tagged QR scan → Play Store install → app launch keeps its
        // attribution. Guarded by per-leg "consumed" flags and a
        // Platform.isAndroid check inside the service. No-op on web / iOS.
        // Fire-and-forget — attribution failure must never block app boot.
        //
        // PROD-3478: when the referrer carries real attribution (Meta ad,
        // UTM campaign, referral — never organic), the returned parse
        // additionally (a) seeds the session UTM holder so sign_up/login
        // events get event-level UTMs, and (b) lands `acq_*` person
        // properties via $set_once so the install is attributable even if
        // the guest never authenticates. The consumed flag is only written
        // after the capture reports success — setAcquisitionAttribution
        // no-ops (false) while the PostHog SDK is uninitialized.
        attributionService.readInstallReferrer().then((parsed) async {
          if (parsed == null) return;
          final utm = parsed.sessionUtm;
          ref
              .read(sessionUtmHolderProvider)
              .setUtm(
                utmSource: utm.source,
                utmMedium: utm.medium,
                utmCampaign: utm.campaign,
                utmContent: utm.content,
                utmTerm: utm.term,
              );
          final captured = await posthogService.setAcquisitionAttribution(
            parsed.acqProps,
          );
          if (captured) {
            await attributionService.markPosthogAttributionConsumed();
          }
        });
      });
    } catch (e) {
      debugPrint('[SokoApp] Failed to initialize attribution: $e');
    }
  }

  /// PROD-2263: log the iOS App Tracking Transparency status at app
  /// launch, unconditional on auth or route, so a build under App Review
  /// produces evidence in device logs even if the reviewer never reaches
  /// the screen that triggers the prompt. Apple's reviewer can then be
  /// shown the same log entry via the submission notes.
  ///
  /// Reads:
  ///   - `notDetermined` → prompt will be shown on first auth-transition.
  ///   - `restricted` → device-level "Allow Apps to Request to Track" is
  ///     OFF (iOS Settings > Privacy & Security > Tracking). The system
  ///     prompt cannot be shown. Common cause of "I never saw the prompt".
  ///   - `denied` / `authorized` → already determined on this install.
  ///
  /// No-op on Android / web.
  void _logAttStatusAtLaunch() {
    if (kIsWeb || !Platform.isIOS) return;
    // Run async so we don't block initState. Errors are swallowed because
    // missing native side here only means we lost telemetry — not a
    // user-visible failure.
    unawaited(() async {
      try {
        final status =
            await AppTrackingTransparency.trackingAuthorizationStatus;
        debugPrint('[SokoApp] ATT status at launch: $status');
      } catch (e) {
        debugPrint('[SokoApp] ATT status at launch read failed: $e');
      }
    }());
  }

  /// Boot the Meta App Events SDK if META_ENABLED is on. No-ops otherwise.
  /// On Android, this immediately fires activate_app so guest/pre-signup
  /// attribution survives. On iOS, activate_app is deferred until the
  /// cold-launch ATT trigger calls requestTrackingAuthorizationIfNeeded().
  void _initMetaAnalytics() {
    try {
      ref.read(metaAnalyticsServiceProvider).init();
    } catch (e) {
      debugPrint('[SokoApp] Failed to initialize Meta analytics: $e');
    }
  }

  /// Boot the TikTok Business SDK if TIKTOK_ENABLED is on and creds are
  /// present (PROD-2919). Android boots the SDK immediately; iOS defers
  /// to the ATT trigger, same as Meta.
  void _initTikTokAnalytics() {
    try {
      ref.read(tiktokAnalyticsServiceProvider).init();
    } catch (e) {
      debugPrint('[SokoApp] Failed to initialize TikTok analytics: $e');
    }
  }

  /// Boot the AppsFlyer SDK if APPSFLYER_ENABLED is on and creds are present
  /// (PROD-3533). No-ops on web / when the destination provider decided
  /// credentials are absent (`appsflyerAnalyticsServiceProvider` is null).
  void _initAppsflyerAnalytics() {
    try {
      final appsflyer = ref.read(appsflyerAnalyticsServiceProvider);
      if (appsflyer != null) {
        // fire-and-forget, but catch async errors so init() failures can't
        // surface as unhandled zone errors.
        unawaited(
          appsflyer
              .init(onDeepLink: _handleAppsflyerDeepLink)
              .catchError(
                (Object e) => debugPrint('[appsflyer] init failed: $e'),
              ),
        );
      }
    } catch (e) {
      debugPrint('[SokoApp] Failed to initialize AppsFlyer analytics: $e');
    }
  }

  /// Initialize the share intent listener for receiving Instagram URLs
  /// from the native share sheet (iOS/Android).
  ///
  /// Android (PROD-2725): when the user has at least one user-created list,
  /// shows a picker first so they can choose a target list (or "Save
  /// without a list"). Dismissing the picker (back gesture / scrim tap)
  /// cancels the submit entirely. iOS keeps today's no-picker behaviour —
  /// the iOS Share Extension owns the iOS picker UI, and this callback
  /// only fires when someone shares to the Flutter app directly (rare).
  void _initShareIntentListener() {
    final service = ref.read(shareIntentServiceProvider);
    _shareIntentService = service;
    service.onInstagramUrl = (String url, InstagramUrlType type) async {
      // Tier 2: Android native share → `share_intake` entry door.
      ref.read(appEntryTrackerProvider).noteShareIntake();
      if (!InstagramUrl.isSupported(type)) return;
      debugPrint(
        '[ShareIntent] Instagram URL received: $url (type: ${type.name})',
      );

      String? selectedListId;
      // Only Android routes through the picker — iOS has the Share
      // Extension and won't hit this callback in the common case.
      if (!kIsWeb && Platform.isAndroid) {
        // listsProvider is lazy; the share intent can fire before the
        // user has visited the Lists hub. Make sure the picker has
        // something to render before deciding whether to skip the sheet.
        await ref.read(listsProvider.notifier).loadLists();
        if (!mounted) return;
        final userLists = ref
            .read(listsProvider)
            .lists
            .where((l) => !l.isSystemManaged)
            .toList();
        if (userLists.isNotEmpty) {
          // Resolve the root-navigator context so the sheet can mount
          // even though the share intent may fire before any route is
          // focused. Mirrors `notification_host.dart:160-167`.
          final navCtx = ref
              .read(appRouterProvider)
              .routerDelegate
              .navigatorKey
              .currentContext;
          if (navCtx != null) {
            ref
                .read(unifiedAnalyticsProvider)
                .trackInstagramShareOpen(source: 'native_share');
            // `navCtx` is the root navigator key's context — it stays
            // attached for the whole app session, and the outer `mounted`
            // check above already guards against teardown. The linter
            // doesn't model the navigator-key invariant, so suppress on
            // the `context: navCtx` line below.
            final pickerResult = await showInstagramShareListPickerSheet(
              // ignore: use_build_context_synchronously
              context: navCtx,
            );
            if (!mounted) return;
            if (pickerResult == null) {
              ref
                  .read(unifiedAnalyticsProvider)
                  .trackInstagramShareDismissed(
                    source: 'native_share',
                    urlType: type.name,
                  );
              return;
            }
            selectedListId = pickerResult.listId;
          }
        }
      }

      // The OS share-sheet pick is the user's click — track it as a submit
      // (no separate sheet/button is shown for this path on iOS; on
      // Android the user just confirmed via the picker above).
      ref
          .read(unifiedAnalyticsProvider)
          .trackInstagramLinkSubmitted(
            source: 'native_share',
            urlType: type.name,
            listId: selectedListId,
          );
      final result = await ref
          .read(instagramShareProvider.notifier)
          .submit(url, listId: selectedListId);
      if (!mounted) return;
      final l10n = lookupLt(ref.read(localeProvider) ?? const Locale('en'));
      if (result == null) {
        final error = ref.read(instagramShareProvider).error;
        final errorMessage = switch (error) {
          InstagramShareInvalidUrl() when type == InstagramUrlType.reel =>
            l10n.instagramShareErrorReelNotSupported,
          InstagramShareInvalidUrl() => l10n.instagramShareErrorInvalidUrl,
          InstagramShareRateLimited() => l10n.instagramShareErrorRateLimit,
          InstagramShareNetworkError() => l10n.instagramShareErrorNetwork,
          InstagramShareWaitForPrevious() => l10n.instagramShareWaitForPrevious,
          InstagramShareUnknown() || null => l10n.instagramShareErrorGeneric,
        };
        showSoko(ref, message: errorMessage, variant: SokoVariant.error);
        return;
      }
      final message = result.status == 'already_pending'
          ? l10n.instagramShareAlreadyPending
          : result.status == 'already_connected'
          ? l10n.instagramShareAlreadyConnected
          : result.isProfile
          ? l10n.instagramShareSuccessProfile
          : l10n.instagramShareSuccessPost;
      showSoko(ref, message: message, variant: SokoVariant.success);
      ref
          .read(instagramSharePollingProvider.notifier)
          .startPollingForResult(result, listId: selectedListId);
      // Surface the processing banner immediately by routing to the library —
      // the banner host is global, so it shows
      // processing → "Found N events" with Review/Ver CTAs there.
      ref.read(appRouterProvider).go(AppRoutes.library);
    };
    service.init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _linkSubscription?.cancel();
    _shareIntentService?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Tier 2: `app_entry` on every real foregrounding. `paused`/`hidden` mark
    // the background start; `inactive` alone (notification shade, system
    // dialog) never left the foreground and is ignored by the tracker.
    final entryTracker = ref.read(appEntryTrackerProvider);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden) {
      entryTracker.onBackground();
    }
    if (state == AppLifecycleState.resumed) {
      entryTracker.onResume();
      // When app resumes from background, check for any pending deep links
      // This catches OAuth callbacks that might have been missed by the stream
      _checkForPendingDeepLink();
      // Also check the App Group for an in-flight share kicked off from the
      // iOS Share Extension. If the user backgrounded the extension UI and
      // opened Soko directly (without tapping "Ver na app"), this is what
      // surfaces the in-app processing banner.
      _consumeShareInFlightFromAppGroup();
      // Re-check push permission state — user may have toggled
      // notifications in Settings while we were backgrounded.
      ref.read(pushPermissionServiceProvider.notifier).refresh();
      // Re-present the OS notification dialog for eligible users who returned
      // without push (dropped out of onboarding, or the prompt never presented
      // due to the iOS out-of-process race). No-op unless the OS is
      // `notDetermined` and the Siga gate is clear; self-limiting once the
      // dialog is answered. Firing on resume also guarantees foreground-active.
      // ignore: unawaited_futures
      ref.read(pushPermissionServiceProvider.notifier).maybeRepromptOnReturn();
      // Re-poll connectivity. The platform onConnectivityChanged channel does
      // not deliver events while paused, so a "back online" transition during
      // background is lost and the offline banner stays stuck until restart.
      ref.read(connectivityServiceProvider).refresh();
      // Re-sync the inbox-badge unread count — background pushes the
      // user did not tap won't have hit the foreground refresh path.
      // ignore: unawaited_futures
      ref.read(notificationsUnreadCountProvider.notifier).refresh();
      // PROD-3730 — recover a Daily Drop generation the user backgrounded.
      // `BackoffPoller` is a plain Dart `Timer`: iOS suspends the VM and
      // Android freezes cached processes, so the poller can come back dead
      // with the card stuck on "picking your drop" forever — or fire late and
      // false-timeout on stale wall-clock. No-ops unless we're mid-wait, and
      // it is GET-only so it never re-enqueues generation.
      // ignore: unawaited_futures
      ref.read(dailyDropProvider.notifier).refreshAfterResume();
    }
  }

  @override
  void didHaveMemoryPressure() {
    super.didHaveMemoryPressure();
    // Clear image cache when iOS signals low memory
    // This helps prevent crashes due to memory exhaustion (PROD-595)
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
    debugPrint('[Memory] Cleared image cache due to memory pressure');
  }

  /// Check for pending deep links when app resumes
  /// This is needed because uriLinkStream may miss events when app is paused
  Future<void> _checkForPendingDeepLink() async {
    try {
      final latestLink = await _appLinks.getLatestLink();
      if (latestLink != null) {
        // Share-extension links are user-initiated each time the user taps
        // "Ver na app" — even when re-sharing the same Instagram post they
        // produce the same URL, and we MUST run the handler again (the
        // handler clears the App Group blob so a stale repeat is harmless).
        // Bypass dedupe for this scheme.
        final isShareResult =
            latestLink.scheme.toLowerCase() == 'sharemedia-ai.heyl.heylapp' &&
            latestLink.host.toLowerCase() == 'share-result';

        // Skip if this is the same link we already processed
        // This prevents spurious navigation when user switches browser tabs
        // On web, getLatestLink() always returns the current URL, even when
        // there's no actual deep link event (user just switched tabs)
        if (!isShareResult &&
            _lastProcessedDeepLink != null &&
            _isSameDeepLink(latestLink, _lastProcessedDeepLink!)) {
          debugPrint(
            '[SokoApp] Ignoring duplicate deep link on resume: $latestLink',
          );
          return;
        }

        debugPrint('[SokoApp] Found pending deep link on resume: $latestLink');
        _lastProcessedDeepLink = latestLink;
        _handleDeepLink(latestLink);
      }
    } catch (e) {
      debugPrint('[SokoApp] Error checking for pending deep link: $e');
    }
  }

  /// Compare two URIs to determine if they represent the same deep link
  /// Ignores fragment identifiers and normalizes for comparison
  bool _isSameDeepLink(Uri a, Uri b) {
    // Compare scheme, host, port, path, and query (ignore fragment)
    return a.scheme == b.scheme &&
        a.host == b.host &&
        a.port == b.port &&
        a.path == b.path &&
        a.query == b.query;
  }

  void _initDeepLinks() {
    // Handle initial link if app was launched via deep link.
    final initialLink = ref.read(initialDeepLinkProvider);

    // app_links replays the cold-start launch link onto `uriLinkStream` the
    // first time we subscribe (its `onListen` re-emits the stored initialLink).
    // That same link is ALSO delivered via the cold-start path below
    // (getInitialLink → provider, and the race-proof `/splash` redirect for the
    // `/drop` & `/weekly-bundle` marker-redirect links). Routing the stream
    // replay too would deliver it twice — and for marker-redirect links each
    // delivery re-stamps a fresh per-tap nonce, so the DiscoveryScreen handler
    // fires twice (two stacked pushes). It can also pre-empt the `/splash`
    // branch by navigating away from `/splash` before it runs. So skip exactly
    // that one replay (the first stream event matching the launch link); warm
    // taps and every later link route normally.
    Uri? coldStartReplayToSkip = initialLink;

    // Handle incoming links while the app is running.
    _linkSubscription = _appLinks.uriLinkStream.listen((Uri uri) {
      final isColdStartReplay =
          coldStartReplayToSkip != null &&
          _isSameDeepLink(uri, coldStartReplayToSkip!);
      // Only the first stream event can be the cold-start replay; clear the
      // guard so a later warm re-tap of the same link is never skipped.
      coldStartReplayToSkip = null;
      _lastProcessedDeepLink = uri;
      if (isColdStartReplay) return;
      _handleDeepLink(uri);
    });

    if (initialLink != null) {
      _lastProcessedDeepLink = initialLink;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        // PROD-2564/PROD-2565: flag this as the cold-start *initial* link so the
        // pipeline can suppress the redundant `go()` for the `/drop` and
        // `/weekly-bundle` marker-redirect links — the `/splash` redirect
        // already delivers those via `coldStartDeepLinkSplashTarget`, and
        // re-issuing `go()` here would re-stamp a fresh marker and double-fire
        // the DiscoveryScreen handler. Attribution / Klaviyo still fire.
        _handleDeepLink(initialLink, isColdStartInitialLink: true);
      });
    } else {
      // Even without an initial deep link, capture the current URL
      // so we don't process it spuriously on app resume.
      _captureCurrentUrlAsProcessed();
    }
  }

  /// Capture current URL to prevent spurious deep link handling on resume
  void _captureCurrentUrlAsProcessed() async {
    try {
      final currentLink = await _appLinks.getLatestLink();
      if (currentLink != null) {
        _lastProcessedDeepLink = currentLink;
        debugPrint('[SokoApp] Captured current URL as processed: $currentLink');
      }
    } catch (e) {
      debugPrint('[SokoApp] Error capturing current URL: $e');
    }
  }

  /// Handle a deep link URI, extracting referral parameters if present.
  ///
  /// [isColdStartInitialLink] is `true` only for the launch link delivered via
  /// the post-frame callback in [_initDeepLinks] (never for warm
  /// `uriLinkStream` taps or resolved short links). It lets [_processDeepLink]
  /// skip the redundant navigation for the `/drop` / `/weekly-bundle`
  /// marker-redirect links, which the `/splash` redirect already delivered
  /// (PROD-2564/PROD-2565). Share-extension and short-link branches don't
  /// forward it — those link kinds are never the marker-redirect deep links and
  /// own their delivery.
  void _handleDeepLink(Uri uri, {bool isColdStartInitialLink = false}) {
    // Share-extension handoff. The iOS Share Extension writes the share
    // payload to the App Group then opens the host app via this URL. Branch
    // out before any other handling so we never accidentally route through
    // referral / app_links logic.
    //
    // Compare lowercased — Dart's `Uri` parser canonicalises both the scheme
    // and host to lowercase per RFC 3986, so the literal mixed-case constant
    // below would never match the actual `sharemedia-ai.heyl.heylapp` /
    // `share-result` we receive.
    if (uri.scheme.toLowerCase() == 'sharemedia-ai.heyl.heylapp' &&
        uri.host.toLowerCase() == 'share-result') {
      ref.read(appEntryTrackerProvider).noteShareIntake();
      _handleShareResultDeepLink(uri);
      return;
    }

    // Tier 2: every other link is a `link` entry door. Noted BEFORE the
    // short-link branch so a slow resolve still yields a link entry; the
    // resolved URL re-notes with its UTMs when it arrives in time.
    ref.read(appEntryTrackerProvider).noteLink(uri);

    // Short.io branded short-link hosts (PROD-2314). The tapped slug is opaque
    // (e.g. r.soko.fyi/aB3xY) — it must be resolved over the network into the
    // real app.soko.fyi/chat?… destination before any routing / referral /
    // attribution logic can run. Resolution is async; kick it off and bail —
    // the resolved URL is fed back through `_processDeepLink` on success so
    // Klaviyo, attribution, and referral handling all fire on the real URL.
    if (AppRoutes.isShortLinkHost(uri)) {
      unawaited(_resolveAndHandleShortLink(uri));
      return;
    }

    _processDeepLink(uri, isColdStartInitialLink: isColdStartInitialLink);
  }

  /// Resolve a Short.io branded short link, then route on the resolved URL.
  ///
  /// On any failure (or a URL the app can't route) falls back to opening the
  /// original short URL in the browser — which follows the Short.io → backend
  /// chain on its own — so the user always lands somewhere. No in-app error UI
  /// (PROD-2314).
  Future<void> _resolveAndHandleShortLink(Uri shortUri) async {
    // Tier 2: resolution can take up to 3 s, past the entry tracker's grace.
    // Hold the pending `app_entry` so the resolved URL's UTMs make it in.
    // One token per resolution: two overlapping resolves must not release
    // each other's hold.
    final entryTracker = ref.read(appEntryTrackerProvider);
    final holdToken = Object();
    entryTracker.hold(holdToken);
    try {
      await _resolveAndHandleShortLinkInner(shortUri);
    } finally {
      entryTracker.release(holdToken);
    }
  }

  static const Object _kPushCheckEntryHold = 'push_initial_message';

  Future<void> _resolveAndHandleShortLinkInner(Uri shortUri) async {
    // Loop guard (layer 1). If this exact short URL failed a few seconds ago,
    // this delivery is almost certainly our own fallback being handed back to
    // us by Android app-link resolution, not a new tap. Do NOT resolve (one
    // network round-trip per iteration) and do NOT launch (the relaunch IS
    // the loop). Emit the failure with its own kind so the guard is countable.
    if (_shortLinkFallback.suppressIfLooping(shortUri)) return;

    // PROD-4388 — share.soko.fyi is served by OUR backend, not Short.io, and
    // its route answers 200-with-OG-tags rather than a redirect (a 302 would
    // send link-preview crawlers on to the SPA shell). `resolveShortLink`
    // follows the Location chain and treats any 2xx as terminal, so it would
    // hand back the share.soko.fyi URL itself — unroutable, and the user would
    // get bounced to the browser. Ask the JSON resolve endpoint instead.
    final result = isFirstPartyShareHost(shortUri)
        ? await resolveFirstPartyShareLink(
            shortUri,
            apiBaseUrl: EnvironmentConfig.baseUrl,
            webappUrl: ApiConstants.webappUrl,
          )
        : await resolveShortLink(shortUri);
    final resolved = result.resolvedUrl;

    // Failed to resolve, or resolved to a URL we can't route. Three guards:
    //   - resolved == null / null route: resolution failed outright.
    //   - sentinel: the chain terminated back on a short-link host (e.g. a 200
    //     interstitial instead of a 302) — nothing app-routable there.
    //   - !isRoutableDeepLinkTarget: the chain resolved to an arbitrary path on
    //     a production host (e.g. app.soko.fyi/some-marketing-page) that
    //     parseDeepLink passes through as a non-null route but the router would
    //     just bounce home. Browser-fall-back so the user lands on the page.
    final route = resolved == null ? null : AppRoutes.parseDeepLink(resolved);
    if (resolved == null ||
        route == null ||
        route == AppRoutes.shortLinkUnresolved ||
        !AppRoutes.isRoutableDeepLinkTarget(resolved)) {
      // Layer 2 lives in the coordinator: record the failure, then open the
      // resolved (or short) URL in the plugin's in-app WebView. NOT
      // `inAppBrowserView`: on Android that is `CustomTabsIntent.launchUrl`
      // with no target package, i.e. a plain ACTION_VIEW, and `shortUri`'s
      // host is one of our verified App Links — so the system routed it back
      // to this app and it looped (2,570 failures from one device on
      // 2026-08-18, on a build that already had inAppBrowserView). The WebView
      // activity does no intent resolution and still follows the Short.io →
      // backend redirect chain.
      await _shortLinkFallback.handleFailure(
        shortUri: shortUri,
        resolved: resolved,
        errorKind: result.failureKind ?? 'unroutable',
      );
      return;
    }

    unawaited(
      ref
          .read(unifiedAnalyticsProvider)
          .trackShortLinkResolved(
            sourceHost: shortUri.host,
            resolvedUrl: redactDeepLinkForLogging(resolved),
            route: route,
          ),
    );

    // Re-enter the normal pipeline on the resolved URL so referral (?ref=) +
    // search (?search=) extraction and attribution fire on the real link.
    ref.read(appEntryTrackerProvider).noteLink(resolved);
    _processDeepLink(resolved);
  }

  /// Run the standard deep-link pipeline (tracking → referral → routing) for an
  /// already-resolved [uri]. Split out of [_handleDeepLink] so short links can
  /// re-enter it with their resolved destination.
  ///
  /// [isColdStartInitialLink] (see [_handleDeepLink]) suppresses only the final
  /// navigation for the `/drop` / `/weekly-bundle` marker-redirect links;
  /// tracking, Klaviyo, and referral handling always run.
  void _processDeepLink(Uri uri, {bool isColdStartInitialLink = false}) {
    // Let Klaviyo record universal tracking link opens when a push/campaign
    // click lands in the app. Normal app routing continues below.
    unawaited(
      ref.read(klaviyoServiceProvider).handleUniversalTrackingLink(uri),
    );

    // Track attribution data if present (fire-and-forget)
    _trackAttribution(uri);

    // Extract referral parameters
    final refSlug = uri.queryParameters['ref'];
    final searchQuery = uri.queryParameters['search'];

    if (refSlug != null && refSlug.isNotEmpty) {
      debugPrint('[SokoApp] Found referral slug in URL: $refSlug');

      // Check if user is already authenticated
      final authState = ref.read(authStateProvider);
      if (authState.isAuthenticated && authState.isInitialized) {
        // User already logged in - process referral immediately
        debugPrint(
          '[SokoApp] User already authenticated, processing referral immediately',
        );
        _processReferralImmediately(refSlug, searchQuery);
        return; // Don't navigate - we'll handle it in processReferral
      } else {
        // User not authenticated - store referral for after auth
        ref
            .read(referralServiceProvider)
            .storeReferral(refSlug, searchQuery: searchQuery);
        // PROD-2315: stop here when the referral carries a search query. The
        // referral pipeline replays the search after auth (the only supported
        // flow today — running search as a guest requires AI consent, deferred
        // to a future refactor). Without this return we'd fall through to
        // `go('/chat?search=...&ref=...')`, which the /chat route would now
        // auto-send (guest), double-running the search once auth completes.
        // Attribution is unaffected: `_trackAttribution` already fired above
        // and `storeReferral` persisted ref + search.
        if (searchQuery != null && searchQuery.isNotEmpty) {
          return;
        }
      }
    }

    // Continue with normal routing
    final route = AppRoutes.parseDeepLink(uri);
    if (route != null) {
      // PROD-2564/PROD-2565 cold-start fix: the `/drop` and `/weekly-bundle`
      // marker-redirect links are delivered from the `/splash` redirect on cold
      // start (`coldStartDeepLinkSplashTarget`). Re-issuing `go()` here would
      // re-hit their route redirect, stamp a *fresh* per-tap marker, and
      // double-fire the DiscoveryScreen handler (a second overlay/detail push).
      // Suppress the redundant nav for them — but ONLY when the splash branch
      // actually delivered it. `coldStartDeepLinkSplashTarget` bails on `?ref=`
      // links (the referral pipeline owns delivery), so a cold-start
      // `/drop?ref=…` is NOT splash-delivered and must still route here, or it
      // would be dropped. Gating on `coldStartDeepLinkSplashTarget(uri) != null`
      // keeps this suppression in lock-step with what the splash branch claims;
      // public-share targets (also splash-delivered) are excluded by the
      // marker-redirect check — their re-issue is idempotent and stays as-is.
      // Warm taps pass isColdStartInitialLink=false; web delivers via natural
      // initial-location routing regardless. Attribution/Klaviyo fired above.
      //
      // PROD-2566: `/user-profiling/flow` is also splash-delivered and is NOT a
      // marker-redirect, but for a LOGGED-OUT user its route redirect stamps a
      // fresh `?user_profiling=<n>` nonce per pass (app_router.dart) — so the
      // redundant `go()` would settle on `/?user_profiling=1` then re-route to
      // `/?user_profiling=2`, double-firing the Discovery login sheet +
      // `profiling_deep_link` analytics. Suppress it too (for an authed user the
      // re-issue is idempotent, so suppression is a harmless no-op — the splash
      // branch already delivered the flow/landing).
      final routePath = Uri.parse(route).path;
      // Tier 2 (B3): remember the list this link points at for 60 s so the
      // list screen can stamp `list_open.source=deep_link`.
      final listTarget = deepLinkListTargetId(routePath);
      if (listTarget != null) {
        ref.read(deepLinkTargetLatchProvider).noteTarget('list', listTarget);
      }
      // PROD-2742 (`/yours`) + PROD-3326 (`/map`): both are markerless final
      // destinations — fire their funnel event once here, at the resolve choke
      // point (before any /login bounce). Runs exactly once per native tap
      // (`_processDeepLink` is the single per-tap entry); web loads the route
      // via the natural initial location and is covered by session UTM +
      // screen-views. UTM auto-merges (see `_utmEnrichedEvents`).
      //
      // auth_state must reflect the SETTLED auth: on cold start this runs in a
      // post-frame callback that can beat token restoration, so reading
      // `isAuthenticated` now would mislabel a returning logged-in user as
      // `logged_out`. Emit immediately when auth is initialized; otherwise defer
      // to a one-shot listener (mirrors `_waitForAuthInitialized` in
      // instagram_callback_screen.dart) so the settled value is reported.
      void emitWhenAuthSettled(void Function(String authState) track) {
        void emit() {
          track(
            ref.read(authStateProvider).isAuthenticated
                ? 'logged_in'
                : 'logged_out',
          );
        }

        if (ref.read(authStateProvider).isInitialized) {
          emit();
        } else {
          late final ProviderSubscription<AuthState> authInitSub;
          authInitSub = ref.listenManual<AuthState>(authStateProvider, (
            _,
            next,
          ) {
            if (next.isInitialized) {
              emit();
              authInitSub.close();
            }
          });
        }
      }

      if (routePath == AppRoutes.lists) {
        emitWhenAuthSettled(
          (authState) => ref
              .read(unifiedAnalyticsProvider)
              .trackYoursDeepLink(authState: authState),
        );
      }
      if (routePath == AppRoutes.mapa) {
        emitWhenAuthSettled(
          (authState) => ref
              .read(unifiedAnalyticsProvider)
              .trackMapDeepLink(authState: authState),
        );
      }
      if (isColdStartInitialLink &&
          (AppRoutes.isMarkerRedirectDeepLink(routePath) ||
              routePath == AppRoutes.userProfilingFlow) &&
          coldStartDeepLinkSplashTarget(uri) != null) {
        return;
      }
      ref.read(appRouterProvider).go(route);
    }
  }

  /// Route an AppsFlyer OneLink UDL callback through the SAME `app_links`
  /// pipeline (Task 13, spec §4) instead of letting AppsFlyer navigate on its
  /// own path.
  ///
  /// AppsFlyer's `onDeepLinking` callback fires independently of
  /// `app_links`' `uriLinkStream` — on Android in particular both SDKs can
  /// observe the same tapped App Link — so this dedupes against
  /// [_lastProcessedDeepLink] (via [_isSameDeepLink]) exactly like
  /// [_checkForPendingDeepLink] does, rather than opening a second
  /// navigation path:
  ///   - Already-handled link (or no destination link at all — an
  ///     attribution-only payload) → no navigation.
  ///   - New link → routed through [_handleDeepLink], the exact function
  ///     `_appLinks.uriLinkStream.listen` calls.
  void _handleAppsflyerDeepLink(Map<String, dynamic> payload) {
    try {
      final uri = _resolveAppsflyerDeepLinkUri(payload);
      if (uri == null) {
        // Attribution-only payload (e.g. install/open attribution with no
        // `deep_link_value`/`link`/`af_dp`) — record it without navigating.
        debugPrint('[appsflyer] attribution-only UDL payload: $payload');
        return;
      }
      if (_lastProcessedDeepLink != null &&
          _isSameDeepLink(uri, _lastProcessedDeepLink!)) {
        debugPrint(
          '[appsflyer] ignoring duplicate UDL (already handled): $uri',
        );
        return;
      }
      debugPrint('[appsflyer] routing UDL via app_links pipeline: $uri');
      _lastProcessedDeepLink = uri;
      _handleDeepLink(uri);
    } catch (e) {
      debugPrint('[appsflyer] failed to handle UDL payload: $e');
    }
  }

  /// Extract the resolved destination [Uri] from an AppsFlyer UDL
  /// `click_event` payload (spec §4).
  ///
  /// The plugin doesn't formally type this map — [RealAppsflyerClient] passes
  /// through the raw `DeepLink.clickEvent` — so check known keys defensively,
  /// most-specific first: `deep_link_value` (the value the OneLink template
  /// was configured to resolve to — mirrors `DeepLink.deepLinkValue`), then
  /// `link` / `af_dp` (the raw clicked / deep-link URL AppsFlyer sometimes
  /// echoes back instead). Only accepts a value that parses to an absolute
  /// URL (has a host) — matching the shape every other entry into this
  /// pipeline (`app_links`, resolved short links) already uses, and what
  /// [_isSameDeepLink] / [AppRoutes.parseDeepLink] expect. Returns `null`
  /// when none qualify, i.e. the payload is attribution-only
  /// (media_source/campaign/etc. with no destination link).
  Uri? _resolveAppsflyerDeepLinkUri(Map<String, dynamic> payload) {
    for (final key in const ['deep_link_value', 'link', 'af_dp']) {
      final value = payload[key];
      if (value is String && value.isNotEmpty) {
        final uri = Uri.tryParse(value);
        if (uri != null && uri.host.isNotEmpty) return uri;
      }
    }
    return null;
  }

  /// Handle the iOS Share Extension's "Ver na app" deep link.
  ///
  /// URL contract:
  ///   `ShareMedia-ai.heyl.heylApp://share-result`
  ///   `?sharedPostId={uuid}`
  ///   `&targetListId={uuid}` (optional)
  ///   `&state=terminal|pending`
  ///
  /// On `state=terminal`, the extension has already polled to a terminal
  /// status and written the full SharedPostOut JSON to the App Group at
  /// `soko.share.last_terminal.v1`. We read it via [AppGroupBridge], call
  /// `applyTerminalFromExtension(...)` on the polling provider, then route
  /// to the right detail / review surface.
  ///
  /// On `state=pending`, the extension wrote `soko.share.in_flight.v1`
  /// (mirroring the existing `active_instagram_share` schema) and handed
  /// off polling. We start a polling loop and route to /lists so the in-app
  /// banner takes over.
  ///
  /// Phase 1: full handoff. The extension has already done all the work; we
  /// just consume the App Group payload and route the user to the right sheet.
  void _handleShareResultDeepLink(Uri uri) {
    final state = uri.queryParameters['state'];
    final sharedPostId = uri.queryParameters['sharedPostId'];
    final targetListId = uri.queryParameters['targetListId'];
    debugPrint(
      '[SokoApp] share-result deep link: state=$state, sharedPostId=$sharedPostId, '
      'targetListId=$targetListId',
    );
    if (state == 'pending') {
      _handlePendingShareResult(
        sharedPostId: sharedPostId,
        listId: targetListId,
      );
    } else {
      _handleTerminalShareResult(listId: targetListId);
    }
  }

  Future<void> _handlePendingShareResult({
    required String? sharedPostId,
    required String? listId,
  }) async {
    if (sharedPostId == null || sharedPostId.isEmpty) {
      ref.read(appRouterProvider).go(AppRoutes.library);
      return;
    }
    ref
        .read(instagramSharePollingProvider.notifier)
        .startPolling(sharedPostId, listId: listId);
    ref.read(appRouterProvider).go(AppRoutes.library);
    // Don't bother clearing the in-flight key — the polling provider's own
    // `_persist` rewrites it to `active_instagram_share` immediately.
  }

  Future<void> _handleTerminalShareResult({required String? listId}) async {
    final raw = await AppGroupBridge.instance.readShareResult();
    if (raw == null) {
      // Extension claimed terminal but no blob is present. Fall back to
      // /library — better than dropping the user on a blank screen.
      debugPrint(
        '[SokoApp] share-result terminal: no App Group blob, routing to /library',
      );
      ref.read(appRouterProvider).go(AppRoutes.library);
      return;
    }
    SharedPostOut? share;
    try {
      share = SharedPostOut.fromJson(raw);
    } catch (e) {
      debugPrint('[SokoApp] share-result: failed to parse SharedPostOut: $e');
      ref.read(appRouterProvider).go(AppRoutes.library);
      await AppGroupBridge.instance.clearShareKeys();
      return;
    }
    debugPrint(
      '[SokoApp] share-result terminal: id=${share.id} status=${share.status} '
      'events=${share.eventIds.length} venue=${share.venueId} '
      'classification=${share.classification}',
    );

    ref
        .read(instagramSharePollingProvider.notifier)
        .applyTerminalFromExtension(share, listId: listId);

    // Clear App Group keys *before* the route change and the navigator wait.
    // The resume hook `_consumeShareInFlightFromAppGroup` runs concurrently
    // with this handler — if it reads `share.in_flight.v1` after we've
    // applied the terminal state, its `startPolling` call wipes
    // `state.activeShare` (timers are stopped, so the dedupe doesn't fire),
    // and `openIngestedItem` finds nothing to open.
    await AppGroupBridge.instance.clearShareKeys();

    // Always make sure the user lands on /library so the banner is visible
    // behind whatever sheet we open.
    ref.read(appRouterProvider).go(AppRoutes.library);

    // On cold launch, the deep link fires before MaterialApp/Navigator has
    // mounted — `currentContext` is null until auth init finishes and the
    // /library route paints its first frame. A fixed 100ms wait was too
    // optimistic and the sheet open silently no-op'd. Poll up to 5s instead.
    final hostContext = await _waitForNavigatorReady();
    if (hostContext == null) {
      debugPrint(
        '[SokoApp] share-result: navigator never became ready; '
        'banner remains visible for manual tap',
      );
      return;
    }
    final showReview =
        (share.eventIds.length >= 2) ||
        (share.classification == 'event_announcement' && share.venueId != null);
    debugPrint(
      '[SokoApp] share-result: opening ${showReview ? "review sheet" : "item detail"}',
    );
    if (showReview) {
      // ignore: use_build_context_synchronously, discarded_futures
      showInstagramShareReviewSheet(
        context: hostContext,
        ref: ref,
        share: share,
        targetListId: listId,
      );
    } else {
      // ignore: use_build_context_synchronously
      await openIngestedItem(hostContext, ref: ref);
    }
  }

  /// Wait until the GoRouter navigator has mounted *and* auth is initialized,
  /// so a sheet shown via the returned context lands on top of the real
  /// /lists page (not the splash) and `Lt.of(context)` resolves.
  ///
  /// Cold launch from the iOS Share Extension's "Ver na app" deep link races
  /// auth init / first frame; on a debug build this can take 600–1500ms. We
  /// poll every 80ms up to 5s, then give up — the banner stays visible so
  /// the user can manually tap it.
  Future<BuildContext?> _waitForNavigatorReady({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!mounted) return null;
      final ctx = ref
          .read(appRouterProvider)
          .routerDelegate
          .navigatorKey
          .currentContext;
      final auth = ref.read(authStateProvider);
      if (ctx != null && auth.isInitialized && auth.isAuthenticated) {
        return ctx;
      }
      await Future<void>.delayed(const Duration(milliseconds: 80));
    }
    return null;
  }

  /// Track attribution data from deep link URL (fire-and-forget)
  void _trackAttribution(Uri uri) {
    try {
      final attributionService = ref.read(attributionServiceProvider);
      attributionService.trackAppOpen(uri);

      final params = uri.queryParameters;

      // Store session-level UTM for auto-enrichment of analytics events
      final utmHolder = ref.read(sessionUtmHolderProvider);
      utmHolder.setUtm(
        utmSource: params['utm_source'],
        utmMedium: params['utm_medium'],
        utmCampaign: params['utm_campaign'],
        utmContent: params['utm_content'],
        utmTerm: params['utm_term'],
      );

      // Also capture document.referrer on web
      final referrer = attributionService.getReferrerUrl();
      utmHolder.setReferrer(referrer);

      // Set UTM params as PostHog person properties ($set_once)
      // so PostHog insights can attribute traffic to campaigns.
      // Native apps don't auto-capture $initial_utm_* like the JS SDK does.
      if (params['utm_source'] != null ||
          params['utm_medium'] != null ||
          params['utm_campaign'] != null) {
        ref
            .read(postHogServiceProvider)
            .setInitialAttribution(
              utmSource: params['utm_source'],
              utmMedium: params['utm_medium'],
              utmCampaign: params['utm_campaign'],
              utmContent: params['utm_content'],
              utmTerm: params['utm_term'],
            );
      }
    } catch (e) {
      debugPrint('[SokoApp] Failed to track attribution: $e');
    }
  }

  /// Process referral immediately for already-authenticated users
  void _processReferralImmediately(String slug, String? searchQueryFromUrl) {
    final referralService = ref.read(referralServiceProvider);

    // Store the referral for tracking
    referralService.storeReferral(slug, searchQuery: searchQueryFromUrl);

    if (searchQueryFromUrl != null && searchQueryFromUrl.isNotEmpty) {
      // We have the query from URL - navigate directly (no async API call needed)
      debugPrint(
        '[SokoApp] Navigating directly with search: $searchQueryFromUrl',
      );
      ref
          .read(appRouterProvider)
          .go(AppRoutes.chat, extra: {'autoSendMessage': searchQueryFromUrl});
      // Clear the stored referral since we've processed it
      referralService.clearPendingReferral();
    } else {
      // No query from URL - use existing async flow to fetch from API
      referralService.processPendingReferral(ref.read(appRouterProvider));
    }
  }

  @override
  Widget build(BuildContext context) {
    // Keeps the cross-account purge alive for the whole app lifetime. It
    // watches the signed-in identity and throws away every account-scoped
    // provider whenever it changes — the single guarantee that account B
    // never sees account A's `/yours`, chat, saves or profile data. See
    // `core/session/user_scoped_state.dart`.
    ref.watch(userScopedStatePurgeProvider);

    final router = ref.watch(appRouterProvider);
    final locale = ref.watch(localeProvider);
    // Theme switching is gated behind a hardcoded kill switch
    // (`EnvironmentConfig.themeSwitchingEnabled`). When off, the app is
    // locked to light mode and every user-facing theme toggle is hidden.
    // The provider is still watched when enabled so a future flip honors
    // the user's previously persisted preference.
    final themeMode = EnvironmentConfig.themeSwitchingEnabled
        ? ref.watch(themeModeProvider)
        : ThemeMode.light;

    // Listen to auth events and handle session expiry
    ref.listen<AsyncValue<AuthEvent>>(authEventStreamProvider, (_, next) {
      next.whenData((event) {
        switch (event) {
          case AuthEvent.sessionExpired:
            _handleSessionExpired();
          case AuthEvent.accountSuspended:
            _handleAccountSuspended();
        }
      });
    });

    // Listen for authentication state changes to process pending referrals
    ref.listen<AuthState>(authStateProvider, (previous, next) {
      _handleAuthStateChange(previous, next);
    });

    // Sync locale from user profile when user changes or on initial load
    final currentUser = ref.watch(currentUserProvider);
    ref.listen(currentUserProvider, (previous, next) {
      if (next != null && previous?.preferredLocale != next.preferredLocale) {
        ref.read(localeProvider.notifier).syncFromProfile(next.preferredLocale);
      }
    });
    // Also sync on initial load (ref.listen doesn't fire for initial value)
    if (currentUser != null && !_didInitialLocaleSync) {
      _didInitialLocaleSync = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref
            .read(localeProvider.notifier)
            .syncFromProfile(currentUser.preferredLocale);
      });
    }

    // Auto-detect country from IP for first-time users (no logged-in user)
    // This sets locale and phone country defaults based on detected location
    if (!_didTriggerCountryDetection && currentUser == null) {
      _didTriggerCountryDetection = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _triggerCountryDetection();
      });
    }

    // PROD-3979 — sits ABOVE the locale-keyed MaterialApp on purpose. The key
    // below tears down the whole subtree on a locale change, so a listener
    // mounted inside it would be destroyed by the very event it exists to
    // observe. From here it survives, sees the change, and refetches the
    // strings the backend resolved (which the key cannot re-render, because
    // they are payload rather than ARB copy).
    return LocaleRefreshListener(
      child: MaterialApp.router(
        // Force rebuild when locale changes to reload translations
        // (Lt delegate has shouldReload => false, so we use key to force reload)
        key: ValueKey('app_locale_${locale?.toString() ?? 'system'}'),
        title: AppConstants.appName,
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light,
        darkTheme: AppTheme.dark,
        themeMode: themeMode,
        routerConfig: router,
        // Render the navigator only once auth has initialized. Until then, show
        // a splash screen IN PLACE — without changing the URL. This is what
        // makes deep links like /memories survive the auth-init race on slow
        // mobile WebKit (the URL bar stays at the user's typed destination,
        // and the underlying screen builds against it once init completes).
        builder: (context, child) => MediaQuery.withClampedTextScaling(
          // PROD-2875: cap OS font scaling app-wide so large iOS Dynamic Type /
          // Android font-size settings don't clip fixed-height buttons and dense
          // layouts. minScaleFactor stays 0 (users who shrink text keep it); we
          // only cap the ceiling at 1.3x — enough accessibility range to honor
          // while keeping layouts intact. The shared primitives (SokoCtaButton,
          // BtSqIco, bottom nav, cards) are separately hardened to survive up to
          // this ceiling. Safety net, not a substitute for those fixes.
          maxScaleFactor: 1.3,
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => FocusManager.instance.primaryFocus?.unfocus(),
            child: NotificationHost(
              child: _SplashGate(child: child ?? const SizedBox.shrink()),
            ),
          ),
        ),
        localizationsDelegates: Lt.localizationsDelegates,
        supportedLocales: Lt.supportedLocales,
        locale: locale,
      ),
    );
  }

  void _handleSessionExpired() {
    // Reset token refresh state for next login session
    ref.read(tokenRefreshServiceProvider.notifier).reset();

    // Force logout in AuthNotifier (clears state without calling API)
    ref.read(authStateProvider.notifier).forceLogout();

    // Don't explicitly navigate to login here.
    // The forceLogout() above clears auth state, which triggers
    // RouterRefreshNotifier → GoRouter re-evaluates the redirect for the
    // current route. The router's redirect logic correctly handles this:
    // - Protected routes (chat, saved, lists hub) → redirect to login
    // - Public routes (individual list views, legal pages) → stay on page
    // Previously, this method always called router.go(AppRoutes.login),
    // which would redirect users away from public list views unnecessarily.
  }

  /// PROD-2264 — Handle a 403 USER_SUSPENDED / USER_BANNED response.
  /// Force-logs out so the bearer token isn't reused on the next call
  /// (which would just 403 again and loop) and routes the user to the
  /// suspended-account landing screen. The route is whitelisted as
  /// public in the redirect block, so it survives the forced logout.
  void _handleAccountSuspended() {
    ref.read(tokenRefreshServiceProvider.notifier).reset();
    ref.read(authStateProvider.notifier).forceLogout();
    ref.read(appRouterProvider).go(AppRoutes.accountSuspended);
  }

  /// Handle authentication state changes to process pending referrals
  void _handleAuthStateChange(AuthState? previous, AuthState next) {
    // Check if user just became authenticated (wasn't before, is now)
    final wasAuthenticated = previous?.isAuthenticated ?? false;
    final isNowAuthenticated = next.isAuthenticated && next.isInitialized;

    if (!wasAuthenticated && isNowAuthenticated) {
      debugPrint('[SokoApp] User authenticated, checking for pending referral');
      _processPendingReferralIfNeeded();
      // Track app open event after authentication is confirmed
      _trackAppOpen();
      // Cold-start coverage for the return-reprompt: the sdk_failure cohort
      // already passed Siga (consent recorded), so a cold start won't
      // re-trigger it. maybeRepromptOnReturn loads preferences if needed,
      // then no-ops unless the OS is `notDetermined` and Siga is clear.
      // ignore: unawaited_futures
      ref.read(pushPermissionServiceProvider.notifier).maybeRepromptOnReturn();
      // Reload sessions now that we have auth — the provider may have loaded
      // empty results before the token was available (PROD-797)
      ref.invalidate(sessionsProvider);
      // Resume any in-flight Instagram share submitted in a previous session
      // (browser refresh / app restart) so the processing banner reappears.
      ref.read(instagramSharePollingProvider.notifier).rehydrate();
      // Same for any in-flight photo→event contribution (PROD-2404). No
      // iOS Share Extension path for contributions in v1, so the rehydrate
      // call alone covers the browser-refresh / app-restart resume.
      ref.read(contributionPollingProvider.notifier).rehydrate();
      // PROD-2523 T-D: resume the FCM-tap deep-link the user tapped while
      // logged out. Fire-and-forget; failures fall back to whatever screen
      // the post-login flow lands on.
      // ignore: unawaited_futures
      _resumeNotificationTapIfStashed();
    }

    // Track app open for guest users (unauthenticated) on first initialization
    final wasInitialized = previous?.isInitialized ?? false;
    if (!wasInitialized && next.isInitialized && !next.isAuthenticated) {
      _trackAppOpen();
    }

    // Reset flags if user logs out
    if (wasAuthenticated && !next.isAuthenticated) {
      _didProcessPendingReferral = false;
      _didTrackAppOpen = false;
    }
  }

  /// PROD-2523 T-D — pop the stashed FCM-tap route (if any) after the user
  /// completes the forced login flow. Mirrors the deep-link resume pattern
  /// already used for referrals.
  Future<void> _resumeNotificationTapIfStashed() async {
    try {
      final route = await NotificationTapResume.consume();
      if (route == null || !mounted) return;
      ref.read(appRouterProvider).go(route);
    } catch (e) {
      debugPrint('[SokoApp] resume notification tap failed: $e');
    }
  }

  /// Track app open event (fire-and-forget, once per session)
  void _trackAppOpen() {
    if (_didTrackAppOpen) return;
    _didTrackAppOpen = true;
    try {
      ref.read(unifiedAnalyticsProvider).trackAppOpen();
    } catch (e) {
      debugPrint('[SokoApp] Failed to track app_open: $e');
    }
  }

  /// Process pending referral after authentication
  void _processPendingReferralIfNeeded() {
    // Only process once per session
    if (_didProcessPendingReferral) {
      debugPrint('[SokoApp] Already processed pending referral this session');
      return;
    }
    _didProcessPendingReferral = true;

    final referralService = ref.read(referralServiceProvider);
    if (referralService.hasPendingReferral()) {
      debugPrint('[SokoApp] Processing pending referral');
      // Capture router BEFORE the delay to avoid using ref after widget disposal
      final router = ref.read(appRouterProvider);
      // Use a small delay to ensure router is ready
      Future.delayed(const Duration(milliseconds: 300), () {
        if (mounted) {
          referralService.processPendingReferral(router);
        }
      });
    } else {
      debugPrint('[SokoApp] No pending referral to process');
    }
  }

  /// Trigger country detection from IP address for first-time users.
  /// Sets locale based on detected country (fire-and-forget).
  void _triggerCountryDetection() async {
    debugPrint('[SokoApp] Triggering country detection from IP');
    try {
      // This will trigger the IP detection if not already cached
      final countryCode = await ref.read(detectedCountryCodeProvider.future);
      if (countryCode != null && mounted) {
        debugPrint('[SokoApp] Detected country: $countryCode, setting locale');
        ref
            .read(localeProvider.notifier)
            .setLocaleFromDetectedCountry(countryCode);
      } else {
        // Detection failed or returned null - don't persist a default.
        // apiLocaleCodeProvider will fall back to the platform locale.
        debugPrint(
          '[SokoApp] Country detection returned null, leaving locale unset',
        );
      }
    } catch (e) {
      // Don't persist a default on error - let platform locale be the fallback
      debugPrint('[SokoApp] Country detection error: $e, leaving locale unset');
    }
  }
}

/// Renders a splash screen IN PLACE while [authStateProvider] is initializing,
/// without changing the URL. Once `isInitialized` flips true, the underlying
/// router child takes over and builds the screen for the URL the user typed.
///
/// This is what makes deep links (`/memories`, `/lists`, `/discovery`) survive
/// the auth-init race on slow mobile WebKit. The previous approach redirected
/// the URL bar to `/splash` during init and then tried to restore the original
/// destination via `returnUrlProvider` — that was racy across login screens
/// and the location-permission detour. By keeping the URL stable, the entire
/// returnUrl-handoff problem disappears for the typed-URL case.
class _SplashGate extends ConsumerStatefulWidget {
  final Widget child;
  const _SplashGate({required this.child});

  @override
  ConsumerState<_SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends ConsumerState<_SplashGate> {
  /// Hard cap on the EXTRA hold added after auth initialises while the
  /// onboarding routing decision settles. If the profile or the PostHog cohort
  /// flag is slow/unreachable, we reveal the app anyway rather than sit on the
  /// splash — a rare, brief flash beats a hang. (The auth-init wait itself is
  /// uncapped, exactly as before.) ExperimentService has its own confirm
  /// watchdog too; this is the independent backstop for the profile fetch.
  static const Duration _decisionHoldCap = Duration(seconds: 3);

  Timer? _capTimer;
  bool _capElapsed = false;

  void _armCapOnce() {
    if (_capTimer != null || _capElapsed) return;
    _capTimer = Timer(_decisionHoldCap, () {
      if (!mounted) return;
      setState(() => _capElapsed = true);
    });
  }

  @override
  void dispose() {
    _capTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isInitialized = ref.watch(
      authStateProvider.select((s) => s.isInitialized),
    );
    // Phase 1 — auth still initialising: show the splash (uncapped, as before).
    if (!isInitialized) return _splash();

    // Phase 2 — auth ready. Hold the splash a moment longer (logged-in users
    // only) until the onboarding routing decision is confident: profile loaded
    // AND the cohort flag confirmed. This keeps a cohort user who needs
    // onboarding from painting the home page (or the legacy Siga screen) for a
    // frame before the router bounces them to /onboarding-chat — the router
    // re-runs its redirect while this gate covers the screen, so the child is
    // revealed already at the correct destination. Guests never wait. Bounded
    // by [_decisionHoldCap] so a slow profile/PostHog can't hang the splash.
    _armCapOnce();
    final decisionReady = ref.watch(onboardingDecisionReadyProvider);
    if (decisionReady || _capElapsed) return widget.child;
    return _splash();
  }

  // PROD-4419 — the canvas moved to `SokoSplashView` so the Discovery variant
  // gate can render the identical thing (see that widget's doc). Behaviour here
  // is unchanged.
  Widget _splash() => const SokoSplashView();
}
