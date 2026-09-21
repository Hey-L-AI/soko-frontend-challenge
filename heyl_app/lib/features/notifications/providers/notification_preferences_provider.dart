import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/notification_item.dart';
import '../../../data/models/notification_preferences.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';

/// PROD-2526 T-L — per-category notification opt-in state.
class NotificationPreferencesState {
  final NotificationPreferences preferences;
  final bool isLoading;
  final bool isSaving;
  final bool hasLoadedOnce;
  final Object? error;

  const NotificationPreferencesState({
    this.preferences = NotificationPreferences.allEnabled,
    this.isLoading = false,
    this.isSaving = false,
    this.hasLoadedOnce = false,
    this.error,
  });

  NotificationPreferencesState copyWith({
    NotificationPreferences? preferences,
    bool? isLoading,
    bool? isSaving,
    bool? hasLoadedOnce,
    Object? error,
    bool clearError = false,
  }) {
    return NotificationPreferencesState(
      preferences: preferences ?? this.preferences,
      isLoading: isLoading ?? this.isLoading,
      isSaving: isSaving ?? this.isSaving,
      hasLoadedOnce: hasLoadedOnce ?? this.hasLoadedOnce,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class NotificationPreferencesNotifier
    extends Notifier<NotificationPreferencesState> {
  @override
  NotificationPreferencesState build() {
    ref.listen<bool>(authStateProvider.select((s) => s.isAuthenticated), (
      prev,
      next,
    ) {
      if (next && prev != true) {
        // ignore: unawaited_futures
        refresh();
      }
    });
    // Cold-start path — same gap fixed on the sibling unread-count notifier
    // (PROD-2511 follow-up). `ref.listen` on `isAuthenticated` only fires on
    // transitions; a user already authed at app launch never produces a
    // `false → true` flip, so the listener stays silent and the notifier
    // never refreshes until something else mounts the preferences screen.
    // Eager microtask refresh when the current state is already authed
    // closes the gap. See:
    // docs/learnings/riverpod-listen-skips-cold-start-when-state-never-transitions.md
    if (ref.read(authStateProvider).isAuthenticated) {
      Future.microtask(refresh);
    }
    return const NotificationPreferencesState();
  }

  Future<void> refresh() async {
    if (state.isLoading) return;
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final prefs = await ref.read(notificationsApiProvider).getPreferences();
      state = state.copyWith(
        preferences: prefs,
        isLoading: false,
        hasLoadedOnce: true,
      );
    } catch (e, st) {
      debugPrint('[NotificationPreferences] refresh failed: $e\n$st');
      state = state.copyWith(isLoading: false, hasLoadedOnce: true, error: e);
    }
  }

  /// Optimistic category-wide toggle. PATCH on failure reverts the
  /// local flip.
  ///
  /// Most categories PATCH the nested `{category.wireName: {enabled: v}}`
  /// shape (PROD-2510 hierarchical preferences). When the category has
  /// registered sub-types (e.g. `discovery` → `weekly_bundle_ready` +
  /// `daily_drop_ready`) the same PATCH also force-syncs every sub-type
  /// to the new value: `{category: {enabled: v, types: {t1: v, t2: v}}}`.
  /// Without this the per-type override wins server-side, so a user who
  /// had previously turned a sub-type ON would keep receiving it even
  /// after toggling the category OFF.
  ///
  /// [NotificationCategory.marketing] is special-cased to the flat
  /// `{marketing: {push: value}}` shape — it predates the hierarchy
  /// and ships as a single channel toggle.
  Future<bool> toggle(NotificationCategory category, bool value) async {
    final original = state.preferences;
    final subTypes = _subTypesToSync(original, category);
    final optimistic = _applyCategoryToggle(
      original,
      category,
      value,
      subTypes,
    );
    state = state.copyWith(
      preferences: optimistic,
      isSaving: true,
      clearError: true,
    );
    try {
      final body = _buildCategoryToggleBody(category, value, subTypes);
      final updated = await ref
          .read(notificationsApiProvider)
          .updatePreferences(body);
      state = state.copyWith(preferences: updated, isSaving: false);
      return true;
    } catch (e, st) {
      debugPrint('[NotificationPreferences] toggle failed: $e\n$st');
      state = state.copyWith(preferences: original, isSaving: false, error: e);
      return false;
    }
  }

  /// Optimistic per-type toggle within a category. Writes a per-type
  /// override row on the server and also derives the category-wide
  /// `enabled` flag from the union of known sub-types — the master row
  /// IS the logical OR of its children. So toggling the last enabled
  /// child off auto-flips the master to off (and toggling any child on
  /// while the master is off auto-flips it on); without this, the
  /// master would visually stay on while every child is off.
  ///
  /// Passing `value = null` would clear the override on the server,
  /// but the UI surfaces a simple bool toggle so the notifier always
  /// writes an explicit bool.
  Future<bool> toggleType(
    NotificationCategory category,
    String type,
    bool value,
  ) async {
    if (category == NotificationCategory.marketing ||
        category == NotificationCategory.unknown) {
      return false;
    }
    final original = state.preferences;
    final originalCategory = original.categoryFor(category);

    final newTypes = Map<String, bool>.from(originalCategory.types);
    newTypes[type] = value;
    final newEnabled = _deriveCategoryEnabled(
      original,
      category,
      newTypes,
      originalCategory.enabled,
    );

    final updatedCategory = CategoryPreference(
      enabled: newEnabled,
      types: Map.unmodifiable(newTypes),
    );
    final optimistic = _replaceCategory(original, category, updatedCategory);
    state = state.copyWith(
      preferences: optimistic,
      isSaving: true,
      clearError: true,
    );
    try {
      // Always send `enabled` alongside the per-type override so the
      // backend's effective state matches the FE optimistic view. The
      // master is the logical OR of known children — if `enabled` is
      // unchanged this is idempotent.
      final body = <String, dynamic>{
        category.wireName: <String, dynamic>{
          'enabled': newEnabled,
          'types': <String, dynamic>{type: value},
        },
      };
      final updated = await ref
          .read(notificationsApiProvider)
          .updatePreferences(body);
      state = state.copyWith(preferences: updated, isSaving: false);
      return true;
    } catch (e, st) {
      debugPrint('[NotificationPreferences] toggleType failed: $e\n$st');
      state = state.copyWith(preferences: original, isSaving: false, error: e);
      return false;
    }
  }

  static NotificationPreferences _applyCategoryToggle(
    NotificationPreferences prefs,
    NotificationCategory category,
    bool value,
    List<String> subTypes,
  ) {
    if (category == NotificationCategory.marketing) {
      return prefs.copyWith(marketing: prefs.marketing.copyWith(push: value));
    }
    if (category == NotificationCategory.unknown) return prefs;
    final existing = prefs.categoryFor(category);
    final mergedTypes = <String, bool>{...existing.types};
    for (final type in subTypes) {
      mergedTypes[type] = value;
    }
    final updated = existing.copyWith(
      enabled: value,
      types: Map.unmodifiable(mergedTypes),
    );
    return _replaceCategory(prefs, category, updated);
  }

  /// Sub-types to force-sync alongside a category-wide toggle. Prefers
  /// the server-resolved key set on `CategoryPreference.types` (the
  /// backend's TemplateSpec registry, fetched on the last `refresh()`)
  /// and falls back to a local mirror if the server's set is empty —
  /// covers the cold-start race where the user toggles before the
  /// first refresh lands.
  static List<String> _subTypesToSync(
    NotificationPreferences prefs,
    NotificationCategory category,
  ) {
    if (category == NotificationCategory.marketing ||
        category == NotificationCategory.unknown) {
      return const [];
    }
    final serverKnown = prefs.categoryFor(category).types.keys.toList();
    if (serverKnown.isNotEmpty) return serverKnown;
    return _localKnownSubTypes[category] ?? const [];
  }

  static Map<String, dynamic> _buildCategoryToggleBody(
    NotificationCategory category,
    bool value,
    List<String> subTypes,
  ) {
    if (category == NotificationCategory.marketing) {
      return <String, dynamic>{
        'marketing': <String, dynamic>{'push': value},
      };
    }
    final categoryBody = <String, dynamic>{'enabled': value};
    if (subTypes.isNotEmpty) {
      categoryBody['types'] = <String, dynamic>{
        for (final type in subTypes) type: value,
      };
    }
    return <String, dynamic>{category.wireName: categoryBody};
  }

  /// Local mirror of the server's per-category type registry. Must stay
  /// in sync with `_subTypeRowsFor` in
  /// `notification_categories_section.dart` — both lists declare the
  /// same client-visible per-category type set. Only consulted as a
  /// cold-start fallback; the server's response is authoritative once
  /// the first refresh lands.
  static const Map<NotificationCategory, List<String>> _localKnownSubTypes = {
    NotificationCategory.discovery: <String>[
      'weekly_bundle_ready',
      'daily_drop_ready',
    ],
    // PROD-3081 Phase A + PROD-3082/3083 Phase B/C — social sub-types
    // (mirror of the server's TemplateSpec registry: follow graph, zines,
    // and the memory-bio nudge). Cold-start fallback only; the server
    // response is authoritative once the first refresh lands.
    NotificationCategory.social: <String>[
      'follow_request',
      'new_follower',
      'follow_request_accepted',
      'followed_back',
      'zine_followed',
      'zine_item_added',
      'saved_added_to_zine',
      'memory_bio_ready',
    ],
  };

  /// Derives the category-wide `enabled` flag from the resolved state
  /// of every known sub-type after a per-type toggle: master = OR of
  /// children. Missing-from-`newTypes` means the child still inherits
  /// from the category's previous `enabled` value (`fallbackEnabled`)
  /// — same resolution rule the backend applies. When the category
  /// has no known sub-types at all, the master can't be derived from
  /// children, so we leave it on `fallbackEnabled`.
  static bool _deriveCategoryEnabled(
    NotificationPreferences prefs,
    NotificationCategory category,
    Map<String, bool> newTypes,
    bool fallbackEnabled,
  ) {
    final known = _subTypesToSync(prefs, category).toSet()
      ..addAll(newTypes.keys);
    if (known.isEmpty) return fallbackEnabled;
    return known.any((t) => newTypes[t] ?? fallbackEnabled);
  }

  static NotificationPreferences _replaceCategory(
    NotificationPreferences prefs,
    NotificationCategory category,
    CategoryPreference value,
  ) {
    switch (category) {
      case NotificationCategory.reminders:
        return prefs.copyWith(reminders: value);
      case NotificationCategory.asyncJobs:
        return prefs.copyWith(asyncJobs: value);
      case NotificationCategory.chat:
        return prefs.copyWith(chat: value);
      case NotificationCategory.social:
        return prefs.copyWith(social: value);
      case NotificationCategory.discovery:
        return prefs.copyWith(discovery: value);
      case NotificationCategory.feedback:
        return prefs.copyWith(feedback: value);
      case NotificationCategory.marketing:
      case NotificationCategory.unknown:
        return prefs;
    }
  }
}

final notificationPreferencesProvider =
    NotifierProvider<
      NotificationPreferencesNotifier,
      NotificationPreferencesState
    >(NotificationPreferencesNotifier.new);
