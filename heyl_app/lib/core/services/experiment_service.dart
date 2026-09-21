import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../features/discovery/feed_v2/debug/feed_flag_debug_log.dart';
import 'posthog_service.dart';
import '../config/research_invitation.dart';

/// State holding experiment flag values.
///
/// Starts with defaults (carousel shown) and updates reactively
/// when PostHog feature flags resolve.
class ExperimentState {
  /// Whether voice messages (mic button, recording, playback) are enabled.
  /// Disabled by default — feature removed due to poor UX (slow processing,
  /// infinite loading). Can be re-enabled via PostHog flag 'voice-messages'.
  final bool enableVoiceMessages;

  /// Whether image attachments (add button, gallery/camera picker) are enabled.
  /// Disabled by default — feature removed because Soko cannot process images.
  /// Can be re-enabled via PostHog flag 'image-attachments'.
  final bool enableImageAttachments;

  /// Whether the in-chat location suggestion card (Option E) is enabled.
  /// Shows a contextual card when Soko replies with place/event cards
  /// to users on IP fallback, prompting them to share their GPS location.
  /// Controlled via PostHog flag 'location-suggestion-card'.
  final bool enableLocationSuggestionCard;

  /// Whether the Discovery location suggestion banner is enabled. A remote
  /// kill switch lets us pause the prompt without another app release.
  /// Controlled via PostHog flag 'location-suggestion-banner'.
  final bool enableLocationSuggestionBanner;

  /// Whether smart list suggestions (AI-curated items based on a prompt) are enabled.
  /// Disabled by default — rolled out to specific admin users first.
  /// Controlled via PostHog flag 'smart-list-suggestions'.
  final bool enableSmartListSuggestions;

  /// Whether the user memory page (drawer entry + screen) is enabled.
  /// Disabled by default — rolled out to admins/testers first while the
  /// feature is in testing. Controlled via PostHog flag 'memory-page'.
  final bool enableMemoryPage;

  /// Master gate for the whole fake-door campaign feature (warm-up
  /// auto-surfacing + `/campaign/:key` deep link). Admin-first while in
  /// testing; default off. Controlled via PostHog flag 'fake-door-campaigns'
  /// (targeted to the `is_admin` person property).
  /// The admin trigger sheet is separately admin-gated and unaffected.
  final bool enableFakeDoorCampaigns;

  /// Business ownership claim and owner-edit surfaces. Defaults off: the
  /// backend owns the actual gate and also returns 404 while disabled.
  final bool enableBusinessOwnership;

  /// PROD-2906 (A6) — whether the Map page requests server-side pin selection
  /// (`pins_version=2`). Disabled by default — dogfood rollout. When on, the
  /// map sends the v2 request (viewport rect + zoom) and consumes the server's
  /// `selection`; the server's own `MAP_PINS_V2_SELECTION` flag is the real
  /// kill-switch (flag off ⇒ `selection` null ⇒ the FE falls back to its
  /// client-side `selectPins`, so flipping this on is safe at any time).
  /// Controlled via PostHog flag 'map-pins-v2'.
  final bool enableMapPinsV2;

  /// PROD-3496 — whether the Map page's v2 search bar + focused search mode
  /// are enabled. Internal (@heyl.ai) rollout first while the suggestion
  /// dropdown (PROD-3497+) lands behind the same flag; kill-switch while the
  /// UX evolves pre-final-designs. Controlled via PostHog flag
  /// 'map-search-v2'. Local dev (PostHog disabled) can force it on with
  /// `--dart-define=MAP_SEARCH_V2=true` ([EnvironmentConfig.mapSearchV2Enabled]).
  final bool enableMapSearchV2;

  /// PROD-3656 — whether the map auto-promotes pool results into the marker
  /// slots a zoom-in frees (dots becoming pins in the same frame as the
  /// gesture, with no `/map/pins` round trip).
  ///
  /// **Default false — the feature is parked.** It shipped in 1.1.20+109 and
  /// made the pin set churn more than intended (pins appearing mid-gesture,
  /// stacks re-forming), so it is behind a remote kill-switch until the exact
  /// desired behaviour is agreed. Off ⇒ the map behaves exactly as it did
  /// before PROD-3656: a live camera move only ever *trims* the server's
  /// selection, and new pins arrive only when a response lands.
  ///
  /// Controlled via PostHog flag 'map-pin-auto-promotion'. Local dev (PostHog
  /// disabled) can force it on with
  /// `--dart-define=MAP_PIN_AUTO_PROMOTION=true`
  /// ([EnvironmentConfig.mapPinAutoPromotionEnabled]).
  final bool enableMapPinAutoPromotion;

  /// PROD-3657 — whether `/map/pins` pools are cached and pre-painted while the
  /// next response is in flight (so panning back over covered ground re-paints
  /// immediately instead of showing the away-area's pins).
  ///
  /// **Default false — parked for the same reason as
  /// [enableMapPinAutoPromotion]**: the pre-paint swaps the drawn pool
  /// mid-settle, which is a second pin transition per camera move. Off ⇒ the
  /// map behaves exactly as it did before PROD-3657 (one last-good response,
  /// no cache, no pre-paint) — and the widened promotion pool that
  /// PROD-3656 draws from this cache is empty too.
  ///
  /// Controlled via PostHog flag 'map-pins-cache'. Local dev can force it on
  /// with `--dart-define=MAP_PINS_CACHE=true`
  /// ([EnvironmentConfig.mapPinsCacheEnabled]).
  final bool enableMapPinsCache;

  /// PROD-2511 follow-up — per-category visibility for the notification
  /// preferences switches. Reminders + Discovery are always visible
  /// (backend dispatcher already fires `event_reminder` /
  /// `daily_drop_ready` / `weekly_bundle_ready`). The four below stay
  /// hidden in the UI until the BE pipeline lands a dispatcher for the
  /// category; flipping the PostHog flag on then reveals the toggle.
  /// All default `false` so a fresh install / unauthed user only sees the
  /// switches that actually do something.
  final bool enableNotifCategoryChat; // notif-category-chat
  final bool enableNotifCategorySocial; // notif-category-social
  final bool enableNotifCategoryAsyncJobs; // notif-category-async-jobs
  final bool enableNotifCategoryFeedback; // notif-category-feedback

  /// PROD-2511 — global kill-switch for the notifications engine. When
  /// false, the app disables EVERYTHING notifications: no FCM token
  /// PATCH, no foreground/opened/cold-start handlers, no inbox tab/
  /// button, no badge, no preferences section, no foreground toast.
  /// Default `true` so a fresh install / PostHog outage keeps the
  /// engine on. Flip to false in the PostHog dashboard
  /// (`notifications_engine_enabled`) to silence the whole subsystem
  /// without a release.
  final bool notificationsEngineEnabled;

  /// Whether the redesigned map-based location-scope **sheet** replaces the
  /// legacy full-screen `MapLocationPickerScreen`. Admin-first while in testing;
  /// default off, so a fresh install / PostHog outage keeps the legacy picker.
  /// Controlled via PostHog flag 'location-scope-sheet' (targets the `is_admin`
  /// person property). Local dev can force it on with
  /// `--dart-define=LOCATION_SCOPE_SHEET=true`
  /// ([EnvironmentConfig.locationScopeSheetEnabled]).
  final bool enableLocationScopeSheet;

  /// PROD-3950 — whether the **tip slot** renders on the Daily Drop detail
  /// page. v1 fills that slot with the drop's personalised `reason`, and the
  /// real tip feature lands in it later, so this gates the slot rather than any
  /// one piece of content.
  ///
  /// Admin-only for now: the PostHog flag `daily-drop-tip` targets the
  /// `is_admin` person property, so the copy can be judged on real drops before
  /// anyone else sees it. **That property is set server-side**, by the
  /// backend's PostHog person sync (`heyl/apps/analytics/posthog_sync.py`,
  /// `"is_admin": user_profile.role == "admin"`) — nothing in this app ever
  /// sends it, which reads like a broken gate if you only grep `lib/`. Every
  /// admin-targeted flag here works the same way. Default off, which is also where a fresh install or a
  /// PostHog outage lands — the slot collapses and the page keeps its rhythm,
  /// exactly as it does for a drop with no reason. Local dev can force it on
  /// with `--dart-define=DAILY_DROP_TIP=true`
  /// ([EnvironmentConfig.dailyDropTipEnabled]).
  final bool enableDailyDropTip;

  /// PROD-3888 — master switch flipping the OLD onboarding (upfront Siga
  /// welcome + legacy onboarding trigger) to the NEW one (no Siga; a
  /// non-dismissible chat onboarding). Drives the router's Siga/location bypass,
  /// the chat-onboarding gate, and the menu replay trigger — all keyed on the
  /// same cohort ([newOnboardingCohortProvider]).
  ///
  /// This is the SOLE driver of the cohort (no local role fallback) so the
  /// rollout can change with no app release. The flag targets the `is_admin`
  /// person property in PostHog (set server-side by the backend's PostHog sync,
  /// like `daily-drop-tip` / `fake-door-campaigns`), so today it's on for admins
  /// and off for everyone else. Default off ⇒ a fresh install / PostHog outage
  /// lands even an admin on the OLD Siga onboarding until the flag resolves —
  /// the accepted trade-off for dashboard-only control. Local dev can force it
  /// on with `--dart-define=NEW_ONBOARDING=true`
  /// ([EnvironmentConfig.newOnboardingEnabled]). See [newOnboardingCohortProvider].
  final bool enableNewOnboarding;

  /// PROD-4071 — remote kill-switch for the product-tour walkthrough (the
  /// 5-step Discovery coachmark tour, "Walk me through"). Default `true` so a
  /// fresh install or a PostHog outage keeps the walkthrough on exactly as it
  /// behaved before this flag existed; flip to `false` in the dashboard to
  /// silence the tour for everyone (or a cohort) without an app release.
  /// Gates the auto-start in `ProductTourHost._maybeStartTour`; the admin
  /// manual replay path is intentionally NOT gated. Controlled via PostHog flag
  /// 'product-tour' — version-agnostic on purpose, so future tour revisions
  /// share one gate rather than minting `-v2`, `-v3` keys.
  final bool enableProductTour;

  /// PROD-4007 — the release flag for the **server-driven Discovery feed**
  /// (v2), the umbrella's flip-and-revert lever (D44).
  ///
  /// ⚠️ **Do not read this field to decide what to render.** Read
  /// `discoveryFeedVariantProvider` instead. This is the *resolved* value,
  /// which arrives asynchronously and can change mid-session; the variant
  /// provider is the *session-fixed* one (D48/D49) and is the only correct
  /// input to a page choice. Gating an entire page on this field directly is
  /// precisely the old-page → flash → new-page bug the variant provider exists
  /// to prevent.
  ///
  /// PROD-4008 — **this flag is the only thing between a user and the v2
  /// feed.** The PostHog flag was created on 2026-09-10 targeting
  /// `is_admin = true` (ladder stage 2); widening it is a dashboard edit, not
  /// a release. Until then the flag was deliberately absent and the mount site
  /// carried an admin code gate on top — both are gone.
  ///
  /// No `--dart-define` override on purpose: a define would short-circuit the
  /// flag so that local runs never exercise it (the trap documented for
  /// `LOCATION_SCOPE_SHEET` in `docs/features/feature-flags.md`). Locally, an
  /// admin account resolves the flag exactly as production does.
  final bool enableDiscoveryFeedV2;

  /// Validated research offer, bound to the SDK identity that resolved it.
  /// Null means hidden; watchdog confirmation never invents an offer.
  final ResearchInvitation? researchInvitation;

  /// Whether the feature flags have been loaded from PostHog.
  /// When false, flags are still default values and
  /// should not be used for experiment exposure tracking.
  final bool loaded;

  /// Whether the flag values can be trusted for a ROUTING decision — a stronger
  /// signal than [loaded]. [loaded] flips true after the very first
  /// [ExperimentNotifier._loadFlags] pass, but on a **fresh login** that pass
  /// returns the PostHog defaults (the SDK hasn't cached the newly-identified
  /// user's flags yet); the real values only arrive after the post-identify
  /// [ExperimentNotifier.reloadFlags] double-load. Cohort-gated navigation (the
  /// onboarding-vs-Siga decision in `app_router`, and the `_SplashGate` hold in
  /// `app.dart`) must wait for THIS, not [loaded], or a cohort user is briefly
  /// mis-routed to the legacy Siga screen during the flag-load race (PROD-3888
  /// follow-up). True once the real values have landed, PostHog is disabled, or
  /// a watchdog cap elapses — see [ExperimentNotifier].
  final bool flagsConfirmed;

  /// PROD-4419 — whether a flag value fetched from PostHog's **server during
  /// this launch** has landed, as opposed to one the SDK had on disk from the
  /// previous session.
  ///
  /// [loaded] and [flagsConfirmed] deliberately do not mean this. The
  /// constructor's first [ExperimentNotifier._loadFlags] pass reads whatever
  /// the SDK has cached and confirms immediately — that is the cold-start fast
  /// path, it is what keeps the splash short, and
  /// `experiment_service_flags_confirmed_test.dart` pins it. For nearly every
  /// flag that is the right trade: a value one session stale changes a button
  /// or a slot, and the fresh value arrives moments later.
  ///
  /// `discovery-feed-v2` is the exception, because
  /// [DiscoveryFeedVariantNotifier] fixes the page for the whole session at the
  /// moment Discovery first builds. A stale `false` there is not corrected
  /// moments later — it costs the user an entire launch (D48). So the Discovery
  /// gate, and only the Discovery gate, waits for this.
  ///
  /// **Additive on purpose.** Nothing that existed before PROD-4419 reads this
  /// field, and the refresh pass that sets it never writes a flag value. A
  /// stale completion can therefore mark "refreshed" early but can never
  /// corrupt a flag or wedge [loaded] — which is exactly what rewiring the
  /// shared confirm path would have risked (codex review, 2026-09-14).
  ///
  /// Fail-open: set true when the refresh lands, when the post-identify
  /// [ExperimentNotifier.reloadFlags] confirms (already a fresh network read,
  /// so a signed-in user never waits for two fetches), when PostHog is
  /// disabled, and when the refresh times out. It means "stop waiting for a
  /// fresher answer", never "the answer is definitely fresh".
  final bool flagsFetchedThisLaunch;

  /// PROD-4425 — whether [enableDiscoveryFeedV2] in THIS state came from a
  /// PostHog **server read during this launch**.
  ///
  /// The **fail-closed** counterpart to fail-open [flagsFetchedThisLaunch], and
  /// the two exist separately because they were conflated once and the bug was
  /// invisible. `flagsFetchedThisLaunch` answers "should the Discovery gate stop
  /// waiting?" and is therefore set on every path that ends the wait, including
  /// three that produced no value at all: PostHog disabled,
  /// `reloadFeatureFlags()` timing out, and `getFeatureFlag()` timing out or
  /// throwing (the `catch` in [ExperimentNotifier._refreshDiscoveryFlag] only
  /// logs and falls through to `_markFlagsFetched`). Its own doc above says so
  /// in as many words — and PROD-4423 still mapped it straight to
  /// `FeedVariantSource.freshFlag`, so `feed_exposed` reported "we knew this
  /// reader's flag" for sessions where the fetch had failed. Found in the
  /// staging verification of that ticket.
  ///
  /// This one answers the other question — "did we actually get an answer?" —
  /// and is set on exactly two paths, both of which produced a value:
  /// [ExperimentNotifier._refreshDiscoveryFlag]'s success branch, and the final
  /// post-identify pass of [ExperimentNotifier.reloadFlags]. Every other path
  /// leaves it false, including [ExperimentNotifier.resetFlags].
  ///
  /// **Accepted residual:** [ExperimentNotifier._loadFlags]'s normal path can
  /// overwrite [enableDiscoveryFeedV2] from the SDK's cache after the refresh
  /// set this true, without clearing it. In practice they agree — the refresh
  /// awaits `reloadFeatureFlags()` first, which is what fills that same cache —
  /// and closing the gap would mean rewiring PROD-4419's deliberately additive
  /// load path for a window in which both reads hold the same value.
  final bool discoveryFlagIsFresh;

  /// PROD-4455 — no `discovery-feed-v2` answer can EVER arrive this launch, so
  /// waiting for one is pointless.
  ///
  /// Set on exactly one path: PostHog disabled in this build. That is a
  /// permanent, knowable-up-front condition, unlike "the answer has not come
  /// yet", which is what every other no-value path means and which the
  /// Discovery gate now waits out rather than acting on.
  ///
  /// **This is not the inverse of [discoveryFlagIsFresh].** Both are false for
  /// most of a normal launch — the answer is simply still in flight. Only this
  /// one means "stop hoping"; the gate reports `refresh_failed` for it and
  /// `cap` for a wait that merely ran out of time. Keeping them apart is what
  /// lets the dashboard tell a build with no analytics from a slow network.
  final bool discoveryFlagUnavailable;

  /// PROD-4425 — how many identity transitions have delivered a **confirmed
  /// post-identify** flag value this launch. Monotonic; starts at 0.
  ///
  /// The signal that makes "apply the post-login value" implementable at all.
  /// A consumer cannot otherwise tell a real post-identify answer from a
  /// pre-identify one: during [ExperimentNotifier.reloadFlags] the intermediate
  /// `_loadFlags` pass sets [loaded] on values resolved for the OLD identity,
  /// and the re-armed 3s watchdog can then stamp [flagsConfirmed] on top. That
  /// state is byte-identical to the real thing. It was a documented, accepted
  /// residual while `DiscoveryFeedVariantNotifier` deferred every late upgrade
  /// (D48); the moment it acts on one, acting on THAT state would apply a
  /// guest's flag value to a session that just signed in — the exact staleness
  /// PROD-4425 exists to remove.
  ///
  /// Written by one place only: [ExperimentNotifier.reloadFlags]'s final pass,
  /// which runs after the identify has been ingested. Compare it with `>` and
  /// never `!=` — [ExperimentNotifier.resetFlags] rebuilds the state from the
  /// constructor defaults and so resets this to 0, which `>` makes inert.
  final int postIdentifyGeneration;

  /// PROD-4425 — true while a post-identity-change [ExperimentNotifier.reloadFlags]
  /// is in flight, i.e. **the flag values in this state belong to the PREVIOUS
  /// identity**.
  ///
  /// [flagsConfirmed] cannot carry this: `reloadFlags` un-confirms at its start,
  /// but the re-armed 3s watchdog fires while the reload is still running (the
  /// reload's own `Future.delayed(2s)` plus four network round trips routinely
  /// exceed 3s) and stamps confirmation back onto those old-identity values.
  /// `_loadFlags` then deliberately preserves that confirmation with `||`. The
  /// result reads as a real answer to every consumer.
  ///
  /// `DiscoveryFeedVariantNotifier` must not act on it in EITHER direction: a
  /// pre-identify `false` would roll a v2 session back to legacy seconds after
  /// sign-in, only for the real post-identify answer to flip it straight back.
  /// Before PROD-4425 that bounce was invisible (the upgrade direction deferred
  /// under D48, so the session simply stayed on legacy); now that the upgrade
  /// applies, it would be a visible double swap.
  ///
  /// Always cleared before [ExperimentNotifier.reloadFlags] returns, including
  /// on the throwing path — a stuck `true` would silence the D49 rollback for
  /// the rest of the session.
  final bool postIdentifyPending;

  const ExperimentState({
    this.enableVoiceMessages = false,
    this.enableImageAttachments = false,
    this.enableLocationSuggestionCard = true,
    this.enableLocationSuggestionBanner = true,
    this.enableSmartListSuggestions = false,
    this.enableMemoryPage = false,
    this.enableFakeDoorCampaigns = false,
    this.enableBusinessOwnership = false,
    this.enableMapPinsV2 = false,
    this.enableMapSearchV2 = false,
    this.enableMapPinAutoPromotion = false,
    this.enableMapPinsCache = false,
    this.enableNotifCategoryChat = false,
    this.enableNotifCategorySocial = false,
    this.enableNotifCategoryAsyncJobs = false,
    this.enableNotifCategoryFeedback = false,
    this.notificationsEngineEnabled = true,
    this.enableLocationScopeSheet = false,
    this.enableDailyDropTip = false,
    this.enableNewOnboarding = false,
    this.enableProductTour = true,
    this.enableDiscoveryFeedV2 = false,
    this.researchInvitation,
    this.loaded = false,
    this.flagsConfirmed = false,
    this.flagsFetchedThisLaunch = false,
    this.discoveryFlagIsFresh = false,
    this.discoveryFlagUnavailable = false,
    this.postIdentifyGeneration = 0,
    this.postIdentifyPending = false,
  });

  ExperimentState copyWith({
    bool? enableVoiceMessages,
    bool? enableImageAttachments,
    bool? enableLocationSuggestionCard,
    bool? enableLocationSuggestionBanner,
    bool? enableSmartListSuggestions,
    bool? enableMemoryPage,
    bool? enableFakeDoorCampaigns,
    bool? enableBusinessOwnership,
    bool? enableMapPinsV2,
    bool? enableMapSearchV2,
    bool? enableMapPinAutoPromotion,
    bool? enableMapPinsCache,
    bool? enableNotifCategoryChat,
    bool? enableNotifCategorySocial,
    bool? enableNotifCategoryAsyncJobs,
    bool? enableNotifCategoryFeedback,
    bool? notificationsEngineEnabled,
    bool? enableLocationScopeSheet,
    bool? enableDailyDropTip,
    bool? enableNewOnboarding,
    bool? enableProductTour,
    bool? enableDiscoveryFeedV2,
    ResearchInvitation? researchInvitation,
    bool clearResearchInvitation = false,
    bool? loaded,
    bool? flagsConfirmed,
    bool? flagsFetchedThisLaunch,
    bool? discoveryFlagIsFresh,
    bool? discoveryFlagUnavailable,
    int? postIdentifyGeneration,
    bool? postIdentifyPending,
  }) {
    return ExperimentState(
      enableVoiceMessages: enableVoiceMessages ?? this.enableVoiceMessages,
      enableImageAttachments:
          enableImageAttachments ?? this.enableImageAttachments,
      enableLocationSuggestionCard:
          enableLocationSuggestionCard ?? this.enableLocationSuggestionCard,
      enableLocationSuggestionBanner:
          enableLocationSuggestionBanner ?? this.enableLocationSuggestionBanner,
      enableSmartListSuggestions:
          enableSmartListSuggestions ?? this.enableSmartListSuggestions,
      enableMemoryPage: enableMemoryPage ?? this.enableMemoryPage,
      enableFakeDoorCampaigns:
          enableFakeDoorCampaigns ?? this.enableFakeDoorCampaigns,
      enableBusinessOwnership:
          enableBusinessOwnership ?? this.enableBusinessOwnership,
      enableMapPinsV2: enableMapPinsV2 ?? this.enableMapPinsV2,
      enableMapSearchV2: enableMapSearchV2 ?? this.enableMapSearchV2,
      enableMapPinAutoPromotion:
          enableMapPinAutoPromotion ?? this.enableMapPinAutoPromotion,
      enableMapPinsCache: enableMapPinsCache ?? this.enableMapPinsCache,
      enableNotifCategoryChat:
          enableNotifCategoryChat ?? this.enableNotifCategoryChat,
      enableNotifCategorySocial:
          enableNotifCategorySocial ?? this.enableNotifCategorySocial,
      enableNotifCategoryAsyncJobs:
          enableNotifCategoryAsyncJobs ?? this.enableNotifCategoryAsyncJobs,
      enableNotifCategoryFeedback:
          enableNotifCategoryFeedback ?? this.enableNotifCategoryFeedback,
      notificationsEngineEnabled:
          notificationsEngineEnabled ?? this.notificationsEngineEnabled,
      enableLocationScopeSheet:
          enableLocationScopeSheet ?? this.enableLocationScopeSheet,
      enableDailyDropTip: enableDailyDropTip ?? this.enableDailyDropTip,
      enableNewOnboarding: enableNewOnboarding ?? this.enableNewOnboarding,
      enableProductTour: enableProductTour ?? this.enableProductTour,
      enableDiscoveryFeedV2:
          enableDiscoveryFeedV2 ?? this.enableDiscoveryFeedV2,
      researchInvitation: clearResearchInvitation
          ? null
          : researchInvitation ?? this.researchInvitation,
      loaded: loaded ?? this.loaded,
      flagsConfirmed: flagsConfirmed ?? this.flagsConfirmed,
      flagsFetchedThisLaunch:
          flagsFetchedThisLaunch ?? this.flagsFetchedThisLaunch,
      discoveryFlagIsFresh: discoveryFlagIsFresh ?? this.discoveryFlagIsFresh,
      discoveryFlagUnavailable:
          discoveryFlagUnavailable ?? this.discoveryFlagUnavailable,
      postIdentifyGeneration:
          postIdentifyGeneration ?? this.postIdentifyGeneration,
      postIdentifyPending: postIdentifyPending ?? this.postIdentifyPending,
    );
  }
}

/// Provider for the experiment service.
///
/// Widgets that [ref.watch] this provider will rebuild when flags resolve.
final experimentServiceProvider =
    StateNotifierProvider<ExperimentNotifier, ExperimentState>((ref) {
      final posthog = ref.watch(postHogServiceProvider);
      return ExperimentNotifier(posthog);
    });

/// Notifier that reads feature flags for A/B experiments.
///
/// This service ONLY handles feature flag reads — it does NOT send events.
/// Event tracking is [UnifiedAnalyticsService]'s responsibility.
///
/// Flags are fetched asynchronously from PostHog on creation.
/// The state updates reactively when flags resolve, triggering
/// widget rebuilds via [ref.watch].
class ExperimentNotifier extends StateNotifier<ExperimentState> {
  final PostHogService _posthog;

  /// The maximum time [ExperimentState.flagsConfirmed] can stay false. If
  /// PostHog is slow/unreachable (or the post-identify [reloadFlags] hangs),
  /// this fires so a cohort-gated wait (e.g. `_SplashGate`) can never hang the
  /// app on the splash. `_SplashGate` has its own independent cap too.
  static const Duration _confirmWatchdogTimeout = Duration(seconds: 3);

  /// True while a post-identity-change [reloadFlags] is in flight. During this
  /// window the intermediate [_loadFlags] passes must NOT confirm — only the
  /// final post-identify pass carries the real cohort value. Outside it (the
  /// cold-start / returning-user case) the SDK-cached flags are already correct,
  /// so [_loadFlags] confirms immediately (no added splash wait).
  bool _loginReloadPending = false;
  int _identityGeneration = 0;

  Timer? _confirmWatchdog;

  /// PROD-4455 — the retry sleep, held so `dispose()` can cancel it.
  ///
  /// A bare `Future.delayed` cannot be cancelled: the timer outlives the
  /// notifier and every widget test that builds this service dies on
  /// "A Timer is still pending even after the widget tree was disposed".
  /// 83 of them did. The same leak in production is a timer ticking against a
  /// disposed notifier — harmless only because of the `mounted` guard after the
  /// await, which is exactly the kind of "harmless" that stops being harmless.
  Timer? _retryTimer;
  Completer<void>? _retrySleep;

  /// PROD-4419 — how long the Discovery refresh pass waits on PostHog before
  /// giving up and letting the Discovery gate open on the SDK-cached answer.
  ///
  /// Shorter than [_confirmWatchdogTimeout] on purpose: this one gates a page
  /// that is already painting behind a loading frame, so a long wait is a
  /// visible stall rather than a splash the user expects. The Discovery gate
  /// caps itself independently too — this bound exists so the *fetch* cannot
  /// dangle, not so the UI cannot hang.
  static const Duration _discoveryRefreshTimeout = Duration(seconds: 2);

  /// PROD-4455 — how long [_refreshDiscoveryFlag] keeps ASKING for an answer,
  /// as opposed to how long any single read may dangle.
  ///
  /// Deliberately the same 3s the Discovery gate holds its splash for
  /// (`kDiscoveryFeedVariantGateCap`): the gate is waiting on exactly this
  /// pass, so a shorter budget here would make it give up while the user is
  /// still looking at the splash, and a longer one would keep asking for an
  /// answer nobody is waiting for any more. The two numbers are one decision
  /// and must move together.
  static const Duration _discoveryAnswerDeadline = Duration(milliseconds: 3000);

  /// Gap between re-asks inside that budget. Short enough that the common case
  /// (measured p50 ≈ 600ms in production) costs at most a couple of extra
  /// reads, long enough that a blocked SDK is not spun against.
  static const Duration _discoveryRetryInterval = Duration(milliseconds: 250);

  /// PROD-4455 — how long [_refreshDiscoveryFlag] keeps re-asking. Injected so
  /// it can be driven to zero (or through `fakeAsync`) in tests.
  ///
  /// It is a constructor parameter rather than a constant because the retry
  /// spends REAL time: a 3s budget in the constructor path is invisible in
  /// production (the user is looking at a splash that was already up) and
  /// crippling in a suite that builds this notifier hundreds of times. The
  /// first cut of this used the constant directly and took one test file from
  /// seconds to >15 minutes.
  final Duration _answerDeadline;

  ExperimentNotifier(this._posthog, {Duration? answerDeadline})
    : _answerDeadline = answerDeadline ?? _discoveryAnswerDeadline,
      super(const ExperimentState()) {
    _startConfirmWatchdog();
    // Unawaited, exactly as before: nothing in the constructor may block, and
    // this is the cold-start fast path that confirms off the SDK's disk cache.
    _loadFlags();
    // PROD-4419 — additive, and deliberately NOT sequenced in front of
    // `_loadFlags()`. Putting an await there would race `_identityGeneration`
    // (which `_loadFlags` captures only at its own start), and would wedge
    // `loaded` outright if the reload hung, since the watchdog sets only
    // `flagsConfirmed`. See [ExperimentState.flagsFetchedThisLaunch].
    _refreshDiscoveryFlag();
  }

  /// Sleeps [_discoveryRetryInterval], or returns early if the notifier is
  /// disposed first. The caller re-checks `mounted` and bails.
  Future<void> _retryDelay() {
    _retryTimer?.cancel();
    final sleep = Completer<void>();
    _retrySleep = sleep;
    _retryTimer = Timer(_discoveryRetryInterval, () {
      if (!sleep.isCompleted) sleep.complete();
    });
    return sleep.future;
  }

  /// Fetches `discovery-feed-v2` from PostHog's server during this launch, so
  /// the Discovery gate is not deciding the whole session off a value the SDK
  /// had on disk from last time (PROD-4419).
  ///
  /// Writes exactly two things: the Discovery flag itself, and
  /// [ExperimentState.flagsFetchedThisLaunch]. It touches no other flag, and
  /// neither [ExperimentState.loaded] nor [ExperimentState.flagsConfirmed], so
  /// the cold-start confirm timing every other consumer depends on is
  /// unchanged.
  ///
  /// Never throws and always settles the field — a hung or failing PostHog
  /// costs the user a stale variant for one launch, never a stuck page.
  Future<void> _refreshDiscoveryFlag() async {
    // Captured BEFORE the await. A sign-in landing mid-fetch bumps the
    // generation, and the value in flight was resolved for the previous
    // identity; `reloadFlags()` is already fetching the right one.
    final generation = _identityGeneration;

    feedFlagLog('refresh.start', {
      'gen': generation,
      'posthogEnabled': _posthog.isEnabled,
    });

    if (!_posthog.isEnabled) {
      feedFlagLog('refresh.skip', {'reason': 'posthog_disabled'});
      // PROD-4455 — terminal, and the gate needs to know: no amount of waiting
      // produces an answer in a build with PostHog off, so it opens at once on
      // the cache rather than showing a 3s splash on every local/test launch.
      if (mounted) {
        state = state.copyWith(discoveryFlagUnavailable: true);
      }
      _markFlagsFetched(generation);
      return;
    }

    // PROD-4455 — started BEFORE the reload, not after it. The reload can take
    // up to 2s of the same wall clock the gate is counting down, so a deadline
    // opened afterwards would let this pass run for reload + 3s, well past the
    // splash it feeds. Codex review caught the comment claiming "the same 3s
    // budget" while the code implemented a later one.
    final deadline = DateTime.now().add(_answerDeadline);

    try {
      await _posthog.reloadFeatureFlags().timeout(_discoveryRefreshTimeout);
      if (!mounted || generation != _identityGeneration) {
        feedFlagLog('refresh.abandoned', {
          'after': 'reload',
          'gen': generation,
        });
        return;
      }
      // PROD-4433 — the nullable read is the fix. `getFeatureFlag` returns
      // `Future<bool>` and maps a MISSING flag onto its `defaultValue`, so
      // "PostHog said false" and "PostHog had no answer" arrived here as the
      // same `false` — and since neither case throws, the `catch` below never
      // ran and freshness was claimed over a default. That is how a reader
      // assigned to the treatment arm rendered the control feed while
      // `variant_source` reported `fresh_flag`.
      // PROD-4455 — ask REPEATEDLY, not once.
      //
      // On a first-ever identity the SDK holds no value yet and answers `null`
      // immediately — it does not block waiting for the server. A single read
      // therefore resolves "no answer" in milliseconds, `discoveryFlagIsFresh`
      // stays false for the whole launch, and nothing ever looks again: the
      // reader is committed to the cached `false` even though the real answer
      // lands moments later. Measured in production 2026-09-15, that is 30% of
      // identities, and it is biased by construction toward first launches —
      // the cohort a new-feed experiment cares most about.
      //
      // It is a race, not a failure: p50 to the first real answer is ~594ms,
      // p90 ~2.27s. So keep asking until the deadline, which is the same 3s
      // the gate is holding its splash for.
      bool? value;
      var attempts = 0;
      while (true) {
        attempts++;
        try {
          value = await _posthog
              .getFeatureFlagOrNull('discovery-feed-v2')
              .timeout(_discoveryRefreshTimeout);
        } catch (e) {
          // PROD-4455 — a read that times out or throws means "no answer YET",
          // not "give up". It used to fall through to the outer catch, which
          // left the loop after a single slow read and silently disabled the
          // retry in exactly the conditions it exists for. Codex review.
          feedFlagLog('refresh.readThrew', {
            'error': e.runtimeType,
            'attempts': attempts,
          });
          value = null;
        }
        if (!mounted || generation != _identityGeneration) {
          feedFlagLog('refresh.abandoned', {
            'after': 'read',
            'gen': generation,
            'attempts': attempts,
          });
          return;
        }
        if (value != null) break;
        if (!DateTime.now().isBefore(deadline)) {
          feedFlagLog('refresh.exhausted', {'attempts': attempts});
          break;
        }
        await _retryDelay();
        if (!mounted || generation != _identityGeneration) {
          feedFlagLog('refresh.abandoned', {
            'after': 'retry-sleep',
            'gen': generation,
            'attempts': attempts,
          });
          return;
        }
      }

      if (value == null) {
        // PROD-4433 — an answer we do not have, now only reachable after the
        // PROD-4455 retry budget above is spent. Leave `enableDiscoveryFeedV2`
        // alone (creation falls back to the cache, as it always has) and leave
        // `discoveryFlagIsFresh` false.
        //
        // ⚠️ PROD-4455 changed what happens next. This no longer opens the
        // gate: `_markFlagsFetched` below still runs (every other consumer
        // depends on it, and it must never become a way for Home to hang), but
        // the Discovery gate stopped keying on it and now waits for its own 3s
        // cap, reporting `cap` rather than `refresh_failed`. `refresh_failed`
        // is left for the one case where no answer can ever arrive — PostHog
        // disabled — which returns far above without reaching here.
        feedFlagLog('refresh.absent', {
          'note': 'no value after retries — not writing, staying not-fresh',
          'attempts': attempts,
          if (feedFlagDebugEnabled)
            'probe': await _posthog.debugProbeFlags(const [
              'discovery-feed-v2',
              'location-scope-sheet',
              'map-pins-v2',
            ]),
        });
      } else {
        // PROD-4425 — the ONLY place outside `reloadFlags`'s final pass that
        // may claim freshness, because it is the only one holding a value the
        // server just produced. `_markFlagsFetched` below runs on the failure
        // paths too and must not be mistaken for this; see
        // [ExperimentState.discoveryFlagIsFresh].
        state = state.copyWith(
          enableDiscoveryFeedV2: value,
          discoveryFlagIsFresh: true,
        );
        feedFlagLog('refresh.value', {
          'value': value,
          'fresh': true,
          'attempts': attempts,
        });
      }
    } catch (e) {
      // Timeout, or PostHog throwing. Either way the gate must stop waiting —
      // but we got no value, so `discoveryFlagIsFresh` stays false and the
      // gate opens reporting `refresh_failed` rather than `fresh_flag`.
      feedFlagLog('refresh.threw', {'error': e.runtimeType});
      debugPrint('[Experiment] discovery-feed-v2 refresh failed: $e');
    }
    _markFlagsFetched(generation);
    // `mounted` before touching `state`: reading a disposed StateNotifier
    // throws, and a log line must never be able to break the thing it
    // observes. `_markFlagsFetched` guards itself the same way; this ran
    // unguarded for one commit and a teardown test caught it immediately.
    if (!mounted) return;
    feedFlagLog('refresh.done', {
      'value': state.enableDiscoveryFeedV2,
      'isFresh': state.discoveryFlagIsFresh,
      'fetchedThisLaunch': state.flagsFetchedThisLaunch,
    });
  }

  void _markFlagsFetched(int generation) {
    if (!mounted || generation != _identityGeneration) return;
    if (state.flagsFetchedThisLaunch) return;
    state = state.copyWith(flagsFetchedThisLaunch: true);
  }

  void _startConfirmWatchdog() {
    _confirmWatchdog?.cancel();
    _confirmWatchdog = Timer(_confirmWatchdogTimeout, () {
      if (!mounted) return;
      if (!state.flagsConfirmed) {
        state = state.copyWith(flagsConfirmed: true);
      }
    });
  }

  @override
  void dispose() {
    _confirmWatchdog?.cancel();
    // PROD-4455 — cancel the timer AND release anything waiting on it. Cancel
    // alone would leave the retry loop awaiting a future that can never
    // complete, trading a pending timer for a leaked async frame.
    _retryTimer?.cancel();
    if (_retrySleep?.isCompleted == false) _retrySleep!.complete();
    super.dispose();
  }

  /// Reload flags after user identity changes (login/logout).
  ///
  /// Does a double-load: first immediately (best-effort), then again
  /// after a short delay. The delay gives PostHog's server time to
  /// ingest the person properties from the preceding [identify]+[flush]
  /// call, so flag targeting (e.g., `is_admin`) evaluates correctly.
  Future<void> reloadFlags() async {
    final generation = ++_identityGeneration;
    // Identity just changed: the previously confirmed cohort value is now stale
    // (the flag targets `is_admin`, evaluated per-identity). Un-confirm and
    // re-arm the watchdog so a cohort-gated wait holds for the REAL
    // post-identify value (or the cap) rather than acting on the stale one.
    _loginReloadPending = true;
    if (mounted) {
      state = state.copyWith(
        flagsConfirmed: false,
        clearResearchInvitation: true,
        // PROD-4425 — publish the un-confirm so consumers can see it survive
        // the watchdog re-confirming old-identity values mid-reload, and drop
        // the freshness claim: whatever `discovery-feed-v2` holds right now was
        // resolved for the identity we are leaving.
        postIdentifyPending: true,
        discoveryFlagIsFresh: false,
        // PROD-4455 — and drop the terminal marker `resetFlags()` sets on
        // logout. An identity change means an answer CAN arrive again, so the
        // gate must go back to waiting rather than inheriting "never" from the
        // signed-out state.
        discoveryFlagUnavailable: false,
      );
    }
    _startConfirmWatchdog();

    try {
      await _reloadFlagsBody(generation);
    } finally {
      // PROD-4425 — `_loadFlags` has no try/catch around its ~20 flag reads, so
      // a throwing PostHog propagates out of the body and `onIdentityChanged`
      // swallows it. A `postIdentifyPending` left true would then silence the
      // D49 rollback for the rest of the session, which is the one direction
      // that must never be slow. Skipped when a NEWER reload has taken over:
      // that call owns the flag now.
      if (mounted &&
          generation == _identityGeneration &&
          state.postIdentifyPending) {
        state = state.copyWith(postIdentifyPending: false);
      }
    }
  }

  Future<void> _reloadFlagsBody(int generation) async {
    // First attempt — may still see stale flags if the server hasn't
    // processed the identify yet, but gives us a quick first pass.
    await _posthog.reloadFeatureFlags();
    if (!mounted || generation != _identityGeneration) return;
    await _loadFlags(includeResearch: false);

    // Second attempt after delay — server should have processed the
    // identify by now, so flags based on person properties are correct.
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted || generation != _identityGeneration) return;
    await _posthog.reloadFeatureFlags();
    if (!mounted || generation != _identityGeneration) return;
    await _loadFlags();
    if (!mounted || generation != _identityGeneration) return;

    // The real post-identify values have landed — confirm.
    _loginReloadPending = false;
    if (!mounted) return;
    // PROD-4419 — `flagsFetchedThisLaunch` too: this pass IS a fresh network
    // read, so a signed-in user's Discovery gate must not also wait on the
    // constructor's refresh (which may have been abandoned on the generation
    // bump this very reload caused).
    //
    // PROD-4425 — and `postIdentifyGeneration`, which is written HERE and
    // nowhere else. It is what lets `DiscoveryFeedVariantNotifier` tell this
    // state — the real post-identify answer — from the pre-identify one the
    // intermediate `_loadFlags` pass plus the re-armed watchdog can produce,
    // which is otherwise identical from the outside. `discoveryFlagIsFresh`
    // rides along because `_loadFlags` above just read the flag through two
    // `reloadFeatureFlags()` calls.
    state = state.copyWith(
      loaded: true,
      flagsConfirmed: true,
      flagsFetchedThisLaunch: true,
      discoveryFlagIsFresh: true,
      postIdentifyGeneration: generation,
      postIdentifyPending: false,
    );
    _confirmWatchdog?.cancel();
  }

  /// Resolves once the flag values can be trusted for a **branching** decision,
  /// i.e. once [ExperimentState.flagsConfirmed] is true. Returns the state at
  /// that moment; returns the current state unchanged if the wait times out or
  /// this notifier is disposed.
  ///
  /// This is the imperative counterpart to `ref.watch(...).flagsConfirmed`.
  /// A widget can *watch* and rebuild when the value lands; a gate that runs
  /// once, on a tap (`showLocationScopePicker`), gets exactly one chance to
  /// read — and reading during the pre-confirm window silently returns the
  /// PostHog **defaults**, which for an admin-targeted flag means the feature
  /// looks un-shipped to the very person it targets.
  ///
  /// Nearly always returns synchronously in practice: flags confirm within
  /// seconds of app start, long before a user can reach a picker. The timeout
  /// exists so a hung PostHog can never wedge a UI action — it is not the
  /// expected path, and falling back to the current (default) state preserves
  /// exactly the old behaviour.
  Future<ExperimentState> whenFlagsConfirmed({
    Duration timeout = _confirmWatchdogTimeout,
  }) async {
    // `state` asserts mounted in state_notifier, so the disposed case must not
    // fall through to reading it.
    if (!mounted) return const ExperimentState();
    if (state.flagsConfirmed) return state;

    final completer = Completer<ExperimentState>();
    // `fireImmediately: false` — the current state was already checked above,
    // and firing immediately would complete with the unconfirmed value.
    final removeListener = addListener((next) {
      if (next.flagsConfirmed && !completer.isCompleted) {
        completer.complete(next);
      }
    }, fireImmediately: false);

    try {
      return await completer.future.timeout(
        timeout,
        // Reading `state` on a disposed StateNotifier throws, and the wait can
        // outlive the notifier (sign-out mid-tap).
        onTimeout: () => mounted ? state : const ExperimentState(),
      );
    } finally {
      removeListener();
    }
  }

  /// Reset flags to defaults (call on logout).
  void resetFlags() {
    _identityGeneration++;
    _loginReloadPending = false;
    _confirmWatchdog?.cancel();
    // `flagsConfirmed: true` — the defaults ARE the final answer for a
    // signed-out user: there is nobody left to target, and nothing reloads
    // flags after a logout (only `onIdentityChanged` calls [reloadFlags], and
    // that fires on login). Same shape as the PostHog-disabled path in
    // [_loadFlags], for the same reason: no async value is coming.
    //
    // Leaving it false is not merely untidy — it cancels the watchdog too, so
    // nothing would ever flip it, and every imperative waiter
    // ([whenFlagsConfirmed]) would burn its full timeout on every call for the
    // rest of the guest session. Codex review caught exactly that.
    //
    // `loaded` deliberately stays false: it means "PostHog has been read",
    // which after a reset is untrue, and the router keys some behaviour on it.
    //
    // PROD-4419 — `flagsFetchedThisLaunch: true` for the same reason
    // `flagsConfirmed` is: a logout does not un-fetch what this launch already
    // fetched, and nothing is going to fetch again. Resetting it to false would
    // make a Discovery gate created after a sign-out (sign out on Menu, then
    // tap Home) wait out its entire cap for an answer that is never coming.
    //
    // PROD-4425 — `discoveryFlagIsFresh` and `postIdentifyGeneration` are NOT
    // carried over, and both omissions are deliberate. Nothing was fetched for
    // the anonymous identity, so claiming freshness here is the exact
    // over-claim this ticket removes; and the generation reset to 0 is inert
    // because `DiscoveryFeedVariantNotifier` compares with `>`, never `!=`.
    state = const ExperimentState(
      flagsConfirmed: true,
      flagsFetchedThisLaunch: true,
      // PROD-4455 — terminal, for the same reason `flagsConfirmed` is: there is
      // nobody left to target and nothing reloads flags after a logout, so the
      // gate must not hold Home for 3s waiting on an answer that cannot come.
      // `reloadFlags()` clears it again on the next sign-in.
      discoveryFlagUnavailable: true,
    );
  }

  Future<void> _loadFlags({bool includeResearch = true}) async {
    final generation = _identityGeneration;
    // If PostHog is not enabled (local dev), keep defaults and confirm
    // immediately — there is no async value to wait for.
    if (!_posthog.isEnabled) {
      if (!mounted) return;
      // PROD-4419 — nothing fresher is coming when PostHog is off (local dev),
      // so the Discovery gate must not wait for it. PROD-4425 — but it did not
      // get an answer either: `discoveryFlagIsFresh` stays false, so the gate
      // opens reporting `refresh_failed`, not `fresh_flag`.
      state = state.copyWith(
        loaded: true,
        flagsConfirmed: true,
        flagsFetchedThisLaunch: true,
      );
      _confirmWatchdog?.cancel();
      return;
    }

    final voiceValue = await _posthog.getFeatureFlag(
      'voice-messages',
      defaultValue: false,
    );
    final imageValue = await _posthog.getFeatureFlag(
      'image-attachments',
      defaultValue: false,
    );
    final locationCardValue = await _posthog.getFeatureFlag(
      'location-suggestion-card',
      defaultValue: true,
    );
    final locationBannerValue = await _posthog.getFeatureFlag(
      'location-suggestion-banner',
      defaultValue: true,
    );
    final smartListValue = await _posthog.getFeatureFlag(
      'smart-list-suggestions',
      defaultValue: false,
    );
    final memoryPageValue = await _posthog.getFeatureFlag(
      'memory-page',
      defaultValue: false,
    );
    // Master gate for the fake-door campaign feature. Admin-first; the flag is
    // targeted to the is_admin person property in PostHog, so only admins see
    // any campaign until it's rolled out wider.
    final fakeDoorCampaignsValue = await _posthog.getFeatureFlag(
      'fake-door-campaigns',
      defaultValue: false,
    );
    final businessOwnershipValue = await _posthog.getFeatureFlag(
      'business-ownership',
      defaultValue: false,
    );
    // PROD-2906 (A6) — Map page server-side pin selection (pins_version=2).
    // Default false; safe to flip on (server flag is the real gate).
    final mapPinsV2Value = await _posthog.getFeatureFlag(
      'map-pins-v2',
      defaultValue: false,
    );
    // PROD-3496 — Map page v2 search bar + focused search mode. Internal
    // rollout first; default false.
    final mapSearchV2Value = await _posthog.getFeatureFlag(
      'map-search-v2',
      defaultValue: false,
    );
    // PROD-3656 / PROD-3657 — the two map pin-churn features, parked behind
    // remote kill-switches while the desired behaviour is tuned. Default false
    // means "the map as it behaved before those tickets", which is also what a
    // PostHog outage falls back to.
    final mapPinAutoPromotionValue = await _posthog.getFeatureFlag(
      'map-pin-auto-promotion',
      defaultValue: false,
    );
    final mapPinsCacheValue = await _posthog.getFeatureFlag(
      'map-pins-cache',
      defaultValue: false,
    );
    // PROD-2511 follow-up — per-category notification toggle visibility.
    // Defaults false so an unflagged install only sees the 2 always-on
    // categories (Reminders, Discovery) until the BE pipeline lands a
    // dispatcher for the others.
    final notifChatValue = await _posthog.getFeatureFlag(
      'notif-category-chat',
      defaultValue: false,
    );
    final notifSocialValue = await _posthog.getFeatureFlag(
      'notif-category-social',
      defaultValue: false,
    );
    final notifAsyncJobsValue = await _posthog.getFeatureFlag(
      'notif-category-async-jobs',
      defaultValue: false,
    );
    final notifFeedbackValue = await _posthog.getFeatureFlag(
      'notif-category-feedback',
      defaultValue: false,
    );
    // PROD-2511 — global kill-switch. Default `true` so the engine stays
    // on for a fresh install or if PostHog can't be reached. Flip to
    // false in the dashboard to silence the whole subsystem.
    final notificationsEngineValue = await _posthog.getFeatureFlag(
      'notifications_engine_enabled',
      defaultValue: true,
    );
    // Redesigned location-scope sheet — admin-first while testing, gated by the
    // PostHog `location-scope-sheet` flag (targets the is_admin person property).
    final locationScopeSheetValue = await _posthog.getFeatureFlag(
      'location-scope-sheet',
      defaultValue: false,
    );
    // PROD-3950 — the Daily Drop page's tip slot. Admin-first: the flag targets
    // the is_admin person property, so the reason copy can be judged on real
    // drops before anyone else sees it. Default false = the slot collapses,
    // which is the same shape a reason-less drop already has.
    final dailyDropTipValue = await _posthog.getFeatureFlag(
      'daily-drop-tip',
      defaultValue: false,
    );
    // PROD-3888 — old→new onboarding master switch, the SOLE cohort driver
    // (see [newOnboardingCohortProvider]). Targets the is_admin person property
    // in PostHog, so admins get the new flow today; widen from the dashboard to
    // release without a build. Default off = the OLD Siga onboarding.
    final newOnboardingValue = await _posthog.getFeatureFlag(
      'unskippable-onboarding-v1',
      defaultValue: false,
    );
    // PROD-4071 — product-tour walkthrough kill-switch. Default `true` = the
    // walkthrough behaves as it did before the flag; flip to false in the
    // dashboard to silence it with no app release.
    final productTourValue = await _posthog.getFeatureFlag(
      'product-tour',
      defaultValue: true,
    );
    // PROD-4007/PROD-4008 — server-driven Discovery feed (v2). Consumers must
    // read `discoveryFeedVariantProvider`, never this value directly — see the
    // field doc on [ExperimentState.enableDiscoveryFeedV2].
    final discoveryFeedV2Value = await _posthog.getFeatureFlag(
      'discovery-feed-v2',
      defaultValue: false,
    );
    ResearchInvitation? researchInvitation;
    if (includeResearch) {
      try {
        researchInvitation = await _posthog.getResearchInvitation();
      } catch (_) {
        // Optional campaign reads must never prevent the other flags loading.
      }
    }
    // Bail if the notifier was disposed while we were awaiting the
    // PostHog reads (e.g. tests tear down the container before the
    // micro-task chain completes). Setting state on a disposed
    // StateNotifier throws.
    if (!mounted || generation != _identityGeneration) return;
    state = state.copyWith(
      researchInvitation: researchInvitation,
      clearResearchInvitation: researchInvitation == null,
      enableVoiceMessages: voiceValue,
      enableImageAttachments: imageValue,
      enableLocationSuggestionCard: locationCardValue,
      enableLocationSuggestionBanner: locationBannerValue,
      enableSmartListSuggestions: smartListValue,
      enableMemoryPage: memoryPageValue,
      enableFakeDoorCampaigns: fakeDoorCampaignsValue,
      enableBusinessOwnership: businessOwnershipValue,
      enableMapPinsV2: mapPinsV2Value,
      enableMapSearchV2: mapSearchV2Value,
      enableMapPinAutoPromotion: mapPinAutoPromotionValue,
      enableMapPinsCache: mapPinsCacheValue,
      enableNotifCategoryChat: notifChatValue,
      enableNotifCategorySocial: notifSocialValue,
      enableNotifCategoryAsyncJobs: notifAsyncJobsValue,
      enableNotifCategoryFeedback: notifFeedbackValue,
      notificationsEngineEnabled: notificationsEngineValue,
      enableLocationScopeSheet: locationScopeSheetValue,
      enableDailyDropTip: dailyDropTipValue,
      enableNewOnboarding: newOnboardingValue,
      enableProductTour: productTourValue,
      // PROD-4425 — do NOT overwrite a value `_refreshDiscoveryFlag` already
      // proved fresh. `discoveryFeedV2Value` was captured further up this
      // method and at least one `await` ago (the research-invitation read), so
      // the refresh can land in between: this pass would then write back the
      // SDK's disk cache over the server value AND leave `discoveryFlagIsFresh`
      // true, so the gate reports `fresh_flag` about a stale variant. That is
      // the PROD-4419 bug wearing the label PROD-4423 added. `reloadFlags`
      // clears the freshness flag at its start, so its own passes still write.
      enableDiscoveryFeedV2: state.discoveryFlagIsFresh
          ? state.enableDiscoveryFeedV2
          : discoveryFeedV2Value,
      loaded: true,
      // Returning-user fast path: on the cold-start load (no login reload in
      // flight) the SDK-cached flags are already the real values, so confirm
      // right away and add no splash wait. During a login reload
      // (`_loginReloadPending`) these intermediate passes may still be default,
      // so leave confirmation to reloadFlags()'s final post-identify pass.
      // (`||` so an already-confirmed watchdog/prior pass is never un-set here.)
      flagsConfirmed: state.flagsConfirmed || !_loginReloadPending,
    );
    if (!_loginReloadPending) _confirmWatchdog?.cancel();
    debugPrint(
      '[Experiment] voice-messages: $voiceValue, image-attachments: $imageValue, location-suggestion-card: $locationCardValue, smart-list-suggestions: $smartListValue, memory-page: $memoryPageValue, map-pins-v2: $mapPinsV2Value, map-search-v2: $mapSearchV2Value, map-pin-auto-promotion: $mapPinAutoPromotionValue, map-pins-cache: $mapPinsCacheValue, notif-category-chat: $notifChatValue, notif-category-social: $notifSocialValue, notif-category-async-jobs: $notifAsyncJobsValue, notif-category-feedback: $notifFeedbackValue, notifications_engine_enabled: $notificationsEngineValue, location-scope-sheet: $locationScopeSheetValue, daily-drop-tip: $dailyDropTipValue, unskippable-onboarding-v1: $newOnboardingValue, product-tour: $productTourValue, discovery-feed-v2: $discoveryFeedV2Value, research-invitation: ${researchInvitation?.offer.flagValue ?? 'off'}',
    );
  }
}
