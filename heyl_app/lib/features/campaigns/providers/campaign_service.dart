import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/attribution_service.dart';
import '../../../core/services/storage_service.dart';
import '../../../data/models/campaign.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import '../services/campaign_persistence.dart';

/// Immutable snapshot of the current user's fake-door-campaign state.
@immutable
class CampaignState {
  const CampaignState({
    required this.activeCampaigns,
    required this.responded,
    required this.hydrated,
    this.activeCampaignKey,
    this.warmupEnabled = true,
  });

  /// Campaigns the backend currently considers eligible for this user.
  /// `GET /campaigns/active` is expected to already exclude campaigns the
  /// user has responded to / that are no longer live — [responded] is a
  /// client-side overlay that closes the gap between "just responded" and
  /// the next successful re-fetch.
  final List<Campaign> activeCampaigns;

  /// Campaign keys this user has responded to (submitted or dismissed)
  /// locally or per the server. Never re-show these to this user.
  final Set<String> responded;

  /// True once the local cache has been read. Callers defer their
  /// "should show" decision until this flips true to avoid flashing a
  /// campaign and then hiding it on the next frame.
  final bool hydrated;

  /// The single campaign key currently claiming the on-screen slot, or
  /// null when none is active. Enforces the "one campaign at a time"
  /// invariant.
  final String? activeCampaignKey;

  /// Admin toggle (persisted, global) for the Discovery warm-up
  /// auto-surfacing. When false, `_CampaignWarmupTrigger` never fires — the
  /// deep-link route and the admin test box still work. Defaults true.
  final bool warmupEnabled;

  CampaignState copyWith({
    List<Campaign>? activeCampaigns,
    Set<String>? responded,
    bool? hydrated,
    Object? activeCampaignKey = _sentinel,
    bool? warmupEnabled,
  }) {
    return CampaignState(
      activeCampaigns: activeCampaigns ?? this.activeCampaigns,
      responded: responded ?? this.responded,
      hydrated: hydrated ?? this.hydrated,
      activeCampaignKey: identical(activeCampaignKey, _sentinel)
          ? this.activeCampaignKey
          : activeCampaignKey as String?,
      warmupEnabled: warmupEnabled ?? this.warmupEnabled,
    );
  }

  static const empty = CampaignState(
    activeCampaigns: [],
    responded: {},
    hydrated: false,
  );
}

/// Sentinel used by [CampaignState.copyWith] to distinguish "not passed"
/// from "explicitly nulled" for the nullable
/// [CampaignState.activeCampaignKey] field.
const Object _sentinel = Object();

final campaignPersistenceProvider = Provider<CampaignPersistence>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return CampaignPersistence(prefs);
});

/// Read-through cache + gating logic for fake-door campaigns.
///
/// Clone of `FeatureSpotlightNotifier` (PROD-2808) adapted for
/// backend-authored campaign content:
///   * On first watch: hydrate the local `responded` cache (sync) then
///     fire `api.getActiveCampaigns()` (async, tolerates 404).
///   * On auth user id change: invalidate self so the new user's state
///     loads.
///   * `shouldShow(key)` is a pure read against the state.
///   * `markResponded(key)` writes optimistically to local storage. The
///     actual response record (choice / selected options / free text) is
///     POSTed by the campaign screen itself via `campaignApiProvider`
///     (`ICampaignApi.submitCampaignResponse`) — this notifier only owns
///     client-side "don't show again" gating, not the durable response.
final campaignServiceProvider =
    NotifierProvider<CampaignNotifier, CampaignState>(CampaignNotifier.new);

class CampaignNotifier extends Notifier<CampaignState> {
  @override
  CampaignState build() {
    ref.listen<String?>(authStateProvider.select((s) => s.user?.id), (
      previous,
      next,
    ) {
      if (previous != next) ref.invalidateSelf();
    });

    final userKey = _userKey();
    if (userKey == null) return CampaignState.empty;

    final persistence = ref.read(campaignPersistenceProvider);
    final initial = CampaignState(
      activeCampaigns: const [],
      responded: persistence.readResponded(userKey),
      hydrated: true,
      warmupEnabled: persistence.readWarmupEnabled(),
    );

    // Fire-and-forget server sync — replaces activeCampaigns on success.
    Future.microtask(() => _syncFromServer(userKey));

    return initial;
  }

  /// Returns the storage bucket key for the current user. Authed users
  /// use their profile id; explicit guests fall back to the visitor id so
  /// dismissals stick within the browser. Returns null while auth is
  /// still resolving.
  String? _userKey() {
    final auth = ref.read(authStateProvider);
    final userId = auth.user?.id;
    if (userId != null && userId.isNotEmpty) return userId;
    if (auth.isGuest) {
      final visitorId = ref.read(attributionServiceProvider).cachedVisitorId;
      if (visitorId != null && visitorId.isNotEmpty) return 'guest:$visitorId';
    }
    return null;
  }

  Future<void> _syncFromServer(String userKey) async {
    try {
      final api = ref.read(campaignApiProvider);
      final campaigns = await api.getActiveCampaigns();
      if (!_stillCurrent(userKey)) return;
      state = state.copyWith(activeCampaigns: campaigns);
    } catch (_) {
      // Silent — local state still drives shouldShow (as "nothing active").
    }
  }

  bool _stillCurrent(String userKey) => _userKey() == userKey;

  /// True when the caller should mount [campaignKey]'s flow.
  ///
  /// False when: hydration hasn't landed yet, the campaign isn't in the
  /// current active set, the key is in `responded`, or another campaign
  /// already holds the single on-screen slot.
  bool shouldShow(String campaignKey) {
    if (!state.hydrated) return false;
    if (!state.activeCampaigns.any((c) => c.key == campaignKey)) return false;
    if (state.responded.contains(campaignKey)) return false;
    final active = state.activeCampaignKey;
    if (active != null && active != campaignKey) return false;
    return true;
  }

  /// The first active, not-yet-responded campaign, or null. Callers use
  /// this to decide which single campaign (if any) to surface on a given
  /// screen without hand-rolling the "one at a time" scan themselves.
  Campaign? nextEligibleCampaign() {
    if (!state.hydrated) return null;
    for (final campaign in state.activeCampaigns) {
      if (shouldShow(campaign.key)) return campaign;
    }
    return null;
  }

  /// Atomically reserve the single "active campaign" slot for
  /// [campaignKey]. Returns true when the reservation succeeds (slot was
  /// free or already held by this key); false when another campaign is
  /// already displayed.
  ///
  /// Callers MUST pair every successful reservation with either
  /// [markResponded] or [release] so the slot doesn't leak.
  bool tryReserve(String campaignKey) {
    final active = state.activeCampaignKey;
    if (active != null && active != campaignKey) return false;
    if (active == campaignKey) return true;
    state = state.copyWith(activeCampaignKey: campaignKey);
    return true;
  }

  /// Release the active-campaign slot if it's currently held by
  /// [campaignKey]. No-op otherwise.
  void release(String campaignKey) {
    if (state.activeCampaignKey == campaignKey) {
      state = state.copyWith(activeCampaignKey: null);
    }
  }

  /// Optimistically mark [campaignKey] as responded-to locally so it never
  /// re-shows this session (or on relaunch, once persisted). Idempotent —
  /// safe to call multiple times. Also releases the active-campaign slot
  /// if it was held by this key.
  ///
  /// Does NOT talk to the backend — the caller is responsible for posting
  /// the durable response record via `ICampaignApi.submitCampaignResponse`
  /// before (or independently of) calling this.
  Future<void> markResponded(String campaignKey) async {
    final wasActive = state.activeCampaignKey == campaignKey;
    if (state.responded.contains(campaignKey)) {
      if (wasActive) state = state.copyWith(activeCampaignKey: null);
      return;
    }

    final userKey = _userKey();
    final newResponded = {...state.responded, campaignKey};
    state = state.copyWith(
      responded: newResponded,
      activeCampaignKey: wasActive ? null : state.activeCampaignKey,
    );

    if (userKey == null) return;
    try {
      await ref
          .read(campaignPersistenceProvider)
          .addResponded(userKey, campaignKey);
    } catch (_) {
      // Local storage failure is non-fatal — state above already holds it.
    }
  }

  /// Admin toggle: enable/disable the Discovery warm-up auto-surfacing.
  /// Persisted globally so it survives relaunch. Does not touch the
  /// responded set or the active slot — only whether the warm-up fires.
  Future<void> setWarmupEnabled(bool enabled) async {
    if (state.warmupEnabled == enabled) return;
    state = state.copyWith(warmupEnabled: enabled);
    try {
      await ref.read(campaignPersistenceProvider).writeWarmupEnabled(enabled);
    } catch (_) {
      // Local storage failure is non-fatal — state above already holds it.
    }
  }
}
