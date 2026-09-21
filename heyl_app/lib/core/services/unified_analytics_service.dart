import 'dart:async';

import 'package:flutter/widgets.dart' show NavigatorObserver;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/note_action.dart';
import '../../data/models/user_list.dart';
import '../../features/discovery/feed_v2/providers/feed_chrome_providers.dart';
import '../../features/discovery/feed_v2/providers/feed_variant_provider.dart';
import '../config/environment.dart';
import 'analytics/analytics.dart';
import 'analytics/auth_context.dart';
import 'analytics/list_open_analytics_props.dart';

import 'analytics/appsflyer_client.dart';
import 'analytics/appsflyer_destination.dart';
import 'analytics_service.dart';
import 'appsflyer_analytics_service.dart';
import 'backend_analytics_service.dart';
import 'meta_analytics_service.dart';
import 'posthog_service.dart';
import 'session_utm_holder.dart';
import 'tiktok_analytics_service.dart';

export 'analytics/auth_context.dart';

/// Latitude / longitude bounds, matching the API schema's own
/// (`latitude: {minimum: -90, maximum: 90}`, `longitude: ±180`).
const double _kAnalyticsLatAbsMax = 90.0;
const double _kAnalyticsLonAbsMax = 180.0;

/// PROD-4531 — a coordinate pair coarse enough to publish, or `(null, null)`
/// when there is nothing publishable.
///
/// **Every coordinate on `feed_exposed` and `unsupported_city_impression` goes
/// through here**, and it owns two rules that were previously each caller's to
/// remember:
///
///  * **Precision.** 2 decimals is about 1 km — enough to see which areas
///    readers are in, not enough to identify a home.
///  * **Validity.** Nothing upstream validates coordinates: a persisted scope
///    passes `center_lat`/`center_lng` through as raw doubles on a payload its
///    own doc says can drift across app updates. A non-finite value reaches
///    `jsonEncode` as `NaN` and throws, taking the whole event with it; an
///    out-of-range one is simply a fabricated location.
///
/// **All-or-nothing, like `feedCoordinatePair`.** Half a pair locates nothing
/// and is worse than nothing, because it still looks like data.
///
/// ⚠️ **Both rules live here rather than at the call sites deliberately**, and
/// the history is the argument: `latitude`/`longitude` on
/// `unsupported_city_impression` shipped unrounded from v7.0.0 to 9.9.0 because
/// rounding was nobody's job in particular, and codex found the validity half
/// re-introduced twice in one review of this very change. A caller that routes
/// through here can no longer leak a precise coordinate, or a NaN.
///
/// ⚠️ **It is NOT yet the only coordinate site in this service.**
/// `trackMapAreaSearched` keeps its own `_roundCoord3` (3 decimals, ~110 m),
/// and that is a deliberate product choice from PROD-3219 — nearby searches are
/// meant to collapse together for coverage-gap analysis, and 2 decimals would
/// coarsen that analysis rather than protect anyone further. What it does lack
/// is this function's **validity** half, so a non-finite centre could still
/// reach `jsonEncode` from that path. Left alone here rather than changed in
/// passing: it is a different event, with a different owner's reasoning on it.
/// Do not describe this boundary as covering every analytics coordinate until
/// that is true.
({double? lat, double? lon}) coarseCoordinates(double? lat, double? lon) {
  if (lat == null || lon == null) return (lat: null, lon: null);
  if (!lat.isFinite || !lon.isFinite) return (lat: null, lon: null);
  if (lat.abs() > _kAnalyticsLatAbsMax || lon.abs() > _kAnalyticsLonAbsMax) {
    return (lat: null, lon: null);
  }
  return (lat: _coarsen(lat), lon: _coarsen(lon));
}

double _coarsen(double value) => (value * 100).roundToDouble() / 100;

/// Message sender types for analytics
class MessageSender {
  static const String user = 'user';
  static const String soko = 'soko';
}

/// Message types for analytics
class MessageType {
  static const String text = 'text';
  static const String image = 'image';
  static const String voice = 'voice';
}

/// Theme types for analytics
class AnalyticsTheme {
  static const String light = 'light';
  static const String dark = 'dark';
}

/// Map context types for analytics
class MapContext {
  static const String chat = 'chat';
  static const String list = 'list';
  static const String search = 'search';

  /// PROD-3219: the dedicated Map page (`/map`), distinct from the chat
  /// places-modal (`chat`) and the list-cover / zine map embeds.
  static const String mapPage = 'map_page';
}

/// Share method types for analytics
class ShareMethod {
  static const String copyLink = 'copy_link';
  static const String social = 'social';
  static const String whatsapp = 'whatsapp';
  static const String email = 'email';
  static const String other = 'other';
}

/// PROD-3168: standardized `entry_point` values for the chat/discover/create
/// entry events. One property answers "which button produced the engagement".
/// Reuse these constants at call sites instead of raw strings.
class EntryPoint {
  /// Home top chat composer.
  static const String homeInput = 'home_input';

  /// Home top pink "create" box.
  static const String homeTopPink = 'home_top_pink';

  /// Home bottom-of-feed pill ("Adiciona à Soko" / "Fala com a Soko").
  static const String homeBottom = 'home_bottom';

  /// Home "Descobre a cidade" purple discover pill.
  static const String homePurpleButton = 'home_purple_button';

  /// Bottom-nav tab.
  static const String navTab = 'nav_tab';

  /// Discover entry via the map button.
  static const String mapButton = 'map_button';

  /// In-chat "Criar um plano" chip.
  static const String chatChip = 'chat_chip';

  /// Chat opened by resuming a session from the sidebar history.
  static const String sidebar = 'sidebar';

  /// Opened via a deep link.
  static const String deepLink = 'deep_link';
}

/// PROD-3168: bottom-nav tab identifiers for `nav_tab_change`.
class NavTab {
  static const String chat = 'chat';
  static const String library = 'library';
  static const String home = 'home';
  static const String create = 'create';
  static const String profile = 'profile';
}

/// PROD-3168: `option` values for `create_option_selected` (the CreateMenuSheet).
class CreateOption {
  static const String googleMapsImport = 'google_maps_import';
  static const String suggestEvent = 'suggest_event';
  static const String instagramLink = 'instagram_link';
  static const String newZine = 'new_zine';
  static const String newMemory = 'new_memory';
}

/// PROD-3168: entity types for the shared-by attribution events.
class SharedByEntity {
  static const String event = 'event';
  static const String venue = 'venue';
}

/// PROD-3168: viewer role for the shared-by attribution events.
class ViewerRole {
  static const String admin = 'admin';
  static const String user = 'user';
}

/// Pre-auth page types for analytics
class PreAuthPage {
  static const String landing = 'landing';
  static const String login = 'login';
  static const String signup = 'signup';
  static const String forgotPassword = 'forgot_password';
}

/// Onboarding step identifiers for analytics
class OnboardingStep {
  static const String hello1 = 'hello_1';
  static const String hello2 = 'hello_2';
  static const String hello3 = 'hello_3';
  static const String hello4 = 'hello_4';
}

/// Onboarding action types for analytics
class OnboardingAction {
  static const String view = 'view';
  static const String next = 'next';
  static const String skip = 'skip';
}

/// Location permission action types for analytics
class LocationPermissionAction {
  static const String promptShown = 'prompt_shown';
  static const String allowed = 'allowed';
  static const String denied = 'denied';
  static const String skipped = 'skipped';
  static const String settingsOpened = 'settings_opened';
}

/// Location permission status types for analytics
class PermissionStatus {
  static const String granted = 'granted';
  static const String denied = 'denied';
  static const String restricted = 'restricted';
  static const String limited = 'limited';
}

/// Auth page types for analytics
class AuthPage {
  static const String login = 'login';
  static const String signup = 'signup';
}

/// Auth prompt action types for analytics
class AuthPromptAction {
  static const String view = 'view';
  static const String methodSelected = 'method_selected';
  static const String dismissed = 'dismissed';
}

/// Auth method types for analytics
class AuthMethod {
  static const String google = 'google';
  static const String apple = 'apple';
  static const String phone = 'phone';
  static const String email = 'email';
  static const String guest = 'guest';
}

/// Auth referrer types for analytics
class AuthReferrer {
  static const String onboarding = 'onboarding';
  static const String deepLink = 'deep_link';
  static const String direct = 'direct';

  // Guest prompt referrers — distinguish by source feature
  static const String guestSaveChat = 'guest_save_chat';
  static const String guestSaveMap = 'guest_save_map';
  static const String guestFollowList = 'guest_follow_list';
  static const String guestShare = 'guest_share';
  static const String guestSaveList = 'guest_save_list';
  static const String guestListBanner = 'guest_list_banner';
  static const String guestListNotFound = 'guest_list_not_found';
  static const String guestMapPastSearches = 'guest_map_past_searches';
  static const String guestMemories = 'guest_memories';
  static const String guestChatHistory = 'guest_chat_history';
  static const String guestProfile = 'guest_profile';
  static const String guestListItemDetail = 'guest_list_item_detail';
  static const String guestListBlurCta = 'guest_list_blur_cta';
  static const String guestFeedPeople = 'guest_feed_people';
  static const String guestListsHubYourLists = 'guest_lists_hub_your_lists';
  static const String guestListsHubFollowing = 'guest_lists_hub_following';
  static const String guestListsHubShowMore = 'guest_lists_hub_show_more';
  static const String guestChatSend = 'guest_chat_send';
  static const String guestSetReminder = 'guest_set_reminder';
  // Map "De quem" scope gate — a guest taps As tuas / Que segues, which
  // require a real account (scope=yours/following → 422 for guests).
  static const String guestMapScope = 'guest_map_scope';
  // Notifications inbox gate (PROD-3142) — a guest taps the inbox button;
  // /menu/notifications is a protected route, so the action needs a real
  // account. Gated at the button so the guest gets the prompt sheet
  // instead of the router bouncing them to /login.
  static const String guestNotifications = 'guest_notifications';
  // My-reminders sheet gate (PROD-3142) — the sheet reads
  // /users/me/events-with-reminders, which a guest can't call. Ungated,
  // the guest got the sheet's "Couldn't load your reminders" error state
  // instead of a prompt to sign in.
  static const String guestReminders = 'guest_reminders';
  // Help-us CTAs gate (PROD-4319) — a guest taps "import your Maps" or "send a
  // post" on the Discovery new-city hero or the feed's `create_cta` block. Both
  // submit to endpoints that reject a guest token (`Lists` write and
  // `/instagram/share`), and a guest carries a REAL bearer token, so ungated
  // the guest filled the sheet in and got a generic 401 error with no route to
  // sign in.
  static const String guestHelpUsContribute = 'guest_help_us_contribute';
  // Fallback for [GuestFeaturePlaceholder] when the host screen doesn't
  // pass its own `onSignUp`. Deliberately generic — a caller that wants
  // funnel attribution should supply a specific referrer instead.
  static const String guestFeaturePlaceholder = 'guest_feature_placeholder';

  // Bottom-nav gate referrers (guest taps Início / Zines / Criar — the
  // route renders [GuestGateScreen] in place of the real content).
  static const String guestGateHome = 'guest_gate_home';
  static const String guestGateZines = 'guest_gate_zines';
  static const String guestGateCreate = 'guest_gate_create';

  // Persistent guest banner (PROD-2072 — web only). Distinct from the
  // gate referrers above so the auth funnel can attribute conversions
  // that originate from the chrome banner separately from gate-page CTAs.
  static const String guestBannerLogin = 'guest_banner_login';
}

/// Lists hub section constants for analytics
class ListHubSection {
  static const String byYou = 'by_you';
  static const String bySoko = 'by_soko';
  static const String following = 'following';
  static const String recommended = 'recommended';
  static const String searchYourLists = 'search_your_lists';
  static const String searchBySoko = 'search_by_soko';
  static const String searchOther = 'search_other';
  static const String filtered = 'filtered';
}

/// Provider for the canonical [MetaDestination] instance. The
/// [unifiedAnalyticsProvider] reads this so its adapters map and any other
/// code that needs the destination (notably [MetaAnalyticsService]) share
/// the same instance.
final metaDestinationProvider = Provider<MetaDestination>((ref) {
  return MetaDestination();
});

/// Provider for [MetaAnalyticsService]. Reads [metaDestinationProvider] for
/// the destination so init() can flip the same instance held by
/// [unifiedAnalyticsProvider]'s adapters map.
final metaAnalyticsServiceProvider = Provider<MetaAnalyticsService>((ref) {
  return MetaAnalyticsService(
    destination: ref.watch(metaDestinationProvider),
    enabled: EnvironmentConfig.metaEnabled,
  );
});

/// Provider for the canonical TikTok destination. On mobile this is the
/// SDK-backed [TikTokDestination]; on web it's the pixel-backed
/// [TikTokWebDestination]. The unified provider reads this so both
/// runtimes route through the same `Dest.tiktok` slot.
final tiktokDestinationProvider = Provider<AnalyticsDestination>((ref) {
  return kIsWeb ? TikTokWebDestination() : TikTokDestination();
});

/// Provider for [TikTokAnalyticsService] (mobile only — web has no ATT
/// gate, no SDK boot). Reads [tiktokDestinationProvider] and casts to
/// [TikTokDestination] since the mobile path always instantiates that.
final tiktokAnalyticsServiceProvider = Provider<TikTokAnalyticsService>((ref) {
  final destination = ref.watch(tiktokDestinationProvider);
  return TikTokAnalyticsService(
    destination: destination is TikTokDestination
        ? destination
        : TikTokDestination(),
    enabled: EnvironmentConfig.tiktokEnabled,
    appId: EnvironmentConfig.tiktokAppId,
    ttAppId: EnvironmentConfig.tiktokTtAppId,
    accessToken: EnvironmentConfig.tiktokAccessToken,
  );
});

/// Canonical AppsFlyer destination. On web (or when creds are absent) the
/// client is null and the destination is fully inert. The unified provider
/// and [appsflyerAnalyticsServiceProvider] share this instance so the service
/// can open the same destination's gate on startSDK().
final appsflyerDestinationProvider = Provider<AppsflyerDestination>((ref) {
  // iOS additionally requires the numeric App Store ID; without it AF can't
  // init on iOS, so no-op rather than construct a broken client.
  final missingIosAppId =
      !kIsWeb &&
      defaultTargetPlatform == TargetPlatform.iOS &&
      EnvironmentConfig.appsflyerIosAppId.isEmpty;
  if (kIsWeb ||
      !EnvironmentConfig.appsflyerEnabled ||
      EnvironmentConfig.appsflyerDevKey.isEmpty ||
      missingIosAppId) {
    return AppsflyerDestination(client: null);
  }
  return AppsflyerDestination(
    client: RealAppsflyerClient(
      devKey: EnvironmentConfig.appsflyerDevKey,
      iosAppId: EnvironmentConfig.appsflyerIosAppId,
      oneLinkDomain: EnvironmentConfig.appsflyerOneLinkDomain,
    ),
  );
});

/// AppsFlyer service (mobile only). Reads [appsflyerDestinationProvider] so
/// init() opens the same destination instance the adapters map holds.
final appsflyerAnalyticsServiceProvider = Provider<AppsflyerAnalyticsService?>((
  ref,
) {
  final destination = ref.watch(appsflyerDestinationProvider);
  final client = destination.client; // getter added in Task 4
  if (client == null) return null;
  return AppsflyerAnalyticsService(
    client: client,
    destination: destination,
    enabled: EnvironmentConfig.appsflyerEnabled,
  );
});

/// Provider for the unified analytics service
final unifiedAnalyticsProvider = Provider<UnifiedAnalyticsService>((ref) {
  final firebase = ref.watch(analyticsServiceProvider);
  final backend = ref.watch(backendAnalyticsServiceProvider);
  final posthog = ref.watch(postHogServiceProvider);
  final utmHolder = ref.watch(sessionUtmHolderProvider);
  final feedVariantHolder = ref.watch(feedVariantHolderProvider);
  final metaDestination = ref.watch(metaDestinationProvider);
  final tiktokDestination = ref.watch(tiktokDestinationProvider);
  final appsflyerDestination = ref.watch(appsflyerDestinationProvider);

  final adapters = <Dest, AnalyticsDestination>{
    Dest.firebase: FirebaseDestination(firebase),
    Dest.posthog: PostHogDestination(posthog),
    Dest.backend: BackendDestination(backend),
    Dest.sentry: SentryDestination(),
    Dest.meta: metaDestination,
    Dest.tiktok: tiktokDestination,
    Dest.appsflyer: appsflyerDestination,
  };

  return UnifiedAnalyticsService(
    adapters,
    firebase: firebase,
    utmHolder: utmHolder,
    feedVariantHolder: feedVariantHolder,
  );
});

/// Unified analytics facade that dispatches events to destinations
/// based on the routing defined in [eventRegistry].
///
/// ## Architecture
///
/// Each event is defined once in the [eventRegistry] with its destination set.
/// The [_dispatch] method fans out to all configured destinations.
/// Adding or removing a destination is a one-line config change in the registry.
///
/// ## Special Methods (bypass dispatch)
///
/// - [setUserId] — uses identify()/reset() on adapters
/// - [initialize] — Firebase-specific initialization
/// - [observer] — Firebase GoRouter observer
/// - [trackExperimentExposure] — once-per-session guard
///
/// ## Usage
/// ```dart
/// final analytics = ref.read(unifiedAnalyticsProvider);
/// await analytics.trackLogout(); // Dispatched to all registered destinations
/// ```
class UnifiedAnalyticsService {
  final Map<Dest, AnalyticsDestination> _adapters;
  final AnalyticsService _firebase;
  final SessionUtmHolder? _utmHolder;
  final FeedVariantHolder? _feedVariantHolder;
  final AnalyticsAuthContext _authContext;
  Future<void> _identityWork = Future<void>.value();
  int _pendingIdentityChanges = 0;
  bool _identityResolved = false;
  String? _desiredUserId;
  final Set<Dest> _identityFailures = {};

  /// Capture before an async operation; pass it to the confirmed event.
  /// Nullable for analytics test doubles that do not model identity.
  AnalyticsActionContext? get actionContext => _authContext.current;

  bool isActionContextCurrent(AnalyticsActionContext? context) =>
      context == null || _authContext.isCurrent(context);

  /// Called synchronously by AuthNotifier before publishing its next state.
  /// A real token without an available account remains unknown until the
  /// profile resolves; neither a cached SDK ID nor a guest token proves auth.
  void updateAuthContext({
    required bool initialized,
    required bool authenticated,
    String? userId,
  }) {
    final authState = !initialized || (authenticated && userId == null)
        ? AnalyticsAuthState.unknown
        : authenticated
        ? AnalyticsAuthState.loggedIn
        : AnalyticsAuthState.loggedOut;
    _authContext.update(authState, userId);
    if (authState == AnalyticsAuthState.unknown) return;
    final account = authenticated ? userId : null;
    if (!_identityResolved || _desiredUserId != account) {
      unawaited(_scheduleIdentity(account));
    }
  }

  Future<void> _scheduleIdentity(
    String? userId, [
    Map<String, dynamic> traits = const {},
  ]) {
    final previous = _desiredUserId;
    _desiredUserId = userId;
    _identityResolved = true;
    _pendingIdentityChanges++;
    // Serialize reset/identify across quick account switches. A guest→account
    // identify keeps the anonymous journey; account A→B resets before identify.
    _identityWork = _identityWork.then((_) async {
      try {
        for (final entry in _adapters.entries) {
          final adapter = entry.value;
          try {
            if (userId == null ||
                _identityFailures.contains(entry.key) ||
                (previous != null && previous != userId)) {
              await adapter.reset();
            }
            if (userId != null) await adapter.identify(userId, traits);
            _identityFailures.remove(entry.key);
          } catch (e) {
            _identityFailures.add(entry.key);
            // Analytics must never turn successful authentication into failure.
            if (kDebugMode) {
              debugPrint('Analytics: identity ${adapter.name} failed: $e');
            }
          }
        }
      } finally {
        _pendingIdentityChanges--;
      }
    });
    return _identityWork;
  }

  /// Events that get session UTM params auto-merged into their properties.
  static const _utmEnrichedEvents = {
    'list_open',
    'list_item_click',
    'list_follow',
    'list_link_opened',
    'external_click',
    'login',
    'sign_up',
    'auth_prompt',
    // PROD-2564: the Weekly Bundle deep link forwards utm_*/ref; enriching the
    // open event lets Growth slice deep-link landings/failures by `utm_source`
    // (e.g. `push`), where push-driven failures matter most.
    'weekly_bundle_open',
    // PROD-2566: the Profiling-Start deep link forwards utm_*/ref. Enrich both
    // the started event (the campaign's conversion) and the deep-link funnel
    // event so Growth can slice landings/sheets/re-runs by `utm_source`.
    'profiling_started',
    'profiling_deep_link',
    // PROD-2742: the `/yours` deep link forwards utm_*/ref — enrich the funnel
    // event so Growth can slice deep-link landings by `utm_source` (e.g. push).
    'yours_deep_link',
    // PROD-3326: same for the `/map` deep link.
    'map_deep_link',
    // Profile share URLs carry utm_source=soko_app / utm_campaign=profile_share
    // (profile_links.dart). Enriching the open event is what makes a shared
    // profile's landings attributable at all — zines had this via
    // `list_link_opened`, profiles had nothing.
    'profile_open',
  };

  /// PROD-4007 (D46) — Discovery events that carry which home page produced
  /// them, so a before/after comparison across the v1→v2 flip is readable
  /// rather than confounded with seasonality.
  ///
  /// Scoped to the Discovery surface deliberately: a global stamp would put the
  /// property on hundreds of unrelated events where it means nothing.
  ///
  /// Not an A/B split — D47 is explicit that the rollout is a confidence ramp,
  /// not a measured experiment. This ships because it costs nothing and makes a
  /// post-hoc look possible.
  static const _feedVariantEvents = {
    // PROD-4423 — the exposure event. Stamped here rather than passed by its
    // caller for the reason `_dispatch` gives below: the variant must be the
    // same value across every event in the comparison, and `FeedVariantHolder`
    // is the one place that reads it.
    'feed_exposed',
    // PROD-4436 — the commit beat, `feed_exposed`'s denominator. It MUST be
    // stamped from the same holder as `feed_exposed`, or the abandonment rate
    // (exposed ÷ committed) would divide two different definitions of "v2".
    'feed_variant_committed',
    'discovery_shelf_viewed',
    'discovery_shelf_card_clicked',
    'discovery_shelf_see_more_clicked',
    'discovery_history_card_clicked',
  };

  UnifiedAnalyticsService(
    this._adapters, {
    required AnalyticsService firebase,
    SessionUtmHolder? utmHolder,
    FeedVariantHolder? feedVariantHolder,
    AnalyticsAuthContext? authContext,
  }) : _firebase = firebase,
       _utmHolder = utmHolder,
       _feedVariantHolder = feedVariantHolder,
       _authContext = authContext ?? AnalyticsAuthContext();

  // ============ CENTRAL DISPATCH ============

  /// Dispatch an event to all destinations registered in [eventRegistry].
  ///
  /// For events in [_utmEnrichedEvents], session-level UTM params from
  /// [SessionUtmHolder] are auto-merged into properties (event-level
  /// properties take precedence over session UTM).
  ///
  /// Fire-and-forget — never blocks UI, never throws.
  Future<void> _dispatch(
    String event, [
    Map<String, dynamic> properties = const {},
    AnalyticsActionContext? actionContext,
    Map<String, dynamic> productProperties = const {},
  ]) {
    final context = actionContext ?? _authContext.current;
    if (!_authContext.isCurrent(context)) return Future<void>.value();
    final destinations = eventRegistry[event];
    if (destinations == null) {
      if (kDebugMode) {
        debugPrint('Analytics: Unknown event "$event" — not in registry');
      }
      return Future<void>.value();
    }

    // Auto-merge session UTM for campaign-attributed events.
    //
    // Copy into a fresh mutable map before stamping `actor` below.
    // `_mergeSessionUtm` returns the caller's `properties` map unchanged for
    // non-UTM events (and for UTM events with no active session UTM), and that
    // map is frequently the immutable default `const {}` from a bare
    // no-properties dispatch call (e.g. trackLogout dispatching 'logout').
    // (Wording matters: the contract checker parses dispatch call sites
    // textually, so this comment must not spell one out with a quoted name.)
    // Mutating it threw `UnsupportedError: Cannot modify unmodifiable map`,
    // which propagated out of the awaited `trackLogout()` in AuthNotifier.logout
    // and stranded the sign-out flow (dead button, no `logout` event) — see the
    // 1.1.20 regression. The copy restores this method's "never throws" contract.
    final mergedProps = Map<String, dynamic>.from(
      _mergeSessionUtm(event, properties),
    );

    // PROD-3207 (tracking-spec §1.3): stamp `actor` on every event so system
    // events (impressions, fallbacks, diagnostics) can never be counted as
    // user activity. Derived from the contract's `level` field via
    // kSystemActorEvents (CI-synced). Forced here so callers can't mislabel.
    mergedProps['actor'] = kSystemActorEvents.contains(event)
        ? 'system'
        : 'user';

    // PROD-4007 (D46): stamp which home page produced this Discovery event.
    // Forced here rather than passed by callers for the same reason `actor` is
    // — a per-call-site property on a dozen shelf widgets would drift, and the
    // one thing this property must be is consistent across the flip it exists
    // to measure. `putIfAbsent` so an explicit caller value still wins.
    if (_feedVariantHolder != null && _feedVariantEvents.contains(event)) {
      mergedProps.putIfAbsent('feed_variant', () => _feedVariantHolder.label);
    }

    Future<void> send() {
      // Identity may have changed while an SDK identify/reset was in flight.
      if (!_authContext.isCurrent(context)) return Future<void>.value();
      var posthogCapture = Future<void>.value();
      for (final dest in destinations) {
        final adapter = _adapters[dest];
        if (adapter == null || _identityFailures.contains(dest)) continue;
        final payload = <String, dynamic>{
          ...mergedProps,
          // Keep application identity and product context out of ad adapters.
          if (dest == Dest.posthog || dest == Dest.backend) ...{
            ...productProperties,
            ...context.properties,
          },
        };
        Future<void> deliver() async {
          try {
            await adapter.track(event, payload);
          } catch (e) {
            if (kDebugMode) {
              debugPrint('Analytics: ${adapter.name} failed for "$event": $e');
            }
          }
        }

        final delivery = deliver();
        if (dest == Dest.posthog) {
          posthogCapture = delivery;
        } else {
          unawaited(delivery);
        }
      }
      // Logout waits only for SDK capture ordering, never a backend HTTP send.
      return posthogCapture;
    }

    // Keep the normal capture path immediate. During identity work, wait for
    // SDK ordering without blocking rendering or retaining stale completions.
    return _pendingIdentityChanges == 0
        ? send()
        : _identityWork.then((_) => send());
  }

  /// Merge session UTM params into event properties for whitelisted events.
  ///
  /// Event-level properties take precedence (spread last).
  Map<String, dynamic> _mergeSessionUtm(
    String event,
    Map<String, dynamic> properties,
  ) {
    if (!_utmEnrichedEvents.contains(event)) return properties;

    final utm = _utmHolder?.current;
    if (utm == null || utm.isEmpty) return properties;

    // UTM goes first so event-level properties can override
    return {...utm, ...properties};
  }

  // ============ SESSION UTM ACCESS ============

  /// Whether the current session has campaign attribution (UTM or referrer).
  bool get hasSessionAttribution => _utmHolder?.hasAttribution ?? false;

  /// The document.referrer captured for this session (web only).
  String? get sessionReferrer => _utmHolder?.referrer;

  // ============ SPECIAL: Observer for GoRouter ============

  /// Navigator observer for automatic screen tracking with GoRouter.
  NavigatorObserver get observer => _firebase.observer;

  // ============ INITIALIZATION ============

  /// Initialize analytics (call after Firebase.initializeApp)
  Future<void> initialize() async {
    await _firebase.initialize();
  }

  // ============ USER IDENTITY (bypasses dispatch) ============

  /// Set user ID for analytics (call after login).
  ///
  /// [userProperties] are forwarded to PostHog as person properties
  /// (e.g., `is_admin`) for feature flag targeting.
  Future<void> setUserId(
    String? userId, {
    Map<String, Object>? userProperties,
  }) async {
    updateAuthContext(
      initialized: true,
      authenticated: userId != null,
      userId: userId,
    );
    if (_pendingIdentityChanges == 0 || (userProperties?.isNotEmpty ?? false)) {
      // Explicit refreshes must still reload flags/person traits for the same
      // account. Coalesce only an already pending lifecycle identification.
      await _scheduleIdentity(userId, userProperties ?? const {});
    } else {
      await _identityWork;
    }
  }

  /// Set user properties
  Future<void> setUserProperty({
    required String name,
    required String? value,
  }) async {
    await _firebase.setUserProperty(name: name, value: value);
  }

  /// Meta Advanced Matching (PROD-3478): forward raw email/phone to the Meta
  /// destination ONLY — the native Meta SDK hashes them on-device.
  ///
  /// Deliberately NOT routed through [setUserId]'s traits: those fan out to
  /// every adapter, and PostHogDestination forwards all traits as person
  /// properties — the app must never send client-side PII to PostHog
  /// (email/phone person props are backend-owned).
  Future<void> setAdvancedMatchingData({String? email, String? phone}) async {
    final meta = _adapters[Dest.meta];
    if (meta is MetaDestination) {
      await meta.setAdvancedMatchingData(email: email, phone: phone);
    }
  }

  // ============ AUTH EVENTS ============

  /// Track user login (Firebase + PostHog)
  Future<void> trackLogin({required String method}) async {
    _dispatch('login', {'method': method});
  }

  /// Track user sign up (Firebase + PostHog)
  Future<void> trackSignUp({required String method}) async {
    _dispatch('sign_up', {'method': method});
  }

  /// Track phone-OTP send attempt (PROD-2632, Backend + PostHog).
  ///
  /// Fired after every `POST /auth/phone/start` response so we can
  /// measure WhatsApp-first adoption + the SMS-allowlist hit rate.
  /// [channelRequested] is what the client asked for; [channelResponse]
  /// is what the server actually attempted (echoed in
  /// `PhoneStartResponse.channel`). [status] is the response status —
  /// one of `sent` / `region_unsupported` / `channel_unavailable`.
  Future<void> trackOtpSend({
    required String channelRequested,
    required String channelResponse,
    required String status,
    required bool smsFallbackAvailable,
  }) async {
    _dispatch('otp_send', {
      'channel_requested': channelRequested,
      'channel_response': channelResponse,
      'status': status,
      'sms_fallback_available': smsFallbackAvailable,
    });
  }

  /// Track user tap on the "Send via SMS" link on the OTP screen
  /// (PROD-2632, Backend + PostHog). [triggeredBy] is `user_tap` for a
  /// raw tap on the always-visible SMS link, or `timeout` when the tap
  /// happened after the 30s WhatsApp-silent-fail nudge.
  Future<void> trackOtpFallbackSms({required String triggeredBy}) async {
    _dispatch('otp_fallback_sms', {'triggered_by': triggeredBy});
  }

  /// Track user logout/sign out (Firebase + Backend + PostHog)
  ///
  /// Dispatches the event, then resets identity on all adapters.
  Future<void> trackLogout() async {
    await _dispatch('logout');
    await setUserId(null);
  }

  // ============ APP LIFECYCLE ============

  /// Track app open event (Backend + PostHog)
  Future<void> trackAppOpen({String? authMethod}) async {
    _dispatch('app_open', {if (authMethod != null) 'auth_method': authMethod});
  }

  /// One per foregrounding — cold start or resume — after the doors have
  /// reported in (`AppEntryTracker`, analytics/app_entry.dart). `utm_*` here
  /// are THIS entry's link only: `app_entry` is deliberately NOT in
  /// `_utmEnrichedEvents`, so it never inherits the sticky session UTMs.
  /// PostHog-only (backend registry pending). Tier 2 of the attribution
  /// fix order; scope in docs/investigations/context/app-entry-scope.md.
  Future<void> trackAppEntry({
    required String entryId,
    required String entryType,
    required bool isColdStart,
    int? backgroundSeconds,
    String? linkHost,
    String? linkPath,
    String? pushRoute,
    Map<String, String> utm = const {},
  }) async {
    _dispatch('app_entry', {
      'entry_id': entryId,
      'entry_type': entryType,
      'is_cold_start': isColdStart,
      if (backgroundSeconds != null) 'background_seconds': backgroundSeconds,
      if (linkHost != null) 'link_host': linkHost,
      if (linkPath != null) 'link_path': linkPath,
      if (pushRoute != null) 'push_route': pushRoute,
      if (utm['utm_source'] != null) 'utm_source': utm['utm_source'],
      if (utm['utm_medium'] != null) 'utm_medium': utm['utm_medium'],
      if (utm['utm_campaign'] != null) 'utm_campaign': utm['utm_campaign'],
      if (utm['utm_content'] != null) 'utm_content': utm['utm_content'],
      if (utm['utm_term'] != null) 'utm_term': utm['utm_term'],
    });
  }

  /// Track a login/landing page view (Backend + PostHog, unauthenticated).
  /// PROD-3168: renamed from `page_open` (which only ever fired here) so the
  /// name is honest — general navigation is covered by `nav_tab_change` and
  /// `screen_view`. `page` ∈ PreAuthPage (landing/login/signup/...).
  Future<void> trackLoginPageView({
    required String page,
    String? referrer,
  }) async {
    _dispatch('login_page_view', {
      'page': page,
      if (referrer != null) 'referrer': referrer,
    });
  }

  // ============ NAVIGATION EVENTS ============

  /// PROD-3168: the user switched bottom-nav tabs. Gives per-tab reach and the
  /// prior tab so we can see navigation flows. `tab`/`fromTab` ∈ NavTab.
  Future<void> trackNavTabChange({required String tab, String? fromTab}) async {
    _dispatch('nav_tab_change', {
      'tab': tab,
      if (fromTab != null) 'from_tab': fromTab,
    });
  }

  /// PROD-3168: a conversation was opened. Home input and the Chat nav tab open
  /// the SAME conversation — one event, distinguished by `entryPoint` (∈
  /// EntryPoint). Funnels to `message_sent_user`. Sidebar resumes also emit
  /// `chat_history_open` (which carries session_id) — see PROD-3168.
  Future<void> trackChatOpen({
    required String entryPoint,
    String? sessionId,
  }) async {
    _dispatch('chat_open', {
      'entry_point': entryPoint,
      if (sessionId != null) 'session_id': sessionId,
    });
  }

  /// PROD-3168: the "Discover the city" surface was opened. Distinct from the
  /// Library tab (different surface). Fires even when no query is typed, so it
  /// is separable from `search`. `entryPoint` ∈ EntryPoint.
  Future<void> trackDiscoverOpen({required String entryPoint}) async {
    _dispatch('discover_open', {'entry_point': entryPoint});
  }

  /// PROD-3168: the Create / "Adiciona à Soko" menu was opened. The only entry
  /// that leads to L3, so `entryPoint` (∈ EntryPoint) is the highest-value
  /// breakdown of the three entry events.
  Future<void> trackCreateOpen({required String entryPoint}) async {
    _dispatch('create_open', {'entry_point': entryPoint});
  }

  /// PROD-3507: the in-chat composer pill (labelled "Turn into a Zine" to
  /// users; a list internally) was tapped, entering the create-list-from-
  /// conversation flow. Distinct from `create_open` (which fires when the
  /// CreateMenuSheet opens) — this pill bypasses that menu. `cardCount` =
  /// active conversation cards available at tap.
  Future<void> trackCreateListFromChat({required int cardCount}) async {
    _dispatch('create_list_from_chat', {'card_count': cardCount});
  }

  /// PROD-3168: the user picked an option inside the CreateMenuSheet.
  /// `option` ∈ CreateOption; `entryPoint` ∈ EntryPoint (how the sheet was opened).
  Future<void> trackCreateOptionSelected({
    required String option,
    String? entryPoint,
  }) async {
    _dispatch('create_option_selected', {
      'option': option,
      if (entryPoint != null) 'entry_point': entryPoint,
    });
  }

  /// PROD-3168: a "Shared by X" attribution rendered on an event/venue detail.
  /// `entityType` ∈ SharedByEntity; `viewerRole` ∈ ViewerRole. `sharersCount`
  /// is set for the multi-sharer variant.
  Future<void> trackSharedByView({
    required String entityType,
    required String entityId,
    required String viewerRole,
    String? sharedByUserId,
    int? sharersCount,
  }) async {
    _dispatch('shared_by_view', {
      'entity_type': entityType,
      'entity_id': entityId,
      'viewer_role': viewerRole,
      if (sharedByUserId != null) 'shared_by_user_id': sharedByUserId,
      if (sharersCount != null) 'sharers_count': sharersCount,
    });
  }

  /// PROD-3168: the user tapped a "Shared by X" attribution (profile link or
  /// the sharers sheet). Tap is admin-only today. `entityType` ∈ SharedByEntity;
  /// `viewerRole` ∈ ViewerRole.
  Future<void> trackSharedByClick({
    required String entityType,
    required String entityId,
    required String viewerRole,
    String? sharedByUserId,
    int? sharersCount,
  }) async {
    _dispatch('shared_by_click', {
      'entity_type': entityType,
      'entity_id': entityId,
      'viewer_role': viewerRole,
      if (sharedByUserId != null) 'shared_by_user_id': sharedByUserId,
      if (sharersCount != null) 'sharers_count': sharersCount,
    });
  }

  /// Track opening the map view (Backend + PostHog)
  Future<void> trackOpenMap({required String context, String? listId}) async {
    _dispatch('open_map', {
      'context': context,
      if (listId != null) 'list_id': listId,
    });
  }

  /// PROD-2016: a map pin tooltip opened for the user. Fires after a
  /// 300 ms stability filter (handled in the shell) so rapid hover
  /// sweeps don't flood PostHog. PostHog-only — no backend endpoint
  /// for this event yet.
  Future<void> trackMapPinTooltipOpen({
    required String itemId,
    required String itemType,
    required String source,
    required String mapContext,
  }) async {
    _dispatch('map_pin_tooltip_open', {
      'item_id': itemId,
      'item_type': itemType,
      'source': source,
      'map_context': mapContext,
    });
  }

  /// PROD-2016: user opened an item's detail from the map. Originally the
  /// tooltip's "View details" button (embeds); PROD-3219 also fires it from the
  /// dedicated Map page — a pin tap (`surface:'pin'`) or a result-card tap
  /// (`surface:'grid'`/`'carousel'`), with `map_context: MapContext.mapPage`.
  /// Fires synchronously on tap (no debounce). PostHog-only.
  Future<void> trackMapPinViewDetailsClick({
    required String itemId,
    required String itemType,
    required String mapContext,
    String? destinationRoute,
    String? surface,
  }) async {
    _dispatch('map_pin_view_details_click', {
      'item_id': itemId,
      'item_type': itemType,
      'map_context': mapContext,
      if (destinationRoute != null) 'destination_route': destinationRoute,
      if (surface != null) 'surface': surface,
    });
  }

  /// PROD-2671: a filter changed on the Map page. `filter` is the control
  /// ('source' | 'type' | 'date' | 'tema' | 'keyword' | 'full_mode');
  /// `value` is its new value (omitted for free-text keyword). PostHog-only.
  Future<void> trackMapFilterChange({
    required String filter,
    String? value,
  }) async {
    _dispatch('map_filter_change', {
      'filter': filter,
      if (value != null) 'value': value,
    });
  }

  /// Round a coordinate to 3 decimal places (~110m). PROD-3219: coarsens
  /// searched-area centres so `map_search` doesn't ship precise points and
  /// nearby searches collapse together for coverage-gap analysis.
  double _roundCoord3(double v) => (v * 1000).roundToDouble() / 1000;

  // ============ FILTERS & LIBRARY TABS (PROD-3209) ============
  // The Map surface keeps its own `map_filter_change` (live dashboards);
  // filter_applied/filters_reset cover the Discovery filter bars.

  /// A filter chip/dropdown selection changed.
  /// [surface] ∈ {discover_events, discover_places}; [filterType] ∈
  /// {when, category}; [selected] false = the chip was toggled OFF.
  void trackFilterApplied({
    required String surface,
    required String filterType,
    required String value,
    bool selected = true,
  }) {
    _dispatch('filter_applied', {
      'surface': surface,
      'filter_type': filterType,
      'value': value,
      'selected': selected,
    });
  }

  /// The clear (✕) chip wiped a surface's filter selection.
  void trackFiltersReset({required String surface, String? filterType}) {
    _dispatch('filters_reset', {
      'surface': surface,
      if (filterType != null) 'filter_type': filterType,
    });
  }

  /// Library (`/yours` hub) search category tab changed.
  /// [tab] ∈ {all, zines, eventos, sitios}.
  void trackLibraryTabChange({required String tab, String? fromTab}) {
    _dispatch('library_tab_change', {
      'tab': tab,
      if (fromTab != null) 'from_tab': fromTab,
    });
  }

  /// PROD-3219: a Map-page search RESOLVED. This is an OUTCOME event — it fires
  /// once results come back (so it can carry `result_count`, including 0), NOT
  /// on every camera settle. `trigger` says why the search ran:
  /// 'initial' | 'area' | 'filter' | 'shortcut' | 'keyword' | 'pan' |
  /// 'selection' (PROD-3500 — an entity pick clearing an active keyword; it
  /// used to masquerade as 'keyword').
  /// `center_lat`/`center_lng` (rounded ~110m) locate the searched area so we
  /// can spot regions that return nothing (cities/neighbourhoods we don't cover
  /// yet). The caller dedupes on a coarse center+zoom bucket and drops searches
  /// interrupted by fresh camera motion — see `map_screen.dart`. PostHog-only.
  Future<void> trackMapAreaSearched({
    required String trigger,
    required double centerLat,
    required double centerLng,
    required int resultCount,
    double? radiusM,
    double? zoom,
  }) async {
    _dispatch('map_area_searched', {
      'trigger': trigger,
      'center_lat': _roundCoord3(centerLat),
      'center_lng': _roundCoord3(centerLng),
      'result_count': resultCount,
      if (radiusM != null) 'radius_m': radiusM,
      if (zoom != null) 'zoom': zoom,
    });
  }

  /// PROD-2993: the results drawer reached its `half` snap, so the map started
  /// highlighting the pins for the cards in view.
  ///
  /// This is the "did anyone actually use the grid↔map link?" number. Fires once
  /// per entry from `peek` — NOT on the `full → half` pass-through, which is the
  /// same session continuing, not a new one. PostHog-only.
  Future<void> trackMapHighlightEnter() async {
    _dispatch('map_highlight_enter', const {});
  }

  /// PROD-2993: the user panned the map away from the searched area while
  /// browsing results, and asked us to search where they'd moved to.
  ///
  /// The counterpart to [trackMapHighlightEnter]: it counts how often the camera
  /// following is being *overridden*. If this is high relative to entries, the
  /// automatic camera is fighting people rather than helping them — which is the
  /// known failure mode of this UI pattern, so it's worth watching. PostHog-only.
  Future<void> trackMapSearchThisArea() async {
    _dispatch('map_search_this_area', const {});
  }

  /// PROD-3499 (map search v2, Decision #34): a past-search row re-executed
  /// successfully — fresh resolve succeeded and the selection was dispatched.
  /// Stale rows (toast + removal) and transient failures don't fire this.
  /// `type` = keyword|venue|event|location|list; `position` = 0-based row
  /// index. PostHog-only.
  Future<void> trackMapPastSearchUsed({
    required String type,
    required int position,
  }) async {
    _dispatch('map_past_search_used', {'type': type, 'position': position});
  }

  /// PROD-3500 (map search v2, Decision #34 / H1): the v2 search bar entered
  /// focused mode. Fires once per open — [MapSearchNotifier.enterFocus] is
  /// idempotent while focused, and this rides behind that same guard, so
  /// keyboard dismissal and re-focus inside an open session don't re-count it.
  /// The denominator of the whole search funnel. PostHog-only.
  Future<void> trackMapSearchOpened() async {
    _dispatch('map_search_opened', const {});
  }

  /// PROD-3500: a row in the typed suggestion dropdown was selected — the core
  /// outcome of the v2 search.
  ///
  /// `type` = keyword|venue|event|location|list (`keyword` = the pinned general
  /// row); `rank` = 0-based VISUAL position in the composed entry list, which
  /// counts the general row and any expander above it; `queryLen` = trimmed
  /// length of the text that produced the list.
  ///
  /// Two counting traps, both by design: the top hit appears TWICE in the list
  /// (Decision #39 — once in the top slot, once inside its domain block), so
  /// one event per logical result means keying on `rank`, not the item id; and
  /// this event covers the dropdown ONLY — a keyword search run any other way
  /// shows up in `map_area_searched{trigger:'keyword'}` instead. PostHog-only.
  Future<void> trackMapSuggestSelected({
    required String type,
    required int rank,
    required int queryLen,
  }) async {
    _dispatch('map_suggest_selected', {
      'type': type,
      'rank': rank,
      'query_len': queryLen,
    });
  }

  /// PROD-3500: a collapsed suggestion block was expanded ("view other …").
  /// Fires on EXPAND only, never on collapse — this measures demand for more
  /// results, and a collapse is not demand. `domain` = venues|events|lists|
  /// locations (`locations` is the client-composed section, not a
  /// `/map/suggest` domain). PostHog-only.
  Future<void> trackMapSuggestExpanded({required String domain}) async {
    _dispatch('map_suggest_expanded', {'domain': domain});
  }

  /// PROD-3652: a domain tag was SELECTED in the focused search bar, scoping
  /// the dropdown to one domain and asking the backend for a deeper page of it.
  ///
  /// `domain` = venues|events|lists|locations (same vocabulary as
  /// [trackMapSuggestExpanded]; `locations` is again the client-composed
  /// section, and again the only one that doesn't hit `/map/suggest`).
  /// `queryLen` = trimmed length of the text at the moment of the tap — often
  /// **0**, because the row is available before anything is typed, and that
  /// zero is a real signal: it separates "narrow these results" from "I know
  /// what kind of thing I want before I start".
  /// `source` = where the tag came from: `tag_row` (a tap here) vs. an entry
  /// point that preselects one (PROD-3653's "Zine" chip). Present from day one
  /// so that ticket adds a value rather than reinterpreting the metric.
  ///
  /// **Select only, never deselect** — same rule and same reason as
  /// `map_suggest_expanded`: a return to the unscoped default is not demand for
  /// a domain, and counting it would read as twice the interest that exists.
  /// PostHog-only.
  Future<void> trackMapSuggestDomainTag({
    required String domain,
    required int queryLen,
    required String source,
  }) async {
    _dispatch('map_suggest_domain_tag', {
      'domain': domain,
      'query_len': queryLen,
      'source': source,
    });
  }

  /// PROD-3500: a query settled with nothing to offer — both lanes done, no
  /// failures, every offered bucket empty. Deduped per query string, so a
  /// refetch of the same text can't re-count it, and a FAILED lane never
  /// reaches here (that shows the retry row, which is a different outcome).
  /// The coverage-gap signal for the suggest corpus. PostHog-only.
  Future<void> trackMapSuggestZeroResults({required int queryLen}) async {
    _dispatch('map_suggest_zero_results', {'query_len': queryLen});
  }

  /// PROD-3568 (map search v2, Decision #20/#46): a Zine became the map's
  /// corpus — the payoff event for the whole list-on-map chain.
  ///
  /// Fired from the ONE place every opening passes through
  /// (`MapSearchExecutorImpl.executeList`), so it can't drift from its
  /// producers. `source` = 'suggest'|'history'; `ownership` =
  /// 'own'|'other'|'unknown'; `auth_state` = 'logged_in'|'logged_out'.
  ///
  /// ⚠️ `ownership` MUST be read together with `source` — the two paths know it
  /// to different standards (history compares owner ids and is exact; the
  /// dropdown compares handles, so it can't see a collaborative list and
  /// reports 'unknown' when either handle is missing). See [MapListOwnership].
  ///
  /// Counts opens DISPATCHED, not opens that resolved. The outcome is the
  /// sibling `map_area_searched{trigger:'list'}`, which carries `result_count`;
  /// a `map_list_opened` with no matching one is a list that 404'd and backed
  /// out. PostHog-only.
  Future<void> trackMapListOpened({
    required String listId,
    required String ownership,
    required String authState,
    required String source,
  }) async {
    _dispatch('map_list_opened', {
      'list_id': listId,
      'ownership': ownership,
      'auth_state': authState,
      'source': source,
    });
  }

  /// PROD-3194: a leave-map prompt was shown because its settled boundary
  /// differed meaningfully from the canonical Search Center. These five events
  /// deliberately carry no place names or coordinates; the funnel is useful
  /// without turning map navigation into a location trail.
  Future<void> trackMapLeavePromptImpression() async {
    _dispatch('map_leave_prompt_impression', const {});
  }

  Future<void> trackMapLeavePromptUpdate() async {
    _dispatch('map_leave_prompt_update', const {});
  }

  Future<void> trackMapLeavePromptKeep() async {
    _dispatch('map_leave_prompt_keep', const {});
  }

  Future<void> trackMapLeavePromptDismiss() async {
    _dispatch('map_leave_prompt_dismiss', const {});
  }

  Future<void> trackMapLeavePromptRenavigateAfterKeep() async {
    _dispatch('map_leave_prompt_renavigate_after_keep', const {});
  }

  /// PROD-3219: the Map-page results drawer changed snap. `snap` is the new
  /// position ('peek' | 'half' | 'full'); `previous_snap` is the one it left.
  /// This is the "did users actually open the results grid (half/full)?" number.
  /// PostHog-only.
  Future<void> trackMapDrawerSnapChange({
    required String snap,
    String? previousSnap,
  }) async {
    _dispatch('map_drawer_snap_change', {
      'snap': snap,
      if (previousSnap != null) 'previous_snap': previousSnap,
    });
  }

  /// PROD-3219: the user tapped a co-located ("+N") pin cluster on the Map page,
  /// scoping the drawer to the stacked items. `member_count` is how many were
  /// stacked there. PostHog-only.
  Future<void> trackMapClusterTap({required int memberCount}) async {
    _dispatch('map_cluster_tap', {'member_count': memberCount});
  }

  /// Track opening the lists hub (Backend + PostHog)
  Future<void> trackOpenLists() async {
    _dispatch('open_lists');
  }

  /// Track opening a specific list (Backend + PostHog)
  /// [source] (`deep_link` | `in_app`, decision B3): whether THIS list was
  /// the target of a deep link in the last 60 s (`DeepLinkTargetLatch`),
  /// not whether the process has ever seen a UTM.
  Future<void> trackListOpen({
    required String listId,
    UserList? list,
    String? listName,
    String? source,
    AnalyticsActionContext? actionContext,
  }) async {
    final context = actionContext ?? _authContext.current;
    final listProperties = listOpenAnalyticsProps(list, viewer: context);
    _dispatch(
      'list_open',
      {
        'list_id': listId,
        if (listProperties.containsKey('owner_is_self'))
          'is_own_list': listProperties['owner_is_self'],
        if (listName != null) 'list_name': listName,
        if (source != null) 'source': source,
      },
      context,
      listProperties,
    );
  }

  /// Track a list opened via a shared/external link (Backend + PostHog).
  ///
  /// Fired when a list is opened and the session has campaign attribution
  /// (UTM params or external referrer). UTM props are auto-merged by
  /// [_dispatch] since `list_link_opened` is in [_utmEnrichedEvents].
  Future<void> trackListLinkOpened({
    required String listId,
    UserList? list,
    String? listName,
    String? referrer,
    AnalyticsActionContext? actionContext,
  }) async {
    final context = actionContext ?? _authContext.current;
    final listProperties = listOpenAnalyticsProps(list, viewer: context);
    _dispatch(
      'list_link_opened',
      {
        'list_id': listId,
        if (listName != null) 'list_name': listName,
        if (referrer != null) 'referrer': referrer,
      },
      context,
      listProperties,
    );
  }

  /// Track list tap from hub with section attribution (PostHog only)
  void trackListHubTap({required String section, required String listId}) {
    _dispatch('list_hub_tap', {'section': section, 'list_id': listId});
  }

  /// Track section expand (title tap) in lists hub (PostHog only)
  void trackListHubSectionExpand({required String section}) {
    _dispatch('list_hub_section_expand', {'section': section});
  }

  /// Track opening chat history (Backend + PostHog)
  Future<void> trackChatHistoryOpen({required String sessionId}) async {
    _dispatch('chat_history_open', {'session_id': sessionId});
  }

  /// Track opening memories screen (Backend + PostHog)
  Future<void> trackMemoriesOpen() async {
    _dispatch('memories_open');
  }

  // ============ CHAT EVENTS ============

  /// Track message sent (Firebase + Backend + PostHog)
  /// @deprecated Use [trackMessageSentUser] instead
  Future<void> trackMessageSent({
    required String sender,
    String? messageType,
  }) async {
    _dispatch('message_sent', {
      'sender': sender,
      if (messageType != null) 'message_type': messageType,
    });
  }

  /// Track user message sent (Firebase + Backend + PostHog).
  /// PROD-3209: [turnIndex] is the message's ordinal within the session
  /// (how deep conversations go). Entry-point attribution comes from
  /// joining `chat_open.entry_point` via session_id — not duplicated here.
  ///
  /// `channel: 'app'` is stamped as a constant so an in-app message and a
  /// backend-emitted WhatsApp message (which carries `channel: 'whatsapp'`)
  /// share one `{app, whatsapp}` vocabulary. Before this, the app row left
  /// `channel` empty and the surface was inferred from the field being absent —
  /// fragile, and broken the day a third channel appears.
  Future<void> trackMessageSentUser({
    String? messageType,
    String? sessionId,
    int? turnIndex,
  }) async {
    _dispatch('message_sent_user', {
      'channel': 'app',
      if (messageType != null) 'message_type': messageType,
      if (sessionId != null) 'session_id': sessionId,
      if (turnIndex != null) 'turn_index': turnIndex,
    });
  }

  /// PROD-3209 (negative): the X on a chat result card — routed to the
  /// recommender, never counted as engagement. [query] is the last user
  /// message the dismissed card was answering.
  void trackChatCardDismissed({
    required String entityId,
    required String entityType,
    required int position,
    required String sessionId,
    String? query,
  }) {
    _dispatch('chat_card_dismissed', {
      'entity_id': entityId,
      'entity_type': entityType,
      'position': position,
      'session_id': sessionId,
      if (query != null) 'query': query,
    });
  }

  // ============ REMINDER LIFECYCLE (PROD-3209) ============
  // There is no update operation — the picker diffs selections into
  // creates + cancels, so set/cancelled cover the full client lifecycle.
  // reminder_fired is backend-owned.

  /// One confirmed reminder create (after the API call succeeds).
  void trackReminderSet({
    required String entityId,
    required String entityType,
    required int offsetMinutes,
    String? occurrenceId,
  }) {
    _dispatch('reminder_set', {
      'entity_id': entityId,
      'entity_type': entityType,
      'offset_minutes': offsetMinutes,
      if (occurrenceId != null) 'occurrence_id': occurrenceId,
    });
  }

  /// One confirmed reminder cancel (after the API call succeeds).
  void trackReminderCancelled({required String reminderId, String? entityId}) {
    _dispatch('reminder_cancelled', {
      'reminder_id': reminderId,
      if (entityId != null) 'entity_id': entityId,
    });
  }

  /// PROD-3210: the OS push-permission prompt is actually about to show
  /// (permission was notDetermined when the user tapped). Makes "never
  /// asked" measurable directly instead of inferred from absence.
  void trackPushPromptShown({
    required String source,
    required String platform,
  }) {
    _dispatch('push_prompt_shown', {'source': source, 'platform': platform});
  }

  /// PROD-3209 (negative): dismissed a people suggestion on Find People.
  void trackPeopleSuggestionDismissed({
    required String dismissedPersonId,
    required int position,
  }) {
    _dispatch('people_suggestion_dismissed', {
      'dismissed_person_id': dismissedPersonId,
      'position': position,
    });
  }

  /// Track Soko (AI) message displayed (PostHog only — backend emits its own)
  Future<void> trackMessageSentSoko({String? sessionId}) async {
    _dispatch('message_sent_soko', {
      if (sessionId != null) 'session_id': sessionId,
    });
  }

  // ============ SEARCH EVENTS ============

  /// Track search result click (Backend + PostHog).
  /// PROD-3209 (spec 8.2c): also fires on Library search results now, not
  /// just chat — [surface] ∈ {chat, library} disambiguates, [query] carries
  /// the search term where the surface has one.
  Future<void> trackSearchResultClick({
    String? eventId,
    String? venueId,
    String? intent,
    int? resultPosition,
    String? sessionId,
    String? itemType,
    String? itemName,
    String? surface,
    String? query,
  }) async {
    _dispatch('search_result_click', {
      if (surface != null) 'surface': surface,
      if (query != null) 'query': query,
      if (eventId != null) 'event_id': eventId,
      if (venueId != null) 'venue_id': venueId,
      if (intent != null) 'intent': intent,
      if (resultPosition != null) 'result_position': resultPosition,
      if (sessionId != null) 'session_id': sessionId,
      if (itemType != null) 'item_type': itemType,
      if (itemName != null) 'item_name': itemName,
    });
  }

  /// The user opened a search surface — the control was tapped, before any
  /// query exists (PROD-4303).
  ///
  /// Separate from [trackSearchSubmitted] on purpose: the gap between the two
  /// is the abandoned search, which is the number that says whether the entry
  /// point is discoverable but unhelpful. [source] matches the `source` those
  /// events carry (`procura` = the feed's Procura circle). The Map keeps its
  /// own `map_search_opened` — its surface has live dashboards on that name.
  void trackSearchOpened({required String source}) {
    _dispatch('search_opened', {'source': source});
  }

  /// Client-side search signal for AppsFlyer's `af_search` (PROD-3533).
  /// Deliberately a SEPARATE event from the backend-emitted `search` — the
  /// contract marks `search` as not-webapp-emitted and Firebase reads its
  /// `search_term`; reusing it here would double-count and mismatch props.
  /// Routes only to Dest.appsflyer (see event_registry). Uses `search_term`
  /// to stay name-consistent with the existing `search` schema.
  void trackSearchSubmitted({required String searchTerm, String? source}) {
    _dispatch('search_submitted', {
      'search_term': searchTerm,
      if (source != null) 'source': source,
    });
  }

  // Research recruitment: clicks are not confirmed bookings.
  void trackResearchInvitationViewed({
    required String campaignId,
    required String variant,
  }) {
    _dispatch('research_invitation_viewed', {
      'campaign_id': campaignId,
      'variant': variant,
      'surface': 'discovery',
      'reward_currency': 'EUR',
      'reward_amount': variant == 'amazon_10' ? 10 : 0,
    });
  }

  void trackResearchInvitationDismissed({
    required String campaignId,
    required String variant,
  }) {
    _dispatch('research_invitation_dismissed', {
      'campaign_id': campaignId,
      'variant': variant,
      'surface': 'discovery',
      'reward_currency': 'EUR',
      'reward_amount': variant == 'amazon_10' ? 10 : 0,
    });
  }

  void trackResearchInterviewClicked({
    required String campaignId,
    required String variant,
  }) {
    _dispatch('research_interview_clicked', {
      'campaign_id': campaignId,
      'variant': variant,
      'surface': 'discovery',
      'reward_currency': 'EUR',
      'reward_amount': variant == 'amazon_10' ? 10 : 0,
    });
  }

  // ============ CONTENT INTERACTION ============

  /// Track viewing an item (Firebase + PostHog)
  Future<void> trackViewItem({
    required String itemId,
    required String itemType,
    String? itemName,
    String? source,
  }) async {
    _dispatch('view_item', {
      'item_id': itemId,
      'item_type': itemType,
      if (itemName != null) 'item_name': itemName,
      if (source != null) 'source': source,
    });
  }

  /// Track a card impression in a discovery shelf (Backend + PostHog).
  /// Fired once per feed load per item when the card is >=70% visible.
  /// Mirrors `trackDiscoveryShelfCardClicked` join keys: [shelfId] and
  /// [cardIndex] map to `shelf_id`/`card_index` so impressions join clicks.
  Future<void> trackItemImpression({
    required String itemId,
    required String itemType,
    required int cardIndex,
    String? shelfId,
    String? blockId,
    String? surface,
  }) async {
    assert(
      (shelfId == null) != (blockId == null),
      'item_impression carries EXACTLY ONE of shelf_id / block_id',
    );
    _dispatch('item_impression', {
      'item_id': itemId,
      'item_type': itemType,
      if (shelfId != null) 'shelf_id': shelfId,
      if (blockId != null) 'block_id': blockId,
      if (surface != null) 'surface': surface,
      'card_index': cardIndex,
    });
  }

  /// Track the reader crossing into the next feed slate (PostHog).
  ///
  /// PROD-4238. Fired from `FeedHomeNotifier.loadSlate` **on success only** —
  /// this counts slates delivered, not taps attempted, because a failed fetch
  /// leaves the button live and the reader will simply tap again.
  ///
  /// [blockId] is the terminal block that was tapped: `feed-end` on slate 1 and
  /// `feed-end-sN` after. That is how slate depth reaches analytics without the
  /// client parsing the cursor, which is opaque by contract.
  void trackFeedSlateAdvance({
    required String blockId,
    required String feedFilter,
    int? blocksBefore,
  }) {
    _dispatch('feed_slate_advance', {
      'block_id': blockId,
      'feed_filter': feedFilter,
      if (blocksBefore != null) 'blocks_before': blocksBefore,
    });
  }

  /// `'<variant>|<filter>'` for every feed already reported as seen this app
  /// session. The dedup key, and the `is_cold_start` oracle.
  final Set<String> _feedsExposedThisSession = {};

  /// Fired once per feed view — the denominator `discovery-feed-v2` never had.
  ///
  /// PROD-4423. Every other thing the v2 feed emits is an **action**
  /// (`feed_slate_advance`, the two click events, `search_submitted`), so
  /// exposure and engagement were inseparable and no rate could be computed
  /// against "saw the feed". This event is that denominator, and it fires on
  /// **both** variants: a treatment-arm user who lands on v1 is the PROD-4419
  /// symptom, and it is only visible if v1 reports too.
  ///
  /// **`feed_variant` is not a parameter.** `_dispatch` stamps it from
  /// `FeedVariantHolder`, which reads `discoveryFeedVariantProvider` — the same
  /// provider `DiscoveryVariantPage` renders on, so the event cannot disagree
  /// with the page on screen (D46), nor with the other four events carrying the
  /// property. The dedup key below reads the holder for the same reason.
  ///
  /// [variantSource] is why the PROD-4419 gate opened — `fresh_flag` /
  /// `cached` / `cap` — snapshotted when it latched, not derived here. It
  /// separates "we knew which feed this reader should get" from "we guessed",
  /// and `cap` is the only place PROD-4419's residual risk is visible outside
  /// device logs.
  ///
  /// **Deduped per (variant, filter) per app session**, like
  /// [trackDiscoveryShelfViewed]: a rebuild must not re-report a feed the user
  /// is already looking at, while a filter switch composes a different feed and
  /// so is a new exposure. The set lives on this service, which is a keep-alive
  /// provider built once per app session — see the note on
  /// `feedVariantHolderProvider` about why a holder that rebuilt would reset it.
  ///
  /// PROD-4531 added four answers this event could not give. [state] is what
  /// the reader actually saw — `block_count` reads `0` for an empty feed, an
  /// errored feed and the no-location notice alike, and the out-of-coverage
  /// answer arrives as a *block*, so it read as an ordinary feed. [waitMs] is
  /// how long they waited for it, measured at the call site from a monotonic
  /// `Stopwatch` (never a wall clock, and never two timestamps for the
  /// dashboard to pair). The location facets describe where the request was
  /// aimed, and are sent only when [state] is not `feed`.
  ///
  /// ⚠️ **[lat] / [lon] go through [coarseCoordinates]** — rounded to 2
  /// decimals (~1 km) and dropped entirely if the pair is non-finite, out of
  /// range or half-present. One site for both rules is the point: a caller that
  /// forgets can leak neither a precise coordinate nor a `NaN`.
  ///
  /// ⚠️ **[waitMs] describes the FIRST exposure of each filter in a launch, and
  /// nothing else.** The dedup below drops every later one, so this is
  /// "first-load wait per feed", not a per-visit measure.
  void trackFeedExposed({
    required String feedFilter,
    required int blockCount,
    required String variantSource,
    required String state,
    required int waitMs,
    String? locationSource,
    String? cityId,
    double? lat,
    double? lon,
    int? suggestionCount,
  }) {
    final variant = _feedVariantHolder?.label ?? 'v1';

    // Read BEFORE the add, so the first feed of the session reports true and
    // nothing else does. "Cold start" means this app session's first feed view,
    // not this filter's.
    final isColdStart = _feedsExposedThisSession.isEmpty;

    if (!_feedsExposedThisSession.add('$variant|$feedFilter')) return;

    final coords = coarseCoordinates(lat, lon);

    _dispatch('feed_exposed', {
      'feed_filter': feedFilter,
      'block_count': blockCount,
      'variant_source': variantSource,
      'is_cold_start': isColdStart,
      'state': state,
      'wait_ms': waitMs,
      if (locationSource != null) 'location_source': locationSource,
      if (cityId != null) 'city_id': cityId,
      if (coords.lat != null) 'lat': coords.lat,
      if (coords.lon != null) 'lon': coords.lon,
      if (suggestionCount != null) 'suggestion_count': suggestionCount,
    });
  }

  /// The variant this app session most recently COMMITTED to, or null before
  /// the first commit. The dedup key and the `is_cold_start` oracle for
  /// [trackFeedVariantCommitted].
  ///
  /// **A last-value comparison, not a `Set` like [_feedsExposedThisSession].**
  /// The difference is deliberate and shows up in exactly one session shape:
  /// `v1 → post_login v2 → sign_out v1`. Set membership would swallow the third
  /// commit, because `'v1'` is already in it — and that third commit is a real
  /// decision the page acted on. A last-value comparison emits on every actual
  /// commit, still no-ops on a rebuild, and cannot grow without bound in any
  /// session that does not repeatedly sign in and out.
  String? _lastVariantCommitted;

  /// PROD-4436 — fired the instant `DiscoveryVariantPage` commits to a variant,
  /// on BOTH arms, **before any fetch**. The denominator [trackFeedExposed]
  /// structurally cannot be.
  ///
  /// `feed_exposed` is emitted asymmetrically by construction: legacy v1 reports
  /// the moment it mounts, while v2 waits for `feedHomeProvider`'s first fetch
  /// and deliberately reports NOTHING if the reader leaves during it. That drops
  /// the fastest bouncers from the treatment arm only and biases every
  /// per-exposed-user rate toward v2. The gap between this event and
  /// `feed_exposed` is the v2 fetch-abandonment rate.
  ///
  /// **This marks a DECISION; `feed_exposed` marks a RENDER.** That is why its
  /// call site emits synchronously during `build` while `feed_exposed` defers to
  /// a post-frame callback — see `discovery_variant_page.dart`. Deferring this
  /// one would put the v2 first fetch ahead of it and lose precisely the readers
  /// it exists to count.
  ///
  /// **`feed_variant` is not a parameter** — `_dispatch` stamps it from
  /// `FeedVariantHolder`, the same source `feed_exposed` uses, so the two events
  /// cannot disagree about which page the session is on (D46).
  ///
  /// ⚠️ **`is_cold_start` means "the first commit since this app launched"**, not
  /// "since sign-in". Nothing clears this state — `trackLogout()` resets adapter
  /// identity but not the dedup, exactly as it does not clear
  /// [_feedsExposedThisSession]. So a post-sign-out commit reports `false` even
  /// though PostHog may have minted a new `$session_id`. Consistent between the
  /// two events, which is what matters for a paired numerator and denominator.
  /// [gateWaitMs] (PROD-4455) is how long the PROD-4419 variant gate held
  /// `SokoSplashView` before this session committed — the cost of the wait,
  /// which is otherwise invisible. A **session** property, not a per-decision
  /// one: it describes the gate's single hold, so a mid-session flip repeats
  /// the same number rather than reporting a second wait that never happened.
  /// Null only where a caller has no gate to report.
  void trackFeedVariantCommitted({
    required String variantSource,
    int? gateWaitMs,
  }) {
    final variant = _feedVariantHolder?.label ?? 'v1';

    // A rebuild is not a commit. The call site runs on every build of
    // `DiscoveryVariantPage`, so this guard is what makes that free.
    if (variant == _lastVariantCommitted) return;

    // Read BEFORE the write, so only the session's first commit reports true.
    final isColdStart = _lastVariantCommitted == null;
    _lastVariantCommitted = variant;

    _dispatch('feed_variant_committed', {
      'variant_source': variantSource,
      'is_cold_start': isColdStart,
      if (gateWaitMs != null) 'gate_wait_ms': gateWaitMs,
    });
  }

  // ============ ITEM UNSAVE ============

  /// Track item removed from bookmarks (Backend + PostHog)
  void trackItemUnsave({required String itemId, required String itemType}) {
    _dispatch('item_unsave', {'item_id': itemId, 'item_type': itemType});
  }

  // ============ EXTERNAL CLICKS ============

  /// Shared emitter for the `external_click` family. PROD-3209: derives
  /// `domain` from the URL host ("got directions" vs "bought a ticket" is
  /// already `destination_type`; domain answers "to WHICH site"). tel: links
  /// have no host and skip it.
  void _emitExternalClick({
    required String destinationType,
    String? url,
    String? eventId,
    String? venueId,
    String? originSource,
    String? originEntityId,
  }) {
    final host = url == null ? null : Uri.tryParse(url)?.host;
    _dispatch('external_click', {
      'destination_type': destinationType,
      if (url != null) 'destination_url': url,
      if (host != null && host.isNotEmpty) 'domain': host,
      if (eventId != null) 'event_id': eventId,
      if (venueId != null) 'venue_id': venueId,
      if (originSource != null) 'origin_source': originSource,
      if (originEntityId != null) 'origin_entity_id': originEntityId,
    });
  }

  /// Track Google Maps click (Backend + PostHog)
  Future<void> trackGoogleMapsClick({
    required String url,
    String? eventId,
    String? venueId,
    String? originSource,
    String? originEntityId,
  }) async {
    _emitExternalClick(
      destinationType: 'google_maps',
      url: url,
      eventId: eventId,
      venueId: venueId,
      originSource: originSource,
      originEntityId: originEntityId,
    );
  }

  /// PROD-2173 — track a maps click with the actual provider chosen by
  /// the OS picker (`'google_maps'`, `'apple_maps'`, or `'other_maps'`).
  /// Fixes the historical bug where event/venue Maps buttons always
  /// reported `google_maps` even when Apple Maps launched.
  Future<void> trackMapsClick({
    required String provider,
    String? url,
    String? eventId,
    String? venueId,
    String? originSource,
    String? originEntityId,
  }) async {
    _emitExternalClick(
      destinationType: provider,
      url: url,
      eventId: eventId,
      venueId: venueId,
      originSource: originSource,
      originEntityId: originEntityId,
    );
  }

  /// Track website click (Backend + PostHog)
  Future<void> trackWebsiteClick({
    required String url,
    String? eventId,
    String? venueId,
    String? originSource,
    String? originEntityId,
  }) async {
    _emitExternalClick(
      destinationType: 'website',
      url: url,
      eventId: eventId,
      venueId: venueId,
      originSource: originSource,
      originEntityId: originEntityId,
    );
  }

  /// Track calendar click (Backend + PostHog)
  Future<void> trackCalendarClick({
    required String url,
    String? eventId,
    String? venueId,
    String? originSource,
    String? originEntityId,
  }) async {
    _emitExternalClick(
      destinationType: 'calendar',
      url: url,
      eventId: eventId,
      venueId: venueId,
      originSource: originSource,
      originEntityId: originEntityId,
    );
  }

  /// Track phone click (Backend + PostHog)
  Future<void> trackPhoneClick({
    required String phoneNumber,
    String? venueId,
    String? originSource,
    String? originEntityId,
  }) async {
    _emitExternalClick(
      destinationType: 'phone',
      url: 'tel:$phoneNumber',
      venueId: venueId,
      originSource: originSource,
      originEntityId: originEntityId,
    );
  }

  /// Track opening hours expand (PostHog only)
  void trackOpeningHoursExpand({String? venueId, String? originSource}) {
    _dispatch('opening_hours_expand', {
      if (venueId != null) 'venue_id': venueId,
      if (originSource != null) 'origin_source': originSource,
    });
  }

  /// Track ticketing click (Backend + PostHog)
  Future<void> trackTicketingClick({
    required String url,
    String? eventId,
    String? venueId,
    String? originSource,
    String? originEntityId,
  }) async {
    _emitExternalClick(
      destinationType: 'ticketing',
      url: url,
      eventId: eventId,
      venueId: venueId,
      originSource: originSource,
      originEntityId: originEntityId,
    );
  }

  /// Track generic external click (Backend + PostHog)
  Future<void> trackExternalClick({
    required String destinationType,
    required String url,
    String? eventId,
    String? venueId,
    String? originSource,
    String? originEntityId,
  }) async {
    _emitExternalClick(
      destinationType: destinationType,
      url: url,
      eventId: eventId,
      venueId: venueId,
      originSource: originSource,
      originEntityId: originEntityId,
    );
  }

  // ============ ZINE BROWSING (PROD-3209) ============

  /// A zine pager page settled (PostHog only). Page 0 is the cover; item
  /// pages double as per-item impressions via [entityId]. Fires on page
  /// CHANGE — the cover's initial render is already counted by list_open.
  void trackZinePageView({
    required String zineId,
    required int pageIndex,
    required int pageTotal,
    String? entityId,
  }) {
    _dispatch('zine_page_view', {
      'zine_id': zineId,
      'page_index': pageIndex,
      'page_total': pageTotal,
      if (entityId != null) 'entity_id': entityId,
    });
  }

  /// The zine/list view-mode toggle changed (PostHog only).
  /// [mode] ∈ {zine, list}.
  void trackZineViewModeChange({required String zineId, required String mode}) {
    _dispatch('zine_view_mode_change', {'zine_id': zineId, 'mode': mode});
  }

  // ============ PROFILE EDITING (PROD-3211, tracking-spec P3) ============

  /// Profile saved with at least one changed field.
  /// [fieldsChanged] names the changed fields (full_name / handle / bio /
  /// city / is_private / show_bio_memories / show_saved).
  void trackProfileUpdated({required List<String> fieldsChanged}) {
    _dispatch('profile_updated', {'fields_changed': fieldsChanged.join(',')});
  }

  /// Avatar upload confirmed by the backend.
  void trackProfilePhotoAdded() {
    _dispatch('profile_photo_added', const {});
  }

  /// The public/private toggle actually flipped (fires alongside
  /// profile_updated — separate event per the tracking spec).
  void trackProfilePrivacyChange({required bool toPrivate}) {
    _dispatch('profile_privacy_change', {'to_private': toPrivate});
  }

  // ============ FEEDBACK (PROD-3211, tracking-spec P3) ============

  /// The feedback sheet opened. [trigger] ∈ {shake, tab}; [screen] is the
  /// active area (homepage / chat / library / create / menu / profile /
  /// general).
  void trackFeedbackOpen({required String trigger, required String screen}) {
    _dispatch('feedback_open', {'trigger': trigger, 'screen': screen});
  }

  /// Feedback submitted. The text itself goes to the backoffice (a human
  /// reads it); this measures volume/type/scope only.
  /// [type] ∈ {problem, idea, both}; [scope] ∈ {page, app}.
  void trackFeedbackSubmit({
    required String type,
    required String scope,
    required int length,
    bool hasAudio = false,
    String? screen,
  }) {
    _dispatch('feedback_submit', {
      'type': type,
      'scope': scope,
      'length': length,
      'has_audio': hasAudio,
      if (screen != null) 'screen': screen,
    });
  }

  // ============ MEMORY SURFACES (PROD-3211, tracking-spec P3) ============
  // The [Admin] Memory page previously had zero analytics. PostHog-only.

  /// The Memory page opened.
  void trackMemoryOpen() {
    _dispatch('memory_open', const {});
  }

  /// An observation chip/row was expanded (browsing one's own memory).
  void trackMemoryRowTap({required String category, required String tag}) {
    _dispatch('memory_row_tap', {'category': category, 'tag': tag});
  }

  /// A chip was nudged up/down — the user correcting their own memory (L3).
  void trackMemorySignalAdjust({
    required String tag,
    required String category,
    required String direction,
  }) {
    _dispatch('memory_signal_adjust', {
      'tag': tag,
      'category': category,
      'direction': direction,
    });
  }

  /// A chip was deleted (after confirm).
  void trackMemoryDelete({required String tag, required String category}) {
    _dispatch('memory_delete', {'tag': tag, 'category': category});
  }

  /// A whole category (family) was cleared (after confirm).
  void trackMemoryCategoryClear({required String category}) {
    _dispatch('memory_category_clear', {'category': category});
  }

  /// The "tell us about you" free text was submitted and accepted.
  /// [length] is the trimmed text length; [factsWritten] how many memory
  /// facts the backend extracted.
  void trackMemoryFreetextSubmit({required int length, int? factsWritten}) {
    _dispatch('memory_freetext_submit', {
      'length': length,
      if (factsWritten != null) 'facts_written': factsWritten,
    });
  }

  /// The free-text submit was rejected ("nothing new to add" and friends) —
  /// previously an uncountable failure state. [status] is the backend
  /// outcome (no_facts / duplicate / too_short / …).
  void trackMemoryFreetextRejected({required String status, int? length}) {
    _dispatch('memory_freetext_rejected', {
      'status': status,
      if (length != null) 'length': length,
    });
  }

  // ============ PERFORMANCE (PROD-3211) ============

  /// First render of a screen's loaded state, measured from screen init
  /// (PostHog only, actor system). The zine open showed a 20+ second
  /// skeleton with zero performance events — this is the first one.
  void trackScreenLoadComplete({
    required String screen,
    required int durationMs,
  }) {
    _dispatch('screen_load_complete', {
      'screen': screen,
      'duration_ms': durationMs,
    });
  }

  /// Track item share (Backend + PostHog)
  Future<void> trackItemShare({
    String? eventId,
    String? venueId,
    String? originSource,
    String? originEntityId,
  }) async {
    _dispatch('external_click', {
      'destination_type': ExternalDestination.share,
      'destination_url': 'share_sheet',
      if (eventId != null) 'event_id': eventId,
      if (venueId != null) 'venue_id': venueId,
      if (originSource != null) 'origin_source': originSource,
      if (originEntityId != null) 'origin_entity_id': originEntityId,
    });
  }

  // ============ LIST EVENTS ============

  /// Track list item click from public list view (Backend + PostHog)
  Future<void> trackListItemClick({
    required String listId,
    required String itemType,
    String? eventId,
    String? venueId,
    String? listName,
    String? itemName,
  }) async {
    _dispatch('list_item_click', {
      'list_id': listId,
      'item_type': itemType,
      if (eventId != null) 'event_id': eventId,
      if (venueId != null) 'venue_id': venueId,
      if (listName != null) 'list_name': listName,
      if (itemName != null) 'item_name': itemName,
    });
  }

  /// Track list share (Firebase + Backend + PostHog)
  Future<void> trackListShare({
    required String listId,
    String? shareMethod,
    String? listName,
  }) async {
    _dispatch('list_share', {
      'list_id': listId,
      if (shareMethod != null) 'share_method': shareMethod,
      if (listName != null) 'list_name': listName,
    });
  }

  /// Track list unfollow (Backend + PostHog)
  ///
  /// Pass [list] (and [currentUserId]) to enrich with the shared list
  /// properties — see [listAnalyticsProps].
  Future<void> trackListUnfollow({
    required String listId,
    String? listName,
    UserList? list,
    String? currentUserId,
  }) async {
    _dispatch('list_unfollow', {
      'list_id': listId,
      if (listName != null) 'list_name': listName,
      if (list != null)
        ...listAnalyticsProps(
          list,
          currentUserId: currentUserId,
          includeFollowerCount: true,
        ),
    });
  }

  /// PROD-2264 — Track a UGC moderation report submitted from any
  /// detail screen (event, place, list, list item). Replaces the
  /// list-only `list_report` flow with a single event that carries the
  /// target type so backoffice can slice by surface.
  Future<void> trackContentReport({
    required String targetType,
    required String reason,
    required bool idempotentHit,
  }) async {
    _dispatch('content_report', {
      'target_type': targetType,
      'reason': reason,
      'idempotent_hit': idempotentHit,
    });
  }

  /// PROD-2264 — Track a server-side user block (POST /blocks).
  Future<void> trackUserBlock({
    required String blockedUserId,
    String? contextTargetType,
  }) async {
    _dispatch('user_block', {
      'blocked_user_id': blockedUserId,
      if (contextTargetType != null) 'context_target_type': contextTargetType,
    });
  }

  /// PROD-2264 — Track a UGC input rejected by the wordlist filter
  /// (400 `CONTENT_BLOCKED`). [field] is the surface that triggered the
  /// rejection (`list_name` / `list_description` / `list_prompt` /
  /// `list_item_tip` / `profile_name` / `profile_handle`) so we can
  /// track block rates per field and prioritise wordlist tuning.
  /// PostHog-only for now — backend registration must land before this
  /// can be promoted to `{Dest.backend, Dest.posthog}` (server-side
  /// event registry rejects unknown names with 422).
  Future<void> trackContentBlocked({required String field}) async {
    _dispatch('content_blocked', {'field': field});
  }

  // ============ DEEP LINKS — SHORT-LINK RESOLUTION (PROD-2314) ============

  /// Track a successful Short.io branded short-link resolution.
  ///
  /// PostHog-only for now — the backend event registry has no entry for this
  /// name yet (rejects unknown names with 422); promote to
  /// `{Dest.backend, Dest.posthog}` once heyl-backend registers it.
  ///
  /// [resolvedUrl] MUST already be passed through `redactDeepLinkForLogging`
  /// (Decision 29) — the resolved chat URL carries the user's search query.
  Future<void> trackShortLinkResolved({
    required String sourceHost,
    required String resolvedUrl,
    String? route,
  }) async {
    _dispatch('deep_link.short_link_resolved', {
      'source_host': sourceHost,
      'resolved_url': resolvedUrl,
      if (route != null) 'route': route,
    });
  }

  /// Track a failed Short.io branded short-link resolution. PostHog-only.
  ///
  /// [shortUrl] MUST already be passed through `redactDeepLinkForLogging`.
  /// [errorKind] is one of the `ShortLinkFailureKind` tags (timeout, network,
  /// http_error, no_location, too_many_hops) or `unroutable` when the chain
  /// resolved to a URL the app can't route.
  Future<void> trackShortLinkResolveFailed({
    required String sourceHost,
    required String shortUrl,
    required String errorKind,
  }) async {
    _dispatch('deep_link.short_link_resolve_failed', {
      'source_host': sourceHost,
      'short_url': shortUrl,
      'error_kind': errorKind,
    });
  }

  /// Track list item removal (Backend + PostHog)
  ///
  /// Pass [list] (and [currentUserId]) to enrich with the shared list
  /// properties — see [listAnalyticsProps]. [listSizeAfter] is the authoritative
  /// item count after the removal; omit it when the caller cannot determine the
  /// list's true total (an omitted count beats a wrong one).
  Future<void> trackListItemRemove({
    required String listId,
    required String itemType,
    String? eventId,
    String? venueId,
    String? listName,
    String? itemName,
    UserList? list,
    String? currentUserId,
    int? listSizeAfter,
  }) async {
    _dispatch('list_item_remove', {
      'list_id': listId,
      'item_type': itemType,
      if (eventId != null) 'event_id': eventId,
      if (venueId != null) 'venue_id': venueId,
      if (listName != null) 'list_name': listName,
      if (itemName != null) 'item_name': itemName,
      if (list != null)
        ...listAnalyticsProps(
          list,
          currentUserId: currentUserId,
          listSizeAfter: listSizeAfter,
          includeRole: true,
        ),
    });
  }

  /// Track a confirmed note change on a list item (Backend + PostHog).
  ///
  /// PROD-4553: [noteAction] is the backend's authoritative transition; callers
  /// must suppress [NoteAction.unchanged] (a no-op re-submit) before calling.
  /// [saveFlowId] is set only when the note was written inside a save flow (the
  /// join that marks "note added during saving"); a later annotation omits it.
  /// The membership/note/flow context rides `productProperties` so it reaches
  /// only PostHog and the backend mirror. Note text itself never travels.
  Future<void> trackListElementNote({
    required String listId,
    required String itemType,
    String? eventId,
    String? venueId,
    String? listName,
    String? itemName,
    String? listItemId,
    NoteAction? noteAction,
    bool? hasNote,
    int? noteLength,
    String? source,
    String? saveFlowId,
    AnalyticsActionContext? actionContext,
  }) async {
    final noteAndFlowProps = <String, dynamic>{
      if (listItemId != null) 'list_item_id': listItemId,
      if (noteAction != null) 'note_action': noteAction.wire,
      if (hasNote != null) 'has_note': hasNote,
      if (noteLength != null) 'note_length': noteLength,
      if (saveFlowId != null) 'save_flow_id': saveFlowId,
    };
    _dispatch(
      'list_element_note',
      {
        'list_id': listId,
        'item_type': itemType,
        if (eventId != null) 'event_id': eventId,
        if (venueId != null) 'venue_id': venueId,
        if (listName != null) 'list_name': listName,
        if (itemName != null) 'item_name': itemName,
        if (source != null) 'source': source,
      },
      actionContext,
      noteAndFlowProps,
    );
  }

  // ============ LIST CRUD EVENTS ============

  /// Track list creation (Firebase + Backend + PostHog).
  /// PROD-3211: [itemCount] is the server count at creation (0 for an empty
  /// zine; items added afterwards ride list_item_add/item_saved).
  void trackListCreate({
    required String listId,
    required bool isPublic,
    bool hasDescription = false,
    bool hasPrompt = false,
    String? source,
    String? listName,
    int? itemCount,
  }) {
    _dispatch('list_create', {
      'list_id': listId,
      'is_public': isPublic,
      'has_description': hasDescription,
      'has_prompt': hasPrompt,
      if (source != null) 'source': source,
      if (listName != null) 'list_name': listName,
      if (itemCount != null) 'item_count': itemCount,
    });
  }

  /// Track list update/edit (Firebase + Backend + PostHog)
  void trackListUpdate({required String listId, String? listName}) {
    _dispatch('list_update', {
      'list_id': listId,
      if (listName != null) 'list_name': listName,
    });
  }

  /// Track list deletion (Firebase + Backend + PostHog)
  void trackListDelete({
    required String listId,
    int? itemCount,
    String? listName,
  }) {
    _dispatch('list_delete', {
      'list_id': listId,
      if (itemCount != null) 'item_count': itemCount,
      if (listName != null) 'list_name': listName,
    });
  }

  /// Track list follow (Firebase + Backend + PostHog)
  ///
  /// Pass [list] (and [currentUserId]) to enrich with the shared list
  /// properties — see [listAnalyticsProps]. [list] must carry the
  /// **post-follow** `followerCount`, which becomes `follower_count`.
  void trackListFollow({
    required String listId,
    String? listName,
    UserList? list,
    String? currentUserId,
  }) {
    _dispatch('list_follow', {
      'list_id': listId,
      if (listName != null) 'list_name': listName,
      if (list != null)
        ...listAnalyticsProps(
          list,
          currentUserId: currentUserId,
          includeFollowerCount: true,
        ),
    });
  }

  /// Track item added to a list (Backend + PostHog)
  ///
  /// Pass [list] (and [currentUserId]) to enrich with the shared list
  /// properties — see [listAnalyticsProps]. [listSizeAfter] is the authoritative
  /// item count after the add — this is what Growth thresholds on ("your Zine
  /// reached 3 places"), so it must only ever describe a **confirmed** add.
  void trackListItemAdd({
    required String listId,
    required String itemType,
    String? source,
    String? eventId,
    String? venueId,
    String? googlePlaceId,
    String? listName,
    String? itemName,
    UserList? list,
    String? currentUserId,
    int? listSizeAfter,
    String? listItemId,
    bool? hasNote,
    int? noteLength,
    String? saveFlowId,
    AnalyticsActionContext? actionContext,
  }) {
    // PROD-4553 — membership id, note facts and the save-flow correlation key.
    // Routed through `productProperties` (the 4th `_dispatch` arg) so they reach
    // only PostHog and the backend mirror, never `list_item_add`'s advertising
    // destination. Note text itself never travels — only the derived facts.
    final noteAndFlowProps = <String, dynamic>{
      if (listItemId != null) 'list_item_id': listItemId,
      if (hasNote != null) 'has_note': hasNote,
      if (noteLength != null) 'note_length': noteLength,
      if (saveFlowId != null) 'save_flow_id': saveFlowId,
    };
    _dispatch(
      'list_item_add',
      {
        'list_id': listId,
        'item_type': itemType,
        if (source != null) 'source': source,
        if (eventId != null) 'event_id': eventId,
        if (venueId != null) 'venue_id': venueId,
        if (listName != null) 'list_name': listName,
        if (itemName != null) 'item_name': itemName,
        if (list != null)
          ...listAnalyticsProps(
            list,
            currentUserId: currentUserId,
            listSizeAfter: listSizeAfter,
            includeRole: true,
          ),
      },
      actionContext,
      noteAndFlowProps,
    );

    // PROD-3209: canonical save event, intentionally co-emitted with
    // list_item_add (in this app "saving" is always add-to-list).
    // `item_saved` is the save count symmetric with `item_unsave`;
    // `list_item_add` stays the list-CRUD telemetry with the rich list
    // vocabulary — never sum the two. Emitting here (not at call sites)
    // inherits the confirmed-adds-only suppression upstream (PROD-3296).
    // save_type: the default "Saved" list is a bookmark (`saved_list`);
    // any other list is a user zine (`zine`). `list` can be null on a
    // first-ever quick save, hence the source fallback.
    final saveType = (list?.isDefault ?? source == 'quick_save')
        ? 'saved_list'
        : 'zine';
    _dispatch(
      'item_saved',
      {
        // External/Google-place saves have no internal id yet — send the
        // Google place id so the save still has a stable key.
        'entity_id': eventId ?? venueId ?? googlePlaceId ?? 'external',
        'entity_type': itemType,
        'save_type': saveType,
        if (saveType == 'zine') 'zine_id': listId,
        if (source != null) 'source': source,
      },
      actionContext,
      noteAndFlowProps,
    );
  }

  // ============ LIST SEARCH EVENTS ============

  /// Track search within the "add to list" sheet (Backend + PostHog).
  ///
  /// [tab] - 'places' or 'events'.
  ///
  /// Scope fields (PROD-1326 v2) are PostHog-only — backend event schema is
  /// unchanged. [scopeType] ∈ {'near_me', 'country', 'country_city'}. When
  /// `country` or `country_city`, [countryCode] is the ISO-3166-1 alpha-2.
  /// [cityId] / [citySource] are only set for user-picked cities (auto
  /// pre-selected cities skip them).
  void trackListSearch({
    required String query,
    required String tab,
    required int resultCount,
    required String listId,
    String? scopeType,
    String? countryCode,
    String? cityId,
    String? citySource,
  }) {
    _dispatch('list_search', {
      'query': query,
      'tab': tab,
      'result_count': resultCount,
      'list_id': listId,
      if (scopeType != null) 'scope_type': scopeType,
      if (countryCode != null) 'country_code': countryCode,
      if (cityId != null) 'city_id': cityId,
      if (citySource != null) 'city_source': citySource,
    });
  }

  /// Track scope change in the add-to-list picker (PROD-1326 v2).
  ///
  /// PostHog-only — no corresponding backend event.
  /// [scopeType] ∈ {'near_me', 'country', 'country_city'}.
  /// [citySource] ∈ {'local', 'google'} — only set when [scopeType] is
  /// `country_city` and the city was user-picked (not auto).
  void trackListSearchScopeChange({
    required String listId,
    required String scopeType,
    String? countryCode,
    String? cityId,
    String? citySource,
  }) {
    _dispatch('list_search_scope_change', {
      'list_id': listId,
      'scope_type': scopeType,
      if (countryCode != null) 'country_code': countryCode,
      if (cityId != null) 'city_id': cityId,
      if (citySource != null) 'city_source': citySource,
    });
  }

  // ============ LISTS HUB EVENTS ============

  /// Track filter change in the lists hub (Backend + PostHog)
  void trackListsHubFilter({required String filter}) {
    _dispatch('lists_hub_filter', {'filter': filter});
  }

  /// Track search in the lists hub (Backend + PostHog)
  void trackListsHubSearch({required String query, required int resultCount}) {
    _dispatch('lists_hub_search', {
      'query': query,
      'result_count': resultCount,
    });
  }

  // ============ LIST MANAGEMENT EVENTS ============

  /// Track list item reorder (Backend + PostHog)
  void trackListReorder({required String listId, String? listName}) {
    _dispatch('list_reorder', {
      'list_id': listId,
      if (listName != null) 'list_name': listName,
    });
  }

  /// Track list cover image change (Backend + PostHog)
  void trackListCoverChange({required String listId, String? listName}) {
    _dispatch('list_cover_change', {
      'list_id': listId,
      if (listName != null) 'list_name': listName,
    });
  }

  /// Track list visibility toggle (Backend + PostHog)
  void trackListVisibilityChange({
    required String listId,
    required String visibility,
    String? listName,
  }) {
    _dispatch('list_visibility_change', {
      'list_id': listId,
      'visibility': visibility,
      if (listName != null) 'list_name': listName,
    });
  }

  /// Track Google Maps list import sheet opened (Backend + PostHog).
  ///
  /// [source] identifies which surface opened the sheet — one of
  /// `discovery_help_us`, future create-menu entry, etc.
  void trackListImportOpen({required String source}) {
    _dispatch('list_import_open', {'source': source});
  }

  /// Track Google Maps list import started (Backend + PostHog)
  void trackListImportStart({required String url}) {
    _dispatch('list_import_start', {'url': url});
  }

  // trackListImportComplete removed — emitted server-side (PROD-1396)

  /// Track AI suggestion accepted (Backend + PostHog)
  void trackSuggestionAccept({
    required String listId,
    required String itemType,
    String? itemName,
    String? listName,
  }) {
    _dispatch('suggestion_accept', {
      'list_id': listId,
      'item_type': itemType,
      if (itemName != null) 'item_name': itemName,
      if (listName != null) 'list_name': listName,
    });
  }

  /// Track AI suggestion dismissed (Backend + PostHog)
  void trackSuggestionDismiss({
    required String listId,
    required String itemType,
    String? itemName,
    String? listName,
  }) {
    _dispatch('suggestion_dismiss', {
      'list_id': listId,
      'item_type': itemType,
      if (itemName != null) 'item_name': itemName,
      if (listName != null) 'list_name': listName,
    });
  }

  // ============ SMART-LIST PROMPT LIFECYCLE (PROD-1429) ============

  /// Track smart-list prompt turned on for the first time (Backend + PostHog).
  /// Emitted when a user adds a prompt to a list that had none before.
  void trackSuggestionPromptEnable({
    required String listId,
    required String prompt,
  }) {
    _dispatch('suggestion_prompt_enable', {
      'list_id': listId,
      'prompt': prompt,
      'prompt_length': prompt.length,
    });
  }

  /// Track smart-list prompt edited (Backend + PostHog).
  /// Emitted when a user changes an existing prompt to a different one.
  void trackSuggestionPromptEdit({
    required String listId,
    required String prompt,
  }) {
    _dispatch('suggestion_prompt_edit', {
      'list_id': listId,
      'prompt': prompt,
      'prompt_length': prompt.length,
    });
  }

  /// Track smart-list prompt cleared / disabled (Backend + PostHog).
  void trackSuggestionPromptDisable({required String listId}) {
    _dispatch('suggestion_prompt_disable', {'list_id': listId});
  }

  /// Track user tapping "Find more suggestions" (Backend + PostHog).
  /// `visible_count_before` is how many cards were on screen just before the
  /// tap — useful to distinguish 5→10 expansions from partial fills.
  void trackSuggestionFindMore({
    required String listId,
    required int visibleCountBefore,
  }) {
    _dispatch('suggestion_find_more', {
      'list_id': listId,
      'visible_count_before': visibleCountBefore,
    });
  }

  // ============ DAILY DROP EVENTS ============

  /// Track a Daily Drop open (Firebase + Backend + PostHog).
  ///
  /// [reason] (PROD-2565) tags how the drop was opened so Growth can measure
  /// `/drop` deep-link outcomes: `deep_link` (detail opened), `no_drop`
  /// (genuinely empty), `generating` (PROD-2908 — still being produced, real
  /// latency; kept separate from `no_drop` so the two don't conflate),
  /// `cta_profiling`, or `unsupported_city`. Omitted for the in-feed tap.
  void trackDailyDropOpen({
    String? recommendationId,
    String? itemType,
    String? category,
    String? reason,
  }) {
    _dispatch('daily_drop_open', {
      if (recommendationId != null) 'recommendation_id': recommendationId,
      if (itemType != null) 'item_type': itemType,
      if (category != null) 'category': category,
      if (reason != null) 'reason': reason,
    });
  }

  /// PROD-1988 — track tap on the profiling CTA card shown in the Daily
  /// Drop slot for new users in the profiling window.
  void trackDailyDropProfilingCtaTap() {
    _dispatch('daily_drop_profiling_cta_tap', const {});
  }

  /// PROD-3950 — the user tapped "Learn more about this place/event" on the
  /// Daily Drop detail page and is being pushed onto venue/event detail.
  ///
  /// This is the moment the user asks for the *entity*, which the drop page
  /// itself deliberately never assumes: it emits no `view_item` and fetches
  /// detail with `source` omitted (the backend's documented no-capture path),
  /// so neither the client view nor the server interest signal fires until
  /// here. `view_item` then fires on the destination page's own mount.
  ///
  /// [hasReason] records whether the tip slot above the CTA had content — the
  /// drop's personalised `reason` — so the CTA's conversion can be read split
  /// by whether the user was given a rationale.
  void trackDailyDropEntityCtaTap({
    String? recommendationId,
    String? itemType,
    String? entityType,
    String? entityId,
    bool? hasReason,
  }) {
    _dispatch('daily_drop_entity_cta_tap', {
      if (recommendationId != null) 'recommendation_id': recommendationId,
      if (itemType != null) 'item_type': itemType,
      if (entityType != null) 'entity_type': entityType,
      if (entityId != null) 'entity_id': entityId,
      if (hasReason != null) 'has_reason': hasReason,
    });
  }

  /// PROD-3730 — the "Soko is picking your Daily Drop" card was shown.
  ///
  /// This is how we count users landing on the **on-demand** path, which is
  /// the central question of the PROD-3749 cost programme. The backend knows
  /// how many generations it ran; only the client knows how many users *saw
  /// the wait*. [pushState] carries the resolved `DailyDropNudge` so the same
  /// event answers "and how many of them could we have notified?".
  void trackDailyDropGeneratingImpression({required String pushState}) {
    _dispatch('daily_drop_generating_impression', {'push_state': pushState});
  }

  /// PROD-3730 — the wait sheet was opened (card tap or `/drop` deep link).
  ///
  /// [nudge] is the resolved `DailyDropNudge`; [occasion] is
  /// `generating` vs `failedTryTomorrow`. Both dimensions matter: the same ask
  /// converts differently mid-wait (something is coming) than after a failure
  /// (we just let the user down), so they must not be pooled. Pair with
  /// `push_suggestion` for the opt-in rate.
  void trackDailyDropGeneratingSheetShown({
    required String nudge,
    required String occasion,
  }) {
    _dispatch('daily_drop_generating_sheet_shown', {
      'nudge': nudge,
      'occasion': occasion,
    });
  }

  /// PROD-3730 — the client gave up waiting at the poller's 2-minute cap.
  ///
  /// Deliberately distinct from the backend's `daily_drop_failed`: this is
  /// **not** a task failure. The Celery task may still be running and finish
  /// at 130 s, in which case the backend records a success and the user saw a
  /// failure. Only the client can report that divergence.
  void trackDailyDropGenerationTimeout() {
    _dispatch('daily_drop_generation_timeout', const {});
  }

  /// PROD-2173 — user-profiling vibe flow lifecycle. `started` fires once
  /// per session when the flow screen first renders for an unfinished
  /// profile. `complete` fires when the submit returns a result. `skipped`
  /// fires when the user confirms the skip dialog and bails out.
  void trackProfilingStarted({String? entrySource}) {
    _dispatch('profiling_started', {
      if (entrySource != null) 'entry_source': entrySource,
    });
  }

  /// PROD-2566 — the `/user-profiling/flow` deep-link funnel. One event with a
  /// `reason` (mirrors `weekly_bundle_open`) so Growth can slice the campaign:
  /// * `logged_out` — a guest tapped the link; the "log in to do the profiling"
  ///   sheet was shown over guest Discovery.
  /// * `already_profiled` — an already-profiled user landed on the persona
  ///   "you've already done this" page.
  /// * `rerun` — the user tapped "erase & re-run" on that landing.
  ///
  /// UTM-enriched (see [_utmEnrichedEvents]) so push-attribution carries through
  /// from the deep link. The fresh-survey conversion itself is `profiling_started`.
  void trackProfilingDeepLink({required String reason}) {
    _dispatch('profiling_deep_link', {'reason': reason});
  }

  /// PROD-2742 — the `/yours` deep-link funnel. Fired once per native tap from
  /// `app.dart::_processDeepLink` (the choke point that resolves the launch URL
  /// to `/yours`), with [authState] captured at tap time:
  /// * `logged_in` — an authed tap cold-opened the Yours hub directly.
  /// * `logged_out` — a guest tapped; they hit the `/login` choice with
  ///   `returnUrl=/yours` and reach the (now populated) hub after auth.
  ///
  /// UTM-enriched (see [_utmEnrichedEvents]) so push-attribution carries through.
  /// Firebase + PostHog only — see the registry note on the backend 422.
  void trackYoursDeepLink({required String authState}) {
    _dispatch('yours_deep_link', {'auth_state': authState});
  }

  /// PROD-3326 — fired once per native `/map` deep-link tap, from the
  /// `app.dart::_processDeepLink` resolve choke point (settled-auth
  /// deferral, same as [trackYoursDeepLink]). [authState] ∈
  /// {logged_in, logged_out}. UTM-enriched (see [_utmEnrichedEvents]);
  /// Firebase + PostHog only — see the registry note on the backend 422.
  void trackMapDeepLink({required String authState}) {
    _dispatch('map_deep_link', {'auth_state': authState});
  }

  void trackProfilingComplete({String? archetype, int? stepCount}) {
    _dispatch('profiling_complete', {
      if (archetype != null) 'archetype': archetype,
      if (stepCount != null) 'step_count': stepCount,
    });
  }

  void trackProfilingSkipped({int? stepIndex}) {
    _dispatch('profiling_skipped', {
      if (stepIndex != null) 'step_index': stepIndex,
    });
  }

  /// PROD-2173 — fires when the user taps "Add to calendar" on an event
  /// detail screen. Replaces the previous `external_click` with
  /// `destination_type='calendar'` to give Klaviyo / reporting a dedicated
  /// event name.
  Future<void> trackEventAddToCalendar({
    required String eventId,
    required String calendarProvider,
    String? originSource,
    String? originEntityId,
  }) async {
    _dispatch('event_add_to_calendar', {
      'event_id': eventId,
      'calendar_provider': calendarProvider,
      if (originSource != null) 'origin_source': originSource,
      if (originEntityId != null) 'origin_entity_id': originEntityId,
    });
  }

  /// PROD-3109 — the user confirmed an area from the map location picker.
  /// [boundaryFound] false means the tap resolved to no PT boundary and the
  /// picker fell back to a plain point + default radius.
  /// [method] is 'tap' (default) or 'search' (search-select flow).
  /// [resultType] / [resultSource] are the prediction type/source from the
  /// search API; only set when [method] is 'search'.
  void trackMapLocationPickerSelect({
    required bool boundaryFound,
    required double radiusMeters,
    int? adminLevel,
    bool restored = false,
    String method = 'tap',
    String? resultType,
    String? resultSource,
  }) {
    _dispatch('location_picker_map_select', {
      'method': method,
      'boundary_found': boundaryFound,
      'fallback_reason': boundaryFound ? 'none' : 'no_boundary',
      'radius_meters': radiusMeters,
      'outcome': 'confirm',
      'restored': restored,
      if (adminLevel != null) 'admin_level': adminLevel,
      if (resultType != null) 'result_type': resultType,
      if (resultSource != null) 'result_source': resultSource,
    });
  }

  /// Location-scope picker lifecycle (redesign): `action` is one of
  /// `opened` | `dismissed` | `moved` | `current_location` | `search` |
  /// `search_result` | `drill_child` (tapped a city's child neighbourhood to
  /// drill in). The terminal "applied" outcome is the richer
  /// [trackMapLocationPickerSelect]. PostHog-only.
  void trackLocationPickerInteraction({
    required String action,
    double? radiusMeters,
    int? resultCount,
  }) {
    _dispatch('location_picker_interaction', {
      'action': action,
      if (radiusMeters != null) 'radius_meters': radiusMeters,
      if (resultCount != null) 'result_count': resultCount,
    });
  }

  /// PROD-2036 / PROD-2045 — track impression of the "unsupported city"
  /// CTA on the Daily Drop or Weekly Bundle slot. Fires once per session
  /// per surface (`daily` | `weekly`) from the respective notifier so we
  /// can size unsupported-city impression volume and prioritise market
  /// expansion.
  ///
  /// PROD-4531 — **[cityId] and the coordinates are no longer mutually
  /// exclusive.** They always could be sent together; the callers' own
  /// `_resolveLocationArgs()` returned one or the other, so every reader whose
  /// city resolved — the common case — produced a row with no coordinates at
  /// all, and the expansion-pressure map was built from the minority who had
  /// none. Both are sent now whenever both are known.
  ///
  /// ⚠️ **[latitude] / [longitude] now go through [coarseCoordinates]** — a
  /// precision change to a field that has shipped since v7.0.0, so rows before
  /// contract 9.9.0 are finer-grained than rows after it, and an invalid pair
  /// is now dropped rather than published. Same boundary, and the same reason,
  /// as [trackFeedExposed]'s `lat` / `lon`.
  void trackUnsupportedCityImpression({
    required String surface,
    String? cityId,
    double? latitude,
    double? longitude,
    String? locationSource,
  }) {
    final coords = coarseCoordinates(latitude, longitude);

    _dispatch('unsupported_city_impression', {
      'surface': surface,
      if (cityId != null) 'city_id': cityId,
      if (coords.lat != null) 'latitude': coords.lat,
      if (coords.lon != null) 'longitude': coords.lon,
      if (locationSource != null) 'location_source': locationSource,
    });
  }

  // PROD-2565 — the daily-drop react/save/share/cta/close events were
  // emitted only by the deprecated full-screen overlay (now removed). The
  // live surfaces only emit `daily_drop_open` (above) and
  // `daily_drop_profiling_cta_tap`.

  // ============ WEEKLY BUNDLE EVENTS ============

  /// Track weekly bundle overlay opened (Firebase + Backend + PostHog)
  void trackWeeklyBundleOpen({
    String? batchId,
    int? itemCount,
    int? pageCount,
    String? reason,
  }) {
    _dispatch('weekly_bundle_open', {
      if (batchId != null) 'batch_id': batchId,
      if (itemCount != null) 'item_count': itemCount,
      if (pageCount != null) 'page_count': pageCount,
      // PROD-2564: `deep_link` for a deep-link landing (set by the overlay from
      // the nav extra), or a failure cause fired by the DiscoveryScreen handler
      // (`no_bundle` / `generating` / `unsupported_city` / `logged_out`). Absent
      // for a normal in-app open.
      if (reason != null) 'reason': reason,
    });
  }

  /// Track page viewed in weekly bundle (Backend + PostHog)
  void trackWeeklyBundlePageView({
    String? batchId,
    int? pageIndex,
    int? pageCount,
  }) {
    _dispatch('weekly_bundle_page_view', {
      if (batchId != null) 'batch_id': batchId,
      if (pageIndex != null) 'page_index': pageIndex,
      if (pageCount != null) 'page_count': pageCount,
    });
  }

  /// Track item tapped in weekly bundle (Firebase + Backend + PostHog)
  void trackWeeklyBundleItemTap({
    String? batchId,
    String? recommendationId,
    String? itemType,
    String? itemName,
  }) {
    _dispatch('weekly_bundle_item_tap', {
      if (batchId != null) 'batch_id': batchId,
      if (recommendationId != null) 'recommendation_id': recommendationId,
      if (itemType != null) 'item_type': itemType,
      if (itemName != null) 'item_name': itemName,
    });
  }

  /// Track toggle between pages and items list (Backend + PostHog)
  void trackWeeklyBundleItemsToggle({String? batchId, required String view}) {
    _dispatch('weekly_bundle_items_toggle', {
      if (batchId != null) 'batch_id': batchId,
      'view': view,
    });
  }

  /// Track weekly bundle overlay closed (Firebase + Backend + PostHog)
  void trackWeeklyBundleClose({
    String? batchId,
    int? lastPageViewed,
    int? pageCount,
  }) {
    _dispatch('weekly_bundle_close', {
      if (batchId != null) 'batch_id': batchId,
      if (lastPageViewed != null) 'last_page_viewed': lastPageViewed,
      if (pageCount != null) 'page_count': pageCount,
    });
  }

  /// Track weekly bundle item saved to list (Firebase + Backend + PostHog)
  void trackWeeklyBundleSave({
    String? batchId,
    String? recommendationId,
    String? itemType,
    String? listId,
  }) {
    _dispatch('weekly_bundle_save', {
      if (batchId != null) 'batch_id': batchId,
      if (recommendationId != null) 'recommendation_id': recommendationId,
      if (itemType != null) 'item_type': itemType,
      if (listId != null) 'list_id': listId,
    });
  }

  /// Track weekly bundle shared (Firebase + Backend + PostHog)
  void trackWeeklyBundleShare({
    String? batchId,
    String? recommendationId,
    String? itemType,
  }) {
    _dispatch('weekly_bundle_share', {
      if (batchId != null) 'batch_id': batchId,
      if (recommendationId != null) 'recommendation_id': recommendationId,
      if (itemType != null) 'item_type': itemType,
    });
  }

  // ============ USER PREFERENCES ============

  /// Track theme change (Firebase + Backend + PostHog)
  Future<void> trackThemeChange({required String theme}) async {
    _dispatch('theme_change', {'theme': theme});
  }

  /// Track language change (Firebase + Backend + PostHog)
  Future<void> trackLanguageChange({
    required String language,
    String? previousLanguage,
  }) async {
    _dispatch('language_change', {
      'language': language,
      if (previousLanguage != null) 'previous_language': previousLanguage,
    });
  }

  /// Track memories download/export (Backend + PostHog)
  Future<void> trackMemoriesDownload({String? format}) async {
    _dispatch('memories_download', {if (format != null) 'format': format});
  }

  // ============ ONBOARDING FUNNEL EVENTS ============

  /// Track onboarding carousel step view/interaction (Backend + PostHog)
  Future<void> trackOnboardingStep({
    required String step,
    required String action,
  }) async {
    _dispatch('onboarding_step', {'step': step, 'action': action});
  }

  /// Track onboarding flow completion (Backend + PostHog)
  Future<void> trackOnboardingComplete({
    required List<String> completedSteps,
    String? skippedAtStep,
    int? totalTimeSeconds,
  }) async {
    _dispatch('onboarding_complete', {
      'completed_steps': completedSteps.join(','),
      if (skippedAtStep != null) 'skipped_at_step': skippedAtStep,
      if (totalTimeSeconds != null) 'total_time_seconds': totalTimeSeconds,
    });
  }

  // ============ PRODUCT TOUR EVENTS ============

  /// Track a product-tour step view or next-tap (PostHog).
  Future<void> trackTourStep({
    required int step,
    required String stepName,
    required String action, // 'view' | 'next'
  }) async {
    final event = action == 'next' ? 'tour_step_next' : 'tour_step_view';
    _dispatch(event, {'step': step, 'step_name': stepName});
  }

  /// Track tour skip (PostHog).
  Future<void> trackTourSkipped({required int atStep}) async {
    _dispatch('tour_skipped', {'at_step': atStep});
  }

  /// Track natural tour completion (PostHog).
  Future<void> trackTourCompleted({
    required int totalTimeSeconds,
    required List<String> viewedSteps,
  }) async {
    _dispatch('tour_completed', {
      'total_time_seconds': totalTimeSeconds,
      'viewed_steps': viewedSteps.join(','),
    });
  }

  /// Track manual tour replay from the profile sheet (PostHog).
  Future<void> trackTourReplayed() async {
    _dispatch('tour_replayed');
  }

  /// Feature-spotlight impression (PROD-2808, PostHog).
  Future<void> trackSpotlightShown({
    required String featureId,
    required String surface,
  }) async {
    _dispatch('spotlight_shown', {'feature_id': featureId, 'surface': surface});
  }

  /// Feature-spotlight dismissed via the dismiss button / backdrop tap
  /// (PROD-2808, PostHog).
  Future<void> trackSpotlightDismissed({
    required String featureId,
    required String surface,
  }) async {
    _dispatch('spotlight_dismissed', {
      'feature_id': featureId,
      'surface': surface,
    });
  }

  /// Feature-spotlight primary CTA tapped (PROD-2808, PostHog).
  Future<void> trackSpotlightCtaTapped({
    required String featureId,
    required String surface,
  }) async {
    _dispatch('spotlight_cta_tapped', {
      'feature_id': featureId,
      'surface': surface,
    });
  }

  /// Track location permission flow (Backend + PostHog)
  Future<void> trackLocationPermission({
    required String action,
    String? permissionStatus,
    bool isFirstPrompt = true,
  }) async {
    _dispatch('location_permission', {
      'action': action,
      if (permissionStatus != null) 'permission_status': permissionStatus,
      'is_first_prompt': isFirstPrompt,
    });
  }

  /// Track auth page views and method selection (Backend + PostHog)
  Future<void> trackAuthPrompt({
    required String page,
    required String action,
    String? method,
    String? referrer,
  }) async {
    _dispatch('auth_prompt', {
      'page': page,
      'action': action,
      if (method != null) 'method': method,
      if (referrer != null) 'referrer': referrer,
    });
  }

  /// Track location suggestion card interactions (Backend + PostHog)
  Future<void> trackLocationSuggestion({required String action}) async {
    _dispatch('location_suggestion', {'action': action});
  }

  /// Push permission events (PostHog only).
  ///
  /// We do NOT emit a `prompt_shown` action — `requestPermission()` can
  /// return cached state without actually showing the OS dialog, so the
  /// event would be unreliable. We emit only terminal outcomes.
  ///
  /// `action` values:
  ///   - 'granted'      — OS allowed AND Klaviyo registered AND token verified
  ///   - 'denied'       — OS auth status is denied or user declined the prompt
  ///   - 'sdk_failure'  — anything else (SDK disabled, init failure, register
  ///                      thrown, or OS-granted-but-no-token — the failure mode
  ///                      this whole feature is trying to detect)
  Future<void> trackPushPermission({
    required String action,
    required String source,
    required String platform,
    String? authStatus,
    String? registrationResult,
  }) async {
    _dispatch('push_permission', {
      'action': action,
      'source': source,
      'platform': platform,
      if (authStatus != null) 'auth_status': authStatus,
      if (registrationResult != null) 'registration_result': registrationResult,
    });
  }

  /// Push suggestion card interactions.
  Future<void> trackPushSuggestion({
    required String action,
    required String source,
    String? authStatus,
  }) async {
    _dispatch('push_suggestion', {
      'action': action,
      'source': source,
      if (authStatus != null) 'auth_status': authStatus,
    });
  }

  // ============ SESSION EVENTS ============

  /// Track session expired (forced logout due to invalid token)
  void trackSessionExpired() {
    _dispatch('session_expired');
  }

  // ============ LOCATION TRACKING EVENTS ============

  /// Track location accuracy status
  void trackLocationAccuracyStatus({
    required bool isPrecise,
    required num accuracyMeters,
    required String platform,
  }) {
    _dispatch('location_accuracy_status', {
      'is_precise': isPrecise,
      'accuracy_meters': accuracyMeters,
      'platform': platform,
    });
  }

  /// Track IP geolocation fallback used
  void trackLocationIpFallback({String? city, String? countryCode}) {
    _dispatch('location_ip_fallback_used', {
      'city': city ?? 'unknown',
      // `country_code`, as the contract declares and as the sibling location
      // events emit. Shipped as `country` until 2026-09-15: the contract check
      // only compared field names with PARAMETER names (`countryCode` matched),
      // never with the emitted key. Check 7 now compares the key.
      if (countryCode != null) 'country_code': countryCode,
    });
  }

  /// Track that IP geolocation was fully unresolved (all providers failed) so
  /// no location could be set. PROD-4278 — replaces the removed locale-based
  /// fallback, which mis-seeded location from the device UI language.
  void trackLocationIpUnresolved() {
    _dispatch('location_ip_unresolved', const {});
  }

  /// Track location shared (one-time share)
  void trackLocationShared({required String mode}) {
    _dispatch('location_shared', {'mode': mode});
  }

  /// Track location sharing enabled
  void trackLocationSharingEnabled() {
    _dispatch('location_sharing_enabled');
  }

  /// Track location sharing disabled
  void trackLocationSharingDisabled() {
    _dispatch('location_sharing_disabled');
  }

  // ============ SCREEN VIEW ============

  /// Log a screen view event (Firebase + PostHog)
  Future<void> trackScreenView({
    required String screenName,
    String? screenClass,
  }) async {
    _dispatch('screen_view', {
      'screen_name': screenName,
      if (screenClass != null) 'screen_class': screenClass,
    });
  }

  // ============ MENU/PROFILE EVENTS ============

  /// Track account menu opened
  Future<void> trackAccountOpen() async {
    _dispatch('account_open');
  }

  /// Track account deletion (fire BEFORE actual deletion)
  Future<void> trackAccountDelete() async {
    _dispatch('account_delete');
  }

  /// Track preferences menu opened
  Future<void> trackPreferencesOpen() async {
    _dispatch('preferences_open');
  }

  /// Track support menu opened
  Future<void> trackSupportOpen() async {
    _dispatch('support_open');
  }

  /// Track support email link clicked
  Future<void> trackSupportEmailClick() async {
    _dispatch('support_email_click');
  }

  // ============ LIST VIEW MODE EVENTS ============

  /// Track list calendar view opened
  Future<void> trackListCalendar({
    required String listId,
    String? listName,
  }) async {
    _dispatch('list_calendar', {
      'list_id': listId,
      if (listName != null) 'list_name': listName,
    });
  }

  /// Track list map view opened
  Future<void> trackListMap({required String listId, String? listName}) async {
    _dispatch('list_map', {
      'list_id': listId,
      if (listName != null) 'list_name': listName,
    });
  }

  // ============ INSTAGRAM EVENTS (PostHog only) ============

  /// Track Instagram connect flow started
  void trackInstagramConnectStart() {
    _dispatch('instagram_connect_start');
  }

  /// Track Instagram connect result (OAuth callback)
  void trackInstagramConnectResult({required bool success, String? reason}) {
    _dispatch('instagram_connect_result', {
      'success': success,
      if (reason != null) 'reason': reason,
    });
  }

  /// Track Instagram disconnect
  void trackInstagramDisconnect({required String connectionId}) {
    _dispatch('instagram_disconnect', {'connection_id': connectionId});
  }

  // ============ BUSINESS CONNECT — VENUE SEARCH (PROD-4270 S5) ============

  /// A manual "Find more" (transient Google) venue search in the Business
  /// Connect claim flow completed. An OUTCOME event — fires once per completed
  /// attempt so it can carry `match_count` (including 0). No raw query, no
  /// precise coordinates. [outcome] ∈ {complete, partial, failed, rate_limited};
  /// [locationSource] ∈ {gps, none}; [errorCategory] ∈ {provider_unavailable,
  /// generic, rate_limited} on a non-success.
  void trackBusinessVenueFindMore({
    required String outcome,
    required int matchCount,
    required String locationSource,
    String? errorCategory,
  }) {
    _dispatch('business_venue_find_more', {
      'tier': 'google',
      'outcome': outcome,
      'match_count': matchCount,
      'location_source': locationSource,
      if (errorCategory != null) 'error_category': errorCategory,
    });
  }

  /// The owner selected a Google "Find more" candidate and it was resolved to a
  /// canonical venue (or the resolve failed). [outcome] ∈ {resolved, failed}.
  void trackBusinessVenueFindMoreResolve({required String outcome}) {
    _dispatch('business_venue_find_more_resolve', {'outcome': outcome});
  }

  // ============ INSTAGRAM SHARE (PROD-1572) ============
  // Frontend captures user-initiated clicks. Submission outcomes (success /
  // failure / status) are emitted server-side from the share endpoint.

  /// Track user dismissing the chat share suggestion ("Send as message").
  void trackInstagramShareChatDismiss({required String urlType}) {
    _dispatch('instagram_share_chat_dismiss', {'url_type': urlType});
  }

  /// Track Instagram share entry-point opened by a user click.
  /// [source] ∈ {lists_hub_menu, list_detail, discovery_help_us, native_share}.
  void trackInstagramShareOpen({required String source, String? listId}) {
    _dispatch('instagram_share_open', {
      'source': source,
      if (listId != null) 'list_id': listId,
    });
  }

  /// Track the share/submit button click (renamed from
  /// `instagram_share_submit`, PROD-3208 — this is a user submitting an
  /// Instagram LINK for extraction, distinct from `instagram_connect_*`
  /// account connection).
  /// [source] ∈ {chat_dialog, lists_hub_menu, list_detail, discovery_help_us, native_share}.
  void trackInstagramLinkSubmitted({
    required String source,
    required String urlType,
    String? listId,
  }) {
    _dispatch('instagram_link_submitted', {
      'source': source,
      'url_type': urlType,
      if (listId != null) 'list_id': listId,
    });
  }

  /// Track the user dismissing the share entry-point without submitting.
  /// Today only fires from the Android share-intent list picker (PROD-2725)
  /// when the user swipes the sheet down / taps the scrim / hits back —
  /// other share surfaces submit or dismiss inline with no abandonment.
  void trackInstagramShareDismissed({
    required String source,
    required String urlType,
  }) {
    _dispatch('instagram_share_dismissed', {
      'source': source,
      'url_type': urlType,
    });
  }

  /// Track a click on the Instagram share processing banner.
  /// [action] ∈ {review, view_item, dismiss}.
  /// [shareStatus] ∈ {processing, completed, failed}.
  void trackInstagramShareBannerAction({
    required String action,
    required String shareStatus,
    String? classification,
    int? eventCount,
  }) {
    _dispatch('instagram_share_banner_action', {
      'action': action,
      'share_status': shareStatus,
      if (classification != null) 'classification': classification,
      if (eventCount != null) 'event_count': eventCount,
    });
  }

  /// Track the user confirming the review sheet (kept some/all items).
  void trackInstagramShareReviewSave({
    required int keptCount,
    required int totalCount,
    required bool venueAdded,
    String? listId,
  }) {
    _dispatch('instagram_share_review_save', {
      'kept_count': keptCount,
      'total_count': totalCount,
      'venue_added': venueAdded,
      if (listId != null) 'list_id': listId,
    });
  }

  /// Track the user cancelling the review sheet without saving.
  void trackInstagramShareReviewCancel({
    required int eventCount,
    String? listId,
  }) {
    _dispatch('instagram_share_review_cancel', {
      'event_count': eventCount,
      if (listId != null) 'list_id': listId,
    });
  }

  // ============ OUTBOUND SHARE FUNNEL (PROD-2785) ============
  // Client half of the share-card funnel. Server emits
  // share_descriptor_resolved (descriptor build) and
  // share_channel_asset_generated (PNG render); client emits
  // share_intent_fired (channel tile tap) and share_completed (terminal
  // outcome of the handoff). Together they close "user tapped a channel
  // → user actually posted / cancelled / errored".

  /// Fires when the user taps a channel tile in [SokoShareSheet] or the
  /// surface-level [IgDirectShareButton]. [entryPoint] ∈
  /// {share_sheet, direct_button, deep_link} — `deep_link` when the sheet
  /// was auto-presented by a `?share=` deep link (PROD-3319). [channel]
  /// is the stable snake_case name from `ShareChannel.analyticsName`.
  void trackShareIntent({
    required String context,
    required String subjectId,
    required String channel,
    required String entryPoint,
    String? subjectKind,
  }) {
    _dispatch('share_intent_fired', {
      'context': context,
      if (subjectKind != null) 'subject_kind': subjectKind,
      'subject_id': subjectId,
      'channel': channel,
      'entry_point': entryPoint,
    });
  }

  /// Fires when a share intent resolves to a terminal state. [status] ∈
  /// {success, ig_not_installed, whatsapp_not_installed, handoff_error}.
  /// [latencyMs] is intent→completed wall-clock — null if the caller
  /// didn't measure it. [errorCode] carries the failure discriminator
  /// on non-success statuses.
  void trackShareCompleted({
    required String context,
    required String subjectId,
    required String channel,
    required String status,
    String? subjectKind,
    int? latencyMs,
    String? errorCode,
  }) {
    _dispatch('share_completed', {
      'context': context,
      if (subjectKind != null) 'subject_kind': subjectKind,
      'subject_id': subjectId,
      'channel': channel,
      'status': status,
      if (latencyMs != null) 'latency_ms': latencyMs,
      if (errorCode != null) 'error_code': errorCode,
    });
  }

  // ============ PHOTO→EVENT CONTRIBUTION EVENTS (PROD-2404) ============

  /// Track the photo-contribution sheet opening.
  /// [source] ∈ {create_menu, discovery_help_us, native_share}.
  void trackPhotoContributionOpen({required String source}) {
    _dispatch('photo_contribution_open', {'source': source});
  }

  /// Track the submit-button click. Fires once per submitted POST.
  ///
  /// Renamed from `photo_contribution_submit` (PROD-3208): this is the
  /// community-supply act — a user contributing an event — the L3 behaviour
  /// the tracking spec most wants to grow. `entity_type`/`has_url`/
  /// `has_image` are constant for the current photo-only flow and will
  /// diversify when other suggestion paths ship. The photo_contribution_
  /// open/success/failure pipeline siblings keep their names — they
  /// describe the photo-extraction mechanics, not the supply act.
  /// [hasNote] / [hasVenue] let us see how often the optional fields are used.
  void trackEventSuggested({
    required String source,
    required bool hasNote,
    required bool hasVenue,
    String? city,
    String? country,
  }) {
    _dispatch('event_suggested', {
      'entity_type': 'event',
      'has_url': false,
      'has_image': true,
      'source': source,
      'has_note': hasNote,
      'has_venue': hasVenue,
      if (city != null) 'city': city,
      if (country != null) 'country': country,
    });
  }

  /// Fires once when polling lands on `extracted` with non-empty `event_ids`.
  void trackPhotoContributionSuccess({
    required String contributionId,
    required int eventCount,
  }) {
    _dispatch('photo_contribution_success', {
      'contribution_id': contributionId,
      'event_count': eventCount,
    });
  }

  /// Fires once when polling lands on `failed` (or `extracted` with empty
  /// event_ids — legacy bucket). [failureCategory] lets us split the
  /// "no events detected" path from infra errors in dashboards.
  void trackPhotoContributionFailure({
    required String contributionId,
    required String failureCategory,
  }) {
    _dispatch('photo_contribution_failure', {
      'contribution_id': contributionId,
      'failure_category': failureCategory,
    });
  }

  // ============ EXPERIMENT EVENTS (PostHog only, once-per-session) ============

  bool _hasTrackedExposure = false;

  /// Track experiment exposure — when user sees the home page.
  /// Fires once per session. PostHog only.
  void trackExperimentExposure({
    required String experiment,
    required String variant,
  }) {
    if (_hasTrackedExposure) return;
    _hasTrackedExposure = true;
    _dispatch('experiment_exposure', {
      'experiment': experiment,
      'variant': variant,
    });
  }

  // `first_message_sent` is backend-owned (PROD-3210). The client emission
  // was structurally dead: the registry routed it {Dest.backend} only, and
  // the backend relay pins only_destinations=database, so client fires never
  // reached PostHog — and its trigger (session creation, instance-scoped
  // guard, dead experiment props) couldn't express "first message ever per
  // user" anyway. The backend derives it from the messages table instead.

  // ============ DISCOVERY SHELVES (PROD-1522) ============

  /// `shelfId` values currently fired from this surface. Stable strings so
  /// PostHog dashboards survive future shelf reordering experiments.
  final Set<String> _shelvesViewedThisSession = {};

  /// Fired the first time a Discovery shelf comes into view in a given
  /// session. Subsequent scrolls do not refire — analytics dashboards count
  /// distinct viewers per shelf, not impression bursts.
  void trackDiscoveryShelfViewed({required String shelfId}) {
    if (!_shelvesViewedThisSession.add(shelfId)) return;
    _dispatch('discovery_shelf_viewed', {'shelf_id': shelfId});
  }

  /// Fired on each card tap inside a Discovery shelf **or a server-driven feed
  /// block** (PROD-4076).
  ///
  /// **Exactly one of [shelfId] / [blockId], never both** — the same contract
  /// `item_impression` carries, and for the same reason: no surface is a shelf
  /// and a block at once, so a row holding both describes a layout that does
  /// not exist, and the failure is a plausible, wrong, silent `GROUP BY`.
  ///
  /// The join keys mirror `trackItemImpression` deliberately, so impressions
  /// pair with clicks into a CTR on either surface.
  ///
  /// ⚠️ **The backend copy of this event does not land yet.** It is dispatched
  /// to `{Dest.backend, Dest.posthog}` but is absent from the backend
  /// `EVENT_REGISTRY`, so the write half has 422'd since it shipped — 0 rows,
  /// ever. PostHog is unaffected. PROD-4077 registers it; until that deploys,
  /// verify this event in PostHog rather than in `analytics_events`.
  void trackDiscoveryShelfCardClicked({
    required int cardIndex,
    required String itemId,
    required String itemType, // 'list' | 'venue' | 'event' | 'person'
    String? shelfId,
    String? blockId,
    String? surface,
    String? slateKind,
  }) {
    assert(
      (shelfId == null) != (blockId == null),
      'discovery_shelf_card_clicked carries EXACTLY ONE of shelf_id / block_id',
    );
    _dispatch('discovery_shelf_card_clicked', {
      if (shelfId != null) 'shelf_id': shelfId,
      if (blockId != null) 'block_id': blockId,
      if (surface != null) 'surface': surface,
      'card_index': cardIndex,
      'item_id': itemId,
      'item_type': itemType,
      // Which ranking served the feed page this card sat on (PROD-4373):
      // 'personalized' | 'safe_bet'. Home-feed clicks only; legacy shelves
      // and run-less pages omit it.
      if (slateKind != null) 'slate_kind': slateKind,
    });
  }

  /// Fired when the trailing "Ver mais" tile at the end of a Discovery
  /// shelf is tapped, opening the shelf's vertical see-more page.
  /// `shelf_id` matches `discovery_shelf_card_clicked` so dashboards can
  /// join tile taps to the shelf they came from.
  ///
  /// **Exactly one of [shelfId] / [blockId]**, same contract as the card click.
  /// No `surface` here, deliberately: the two see-all affordances are already
  /// told apart by which key is present, so a third signal would restate a
  /// distinction the keys already make. It becomes necessary only if one block
  /// ever grows TWO see-all affordances, which would collide on one `block_id`
  /// with nothing to separate them (agreed with BE, 2026-08-28). Properties are
  /// free-form, so adding it later is a client change with no backend work.
  void trackDiscoveryShelfSeeMoreClicked({String? shelfId, String? blockId}) {
    assert(
      (shelfId == null) != (blockId == null),
      'discovery_shelf_see_more_clicked carries EXACTLY ONE of '
      'shelf_id / block_id',
    );
    _dispatch('discovery_shelf_see_more_clicked', {
      if (shelfId != null) 'shelf_id': shelfId,
      if (blockId != null) 'block_id': blockId,
    });
  }

  /// Fired on each card tap inside the Discovery History grid (PROD-1521).
  /// Mirrors `trackDiscoveryShelfCardClicked` but the History grid is not a
  /// shelf — it has its own event name so dashboards can analyse recent-
  /// activity engagement separately from editorial shelves.
  void trackDiscoveryHistoryCardClicked({
    required int cardIndex,
    required String itemId,
    required String itemType, // 'list' | 'venue' | 'event'
  }) {
    _dispatch('discovery_history_card_clicked', {
      'card_index': cardIndex,
      'item_id': itemId,
      'item_type': itemType,
    });
  }

  // ============ NOTIFICATIONS (PROD-2511) ============

  /// Fired when the inbox bell button is tapped (Backend + PostHog).
  /// `unreadCount` is the badge count at the moment of tap so dashboards
  /// can split "opened with new" vs "opened empty".
  void trackNotificationInboxOpen({required int unreadCount}) {
    _dispatch('notification_inbox_open', {'unread_count': unreadCount});
  }

  /// Fired on Por ler ↔ Histórico tab switch (Backend + PostHog).
  /// `tab` ∈ {'inbox', 'history'}.
  void trackNotificationInboxTabChange({required String tab}) {
    _dispatch('notification_inbox_tab_change', {'tab': tab});
  }

  /// Fired when a row is tapped in the in-app inbox (Backend + PostHog).
  /// Distinct from `notification_push_tap`, which fires on the OS-level
  /// push tap. `category` is the per-row [NotificationCategory.wireName].
  ///
  /// [notificationType] is the per-row wire sub-type — for the social
  /// category: 'follow_request', 'new_follower', 'follow_request_accepted',
  /// 'followed_back', 'zine_followed', 'zine_item_added',
  /// 'saved_added_to_zine', 'memory_bio_ready'. Without it all eight social
  /// types were indistinguishable in PostHog (you'd have to reverse-engineer
  /// the type out of `route_path`), so per-type click-through — the whole
  /// point of measuring notifications — was unanswerable.
  void trackNotificationClick({
    required String notificationId,
    required String category,
    String? routePath,
    String? notificationType,
  }) {
    _dispatch('notification_click', {
      'notification_id': notificationId,
      'category': category,
      if (routePath != null) 'route_path': routePath,
      'notification_type': notificationType ?? 'unknown',
    });
  }

  /// Fired on swipe-to-dismiss in the inbox (Backend + PostHog).
  ///
  /// [notificationType] — see [trackNotificationClick]. Dismissal per type is
  /// the negative signal that pairs with click-through: a type with low clicks
  /// *and* high dismissals is one to stop sending.
  void trackNotificationDismiss({
    required String notificationId,
    required String category,
    String? notificationType,
  }) {
    _dispatch('notification_dismiss', {
      'notification_id': notificationId,
      'category': category,
      'notification_type': notificationType ?? 'unknown',
    });
  }

  /// Fired when the "marcar todas como lidas" bulk action runs
  /// (Backend + PostHog). `clearedCount` is the count of unread rows
  /// in the optimistic flip at click time.
  void trackNotificationMarkAllRead({required int clearedCount}) {
    _dispatch('notification_mark_all_read', {'cleared_count': clearedCount});
  }

  /// Fired when the user taps an OS-level push notification
  /// (Backend + PostHog). `entry` distinguishes the FCM entry point:
  /// `background` (onMessageOpenedApp), `cold_start` (getInitialMessage),
  /// or `foreground_toast` (the in-app "Abrir" action).
  ///
  /// [notificationType] — see [trackNotificationClick]. Paired with
  /// `notification_received` it gives per-type push open-rate, which is what
  /// tells us which notification types actually bring people back.
  void trackNotificationPushTap({
    required String notificationId,
    required String entry,
    String? category,
    String? notificationType,
  }) {
    _dispatch('notification_push_tap', {
      'notification_id': notificationId,
      'entry': entry,
      if (category != null) 'category': category,
      'notification_type': notificationType ?? 'unknown',
    });
  }

  /// Fired when FCM delivers a push while the app is in the foreground
  /// (`onMessage`). Gives a "delivered" signal to compute open-rate
  /// (paired with `notification_push_tap`). Backend + PostHog.
  /// [notificationType] — see [trackNotificationClick]; this is the
  /// denominator of per-type open-rate.
  void trackNotificationReceived({
    required String notificationId,
    String? category,
    String? notificationType,
  }) {
    _dispatch('notification_received', {
      'notification_id': notificationId,
      if (category != null) 'category': category,
      'notification_type': notificationType ?? 'unknown',
    });
  }

  /// Fired when `MyRemindersSheet` opens (Backend + PostHog).
  /// `surface` tags the trigger surface ('menu', 'discovery', 'yours', …).
  void trackMyRemindersOpen({required int reminderCount, String? surface}) {
    _dispatch('my_reminders_open', {
      'reminder_count': reminderCount,
      if (surface != null) 'surface': surface,
    });
  }

  /// Fired on tap of a reminder card in `MyRemindersSheet` (Backend + PostHog).
  /// `remindersForEvent` is the count of pending reminders the user has set
  /// on the tapped event.
  void trackMyRemindersEventClick({
    required String eventId,
    required int remindersForEvent,
  }) {
    _dispatch('my_reminders_event_click', {
      'event_id': eventId,
      'reminders_for_event': remindersForEvent,
    });
  }

  /// Fired on a per-category notification preference toggle in
  /// `NotificationCategoriesSection` (Backend + PostHog). `category` is the
  /// wire name ('reminders' / 'async_jobs' / 'chat' / 'social' /
  /// 'discovery' / 'feedback'); `enabled` is the new state.
  void trackNotificationPreferencesChange({
    required String category,
    required bool enabled,
  }) {
    _dispatch('notification_preferences_change', {
      'category': category,
      'enabled': enabled,
    });
  }

  /// Fired on a marketing-channel toggle in `PreferencesScreen` — the
  /// per-channel rows (email, SMS, WhatsApp) and the OS push permission
  /// toggle (Backend + PostHog). `channel` ∈ {'email', 'sms', 'whatsapp',
  /// 'push'}; `enabled` is the new state; `source` is the surface that
  /// triggered the change (default 'preferences_screen').
  void trackMarketingPreferencesChange({
    required String channel,
    required bool enabled,
    String source = 'preferences_screen',
  }) {
    _dispatch('marketing_preferences_change', {
      'channel': channel,
      'enabled': enabled,
      'source': source,
    });
  }

  // ============ SOCIAL GRAPH ============
  //
  // All PostHog-only for v1 — see the SOCIAL GRAPH block in [eventRegistry]
  // for why (backend 422s on unregistered event names).
  //
  // A note on sentinels rather than omitted keys: PostHog strips null
  // properties, and an omitted key is indistinguishable from a dropped one in
  // a breakdown — the rows just vanish. Every property that a breakdown is
  // meant to slice on therefore falls back to a sentinel ('unknown') instead
  // of being conditionally omitted. See
  // docs/learnings/posthog-drops-null-properties-use-a-sentinel.md.

  /// Fired when the user follows someone, from any of the seven entry points.
  ///
  /// [source] ∈ {'profile_header', 'follow_list', 'suggestions',
  /// 'people_search', 'contact_match', 'follow_request', 'profile_banner'} —
  /// this is what tells us which discovery surface actually produces follows.
  ///
  /// [resultingState] matters more than it looks: following a private account
  /// creates a *pending request*, not a follow. Conflating the two would make
  /// the follow funnel look healthier than it is, so this distinguishes
  /// 'following' from 'requested'. It doubles as the account-privacy signal —
  /// 'requested' comes straight off the API response and *means* the target is
  /// private — which is why there is no separate `target_is_private` here: it
  /// would be a redundant copy, and list rows don't reliably carry the field
  /// (defaulting it to `false` there would put fabricated data in PostHog).
  ///
  /// [isSoko] flags the @soko account, whose follow edge is created server-side
  /// for every user. Any follower metric that doesn't exclude it is measuring
  /// an automatic write, not social behaviour.
  ///
  /// The name is `is_soko`, not `target_is_official`, because that property
  /// already exists — `listAnalyticsProps` computes the identical
  /// `ownerHandle == EnvironmentConfig.sokoHandle` for the list events, and
  /// PROD-3035 made it a vocabulary shared with the backend notification events
  /// and Klaviyo. A second name for one concept means a filter written once
  /// stops working across event families. `target_is_official` was arguably the
  /// more precise name; consistency won.
  void trackUserFollow({
    required String targetUserId,
    required String source,
    required String resultingState,
    required bool isSoko,
    bool wasFollowBack = false,
    AnalyticsActionContext? actionContext,
  }) {
    _dispatch('user_follow', {
      'target_user_id': targetUserId,
      'source': source,
      'resulting_state': resultingState,
      'is_soko': isSoko,
      'was_follow_back': wasFollowBack,
    }, actionContext);
  }

  /// Fired on unfollow *and* on cancelling a pending follow request — both hit
  /// the same DELETE endpoint.
  ///
  /// [previousState] ∈ {'following', 'requested'} separates the two: a
  /// cancelled request is a very different signal from an unfollow (the first
  /// says "I changed my mind before they answered", the second says "this
  /// wasn't worth it"), and lumping them together would poison the churn rate.
  void trackUserUnfollow({
    required String targetUserId,
    required String source,
    required String previousState,
    required bool isSoko,
    AnalyticsActionContext? actionContext,
  }) {
    _dispatch('user_unfollow', {
      'target_user_id': targetUserId,
      'source': source,
      'previous_state': previousState,
      'is_soko': isSoko,
    }, actionContext);
  }

  /// Fired when a profile screen opens — `/u/:handle`, `/@:handle` or
  /// `/profile`.
  ///
  /// This is the denominator of the social funnel: profile_open → user_follow.
  /// It also closes a real gap — zines have `list_link_opened`, so a shared
  /// zine link's landings are measurable, while a shared *profile* link's were
  /// completely invisible. [source] carries 'deep_link' for that case.
  ///
  /// [relationship] ∈ {'self', 'none', 'following', 'follower', 'mutual',
  /// 'requested'} — lets us ask whether people who already follow each other
  /// keep coming back to each other's profiles.
  /// [isSoko] — see [trackUserFollow] for why this is `is_soko` and not
  /// `is_official`.
  void trackProfileOpen({
    required String source,
    required bool isSelf,
    required bool isSoko,
    required bool isPrivate,
    required String relationship,
    String? targetUserId,
  }) {
    _dispatch('profile_open', {
      'source': source,
      // Kept as `is_self` rather than the list vocabulary's `owner_is_self`:
      // a list has an owner distinct from the viewer, a profile *is* a user.
      'is_self': isSelf,
      'is_soko': isSoko,
      'is_private': isPrivate,
      'relationship': relationship,
      if (targetUserId != null) 'target_user_id': targetUserId,
    });
  }

  /// Fired on accept / reject of an incoming follow request, and on removing
  /// an existing follower.
  ///
  /// [action] ∈ {'accept', 'reject', 'remove_follower'}; [source] ∈
  /// {'requests_screen', 'profile_banner', 'followers_list'}. A low or slow
  /// accept rate is the signal that private accounts are throttling graph
  /// growth.
  void trackFollowRequestAction({
    required String action,
    required String source,
  }) {
    _dispatch('follow_request_action', {'action': action, 'source': source});
  }

  // ============ PEOPLE DISCOVERY ============

  /// Fired when a people-search query resolves on `/find-people`.
  ///
  /// Sends [queryLength], not the query text: a people search is somebody
  /// typing a person's name or handle, and the length answers the analytical
  /// question ("are short/partial queries failing?") without putting personal
  /// data in PostHog. A high share of `result_count: 0` means either the
  /// search is bad or the user base is too thin — both worth knowing.
  void trackPeopleSearch({required int queryLength, required int resultCount}) {
    _dispatch('people_search', {
      'query_length': queryLength,
      'result_count': resultCount,
    });
  }

  /// Fired when a batch of suggested users is displayed.
  ///
  /// Deliberately batched rather than per-card: per-card impressions would be
  /// high-volume and add nothing, since the *taps* already arrive as
  /// `user_follow` with `source: 'suggestions'`. [source] ∈ {'find_people',
  /// 'profile_locals_tab'}.
  /// [suggestionCount] follows the established `<thing>_count` naming
  /// (`follower_count`, `result_count`, `member_count`, …) — a bare `count`
  /// would have been the only one in the contract.
  void trackSuggestedUsersViewed({
    required int suggestionCount,
    required String source,
  }) {
    _dispatch('suggested_users_viewed', {
      'suggestion_count': suggestionCount,
      'source': source,
    });
  }

  /// Fired across the contact-sync flow on `/find-people/contacts`.
  ///
  /// [status] ∈ {'started', 'completed', 'failed', 'permission_denied'}.
  /// Contact sync imports an already-existing social graph from outside the
  /// app, so it's plausibly the biggest growth lever here — and today we can't
  /// even tell how many people try it. [matchCount] / [contactCount] are only
  /// meaningful on 'completed'.
  void trackContactSync({
    required String status,
    int? matchCount,
    int? contactCount,
  }) {
    _dispatch('contact_sync', {
      'status': status,
      if (matchCount != null) 'match_count': matchCount,
      if (contactCount != null) 'contact_count': contactCount,
    });
  }

  /// Fired when a user opens the system share sheet to invite someone.
  ///
  /// Invite is the top of the growth funnel — it turns an existing user into
  /// new signups — yet it was the one social action with no instrumentation.
  /// [source] ∈ {'contact_match', 'find_people', 'profile_share'} names the
  /// surface the invite was launched from.
  ///
  /// This fires when the share sheet is *opened*, not when a message is
  /// confirmed sent: the native share sheet doesn't reliably report
  /// completion, so "shared" is the honest ceiling of what we can observe.
  void trackInviteShared({required String source}) {
    _dispatch('invite_shared', {'source': source});
  }
}
