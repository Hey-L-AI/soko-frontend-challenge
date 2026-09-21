import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../data/models/notification_item.dart';
import '../../../l10n/generated/l10n.dart';
import '../../discovery/widgets/discovery_shell.dart' show popOrFallback;
import '../../profile/providers/public_profile_providers.dart'
    show pendingRequestCountProvider;
import '../../profile/screens/follow_requests_screen.dart'
    show FollowRequestsList;
import '../providers/notifications_provider.dart';
import '../utils/bundle_summary.dart';
import '../widgets/my_reminders_sheet.dart' show MyRemindersListBody;
import '../widgets/notification_card.dart';

/// PROD-2524 T-E — `/menu/notifications` page. Card layout (rounded,
/// soft-shadow tiles) instead of a list of rows. Tap a card → mark-read +
/// navigate to its `route_path` (when set). Swipe-to-dismiss for soft
/// hide. Pull-to-refresh re-fetches.
///
/// Background mirrors the `/menu/X` screens (`AppColors.sokoPaper`) so
/// the chrome reads as a continuation of the menu surface.
class NotificationsScreen extends ConsumerStatefulWidget {
  const NotificationsScreen({super.key});

  @override
  ConsumerState<NotificationsScreen> createState() =>
      _NotificationsScreenState();
}

class _NotificationsScreenState extends ConsumerState<NotificationsScreen> {
  /// Keys of bundles the user has tapped to expand (multi-member only;
  /// singleton bundles render their head as a plain card and never
  /// enter this set). Cleared on mode change.
  final Set<String> _expandedBundles = {};

  /// Social pilot: a local "Requests" tab layered over the inbox/history
  /// engine modes. When true the body shows incoming follow requests instead
  /// of notification bundles.
  bool _requestsTab = false;

  /// Local "Reminders" tab (same overlay pattern as Requests): shows the
  /// user's event reminders — the surface the standalone bell button used to
  /// open as a sheet, now living inside the inbox.
  bool _remindersTab = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Delivery plan: fetch fresh on every open. The provider de-dupes
      // concurrent refresh calls so this is safe.
      ref.read(notificationsInboxProvider.notifier).refresh();
    });
  }

  void _toggleBundleExpansion(String bundleKey) {
    setState(() {
      if (!_expandedBundles.remove(bundleKey)) {
        _expandedBundles.add(bundleKey);
      }
    });
  }

  /// Tap-handler for a multi-member bundle's synthesized summary head.
  /// Toggles expansion; if expanding from collapsed AND we're in Inbox
  /// mode AND any member is still unread, also fires the bundle-wide
  /// mark-read so the badge clears in one round-trip
  /// (PROD-2781 B3). The bundle stays visible while expanded via the
  /// `_expandedBundles`-aware filter in `_buildBody`, so the user
  /// doesn't see the group yank itself off the inbox mid-read.
  Future<void> _onTapBundleHead(
    NotificationBundle bundle,
    NotificationsInboxMode mode,
  ) async {
    final wasExpanded = _expandedBundles.contains(bundle.key);
    _toggleBundleExpansion(bundle.key);
    if (!wasExpanded &&
        mode == NotificationsInboxMode.inbox &&
        bundle.members.any((m) => m.isUnread)) {
      await ref
          .read(notificationsInboxProvider.notifier)
          .markBundleRead(bundle.key);
    }
  }

  Future<void> _onCardTap(
    NotificationItem item,
    NotificationsInboxMode mode,
  ) async {
    ref
        .read(unifiedAnalyticsProvider)
        .trackNotificationClick(
          notificationId: item.id,
          category: item.category.wireName,
          routePath: item.routePath,
          notificationType: item.type,
        );
    if (mode == NotificationsInboxMode.inbox) {
      await ref.read(notificationsInboxProvider.notifier).markRead(item.id);
    }
    if (!mounted ||
        item.routePath == null ||
        (item.routePath?.isEmpty ?? true)) {
      return;
    }
    final router = ref.read(appRouterProvider);
    router.go(item.routePath!);
  }

  Future<void> _onMarkAllRead() async {
    final unreadCount = ref
        .read(notificationsInboxProvider)
        .items
        .where((it) => it.isUnread)
        .length;
    ref
        .read(unifiedAnalyticsProvider)
        .trackNotificationMarkAllRead(clearedCount: unreadCount);
    await ref.read(notificationsInboxProvider.notifier).markAllRead();
  }

  Future<void> _onDismiss(NotificationItem item) async {
    ref
        .read(unifiedAnalyticsProvider)
        .trackNotificationDismiss(
          notificationId: item.id,
          category: item.category.wireName,
          notificationType: item.type,
        );
    await ref.read(notificationsInboxProvider.notifier).dismiss(item.id);
  }

  void _onSelectMode(NotificationsInboxMode mode) {
    if (mode == ref.read(notificationsInboxProvider).mode) return;
    // Collapse all expansions on mode switch — the visible row set
    // changes underneath us and keeping stale expanded keys is just
    // noise.
    _expandedBundles.clear();
    ref
        .read(unifiedAnalyticsProvider)
        .trackNotificationInboxTabChange(
          tab: mode == NotificationsInboxMode.history ? 'history' : 'inbox',
        );
    // ignore: unawaited_futures
    ref.read(notificationsInboxProvider.notifier).refresh(mode: mode);
  }

  Future<void> _onDismissBundle(NotificationBundle bundle) async {
    // Bundle swipe dismisses every member. Reuses the per-row endpoint
    // sequentially via the existing `dismiss` notifier action — no new
    // API. The bundle's expansion state, if any, is cleared so the
    // collapsed view doesn't briefly show a header for an empty group.
    _expandedBundles.remove(bundle.key);
    final inbox = ref.read(notificationsInboxProvider.notifier);
    for (final member in bundle.members) {
      ref
          .read(unifiedAnalyticsProvider)
          .trackNotificationDismiss(
            notificationId: member.id,
            category: member.category.wireName,
            notificationType: member.type,
          );
      // ignore: unawaited_futures
      inbox.dismiss(member.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final state = ref.watch(notificationsInboxProvider);
    final bundles = _bundlesForRender(state);
    final isHistory = state.mode == NotificationsInboxMode.history;
    final hasUnread = !isHistory && state.visible.any((it) => it.isUnread);
    // Pending follow-request count → badge on the Requests tab.
    final requestsCount = ref.watch(pendingRequestCountProvider);

    return ColoredBox(
      color: AppColors.sokoPaper,
      child: PageContent(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                onBack: () => popOrFallback(context),
                mode: state.mode,
                unreadLabel: l10n.notificationsTabUnread,
                historyLabel: l10n.notificationsTabHistory,
                requestsLabel: l10n.notificationsTabRequests,
                remindersLabel: l10n.notificationsTabReminders,
                requestsCount: requestsCount,
                requestsSelected: _requestsTab,
                remindersSelected: _remindersTab,
                onSelectMode: (m) {
                  if (_requestsTab || _remindersTab) {
                    setState(() {
                      _requestsTab = false;
                      _remindersTab = false;
                    });
                  }
                  _onSelectMode(m);
                },
                onSelectRequests: () => setState(() {
                  _requestsTab = true;
                  _remindersTab = false;
                }),
                onSelectReminders: () => setState(() {
                  _remindersTab = true;
                  _requestsTab = false;
                }),
                markAllLabel: l10n.notificationsMarkAllRead,
                onMarkAll: (!_requestsTab && !_remindersTab && hasUnread)
                    ? _onMarkAllRead
                    : null,
              ),
              Expanded(
                child: _requestsTab
                    ? const FollowRequestsList()
                    : _remindersTab
                    ? const MyRemindersListBody(
                        surface: 'notifications_inbox',
                        popOnOpenEvent: false,
                        shrinkWrap: false,
                      )
                    : _buildBody(context, l10n, state, bundles),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// Like `state.visibleBundles`, but keeps any currently-expanded
  /// bundle visible in Inbox mode even if every member has just been
  /// flipped to read (via `_onTapBundleHead`). Without this, marking
  /// the bundle read on tap would drop it from `state.visible` and the
  /// expansion the user just triggered would vanish on the next frame.
  /// Dismissed members are always filtered out — dismiss is a stronger
  /// "hide" intent than read.
  List<NotificationBundle> _bundlesForRender(NotificationsInboxState state) {
    if (state.mode == NotificationsInboxMode.history) {
      return state.visibleBundles;
    }
    final items = state.items
        .where((it) {
          if (it.isDismissed) return false;
          if (it.isUnread) return true;
          final key = it.bundleKey;
          return key != null && _expandedBundles.contains(key);
        })
        .toList(growable: false);
    return NotificationBundle.group(items);
  }

  Widget _buildBody(
    BuildContext context,
    Lt l10n,
    NotificationsInboxState state,
    List<NotificationBundle> bundles,
  ) {
    // Cold-start load OR a mid-flight mode switch (PROD-2803): the
    // currently-held `items` belong to a different mode than the one
    // the UI now reports, so showing the empty/list state would flash
    // stale content for the duration of the network round-trip.
    final isInitialLoad = !state.hasLoadedOnce && state.isLoading;
    final isModeSwitchLoad =
        state.isLoading &&
        state.loadedMode != null &&
        state.loadedMode != state.mode;
    if (isInitialLoad || isModeSwitchLoad) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            valueColor: AlwaysStoppedAnimation(AppColors.sokoInk),
          ),
        ),
      );
    }

    if (state.error != null && bundles.isEmpty) {
      return _ErrorState(
        title: l10n.notificationsErrorTitle,
        retryLabel: l10n.notificationsErrorRetry,
        onRetry: () => ref.read(notificationsInboxProvider.notifier).refresh(),
      );
    }

    if (bundles.isEmpty) {
      final isHistory = state.mode == NotificationsInboxMode.history;
      return _EmptyState(
        title: isHistory
            ? l10n.notificationsHistoryEmptyTitle
            : l10n.notificationsEmptyTitle,
        body: isHistory
            ? l10n.notificationsHistoryEmptyBody
            : l10n.notificationsEmptyBody,
      );
    }

    return RefreshIndicator(
      color: AppColors.sokoInk,
      onRefresh: () => ref
          .read(notificationsInboxProvider.notifier)
          .refresh(mode: state.mode),
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        itemCount: bundles.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          final bundle = bundles[index];
          // Singleton bundle: render as a plain card, swipe dismisses
          // the underlying item directly. Mirrors the pre-bundling
          // behaviour for un-bundled notifications.
          if (!bundle.isMulti) {
            final item = bundle.head;
            return Dismissible(
              key: ValueKey('notif_${item.id}'),
              direction: DismissDirection.endToStart,
              background: const _DismissBackground(),
              onDismissed: (_) => _onDismiss(item),
              child: NotificationCard(
                item: item,
                onTap: () => _onCardTap(item, state.mode),
              ),
            );
          }
          // Multi-member bundle: render a synthesized summary head
          // (NOT one of the members) + count chip + chevron. Tapping
          // the head expands inline AND, when expanding from collapsed
          // in Inbox mode, fires the bundle-wide mark-read so the
          // badge clears in one round-trip. Expanded view shows ALL N
          // members below — each child retains its own tap →
          // `routePath`, so a 3-day-old daily drop opens THAT day's
          // specific picks.
          final expanded = _expandedBundles.contains(bundle.key);
          return Dismissible(
            key: ValueKey('bundle_${bundle.key}'),
            direction: DismissDirection.endToStart,
            background: const _DismissBackground(),
            onDismissed: (_) => _onDismissBundle(bundle),
            child: _BundledNotificationCard(
              bundle: bundle,
              expanded: expanded,
              onTapHead: () => _onTapBundleHead(bundle, state.mode),
              onTapChild: (child) => _onCardTap(child, state.mode),
            ),
          );
        },
      ),
    );
  }
}

/// Inbox card that wraps a bundle of N>1 notifications. The head is a
/// SYNTHESIZED summary (not one of the members) so expanding doesn't
/// duplicate the head row inside the children list. Collapsed view
/// shows the summary card + count chip + chevron; expanded view keeps
/// the summary and reveals every member below it, each as a regular
/// sub-card with its own per-id route. Unread state on the summary
/// tracks "any member unread" so the pink dot only clears once the
/// whole bundle is read.
class _BundledNotificationCard extends StatelessWidget {
  final NotificationBundle bundle;
  final bool expanded;
  final VoidCallback onTapHead;
  final ValueChanged<NotificationItem> onTapChild;

  const _BundledNotificationCard({
    required this.bundle,
    required this.expanded,
    required this.onTapHead,
    required this.onTapChild,
  });

  /// Builds a virtual NotificationItem to render as the bundle head.
  /// Reuses the existing `NotificationCard` chrome (accent stripe,
  /// background tint, footer time) without adding a parallel widget.
  NotificationItem _summaryItem(BundleSummary summary) {
    final head = bundle.head;
    final bundleUnread = bundle.members.any((m) => m.isUnread);
    return NotificationItem(
      id: 'bundle_summary_${bundle.key}',
      category: head.category,
      type: head.type,
      title: summary.title,
      body: summary.body,
      // No nav from the summary head — the user expands and taps a
      // specific child to navigate. Suppresses the trailing arrow
      // icon in NotificationCard's footer.
      routePath: null,
      // `data: null` skips the reminders-specific "Starts in X" footer
      // (each member has its own `event_start_at`); the summary's
      // footer falls back to "X ago" relative to the latest member.
      data: null,
      bundleKey: bundle.key,
      readAt: bundleUnread ? null : DateTime.now().toUtc(),
      dismissedAt: null,
      createdAt: head.createdAt,
    );
  }

  @override
  Widget build(BuildContext context) {
    final summary = computeBundleSummary(context, bundle);
    final summaryItem = _summaryItem(summary);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Stack(
          children: [
            NotificationCard(item: summaryItem, onTap: onTapHead),
            Positioned(
              top: 10,
              right: 12,
              child: _BundleCountChip(
                count: bundle.members.length,
                expanded: expanded,
              ),
            ),
          ],
        ),
        if (expanded) ...[
          const SizedBox(height: 8),
          for (final child in bundle.members)
            Padding(
              padding: const EdgeInsets.only(left: 16, top: 6),
              child: Opacity(
                opacity: 0.92,
                child: NotificationCard(
                  item: child,
                  onTap: () => onTapChild(child),
                ),
              ),
            ),
        ],
      ],
    );
  }
}

class _BundleCountChip extends StatelessWidget {
  final int count;
  final bool expanded;

  const _BundleCountChip({required this.count, required this.expanded});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.sokoInk.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$count',
            style: const TextStyle(
              color: AppColors.sokoInk,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(width: 4),
          Icon(
            expanded ? LucideIcons.chevron_up : LucideIcons.chevron_down,
            color: AppColors.sokoInk,
            size: 14,
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback onBack;
  final NotificationsInboxMode mode;
  final String unreadLabel;
  final String historyLabel;
  final String requestsLabel;
  final String remindersLabel;
  final int requestsCount;
  final bool requestsSelected;
  final bool remindersSelected;
  final ValueChanged<NotificationsInboxMode> onSelectMode;
  final VoidCallback onSelectRequests;
  final VoidCallback onSelectReminders;
  final String markAllLabel;
  final VoidCallback? onMarkAll;

  const _Header({
    required this.onBack,
    required this.mode,
    required this.unreadLabel,
    required this.historyLabel,
    required this.requestsLabel,
    required this.remindersLabel,
    required this.requestsCount,
    required this.requestsSelected,
    required this.remindersSelected,
    required this.onSelectMode,
    required this.onSelectRequests,
    required this.onSelectReminders,
    required this.markAllLabel,
    required this.onMarkAll,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 12, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              IconButton(
                icon: const Icon(
                  LucideIcons.arrow_left,
                  color: AppColors.sokoInk,
                ),
                onPressed: onBack,
                tooltip: MaterialLocalizations.of(context).backButtonTooltip,
              ),
              Expanded(
                child: _ModeTabs(
                  mode: mode,
                  unreadLabel: unreadLabel,
                  historyLabel: historyLabel,
                  requestsLabel: requestsLabel,
                  remindersLabel: remindersLabel,
                  requestsCount: requestsCount,
                  requestsSelected: requestsSelected,
                  remindersSelected: remindersSelected,
                  onSelectMode: onSelectMode,
                  onSelectRequests: onSelectRequests,
                  onSelectReminders: onSelectReminders,
                ),
              ),
            ],
          ),
          // Mark-all sits on its own line UNDER the Unread/History/Requests
          // toggle (not beside it) so it never crowds the Requests pill.
          if (onMarkAll != null)
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: onMarkAll,
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.sokoInk,
                  textStyle: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                child: Text(markAllLabel),
              ),
            ),
        ],
      ),
    );
  }
}

/// Two-pill segmented switch between inbox-mode and history-mode.
/// Selected pill takes the soko-dark treatment (sokoInk bg + sokoPaper
/// text) — same idiom as `SokoCtaButton.ink` and the soonest-occurrence
/// chip on the reminder picker.
class _ModeTabs extends StatelessWidget {
  final NotificationsInboxMode mode;
  final String unreadLabel;
  final String historyLabel;
  final String requestsLabel;
  final String remindersLabel;
  final int requestsCount;
  final bool requestsSelected;
  final bool remindersSelected;
  final ValueChanged<NotificationsInboxMode> onSelectMode;
  final VoidCallback onSelectRequests;
  final VoidCallback onSelectReminders;

  const _ModeTabs({
    required this.mode,
    required this.unreadLabel,
    required this.historyLabel,
    required this.requestsLabel,
    required this.remindersLabel,
    required this.requestsCount,
    required this.requestsSelected,
    required this.remindersSelected,
    required this.onSelectMode,
    required this.onSelectRequests,
    required this.onSelectReminders,
  });

  @override
  Widget build(BuildContext context) {
    // Any overlay tab active → the engine pills read as unselected.
    final overlayActive = requestsSelected || remindersSelected;
    return Align(
      alignment: Alignment.centerLeft,
      // Four tabs are tight on a normal phone, so drop the enclosing grey
      // pill-group box and tighten each tab — only the selected tab keeps its
      // dark fill. The horizontal scroll stays as a safety net for very small
      // phones (with no outer box it no longer reads as "clipped").
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _ModeTab(
              label: unreadLabel,
              selected: !overlayActive && mode == NotificationsInboxMode.inbox,
              onTap: () => onSelectMode(NotificationsInboxMode.inbox),
            ),
            _ModeTab(
              label: historyLabel,
              selected:
                  !overlayActive && mode == NotificationsInboxMode.history,
              onTap: () => onSelectMode(NotificationsInboxMode.history),
            ),
            _ModeTab(
              label: requestsLabel,
              selected: requestsSelected,
              badgeCount: requestsCount,
              onTap: onSelectRequests,
            ),
            _ModeTab(
              label: remindersLabel,
              selected: remindersSelected,
              onTap: onSelectReminders,
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeTab extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final int badgeCount;

  const _ModeTab({
    required this.label,
    required this.selected,
    required this.onTap,
    this.badgeCount = 0,
  });

  @override
  Widget build(BuildContext context) {
    final bg = selected ? AppColors.sokoInk : Colors.transparent;
    final fg = selected ? AppColors.sokoPaper : AppColors.sokoInk;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          curve: Curves.easeOut,
          padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: fg,
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w500 : FontWeight.w400,
                ),
              ),
              if (badgeCount > 0) ...[
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.sokoPink,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    badgeCount > 99 ? '99+' : '$badgeCount',
                    style: const TextStyle(
                      color: AppColors.sokoInk,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String title;
  final String body;

  const _EmptyState({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              LucideIcons.inbox,
              color: AppColors.sokoShade3,
              size: 56,
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.sokoShade3,
                fontSize: 14,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String title;
  final String retryLabel;
  final VoidCallback onRetry;

  const _ErrorState({
    required this.title,
    required this.retryLabel,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              LucideIcons.triangle_alert,
              color: AppColors.sokoShade3,
              size: 36,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 16,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onRetry,
              style: OutlinedButton.styleFrom(
                foregroundColor: AppColors.sokoInk,
                side: const BorderSide(color: AppColors.sokoInk),
              ),
              child: Text(retryLabel),
            ),
          ],
        ),
      ),
    );
  }
}

class _DismissBackground extends StatelessWidget {
  const _DismissBackground();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppColors.sokoInk.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      alignment: Alignment.centerRight,
      child: const Icon(
        LucideIcons.trash_2,
        color: AppColors.sokoInk,
        size: 20,
      ),
    );
  }
}
