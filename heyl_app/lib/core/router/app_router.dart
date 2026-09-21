import 'package:flutter/cupertino.dart' show CupertinoPage;
import 'package:flutter/foundation.dart'
    show debugPrint, defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../config/environment.dart';
import '../services/experiment_service.dart';
import '../services/storage_service.dart' show sharedPreferencesProvider;
import '../services/token_refresh_service.dart';
import '../theme/app_colors.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../features/auth/screens/email_login_screen.dart';
import '../../features/auth/screens/email_otp_verification_screen.dart';
import '../../features/auth/screens/login_screen.dart';
import '../../features/profile/screens/contact_matches_screen.dart';
import '../../features/profile/screens/crop_avatar_screen.dart';
import '../../features/profile/screens/discover_people_screen.dart';
import '../../features/profile/screens/edit_profile_screen.dart';
import '../../features/profile/screens/follow_list_screen.dart';
import '../../features/profile/screens/public_profile_screen.dart';
import '../../features/auth/screens/otp_verification_screen.dart';
import '../../features/auth/screens/oauth_callback_screen.dart';
import '../../features/auth/screens/forgot_password_screen.dart';
import '../../features/auth/widgets/auth_shell.dart';
import '../../features/auth/screens/reset_password_screen.dart';
import '../../features/auth/screens/activation_pending_screen.dart';
import '../../features/auth/screens/activation_callback_screen.dart';
import '../../features/auth/screens/guest_gate_screen.dart';
import '../../features/auth/screens/soko_welcome_screen.dart';
import '../../features/auth/screens/soko_location_ask_screen.dart';
import '../../features/chat/screens/chat_screen.dart';
import '../../features/instagram/screens/instagram_callback_screen.dart';
import '../../features/lists/screens/create_zine_screen.dart';
import '../../features/share/utils/share_deep_link.dart';
import '../../features/library/models/library_filter.dart';
import '../../features/library/screens/library_screen.dart';
import '../../features/lists/screens/list_page_screen.dart';
import '../../data/models/entity_signal.dart' show SignalEntityType;
import '../../features/entity_signals/screens/interested_screen.dart';
import '../../features/lists/screens/list_followers_screen.dart';
import '../../features/legal/screens/privacy_policy_screen.dart';
import '../../features/legal/screens/terms_of_service_screen.dart';
import '../../features/legal/screens/account_deletion_screen.dart';
import '../../features/legal/screens/account_suspended_screen.dart';
import '../../features/legal/screens/support_screen.dart' as legacy_support;
import '../../features/weekly_bundle/screens/weekly_bundle_screen.dart';
import '../../features/weekly_bundle/weekly_bundle_nav.dart';
import '../../features/campaigns/screens/campaign_deep_link_screen.dart';
import '../../features/feature_spotlight/spotlight_route_observer.dart';
import '../../features/onboarding/screens/hello_screen.dart';
import '../../features/onboarding/screens/onboarding_screen.dart';
import '../../features/onboarding_chat/screens/onboarding_chat_preview_page.dart';
import '../../features/onboarding_chat/screens/onboarding_chat_screen.dart';
import '../../features/onboarding_chat/providers/needs_onboarding_provider.dart';
import '../../features/user_profiling/providers/user_profiling_gate_provider.dart';
import '../../features/user_profiling/screens/persona_reveal_screen.dart';
import '../../features/user_profiling/screens/smart_lists_screen.dart';
import '../../features/user_profiling/screens/user_profiling_flow_screen.dart';
import '../../features/user_profiling/screens/user_profiling_loading_screen.dart';
import '../../features/discovery/feed_v2/screens/discovery_variant_page.dart';
import '../../features/discovery/feed_v2/screens/feed_bundle_see_all_screen.dart';
import '../../features/discovery/screens/discovery_screen.dart';
import '../../features/discovery/widgets/discovery_deep_link_resolver.dart';
import '../../features/discovery/screens/shelf_see_more_screen.dart';
import '../../features/discovery/widgets/discovery_shell.dart';
import '../../features/discovery/widgets/discovery_typeahead_overlay.dart';
import '../../features/daily_drop/screens/daily_drop_detail_screen.dart';
import '../../features/daily_drop/screens/recommendation_deep_link_screen.dart';
import '../../features/event_detail/screens/event_detail_screen.dart';
import '../../features/lists/screens/list_in_context_detail_screen.dart';
import '../../features/venue_detail/screens/venue_detail_screen.dart';
import '../../data/models/feed_home.dart';
import '../../data/models/user_profile.dart';
import '../../data/models/daily_drop.dart';
import '../../shared/navigation/detail_siblings.dart';
import '../../features/lists/providers/unified_list_provider.dart';
import '../../features/onboarding/providers/onboarding_provider.dart';
import '../../features/onboarding/providers/login_history_provider.dart';
import '../../providers/preferences_provider.dart';
import '../../features/about/screens/about_screen.dart';
import '../../features/memory/screens/memory_page_screen.dart';
import '../../features/memory/screens/memory_screen.dart';
import '../../features/legal/screens/ai_data_screen.dart';
import '../../features/account/screens/account_screen.dart';
import '../../features/account/screens/blocked_users_screen.dart';
import '../../features/account/screens/merge_accounts_screen.dart';
import '../../features/business_connections/screens/business_connections_screen.dart';
import '../../features/business_home/providers/business_session_provider.dart';
import '../../features/business_home/screens/business_home_screen.dart';
import '../../features/notifications/screens/notifications_screen.dart';
import '../../features/preferences/screens/language_settings_screen.dart';
import '../../features/preferences/screens/preferences_screen.dart';
import '../../features/preferences/screens/whatsapp_settings_screen.dart';
import '../../features/profile/screens/menu_screen.dart';
import '../../features/support/screens/support_screen.dart';
import '../../features/map/screens/map_screen.dart';
import '../../features/map/widgets/map_open_transition.dart';
import '../../features/map/providers/map_seed_provider.dart';
import '../../features/map/utils/map_camera.dart';
import '../../features/map/utils/map_deep_link_params.dart';
import '../../providers/auth_provider.dart';
import '../../providers/location_provider.dart';
import '../services/unified_analytics_service.dart';

/// The link the app was cold-launched with (`AppLinks().getInitialLink()`),
/// or `null` on a normal launch. Overridden in `main.dart`'s root
/// [ProviderScope]. Read by the `/splash` redirect (PROD-2480) so a cold-start
/// shared deep link is delivered straight from the redirect instead of being
/// clobbered by the auth-init splash→home/login bounce. Also read by
/// `app.dart::_initDeepLinks` to fire the full `_handleDeepLink` pipeline
/// (attribution, referral, Klaviyo) once the first frame is up.
final initialDeepLinkProvider = Provider<Uri?>((ref) => null);

/// The shared-element page: a push long enough for a [Hero] flight to run.
///
/// **Only the routes that still carry a flight use this** — the in-list
/// (zine → item) detail routes, the daily-drop detail, and the feed-bundle
/// see-all. Every other pushed route uses [_slidePage] and opens from the
/// side. We deliberately reverted the "everything flies" era: when every page
/// open had a shared element, the flight stopped meaning anything.
///
/// - **iOS**: [CupertinoPage] — its built-in
///   `_CupertinoBackGestureDetector` drives the route's transition
///   animation interactively. The user drags the page from the left
///   edge, snap-back kicks in on reverse / release-before-threshold, and
///   the pop completes when released past threshold or with rightward
///   velocity.
/// - **Other platforms (Android, web)**: a ~300 ms [FadeTransition]
///   ([CustomTransitionPage]). PROD-4160-followup reintroduces a non-zero
///   transition here (previously [NoTransitionPage], PROD-1804) purely so the
///   zine → detail shared-element **Hero flights have time to run** on Android
///   and web — a Hero cannot animate across a zero-duration page. A fade (not a
///   slide) keeps the background quiet so the eye tracks the flying poster +
///   colour panel. Android still has no in-app swipe-back (system back /
///   hardware button); web still falls back to browser back. iOS keeps its
///   native [CupertinoPage] slide, which already gives Heroes their flight
///   window AND preserves the interactive edge swipe-back.
/// Web/Android page transition for the shared-element routes ([_detailPage]).
///
/// **Push (forward): no fade.** The incoming page paints opaque from frame 1,
/// so the transition can't render it semi-transparent and reveal the feed's
/// light header beneath it as a "white bar/row" (reported on web). The non-zero
/// route [transitionDuration] is still what gives the shared-element Hero
/// flights their window — a Hero cannot animate across a zero-duration page —
/// so the poster + colour-panel Heroes still fly. The content-pop that the
/// push-fade used to hide is now owned by [SokoRevealOnSettle], which holds the
/// below-hero content until the flight lands and then reveals it deliberately.
///
/// **Pop (reverse): a gentle fade-out** keeps the back navigation smooth (the
/// outgoing detail fades to reveal the feed destination — no white, since the
/// destination is the feed, not a light header seam).
Widget _heroFriendlyPageTransition(
  BuildContext context,
  Animation<double> animation,
  Animation<double> secondaryAnimation,
  Widget child,
) {
  final popping =
      animation.status == AnimationStatus.reverse ||
      animation.status == AnimationStatus.dismissed;
  if (popping) {
    return FadeTransition(
      opacity: CurvedAnimation(parent: animation, curve: Curves.easeInOut),
      child: child,
    );
  }
  return child;
}

Page<T> _detailPage<T>({
  required String name,
  required LocalKey key,
  required Widget child,
  Object? arguments,
}) {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return CupertinoPage<T>(
      name: name,
      key: key,
      arguments: arguments,
      child: child,
    );
  }
  return CustomTransitionPage<T>(
    name: name,
    key: key,
    arguments: arguments,
    // Non-zero purely so the shared-element Hero flights have a window — a
    // Hero cannot animate across a zero-duration page. The push paints opaque
    // (no fade) so it never reveals the feed beneath as a white row; see
    // [_heroFriendlyPageTransition].
    transitionDuration: const Duration(milliseconds: 460),
    reverseTransitionDuration: const Duration(milliseconds: 400),
    transitionsBuilder: _heroFriendlyPageTransition,
    child: child,
  );
}

/// The default page transition: the page simply **opens from the side**.
///
/// - **iOS**: [CupertinoPage] — already a side slide, and the only thing that
///   carries the interactive edge swipe-back. Never swap it for a
///   [CustomTransitionPage]; see
///   `docs/learnings/customtransitionpage-loses-ios-swipe-back.md`.
/// - **Android/web**: the incoming child slides `Offset(1, 0) → 0`; the
///   outgoing child stays put (no parallax, so the browser only repaints the
///   incoming layer — same reasoning as [_authSlidePage]).
///
/// Use this for every pushed route. [_detailPage] — the shared-element variant
/// — is reserved for the handful of routes that still carry a flight.
Page<T> _slidePage<T>({
  required String name,
  required LocalKey key,
  required Widget child,
  Object? arguments,
}) {
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return CupertinoPage<T>(
      name: name,
      key: key,
      arguments: arguments,
      child: child,
    );
  }
  return CustomTransitionPage<T>(
    name: name,
    key: key,
    arguments: arguments,
    transitionDuration: const Duration(milliseconds: 300),
    reverseTransitionDuration: const Duration(milliseconds: 250),
    transitionsBuilder: (context, animation, secondary, child) {
      return SlideTransition(
        position: animation.drive(
          Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.easeOut)),
        ),
        child: child,
      );
    },
    child: child,
  );
}

/// Slide-from-right transition used by every screen inside the auth funnel
/// shell (welcome, login form, register, OTP). The incoming child slides
/// `Offset(1, 0) → 0`; the outgoing child stays put (no parallax) so the
/// browser only repaints the incoming layer — keeps the transition crisp
/// on Flutter web's dev builds. SokoBrandHeader lives in [AuthShell],
/// outside this transition, so the wordmark stays anchored as the routed
/// child slides in/out below it.
CustomTransitionPage<T> _authSlidePage<T>(GoRouterState state, Widget child) {
  return CustomTransitionPage<T>(
    key: state.pageKey,
    name: state.name ?? state.matchedLocation,
    child: child,
    transitionDuration: const Duration(milliseconds: 220),
    reverseTransitionDuration: const Duration(milliseconds: 180),
    transitionsBuilder: (context, animation, secondary, child) {
      return SlideTransition(
        position: animation.drive(
          Tween<Offset>(
            begin: const Offset(1, 0),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.easeOut)),
        ),
        child: child,
      );
    },
  );
}

/// App route paths
/// Rendered when a route that REQUIRES a `state.extra` is built without one,
/// bouncing to [fallback] instead of crashing or sitting on a blank page.
///
/// **Why a `redirect` is not enough on its own.** `redirect` runs when a route
/// is RESOLVED; `pageBuilder` runs again on every router rebuild of a page
/// already on the stack. `extra` cannot survive a web history re-parse, and
/// this app sets `refreshListenable`, so an auth or token tick is enough to
/// rebuild such a page with a null `extra` that `redirect` is never
/// re-consulted about. A builder that casts therefore throws
/// `Null is not a subtype of …` and paints a red screen over a page the user
/// was reading — observed on `/feed/bundle/:blockId` (Zé, 2026-08-31, browser)
/// and latent in exactly the same shape on `/drop/detail/:id`.
///
/// Paints the paper surface rather than nothing, so the bounce reads as a
/// frame of the page being left instead of a white flash.
class _RouteWithoutItsExtra extends StatefulWidget {
  const _RouteWithoutItsExtra({required this.fallback});

  /// Where to send the user — match the route's own `redirect` target, so the
  /// two paths agree about where "this page cannot render" leads.
  final String fallback;

  @override
  State<_RouteWithoutItsExtra> createState() => _RouteWithoutItsExtraState();
}

class _RouteWithoutItsExtraState extends State<_RouteWithoutItsExtra> {
  @override
  void initState() {
    super.initState();
    // Post-frame: navigating during build would assert.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.go(widget.fallback);
    });
  }

  @override
  Widget build(BuildContext context) =>
      const ColoredBox(color: AppColors.sokoPaper);
}

/// Builds the Daily Drop detail page, or bounces to `/drop` without its drop.
///
/// Top-level and `@visibleForTesting` so a test can drive the SHIPPED builder
/// rather than a copy — the failure being guarded is a builder invoked outside
/// the `redirect` meant to protect it, which a copy could not model.
@visibleForTesting
Page<void> buildDailyDropDetailPage(BuildContext context, GoRouterState state) {
  final drop = state.extra;
  // Tolerant, never a cast — see [_RouteWithoutItsExtra] for why `redirect` is
  // not sufficient here. This had the identical latent shape to the see-all
  // page's crash, and the same trigger: a token tick while the user is reading
  // the page. Fixed alongside it (Zé, 2026-08-31) rather than left to be
  // rediscovered as a red screen.
  if (drop is! DailyDrop) {
    return _detailPage(
      name: dailyDropDetailPageName,
      key: state.pageKey,
      // No `arguments`: the surface colour is derived from the drop's
      // `item_type`, and there is no drop. `dailyDropChromeIsEvent` already
      // treats a null/absent argument as non-event, so the frame paints the
      // venue surface for the instant before the bounce.
      child: const _RouteWithoutItsExtra(fallback: AppRoutes.dailyDrop),
    );
  }
  return _detailPage(
    name: dailyDropDetailPageName,
    // PROD-3950 — the drop's `item_type` rides in `Page.arguments` so the
    // shell can paint the right surface: an event drop gets sokoEvent,
    // everything else sokoVenue. Two sites read it
    // (`PinnedPageChrome._resolveSpec` and `_pageBgForRoute`), both via
    // `dailyDropChromeIsEvent`. Same mechanism the in-list routes use to pass
    // `listId` — arguments, not `matchedLocation`, because this page is always
    // reached by an imperative push.
    arguments: drop.itemType,
    key: state.pageKey,
    child: DailyDropDetailScreen(drop: drop),
  );
}

@visibleForTesting
Page<void> buildFeedBundleSeeAllPage(
  BuildContext context,
  GoRouterState state,
) {
  final block = state.extra;
  // ⚠️ **Tolerant, never a cast.** `redirect` above is the primary
  // guard, but it is NOT a guarantee: it runs when the route is
  // RESOLVED, while this runs again on every router rebuild of a
  // page already on the stack — and `extra` cannot survive a web
  // history re-parse, which `refreshListenable` (auth / token
  // ticks) is enough to trigger. A hard cast therefore threw
  // `Null is not a subtype of FeedBlockBundle` and painted a red
  // screen over a page the user was already reading (Zé,
  // 2026-08-31, browser).
  //
  // Degrading to the feed here is the same answer `redirect`
  // gives, just reachable from the branch that actually runs.
  if (block is! FeedBlockBundle) {
    return _detailPage(
      name: feedBundleSeeAllPageName,
      key: state.pageKey,
      child: const _RouteWithoutItsExtra(fallback: AppRoutes.home),
    );
  }
  return _detailPage(
    // Named constant, not a bare string: the shell keys nav-hiding
    // off this exact value (PROD-4068).
    name: feedBundleSeeAllPageName,
    key: state.pageKey,
    child: FeedBundleSeeAllScreen(block: block),
  );
}

class AppRoutes {
  AppRoutes._();

  // Auth routes (short, user-facing paths)
  /// **Don't `context.push(AppRoutes.login)` directly from a guest screen.**
  /// Use [navigateToLoginPreservingReturn] in `core/utils/auth_gating.dart`
  /// instead — it captures the current URL into [returnUrlProvider] so the
  /// post-OAuth flow returns the user to where they were. Direct navigation
  /// drops them on `/home` after Google login, losing their deep-link intent.
  ///
  /// Direct use is fine from auth-flow internals (OAuth callback error path,
  /// activation/reset flows) where there is no "previous page" to preserve.
  static const String login = '/login';

  /// PROD-2073: tabbed Phone / Email login form, reached from the welcome
  /// landing's "Log in" CTA. Lives inside the auth funnel shell so the Soko
  /// wordmark stays anchored as the form slides in from the right.
  static const String loginForm = '/login/form';
  static const String otpVerify = '/auth/verify';
  static const String authCallback = '/auth/callback';

  /// PROD-3594 email fallback rung — passwordless email-OTP login (PROD-3595).
  /// Reached from the phone-OTP screen's "Continue with email" link, or
  /// auto-opened when a phone country can't receive WhatsApp/SMS.
  static const String emailLogin = '/auth/email-login';
  static const String emailLoginVerify = '/auth/email-login/verify';

  // Email auth routes (short, user-facing paths)
  static const String emailRegister = '/register';
  static const String forgotPassword = '/forgot-password';
  static const String resetPassword = '/auth/reset-password';
  static const String activationPending = '/auth/activation-pending';
  static const String activateAccount = '/auth/activate';

  // PROD-2073 (PROD-2081): post-auth Soko greeting (one-time, on first auth)
  static const String sokoWelcome = '/auth/soko-welcome';

  /// Slim location-only prompt for users who already completed Siga on
  /// another device. Gated by `needsLocationAskProvider`.
  static const String locationAsk = '/auth/location-ask';

  // Onboarding routes
  static const String hello = '/hello';
  static const String onboarding = '/onboarding';

  /// Admin-only preview of the scripted onboarding chat foundation
  /// (PROD-3886). Reachable only via the `[admin] Replay onboarding` menu row;
  /// launches the client-side scripted animation with an ephemeral store.
  static const String onboardingChatPreview = '/onboarding-chat-preview';

  /// Production chat onboarding flow (PROD-3881, FE-1/FE-2). Server-persisted,
  /// non-dismissible; the [needsOnboardingProvider] gate forces incomplete
  /// authed users here and blocks escape until `onboarding_complete`.
  static const String onboardingChat = '/onboarding-chat';

  // Main app routes
  static const String home = '/';
  static const String chat = '/chat';
  static const String dailyDrop = '/drop';

  /// PROD-2908 — full-screen detail for a Daily Drop pick with no local
  /// venue/event route (raw editorial / Google-Places / web-search pick).
  /// Internal-push-only (NOT in the deep-link allowlist): the resolver
  /// pushes it with the ready `DailyDrop` as `extra`. A cold web load
  /// (no `extra`) redirects back to `/drop` to re-resolve.
  static const String dailyDropDetail = '/drop/detail/:recommendationId';

  /// PROD-3730 — `/recommendations/:recommendationId`, the target the backend
  /// has always put in the `daily_drop_ready` push payload (`route_path`).
  /// Nothing matched it before, so every tap fell through `errorBuilder` to
  /// `/`. Resolves the recommendation by id and opens ITS destination, so an
  /// old push opens that day's picks rather than today's.
  static const String recommendationById = '/recommendations/:recommendationId';

  static const String weeklyBundle = '/weekly-bundle';

  /// `/u/:handle` (PROD-2775) — another user's social profile by @handle.
  /// Admin-gated pilot (only admins reach it) while the real designs land.
  static const String publicProfile = '/u/:handle';
  static String publicProfilePath(String handle) => '/u/$handle';

  /// Vanity alias `/@:handle` (PROD-2823) — shareable profile link
  /// (`soko.fyi/@handle`). Renders the same public profile.
  static const String publicProfileVanity = '/@:handle';

  /// `/profile` — your own social profile as a shell tab (admin pilot). The
  /// bottom nav's last slot routes here for admins; Settings/account live
  /// behind the gear in the profile header.
  static const String profile = '/profile';

  // Social-profile sub-screens — registered as go_router routes (not raw
  // Navigator.push) so the URL updates and web browser-back / native swipe-back
  // pop to the previous screen instead of jumping home.
  static const String editProfile = '/profile/edit';
  static const String editProfileCrop = '/profile/edit/crop';
  static const String findPeople = '/find-people';
  static const String findPeopleContacts = '/find-people/contacts';
  static const String publicProfileFollowers = '/u/:handle/followers';
  static const String publicProfileFollowing = '/u/:handle/following';
  static const String publicProfileMutual = '/u/:handle/mutual';

  /// Follower/following/mutual list path for a handle. [type] ∈
  /// {followers, following, mutual}.
  static String followListPath(String handle, String type) =>
      '/u/$handle/$type';

  /// `/lists/:listId/followers` — who follows a zine. Public zines viewable by
  /// anyone; private zines are owner-only.
  static const String listFollowers = '/lists/:listId/followers';
  static String listFollowersPath(String listId) => '/lists/$listId/followers';

  /// `/{venues|events}/:id/interested` — everyone who liked or saved an entity
  ///. Reached from the "… têm interesse" row on the detail page.
  /// A route rather than a sheet, matching [listFollowers]: it is a paged list
  /// of people, so it earns a shareable URL and browser back.
  static const String venueInterested = '/venues/:venueId/interested';
  static String venueInterestedPath(String venueId) =>
      '/venues/$venueId/interested';
  static const String eventInterested = '/events/:eventId/interested';
  static String eventInterestedPath(String eventId) =>
      '/events/$eventId/interested';

  /// `/yours` (renamed from `/lists` at PROD-2026 — the hub IS the Yours
  /// page now, so the URL should match). The legacy `/lists` path is
  /// preserved as a top-level redirect to this route, so external/older
  /// links still land here. List-detail routes stay on `/lists/:listId`
  /// (those are shareable list URLs and not in a "yours" namespace).
  static const String lists = '/yours';

  /// `/library` — Biblioteca tab. `/yours` still serves [lists].
  static const String library = '/library';

  /// `/library?tag=<category>` — the Library with one filter tag pre-applied.
  /// Used by the profile counters (Zines → `zines`) so a counter tap lands on
  /// the matching shelf. Without a `tag` the hub keeps the tab parked by the
  /// last visit, so [libraryAll] spells out "everything" explicitly.
  static String libraryWithTag(LibraryCategory category) =>
      '$library?tag=${category.name}';

  /// `/library?tag=all` — the Library forced to its unfiltered landing.
  static const String libraryAll = '$library?tag=$kLibraryAllTag';

  /// `/map` (PROD-2671) — the dedicated Map page. Reachable on **all
  /// platforms** by **any** principal (guest, authed, admin); the route does
  /// NOT redirect. Publicly released to all users (PROD-3133 removed the
  /// admin gate on the Discovery entry button).
  ///
  /// PROD-3326: claimed as a real deep link (exact entry in
  /// [_exactDeepLinkPaths] + AASA + Android manifest) and delivered
  /// race-proof from the `/splash` redirect on cold start — reversing the
  /// earlier deliberate "never a cold-open target" exclusion, whose
  /// pre-release rationale expired with PROD-3133. See the `GoRoute` for
  /// the full note.
  static const String mapa = '/map';

  /// `/chat-map` — the seeded chat map (the same [MapScreen] as [mapa], fed a
  /// fixed list from chat via [mapSeedProvider]).
  static const String chatMap = '/chat-map';

  /// `/menu` (PROD-2019). Replaces the legacy right-side `ProfileDrawer`
  /// for the Profile root. The 6 sub-screens (Account, Preferences,
  /// Business Connections, Support, About, Merge) get peeled out into
  /// `/menu/X` routes by PROD-2020..2025.
  static const String menu = '/menu';

  /// `/menu/account` (PROD-2020). Account screen extracted from the
  /// legacy `ProfileSheet` drawer. Lives under the [DiscoveryShell] like
  /// `/menu` itself.
  static const String menuAccount = '/menu/account';

  /// `/menu/account/merge` (PROD-2023). Merge-accounts sub-flow. Reached
  /// only when [AddPhoneInline]/[AddEmailInline] in [AccountScreen]
  /// detects that the new identifier belongs to another account; the
  /// flow returns to `/menu/account` on cancel or success.
  static const String menuAccountMerge = '/menu/account/merge';

  /// `/menu/account/blocked-users` (PROD-2264). Blocked Users management
  /// screen — lists users the caller has blocked via the moderation menu
  /// on list detail screens, with an Unblock action. Required by Apple
  /// Guideline 1.2 (UGC safety).
  static const String menuAccountBlockedUsers = '/menu/account/blocked-users';

  /// `/menu/preferences` (PROD-2021). Preferences screen extracted from
  /// the legacy `ProfileSheet` drawer. Same shell pattern as
  /// `/menu/account`.
  static const String menuPreferences = '/menu/preferences';

  /// `/menu/preferences/language` (PROD-2073). Language detail page
  /// pushed from the Language tile on `/menu/preferences`. Same shell
  /// pattern as the other `/menu/*` screens.
  static const String menuPreferencesLanguage = '/menu/preferences/language';

  /// `/menu/preferences/whatsapp`. WhatsApp-line detail page pushed
  /// from the WhatsApp tile on `/menu/preferences`. Same shell pattern
  /// as [menuPreferencesLanguage].
  static const String menuPreferencesWhatsapp = '/menu/preferences/whatsapp';

  /// `/menu/business-connections` (PROD-2022). Business Connections
  /// screen extracted from the legacy `ProfileSheet` drawer. Same shell
  /// pattern as `/menu/account`. The legacy magic-link target
  /// [businessConnections] (`/profile/business-connections`) now
  /// redirects here via the top-level [redirect:] block.
  static const String menuBusinessConnections = '/menu/business-connections';

  /// `/business` (PROD-4040). Business Home dashboard — the authed Business
  /// Connect portal (phone-verify + Instagram + claim/edit venues), gated on
  /// BUSINESS_OWNERSHIP_ENABLED. Reached via in-app navigation / a direct web
  /// URL for now; native deep-link claiming (AASA + Android intent filter +
  /// cold-start delivery) and return-state land in T2.4.
  static const String businessHome = '/business';

  /// `/menu/support` (PROD-2024). Support screen extracted from the
  /// legacy `ProfileSheet` drawer. Same shell pattern as `/menu/account`.
  static const String menuSupport = '/menu/support';

  /// `/menu/about` (PROD-2025). About screen extracted from the legacy
  /// `ProfileSheet` drawer. Same shell pattern as `/menu/account`.
  static const String menuAbout = '/menu/about';

  /// `/menu/notifications` (PROD-2524 T-E). Inbox screen — list of the
  /// current user's persisted notifications, mark-as-read + dismiss.
  /// Reached from the Menu screen row.
  static const String menuNotifications = '/menu/notifications';

  /// `/menu/memory`. Admin-only Memory page that consumes the twin-shaped
  /// MemoryTwinResponse. Hidden from non-admin users via drawer-side gating;
  /// URL remains accessible if typed (testing phase).
  static const String menuMemory = '/menu/memory';

  /// `/profile/preview` — your own profile rendered the way a visitor sees it.
  /// Reachable from the settings menu; not linkable from anywhere public.
  static const String profilePreview = '/profile/preview';

  /// `/memory` — the Memory page: persona, what you like, the composer and the
  /// tunable memory sections, with none of the social profile above them.
  /// Every "brain" header button routes here (PROD-4164).
  static const String memory = '/memory';

  /// `/menu/ai-data` — AI consent review/revoke (PROD-2265 Phase 2).
  static const String menuAiData = '/menu/ai-data';

  /// Set of legacy URLs dropped at PROD-1736 cutover that redirect to
  /// [home] via the top-level router redirect. Kept as a single
  /// constant for greppability + so the redirect logic is data-driven.
  ///
  /// - `/memories`: page is hidden from user-facing surfaces (#360);
  ///   `MemoriesScreen` widget preserved for re-introduction
  ///   post-redesign, but no longer reachable via URL.
  /// - `/lists/{yours,soko,following,recommended}`: filter sub-paths
  ///   removed at cutover. The lists hub still surfaces filters via
  ///   in-page chips; they no longer drive the URL.
  static const Set<String> droppedRoutes = {
    '/memories',
    '/lists/yours',
    '/lists/soko',
    '/lists/following',
    '/lists/recommended',
  };

  /// Deep-link entry point that drops the user directly onto the
  /// Instagram Business Connect view inside the profile drawer
  /// (PROD-1778). Used by emails / QR codes / external nudges.
  /// Protected: unauthenticated visitors hit the returnUrl flow and are
  /// restored here post-login.
  static const String businessConnections = '/profile/business-connections';

  /// Legacy `/discovery` path. Pre-cutover this was an admin-only entry
  /// point to `DiscoveryScreen` under `DiscoveryShell`; post-PROD-1736 the
  /// canonical home `/` IS Discovery for everyone, so `/discovery` is
  /// retained only as a redirect to `/` (preserves any in-the-wild admin
  /// bookmarks). No code should `context.go(AppRoutes.discovery)`; use
  /// `context.go(AppRoutes.home)` instead.
  static const String discovery = '/discovery';

  /// Vertical see-more page for a Discovery shelf (the trailing "Ver
  /// mais" tile's destination). `:shelfId` is a [SeeMoreShelf] slug —
  /// unknown slugs redirect home.
  static const String shelfSeeMore = '/shelves/:shelfId';

  /// Full-results page for a server-driven feed bundle (PROD-4068). `:blockId`
  /// is the block's **layout slot id** (`bundle-venue`), which makes the URL
  /// readable and stable — but it is not what the page renders from.
  ///
  /// **Internal-push-only, like [dailyDropDetail].** The block is handed over
  /// as `extra` because it already arrived with the feed (D80), so there is no
  /// fetch and no spinner. A cold entry — a browser refresh, a pasted link —
  /// carries no `extra` and redirects to the feed rather than rendering empty.
  static const String feedBundleSeeAll = '/feed/bundle/:blockId';

  static String feedBundleSeeAllPath(String blockId) => '/feed/bundle/$blockId';

  /// New venue detail page (PROD-1670). Standalone form for direct landing
  /// + the in-list form for shared-from-list contexts.
  static const String venueDetail = '/venues/:venueId';
  static const String listVenueDetail = '/lists/:listId/venues/:venueId';

  /// New event detail page (PROD-1671). Standalone form for direct landing
  /// + the in-list form for shared-from-list contexts.
  static const String eventDetail = '/events/:eventId';
  static const String listEventDetail = '/lists/:listId/events/:eventId';

  /// Public list detail page. Mounts [ListPageScreen] inside
  /// [DiscoveryShell] for all viewers — admin, non-admin, and guest
  /// (PROD-1705 cutover).
  static const String listDetail = '/lists/:listId';

  /// Create-a-zine name screen (PROD-1764). Registered under
  /// `/discovery/lists/` to keep it out of the public `/lists/...`
  /// namespace.
  static const String discoveryListCreate = '/discovery/lists/new';

  static const String session = '/chat/:sessionId';

  // Public routes (no authentication required)
  static const String publicList = '/lists/public/:listId';

  // Integration callback routes
  static const String instagramCallback = '/integrations/instagram';

  // Legal routes (no authentication required)
  static const String privacy = '/privacy';
  static const String terms = '/terms';
  static const String accountDeletion = '/account-deletion';

  /// `/account-suspended` (PROD-2264). Landing screen shown after a
  /// 403 [ModerationError] (USER_SUSPENDED / USER_BANNED). The handler
  /// in `app.dart` force-logs-out and then routes here. Read-only.
  static const String accountSuspended = '/account-suspended';
  static const String support = '/support';

  // User profiling (post-signup vibe flow). The legacy `onboarding` constant
  // above (`/onboarding`) still maps to the old 5-slide tutorial; Phase 3
  // will rewire it. Until then these are reachable directly via URL for dev.
  static const String userProfilingFlow = '/user-profiling/flow';
  static const String userProfilingLoading = '/user-profiling/loading';
  static const String userProfilingResult = '/user-profiling/result';
  static const String userProfilingLists = '/user-profiling/lists';

  /// `/user-profiling/landing` (PROD-2566). The "you've already done this"
  /// persona landing an already-profiled user is redirected to when they tap
  /// the `/user-profiling/flow` deep link without `?reset=1`. In-app redirect
  /// target only — NOT externally claimed (absent from `_exactDeepLinkPaths`,
  /// AASA, and the Android manifest), like its `/loading`/`/result` siblings.
  static const String userProfilingLanding = '/user-profiling/landing';

  /// Fake-door campaign deep link (ticket #8). `/campaign/:key` mirrors the
  /// `/user-profiling/flow` deep-link gate: a logged-out tap is treated as a
  /// protected route (see [_isProtectedRoute]) and bounces to `/login` with
  /// the full URI — utm_*/attribution query preserved — stashed in
  /// [returnUrlProvider]; a logged-in tap fetches the campaign by key and
  /// renders its flow directly (see `CampaignDeepLinkScreen`), with no
  /// Discovery bounce-through and no analogue of `?reset=1` — a campaign
  /// response isn't something a user re-runs.
  static const String campaign = '/campaign/:key';
  static String campaignPath(String key) => '/campaign/$key';

  /// Allowed deep-link path prefixes — used by [parseDeepLink] to validate
  /// `soko.fyi/get/<path>` install-driver URLs (PROD-2054 / PROD-2068).
  ///
  /// Entries ending in `/` match any path with that prefix. Entries without
  /// a trailing `/` match the path exactly OR as a path segment boundary
  /// (so `/activate` matches `/activate` and `/activate/...` but NOT
  /// `/activate-something`). Mirrors the AASA `paths` array and Android
  /// `pathPrefix` set so the app's notion of "what's a valid deep link"
  /// stays in sync with what the OS claims.
  static const List<String> _allowedDeepLinkPathPrefixes = [
    '/venues/',
    '/events/',
    '/lists/',
    '/u/', // public profile share links (PROD-2823) — open the app if installed
    '/chat',
    '/activate',
    '/auth/activate',
    '/auth/callback',
    '/auth/reset-password',
    '/reset-password',
    '/integrations/instagram',
  ];

  /// Deep-link paths claimed for an **exact** match only — no child segments.
  /// `/drop` (PROD-2565) and `/weekly-bundle` (PROD-2564) each have a single
  /// exact route (no `/drop/:x`, no `/weekly-bundle/:x`), so treating
  /// `/<x>/...` as routable would send a malformed short/bridge link to an
  /// unmatched route instead of letting the resolver browser-fall-back.
  ///
  /// `/user-profiling/flow` (PROD-2566) is exact for a different reason: its
  /// three siblings `/user-profiling/{loading,result,lists}` are reached ONLY
  /// via in-flow `pushReplacement` and assume prior state. A `/user-profiling/`
  /// prefix claim would make all four externally routable, so an external/push
  /// tap on `/user-profiling/loading` would land a user mid-flow on a screen
  /// expecting state it doesn't have. The exact claim covers only the flow
  /// entry; `?reset=1` rides along as a query param.
  ///
  /// `/yours` (PROD-2742) was the Lists/saved-items hub ([AppRoutes.lists]);
  /// it now redirects to `/library`, but stays claimed so shipped deep links
  /// resolve in-app instead of falling to browser fallback. Exact claim —
  /// `/yours/<x>` still drops to browser fallback. Guest-accessible, no gate.
  static const Set<String> _exactDeepLinkPaths = {
    '/drop',
    '/weekly-bundle',
    '/user-profiling/flow',
    '/yours',
    '/library',
    // PROD-3326: the Map page. Exact — no child routes; `/map/<x>` falls to
    // browser fallback like the other exact claims.
    '/map',
  };

  static bool _isAllowedDeepLinkPath(String path) {
    if (_exactDeepLinkPaths.contains(path)) return true;
    for (final prefix in _allowedDeepLinkPathPrefixes) {
      if (prefix.endsWith('/')) {
        if (path.startsWith(prefix)) return true;
      } else if (path == prefix || path.startsWith('$prefix/')) {
        return true;
      }
    }
    return false;
  }

  /// Auth-gated deep links that are *redirect* routes rather than final
  /// destinations: `/drop` (PROD-2565) and `/weekly-bundle` (PROD-2564). Each
  /// one's GoRoute redirect stamps a per-tap marker (`?daily_drop=<n>` /
  /// `?weekly_bundle=<n>`) and bounces through Discovery, where the handler
  /// settles the provider and pushes the overlay/detail (or an empty-state
  /// sheet).
  ///
  /// Single source of truth for the two cold-start sites that must treat these
  /// specially (PROD-2564/PROD-2565 cold-start fix):
  ///   1. [coldStartDeepLinkSplashTarget] delivers them straight from the
  ///      `/splash` redirect (like a public-share target) so they can't lose to
  ///      the splash→home/login race.
  ///   2. `app.dart::_processDeepLink` suppresses its redundant post-frame
  ///      `go()` for them on the cold-start initial link — re-issuing it would
  ///      re-hit the route redirect, stamp a *fresh* marker, and double-fire the
  ///      handler (a second overlay/detail push).
  static bool isMarkerRedirectDeepLink(String path) =>
      path == dailyDrop || path == weeklyBundle;

  /// Whether [uri] resolves to a path the app genuinely deep-links — one of the
  /// claimed AASA / intent-filter paths in [_allowedDeepLinkPathPrefixes].
  ///
  /// Used by the short-link resolver (PROD-2314) to distinguish a real
  /// destination from an arbitrary passthrough path on a production host (e.g.
  /// `app.soko.fyi/some-marketing-page`). [parseDeepLink] passes such paths
  /// through as a non-null route, which the router would then bounce home —
  /// losing the short link. When this returns false the resolver browser-falls-
  /// back instead, so the user lands on the real page. Strips a `/get/` bridge
  /// prefix first so `soko.fyi/get/venues/x` is judged on `/venues/x`.
  static bool isRoutableDeepLinkTarget(Uri uri) {
    var path = uri.path;
    if (path.startsWith('/get/')) {
      path = path.substring('/get'.length);
    }
    return _isAllowedDeepLinkPath(path);
  }

  /// Short.io branded short-link hosts claimed as Universal Links / App Links
  /// (PROD-2314). A tap on one of these opens the app, but the slug is opaque
  /// (e.g. `r.soko.fyi/aB3xY`): the URL must be resolved over the network — see
  /// `resolveShortLink` in `short_link_resolver.dart` — into the real
  /// `app.soko.fyi/chat?search=…` destination before it can be routed.
  /// assetlinks/AASA for these hosts is served by Short.io, not this repo.
  static const List<String> shortLinkHosts = [
    'share.soko.fyi',
    'r.soko.fyi',
    'l.soko.fyi',
    'l.heyl.ai',
    't.heyl.ai',
  ];

  /// Sentinel returned by [parseDeepLink] for a short-link host: the URL is
  /// recognized but is NOT synchronously routable (it needs async resolution).
  /// Callers must branch on [isShortLinkHost] and resolve before routing.
  static const String shortLinkUnresolved = '__short_link_unresolved__';

  /// Whether [uri] points at a Short.io branded short-link host (PROD-2314).
  static bool isShortLinkHost(Uri uri) =>
      (uri.scheme == 'https' || uri.scheme == 'http') &&
      shortLinkHosts.contains(uri.host);

  /// Parse deep link URI to route path
  /// Handles URLs like:
  /// - soko://memories -> /memories
  /// - soko://chat/123 -> /chat/123
  /// - soko://auth/callback?access_token=XXX -> /auth/callback?access_token=XXX
  /// - soko://auth/activate?token=XXX -> /auth/activate?token=XXX
  /// - soko://auth/reset-password?token=XXX -> /auth/reset-password?token=XXX
  /// - soko://lists/public/123 -> /lists/public/123
  /// - https://soko.fyi/auth/callback?access_token=XXX -> /auth/callback?access_token=XXX
  /// - https://soko.fyi/lists/public/123 -> /lists/public/123
  /// - https://soko.fyi/get/venues/abc -> /venues/abc (bridge-stripped, PROD-2054)
  /// - https://soko.fyi/get (or /get/) -> / (bare install-driver link, PROD-2298)
  /// - https://app.soko.fyi/venues/abc?utm_source=push -> /venues/abc?utm_source=push
  /// Also supports legacy heyl:// scheme for backward compatibility
  static String? parseDeepLink(Uri uri) {
    // Handle custom schemes: soko:// and heyl:// (legacy)
    if (uri.scheme == 'soko' || uri.scheme == 'heyl') {
      if (uri.host == 'auth') {
        // Special handling for auth routes with query parameters
        if (uri.path == '/callback') {
          return '$authCallback?${uri.query}';
        }
        if (uri.path == '/activate') {
          return '$activateAccount?${uri.query}';
        }
        if (uri.path == '/reset-password') {
          return '$resetPassword?${uri.query}';
        }
      }
      if (uri.host == 'integrations') {
        final path = '/${uri.host}${uri.path}';
        return uri.query.isNotEmpty ? '$path?${uri.query}' : path;
      }
      final path = '/${uri.host}${uri.path}';
      if (path == '/') return home;
      // Legacy deep links: /session/:id -> /chat/:id
      if (path.startsWith('/session/')) {
        return '/chat/${path.substring('/session/'.length)}';
      }
      // Legacy deep links: /conversation -> /
      if (path == '/conversation') return home;
      return uri.query.isNotEmpty ? '$path?${uri.query}' : path;
    }

    // Short.io branded short-link hosts (PROD-2314): recognized here so the
    // caller knows the URL is a claimed deep link, but not routable yet — the
    // opaque slug must be resolved (redirect chain) before routing. Returning
    // the sentinel keeps this function a pure synchronous URL→route mapper.
    if (isShortLinkHost(uri)) {
      return shortLinkUnresolved;
    }

    // Handle web URLs for production, staging, and development
    final isProductionHost =
        uri.host == 'heyl-webapp-production.onrender.com' ||
        uri.host == 'heyl-webapp-staging.onrender.com' ||
        uri.host == 'www.soko.fyi' ||
        uri.host == 'soko.fyi' ||
        uri.host == 'app.soko.fyi';
    final isDevHost =
        EnvironmentConfig.isDev &&
        (uri.host == 'localhost' || uri.host == '127.0.0.1');

    if (isProductionHost || isDevHost) {
      // Bare install-driver link (soko.fyi/get or soko.fyi/get/) — PROD-2298.
      // The bridge at soko.fyi/get is the generic "download the app" link
      // (marketing QR + shareable URL). soko-website's AASA now claims the
      // exact `/get` and `/get/` paths, so an installed app receives the
      // bare Universal Link / App Link here instead of falling through to
      // the store. With no entity path to route to, send the user home.
      // Any attribution query (utm_*, referrer, …) is handled upstream in
      // _handleDeepLink and is intentionally dropped from the route here.
      if (uri.path == '/get' || uri.path == '/get/') {
        return home;
      }

      // Strip the soko.fyi/get/* install-driver bridge prefix. The bridge
      // hosts an "Open in App" button that links to app.soko.fyi/<path>
      // — but if a direct tap on a Universal Link / App Link arrives at
      // app side with /get/<path>, we want to route as if it were the
      // unwrapped path. Validate against the whitelist so arbitrary
      // suffixes (potential open-redirect / unintended routes) drop.
      var path = uri.path;
      if (path.startsWith('/get/')) {
        path = path.substring('/get'.length);
        if (!_isAllowedDeepLinkPath(path)) {
          return null;
        }
      }

      // Special handling for auth routes with query parameters
      if (path == '/auth/callback') {
        return '$authCallback?${uri.query}';
      }
      // Handle both /activate and /auth/activate paths
      if (path == '/auth/activate' || path == '/activate') {
        return '$activateAccount?${uri.query}';
      }
      // Handle both /reset-password and /auth/reset-password paths
      if (path == '/auth/reset-password' || path == '/reset-password') {
        return '$resetPassword?${uri.query}';
      }
      // Preserve query parameters for Instagram OAuth callback
      if (path == AppRoutes.instagramCallback) {
        return uri.query.isNotEmpty
            ? '${AppRoutes.instagramCallback}?${uri.query}'
            : AppRoutes.instagramCallback;
      }
      // Legacy web URLs: /session/:id -> /chat/:id
      if (path.startsWith('/session/')) {
        return '/chat/${path.substring('/session/'.length)}';
      }
      // Legacy web URLs: /conversation -> /
      if (path == '/conversation') return home;
      final basePath = path.isEmpty ? home : path;
      return uri.query.isNotEmpty ? '$basePath?${uri.query}' : basePath;
    }

    return null;
  }
}

/// Listenable for router refresh
class RouterRefreshNotifier extends ChangeNotifier {
  RouterRefreshNotifier(Ref ref) {
    ref.listen(authStateProvider, (_, __) {
      notifyListeners();
    });
    // Listen to token refresh state to re-evaluate routes when refresh completes
    ref.listen(tokenRefreshServiceProvider, (_, __) {
      notifyListeners();
    });
    ref.listen(hasSeenOnboardingProvider, (_, __) {
      notifyListeners();
    });
    // PROD-2073 — re-run redirect when server preferences land (cold-start
    // case) or update (post-Siga PATCH). Without this the router would
    // never pick up the null → true/false transition for a user who
    // arrived on the app via a restored session.
    ref.listen(needsSokoIntroProvider, (_, __) {
      notifyListeners();
    });
    // Cross-device location prompt — re-evaluate when consent lands or
    // when local location-setup flag flips.
    ref.listen(needsLocationAskProvider, (_, __) {
      notifyListeners();
    });
    // Listen to location provider to detect when permission is granted
    ref.listen(locationProvider, (_, __) {
      notifyListeners();
    });
    // Chat-onboarding gate (PROD-3881, FE-2) — re-run redirect when the
    // onboarding-complete signal resolves (cold start) or flips on completion,
    // so the app unlocks the instant onboarding finishes.
    ref.listen(needsOnboardingProvider, (_, __) {
      notifyListeners();
    });
    // PROD-3888 — re-run redirect when the PostHog experiment flags resolve.
    // The legacy Siga/location gates are held while flags are still resolving
    // (`experimentConfirmed` guard below), so the router must wake once they
    // land to make the authoritative cohort decision. `needsOnboarding` alone
    // doesn't cover this: for an already-`onboarding_complete` cohort user it's
    // `false` both before and after the flag flips, so it never notifies. We
    // watch BOTH `loaded` and `flagsConfirmed` (a `(bool, bool)` record has
    // value equality) — the gates now key on `flagsConfirmed`, which lands after
    // `loaded` on a fresh login's post-identify reload, so a `loaded`-only
    // listener would miss that final transition.
    ref.listen(
      experimentServiceProvider.select((s) => (s.loaded, s.flagsConfirmed)),
      (_, __) {
        notifyListeners();
      },
    );
  }
}

/// Provider to store return URL after login
/// Used when unauthenticated users visit public content then navigate away
///
/// PROD-3580 — self-clears so the destination one account was heading to is
/// never restored for the *next* account on this device. `MenuScreen._signOut`
/// used to be the only clear, which covered the menu sign-out and none of the
/// other three session-end paths (expiry, suspension, account deletion).
///
/// It deliberately cannot go in `userScopedProviders`:
/// [navigateToLoginPreservingReturn] writes this while the user is still
/// unauthenticated, so a central purge on the `null → user` flip would eat the
/// very destination it exists to preserve — the same pre-flip-write hazard that
/// keeps `preferencesProvider` out (PROD-2283).
///
/// **Clearing on departure alone is not enough**, which is why this keeps its
/// own memory rather than reusing `_IdentityWatcher`. On a session-expiry
/// bounce the user is still standing on a protected route, so the redirect at
/// the `_isProtectedRoute` check below re-captures that route into this
/// provider *after* the departure clear, via a post-frame callback, while the
/// identity is already `null`. A `prev != null` guard would then wave the next
/// sign-in through and hand account B account A's URL.
///
/// So the arrival edge is checked too, against the last account that was
/// actually signed in — remembered ACROSS the signed-out gap, which
/// `_IdentityWatcher` deliberately does not do (it resets `_lastIdentity` to
/// null on the way out). That distinction is the whole point:
///
///   * same account returns after an expiry → the re-captured route is theirs,
///     keep it. This is the PROD-761 session-loss restore, and clearing on
///     arrival unconditionally would break it.
///   * a different account signs in → drop it, whoever captured it.
///   * a never-authenticated guest signs in → nothing to compare against, keep
///     what the gated action stored. This is the flow a central purge breaks.
///
/// Mutates through `ref.controller` rather than `ref.invalidateSelf()` on
/// purpose: invalidation would rebuild the element and take `lastSignedInId`
/// with it, losing the memory the arrival check depends on. For the same
/// reason `userScopedStatePurgeProvider` arms this provider at app start — a
/// lazily-created listener cannot observe a departure that predates it.
///
/// **Known gap, web + Google OAuth only.** `_startGoogleLoginWebRedirect`
/// persists the return URL to `SharedPreferences` precisely because the
/// full-page redirect destroys Riverpod state — and that reload destroys
/// `lastSignedInId` too. [OAuthCallbackScreen] then restores the URL into a
/// freshly built element whose memory is null, so a *different* account
/// completing that login keeps the previous one's destination. Closing it
/// means persisting the departing id alongside the URL (an auth/OAuth-storage
/// change; Apple web login would need the same). Every path that does not
/// reload the page — native, phone OTP, in-page web — is covered.
final returnUrlProvider = StateProvider<String?>((ref) {
  String? lastSignedInId = ref.read(authStateProvider).user?.id;

  ref.listen<String?>(authStateProvider.select((s) => s.user?.id), (
    prev,
    next,
  ) {
    if (next == null) {
      // An account left. Drop where it was going; keep remembering WHO left.
      if (prev != null) ref.controller.state = null;
      return;
    }
    if (lastSignedInId != null && lastSignedInId != next) {
      ref.controller.state = null;
    }
    lastSignedInId = next;
  });

  return null;
});

/// PROD-4124 — what the login bounce should remember as "where they were
/// going", **including the query string**.
///
/// This used to be `state.matchedLocation`, which is the matched *path* with
/// the query dropped. That was invisible while every auth-gated destination was
/// a bare path, and became wrong the moment `/map` started carrying its filters
/// in the URL: a logged-out visitor opening
/// `/map?entity=event&when=this_weekend` was bounced to `/login`, signed in,
/// and restored to a plain unfiltered `/map`. The whole point of the link was
/// the part that got dropped — and campaign links go disproportionately to
/// people who are not signed in yet.
///
/// **Safe to keep the query here specifically**, because the one-shot markers
/// that must never be replayed after a login do not reach this branch: the
/// caller already excludes `_isPublicShareTarget` (the `?share=sheet` routes —
/// PROD-3319 deliberately does not auto-share post-auth) and
/// `guestMarketingDeepLink` (`?daily_drop=<n>` / `?weekly_bundle=<n>` per-tap
/// markers, and the profiling flow). What is left is declarative state: a
/// filter, a view mode, an attribution tag.
///
/// ⚠️ If a future auth-gated route gains a query param that *performs* an
/// action rather than describing a destination, exclude it in the caller the
/// way those three are, or strip it here. Restoring a destination is safe;
/// replaying an action is not.
///
/// Returns a relative location (`/map?entity=event`) — `GoRouterState.uri` is
/// origin-less, and the result is fed straight back to `go()`.
/// Takes the two primitives it reads rather than the whole `GoRouterState`:
/// that type needs a `RouteConfiguration` and is not constructible in a test,
/// so a function over it could only be exercised by standing up the entire
/// router and an auth flow. Over `(uri, matchedLocation)` the rule is pinned
/// directly.
@visibleForTesting
String returnUrlForLocation({
  required Uri uri,
  required String matchedLocation,
}) {
  // `matchedLocation` over `uri.path` on the no-query path so this is a strict
  // superset of the old behaviour: shell/nested routes can leave `uri.path`
  // and `matchedLocation` differing, and every existing caller was built
  // against `matchedLocation`.
  if (uri.query.isEmpty) return matchedLocation;
  return '$matchedLocation?${uri.query}';
}

typedef RouterProviderReader = T Function<T>(ProviderListenable<T> provider);

/// Defers return-url mutations that are caused by [GoRouter.redirect].
///
/// GoRouter can evaluate redirects while Flutter is building/restoring the
/// router widget. Riverpod rejects provider mutations during that phase, so
/// redirect side effects must run after the frame.
@visibleForTesting
void scheduleRouterReturnUrlUpdate(
  RouterProviderReader read,
  String? returnUrl,
) {
  // `/menu/*` is never a valid returnUrl — those routes are reachable only
  // via in-app nav, never via deep link or bookmark. Capturing them during
  // a sign-out (e.g. PROD-761 session-loss branch fires while the user is
  // still on `/menu/account`) would re-bind the post-login destination to
  // the menu and send the next signed-in user back there instead of
  // landing on `/home`. Survives the post-frame race: we reject the value
  // before scheduling, so no deferred write can overwrite a sync clear.
  // Clears (returnUrl == null) are always honoured.
  if (returnUrl != null && returnUrl.startsWith('/menu')) {
    return;
  }
  SchedulerBinding.instance.addPostFrameCallback((_) {
    if (read(returnUrlProvider) == returnUrl) return;
    read(returnUrlProvider.notifier).state = returnUrl;
  });
}

/// Check if a route requires authentication
/// Most routes are now accessible to guests with graceful guest mode handling
/// Only session history remains protected (guests don't have persistent sessions)
bool _isProtectedRoute(String location) {
  // Home and chat are accessible to guests; the route's pageBuilder
  // renders [GuestGateScreen] in place of the real content for
  // unauthenticated users (Início's gate).
  if (location == AppRoutes.home) return false;
  if (location == AppRoutes.chat) return false;
  // `/yours` redirects to `/library`; keep it guest-passable so the
  // redirect resolves for unauthenticated deep links.
  if (location == AppRoutes.lists) return false;
  // Guest-accessible chrome; skip GET until signed in (401).
  if (location == AppRoutes.library) return false;
  // Individual list views are public - the screen handles auth-based features
  if (location.startsWith('/lists/') && location != '/lists') return false;
  // Session history views are still protected (guests don't have persistent sessions)
  if (location.startsWith('/chat/')) return true;
  // PROD-1778: deep-link to the IG Business Connect view. Requires auth
  // so unauthenticated visitors hit the returnUrl flow and are restored
  // here post-login.
  if (location == AppRoutes.businessConnections) return true;
  // PROD-4040: Business Home dashboard. Its endpoints reject guest JWTs, so a
  // logged-out entry must bounce through `/login` and resume here post-login
  // rather than render an empty guest surface.
  if (location == AppRoutes.businessHome) return true;
  // Ticket #8: fake-door campaign deep link. The response POST 401s for a
  // guest JWT, so — same rationale as `businessConnections` above — a
  // logged-out tap must bounce through `/login` and resume here rather
  // than fall through to a guest-rendered screen.
  if (location.startsWith('/campaign/')) return true;
  // Menu subroutes (account, preferences, business-connections) load
  // real account state and reject guest JWTs. The bare /menu route is
  // intentionally guest-accessible — [MenuScreen] renders a guest header
  // with a sign-in CTA. Subroutes always require a real user. This is
  // the defense that previously lived in the native-only catch-all.
  if (location.startsWith('/menu/')) return true;
  // Create-zine: guests fall through so the pageBuilder can render
  // [GuestGateScreen] (Criar's gate); without this, the redirect block
  // would bounce them to /login instead of showing the sign-in CTA the
  // user expects.
  if (location == AppRoutes.discoveryListCreate) return false;
  return false;
}

/// Protected routes that bypass the welcome/onboarding intro for guests
/// (PROD-1778). External campaigns hand out URLs whose value to the user
/// is the destination itself — Instagram Business Connect, etc. Sending
/// such a user through the brand intro before they can sign in is
/// friction with no upside; they already chose to be here. The login
/// screen still offers a sign-up path for users without an account.
///
/// Add a path here only when the route is itself a marketing entry point
/// (a magic link, QR code, email CTA). Don't add generic protected
/// routes — losing the welcome flow for someone who stumbled into
/// `/chat/<id>` from a stale link is the wrong call.
bool _skipsWelcomeWhenDeepLinked(String location) {
  if (location == AppRoutes.businessConnections) return true;
  return false;
}

/// Paths produced by the in-app share builders (`buildEventShareUrl`,
/// `buildVenueShareUrl`, list share sheet). A fresh visitor arriving via
/// one of these URLs already chose a destination — gating them behind the
/// Apple-compliant "Sign in vs Continue as guest" choice screen would
/// just frustrate them. Let them fall through to the guest-rendered
/// detail; the choice screen still appears when they navigate to
/// Home/Menu/etc. (the no-choice-yet bounce is path-scoped, not session
/// flipped). UTM params are intentionally not required — users may strip
/// the tail when forwarding the URL.
bool _isPublicShareTarget(String location) {
  // Single-segment list/event/venue/profile shares (profiles: /u/<handle>).
  final single = RegExp(r'^/(lists|events|venues|u)/[^/]+$');
  if (single.hasMatch(location)) return true;
  // In-list nested event/venue shares.
  final nested = RegExp(r'^/lists/[^/]+/(events|venues)/[^/]+$');
  if (nested.hasMatch(location)) return true;
  return false;
}

/// Read query param [name] from [state], falling back to `Uri.base` on the
/// Flutter-web cold-start query-strip: `usePathUrlStrategy` + GoRouter drop
/// query params from `state.uri` after SplashGate dismisses (the URL bar
/// briefly shows the query, then re-syncs to a path-only URI). Internal
/// `context.push('...?x=y')` navigations preserve `state.uri` correctly;
/// cold-start external URLs do not, so fall back to `Uri.base` (the URL
/// the browser actually loaded) only when
///   (a) `state.uri` carries no query at all, and
///   (b) we're still on the cold-start path
/// — guarding against leaking the cold-start query into later same-shell
/// pushes. On native `Uri.base` is a file URI whose path never matches a
/// route, so the fallback is web-only by nature. (Pattern introduced for
/// `?view=` on the list route in PROD-1764, generalised for PROD-3319.)
String? _queryParamWithColdStartFallback(GoRouterState state, String name) {
  final stateQuery = state.uri.queryParameters;
  final fromState = stateQuery[name];
  if (fromState != null) return fromState;
  final coldStartFallbackOk =
      stateQuery.isEmpty && state.matchedLocation == Uri.base.path;
  return coldStartFallbackOk ? Uri.base.queryParameters[name] : null;
}

/// Monotonic counter stamped into the `?daily_drop=<n>` marker by the `/drop`
/// redirect (PROD-2565). A fresh value per tap makes each `/drop` open a
/// distinct location, so go_router actually navigates and `DiscoveryScreen`
/// re-fires even for a warm-session re-tap of the same link (e.g. a guest who
/// dismissed the login sheet and tapped the nudge again). Incremented exactly
/// once per navigation (the `/drop` route redirect runs once before the
/// location settles on `/`).
int _dailyDropDeepLinkSeq = 0;

/// Whether [state] is a Daily Drop deep-link entry (PROD-2565) — either the
/// claimed `/drop` path (before its redirect) or the `/?daily_drop=<n>` marker
/// it redirects to. Exempt from the no-choice-yet `/login` bounce so a
/// logged-out tap lands on guest Discovery + the login sheet (Decision #12)
/// rather than the Apple-gate choice screen; the login sheet itself presents
/// the sign-in-vs-continue-as-guest choice, preserving 5.1.1(v)'s intent.
bool _isDailyDropDeepLinkEntry(GoRouterState state) =>
    state.matchedLocation == AppRoutes.dailyDrop ||
    state.uri.queryParameters['daily_drop'] != null;

/// Monotonic counter stamped into the `?weekly_bundle=<n>` marker by the
/// `/weekly-bundle` redirect (PROD-2564). Mirrors [_dailyDropDeepLinkSeq]: a
/// fresh value per tap makes each external `/weekly-bundle` open a distinct
/// location, so a warm-session re-tap re-fires `DiscoveryScreen`'s handler.
int _weeklyBundleDeepLinkSeq = 0;

/// Whether [state] is a Weekly Bundle deep-link entry (PROD-2564) — the claimed
/// `/weekly-bundle` path (before its redirect) or the `/?weekly_bundle=<n>`
/// marker it redirects to. Exempt from the no-choice-yet `/login` bounce, same
/// as [_isDailyDropDeepLinkEntry], so a logged-out tap reaches guest Discovery +
/// the login sheet. (An in-app overlay push also matches `matchedLocation`, but
/// that path is authenticated, so the exemption is a harmless no-op there.)
bool _isWeeklyBundleDeepLinkEntry(GoRouterState state) =>
    state.matchedLocation == AppRoutes.weeklyBundle ||
    state.uri.queryParameters['weekly_bundle'] != null;

/// Monotonic counter stamped into the `?user_profiling=<n>` marker by the
/// `/user-profiling/flow` redirect for a LOGGED-OUT tap (PROD-2566). Mirrors
/// [_dailyDropDeepLinkSeq]: a fresh value per tap makes each guest open a
/// distinct location, so a warm-session re-tap re-fires `DiscoveryScreen`'s
/// handler (the login sheet). Authenticated taps never get the marker — they
/// route straight to the flow or the persona landing, so the marker means
/// "a guest tapped the profiling deep link".
int _userProfilingDeepLinkSeq = 0;

/// Whether [state] is a Profiling Start deep-link entry (PROD-2566) — the
/// claimed `/user-profiling/flow` path (before its redirect) or the
/// `/?user_profiling=<n>` marker a logged-out tap redirects to. Exempt from the
/// no-choice-yet `/login` bounce so a guest reaches guest Discovery + the "log
/// in to do the profiling" sheet (Decision #12), same as
/// [_isDailyDropDeepLinkEntry].
bool _isProfilingDeepLinkEntry(GoRouterState state) =>
    state.matchedLocation == AppRoutes.userProfilingFlow ||
    state.uri.queryParameters['user_profiling'] != null;

/// Whether [state] is a fake-door campaign deep-link entry (ticket #8) —
/// unlike [_isDailyDropDeepLinkEntry]/[_isProfilingDeepLinkEntry] this isn't
/// exempt from any bounce: it's used only to preserve the full URI (query
/// params included) when [_isProtectedRoute]'s logged-out branch captures
/// [returnUrlProvider], since that branch otherwise stores
/// `state.matchedLocation`, which drops utm_*/attribution query params.
bool _isCampaignDeepLinkEntry(GoRouterState state) =>
    state.matchedLocation.startsWith('/campaign/');

/// PROD-2480: the route to deliver from the `/splash` redirect when the app was
/// cold-started via a shared deep link.
///
/// On native there's no URL bar, so GoRouter boots at [_splashRoute] and the
/// launch link is applied by a post-frame `go()` in `app.dart::_initDeepLinks`.
/// That `go()` races the auth-init splash→home/login bounce (which fires the
/// moment `authState.isInitialized` flips true while still on `/splash`) and
/// loses — dropping the user on home (logged-in) or login (logged-out) instead
/// of the shared zine/event/venue. Delivering the route from the splash
/// redirect itself removes the race: the redirect only runs once auth is
/// initialised, so the destination is final and can't be clobbered.
///
/// Returns a route for clean public share targets that parse synchronously
/// (zine/event/venue, incl. in-list) AND for the auth-gated marker-redirect
/// deep links `/drop` (PROD-2565) and `/weekly-bundle` (PROD-2564) — see
/// [AppRoutes.isMarkerRedirectDeepLink]. Returns `null` for everything else —
/// short links, referral links, the iOS share extension, and auth callbacks
/// keep their existing async handling in `app.dart::_handleDeepLink`.
///
/// For public share targets the post-frame `_handleDeepLink` still runs and
/// idempotently re-issues the same `go()` (same location → go_router de-dupes),
/// so attribution / Klaviyo side-effects are unchanged. For the marker-redirect
/// links that re-issue is NOT idempotent (it re-stamps a fresh per-tap marker),
/// so `app.dart::_processDeepLink` suppresses the redundant `go()` for them on
/// the cold-start initial link while still firing attribution / Klaviyo.
///
/// Used in production by two sites (hence not `@visibleForTesting`): the
/// `/splash` redirect (which returns this target) and `app.dart::_processDeepLink`
/// (which calls it as the authoritative "did the splash branch deliver this?"
/// test before suppressing its own `go()` — so the two stay in lock-step, incl.
/// the `?ref=` carve-out below). Also exercised directly by `app_router_test`.
String? coldStartDeepLinkSplashTarget(Uri? initialLink) {
  if (initialLink == null) return null;
  // iOS Share Extension handoff resolves via its own App Group payload.
  if (initialLink.scheme.toLowerCase() == 'sharemedia-ai.heyl.heylapp') {
    return null;
  }
  // Short.io branded links need async network resolution before routing.
  if (AppRoutes.isShortLinkHost(initialLink)) return null;
  // Referral links (`?ref=`) run through the referral pipeline, which may store
  // the referral and intentionally NOT navigate — don't pre-empt it here.
  if ((initialLink.queryParameters['ref'] ?? '').isNotEmpty) return null;
  final route = AppRoutes.parseDeepLink(initialLink);
  if (route == null || route == AppRoutes.shortLinkUnresolved) return null;
  final path = Uri.parse(route).path;
  // Deliver clean public-share entities, the auth-gated marker-redirect deep
  // links (`/drop`, `/weekly-bundle`), AND the profiling-start flow
  // (`/user-profiling/flow`, PROD-2566). The marker-redirect links aren't final
  // destinations — returning the bare path lets their own GoRoute redirect
  // stamp the per-tap marker and bounce through Discovery, exactly as a warm tap
  // would. The profiling flow IS a final destination: it's a self-initializing
  // full-screen route (not a Discovery overlay), so delivering it from splash
  // makes a cold-start tap race-proof without any marker/nonce — the post-frame
  // `go()` in `app.dart` re-issues the identical location, which go_router
  // de-dupes (idempotent, like a public-share target). The Yours hub
  // (`/yours`, PROD-2742) is delivered for the same reason: a self-initializing
  // final screen (guest-accessible, markerless), so the post-frame re-issue is
  // a harmless no-op — for a logged-out tap it just re-evaluates `/yours`, which
  // the no-choice-yet wall bounces to `/login` with `returnUrl=/yours` (no
  // overlay to double-fire). Everything else keeps its own async flow in
  // `_handleDeepLink` (and would lose the splash→home/login race — the
  // PROD-2564/PROD-2565 cold-start bug).
  if (!_isPublicShareTarget(path) &&
      !AppRoutes.isMarkerRedirectDeepLink(path) &&
      path != AppRoutes.userProfilingFlow &&
      // `/yours` now redirects to `/library`; cold-start taps must still
      // survive splash→home so the redirect fires (PROD-2742).
      path != AppRoutes.lists &&
      // PROD-3326: `/map` is a self-initializing final destination —
      // markerless and idempotent, so the post-frame `go()`
      // re-issue in `app.dart` is a harmless de-duped no-op.
      path != AppRoutes.mapa &&
      // Cold-start `/library` must survive splash→home; same as `/yours`.
      path != AppRoutes.library) {
    return null;
  }
  return route; // query (e.g. `?reset=1`, `?utm_source=push`) preserved
}

/// Splash screen shown while auth is initializing. Mirrors `_SplashGate`
/// in `app.dart` — same pink + Soko illustration as the welcome screen so
/// the handoff is seamless.
class _SplashScreen extends StatelessWidget {
  const _SplashScreen();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: AppColors.sokoPink,
      body: SafeArea(
        child: Center(
          child: Image(
            image: AssetImage(
              'assets/images/illustrations/soko-seating-and-reading.webp',
            ),
            width: 140,
            fit: BoxFit.contain,
            semanticLabel: 'Soko',
          ),
        ),
      ),
    );
  }
}

/// Route path for splash screen (internal only)
const _splashRoute = '/splash';

/// Go router configuration provider.
///
/// To reach a `BuildContext` that lives **inside** the Navigator (e.g. when
/// invoking `showModalBottomSheet` / `Navigator.push` from code that's
/// mounted ABOVE the Navigator — `MaterialApp.builder`, a Riverpod listener,
/// a cold-launch deep-link handler), use:
///
/// ```dart
/// final ctx = ref.read(appRouterProvider)
///     .routerDelegate
///     .navigatorKey
///     .currentContext;
/// ```
///
/// `Navigator.of(builderContext)` walks UP and finds nothing in that
/// situation. Existing call sites: `app.dart::_waitForNavigatorReady`
/// (cold-launch deep links, PROD-1712) and
/// `shared/notifications/notification_host.dart` (Soko notification action
/// callbacks, PROD-1863). See
/// `docs/learnings/material-app-builder-navigator-context.md`.
final appRouterProvider = Provider<GoRouter>((ref) {
  final refreshNotifier = RouterRefreshNotifier(ref);
  final analytics = ref.read(unifiedAnalyticsProvider);

  return GoRouter(
    initialLocation: _splashRoute,
    debugLogDiagnostics: true,
    refreshListenable: refreshNotifier,
    observers: [analytics.observer, spotlightModalObserver],
    redirect: (context, state) {
      final authState = ref.read(authStateProvider);
      final isInitialized = authState.isInitialized;
      final isLoggedIn = authState.isAuthenticated;
      final tokenRefreshState = ref.read(tokenRefreshServiceProvider);
      final isRefreshingToken = tokenRefreshState.isRefreshing;
      final isAuthRoute =
          state.matchedLocation.startsWith('/auth') ||
          state.matchedLocation == AppRoutes.login ||
          state.matchedLocation == AppRoutes.loginForm ||
          state.matchedLocation == AppRoutes.emailRegister ||
          state.matchedLocation == AppRoutes.forgotPassword;
      final isSplashRoute = state.matchedLocation == _splashRoute;
      final isOAuthCallback = state.matchedLocation == AppRoutes.authCallback;
      final isActivateCallback =
          state.matchedLocation == AppRoutes.activateAccount;
      final isResetPassword =
          state.matchedLocation == AppRoutes.resetPassword ||
          state.matchedLocation == '/reset-password';
      final isHelloRoute = state.matchedLocation == AppRoutes.hello;
      final isOnboardingRoute = state.matchedLocation == AppRoutes.onboarding;
      final isOnboardingFlow = isHelloRoute || isOnboardingRoute;

      // Check if this is a legal page route (no auth required)
      final isLegalRoute =
          state.matchedLocation == AppRoutes.privacy ||
          state.matchedLocation == AppRoutes.terms ||
          state.matchedLocation == AppRoutes.accountDeletion ||
          state.matchedLocation == AppRoutes.accountSuspended ||
          state.matchedLocation == AppRoutes.support;

      // Instagram callback route (after OAuth redirect from Instagram)
      final isInstagramCallback =
          state.matchedLocation == AppRoutes.instagramCallback;

      // These routes handle their own flows and should always be accessible
      final isSpecialAuthRoute =
          isOAuthCallback ||
          isActivateCallback ||
          isResetPassword ||
          isInstagramCallback;

      // PROD-2073: backend OAuth flows sometimes redirect to /login with
      // tokens on the query string instead of the dedicated /auth/callback
      // route. Re-route to /auth/callback (which sits outside the auth shell)
      // so the wordmark surface doesn't flash behind the callback spinner.
      if (state.matchedLocation == AppRoutes.login) {
        final qp = state.uri.queryParameters;
        if (qp['access_token'] != null || qp['error'] != null) {
          return '${AppRoutes.authCallback}?${state.uri.query}';
        }
      }

      // While auth is initializing, suppress all router redirects.
      //
      // The SplashGate widget (wired in app.dart's MaterialApp.router
      // builder) renders a splash screen over the entire navigator while
      // authState.isInitialized is false. Returning null here means the URL
      // bar stays at whatever the user typed (e.g. /memories) — once init
      // completes, SplashGate disappears and the underlying screen builds
      // against the real URL.
      //
      // This replaces the previous "redirect to /splash" pattern, which
      // overwrote the URL during init and lost any deep-link destination
      // (see PRs #269/#270/#272/#277 for the failed returnUrl-handoff
      // approach this supersedes).
      if (!isInitialized) return null;

      // The MEMORY hub (bio memories, tastes/twin, the Memory screen) is a
      // per-user transparency surface — the signed-in user's own twin. It's
      // now open to every authenticated user (chat's header brain button, the
      // profile brain icon), no longer admin-only. Guests have no persistent
      // account/twin, so a guest (or a typed URL / deep link with no real
      // account) is still bounced home.
      final loc = state.matchedLocation;
      final isMemoryRoute =
          loc == AppRoutes.memory ||
          loc == AppRoutes.menuMemory ||
          loc.startsWith('${AppRoutes.menuMemory}/');
      if (isMemoryRoute && !isLoggedIn) {
        return AppRoutes.home;
      }

      // PROD-1736: legacy/dropped routes redirect to home.
      // - `/discovery`: pre-cutover admin entry point to DiscoveryScreen;
      //   `/` IS Discovery now, this preserves stale admin bookmarks.
      // - [AppRoutes.droppedRoutes]: routes whose registrations were
      //   removed at cutover (memories + lists hub filter sub-paths).
      if (state.matchedLocation == AppRoutes.discovery ||
          AppRoutes.droppedRoutes.contains(state.matchedLocation)) {
        return AppRoutes.home;
      }

      // PROD-2026 renamed `/lists` to `/yours`; the hub has since been
      // replaced by the library, so the legacy path now lands external
      // links / shortcuts / bookmarks directly on `/library` (avoiding a
      // two-hop redirect through `/yours`). Only the exact `/lists`
      // literal redirects — `/lists/:listId` and friends are shareable
      // list URLs and stay in their own namespace.
      if (state.matchedLocation == '/lists') {
        return AppRoutes.library;
      }

      // Always allow special auth routes - they handle their own navigation
      if (isSpecialAuthRoute) {
        return null;
      }

      // Individual list routes (`/lists/:id` + legacy `/lists/public/:id`)
      // are public — the screen handles auth-based features inline and
      // unauthenticated viewers see a guest-blurred experience.
      // We intentionally do NOT short-circuit here: returning users with
      // an expired session must still be funneled through the session-loss
      // block below (which preserves the list URL via returnUrlProvider)
      // before guests are allowed to fall through to the public view.

      // Always allow legal routes - they're accessible without auth
      if (isLegalRoute) {
        return null;
      }

      // EXPLICIT PROTECTION: Ensure protected routes always require authentication
      // This is a defense-in-depth check that runs early, before complex conditional logic
      if (!isLoggedIn && _isProtectedRoute(state.matchedLocation)) {
        // Don't redirect during active token refresh (legitimate temporary unauthenticated state)
        if (!isRefreshingToken) {
          // Store return URL and redirect to login. Ticket #8: a campaign
          // deep link preserves the full URI (utm_*/attribution query
          // included) — `state.matchedLocation` alone drops the query
          // string, which `navigateToLoginPreservingReturn` avoids the same
          // way for its own callers.
          final returnTarget = _isCampaignDeepLinkEntry(state)
              ? state.uri.toString()
              : state.matchedLocation;
          scheduleRouterReturnUrlUpdate(ref.read, returnTarget);
          // PROD-1778: external magic-link entry points (e.g. the
          // Instagram Business Connect deep link emailed to creators)
          // skip the brand welcome screen even for first-time visitors —
          // the user arrived with explicit intent and the intro would
          // bury the ask. The login screen still surfaces a sign-up
          // path for users without an account.
          if (_skipsWelcomeWhenDeepLinked(state.matchedLocation)) {
            return AppRoutes.login;
          }
          return AppRoutes.login;
        }
      }

      // Once initialized, redirect away from splash
      if (isSplashRoute) {
        // PROD-2480: deliver a cold-start shared deep link straight from the
        // splash redirect so the auth-init splash→home/login bounce below
        // can't clobber the post-frame `go()` in `app.dart::_initDeepLinks`.
        // Safe one-shot: `/splash` is only ever the boot `initialLocation` —
        // nothing routes back to it — so a still-populated
        // `initialDeepLinkProvider` never re-triggers this branch. Scoped to
        // clean public share targets; other link kinds resolve via their own
        // async path in `_handleDeepLink`.
        final coldStartTarget = coldStartDeepLinkSplashTarget(
          ref.read(initialDeepLinkProvider),
        );
        if (coldStartTarget != null) return coldStartTarget;

        if (isLoggedIn) {
          // PROD-2073: post-auth gating (Soko welcome + permissions) now
          // lives entirely in the logged-in branch below. Splash just lands
          // the user on /home and that branch decides whether to hop to
          // /auth/soko-welcome (first-time) or fall through.
          return AppRoutes.home;
        }
        // Check for pending phone verification (user was on OTP screen when tab was killed)
        if (authState.pendingPhoneVerification != null) {
          final encodedPhone = Uri.encodeComponent(
            authState.pendingPhoneVerification!,
          );
          return '${AppRoutes.otpVerify}?phone=$encodedPhone';
        }
        // Unauth cold-start: first-time visitors see `/login` so the
        // sign-in / sign-up / "Continue as guest" choice is up front
        // (Apple 5.1.1(v)). Returning guests — users who previously
        // tapped "Continue as guest" — skip the choice and go straight
        // to `/` (the choice is persisted via `explicitGuestModeProvider`,
        // which reads from SharedPreferences).
        final explicitGuestMode = ref.read(explicitGuestModeProvider);
        if (explicitGuestMode) return AppRoutes.home;
        return AppRoutes.login;
      }

      // LOGGED IN users
      if (isLoggedIn) {
        // Server-derived Siga gate. `needsSokoIntro` is `null` while
        // `preferencesProvider` is still fetching; treat that as "don't
        // redirect" so the user's current navigation continues. Once the
        // GET lands, the GoRouter listener wakes and re-runs this
        // redirect with the resolved value. The pre-activation register
        // window is handled below by a dedicated `pendingActivationEmail`
        // guard.
        final needsSokoIntro = ref.read(needsSokoIntroProvider);
        final needsLocationAsk = ref.read(needsLocationAskProvider);
        // PROD-3888 — whether the PostHog experiment flags can be TRUSTED for the
        // cohort decision. The new-onboarding cohort is flag-driven, so
        // `!inNewOnboardingCohort` is NOT authoritative until this is true. Note
        // this reads `flagsConfirmed`, NOT `loaded`: `loaded` flips true on the
        // first flag pass, which on a fresh login still holds the default `false`
        // (the SDK hasn't cached the newly-identified user's flags), so gating on
        // `loaded` bounced cohort users to Siga during the login flag-load race.
        // `flagsConfirmed` waits for the real post-identify value (or a cap).
        // Locally (PostHog disabled) it's true immediately, so no added wait.
        final experimentConfirmed = ref
            .read(experimentServiceProvider)
            .flagsConfirmed;
        final isSokoWelcomeRoute =
            state.matchedLocation == AppRoutes.sokoWelcome;
        final isLocationAskRoute =
            state.matchedLocation == AppRoutes.locationAsk;
        // PROD-4040: the authed Business Connect portal is a separate flow for
        // venue owners — it must never be swallowed by the consumer onboarding
        // gates (chat onboarding / Soko welcome / location ask) below. An owner
        // deep-linking to `/business` reaches it directly; the portal doesn't
        // need Siga/location consent.
        final isBusinessHomeRoute =
            state.matchedLocation == AppRoutes.businessHome;
        // Once an owner has entered the Business Connect portal, treat all their
        // navigation as business context (not just `/business`): the portal's
        // CTAs route through shared consumer routes — verify phone
        // (`/menu/account`), manage Instagram (`/menu/business-connections`),
        // edit venue (`/venues/:id`) — and none of those should re-trap a
        // business user in consumer onboarding. See [businessSessionActiveProvider].
        final inBusinessContext =
            isBusinessHomeRoute || ref.read(businessSessionActiveProvider);
        final sigaDiagIdentity = ref.read(currentLocationAskIdentityProvider);
        final sigaDiagFlagKey = sigaDiagIdentity == null
            ? null
            : locationAskShownKey(
                scope: sigaDiagIdentity.scope,
                id: sigaDiagIdentity.id,
              );
        final sigaDiagFlagSet = sigaDiagFlagKey == null
            ? null
            : ref.read(sharedPreferencesProvider).containsKey(sigaDiagFlagKey);
        debugPrint(
          '[SIGA-DIAG] router redirect: matched="${state.matchedLocation}" '
          'needsSokoIntro=$needsSokoIntro '
          'needsLocationAsk=$needsLocationAsk '
          'experimentConfirmed=$experimentConfirmed '
          'identity=${sigaDiagIdentity == null ? 'null' : '${sigaDiagIdentity.scope}.${sigaDiagIdentity.id}'} '
          'flagKey=$sigaDiagFlagKey flagSet=$sigaDiagFlagSet',
        );
        // Register funnel guard: between `/auth/register` returning a token
        // and the user clicking the activation link, `pendingActivationEmail`
        // is set. The session is half-authenticated — backend rejects most
        // calls — so we must NOT redirect to Siga (the PATCH would 401).
        // The activation callback clears `pendingActivationEmail` and the
        // gate fires on the next router pass.
        if (authState.pendingActivationEmail != null) {
          // Auth routes (e.g. /auth/activation-pending) need this too —
          // the downstream protected-route checks would otherwise punt them
          // through Siga/business-connections instead of the inbox screen.
          return null;
        }
        // Chat onboarding takes PRECEDENCE over Siga + location (PROD-3887):
        // a new user is routed into onboarding FIRST and grants permissions
        // contextually inside it (location at the "where do you live?" step),
        // so the upfront Siga permission page is skipped for them. `null` while
        // the profile loads → don't redirect; `false` (kill-switch off or
        // already complete) → fall through to the normal Siga/location gates.
        final needsOnboarding = ref.read(needsOnboardingProvider);
        final inNewOnboardingCohort = ref.read(newOnboardingCohortProvider);
        final isOnboardingChatRoute =
            state.matchedLocation == AppRoutes.onboardingChat;
        if (needsOnboarding == true &&
            !isSplashRoute &&
            !isOAuthCallback &&
            !isOnboardingFlow &&
            !isOnboardingChatRoute &&
            !inBusinessContext) {
          return AppRoutes.onboardingChat;
        }

        // Let logged-in users stay on either greeting screen regardless of the
        // derived gates — downstream Siga/location gates must not hijack them
        // before the user taps Continue.
        //
        // This runs AFTER the onboarding-chat branch above (not before it, as it
        // used to): a cohort user whose flag confirms `true` only after they've
        // already been placed on `/auth/soko-welcome` (the flag-load race on
        // first login) would otherwise be trapped here by this early `return
        // null` and need a cold restart to reach the new onboarding (PROD-3888
        // follow-up). With the onboarding-chat branch first, `needsOnboarding ==
        // true` pulls them into `/onboarding-chat`; a non-cohort user
        // (`needsOnboarding != true`) still hits this and stays put as before.
        if (isSokoWelcomeRoute || isLocationAskRoute) {
          return null;
        }

        // Siga + location-ask are OFF for the whole NEW-onboarding cohort
        // ([newOnboardingCohortProvider] — the PostHog `unskippable-onboarding-v1`
        // flag, which targets `is_admin` today) — PROD-3887 / PROD-3888:
        //   1. While the chat onboarding is actively claiming them
        //      (`needsOnboarding == true`), location is asked at the city step
        //      and push later (daily-drop / weekly-bundle / rituals).
        //   2. Even AFTER they finish (`needsOnboarding == false`), a cohort
        //      user must NOT be bounced back through the legacy Siga/location
        //      gates — they never use that flow. The new onboarding already
        //      collected consent contextually.
        // Non-cohort users (the OLD onboarding — non-admins with the flag off)
        // still hit Siga/location exactly as before. `null` (profile loading)
        // leaves `inNewOnboardingCohort` false, but needsSokoIntro is likewise
        // null while loading, so no premature redirect fires.
        if (needsOnboarding != true &&
            !inNewOnboardingCohort &&
            experimentConfirmed &&
            needsSokoIntro == true &&
            !isSplashRoute &&
            !isOAuthCallback &&
            !isOnboardingFlow &&
            !inBusinessContext) {
          // PROD-1778: a brand-new user arriving via a magic-link deep
          // link (e.g. `/profile/business-connections`) lands here on
          // first login. The auth screens already consumed and nulled
          // returnUrlProvider on the way in, so reseed it from the
          // current matched location — the Soko welcome's CTA reads
          // returnUrlProvider after granting permissions to restore the
          // original destination.
          //
          // Scoped to deep-linkable destinations (currently just the
          // business-connections route) so we don't accidentally save
          // an internal redirect target like /login as returnUrl.
          if (state.matchedLocation == AppRoutes.businessConnections &&
              ref.read(returnUrlProvider) == null) {
            scheduleRouterReturnUrlUpdate(ref.read, state.matchedLocation);
          }
          // PROD-2565: a `/drop` deep link can arrive before a freshly
          // signed-up user has completed Siga (needsSokoIntro). Seed `/drop`
          // so the welcome CTA restores it post-Siga — otherwise the gate
          // bounces them home and the Daily Drop never opens.
          if (_isDailyDropDeepLinkEntry(state) &&
              ref.read(returnUrlProvider) == null) {
            scheduleRouterReturnUrlUpdate(ref.read, AppRoutes.dailyDrop);
          }
          // PROD-2564: same for a `/weekly-bundle` deep link.
          if (_isWeeklyBundleDeepLinkEntry(state) &&
              ref.read(returnUrlProvider) == null) {
            scheduleRouterReturnUrlUpdate(ref.read, AppRoutes.weeklyBundle);
          }
          // PROD-2566: same for a `/user-profiling/flow` deep link (a guest who
          // signs in to start profiling and still needs Siga).
          if (_isProfilingDeepLinkEntry(state) &&
              ref.read(returnUrlProvider) == null) {
            scheduleRouterReturnUrlUpdate(
              ref.read,
              AppRoutes.userProfilingFlow,
            );
          }
          return AppRoutes.sokoWelcome;
        }
        if (needsOnboarding != true &&
            !inNewOnboardingCohort &&
            experimentConfirmed &&
            needsLocationAsk == true &&
            !isSplashRoute &&
            !isOAuthCallback &&
            !isOnboardingFlow &&
            !inBusinessContext) {
          // Cross-device case: consent recorded on another device but this
          // device hasn't completed location setup. Slim prompt instead of
          // full Siga since the user already knows Soko.
          // PROD-2565: same as the welcome gate — preserve a `/drop` deep
          // link across the location-ask gate (the screen restores returnUrl).
          if (_isDailyDropDeepLinkEntry(state) &&
              ref.read(returnUrlProvider) == null) {
            scheduleRouterReturnUrlUpdate(ref.read, AppRoutes.dailyDrop);
          }
          // PROD-2564: same for a `/weekly-bundle` deep link.
          if (_isWeeklyBundleDeepLinkEntry(state) &&
              ref.read(returnUrlProvider) == null) {
            scheduleRouterReturnUrlUpdate(ref.read, AppRoutes.weeklyBundle);
          }
          // PROD-2566: same for a `/user-profiling/flow` deep link.
          if (_isProfilingDeepLinkEntry(state) &&
              ref.read(returnUrlProvider) == null) {
            scheduleRouterReturnUrlUpdate(
              ref.read,
              AppRoutes.userProfilingFlow,
            );
          }
          return AppRoutes.locationAsk;
        }

        // Non-dismissible chat-onboarding gate (PROD-3881, FE-2). Runs after
        // Siga + location so the redirect order is siga → location →
        // onboarding. `needsOnboarding` is null while the profile loads (treat
        // as "don't redirect") and false while the kill-switch
        // (`kChatOnboardingGateEnabled`) is off, so this is inert until the
        // flow is completable. When true it forces `/onboarding-chat` and, by
        // re-firing on every navigation attempt, blocks escape via
        // back/deep-link/refresh/tabs. Completion flips the server flag →
        // `needsOnboarding` goes false → the app unlocks.
        // PROD-2285 Phase 2 — `needsSokoIntro=false` + `needsLocationAsk=false`
        // means consent is recorded server-side (the cross-device source of
        // truth). No local-flag backfill needed; the migration helper
        // (`runLocationOptInMigrationIfNeeded`) handles legacy installs.

        // User profiling (V6 vibe flow) is hidden/direct-link only for now. Do not redirect
        // newly signed-up users based on `user.onboardingComplete`; callers
        // with the explicit URL can still access the flow.

        // PROD-1778 / PROD-2022: deep-link consumer for the legacy
        // `/profile/business-connections` URL. Runs at the top level
        // (vs the GoRoute's own `redirect`) because route-level
        // redirects inside a ShellRoute don't reliably update the
        // browser URL on web — they sometimes swap the rendered page
        // while leaving the URL stuck at the original deep-link path.
        // The top-level redirect updates the URL definitively.
        //
        // Pre-PROD-2022 this scheduled a post-frame drawer-open with
        // `profileDrawerInitialPageProvider = businessConnections`;
        // now that `/menu/business-connections` is a real route we
        // redirect directly. The drawer Stack mount in DiscoveryShell
        // stays alive until PROD-2023 extracts the Merge sub-flow.
        if (state.matchedLocation == AppRoutes.businessConnections) {
          return AppRoutes.menuBusinessConnections;
        }

        // If trying to access onboarding or auth, redirect to home.
        // (activation-pending and soko-welcome have already short-circuited
        // above with `return null`, so they never reach this bounce.)
        if (isOnboardingFlow || isAuthRoute) {
          final returnUrl = ref.read(returnUrlProvider);
          if (returnUrl != null) {
            scheduleRouterReturnUrlUpdate(ref.read, null);
            return returnUrl;
          }
          return AppRoutes.home;
        }
        return null;
      }

      // IMPORTANT: Don't redirect during active token refresh
      // When a 401 occurs, auth state briefly shows as "not logged in" while
      // the token refresh is in progress. Wait for refresh to complete before
      // redirecting, otherwise we'll unnecessarily bounce the user to login.
      if (!isLoggedIn && isRefreshingToken && !isSplashRoute && !isAuthRoute) {
        return null; // Stay on current route, re-evaluate when refresh completes
      }

      // NOT LOGGED IN users
      final hasSeenOnboarding = ref.read(hasSeenOnboardingProvider);

      // NO-CHOICE-YET REDIRECT: any unauthenticated visitor who has not
      // yet picked between "Sign in" and "Continue as guest" lands on
      // /login first (Apple 5.1.1(v) — the guest option must be visible
      // up front). Covers both first-time visitors and returners with
      // an expired session. The original deep-link destination is
      // preserved via [returnUrlProvider] so post-auth flows restore
      // it; same path drove the previous "session loss" branch.
      //
      // Skipped when:
      //   - the user previously tapped "Continue as guest"
      //     (`explicitGuestMode` is persisted in `SharedPreferences`),
      //   - the request is itself an auth route (login/register/OTP),
      //   - the request is part of the onboarding flow (legacy/direct
      //     link surfaces).
      final explicitGuestMode = ref.read(explicitGuestModeProvider);
      // Marketing / notification deep links (daily-drop, weekly-bundle,
      // profiling) redirect an intentful visitor to GUEST Discovery + a login
      // sheet. That is a guest surface, so it only bypasses the login wall when
      // guest mode is available on this build (web, or native before the
      // guest-mode removal is flipped on); with guest disabled it walls to
      // /login. Public *item* share targets (`_isPublicShareTarget`:
      // /events/:id, /venues/:id, /lists/:id + in-list nested variants) stay
      // exempt on EVERY build so a shared item still previews without an account
      // (device-tested decision — A2). See docs/features/guest-mode.md.
      final guestMarketingDeepLink =
          EnvironmentConfig.guestModeEnabled &&
          // PROD-2565 daily-drop, PROD-2564 weekly-bundle, PROD-2566 profiling.
          (_isDailyDropDeepLinkEntry(state) ||
              _isWeeklyBundleDeepLinkEntry(state) ||
              _isProfilingDeepLinkEntry(state));
      if (!explicitGuestMode &&
          !isAuthRoute &&
          !isOnboardingFlow &&
          !_isPublicShareTarget(state.matchedLocation) &&
          !guestMarketingDeepLink) {
        scheduleRouterReturnUrlUpdate(
          ref.read,
          returnUrlForLocation(
            uri: state.uri,
            matchedLocation: state.matchedLocation,
          ),
        );
        return AppRoutes.login;
      }

      // Allow onboarding flow if not completed
      if (isOnboardingFlow) {
        if (hasSeenOnboarding) {
          // Guests who already completed onboarding land in /chat
          // — it's the route fully usable without auth on every
          // platform. The home grid + zines + create routes render
          // [GuestGateScreen] for unauthenticated visitors.
          return AppRoutes.chat;
        }
        return null; // Allow access to onboarding
      }

      // Allow auth routes
      if (isAuthRoute) {
        return null;
      }

      // GUEST MODE: Allow access to non-protected routes
      // (like /chat). Only redirect to login/onboarding for protected
      // routes — handled by the explicit protection block above.
      return null;
    },
    routes: [
      // Splash screen (shown during auth initialization)
      GoRoute(
        path: _splashRoute,
        builder: (context, state) => const _SplashScreen(),
      ),

      // PROD-2073: auth funnel shell. AuthShell paints Scaffold + SafeArea
      // + SokoBrandHeader once at the top; the routed child slides in/out
      // below it via [_authSlidePage]. The wordmark sits at the exact same
      // pixel Y on every auth screen and never participates in transitions.
      ShellRoute(
        pageBuilder: (context, state, child) => NoTransitionPage(
          key: const ValueKey('AuthShell'),
          // state.uri.path resolves to the deepest matched child route
          // (e.g. '/login/form') and is delivered to the shell in the
          // same build pass that swaps the child in, so it stays in sync
          // with what's rendering. Reading routeInformationProvider.value
          // from inside the shell races microtask ordering and sometimes
          // returned the previous path on push.
          child: AuthShell(currentLocation: state.uri.path, child: child),
        ),
        routes: [
          GoRoute(
            path: AppRoutes.login,
            name: 'login',
            pageBuilder: (context, state) {
              final from = state.uri.queryParameters['from'];
              return _authSlidePage(
                state,
                LoginScreen(skipAuthPromptView: from != null),
              );
            },
          ),
          // PROD-2161: legacy email/register routes disabled. Constants kept
          // so the `isAuthRoute` allow-list (above) and `/auth/register`
          // redirect (below) stay compiling; screen files (`login_form_screen
          // .dart`, `email_register_screen.dart`) remain on disk for revival.
          GoRoute(
            path: AppRoutes.loginForm,
            name: 'loginForm',
            redirect: (context, state) => AppRoutes.login,
          ),
          GoRoute(
            path: AppRoutes.emailRegister,
            name: 'emailRegister',
            redirect: (context, state) => AppRoutes.login,
          ),
          GoRoute(
            path: AppRoutes.otpVerify,
            name: 'otpVerify',
            pageBuilder: (context, state) {
              // Priority: 1. URL query param (survives tab kill), 2. extra, 3. provider
              final queryPhone = state.uri.queryParameters['phone'];
              final decodedPhone = queryPhone != null
                  ? Uri.decodeComponent(queryPhone)
                  : null;
              final phone =
                  decodedPhone ??
                  state.extra as String? ??
                  ref.read(authStateProvider).pendingPhoneVerification ??
                  '';
              // Default to 'sms' so the resend path keeps OS-level OTP
              // autofill usable when the original channel isn't carried
              // (e.g. tab-restore deep link).
              final channel = state.uri.queryParameters['channel'] ?? 'sms';
              // PROD-2632: smsFallbackAvailable + initialStatus drive the
              // OTP screen's render mode (entry boxes vs fallback CTAs).
              // Both default to the conservative "sent + no SMS retry"
              // path so tab-restore renders the legacy OTP entry UX.
              final smsFallbackAvailable =
                  state.uri.queryParameters['smsFallbackAvailable'] == 'true';
              final initialStatus =
                  state.uri.queryParameters['status'] ?? 'sent';
              return _authSlidePage(
                state,
                OtpVerificationScreen(
                  phone: phone,
                  channel: channel,
                  smsFallbackAvailable: smsFallbackAvailable,
                  initialStatus: initialStatus,
                ),
              );
            },
          ),
          // PROD-3594 email fallback rung (passwordless email-OTP, PROD-3595).
          // `?reason=region` shows the "can't text your region" banner when the
          // app auto-routes here after a region_unsupported phone/start.
          GoRoute(
            path: AppRoutes.emailLogin,
            name: 'emailLogin',
            pageBuilder: (context, state) {
              final regionUnsupported =
                  state.uri.queryParameters['reason'] == 'region';
              return _authSlidePage(
                state,
                EmailLoginScreen(regionUnsupported: regionUnsupported),
              );
            },
          ),
          GoRoute(
            path: AppRoutes.emailLoginVerify,
            name: 'emailLoginVerify',
            pageBuilder: (context, state) {
              final queryEmail = state.uri.queryParameters['email'];
              final email = queryEmail != null
                  ? Uri.decodeComponent(queryEmail)
                  : (state.extra as String? ?? '');
              return _authSlidePage(
                state,
                EmailOtpVerificationScreen(email: email),
              );
            },
          ),
          // PROD-2073: activation-pending lives inside the auth shell so it
          // inherits the same SokoBrandHeader + PageContent (480-px max-width
          // column) + sokoPaper surface as every other funnel screen.
          GoRoute(
            path: AppRoutes.activationPending,
            name: 'activationPending',
            pageBuilder: (context, state) {
              // Try extra first (normal navigation), fall back to provider
              // (app restart / direct deep link).
              final email =
                  state.extra as String? ??
                  ref.read(authStateProvider).pendingActivationEmail;
              return _authSlidePage(
                state,
                ActivationPendingScreen(email: email),
              );
            },
          ),
          // PROD-2073: activation callback (the deep-link landing after the
          // user clicks the link in the activation email) also lives inside
          // the shell so it picks up the same SokoBrandHeader + PageContent
          // (480-px max-width column) + sokoPaper surface. The shell's back
          // chevron falls through to /login when there's no nav history
          // (deep-link arrivals), which is the desired escape hatch.
          GoRoute(
            path: AppRoutes.activateAccount,
            name: 'activateAccount',
            pageBuilder: (context, state) {
              final token = state.uri.queryParameters['token'];
              return _authSlidePage(
                state,
                ActivationCallbackScreen(token: token),
              );
            },
          ),
          // PROD-2073: reset-password (deep-link landing after the user clicks
          // the link in the password-reset email) hosted in the shell for the
          // same reason. Two GoRoutes because the backend sends `/reset-password`
          // (no `/auth` prefix); the canonical path is `/auth/reset-password`.
          GoRoute(
            path: AppRoutes.resetPassword,
            name: 'resetPassword',
            pageBuilder: (context, state) {
              final token = state.uri.queryParameters['token'];
              return _authSlidePage(state, ResetPasswordScreen(token: token));
            },
          ),
          GoRoute(
            path: '/reset-password',
            name: 'resetPasswordAlias',
            pageBuilder: (context, state) {
              final token = state.uri.queryParameters['token'];
              return _authSlidePage(state, ResetPasswordScreen(token: token));
            },
          ),
          // PROD-2073: forgot-password entry point (request a reset email).
          // Hosted in the shell for the same reasons as the rest of the
          // funnel — inherits SokoBrandHeader + PageContent + sokoPaper.
          GoRoute(
            path: AppRoutes.forgotPassword,
            name: 'forgotPassword',
            pageBuilder: (context, state) =>
                _authSlidePage(state, const ForgotPasswordScreen()),
          ),
          // PROD-2161: OAuth callback moved into the shell so the
          // "Verifying your account…" view inherits SokoBrandHeader +
          // sokoPaper + the auth funnel's typography. Previously a bare
          // Scaffold with default Material chrome, which read as a
          // different app mid-flow.
          GoRoute(
            path: AppRoutes.authCallback,
            name: 'authCallback',
            pageBuilder: (context, state) {
              final accessToken = state.uri.queryParameters['access_token'];
              final refreshToken = state.uri.queryParameters['refresh_token'];
              final error = state.uri.queryParameters['error'];
              // PROD-4040 T2.4: the backend appends a validated, allowlisted
              // business_return_to when the Google login carried business
              // return-state.
              final businessReturnTo =
                  state.uri.queryParameters['business_return_to'];
              return _authSlidePage(
                state,
                OAuthCallbackScreen(
                  accessToken: accessToken,
                  refreshToken: refreshToken,
                  error: error,
                  businessReturnTo: businessReturnTo,
                ),
              );
            },
          ),
        ],
      ),

      // Email auth routes
      // PROD-2073 (PROD-2081): post-auth Soko greeting (one-time, on first auth)
      GoRoute(
        path: AppRoutes.sokoWelcome,
        name: 'sokoWelcome',
        builder: (context, state) => const SokoWelcomeScreen(),
      ),
      // Cross-device slim location prompt — Siga already done elsewhere.
      GoRoute(
        path: AppRoutes.locationAsk,
        name: 'locationAsk',
        builder: (context, state) => const SokoLocationAskScreen(),
      ),
      // (Social profile routes `/u/:handle` and `/@:handle` now live INSIDE the
      // Discovery shell — see the GoRoutes next to `/profile` — so shell-tab
      // pushes update the URL and support back on web.)
      // Daily Drop deep link (PROD-2565). `/drop` is claimed for Universal
      // Links / App Links / web but renders nothing of its own — it redirects
      // to Discovery (`/`) with a `daily_drop=1` marker. DiscoveryScreen reads
      // the marker and either pushes today's drop's detail page on top of
      // Discovery (happy path) or shows a cause-specific empty-state sheet
      // (logged-out / profiling / unsupported-area / come-back-tomorrow — see
      // `daily_drop_deep_link_sheet.dart`). The marker also exempts the entry
      // from the no-choice-yet `/login` bounce (see [_isDailyDropDeepLinkEntry])
      // so logged-out taps reach guest Discovery + the login sheet. Any
      // utm_*/ref attribution query is forwarded so the home surface and the
      // attribution pipeline still see it.
      GoRoute(
        path: AppRoutes.dailyDrop,
        name: 'dailyDrop',
        redirect: (context, state) {
          // Stamp a fresh sequence value so each `/drop` tap is a distinct
          // location (re-fires the handler on a warm re-tap — see
          // [_dailyDropDeepLinkSeq]).
          final params = Map<String, String>.from(state.uri.queryParameters)
            ..['daily_drop'] = (++_dailyDropDeepLinkSeq).toString();
          return Uri(path: AppRoutes.home, queryParameters: params).toString();
        },
      ),

      // PROD-3730 — per-id daily-drop target carried by the `daily_drop_ready`
      // push and by inbox rows. Unlike `/drop` this is NOT a marker redirect:
      // the id names a specific recommendation, so the resolver fetches it and
      // opens that drop's own destination. Not in `_exactDeepLinkPaths` — it is
      // navigated in-app by `FcmHandlerService` / the notifications inbox, not
      // claimed as a Universal Link.
      GoRoute(
        path: AppRoutes.recommendationById,
        name: 'recommendationById',
        builder: (context, state) => RecommendationDeepLinkScreen(
          recommendationId: state.pathParameters['recommendationId']!,
        ),
      ),

      // Weekly Bundle overlay + deep-link claim (PROD-2564). `/weekly-bundle`
      // is BOTH the in-app overlay route (WeeklyBundleSection._onTap pushes it
      // with a `WeeklyBundleNav` extra) AND the external deep-link claim. The
      // redirect renders the overlay only for an in-app push (extra present);
      // an external/cold entry (no extra — incl. browser restore, which drops a
      // complex extra to null) bounces to Discovery with a per-tap
      // `?weekly_bundle=<n>` marker that primes the provider + gives a real
      // back-stack. DiscoveryScreen then pushes the overlay (extra: deepLink) on
      // a ready bundle, or shows a cause-specific sheet. The marker also exempts
      // the entry from the no-choice-yet `/login` bounce (see
      // [_isWeeklyBundleDeepLinkEntry]). utm_*/ref attribution is forwarded.
      GoRoute(
        path: AppRoutes.weeklyBundle,
        name: 'weeklyBundle',
        redirect: (context, state) {
          // In-app push → render the overlay. External/cold entry → bounce
          // through Discovery so the provider gets primed (otherwise the
          // overlay spins forever — nothing else calls its initialize()).
          if (state.extra is WeeklyBundleNav) return null;
          final params = Map<String, String>.from(state.uri.queryParameters)
            ..['weekly_bundle'] = (++_weeklyBundleDeepLinkSeq).toString();
          return Uri(path: AppRoutes.home, queryParameters: params).toString();
        },
        pageBuilder: (context, state) {
          final nav = state.extra is WeeklyBundleNav
              ? state.extra as WeeklyBundleNav
              : null;
          return CustomTransitionPage(
            child: WeeklyBundleScreen(openReason: nav?.openReason),
            opaque: false,
            barrierDismissible: true,
            barrierColor: Colors.transparent,
            transitionsBuilder:
                (context, animation, secondaryAnimation, child) {
                  return FadeTransition(
                    opacity: CurvedAnimation(
                      parent: animation,
                      curve: Curves.easeOut,
                    ),
                    child: ScaleTransition(
                      scale: Tween<double>(begin: 0.95, end: 1.0).animate(
                        CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOut,
                        ),
                      ),
                      child: child,
                    ),
                  );
                },
          );
        },
      ),

      // Fake-door campaign deep link (ticket #8). Auth-gated via
      // `_isProtectedRoute` (`/campaign/` prefix) — a logged-out tap is
      // bounced to `/login` with the full URI (utm_* preserved) stashed in
      // [returnUrlProvider] and restored post-auth by the generic
      // auth-route bounce-back above (`isOnboardingFlow || isAuthRoute`
      // branch). A logged-in tap renders [CampaignDeepLinkScreen], which
      // fetches the campaign by key and either presents its
      // `CampaignFlowScreen` flow or falls back to Discovery when the
      // backend has nothing to show (404 / already responded).
      GoRoute(
        path: AppRoutes.campaign,
        name: 'campaign',
        builder: (context, state) =>
            CampaignDeepLinkScreen(campaignKey: state.pathParameters['key']!),
      ),

      // Backward-compat redirects for old /auth/* paths
      GoRoute(
        path: '/auth/login',
        name: 'legacyLogin',
        redirect: (context, state) => AppRoutes.login,
      ),
      GoRoute(
        path: '/auth/register',
        name: 'legacyRegister',
        redirect: (context, state) => AppRoutes.emailRegister,
      ),
      GoRoute(
        path: '/auth/forgot-password',
        name: 'legacyForgotPassword',
        redirect: (context, state) => AppRoutes.forgotPassword,
      ),

      // Legacy public list route - redirect to unified route
      GoRoute(
        path: AppRoutes.publicList,
        name: 'publicListRedirect',
        redirect: (context, state) {
          final listId = state.pathParameters['listId'] ?? '';
          return '/lists/$listId';
        },
      ),

      // Legal routes (accessible without authentication)
      GoRoute(
        path: AppRoutes.privacy,
        name: 'privacy',
        builder: (context, state) => const PrivacyPolicyScreen(),
      ),
      GoRoute(
        path: AppRoutes.terms,
        name: 'terms',
        builder: (context, state) => const TermsOfServiceScreen(),
      ),
      GoRoute(
        path: AppRoutes.accountDeletion,
        name: 'accountDeletion',
        builder: (context, state) => const AccountDeletionScreen(),
      ),
      // PROD-2264: `/account-suspended` — landing screen for users
      // whose account has been suspended/banned by backoffice T&S.
      GoRoute(
        path: AppRoutes.accountSuspended,
        name: 'accountSuspended',
        builder: (context, state) => const AccountSuspendedScreen(),
      ),
      GoRoute(
        path: AppRoutes.support,
        name: 'support',
        builder: (context, state) => const legacy_support.SupportScreen(),
      ),

      // Instagram OAuth callback route
      GoRoute(
        path: AppRoutes.instagramCallback,
        name: 'instagramCallback',
        builder: (context, state) {
          final status = state.uri.queryParameters['status'];
          final reason = state.uri.queryParameters['reason'];
          final claimDuplicateKey = state.uri.queryParameters['key'];
          return InstagramCallbackScreen(
            status: status,
            reason: reason,
            claimDuplicateKey: claimDuplicateKey,
          );
        },
      ),

      // Legacy onboarding routes. Hidden/direct-link only for now; the router
      // no longer sends first-time users here automatically.
      GoRoute(
        path: AppRoutes.hello,
        name: 'hello',
        builder: (context, state) => const HelloScreen(),
      ),
      GoRoute(
        path: AppRoutes.onboarding,
        name: 'onboarding',
        builder: (context, state) => const OnboardingScreen(),
      ),

      // Admin-only preview of the scripted onboarding chat foundation
      // (PROD-3886). Reached only through the admin-gated `[admin] Replay
      // onboarding` menu row — no separate redirect guard, matching the other
      // admin surfaces (e.g. `[admin] Social profile`). Launches the
      // client-side scripted animation with an ephemeral in-memory store; the
      // production, user_profiling-backed wiring lands with PROD-3882.
      GoRoute(
        path: AppRoutes.onboardingChatPreview,
        name: 'onboardingChatPreview',
        builder: (context, state) => const OnboardingChatPreviewPage(),
      ),

      // Production chat onboarding flow (PROD-3881, FE-1/FE-2). The
      // non-dismissible gate below forces incomplete authed users here.
      GoRoute(
        path: AppRoutes.onboardingChat,
        name: 'onboardingChat',
        builder: (context, state) => const OnboardingChatScreen(),
      ),

      // User profiling — vibe flow (PROD-onboarding). Also the external
      // deep-link destination (PROD-2566): `app.soko.fyi/user-profiling/flow`.
      GoRoute(
        path: AppRoutes.userProfilingFlow,
        name: 'userProfilingFlow',
        // PROD-2566 deep-link gate. Branch order matters:
        //   • Logged-out (FIRST, even with `?reset=1`) → bounce through
        //     Discovery with a per-tap `?user_profiling=<n>` marker (exempt from
        //     the no-choice `/login` wall) so the "log in to do the profiling"
        //     sheet shows over guest Discovery, mirroring `/drop`. A guest can't
        //     profile without an account, so we never drop them into the survey
        //     (they'd 401 at submit); after login, `returnUrl` brings them back
        //     here as a fresh, not-yet-profiled user → the survey.
        //   • `?reset=1` (authed) → a fresh survey (the campaign's explicit
        //     fresh-start link + the landing's "erase & re-run"), bypassing the
        //     already-profiled landing.
        //   • Logged-in + already-profiled → the persona "you've already done
        //     this" landing instead of re-running the survey.
        //   • Logged-in + not-yet-profiled → the survey (fall through).
        redirect: (context, state) {
          final isLoggedIn = ref.read(isAuthenticatedProvider);
          if (!isLoggedIn) {
            final params = Map<String, String>.from(state.uri.queryParameters)
              ..['user_profiling'] = (++_userProfilingDeepLinkSeq).toString();
            return Uri(
              path: AppRoutes.home,
              queryParameters: params,
            ).toString();
          }
          if (state.uri.queryParameters['reset'] != null) return null;
          if (ref.read(hasCompletedUserProfilingProvider)) {
            // Preserve utm_*/attribution query on the landing.
            final query = state.uri.query;
            return query.isEmpty
                ? AppRoutes.userProfilingLanding
                : '${AppRoutes.userProfilingLanding}?$query';
          }
          return null;
        },
        builder: (context, state) {
          // ?reset=1 (or any truthy value) wipes prior in-memory state on
          // entry. Used by the campaign fresh-start link + the landing's
          // "erase & re-run". Leaves backend-stored archetype alone.
          final reset = state.uri.queryParameters['reset'] != null;
          // PROD-2566: `?source=` attributes `profiling_started` (in-app pushes
          // pass it; an external deep-link tap has none → 'deep_link'). Doesn't
          // affect gating — the redirect above keys off reset/auth/profiled.
          final source = state.uri.queryParameters['source'] ?? 'deep_link';
          return UserProfilingFlowScreen(reset: reset, entrySource: source);
        },
      ),
      // PROD-2566: persona "you've already done this" landing. Reached only via
      // the in-app redirect above (not externally claimed). A direct hit by a
      // logged-out or not-yet-profiled user bounces to the flow.
      GoRoute(
        path: AppRoutes.userProfilingLanding,
        name: 'userProfilingLanding',
        redirect: (context, state) {
          final isLoggedIn = ref.read(isAuthenticatedProvider);
          if (!isLoggedIn || !ref.read(hasCompletedUserProfilingProvider)) {
            return AppRoutes.userProfilingFlow;
          }
          return null;
        },
        builder: (context, state) => const ProfilingAlreadyDoneLanding(),
      ),
      GoRoute(
        path: AppRoutes.userProfilingLoading,
        name: 'userProfilingLoading',
        builder: (context, state) => const UserProfilingLoadingScreen(),
      ),
      GoRoute(
        path: AppRoutes.userProfilingResult,
        name: 'userProfilingResult',
        builder: (context, state) => const PersonaRevealScreen(),
      ),
      // NOTE: `AppRoutes.userProfilingLists` is intentionally NOT a
      // top-level GoRoute. It lives inside the DiscoveryShell below so
      // the terminus smart-list grid can `context.push('/lists/<id>')`
      // onto the same nested navigator — cross-shell push leaves the
      // navigator inconsistent (back-arrow dead, URL stuck).

      // Legacy redirects for bookmarks and browser history
      GoRoute(
        path: '/conversation',
        name: 'conversationRedirect',
        redirect: (context, state) => AppRoutes.home,
      ),
      GoRoute(
        path: '/session/:sessionId',
        name: 'sessionRedirect',
        redirect: (context, state) {
          final sessionId = state.pathParameters['sessionId'] ?? '';
          return '/chat/$sessionId';
        },
      ),

      // Discovery shell (PROD-1526). Owns its own bottom nav (5 items:
      // Search · Zines · Home · Create · Menu). The list-detail subroutes
      // mounted here are public for all viewers (PROD-1705 cutover).
      ShellRoute(
        builder: (context, state, child) => DiscoveryShell(child: child),
        // Two observers ride this navigator:
        //   - `discoveryNavObserver` — drives the shell's chrome rebuild
        //     and bottom-nav highlight logic. See `discovery_shell.dart`.
        //   - `typeaheadResumeNavObserver` (PROD-1983) — synchronously
        //     re-opens the Discovery typeahead overlay when the user
        //     back-arrows out of a detail page they reached via a
        //     typeahead result tap. Synchronous didPop is essential
        //     here: deferring the dialog push to post-frame would let
        //     Discovery paint for one frame between the pop and the
        //     re-open. See `discovery_typeahead_overlay.dart`.
        //
        // (Scroll position is preserved per-page natively now — each page owns
        // its own `ScrollController` via `ShellSliverHost` — so there is no
        // scroll observer here anymore. See
        // `docs/infrastructure/scroll-position-memory.md`.)
        //
        // Both observers receive imperative `context.push('/venues/<id>')`
        // events that `GoRouterState.matchedLocation` can't see — the
        // shell can't rely on the matched-location signal alone.
        observers: [discoveryNavObserver, typeaheadResumeNavObserver],
        routes: [
          // PROD-1736: canonical home `/` mounts DiscoveryScreen for all
          // viewers (admin, non-admin, guest). The legacy `/discovery`
          // URL is preserved as a top-level redirect to `/` for any stale
          // admin bookmarks (see the redirect block at the top of this
          // provider).
          GoRoute(
            path: AppRoutes.home,
            name: 'home',
            pageBuilder: (context, state) => NoTransitionPage(
              // `name` is the page-level identifier the
              // `discoveryNavObserver` uses to recognise when the shell's
              // topmost route is Discovery (vs a pushed detail page).
              // Kept the same for both auth + guest so the bottom-nav's
              // Início highlight reads correctly when a guest taps the
              // home item and lands on the gate.
              name: discoveryPageName,
              // PROD-1979 — guests now see the discovery page directly.
              // The screen itself blurs Daily Drop + the trailing shelves
              // group and hides Weekly Bundle / Yours for unauth users
              // (see `_DiscoveryShelves`), so there's no need to redirect.
              // PROD-2565 — the `/drop` deep link redirects here with
              // `?daily_drop=<n>`; [DiscoveryDeepLinkResolver] resolves today's
              // drop and opens its detail page on top, or shows an empty-state
              // sheet.
              // The nonce (vs a constant) lets a warm-session re-tap re-fire.
              // PROD-2564 — same for `/weekly-bundle` → `?weekly_bundle=<n>`.
              // PROD-2566 — a logged-out `/user-profiling/flow` tap redirects
              // here with `?user_profiling=<n>`; the resolver shows the "log in
              // to do the profiling" sheet over guest Discovery.
              // PROD-4008 — the `discovery-feed-v2` release flag decides
              // whether this route builds the legacy page below or the
              // server-driven v2 feed (D44), via the session-fixed variant
              // provider. The admin-only switcher PROD-4005 shipped here is
              // gone; PROD-4011 deletes the legacy branch once the flag sits
              // at 100%.
              // PROD-4431 — the markers are resolved ABOVE the variant
              // split, not inside the legacy page. They used to be
              // `DiscoveryScreen` constructor args, so every one of them was
              // silently dropped for anyone the `discovery-feed-v2` flag put
              // on the v2 feed (a daily-drop push tap, a weekly-bundle push
              // tap and a guest profiling link all died on a bare feed).
              child: DiscoveryDeepLinkResolver(
                dailyDropDeepLinkNonce:
                    state.uri.queryParameters['daily_drop'],
                // PROD-2908 — a `/drop?rec_id=` link carries an exact
                // recommendation id; the resolver opens that drop directly by
                // id. (The per-id PUSH goes to `/recommendations/{id}` and its
                // own PROD-3730 route instead — see `FcmHandlerService`.)
                dailyDropRecId: state.uri.queryParameters['rec_id'],
                weeklyBundleDeepLinkNonce:
                    state.uri.queryParameters['weekly_bundle'],
                userProfilingDeepLinkNonce:
                    state.uri.queryParameters['user_profiling'],
                child: const DiscoveryVariantPage(legacy: DiscoveryScreen()),
              ),
            ),
            routes: [
              // PROD-2671: `/map` — the dedicated Map page (v0). Rendered
              // full-bleed (the map owns the whole surface; see
              // [mapPageName] + `_isFullBleedRouteName` in discovery_shell).
              //
              // Reachable on **all platforms** (web + native iOS/Android), with
              // the full custom rendering on both: `mapbox_map_native` mirrors
              // the web layer set (facet-colour PNG teardrops + captions, `+k`
              // world-grid bubbles + stack-of-5, settle-to-search via
              // `onMapIdleListener`). It is intentionally reachable by **any**
              // principal — guest, authed user, or admin: guests get the map's
              // own guest scope gate, and since PROD-3133 the Discovery entry
              // button renders for everyone (the temporary admin pre-release
              // gate is gone). PROD-3326 additionally claims `/map` as a deep
              // link (universal link + cold-start splash delivery), so pushes
              // and campaigns can land users here directly.
              //
              // PROD-3524 — declared as a CHILD of `/` (relative `path: 'map'`,
              // so the full path is still `/map`) and entered with
              // `context.go`, NOT the imperative `context.push` it used to
              // use. The push never updated the URL (the PROD-2162 desync), so
              // `/map` owned no browser-history entry and browser back was a
              // route-information rebuild that bypassed the map's `PopScope`
              // entirely — scenario A4 was unsatisfiable on web.
              //
              // Nesting is what makes the switch to `go` free: measured on
              // go_router 14.8.1, a nested `go('/map')` keeps Discovery mounted
              // beneath the map and leaves `context.canPop()` true — the exact
              // stack the old `push` produced — whereas a top-level `go('/map')`
              // would have replaced the stack, unmounting Discovery (remount +
              // scroll-position regression) and flipping `canPop()` to false.
              GoRoute(
                path: 'map',
                name: 'mapa',
                // PROD-4124 — `/map` carries preselected filters as query
                // params. Parsing happens HERE rather than inside `MapScreen`
                // for one reason: the web cold-start fallback below is
                // router-shaped (it needs `GoRouterState` + `Uri.base`), while
                // everything after it is a pure function over a plain map and
                // is tested as one.
                //
                // The key stays `ValueKey('mapa')`, so a second arrival at
                // `/map` with different params does NOT remount the screen —
                // it updates it. That is why `MapScreen` reconciles the deep
                // link in `didUpdateWidget` as well as `initState`; an
                // initState-only read would silently no-op for a push landing
                // on an already-open map.
                pageBuilder: (context, state) {
                  final raw = <String, String?>{
                    for (final k in kMapDeepLinkParamKeys)
                      k: _queryParamWithColdStartFallback(state, k),
                  };
                  final deepLink = MapDeepLinkParams.parse(raw);
                  // PROD — container-transform open: the Discovery `Mapa` pill
                  // expands into the map. Hero borrows this page's transition
                  // animation, so the duration here IS the flight duration; a
                  // `NoTransitionPage` (zero duration) would suppress the Hero
                  // entirely and the map would just pop in. See
                  // [mapOpenPageTransitionsBuilder] / [mapOpenFlightShuttleBuilder].
                  return CustomTransitionPage(
                    name: mapPageName,
                    key: const ValueKey('mapa'),
                    transitionDuration: kMapOpenDuration,
                    reverseTransitionDuration: kMapCloseDuration,
                    transitionsBuilder: mapOpenPageTransitionsBuilder,
                    child: MapScreen(
                      deepLink: deepLink,
                      initialCamera: deepLink.hasCamera
                          ? MapCameraTarget(
                              lat: deepLink.centerLat!,
                              lng: deepLink.centerLng!,
                              radiusMeters:
                                  deepLink.radiusMeters ??
                                  kDefaultMapRadiusMeters,
                            )
                          : null,
                    ),
                  );
                },
              ),
              // Seeded chat map — the SAME [MapScreen] as `/map`, fed a FIXED
              // list from chat (see [_ChatMapRoute] + [mapSeedProvider])
              // instead of the live `/map/pins` pipeline. Declared as a sibling
              // of `/map` under the same shell so detail-sheet pushes stack
              // correctly and back / `PopScope` behave exactly as on `/map`.
              GoRoute(
                path: 'chat-map',
                name: 'chatMap',
                pageBuilder: (context, state) => const NoTransitionPage(
                  // Reuses the chat-map page name so DiscoveryShell hides the
                  // bottom nav (a full-screen map, like the old modal did).
                  name: chatPlacesMapPageName,
                  key: ValueKey('chat-map'),
                  child: _ChatMapRoute(),
                ),
              ),
            ],
          ),
          // PROD-1778 / PROD-2022: deep-link entry point. The real
          // handling (rewrite to `/menu/business-connections`) lives in
          // the top-level `redirect` above — route-level redirects
          // inside a ShellRoute don't reliably update the browser URL
          // on web. This pageBuilder is effectively unreachable but
          // kept defensive.
          GoRoute(
            path: AppRoutes.businessConnections,
            name: 'businessConnections',
            redirect: (context, state) => AppRoutes.menuBusinessConnections,
          ),
          // Shelf see-more page — the trailing "Ver mais" tile on a
          // Discovery shelf pushes here. Flat under DiscoveryShell so the
          // bottom nav stays. Unknown slugs (stale links) land home.
          GoRoute(
            path: AppRoutes.shelfSeeMore,
            name: 'shelfSeeMore',
            redirect: (context, state) {
              final slug = state.pathParameters['shelfId'] ?? '';
              return SeeMoreShelf.fromSlug(slug) == null
                  ? AppRoutes.home
                  : null;
            },
            pageBuilder: (context, state) {
              final slug = state.pathParameters['shelfId']!;
              return _slidePage(
                name: 'shelfSeeMore',
                key: state.pageKey,
                child: ShelfSeeMoreScreen(shelf: SeeMoreShelf.fromSlug(slug)!),
              );
            },
          ),
          // Bundle see-all page (PROD-4068) — the full result set behind a
          // feed bundle's title + chevron. Flat under DiscoveryShell so the
          // bottom nav stays, exactly like the shelf see-more above.
          //
          // Internal-push-only: the block travels as `extra` because it
          // already arrived with the feed (D80), so this page never fetches.
          // `extra` cannot survive serialization, which is precisely what
          // makes it the right guard — "has extra" means "live in-app push",
          // and a browser refresh or pasted link degrades to the feed instead
          // of rendering an empty page. Same shape as `dailyDropDetail`.
          GoRoute(
            path: AppRoutes.feedBundleSeeAll,
            name: 'feedBundleSeeAll',
            redirect: (context, state) =>
                state.extra is FeedBlockBundle ? null : AppRoutes.home,
            pageBuilder: buildFeedBundleSeeAllPage,
          ),
          // Venue detail (PROD-1670): two URL forms, both flat under
          // DiscoveryShell. Synthetic back-stack on cold deep-load is
          // handled by VenueBackButton (no GoRouter parent-child nesting).
          //
          // **Page key:** `state.pageKey` — a `ValueKey<String>` minted
          // once per Navigator stack entry (push) by GoRouter and
          // reused across router rebuilds. This is the property we want:
          //   - Stable across rebuilds → no element-tree churn (an
          //     earlier `UniqueKey()` here regenerated every rebuild and
          //     torpedoed the page subtree mid-frame, throwing
          //     `markNeedsLayout outside layout phase` and
          //     `Element.update` lifecycle assertions).
          //   - Distinct between different pushes of the same path →
          //     no `_ScrollSemantics` GlobalKey collision when the same
          //     entity is pushed twice in a session (e.g. event A →
          //     venue B → event A again from venue B's "Eventos aqui").
          // A path-derived ValueKey (e.g. `ValueKey('venue-$venueId')`)
          // misses the second property and was the original bug behind
          // [D71].
          GoRoute(
            path: AppRoutes.venueDetail,
            name: 'venueDetail',
            // [_slidePage] picks `CupertinoPage` on iOS (interactive
            // drag-to-pop) and a slide-from-right elsewhere. The feed card's
            // poster used to fly into this page's collage; that flight was
            // reverted — see [_detailPage].
            //
            // `state.extra` may carry a [DetailSiblings] when the user
            // opened this detail from a multi-item source (chat card
            // array or saved list) — see `SiblingSwipeNav`.
            //
            // PROD-3952 — this route used to parse
            // `?from=daily-drop&dropId=&dropDate=` (PROD-2785 / PROD-3439) to
            // tell the page it was being viewed as a Daily Drop, so it could
            // wear the branded header and attribute its share to the
            // recommendation. The drop has its own page now (PROD-3950) and
            // no route sets those params any more (PROD-3951), so the
            // parsing is gone. Pre-existing links that still carry them —
            // browser history, or a URL already shared — simply render a
            // plain detail page; the params are ignored, with no shim.
            pageBuilder: (context, state) => _slidePage(
              name: standaloneVenueDetailPageName,
              key: state.pageKey,
              child: VenueDetailScreen(
                venueId: state.pathParameters['venueId']!,
                siblings: state.extra is DetailSiblings
                    ? state.extra as DetailSiblings
                    : null,
                autoShareAction: parseShareDeepLink(
                  _queryParamWithColdStartFallback(state, 'share'),
                ),
              ),
            ),
          ),
          // Daily Drop detail (PROD-2908): full-screen detail for a ready
          // drop with no local venue/event route (raw editorial /
          // Google-Places / web-search pick). Internal-push-only — the
          // resolver / feed card push it with the ready `DailyDrop` as
          // `extra`. NOT in the deep-link allowlist, so it stays
          // guest-gated and external entry keeps flowing through `/drop`.
          //
          // Cold web load (browser refresh on `/drop/detail/:id`) carries
          // no `extra` → redirect back to `/drop`, which re-resolves the
          // drop through Discovery and re-pushes this screen with the
          // in-memory model (avoids a `GET /recommendations/{id}` fetch).
          GoRoute(
            path: AppRoutes.dailyDropDetail,
            name: 'dailyDropDetail',
            redirect: (context, state) =>
                state.extra is DailyDrop ? null : AppRoutes.dailyDrop,
            pageBuilder: buildDailyDropDetailPage,
          ),
          GoRoute(
            path: AppRoutes.listVenueDetail,
            name: 'listVenueDetail',
            pageBuilder: (context, state) {
              final listId = state.pathParameters['listId']!;
              final venueId = state.pathParameters['venueId']!;
              return _detailPage(
                // The one surviving shared-element open: the zine item card's
                // poster + colour panel fly into this page. [_detailPage]
                // resolves to CupertinoPage on iOS and to a 460 ms opaque push
                // elsewhere — the duration is the Hero's flight window.
                name: inListVenueDetailPageName,
                arguments: listId,
                key: state.pageKey,
                // PROD-1703: in-list detail mounts the body inside a
                // card-bounded ColoredBox under the list-page header,
                // not the standalone full-screen [VenueDetailScreen].
                child: ListInContextDetailScreen(
                  listId: listId,
                  entityId: venueId,
                  kind: ListInContextEntityKind.venue,
                  siblings: state.extra is DetailSiblings
                      ? state.extra as DetailSiblings
                      : null,
                  autoShareAction: parseShareDeepLink(
                    _queryParamWithColdStartFallback(state, 'share'),
                  ),
                ),
              );
            },
          ),
          // Event detail (PROD-1671): same `state.pageKey` strategy as
          // the venue routes above. See the venue route's page-key
          // comment for the full rationale.
          GoRoute(
            path: AppRoutes.eventDetail,
            name: 'eventDetail',
            // [_slidePage] — see the standalone venue route above.
            //
            // PROD-3952 — the `?from=daily-drop&…` parsing is gone; see the
            // standalone venue route above.
            pageBuilder: (context, state) => _slidePage(
              name: standaloneEventDetailPageName,
              key: state.pageKey,
              child: EventDetailScreen(
                eventId: state.pathParameters['eventId']!,
                siblings: state.extra is DetailSiblings
                    ? state.extra as DetailSiblings
                    : null,
                autoShareAction: parseShareDeepLink(
                  _queryParamWithColdStartFallback(state, 'share'),
                ),
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.listEventDetail,
            name: 'listEventDetail',
            pageBuilder: (context, state) {
              final listId = state.pathParameters['listId']!;
              final eventId = state.pathParameters['eventId']!;
              return _detailPage(
                // Shared-element open — see the in-list venue route above.
                name: inListEventDetailPageName,
                arguments: listId,
                key: state.pageKey,
                // PROD-1703: in-list detail mounts the body inside a
                // card-bounded ColoredBox under the list-page header,
                // not the standalone full-screen [EventDetailScreen].
                child: ListInContextDetailScreen(
                  listId: listId,
                  entityId: eventId,
                  kind: ListInContextEntityKind.event,
                  siblings: state.extra is DetailSiblings
                      ? state.extra as DetailSiblings
                      : null,
                  autoShareAction: parseShareDeepLink(
                    _queryParamWithColdStartFallback(state, 'share'),
                  ),
                ),
              );
            },
          ),
          // Create-zine name screen (PROD-1764). Lives under
          // `/discovery/lists/` to stay out of the public `/lists/...`
          // namespace. Callers may pass [CreateZineRouteExtra] via
          // `extra:` to hook into the post-create flow (chat banner
          // uses this to bulk-add recommendation cards + show its
          // success state).
          GoRoute(
            path: AppRoutes.discoveryListCreate,
            name: 'discoveryListCreate',
            pageBuilder: (context, state) {
              final extra = state.extra is CreateZineRouteExtra
                  ? state.extra as CreateZineRouteExtra
                  : null;
              return NoTransitionPage(
                key: state.pageKey,
                name: discoveryListCreatePageName,
                child: _GuestGated(
                  referrer: AuthReferrer.guestGateCreate,
                  child: CreateZineScreen(
                    initialName: extra?.initialName,
                    source: extra?.source,
                    onListCreated: extra?.onListCreated,
                    showSuccessState: extra?.showSuccessState ?? false,
                  ),
                ),
              );
            },
          ),
          // PROD-1736: canonical /chat[/...] mounts ChatScreen under
          // DiscoveryShell for all viewers. Pre-cutover this was a twin-paths
          // bridge (/discovery/chat[/...] for admins, /chat[/...] under
          // MainShell for non-admins); cutover collapses both paths back
          // onto the canonical URLs under DiscoveryShell.
          //
          // The `name: chatPageName` is what tells [DiscoveryShell] to
          // mount the body full-bleed (skip the shared
          // SingleChildScrollView + chromeReserved padding) — chat owns
          // its own scrollable message list and would explode if nested
          // inside another vertical scrollable. See `discovery_shell.dart`.
          GoRoute(
            path: AppRoutes.chat,
            name: 'chat',
            pageBuilder: (context, state) {
              // Support passing autoSendMessage for referral flows.
              //
              // PROD-2315: a referral search deep link cold-opens as
              // `/chat?search=<q>` with no `extra` map. Fall back to the
              // `search` query param so the search auto-runs on entry. Read
              // via `state.uri.queryParameters` (form-decodes `+` → space);
              // do NOT route it through `Uri.decodeComponent` — the backend
              // single-encodes with `quote_plus`, so that would leave `+`
              // intact instead of restoring spaces. `extra` still wins, so
              // the authed-ref flow (which passes `extra:{autoSendMessage}`)
              // is unchanged and there is no double source.
              final extra = state.extra as Map<String, dynamic>?;
              final autoSendMessage =
                  extra?['autoSendMessage'] as String? ??
                  state.uri.queryParameters['search'];
              return NoTransitionPage(
                name: chatPageName,
                key: const ValueKey('chat'),
                child: ChatScreen(autoSendMessage: autoSendMessage),
              );
            },
          ),
          GoRoute(
            path: AppRoutes.session,
            name: 'session',
            pageBuilder: (context, state) {
              final sessionId = state.pathParameters['sessionId'] ?? '';
              final extra = state.extra as Map<String, dynamic>?;
              final initialAssistantMessage =
                  extra?['initialAssistantMessage'] as String?;
              final secondAssistantMessage =
                  extra?['secondAssistantMessage'] as String?;
              final secondMessageDelay =
                  extra?['secondMessageDelay'] as int? ?? 500;
              final inputPlaceholder = extra?['inputPlaceholder'] as String?;
              final autoSendMessage = extra?['autoSendMessage'] as String?;
              return NoTransitionPage(
                name: chatPageName,
                key: ValueKey('session-$sessionId'),
                child: ChatScreen(
                  sessionId: sessionId,
                  initialAssistantMessage: initialAssistantMessage,
                  secondAssistantMessage: secondAssistantMessage,
                  secondMessageDelay: secondMessageDelay,
                  inputPlaceholder: inputPlaceholder,
                  autoSendMessage: autoSendMessage,
                ),
              );
            },
          ),
          // `/yours` was the ListsHubScreen hub (PROD-1911/PROD-2026); the
          // library (`/library`) replaced it and the hub code was deleted.
          // The route stays registered as a redirect so shipped deep links
          // (push notifications, emails, PROD-2742 funnel) still resolve
          // instead of falling to browser fallback. List-detail routes
          // (`/lists/:listId` etc.) remain under `/lists/...` because
          // they're shareable URLs, not part of the old hub.
          GoRoute(
            path: AppRoutes.lists,
            name: 'lists',
            redirect: (context, state) => AppRoutes.library,
          ),
          GoRoute(
            path: AppRoutes.library,
            name: libraryPageName,
            pageBuilder: (context, state) {
              // `?tag=<category>` lands the hub on one shelf (the profile
              // counters use it). The key carries the tag so arriving with a
              // different one rebuilds the screen instead of reusing a State
              // whose `initState` already picked the previous tag.
              final tag = state.uri.queryParameters['tag'];
              return NoTransitionPage(
                key: ValueKey('library:${tag ?? ''}'),
                child: LibraryScreen(
                  landingFilter: libraryLandingFilterFor(tag),
                ),
              );
            },
          ),
          // PROD-2019: `/menu` replaces the legacy right-side `ProfileDrawer`.
          // Top-level shell tab — uses `NoTransitionPage` (symmetric with
          // `/chat` and `/yours`) so tab swaps are instant and no Cupertino
          // drag-to-pop transition is layered on top. The bottom nav reaches
          // this route via `context.go(AppRoutes.menu)`, not `push`. The
          // `MenuScreen` paints its own `sokoPaper` bg + header, so no entry
          // in `_pageBgForRoute` or `PinnedPageChrome` is needed.
          GoRoute(
            path: AppRoutes.menu,
            name: 'menu',
            pageBuilder: (context, state) => NoTransitionPage(
              name: menuPageName,
              key: const ValueKey('menu'),
              child: const MenuScreen(),
            ),
          ),
          // Social-profile pilot (admin) — `/profile` renders your own social
          // profile as a shell tab so the bottom nav stays visible. Paints its
          // own sokoPaper bg (like `/menu`), so no `_pageBgForRoute` entry.
          GoRoute(
            path: AppRoutes.profile,
            name: 'profile',
            pageBuilder: (context, state) => const NoTransitionPage(
              key: ValueKey('profile'),
              child: SelfProfileScreen(),
            ),
          ),
          // `/profile/preview` — the self profile through the visitor layout.
          // A pushed detail page, so the back arrow returns to the menu.
          GoRoute(
            path: AppRoutes.profilePreview,
            name: 'profile-preview',
            pageBuilder: (context, state) => _slidePage(
              name: 'profile-preview',
              key: state.pageKey,
              child: const SelfProfileScreen(previewAsVisitor: true),
            ),
          ),
          // `/memory` — the Memory page. Its own screen (same content as the
          // profile's Memória section, none of the social profile above it),
          // pushed as a detail page so the back arrow returns to whichever
          // header brain button opened it.
          GoRoute(
            path: AppRoutes.memory,
            name: 'memory',
            pageBuilder: (context, state) => _slidePage(
              name: memoryPageName,
              key: state.pageKey,
              child: MemoryPageScreen(
                openTellUs: state.uri.queryParameters['tellUs'] == '1',
              ),
            ),
          ),
          // Another user's social profile by @handle (PROD-2775) and its vanity
          // alias `/@handle` (PROD-2823). Mounted INSIDE the Discovery shell —
          // like `/lists/:id` — so pushing from a shell tab updates the browser
          // URL and the back arrow pops reliably (a top-level route pushed from
          // within the shell did neither on web), and the bottom nav stays.
          GoRoute(
            path: AppRoutes.publicProfile,
            name: 'publicProfile',
            // Named `pageBuilder` (not a bare `builder`) so the shell's nav
            // observer identifies this page and stops painting the previous
            // page's chrome — a `builder:` route sets no `Page.name`, which
            // left a profile pushed over an event detail wearing the event's
            // green chrome. `publicProfilePageName` has no chrome/bg entry, so
            // it resolves to no `PinnedPageChrome` + `sokoPaper`.
            pageBuilder: (context, state) => NoTransitionPage(
              name: publicProfilePageName,
              key: state.pageKey,
              child: PublicProfileScreen(
                handle: state.pathParameters['handle'] ?? '',
              ),
            ),
          ),
          GoRoute(
            path: AppRoutes.publicProfileVanity,
            name: 'publicProfileVanity',
            pageBuilder: (context, state) => NoTransitionPage(
              name: publicProfilePageName,
              key: state.pageKey,
              child: PublicProfileScreen(
                handle: state.pathParameters['handle'] ?? '',
              ),
            ),
          ),
          // Social-profile sub-screens — mounted in the shell (like the profile
          // routes) so navigating updates the URL and web browser-back / native
          // swipe-back pop to the previous screen instead of jumping home.
          GoRoute(
            path: AppRoutes.editProfile,
            name: 'profile-edit',
            builder: (context, state) => const EditProfileScreen(),
          ),
          GoRoute(
            path: AppRoutes.editProfileCrop,
            name: 'profile-edit-crop',
            // Bytes in / result out travel via `avatarCropRequestProvider`
            // (an AvatarCropRequest), NOT GoRouter `extra` or this push's
            // return value — the web router rebuild (refresh-listenable) drops
            // both mid-crop. CropAvatarScreen reads the request and leaves on
            // its own if there's nothing to crop (direct hit / refresh).
            builder: (context, state) => const CropAvatarScreen(),
          ),
          GoRoute(
            path: AppRoutes.findPeople,
            name: 'find-people',
            builder: (context, state) => const DiscoverPeopleScreen(),
          ),
          GoRoute(
            path: AppRoutes.findPeopleContacts,
            name: 'find-people-contacts',
            builder: (context, state) => const ContactMatchesScreen(),
          ),
          GoRoute(
            path: AppRoutes.publicProfileFollowers,
            name: 'pp-followers',
            builder: (context, state) => FollowListScreen(
              handle: state.pathParameters['handle'] ?? '',
              mode: FollowListMode.followers,
            ),
          ),
          GoRoute(
            path: AppRoutes.publicProfileFollowing,
            name: 'pp-following',
            builder: (context, state) => FollowListScreen(
              handle: state.pathParameters['handle'] ?? '',
              mode: FollowListMode.following,
            ),
          ),
          GoRoute(
            path: AppRoutes.publicProfileMutual,
            name: 'pp-mutual',
            builder: (context, state) => FollowListScreen(
              handle: state.pathParameters['handle'] ?? '',
              mode: FollowListMode.mutual,
            ),
          ),
          // PROD-2020: `/menu/account` — Account screen extracted from
          // the legacy `ProfileSheet` drawer. Same `_slidePage` chrome
          // as `/menu` itself.
          GoRoute(
            path: AppRoutes.menuAccount,
            name: 'menu-account',
            pageBuilder: (context, state) => _slidePage(
              name: menuAccountPageName,
              key: state.pageKey,
              child: const AccountScreen(),
            ),
          ),
          // PROD-2021: `/menu/preferences` — Preferences screen extracted
          // from the legacy `ProfileSheet` drawer.
          GoRoute(
            path: AppRoutes.menuPreferences,
            name: 'menu-preferences',
            pageBuilder: (context, state) => _slidePage(
              name: menuPreferencesPageName,
              key: state.pageKey,
              child: const PreferencesScreen(),
            ),
          ),
          // PROD-2073: `/menu/preferences/language` — Language detail page
          // pushed from the Language tile on `/menu/preferences`.
          GoRoute(
            path: AppRoutes.menuPreferencesLanguage,
            name: 'menu-preferences-language',
            pageBuilder: (context, state) => _slidePage(
              name: menuPreferencesLanguagePageName,
              key: state.pageKey,
              child: const LanguageSettingsScreen(),
            ),
          ),
          // `/menu/preferences/whatsapp` — WhatsApp-line detail page
          // pushed from the WhatsApp tile on `/menu/preferences`.
          GoRoute(
            path: AppRoutes.menuPreferencesWhatsapp,
            name: 'menu-preferences-whatsapp',
            pageBuilder: (context, state) => _slidePage(
              name: menuPreferencesWhatsappPageName,
              key: state.pageKey,
              child: const WhatsappSettingsScreen(),
            ),
          ),
          // PROD-2524 T-E: `/menu/notifications` — in-app inbox screen.
          // Reachable from the Menu screen's Notifications row AND from
          // the top-right bell button on the Discovery header.
          //
          // PROD-2511 — kill-switch redirect. When the engine is
          // disabled, send the user back to the Menu so stale deep
          // links (older push payloads, shared URLs) don't land on an
          // "orphan" inbox tab whose entry points are hidden elsewhere.
          GoRoute(
            path: AppRoutes.menuNotifications,
            name: 'menu-notifications',
            redirect: (context, state) {
              final engineEnabled = ref
                  .read(experimentServiceProvider)
                  .notificationsEngineEnabled;
              return engineEnabled ? null : AppRoutes.menu;
            },
            pageBuilder: (context, state) => _slidePage(
              name: menuNotificationsPageName,
              key: state.pageKey,
              child: const NotificationsScreen(),
            ),
          ),
          // PROD-2022: `/menu/business-connections` — Business Connections
          // screen extracted from the legacy `ProfileSheet` drawer. The
          // legacy magic-link target `/profile/business-connections` now
          // redirects here via the top-level [redirect:] block.
          GoRoute(
            path: AppRoutes.menuBusinessConnections,
            name: 'menu-business-connections',
            pageBuilder: (context, state) => _slidePage(
              name: menuBusinessConnectionsPageName,
              key: state.pageKey,
              child: const BusinessConnectionsScreen(),
            ),
          ),
          // PROD-4040: `/business` — Business Home dashboard (authed Business
          // Connect portal). Flag-gated: when BUSINESS_OWNERSHIP_ENABLED is
          // off, a stale deep link bounces back to the Menu rather than
          // landing on an orphan screen. Auth is enforced by
          // `_isProtectedRoute` above.
          GoRoute(
            path: AppRoutes.businessHome,
            name: 'business-home',
            redirect: (context, state) {
              // PROD-4040 v1.0: the Business Connect portal is WEB-ONLY. It has
              // no native deep-link claim (no Android intent-filter / AASA
              // entry), so a device tap opens mobile web instead. This guard is
              // the belt-and-suspenders case — a hand-typed `soko://business` or
              // any future in-app link must not render the portal natively.
              if (!kIsWeb) {
                return AppRoutes.menu;
              }
              final experiments = ref.read(experimentServiceProvider);
              // Gate on `flagsConfirmed`, NOT `loaded` — same as the Siga
              // cohort gate above. `loaded` flips true after the first
              // anonymous `_loadFlags` pass, which returns PostHog *defaults*
              // (business-ownership=false); the real per-user value only lands
              // after the post-identify reload. Bouncing on `loaded` strands a
              // real owner on the Menu during that race (seen in staging QA:
              // fresh session → flag still default → redirect to /menu). The
              // backend still 404s the data when off, so rendering pre-confirm
              // is safe.
              if (experiments.flagsConfirmed &&
                  !experiments.enableBusinessOwnership) {
                return AppRoutes.menu;
              }
              return null;
            },
            pageBuilder: (context, state) => _slidePage(
              name: businessHomePageName,
              key: state.pageKey,
              child: const BusinessHomeScreen(),
            ),
          ),
          // PROD-2023: `/menu/account/merge` — Merge Accounts sub-flow
          // extracted from the legacy `ProfileSheet` drawer. Reached
          // only when an in-progress phone/email addition detects an
          // identifier that belongs to another account.
          GoRoute(
            path: AppRoutes.menuAccountMerge,
            name: 'menu-account-merge',
            pageBuilder: (context, state) => _slidePage(
              name: menuAccountMergePageName,
              key: state.pageKey,
              child: const MergeAccountsScreen(),
            ),
          ),
          // PROD-2264: `/menu/account/blocked-users` — Blocked Users
          // management. Required by Apple Guideline 1.2 (UGC safety).
          GoRoute(
            path: AppRoutes.menuAccountBlockedUsers,
            name: 'menu-account-blocked-users',
            pageBuilder: (context, state) => _slidePage(
              name: menuAccountBlockedUsersPageName,
              key: state.pageKey,
              child: const BlockedUsersScreen(),
            ),
          ),
          // PROD-2024: `/menu/support` — Support screen extracted from
          // the legacy `ProfileSheet` drawer.
          GoRoute(
            path: AppRoutes.menuSupport,
            name: 'menu-support',
            pageBuilder: (context, state) => _slidePage(
              name: menuSupportPageName,
              key: state.pageKey,
              child: const SupportScreen(),
            ),
          ),
          // PROD-2025: `/menu/about` — About screen extracted from the
          // legacy `ProfileSheet` drawer.
          GoRoute(
            path: AppRoutes.menuAbout,
            name: 'menu-about',
            pageBuilder: (context, state) => _slidePage(
              name: menuAboutPageName,
              key: state.pageKey,
              child: const AboutScreen(),
            ),
          ),
          // /menu/memory — admin-only Memory page (twin-shaped read shape).
          GoRoute(
            path: AppRoutes.menuMemory,
            name: 'menu-memory',
            pageBuilder: (context, state) => _slidePage(
              name: menuMemoryPageName,
              key: state.pageKey,
              child: MemoryScreen(
                openTellUs: state.uri.queryParameters['tellUs'] == '1',
              ),
            ),
          ),
          // PROD-2265 Phase 2: `/menu/ai-data` — AI consent review/revoke.
          GoRoute(
            path: AppRoutes.menuAiData,
            name: 'menu-ai-data',
            pageBuilder: (context, state) => _slidePage(
              name: menuAiDataPageName,
              key: state.pageKey,
              child: const AiDataScreen(),
            ),
          ),
          // PROD-1705: canonical list detail page for all viewers
          // (admin, non-admin, guest). Mounts [ListPageScreen] inside
          // [DiscoveryShell].
          //
          // Use `pageBuilder` (not `builder`) so we can set
          // [NoTransitionPage.name] = [listDetailPageName]. The
          // [discoveryNavObserver] reads that name to drive the
          // bottom-nav "Zines" highlight — `matchedLocation` is
          // unreliable here because GoRouter `context.push` doesn't
          // update it (see
          // `docs/learnings/gorouter-imperative-push-invisible-to-matchedlocation.md`).
          GoRoute(
            path: AppRoutes.listDetail,
            name: 'listDetail',
            pageBuilder: (context, state) {
              final listId = state.pathParameters['listId'] ?? '';
              // PROD-1764: honour `?view=list` / `?view=zine` deep-link.
              // All query reads go through the shared cold-start-safe
              // helper — see [_queryParamWithColdStartFallback] for the
              // Flutter-web query-strip rationale.
              final viewParam = _queryParamWithColdStartFallback(state, 'view');
              final refParam = _queryParamWithColdStartFallback(state, 'ref');
              ref.read(publicListRefProvider.notifier).state = refParam;
              final initialViewMode = switch (viewParam) {
                'list' => ListViewMode.list,
                'zine' => ListViewMode.zine,
                _ => null,
              };
              return _slidePage(
                // [_slidePage] resolves to CupertinoPage on iOS (preserves
                // swipe-back) and a slide-from-right on Android/web. The
                // Library/feed thumbnail used to fly into the zine cover here;
                // that flight was reverted — see [_detailPage].
                name: listDetailPageName,
                // PROD-1738: surface the listId so `PinnedPageChrome`
                // can read the list name via `unifiedListProvider`.
                arguments: listId,
                key: state.pageKey,
                child: ListPageScreen(
                  listId: listId,
                  initialViewMode: initialViewMode,
                  autoShareAction: parseShareDeepLink(
                    _queryParamWithColdStartFallback(state, 'share'),
                  ),
                ),
              );
            },
          ),
          // `/lists/:listId/followers` — who follows a zine. Reached from the
          // tappable follower count and the "Followed by …" line under the
          // description. The zine name (for the header) rides along in `extra`
          // when available; the screen falls back to just "followers" without it.
          GoRoute(
            path: AppRoutes.listFollowers,
            name: 'listFollowers',
            builder: (context, state) => ListFollowersScreen(
              listId: state.pathParameters['listId'] ?? '',
              zineName: state.extra is String ? state.extra as String : null,
            ),
          ),
          // `/{venues|events}/:id/interested` — everyone who liked or saved an
          // entity, reached from the "… têm interesse" row. Sits
          // beside the zine follower list above: same shape of screen, same
          // row format. The count rides along in `extra` so the header reads
          // right before the first page lands; the server's count wins after.
          GoRoute(
            path: AppRoutes.venueInterested,
            name: 'venueInterested',
            builder: (context, state) => InterestedScreen(
              entityType: SignalEntityType.venue,
              entityId: state.pathParameters['venueId'] ?? '',
              initialCount: state.extra is int ? state.extra as int : null,
            ),
          ),
          GoRoute(
            path: AppRoutes.eventInterested,
            name: 'eventInterested',
            builder: (context, state) => InterestedScreen(
              entityType: SignalEntityType.event,
              entityId: state.pathParameters['eventId'] ?? '',
              initialCount: state.extra is int ? state.extra as int : null,
            ),
          ),
          // Profiling terminus "Só para ti" grid. Mounted INSIDE
          // DiscoveryShell (not as a top-level route) so card taps can
          // `context.push('/lists/<id>')` onto the same nested
          // navigator — back from the list returns to the grid. The
          // bottom nav stays hidden via `userProfilingListsPageName`
          // in `_navHiddenOnRoute`; the screen has its own footer CTA.
          GoRoute(
            path: AppRoutes.userProfilingLists,
            name: 'userProfilingLists',
            pageBuilder: (context, state) => NoTransitionPage(
              name: userProfilingListsPageName,
              key: state.pageKey,
              child: const SmartListsScreen(),
            ),
          ),
        ],
      ),
    ],
    // PROD-1736: unknown routes redirect to home rather than showing a
    // "page not found" page. Stale bookmarks, mistyped URLs, and
    // post-cutover legacy paths we didn't explicitly redirect all land
    // on `/` (DiscoveryScreen) instead of an error screen.
    errorBuilder: (context, state) => const _UnknownRouteRedirect(),
  );
});

/// Wraps a route's real content with a guest-mode check: shows
/// [GuestGateScreen] to unauthenticated visitors and the [child] to
/// signed-in users. Used by `/`, `/lists`, and `/discovery/lists/new`
/// so guests who tap Início / Zines / Criar see a sign-in CTA instead
/// of empty content (those routes' data fetches are auth-only).
///
/// [referrer] is forwarded to auth analytics so the sign-in funnel
/// can attribute conversions back to the nav item the user tapped.
class _GuestGated extends ConsumerWidget {
  const _GuestGated({required this.referrer, required this.child});

  final String referrer;
  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAuthenticated = ref.watch(isAuthenticatedProvider);
    if (!isAuthenticated) {
      return GuestGateScreen(referrer: referrer);
    }
    return child;
  }
}

/// Schedules a post-frame `context.go('/')` for any route GoRouter
/// couldn't match. Renders nothing visible in the meantime so the
/// transition is invisible to the user.
class _UnknownRouteRedirect extends StatefulWidget {
  const _UnknownRouteRedirect();

  @override
  State<_UnknownRouteRedirect> createState() => _UnknownRouteRedirectState();
}

class _UnknownRouteRedirectState extends State<_UnknownRouteRedirect> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.go(AppRoutes.home);
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.shrink());
}

/// The `/chat-map` route: renders the SHARED [MapScreen] in seeded mode, fed a
/// fixed list from [mapSeedProvider] (set by chat's "view on map" before the
/// push), so the chat map is the same screen, cards, pins and detail sheets as
/// `/map` — just populated from chat instead of the live `/map/pins` pipeline.
///
/// No `ProviderScope` overrides: the pipeline providers branch on the ROOT
/// [mapSeedProvider] themselves, which sidesteps Riverpod's scoped-override rule
/// (dependents would otherwise each need `dependencies: [...]`). A `null` seed
/// (a direct deep-load of `/chat-map`) pops back on the first frame.
class _ChatMapRoute extends ConsumerWidget {
  const _ChatMapRoute();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seed = ref.watch(mapSeedProvider);
    if (seed == null) return const _ChatMapDeepLoadFallback();
    return MapScreen(seeded: true, initialCamera: seed.seededCamera());
  }
}

/// Pops back when `/chat-map` is deep-loaded without a payload (nothing to
/// show).
class _ChatMapDeepLoadFallback extends StatefulWidget {
  const _ChatMapDeepLoadFallback();

  @override
  State<_ChatMapDeepLoadFallback> createState() =>
      _ChatMapDeepLoadFallbackState();
}

class _ChatMapDeepLoadFallbackState extends State<_ChatMapDeepLoadFallback> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (context.canPop()) {
        context.pop();
      } else {
        context.go(AppRoutes.home);
      }
    });
  }

  @override
  Widget build(BuildContext context) => const Scaffold(body: SizedBox.shrink());
}
