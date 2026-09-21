import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/attribution_service.dart';
import '../../../core/services/storage_service.dart';
import '../../../providers/auth_provider.dart';
import '../guest_limits.dart';

/// Snapshot of how much of the guest chat allowance has been consumed.
///
/// `sessionId` is null until the guest creates their one allowed session.
/// `messageCount` is the number of successful user-initiated sends in that
/// session.
@immutable
class GuestQuotaState {
  final String? sessionId;
  final int messageCount;

  const GuestQuotaState({this.sessionId, this.messageCount = 0});

  bool get hasSession => sessionId != null;

  /// True once the guest has used up their per-session send allowance.
  bool get isAtMessageCap => messageCount >= kMaxGuestMessagesPerSession;

  /// True once the guest has already created their one allowed session AND
  /// is trying to create a *different* one. Callers should redirect to
  /// `sessionId` instead of creating fresh.
  bool canCreateSession(String? attemptedSessionId) {
    if (sessionId == null) return true;
    return attemptedSessionId == sessionId;
  }

  GuestQuotaState copyWith({Object? sessionId = _sentinel, int? messageCount}) {
    return GuestQuotaState(
      sessionId: identical(sessionId, _sentinel)
          ? this.sessionId
          : sessionId as String?,
      messageCount: messageCount ?? this.messageCount,
    );
  }

  static const Object _sentinel = Object();
}

/// Tracks the guest chat quota: how many sessions and how many messages
/// they've used. Persists per-visitor in SharedPreferences so a reload
/// doesn't reset the counter. Authenticated users do not consult this
/// notifier — the chat-send gate short-circuits for real users.
///
/// The notifier loads its state lazily on first access via [hydrate]; the
/// chat screen calls `hydrate()` before consulting state so the very first
/// guest send after a cold start sees the persisted count rather than
/// zero. Subsequent calls are no-ops.
class GuestQuotaNotifier extends StateNotifier<GuestQuotaState> {
  final StorageService _storage;
  final AttributionService _attribution;
  bool _hydrated = false;

  GuestQuotaNotifier(this._storage, this._attribution)
    : super(const GuestQuotaState());

  /// Read persisted state and reconcile with the current visitor_id. If the
  /// stored visitor_id differs from the current one (e.g. user wiped storage
  /// or the secure-storage visitor row got regenerated), start fresh.
  Future<void> hydrate() async {
    if (_hydrated) return;
    _hydrated = true;
    final visitorId = await _attribution.getVisitorId();
    final storedVisitorId = _storage.getGuestQuotaVisitorId();
    if (storedVisitorId != visitorId) {
      // Visitor identity changed — drop stale counters.
      await _storage.clearGuestQuota();
      state = const GuestQuotaState();
      return;
    }
    state = GuestQuotaState(
      sessionId: _storage.getGuestQuotaSessionId(),
      messageCount: _storage.getGuestQuotaMessageCount(),
    );
  }

  /// Record that the guest just created their session. No-op if the same
  /// sessionId is already recorded.
  Future<void> recordSessionCreated(String sessionId) async {
    if (state.sessionId == sessionId) return;
    final visitorId = await _attribution.getVisitorId();
    state = state.copyWith(sessionId: sessionId);
    await _storage.saveGuestQuota(
      visitorId: visitorId,
      sessionId: sessionId,
      messageCount: state.messageCount,
    );
  }

  /// Increment the per-session message counter. Called from the chat
  /// provider's success path so failed sends don't burn a slot.
  Future<void> incrementMessageCount() async {
    final visitorId = await _attribution.getVisitorId();
    state = state.copyWith(messageCount: state.messageCount + 1);
    await _storage.saveGuestQuota(
      visitorId: visitorId,
      sessionId: state.sessionId,
      messageCount: state.messageCount,
    );
  }

  /// Wipe the quota. Called when a guest signs in or signs up so the new
  /// real-user state isn't polluted by stale guest counters.
  Future<void> clear() async {
    state = const GuestQuotaState();
    await _storage.clearGuestQuota();
  }
}

final guestQuotaProvider =
    StateNotifierProvider<GuestQuotaNotifier, GuestQuotaState>((ref) {
      final storage = ref.watch(storageServiceProvider);
      final attribution = ref.watch(attributionServiceProvider);
      final notifier = GuestQuotaNotifier(storage, attribution);
      // Wipe the quota whenever a guest signs in or signs up. Listening on the
      // auth flip keeps the quota module self-contained — auth code stays
      // ignorant of guest counters.
      ref.listen<bool>(isAuthenticatedProvider, (previous, next) {
        if (previous == false && next == true) {
          // ignore: discarded_futures
          notifier.clear();
        }
      });
      return notifier;
    });
