/// Destination identifiers for the analytics event registry.
enum Dest { posthog, firebase, backend, sentry, meta, tiktok, appsflyer }

/// Single source of truth for event → destination routing.
///
/// To add a new destination to an event: add it to the Set here.
/// To remove a destination from an event: remove it from the Set here.
/// To add a new destination entirely: implement [AnalyticsDestination],
/// add it to the [Dest] enum, and register it in [UnifiedAnalyticsService].
///
/// Events NOT in this registry will log a debug warning and be silently dropped.
const Map<String, Set<Dest>> eventRegistry = {
  'research_invitation_viewed': {Dest.posthog},
  'research_invitation_dismissed': {Dest.posthog},
  'research_interview_clicked': {Dest.posthog},

  // ============ AUTH ============
  'login': {
    Dest.firebase,
    Dest.backend,
    Dest.posthog,
    Dest.tiktok,
    Dest.appsflyer,
  },
  'sign_up': {
    Dest.firebase,
    Dest.backend,
    Dest.posthog,
    Dest.meta,
    Dest.tiktok,
    Dest.appsflyer,
  },
  'logout': {Dest.firebase, Dest.backend, Dest.posthog},
  'session_expired': {Dest.backend, Dest.posthog},
  // Phone OTP send + user-driven SMS fallback (PROD-2632). Backend +
  // PostHog only (matches `login` minus Firebase — auth funnel doesn't
  // reach Firebase). `otp_send` fires after every POST /auth/phone/start
  // response; `otp_fallback_sms` fires on user tap of the "Send via SMS"
  // link on the OTP screen.
  'otp_send': {Dest.backend, Dest.posthog},
  'otp_fallback_sms': {Dest.backend, Dest.posthog},

  // ============ APP LIFECYCLE ============
  'app_open': {Dest.backend, Dest.posthog},
  // Tier 2 (2026-09-17): one per foregrounding, with the door used. PostHog
  // only until the backend registry knows it (422 gate).
  'app_entry': {Dest.posthog},
  // PROD-3168: renamed from 'page_open' (login-only; the old name was a trap).
  'login_page_view': {Dest.backend, Dest.posthog},

  // ============ NAVIGATION ============
  'open_map': {Dest.backend, Dest.posthog},
  'open_lists': {Dest.backend, Dest.posthog},
  'list_open': {Dest.backend, Dest.posthog, Dest.meta, Dest.appsflyer},
  'chat_history_open': {Dest.backend, Dest.posthog},
  'memories_open': {Dest.backend, Dest.posthog},
  'screen_view': {Dest.firebase, Dest.backend, Dest.posthog},
  // PROD-3168: entry-points & navigation. Backend 422s these until it
  // registers them (swallowed); PostHog is the source of truth for now.
  'nav_tab_change': {Dest.backend, Dest.posthog},
  'chat_open': {Dest.backend, Dest.posthog},
  'discover_open': {Dest.backend, Dest.posthog},
  'create_open': {Dest.backend, Dest.posthog},
  'create_list_from_chat': {Dest.backend, Dest.posthog},
  'create_option_selected': {Dest.backend, Dest.posthog},
  'shared_by_view': {Dest.backend, Dest.posthog},
  'shared_by_click': {Dest.backend, Dest.posthog},

  // ============ CHAT ============
  // LEGACY NAME (PROD-3334): dead — trackMessageSent is @deprecated with no
  // callers; the canonical name is message_sent_user. Never route to PostHog.
  'message_sent': {
    Dest.backend,
  }, // legacy — Firebase only for user msgs (use message_sent_user)
  'message_sent_user': {
    Dest.firebase,
    Dest.backend,
    Dest.posthog,
    Dest.meta,
    Dest.appsflyer,
  },
  'message_sent_soko': {
    Dest.posthog,
  }, // PostHog only — backend emits its own (PROD-1396)
  // ============ SEARCH ============
  'search': {Dest.firebase, Dest.backend, Dest.posthog, Dest.tiktok},
  'search_result_click': {Dest.backend, Dest.posthog, Dest.appsflyer},
  // Client-emitted AppsFlyer-only signal for `af_search`; deliberately
  // separate from the backend-emitted `search` event above to avoid
  // double-count + Firebase `search_term` prop mismatch (PROD-3533).
  'search_submitted': {Dest.appsflyer},

  // ============ CONTENT INTERACTION ============
  'view_item': {Dest.firebase, Dest.backend, Dest.posthog, Dest.appsflyer},
  'item_impression': {Dest.backend, Dest.posthog},
  'item_unsave': {Dest.backend, Dest.posthog},
  // PROD-3209: canonical save, co-emitted with list_item_add inside
  // trackListItemAdd — see the contract notes; never sum the two.
  'item_saved': {Dest.backend, Dest.posthog},
  'preference_feedback': {Dest.backend, Dest.posthog},

  // ============ EXTERNAL CLICKS ============
  'external_click': {Dest.backend, Dest.posthog},
  'opening_hours_expand': {Dest.backend, Dest.posthog},

  // ============ LIST EVENTS ============
  'list_link_opened': {Dest.backend, Dest.posthog},
  'list_item_click': {Dest.backend, Dest.posthog},
  'list_share': {Dest.firebase, Dest.backend, Dest.posthog, Dest.appsflyer},
  'list_unfollow': {Dest.backend, Dest.posthog},
  'list_item_remove': {Dest.backend, Dest.posthog},
  'list_element_note': {Dest.backend, Dest.posthog},
  'list_report': {Dest.backend, Dest.posthog},

  // ============ MODERATION (PROD-2264) ============
  'content_report': {Dest.backend, Dest.posthog},
  'user_block': {Dest.backend, Dest.posthog},
  // PostHog only for now — backend registration must land in the
  // heyl-backend repo before flipping this to {Dest.backend, Dest.posthog}.
  // Server-side event registry rejects unknown names with 422.
  'content_blocked': {Dest.posthog},

  // ============ DEEP LINKS — SHORT-LINK RESOLUTION (PROD-2314) ============
  // Short.io branded short-link resolution outcomes. PostHog only — the
  // server-side event registry has no entry for these names yet (rejects
  // unknown names with 422); promote to {Dest.backend, Dest.posthog} once
  // heyl-backend registers them.
  'deep_link.short_link_resolved': {Dest.posthog},
  'deep_link.short_link_resolve_failed': {Dest.posthog},

  // ============ LIST CRUD ============
  'list_create': {
    Dest.firebase,
    Dest.backend,
    Dest.posthog,
    Dest.meta,
    Dest.tiktok,
    Dest.appsflyer,
  },
  'list_update': {Dest.firebase, Dest.backend, Dest.posthog},
  'list_delete': {Dest.firebase, Dest.backend, Dest.posthog},
  'list_follow': {Dest.firebase, Dest.backend, Dest.posthog},
  'list_item_add': {Dest.backend, Dest.posthog, Dest.appsflyer},

  // ============ LIST SEARCH ============
  'list_search': {Dest.backend, Dest.posthog},
  'list_search_scope_change': {Dest.posthog},

  // ============ LISTS HUB ============
  'list_hub_tap': {Dest.backend, Dest.posthog},
  'list_hub_section_expand': {Dest.backend, Dest.posthog},
  'lists_hub_filter': {Dest.backend, Dest.posthog},
  'lists_hub_search': {Dest.backend, Dest.posthog},
  // PROD-2742 — `/yours` deep-link funnel (auth_state: logged_in / logged_out).
  // Firebase + PostHog only: the generic backend `/app/analytics/track` rejects
  // event names absent from its server-side registry (422), so a backend
  // destination needs a heyl-backend change first — deferred.
  'yours_deep_link': {Dest.firebase, Dest.posthog},
  // PROD-3326: the /map deep-link funnel event — same backend-422 deferral.
  'map_deep_link': {Dest.firebase, Dest.posthog},

  // ============ LIST MANAGEMENT ============
  'list_reorder': {Dest.backend, Dest.posthog},
  'list_cover_change': {Dest.backend, Dest.posthog},
  'list_visibility_change': {Dest.backend, Dest.posthog},
  'list_import_open': {Dest.backend, Dest.posthog},
  'list_import_start': {Dest.backend, Dest.posthog},
  // list_import_complete: removed — emitted server-side (PROD-1396)
  'list_calendar': {Dest.backend, Dest.posthog},
  'list_map': {Dest.backend, Dest.posthog},

  // ============ SUGGESTIONS ============
  'suggestion_accept': {Dest.backend, Dest.posthog},
  'suggestion_dismiss': {Dest.backend, Dest.posthog},
  // Smart-list prompt lifecycle (PROD-1429).
  'suggestion_prompt_enable': {Dest.backend, Dest.posthog},
  'suggestion_prompt_edit': {Dest.backend, Dest.posthog},
  'suggestion_prompt_disable': {Dest.backend, Dest.posthog},
  'suggestion_find_more': {Dest.backend, Dest.posthog},

  // ============ DAILY DROP ============
  // PROD-2565 — react/save/share/cta/close emitted only by the deprecated
  // overlay (removed). Live surfaces emit open + profiling_cta_tap.
  'daily_drop_open': {Dest.firebase, Dest.backend, Dest.posthog},
  'daily_drop_profiling_cta_tap': {Dest.firebase, Dest.backend, Dest.posthog},

  // PROD-3730 — the waiting state. `generating_impression` is how we count
  // users landing on the ON-DEMAND path, which is the central question of the
  // PROD-3749 cost programme: the backend knows how many drops it generated,
  // only the client knows how many users saw the wait and whether we could
  // have notified them.
  'daily_drop_generating_impression': {
    Dest.firebase,
    Dest.backend,
    Dest.posthog,
  },
  'daily_drop_generating_sheet_shown': {
    Dest.firebase,
    Dest.backend,
    Dest.posthog,
  },
  // Distinct from the backend's `daily_drop_failed`: this is the CLIENT giving
  // up at its 2-minute cap. The Celery task may still be running and finish at
  // 130 s, in which case the backend records a success and the user saw a
  // failure. Only the client can report that divergence.
  'daily_drop_generation_timeout': {Dest.firebase, Dest.backend, Dest.posthog},

  // PROD-3950 — the Daily Drop got its own detail page, so opening the drop and
  // opening the *entity* it points at became two separate acts. This fires on
  // the second one: the "Learn more about this place/event" CTA that walks the
  // user from the drop page onto venue/event detail. It is the only place the
  // drop page writes an entity-level intent — the page itself deliberately
  // emits no `view_item` and fetches with `source` omitted, so nothing counts
  // as interest until the user asks for the entity here.
  'daily_drop_entity_cta_tap': {Dest.firebase, Dest.backend, Dest.posthog},

  // ============ USER PROFILING (PROD-2173) ============
  // Lifecycle of the user-profiling vibe flow. CTA tap is tracked separately
  // by `daily_drop_profiling_cta_tap`; these cover the actual flow.
  'profiling_started': {Dest.firebase, Dest.backend, Dest.posthog},
  'profiling_complete': {Dest.firebase, Dest.backend, Dest.posthog},
  'profiling_skipped': {Dest.firebase, Dest.backend, Dest.posthog},
  // PROD-2566 — `/user-profiling/flow` deep-link funnel (reason: logged_out /
  // already_profiled / rerun).
  'profiling_deep_link': {Dest.firebase, Dest.backend, Dest.posthog},

  // ============ EVENT DETAIL — ADD TO CALENDAR (PROD-2173) ============
  'event_add_to_calendar': {Dest.firebase, Dest.backend, Dest.posthog},

  // ============ MAP LOCATION PICKER (PROD-3109) ============
  // Fired when the user confirms an area picked on the map. Powers the A/B vs
  // the country/city scope flow (boundary_found distinguishes a real PT
  // neighborhood from the point fallback).
  'location_picker_map_select': {Dest.firebase, Dest.backend, Dest.posthog},
  // Location-scope sheet lifecycle (opened/dismissed/moved/search/
  // search_result). PostHog-only — diagnostic funnel around the picker; the
  // terminal "applied" outcome is the richer `location_picker_map_select`.
  'location_picker_interaction': {Dest.posthog},

  // ============ WEEKLY BUNDLE ============
  'weekly_bundle_open': {Dest.firebase, Dest.backend, Dest.posthog},
  'weekly_bundle_page_view': {Dest.backend, Dest.posthog},
  'weekly_bundle_item_tap': {Dest.firebase, Dest.backend, Dest.posthog},
  'weekly_bundle_items_toggle': {Dest.backend, Dest.posthog},
  'weekly_bundle_close': {Dest.firebase, Dest.backend, Dest.posthog},
  'weekly_bundle_save': {Dest.firebase, Dest.backend, Dest.posthog},
  'weekly_bundle_share': {Dest.firebase, Dest.backend, Dest.posthog},

  // ============ USER PREFERENCES ============
  'theme_change': {Dest.firebase, Dest.backend, Dest.posthog},
  'language_change': {Dest.firebase, Dest.backend, Dest.posthog},
  'memories_download': {Dest.backend, Dest.posthog},

  // ============ LOCATION ============
  'location_accuracy_status': {
    Dest.posthog,
  }, // diagnostic — PostHog only (fires on every poll)
  'location_ip_fallback_used': {Dest.posthog}, // diagnostic — PostHog only
  'location_ip_unresolved': {Dest.posthog}, // diagnostic — PostHog only
  'location_shared': {Dest.backend, Dest.posthog},
  'location_sharing_enabled': {Dest.backend, Dest.posthog},
  'location_sharing_disabled': {Dest.backend, Dest.posthog},

  // ============ ONBOARDING ============
  'onboarding_step': {Dest.backend, Dest.posthog},
  'onboarding_complete': {Dest.backend, Dest.posthog},
  'location_permission': {Dest.backend, Dest.posthog},
  'auth_prompt': {Dest.backend, Dest.posthog},
  'location_suggestion': {Dest.backend, Dest.posthog},
  // PostHog only for now — backend registration must land in the
  // heyl-backend repo before flipping these to {Dest.backend, Dest.posthog}.
  // See open-api/heyl-webapp-v1.openapi.yaml:5622 (server-side event
  // registry rejects unknown names with 422).
  'push_permission': {Dest.posthog},
  'push_suggestion': {Dest.posthog},

  // ============ PRODUCT TOUR ============
  'tour_step_view': {Dest.posthog},
  'tour_step_next': {Dest.posthog},
  'tour_skipped': {Dest.posthog},
  'tour_completed': {Dest.posthog},
  'tour_replayed': {Dest.posthog},

  // ============ FEATURE SPOTLIGHTS (PROD-2808) ============
  // Once-only in-app spotlights teaching existing users about new features.
  // PostHog-only for v1; backend registration follows once server-side event
  // schemas land (out-of-scope on this PR).
  'spotlight_shown': {Dest.posthog},
  'spotlight_dismissed': {Dest.posthog},
  'spotlight_cta_tapped': {Dest.posthog},

  // ============ MENU / PROFILE ============
  'account_open': {Dest.backend, Dest.posthog},
  'account_delete': {Dest.backend, Dest.posthog},
  'preferences_open': {Dest.backend, Dest.posthog},
  'support_open': {Dest.backend, Dest.posthog},
  'support_email_click': {Dest.backend, Dest.posthog},

  // ============ INSTAGRAM ============
  'instagram_connect_start': {Dest.backend, Dest.posthog},
  'instagram_connect_result': {Dest.backend, Dest.posthog},
  'instagram_disconnect': {Dest.backend, Dest.posthog},

  // ============ BUSINESS CONNECT — VENUE SEARCH (PROD-4270 S5) ============
  'business_venue_find_more': {Dest.posthog},
  'business_venue_find_more_resolve': {Dest.posthog},

  // ============ INSTAGRAM SHARE (PROD-1572) ============
  // Frontend tracks user-initiated clicks only — outcomes (API success /
  // failure / status) are emitted by the backend.
  'instagram_share_chat_dismiss': {Dest.backend, Dest.posthog},
  'instagram_share_open': {Dest.backend, Dest.posthog},
  // Renamed from instagram_share_submit (PROD-3208).
  'instagram_link_submitted': {Dest.backend, Dest.posthog, Dest.appsflyer},
  'instagram_share_dismissed': {Dest.backend, Dest.posthog},
  'instagram_share_banner_action': {Dest.backend, Dest.posthog},
  'instagram_share_review_save': {Dest.backend, Dest.posthog},
  'instagram_share_review_cancel': {Dest.backend, Dest.posthog},

  // ============ OUTBOUND SHARE FUNNEL (PROD-2785) ============
  // Client half of the share-card funnel: server emits
  // share_descriptor_resolved + share_channel_asset_generated, client
  // emits share_intent_fired + share_completed. Together they answer
  // "user tapped a channel → user actually posted".
  'share_intent_fired': {Dest.backend, Dest.posthog},
  'share_completed': {Dest.backend, Dest.posthog, Dest.appsflyer},

  // ============ DISCOVERY (PROD-1520 / 1522) ============
  // Admin-gated Discovery shelves dispatch these from
  // `unified_analytics_service.dart`; they were missing from the registry,
  // so every dispatch logged a debug "Unknown event" warning.
  'discovery_shelf_viewed': {Dest.backend, Dest.posthog},
  'discovery_shelf_card_clicked': {Dest.backend, Dest.posthog},
  'discovery_shelf_see_more_clicked': {Dest.backend, Dest.posthog},
  'discovery_history_card_clicked': {Dest.backend, Dest.posthog},

  // PROD-4238 — the server-driven feed's slate crossing.
  //
  // **PostHog only, deliberately.** `discovery_shelf_card_clicked` above routes
  // to `backend` and has 422'd since it shipped, because the backend
  // `EVENT_REGISTRY` never registered it — zero rows, ever. Adding a second
  // destination we know rejects the event would repeat that, so this ships
  // where it actually lands. Adding `Dest.backend` is one word once a backend
  // registry ticket lands.
  'feed_slate_advance': {Dest.posthog},

  // PROD-4423 — which Discovery feed a user was actually SHOWN.
  //
  // The four `feed_variant`-carrying events above are all legacy-shelf events,
  // and everything v2 emits is an action, so exposure and engagement were
  // inseparable: no rate could have "saw the feed" as its denominator. This is
  // the denominator. PostHog-only for the same reason `feed_slate_advance` is.
  'feed_exposed': {Dest.posthog},

  // PROD-4436 — which variant a session COMMITTED to, fired before any fetch.
  //
  // `feed_exposed` above cannot be the denominator it was built to be: v1
  // reports at mount while v2 waits for its first fetch and reports nothing if
  // the reader leaves during it, so the fastest bouncers are dropped from the
  // treatment arm only. This fires symmetrically at the decision; the gap
  // between the two is v2 fetch abandonment. Same destination as the event it
  // is the denominator for — a rate cannot be computed across two backends.
  'feed_variant_committed': {Dest.posthog},

  // ============ EXPERIMENTS ============
  'experiment_exposure': {Dest.backend, Dest.posthog},
  // first_message_sent is backend-owned end-to-end (ADR-023, PROD-3210):
  // the client no longer dispatches it at all — the old emission relayed to
  // the DB mirror only and its trigger (session creation) couldn't express
  // "first message ever per user".

  // ============ MAP PIN TOOLTIP (PROD-2016) ============
  // PostHog-only — no backend endpoint yet. The handoff says wire
  // through `BackendAnalyticsService` eventually; for now we ship the
  // FE side and the BE endpoint becomes a follow-up.
  'map_pin_tooltip_open': {Dest.posthog},
  'map_pin_view_details_click': {Dest.posthog},

  // ============ MAP PAGE (PROD-2671) ============
  // PROD-3219: `map_area_searched` (renamed from the old per-settle
  // `map_search`) is an OUTCOME event — it fires when a search RESOLVES
  // (carrying `result_count` + searched-area centre), deduped on a coarse
  // centre/zoom bucket, NOT on every camera settle. PostHog-only — no backend
  // endpoint yet, matching the map-pin events above.
  'map_area_searched': {Dest.posthog},

  // PROD-3219: results-drawer snap changes (half/full opens) + "+N" pin-cluster
  // taps on the Map page. PostHog-only.
  'map_drawer_snap_change': {Dest.posthog},
  'map_cluster_tap': {Dest.posthog},

  // PROD-2993 — the results↔map highlight. `map_highlight_enter` counts how
  // often anyone actually opens the drawer to `half` and uses the link;
  // `map_search_this_area` counts how often our automatic camera gets
  // overridden. The ratio is the honest read on whether the feature helps or
  // fights. Registering them is not optional: an unregistered event is logged
  // as "Unknown event" and **silently dropped** (see `map_search` above, which
  // learned this the hard way).
  'map_highlight_enter': {Dest.posthog},
  'map_search_this_area': {Dest.posthog},

  // PROD-3499 (map search v2, D34): a past-search row re-executed
  // successfully — the re-use rate of backend-stored history.
  'map_past_search_used': {Dest.posthog},

  // PROD-3500 (map search v2, Decision #34 / scenario H1): the v2 search-bar
  // funnel. All four are OUTCOME events, deliberately not keystroke
  // impressions — the old per-settle `map_search` fired 13.6k times for 18
  // users, which is why it no longer exists. `map_suggest_selected` counts
  // TYPED-DROPDOWN rows only; a keyword search reached any other way (Enter
  // today, whatever replaces it tomorrow) is counted by the producer-agnostic
  // `map_area_searched{trigger:'keyword'}` + `map_filter_change{filter:
  // 'keyword'}` below, which fire from the executor and know nothing about
  // who called them.
  'map_search_opened': {Dest.posthog},
  'search_opened': {Dest.posthog},
  'map_suggest_selected': {Dest.posthog},
  'map_suggest_expanded': {Dest.posthog},
  'map_suggest_zero_results': {Dest.posthog},
  // PROD-3652: a domain tag scoped the dropdown to one domain. Sits with the
  // suggest family and PostHog-only for the same reason they are — the backend
  // `POST /app/analytics/track` 422s on names it doesn't know.
  'map_suggest_domain_tag': {Dest.posthog},

  // PROD-3568 (map search v2, Decision #20/#46): a Zine became the map's
  // corpus. PostHog-only like the rest of the map surface — the generic
  // backend `POST /app/analytics/track` 422s on names it doesn't know, and
  // registering one there buys nothing this event needs.
  'map_list_opened': {Dest.posthog},

  // PROD-3194: leave-map divergence prompt funnel. Place names/coordinates
  // stay in the UI only; all five events are aggregate, PostHog-only signals.
  'map_leave_prompt_impression': {Dest.posthog},
  'map_leave_prompt_update': {Dest.posthog},
  'map_leave_prompt_keep': {Dest.posthog},
  'map_leave_prompt_dismiss': {Dest.posthog},
  'map_leave_prompt_renavigate_after_keep': {Dest.posthog},

  // PROD-3219: was MISSING from the registry, so every `map_filter_change`
  // (source/type/date since PROD-2671, and now shortcut/reset) was silently
  // dropped by `_dispatch` — which is why the event never showed up in PostHog.
  'map_filter_change': {Dest.posthog},

  // ============ FILTERS & LIBRARY TABS (PROD-3209) ============
  // The Map surface keeps map_filter_change (live dashboards); these cover
  // the Discovery filter bars + the Library category tabs.
  'filter_applied': {Dest.posthog},
  'filters_reset': {Dest.posthog},
  'library_tab_change': {Dest.posthog},

  // ============ ZINE BROWSING + PERF (PROD-3209 / PROD-3211) ============
  'zine_page_view': {Dest.posthog},
  'zine_view_mode_change': {Dest.posthog},
  'screen_load_complete': {Dest.posthog},

  // ============ PROFILE EDITING + FEEDBACK (PROD-3211) ============
  'profile_updated': {Dest.posthog},
  'profile_photo_added': {Dest.posthog},
  'profile_privacy_change': {Dest.posthog},
  'feedback_open': {Dest.posthog},
  'feedback_submit': {Dest.posthog},

  // ============ MEMORY SURFACES (PROD-3211) ============
  'memory_open': {Dest.posthog},
  'memory_row_tap': {Dest.posthog},
  'memory_signal_adjust': {Dest.posthog},
  'memory_delete': {Dest.posthog},
  'memory_category_clear': {Dest.posthog},
  'memory_freetext_submit': {Dest.posthog},
  'memory_freetext_rejected': {Dest.posthog},

  // ============ NEGATIVE SIGNALS + REMINDERS + PUSH (PROD-3209/3210) ====
  // chat_card_dismissed also goes to the backend: it's recommender
  // training data, not just analytics (422-swallowed until registered).
  'chat_card_dismissed': {Dest.backend, Dest.posthog},
  'reminder_set': {Dest.posthog},
  'reminder_cancelled': {Dest.posthog},
  'push_prompt_shown': {Dest.posthog},
  'people_suggestion_dismissed': {Dest.posthog},

  // ============ NOTIFICATIONS (PROD-2511) ============
  // Inbox / push / reminders sheet lifecycle + per-channel and per-category
  // preference changes. Dispatched through `BackendDestination.trackGeneric`
  // (POST /api/v1/app/analytics/track) — backend ignores unknown event
  // names silently (fire-and-forget catches the 422), so PostHog still
  // gets the event even before heyl-backend registers these names.
  'notification_inbox_open': {Dest.backend, Dest.posthog},
  'notification_inbox_tab_change': {Dest.backend, Dest.posthog},
  'notification_click': {Dest.backend, Dest.posthog},
  'notification_dismiss': {Dest.backend, Dest.posthog},
  'notification_mark_all_read': {Dest.backend, Dest.posthog},
  'notification_push_tap': {Dest.backend, Dest.posthog},
  'notification_received': {Dest.backend, Dest.posthog},
  'my_reminders_open': {Dest.backend, Dest.posthog},
  'my_reminders_event_click': {Dest.backend, Dest.posthog},
  'notification_preferences_change': {Dest.backend, Dest.posthog},
  'marketing_preferences_change': {Dest.backend, Dest.posthog},

  // ============ SOCIAL GRAPH ============
  // The follow graph had ZERO instrumentation before this block — no follow,
  // no profile view, no people search. These answer the only two questions
  // that matter for the social pilot: does the graph form, and does it bring
  // people back?
  //
  // PostHog-only for v1, matching the precedent above (`content_blocked`,
  // `push_permission`, the map events): the generic backend
  // `/app/analytics/track` rejects event names absent from its server-side
  // registry with 422. Promote to {Dest.backend, Dest.posthog} once
  // heyl-backend registers these names.
  //
  // `user_follow`/`user_unfollow` mirror the existing `list_follow`/
  // `list_unfollow` pair rather than collapsing into one event with an
  // `action` property — consistency with the zine follow graph wins, and it
  // keeps the two graphs directly comparable in PostHog.
  //
  // NOTE: `is_soko` is not optional on the follow events. The @soko
  // mutual-follow edge is created server-side for every user, so any follower
  // metric that doesn't exclude it is inflated by a number that has nothing to
  // do with real social behaviour.
  //
  // The property is named `is_soko`, not `target_is_official`, because
  // `listAnalyticsProps` already emits exactly this (`ownerHandle ==
  // EnvironmentConfig.sokoHandle`) on the four list events, and PROD-3035 made
  // it a vocabulary shared with the backend notification events and Klaviyo.
  // One concept, one name — see the contract v6.3.0 changelog.
  'user_follow': {Dest.posthog, Dest.appsflyer},
  'user_unfollow': {Dest.posthog},
  'profile_open': {Dest.posthog},
  'follow_request_action': {Dest.posthog},

  // ============ PEOPLE DISCOVERY ============
  // Does discovery actually produce follows? Suggestion/contact-row taps are
  // already covered by `user_follow` with `source: suggestions|contact_match`,
  // so these cover only the top of the funnel (searched / saw / synced).
  'people_search': {Dest.posthog},
  'suggested_users_viewed': {Dest.posthog},
  'contact_sync': {Dest.posthog},

  // Invite is the top of the growth funnel (existing user -> new signup) and
  // was the only social action with no event at all. Fires when the system
  // share sheet is opened from any of the three invite surfaces
  // (contact_match | find_people | profile_share).
  'invite_shared': {Dest.posthog},

  // ============ CONTRIBUTIONS + UNSUPPORTED CITY ============
  // PROD-2404 photo->event contribution + unsupported-city impressions.
  // These five were dispatched but missing from this registry entirely, so
  // _dispatch silently dropped them — they never reached ANY destination
  // (0 events in PostHog, all time) until catalogued in contract v7.0.0.
  // PostHog-only: backend registration pending (server 422 gate).
  'photo_contribution_open': {Dest.posthog},
  // Renamed from photo_contribution_submit (PROD-3208) — the community-
  // supply act. The photo_contribution_open/success/failure pipeline
  // siblings keep their names.
  'event_suggested': {Dest.posthog},
  'photo_contribution_success': {Dest.posthog},
  'photo_contribution_failure': {Dest.posthog},
  'unsupported_city_impression': {Dest.posthog},
};

/// Events whose contract `level` is `system` — fired by the app/SDK without a
/// direct human action (impressions, fallbacks, diagnostics, experiment
/// exposure). `_dispatch` stamps these `actor: system`, everything else
/// `actor: user` (tracking-spec PROD-3205 §1.3 — system events must never
/// count as user activity).
///
/// KEEP IN SYNC with analytics-contract.json (`level == "system"`) — enforced
/// by check-analytics-contract.py Check 6; CI fails on drift.
const Set<String> kSystemActorEvents = {
  'research_invitation_viewed',
  'content_blocked',
  'deep_link.short_link_resolve_failed',
  'deep_link.short_link_resolved',
  'discovery_shelf_viewed',
  'experiment_exposure',
  'feed_exposed',
  'feed_variant_committed',
  'item_impression',
  'location_accuracy_status',
  'location_ip_fallback_used',
  'location_ip_unresolved',
  'location_shared',
  'location_suggestion',
  'map_leave_prompt_impression',
  'message_sent_soko',
  'notification_received',
  'photo_contribution_failure',
  'photo_contribution_success',
  'screen_load_complete',
  'suggested_users_viewed',
  'unsupported_city_impression',
};
