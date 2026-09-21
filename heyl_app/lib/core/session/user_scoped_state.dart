// Cross-account state isolation.
//
// THE BUG THIS EXISTS TO PREVENT
// ------------------------------
// Sign out of account A, sign in as account B, open `/yours` → B sees A's
// zines, saved pins and calendar. Riverpod providers that are not
// `autoDispose` live for the whole process lifetime, so unless something
// explicitly throws their state away, they keep serving the previous
// account's data to the next one.
//
// Before this file, the only cleanup was a hand-maintained list of six
// `ref.invalidate(...)` calls inside `MenuScreen._signOut()`. That list
// covered neither `/yours` (`listsHubItemsProvider`,
// `listsSearchResultsProvider`, `unifiedListProvider`) nor any of the other
// ~40 account-scoped providers — and it ran on exactly ONE of the four ways
// a session ends (menu sign-out; not session expiry, not account
// suspension, not account deletion, not a direct A→B switch).
//
// THE MECHANISM
// -------------
// [userScopedStatePurgeProvider] watches the authenticated user's id and, on
// every change, drops the in-memory API caches and invalidates every
// provider in [userScopedProviders]. One owner, every sign-out path, every
// sign-in path.
//
// ADDING A PROVIDER
// -----------------
// Any new non-`autoDispose` provider that holds data fetched with the user's
// credentials — or derived from their account — must be listed in
// [userScopedProviders]. `test/lint/user_scoped_provider_registry_test.dart`
// fails the build if a new keep-alive provider is neither registered here nor
// explicitly excused in that test's allowlist, so this cannot silently rot.
//
// One hazard to check first: **does any login path write into the provider
// BEFORE `authState.user` flips?** `AuthNotifier` resolves preferences and
// migrates guest location consent ahead of the flip so the router's Siga gate
// sees them on the first redirect. The purge fires ON the flip, so registering
// such a provider would undo that write — which is why `preferencesProvider`
// is excluded and self-listens with a `prev != null` guard instead
// (PROD-2283). `returnUrlProvider` is the same shape for the same reason: an
// unauthenticated user is sent to login with their destination already stored
// (PROD-3580). See `docs/platform/cross-account-state-isolation.md`.
//
// The second hazard is the mirror image: a provider can be *correctly* out of
// this list and still hold account data, if some other mechanism resets it.
// That mechanism's COVERAGE is the thing that rots — the excuse list in the
// lint test carried "cleared in _signOut" for a while, which was one of the
// four session-end paths. PROD-3580 re-read all 77 excuses against code; the
// doc above records what it found and what to write instead.

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../router/app_router.dart';
import '../services/storage_service.dart';
import '../../features/chat/providers/dismissed_cards_provider.dart';
import '../../features/contributions/providers/contribution_polling_provider.dart';
import '../../features/contributions/providers/contribution_submit_provider.dart';
import '../../features/business_home/providers/business_search_area_providers.dart';
import '../../features/campaigns/providers/campaign_service.dart';
import '../../features/daily_drop/providers/daily_drop_provider.dart';
import '../../features/lists/utils/zine_cover_seed.dart';
import '../../features/map/providers/boundary_children_provider.dart';
import '../../features/instagram_share/providers/instagram_share_polling_provider.dart';
import '../../features/instagram_share/providers/instagram_share_provider.dart';
import '../../features/discovery/feed_v2/providers/feed_chrome_providers.dart';
import '../../features/discovery/feed_v2/providers/feed_home_provider.dart';
import '../../features/discovery/feed_v2/providers/procura_search_providers.dart';
import '../../features/discovery/feed_v2/providers/feed_filter_provider.dart';
import '../../features/discovery/feed_v2/utils/feed_zine_follow.dart';
import '../../features/entity_signals/providers/feed_going_seeds.dart';
import '../../features/entity_signals/providers/feed_signal_seeds.dart';
import '../../features/discovery/providers/following_shelf_provider.dart';
import '../../features/discovery/providers/history_grid_provider.dart';
import '../../features/discovery/providers/yours_shelf_provider.dart';
import '../../features/event_detail/providers/event_reminders_provider.dart';
import '../../features/lists/providers/list_followers_provider.dart';
import '../../features/notifications/providers/my_events_with_reminders_provider.dart';
import '../../features/library/providers/library_calendar_provider.dart';
import '../../features/library/providers/library_filter_provider.dart';
import '../../features/lists/providers/lists_hub_items_provider.dart';
import '../../features/lists/providers/lists_search_providers.dart';
import '../../features/lists/providers/lists_search_results_provider.dart';
import '../../features/lists/providers/list_suggestions_provider.dart';
import '../../features/lists/providers/unified_list_provider.dart';
import '../../features/moderation/providers/blocked_users_provider.dart';
import '../../features/notifications/providers/notification_preferences_provider.dart';
import '../../features/notifications/providers/notifications_provider.dart';
import '../../features/product_tour/providers/product_tour_controller.dart';
import '../../features/profile/providers/follow_state_provider.dart';
import '../../features/profile/providers/people_providers.dart';
import '../../features/profile/providers/public_profile_providers.dart';
import '../../features/share/providers/share_controller.dart';
import '../../features/user_profiling/providers/user_profiling_provider.dart';
import '../../providers/account_provider.dart';
import '../../providers/api_provider.dart';
import '../../providers/detail_seed_provider.dart';
import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/city_auto_location_label_provider.dart';
import '../../providers/city_auto_scope_provider.dart';
import '../../providers/import_list_provider.dart';
import '../../providers/instagram_provider.dart';
import '../../providers/lists_provider.dart';
import '../../providers/location_provider.dart';
import '../../providers/memory_provider.dart';
import '../../providers/memory_twin_provider.dart';
import '../../providers/resolved_search_location_provider.dart';
import '../../providers/saved_provider.dart';
import '../../providers/session_provider.dart';
import '../../providers/social_proof_provider.dart';

/// Every keep-alive provider whose state belongs to one account.
///
/// Invalidated wholesale whenever the signed-in identity changes. Order is
/// irrelevant — Riverpod rebuilds each one lazily, and a provider with no
/// listeners is simply disposed rather than refetched.
final List<ProviderOrFamily> userScopedProviders = <ProviderOrFamily>[
  // ---- Lists / zines / saves — the `/yours` hub ----------------------
  listsProvider,
  listsHubItemsProvider,
  listsSearchResultsProvider,
  listsSearchQueryProvider,
  listsSearchOpenProvider,
  listsSearchCategoryProvider,
  unifiedListProvider,
  zineWarmIntentProvider,
  listSuggestionsProvider,
  importListProvider,
  savedProvider,
  detailSeedCacheProvider,
  // Mirrors [detailSeedCacheProvider]: an in-memory cache of cover seeds for
  // zines the signed-in user browsed. Cleared on account switch so account B
  // never paints a cover seeded from account A's browsing.
  zineCoverSeedProvider,

  // ---- Chat & sessions ----------------------------------------------
  sessionsProvider,
  activeSessionIdProvider,
  chatProvider,
  messageStartersProvider,
  chatSeedLocationProvider,
  dismissedCardsProvider,

  // ---- Profile, social graph, moderation ------------------------------
  accountProvider,
  followStateProvider,
  contactSyncCacheProvider,
  dismissedSuggestionsProvider,
  publicProfileProvider,
  profileZinesProvider,
  profileTastesProvider,
  profileSavedProvider,
  profileSavedZinesProvider,
  profileActivityProvider,
  profileSocialProofProvider,
  // PROD-3581 — `autoDispose`, and its 14 file-siblings are all here; it was
  // missed because the audit's scan skips `autoDispose` by construction. Its
  // host (`/u/:handle`, guest-reachable and mounted inside `DiscoveryShell`)
  // can stay up straight through a sign-out, so the listener survives and the
  // provider keeps serving `/lists/public` — whose `UserListOut` carries the
  // VIEWER's `is_following` / `user_role`. Invalidating an `autoDispose`
  // provider that was never created is a no-op, so listing it costs nothing.
  sokoEditorPicksProvider,
  profileFollowersProvider,
  profileFollowingProvider,
  profileMutualFollowersListProvider,
  followRequestsProvider,
  // PROD-3580 — arrived on develop with #1257 (zine followers list) and was
  // never classified; the lint has been failing on develop ever since, unseen
  // because unit tests are not a PR gate here. `FollowUserSummary` carries the
  // viewer's `isFollowing` / `followsYou` / `requested`, and every sibling
  // returning the same `FollowUserListResponse` is already registered.
  listFollowersProvider,
  pendingRequestCountProvider,
  myFollowingCountDeltaProvider,
  myFollowerCountDeltaProvider,
  socialProofProvider,
  blockedUsersProvider,

  // ---- Memory & profiling ---------------------------------------------
  // `preferencesProvider` is deliberately absent — see the pre-flip hazard
  // in the header comment.
  memoryProvider,
  memoryTwinProvider,
  userProfilingProvider,
  alreadyProfiledPersonaProvider,

  // ---- Notifications ---------------------------------------------------
  notificationsInboxProvider,
  notificationsUnreadCountProvider,
  notificationPreferencesProvider,

  // ---- Contributions & sharing -----------------------------------------
  contributionPollingProvider,
  contributionSubmitProvider,
  instagramProvider,
  instagramShareProvider,
  instagramSharePollingProvider,
  shareControllerProvider,

  // ---- Location scope derived from the account's profile city ----------
  // The explicit picker (`cityScopeProvider`) is deliberately NOT here: it
  // persists per user id and its `build()` watches `currentUserProvider`, so
  // it already rebuilds and re-restores from the new account's key. These two
  // read the signed-in user's profile, so they must re-resolve for the new one.
  cityAutoScopeProvider,
  cityAutoLocationLabelProvider,
  // Looks public — it is keyed by `GeoCity` — but its factory sends the active
  // locale (`apiLocaleCodeProvider`) to `/geo/areas`, so the cached
  // `GeoBoundary.name` / `parentName` are rendered in the *previous* account's
  // language. `resolvedSearchLocationProvider` re-reads this family after a
  // purge, so nothing else would refresh it (PROD-3580).
  resolvedCityBoundaryProvider,
  // Same shape as `resolvedCityBoundaryProvider`: a kept-alive geo family whose
  // `/geo/areas` fetch carries the active locale, so the cached child boundary
  // names are rendered in the previous account's language. Purge so they
  // re-resolve for the new account.
  boundaryChildrenProvider,

  // ---- autoDispose, but their host can stay mounted through the purge -----
  // PROD-3581. `autoDispose` only protects a provider whose last listener
  // actually goes away. These sit on routes that are guest-reachable and
  // mounted inside `DiscoveryShell` (`/u/:handle`, `/find-people`,
  // `/events/:id`, Discovery itself), so a viewer standing on one during a
  // sign-out keeps the listener — and the provider keeps serving the departed
  // account's data. Each returns the VIEWER's own state: `UserSearchItem`'s
  // `is_following` / `follows_you` / `requested`, their reminders, their
  // activity, their zines.
  //
  // All are self-loading (the factory body IS the fetch), so they are on the
  // safe side of the PROD-2065 boundary, and invalidating one that was never
  // created is a no-op — listing them costs nothing.
  peopleSearchProvider,
  suggestedUsersProvider,
  // Derives from the one above, so purging the source would rebuild it anyway
  // — but that is exactly the reasoning PROD-3581 says not to lean on. It
  // holds the same viewer-relative rows, so it is listed on its own account.
  orderedSuggestedUsersProvider,
  suggestedUsersPagedProvider,
  eventReminderListProvider,
  myEventsWithRemindersProvider,
  historyGridProvider,
  yoursShelfProvider,
  followingShelfProvider,

  // ---- Server-driven Discovery feed chrome (PROD-4005) ------------------
  // D17 wants the selected filter to persist across navigation but reset on a
  // new session — and a sign-out/sign-in IS a new session. Registering here
  // gets that for free on all four session-end paths, which a plain
  // `StateProvider` would not: without it, account B would inherit account A's
  // filter, and an admin's alternative-header toggle would follow them into
  // the next account.
  feedFilterProvider,
  feedFilterBarOpenProvider,
  // PROD-4179 — Procura's mode, and the search it holds.
  //
  // All three, not just the mode. The query and category used to be excused as
  // "screen-scoped", which was true while Procura was a pushed route: its
  // `dispose` cleared them on every unmount, sign-out included. As a mode on a
  // page that never unmounts, nothing clears them — so a query typed by the
  // previous account survived, and the next one entered Procura to a page of
  // results for something they never typed, beside an empty field. Caught in
  // review; `_enterProcura` also clears defensively, but the excuse itself was
  // what had gone stale.
  feedProcuraModeProvider,
  procuraSearchQueryProvider,
  procuraSearchCategoryProvider,
  // The forced-feed-state scaffold (PROD-4286 / PROD-4288). It holds no
  // account data, but it survives a sign-out, and the next session to sign in
  // may be a different person who forced nothing — they would land on "I don't
  // know this area" over a location we know perfectly well, or on an error
  // state with nothing wrong. Same reasoning as its neighbours above.
  feedForcedStateProvider,

  // PROD-4520 — ⚠️ **the feed page itself is account data now.**
  //
  // It always held a per-viewer page, but nothing made that visible until the
  // sign-in gate became a BLOCK on the wire. A guest on *Pessoas* fetches
  // `blocks: [sign_in_gate]`; the CTA pushes login, so this screen stays
  // mounted and the autoDispose provider stays alive; and on return nothing
  // refetched — so the reader who just signed in was shown the sign-in gate
  // again. Measured, not theorised: a probe flipped `isAuthenticated` with the
  // provider subscribed and read back `blocks=[sign_in_gate] calls=1`.
  //
  // autoDispose and registered anyway, like `sokoEditorPicksProvider` above:
  // the purge goes through `container.invalidate`, which is a no-op for a
  // provider nobody is watching and a refetch for one that is mounted —
  // exactly the two behaviours wanted here.
  feedHomeProvider,

  // ---- The feed's sentiment seeds (PROD-4027) ---------------------------
  // Straightforwardly account data: it IS the caller's thumbs, keyed by
  // entity. Left unregistered, account B's feed cards would paint account A's
  // likes — and worse than a stale cache, because a seed suppresses the GET
  // that would otherwise correct it, so the wrong state would simply persist.
  // Same defect class as PROD-3665, which is why the lint test exists.
  feedSignalSeedsProvider,

  // ---- The feed's friends-going seeds (PROD-4337) -----------------------
  // The worst of the four this ticket found, because it is not the caller's
  // own data: each entry carries up to three named FRIENDS from the previous
  // account's social graph. Left unregistered, account B's event rows paint
  // "John vai" about people B has never met. `clear()` runs on feed
  // recomposition only, which a sign-out does not guarantee.
  feedGoingSeedsProvider,

  // ---- The feed's zine follow overrides (PROD-4118) ---------------------
  // The caller's own follows, keyed by zine. Same reasoning as the seeds one
  // line up: unregistered, account B's zine rows would render account A's
  // filled bookmarks — and because an override takes precedence over the
  // cached following page, the wrong state would win rather than merely lag.
  feedZineFollowOverridesProvider,

  // ---- Biblioteca (`/library`) ------------------------------------------
  // The feeds are `GET /users/me/library` — the caller's own saves, zines and
  // calendar. They were `autoDispose` and self-cleaning until they started
  // parking their pages with `cacheFor` so a tab swap or a trip to Home stops
  // refetching; that is exactly the PROD-3581 shape, so the purge now owns
  // their cross-account teardown. The four selection providers ride along:
  // account B must land on the merged landing page at the top, not inside
  // account A's Zines / Followed tab.
  libraryFeedProvider,
  libraryTypedFeedProvider,
  libraryTabProvider,
  librarySortProvider,
  libraryViewProvider,
  libraryScrollOffsetProvider,
  // The parked whole-library calendar (owned + followed saved events).
  // Keep-alive for stale-while-revalidate on reopen, so it must be dropped
  // when the signed-in identity changes.
  libraryCalendarItemsProvider,
  libraryCalendarOpenProvider,

  // ---- Business Connect's search area (PROD-4337) ------------------------
  // The owner's chosen claim-finder location: lat/lng, label and
  // `countryCode`. Two leaks in one. The label and coordinates are the
  // previous owner's whereabouts, and `countryCode` is the FIRST source of
  // `businessSearchRegionProvider`, so a stale one biases the next owner's
  // Google "Find more" (`region_code`, PROD-4296) to the wrong country.
  //
  // Safe to purge: nothing writes it before the auth flip, so it is clear of
  // the pre-flip hazard in the header. On rebuild its tiers re-derive from
  // the new account's own location and Discovery centre.
  businessSearchAreaProvider,

  // ---- Onboarding tour progress (per account) ---------------------------
  productTourControllerProvider,
  tourDescobreTabsDoneProvider,
  tourAdicionaCardReadyProvider,

  // ---- Campaign "don't show again" gating (per account) -----------------
  // Owns the caller's client-side campaign response gating. Account B must not
  // inherit account A's dismissed/answered campaigns, so purge on switch and
  // let it re-hydrate for the new account.
  campaignServiceProvider,
];

/// Drops every account-scoped cache the app holds.
///
/// Three layers, because they are separate stores:
///   1. the in-memory id caches inside the API clients (`listsApi` keeps
///      `_allOwnedEventIds` etc., which drive the bookmark-filled state);
///   2. the Riverpod providers in [userScopedProviders];
///   3. `LocationNotifier`'s belief about what the server holds for the
///      signed-in account — see the targeted reset below.
///
/// Safe to call more than once — `clearCache()` is idempotent and
/// invalidating a provider nobody has created yet does nothing.
///
/// Invalidation deliberately goes through `ref.container.invalidate` rather
/// than `ref.invalidate`. `Ref.invalidate` runs `_debugAssertCanDependOn`,
/// whose cycle check calls `readProviderElement` — which *builds* the
/// provider if it does not exist yet. That happens inside an `assert`, so
/// in debug and test builds a bulk purge would eagerly construct all ~50
/// providers here (firing their requests, spinning up `LocationNotifier`,
/// …) while release builds, with asserts stripped, would not. The
/// container method skips the assert and no-ops on uncreated providers, so
/// debug and release behave identically. See
/// `docs/learnings/riverpod-ref-invalidate-builds-uncreated-providers.md`.
void purgeUserScopedState(Ref ref) {
  ref.read(listsApiProvider).clearCache();
  ref.read(savedApiProvider).clearCache();
  ref.read(memoryApiProvider).clearCache();
  ref.read(sessionsApiProvider).clearCache();

  // PROD-4403 — `activeSessionIdProvider` is in [userScopedProviders], but
  // invalidating it only rebuilds `ActiveSessionNotifier`, whose
  // `_initFromStorage` re-reads the SAME persisted `active_session_id` key and
  // resurrects the previous account's chat id. Account B then operates on
  // account A's session and 403s on every session-scoped call (GET session,
  // POST messages, PUT search-center). Remove the persisted key here so the
  // rebuild below reads null. `SharedPreferences.remove` updates the in-memory
  // cache synchronously, so the invalidate() that follows sees the cleared
  // value even though the disk write is still in flight.
  ref.read(storageServiceProvider).clearActiveSessionId();

  final container = ref.container;
  for (final provider in userScopedProviders) {
    container.invalidate(provider);
  }

  // PROD-3580 — `locationProvider` holds device state (the fix, the OS
  // permission, the sharing mode) and account state (`_lastBackendLocation`,
  // seeded from `GET /me/location`, plus the backend's reverse geocode of the
  // authenticated PUT) in one notifier. Invalidating it would drop the GPS
  // subscription and the PROD-3123 web-probe gating to clear two fields, so it
  // exposes a targeted reset instead and stays out of the list above.
  //
  // Hooked here rather than in the notifier's own factory so it inherits
  // `_IdentityWatcher`'s two guards for free. A hand-rolled `user?.id` listener
  // would fire on the cold-start `null → A` hydration and wipe the boot
  // read-back seed that `_readBackServerLocation` had just established —
  // `isAuthenticated` flips true before `/auth/me` lands, so the seed is
  // already there when the identity arrives.
  //
  // `exists` guard: reading `.notifier` would BUILD `LocationNotifier` —
  // permission checks, IP geolocation, timers — on every identity change,
  // which is the same eager-construction hazard the `container.invalidate`
  // note above exists to avoid.
  if (container.exists(locationProvider)) {
    container.read(locationProvider.notifier).resetAccountScopedBackendState();
  }
}

/// Watches the signed-in identity and purges account-scoped state on every
/// change: sign-out, sign-in, and a direct A→B switch alike.
///
/// Must be kept alive for the whole app lifetime — `SokoApp.build` watches
/// it. It holds no state of its own; the value is `void`.
final userScopedStatePurgeProvider = Provider<void>((ref) {
  // PROD-3580 — arm `returnUrlProvider`'s identity guard for the app's
  // lifetime. That guard is a `ref.listen` on its OWN element, and the element
  // is created lazily on first read: nothing reads the return URL during a
  // normal signed-in session, so without this the element's first existence is
  // often the session-loss redirect re-capturing the route *after* the account
  // is already gone — at which point it has no memory of who departed and
  // waves the next sign-in through with the previous account's destination.
  //
  // `read`, not `watch`: watching would rebuild this provider on every return
  // URL change, re-running `_IdentityWatcher` and resetting its boot grace
  // period. A `read` is enough — the provider is not `autoDispose`, so the
  // element it creates lives as long as the container.
  ref.read(returnUrlProvider);

  final watcher = _IdentityWatcher(ref);
  ref.listen<AuthState>(
    authStateProvider,
    (_, next) => watcher.onAuthState(next),
    fireImmediately: true,
  );
});

/// The transition rules, extracted so the two non-obvious guards live in
/// one place. Exercised end-to-end through [userScopedStatePurgeProvider]
/// in `test/core/session/account_switch_leak_repro_test.dart`.
class _IdentityWatcher {
  _IdentityWatcher(this._ref);

  final Ref _ref;

  /// False until the app's first *settled* auth state has been observed.
  /// Cold start hydrates `user` asynchronously (token restored from
  /// storage → `/auth/me`), so the boot identity arrives as a null → A
  /// transition that must NOT be mistaken for an account switch —
  /// purging there would invalidate providers that had only just been
  /// built and re-fire their requests on every launch.
  bool _booted = false;

  String? _lastIdentity;

  void onAuthState(AuthState next) {
    if (!next.isInitialized) return;

    final id = next.user?.id;

    if (!_booted) {
      // Booted with a stored account token but `/auth/me` hasn't landed
      // yet — hold the grace period open until the identity shows up.
      if (id == null && next.isAuthenticated) return;
      _booted = true;
      _lastIdentity = id;
      return;
    }

    if (id == _lastIdentity) return;

    // `logout()` clears the token and only THEN mints the replacement
    // guest JWT. Invalidating inside that gap would fire a burst of
    // unauthenticated requests, each 401 → refresh-failed → "session
    // expired". Wait for the session to be re-tokenized; the guest mint
    // emits another state and the purge runs on that one instead.
    //
    // If the mint fails (offline sign-out), the purge is deferred to the
    // next tokenized state — in practice the next sign-in, which is the
    // transition that actually matters for cross-account isolation.
    if (next.accessToken == null) return;

    _lastIdentity = id;
    purgeUserScopedState(_ref);
  }
}
