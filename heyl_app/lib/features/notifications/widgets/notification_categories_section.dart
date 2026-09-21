import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/experiment_service.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/notification_item.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/notifications/notifications_provider.dart';
import '../providers/notification_preferences_provider.dart';

/// Returns the set of [NotificationCategory] values the user can see /
/// toggle for the current [ExperimentState]. Reminders, Discovery, and
/// Marketing are always visible; the remaining four are gated by
/// `notif-category-*` PostHog flags. Marketing surfaces the nested
/// `marketing.push` channel (PROD-2510); the other marketing channels
/// (email / SMS / WhatsApp) live in the separate Marketing section.
Set<NotificationCategory> visibleNotificationCategories(
  ExperimentState experiment,
) {
  return {
    NotificationCategory.reminders,
    NotificationCategory.discovery,
    NotificationCategory.marketing,
    if (experiment.enableNotifCategoryChat) NotificationCategory.chat,
    if (experiment.enableNotifCategorySocial) NotificationCategory.social,
    if (experiment.enableNotifCategoryAsyncJobs) NotificationCategory.asyncJobs,
    if (experiment.enableNotifCategoryFeedback) NotificationCategory.feedback,
  };
}

/// PROD-2526 T-L — per-category toggles. Six categories, one row each,
/// grouped under a single section header. Opt-out model: every row
/// starts as on. Switches PATCH the change immediately (optimistic).
class NotificationCategoriesSection extends ConsumerStatefulWidget {
  const NotificationCategoriesSection({super.key});

  @override
  ConsumerState<NotificationCategoriesSection> createState() =>
      _NotificationCategoriesSectionState();
}

class _NotificationCategoriesSectionState
    extends ConsumerState<NotificationCategoriesSection> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final state = ref.read(notificationPreferencesProvider);
      if (!state.hasLoadedOnce) {
        ref.read(notificationPreferencesProvider.notifier).refresh();
      }
    });
  }

  Future<void> _onToggle(NotificationCategory category, bool value) async {
    final l10n = Lt.of(context);
    // Fire on user gesture (matches the optimistic UI) — the event reflects
    // the user's intent regardless of whether the PATCH succeeds. A failed
    // PATCH reverts the toggle but the user-intent signal stays.
    ref
        .read(unifiedAnalyticsProvider)
        .trackNotificationPreferencesChange(
          category: category.wireName,
          enabled: value,
        );
    final ok = await ref
        .read(notificationPreferencesProvider.notifier)
        .toggle(category, value);
    if (!mounted || ok) return;
    ref
        .read(notificationsProvider.notifier)
        .show(
          message: l10n.notificationCategoriesSaveError,
          variant: SokoVariant.error,
        );
  }

  Future<void> _onToggleType(
    NotificationCategory category,
    String type,
    bool value,
  ) async {
    final l10n = Lt.of(context);
    ref
        .read(unifiedAnalyticsProvider)
        .trackNotificationPreferencesChange(
          category: '${category.wireName}.$type',
          enabled: value,
        );
    final ok = await ref
        .read(notificationPreferencesProvider.notifier)
        .toggleType(category, type, value);
    if (!mounted || ok) return;
    ref
        .read(notificationsProvider.notifier)
        .show(
          message: l10n.notificationCategoriesSaveError,
          variant: SokoVariant.error,
        );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final state = ref.watch(notificationPreferencesProvider);
    final experiment = ref.watch(experimentServiceProvider);
    final prefs = state.preferences;

    // PROD-2511 follow-up — filter unimplemented categories. Reminders +
    // Discovery have a wired-up BE dispatcher today and are always shown;
    // the others stay hidden until their PostHog flag flips on (default
    // false). Server-side preference is preserved regardless of FE
    // visibility — re-enabling a flag restores the toggle to its last
    // PATCH'd value.
    final visibleRows = _categoryRows(
      l10n,
    ).where((r) => r.visibleWhen?.call(experiment) ?? true).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Icon(
              LucideIcons.list_filter,
              color: AppColors.sokoInk,
              size: 18,
            ),
            const SizedBox(width: 8),
            Text(
              l10n.notificationCategoriesTitle,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          l10n.notificationCategoriesSubtitle,
          style: const TextStyle(
            color: AppColors.sokoShade3,
            fontSize: 13,
            height: 1.35,
          ),
        ),
        const SizedBox(height: 12),
        for (final entry in visibleRows) ...[
          _CategoryRow(
            title: entry.title,
            subtitle: entry.subtitle,
            value: prefs.valueFor(entry.category),
            isSaving: state.isSaving,
            onChanged: (next) => _onToggle(entry.category, next),
          ),
          // PROD-2510 hierarchical preferences: when a category has
          // registered notification types (e.g. `discovery` has
          // `weekly_bundle_ready` + `daily_drop_ready`), surface each
          // as an indented sub-row so the user can opt out of one
          // specific drop without losing the others. Sub-rows are
          // hidden entirely when the category-wide toggle is off —
          // the master IS the OR of its children (see
          // `NotificationPreferencesNotifier.toggleType`), so when the
          // master is off all children are off, and there's no
          // fine-grained state to expose.
          if (prefs.valueFor(entry.category))
            for (final typeEntry in _subTypeRowsFor(l10n, entry.category))
              Padding(
                padding: const EdgeInsets.only(left: 28),
                child: _CategoryRow(
                  title: typeEntry.title,
                  subtitle: typeEntry.subtitle,
                  value:
                      prefs.categoryFor(entry.category).types[typeEntry.type] ??
                      prefs.valueFor(entry.category),
                  isSaving: state.isSaving,
                  onChanged: (next) =>
                      _onToggleType(entry.category, typeEntry.type, next),
                ),
              ),
          if (entry != visibleRows.last) const SizedBox(height: 4),
        ],
      ],
    );
  }

  /// Returns the wire-`type` sub-rows to render under [category], in
  /// declaration order. Empty when the category has no registered
  /// types (server's TemplateSpec registry is empty for it). Each row
  /// pairs a localized label + subtitle with the wire type name the
  /// PATCH endpoint expects.
  List<_TypeRowSpec> _subTypeRowsFor(Lt l10n, NotificationCategory category) {
    switch (category) {
      case NotificationCategory.discovery:
        return [
          _TypeRowSpec(
            type: 'weekly_bundle_ready',
            title: l10n.notificationTypeWeeklyBundleReady,
            subtitle: l10n.notificationTypeWeeklyBundleReadySubtitle,
          ),
          _TypeRowSpec(
            type: 'daily_drop_ready',
            title: l10n.notificationTypeDailyDropReady,
            subtitle: l10n.notificationTypeDailyDropReadySubtitle,
          ),
        ];
      // PROD-3081 Phase A — follow-graph sub-types. Mirror the server's
      // TemplateSpec registry (social:follow_request / new_follower /
      // follow_request_accepted / followed_back).
      case NotificationCategory.social:
        return [
          _TypeRowSpec(
            type: 'follow_request',
            title: l10n.notificationTypeFollowRequest,
            subtitle: l10n.notificationTypeFollowRequestSubtitle,
          ),
          _TypeRowSpec(
            type: 'new_follower',
            title: l10n.notificationTypeNewFollower,
            subtitle: l10n.notificationTypeNewFollowerSubtitle,
          ),
          _TypeRowSpec(
            type: 'follow_request_accepted',
            title: l10n.notificationTypeFollowRequestAccepted,
            subtitle: l10n.notificationTypeFollowRequestAcceptedSubtitle,
          ),
          _TypeRowSpec(
            type: 'followed_back',
            title: l10n.notificationTypeFollowedBack,
            subtitle: l10n.notificationTypeFollowedBackSubtitle,
          ),
          // PROD-3082 Phase B — zine sub-types.
          _TypeRowSpec(
            type: 'zine_followed',
            title: l10n.notificationTypeZineFollowed,
            subtitle: l10n.notificationTypeZineFollowedSubtitle,
          ),
          _TypeRowSpec(
            type: 'zine_item_added',
            title: l10n.notificationTypeZineItemAdded,
            subtitle: l10n.notificationTypeZineItemAddedSubtitle,
          ),
          _TypeRowSpec(
            type: 'saved_added_to_zine',
            title: l10n.notificationTypeSavedAddedToZine,
            subtitle: l10n.notificationTypeSavedAddedToZineSubtitle,
          ),
          // PROD-3083 Phase C — memory-bio nudge.
          _TypeRowSpec(
            type: 'memory_bio_ready',
            title: l10n.notificationTypeMemoryBioReady,
            subtitle: l10n.notificationTypeMemoryBioReadySubtitle,
          ),
        ];
      // No other categories have user-tunable sub-types yet. As
      // async_jobs / feedback gain registered types, add their sub-rows
      // here.
      case NotificationCategory.reminders:
      case NotificationCategory.asyncJobs:
      case NotificationCategory.chat:
      case NotificationCategory.feedback:
      case NotificationCategory.marketing:
      case NotificationCategory.unknown:
        return const [];
    }
  }

  List<_CategoryRowSpec> _categoryRows(Lt l10n) => [
    _CategoryRowSpec(
      category: NotificationCategory.reminders,
      title: l10n.notificationCategoryReminders,
      subtitle: l10n.notificationCategoryRemindersSubtitle,
    ),
    _CategoryRowSpec(
      category: NotificationCategory.chat,
      title: l10n.notificationCategoryChat,
      subtitle: l10n.notificationCategoryChatSubtitle,
      visibleWhen: (s) => s.enableNotifCategoryChat,
    ),
    _CategoryRowSpec(
      category: NotificationCategory.discovery,
      title: l10n.notificationCategoryDiscovery,
      subtitle: l10n.notificationCategoryDiscoverySubtitle,
    ),
    _CategoryRowSpec(
      category: NotificationCategory.marketing,
      title: l10n.notificationCategoryMarketing,
      subtitle: l10n.notificationCategoryMarketingSubtitle,
    ),
    _CategoryRowSpec(
      category: NotificationCategory.social,
      title: l10n.notificationCategorySocial,
      subtitle: l10n.notificationCategorySocialSubtitle,
      visibleWhen: (s) => s.enableNotifCategorySocial,
    ),
    _CategoryRowSpec(
      category: NotificationCategory.asyncJobs,
      title: l10n.notificationCategoryAsyncJobs,
      subtitle: l10n.notificationCategoryAsyncJobsSubtitle,
      visibleWhen: (s) => s.enableNotifCategoryAsyncJobs,
    ),
    _CategoryRowSpec(
      category: NotificationCategory.feedback,
      title: l10n.notificationCategoryFeedback,
      subtitle: l10n.notificationCategoryFeedbackSubtitle,
      visibleWhen: (s) => s.enableNotifCategoryFeedback,
    ),
  ];
}

class _TypeRowSpec {
  /// Wire `notification_type` (e.g. `weekly_bundle_ready`).
  final String type;
  final String title;
  final String subtitle;

  const _TypeRowSpec({
    required this.type,
    required this.title,
    required this.subtitle,
  });
}

class _CategoryRowSpec {
  final NotificationCategory category;
  final String title;
  final String subtitle;

  /// When null the row is always shown (Reminders + Discovery — the two
  /// categories already wired end-to-end on the backend). When non-null
  /// the row renders only if the predicate returns true over the current
  /// [ExperimentState] — wired to PostHog flags `notif-category-*` so
  /// the toggle stays hidden until the BE pipeline lands a dispatcher
  /// for that category, then a flag flip reveals it.
  final bool Function(ExperimentState)? visibleWhen;

  const _CategoryRowSpec({
    required this.category,
    required this.title,
    required this.subtitle,
    this.visibleWhen,
  });

  @override
  bool operator ==(Object other) =>
      other is _CategoryRowSpec && other.category == category;

  @override
  int get hashCode => category.hashCode;
}

class _CategoryRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final bool isSaving;
  final ValueChanged<bool> onChanged;

  const _CategoryRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.isSaving,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.sokoInk,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppColors.sokoShade3,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Switch(
            value: value,
            onChanged: isSaving ? null : onChanged,
            activeThumbColor: AppColors.sokoPink,
            activeTrackColor: AppColors.sokoPink.withValues(alpha: 0.4),
          ),
        ],
      ),
    );
  }
}
