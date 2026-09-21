import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/attribution_service.dart';
import '../../../core/services/storage_service.dart';
import '../../../data/models/feature_spotlight.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../product_tour/models/tour_step.dart';
import '../../product_tour/providers/product_tour_controller.dart';
import '../services/spotlight_persistence.dart';
import '../spotlight_registry.dart';

/// Immutable snapshot of the current user's spotlight state.
@immutable
class FeatureSpotlightState {
  const FeatureSpotlightState({
    required this.seen,
    required this.disabled,
    required this.hydrated,
    this.activeFeatureId,
  });

  /// Feature ids the user has already dismissed / CTA-tapped locally or
  /// per the server. Never re-show these to this user.
  final Set<String> seen;

  /// Feature ids globally killed by ops via the backoffice. Never show
  /// these to anyone until the backoffice re-enables them. Server is
  /// authoritative; the client caches the last known set locally
  /// (`SpotlightPersistence.readDisabled`) so cold-start eligibility
  /// decisions don't run against an empty set before the network
  /// round-trip completes — otherwise the pre-fire delay in
  /// `SpotlightTrigger` would race the microtask sync.
  final Set<String> disabled;

  /// True once the local cache has been read. Widgets defer their
  /// "should show" decision until this flips true to avoid flashing a
  /// spotlight and then hiding it on the next frame.
  final bool hydrated;

  /// The single feature id currently claiming the on-screen spotlight,
  /// or null when none is active. Enforces the "one spotlight at a time"
  /// invariant so surfaces with multiple eligible spotlights (e.g. event
  /// detail's bell + IG-share pair) don't stack overlays on top of one
  /// another.
  final String? activeFeatureId;

  /// Everything to suppress — union of seen + disabled.
  Set<String> get suppressed => {...seen, ...disabled};

  FeatureSpotlightState copyWith({
    Set<String>? seen,
    Set<String>? disabled,
    bool? hydrated,
    Object? activeFeatureId = _sentinel,
  }) {
    return FeatureSpotlightState(
      seen: seen ?? this.seen,
      disabled: disabled ?? this.disabled,
      hydrated: hydrated ?? this.hydrated,
      activeFeatureId: identical(activeFeatureId, _sentinel)
          ? this.activeFeatureId
          : activeFeatureId as String?,
    );
  }

  static const empty = FeatureSpotlightState(
    seen: {},
    disabled: {},
    hydrated: false,
  );
}

/// Sentinel used by [FeatureSpotlightState.copyWith] to distinguish
/// "not passed" from "explicitly nulled" for the nullable
/// [FeatureSpotlightState.activeFeatureId] field.
const Object _sentinel = Object();

final spotlightPersistenceProvider = Provider<SpotlightPersistence>((ref) {
  final prefs = ref.watch(sharedPreferencesProvider);
  return SpotlightPersistence(prefs);
});

/// Read-through cache backing every `SpotlightTrigger` in the app.
///
/// Lifecycle:
///   * On first watch: hydrate from [SpotlightPersistence] (sync) then
///     fire `api.fetchState()` (async, tolerates 404).
///   * On auth user id change: invalidate self so the new user's state
///     loads.
///   * `shouldShow(id)` is a pure read against the state — returns false
///     if the feature id is in `seen` or `disabled`, or the product tour
///     is running (we don't stack overlays inside the same `ShowCaseWidget`
///     ancestor).
///   * `markSeen(id, reason)` writes optimistically to local + fire-and-
///     forget POST. Failures leave the local flag in place; the next
///     successful server fetch reconciles.
final featureSpotlightServiceProvider =
    NotifierProvider<FeatureSpotlightNotifier, FeatureSpotlightState>(
      FeatureSpotlightNotifier.new,
    );

class FeatureSpotlightNotifier extends Notifier<FeatureSpotlightState> {
  @override
  FeatureSpotlightState build() {
    ref.listen<String?>(authStateProvider.select((s) => s.user?.id), (
      previous,
      next,
    ) {
      if (previous != next) ref.invalidateSelf();
    });

    final userKey = _userKey();
    if (userKey == null) return FeatureSpotlightState.empty;

    final persistence = ref.read(spotlightPersistenceProvider);
    final initial = FeatureSpotlightState(
      seen: persistence.readSeen(userKey),
      // Cached from the last successful server sync so the trigger's
      // pre-fire eligibility check doesn't race the microtask below.
      // Server sync will overwrite this on success.
      disabled: persistence.readDisabled(userKey),
      hydrated: true,
    );

    // Fire-and-forget server sync — union results into state on success.
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
    final auth = ref.read(authStateProvider);
    if (auth.isGuest) return; // guests never hit the backend for this
    try {
      final api = ref.read(featureSpotlightsApiProvider);
      final serverState = await api.fetchState();
      if (!_stillCurrent(userKey)) return;
      final mergedSeen = {...state.seen, ...serverState.seen};
      final needsSeenWrite = mergedSeen.length != state.seen.length;
      final disabledChanged = !_setEquals(state.disabled, serverState.disabled);
      if (!needsSeenWrite && !disabledChanged) return;
      state = state.copyWith(seen: mergedSeen, disabled: serverState.disabled);
      final persistence = ref.read(spotlightPersistenceProvider);
      if (needsSeenWrite) {
        await persistence.writeSeen(userKey, mergedSeen);
      }
      if (disabledChanged) {
        await persistence.writeDisabled(userKey, serverState.disabled);
      }
    } catch (_) {
      // Silent — local cache still drives shouldShow.
    }
  }

  bool _stillCurrent(String userKey) => _userKey() == userKey;

  static bool _setEquals(Set<String> a, Set<String> b) {
    if (a.length != b.length) return false;
    for (final v in a) {
      if (!b.contains(v)) return false;
    }
    return true;
  }

  /// True when the caller should mount its spotlight for [featureId].
  ///
  /// False when: the id isn't in the registry, hydration hasn't landed
  /// yet, the id is in `seen` or `disabled`, another spotlight is
  /// already active, or the product tour is running.
  bool shouldShow(String featureId) {
    if (!state.hydrated) return false;
    if (!kFeatureSpotlights.containsKey(featureId)) return false;
    if (state.suppressed.contains(featureId)) return false;
    final active = state.activeFeatureId;
    if (active != null && active != featureId) return false;
    final tourStep = ref.read(productTourControllerProvider).step;
    if (tourStep != TourStep.idle && tourStep != TourStep.done) return false;
    return true;
  }

  /// Atomically reserve the single "active spotlight" slot for
  /// [featureId]. Returns true when the reservation succeeds (slot was
  /// free or already held by this id); false when another spotlight is
  /// already displayed.
  ///
  /// Callers MUST pair every successful reservation with either
  /// [markSeen] (natural dismissal / CTA path) or [release] (screen
  /// navigation-away without user action) so the slot doesn't leak.
  bool tryReserve(String featureId) {
    final active = state.activeFeatureId;
    if (active != null && active != featureId) return false;
    if (active == featureId) return true;
    state = state.copyWith(activeFeatureId: featureId);
    return true;
  }

  /// Release the active-spotlight slot if it's currently held by
  /// [featureId]. No-op otherwise.
  void release(String featureId) {
    if (state.activeFeatureId == featureId) {
      state = state.copyWith(activeFeatureId: null);
    }
  }

  /// Optimistically mark [featureId] as seen locally, then POST to the
  /// backend. Idempotent — safe to call multiple times. Also releases
  /// the active-spotlight slot if it was held by this id.
  Future<void> markSeen(
    String featureId,
    FeatureSpotlightSeenReason reason,
  ) async {
    final wasActive = state.activeFeatureId == featureId;
    if (state.seen.contains(featureId)) {
      if (wasActive) state = state.copyWith(activeFeatureId: null);
      return;
    }

    final userKey = _userKey();
    final newSeen = {...state.seen, featureId};
    state = state.copyWith(
      seen: newSeen,
      activeFeatureId: wasActive ? null : state.activeFeatureId,
    );

    if (userKey != null) {
      try {
        await ref
            .read(spotlightPersistenceProvider)
            .addSeen(userKey, featureId);
      } catch (_) {
        // Local storage failure is non-fatal — state above already holds it.
      }
    }

    final auth = ref.read(authStateProvider);
    if (auth.isGuest) return;
    try {
      final api = ref.read(featureSpotlightsApiProvider);
      await api.markSeen(featureId, reason: reason);
    } catch (_) {
      // Fire-and-forget — next _syncFromServer will reconcile once the
      // endpoint is reachable.
    }
  }
}
