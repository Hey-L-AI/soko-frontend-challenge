import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/experiment_service.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/auth_gating.dart';
import '../../../l10n/generated/l10n.dart';
import '../../profile/providers/public_profile_providers.dart'
    show pendingRequestCountProvider;
import '../providers/notifications_provider.dart';

/// Small inbox button with unread badge. Mounted on the Menu header,
/// the Discovery chat bar, the Discovery end-of-feed CTAs and the social
/// profile header. Tap routes to `/menu/notifications`. Badge auto-hides at
/// zero.
///
/// One chrome everywhere: a 36 px `Soko/Ink @8%` circle with a 16 px glyph,
/// matching `ChatBarCircleButton`. (A bare-glyph variant existed for the
/// profile header until that header adopted the tinted circles too.)
class NotificationsTopButton extends ConsumerWidget {
  const NotificationsTopButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // PROD-2511 — kill-switch. Hides the inbox entry point everywhere
    // the button is mounted (chat bar, menu screen, city action bar,
    // discovery end-of-feed CTAs, my-reminders composition).
    final engineEnabled = ref.watch(
      experimentServiceProvider.select((s) => s.notificationsEngineEnabled),
    );
    if (!engineEnabled) return const SizedBox.shrink();

    final unread = ref.watch(notificationsUnreadCountProvider);
    // Follow requests live in the inbox (Requests tab), so they count toward
    // the badge. Uses the live count that drops immediately on accept/reject.
    final requestsCount = ref.watch(pendingRequestCountProvider);
    final badgeCount = unread + requestsCount;
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;

    // PROD-3142 — guests must be gated here, at the button. `/menu/*` is a
    // protected route (`_isProtectedRoute`, app_router.dart), so without
    // this the router silently bounces the guest to /login mid-tap. Both
    // variants below share this closure so the two can't drift apart again.
    void handleTap() => requireAuth(
      context,
      ref,
      action: l10n.guestNotificationsAction,
      referrer: AuthReferrer.guestNotifications,
      // Tracked inside the gate: a guest who never gets past the sheet
      // hasn't opened the inbox. `requireAuth` emits its own auth_prompt.
      onAuthenticated: () {
        ref
            .read(unifiedAnalyticsProvider)
            .trackNotificationInboxOpen(unreadCount: unread);
        context.push(AppRoutes.menuNotifications);
      },
    );

    Widget badge() => Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      decoration: BoxDecoration(
        color: AppColors.sokoPink,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.sokoPaper, width: 1.5),
      ),
      child: Center(
        child: Text(
          badgeCount > 99 ? '99+' : '$badgeCount',
          style: const TextStyle(
            color: AppColors.sokoInk,
            fontSize: 10,
            fontWeight: FontWeight.w600,
            height: 1.0,
          ),
        ),
      ),
    );

    return Tooltip(
      message: l10n.notificationsTooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: handleTap,
          child: Container(
            // Matches ChatBarCircleButton (mic, send, history) — 36 × 36
            // with a 16 px glyph — so the inbox reads as a peer to the
            // other chat-bar circle buttons, not a heavier outlier.
            width: 36,
            height: 36,
            decoration: const BoxDecoration(
              color: AppColors.sokoInk8,
              shape: BoxShape.circle,
            ),
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                Icon(LucideIcons.inbox, color: inkColor, size: 16),
                if (badgeCount > 0)
                  Positioned(top: -2, right: -2, child: badge()),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
