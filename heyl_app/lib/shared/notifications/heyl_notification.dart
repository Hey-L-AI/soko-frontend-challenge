import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/theme/app_colors.dart';
import '../widgets/clickable.dart';
import 'notification_state.dart';
import 'notifications_provider.dart';

/// Default auto-dismiss for non-sticky, non-loading notifications.
const Duration _kDefaultDuration = Duration(seconds: 4);

/// Show (or replace) the global in-app notification.
///
/// Renders via a `Stack` sibling at `MaterialApp.builder` level (see
/// [NotificationHost]), so the notification floats above every route,
/// dialog, and modal sheet. Auto-replace semantics: a `show` while
/// another is visible replaces it.
void showSoko(
  WidgetRef ref, {
  required String message,
  SokoVariant variant = SokoVariant.info,
  SokoAction? action,
  Duration? duration,
  bool sticky = false,
  IconData? icon,
  VoidCallback? onDismissed,
}) {
  ref
      .read(notificationsProvider.notifier)
      .show(
        message: message,
        variant: variant,
        action: action,
        duration:
            duration ??
            (variant == SokoVariant.loading ? null : _kDefaultDuration),
        sticky: sticky || variant == SokoVariant.loading,
        icon: icon,
        onDismissed: onDismissed,
      );
}

/// `BuildContext`-only convenience for call sites without a `WidgetRef`
/// — internally resolves the provider via a [ProviderScope] lookup.
/// Prefer the [WidgetRef]-typed variant inside Consumer widgets.
void showSokoFromContext(
  BuildContext context, {
  required String message,
  SokoVariant variant = SokoVariant.info,
  SokoAction? action,
  Duration? duration,
  bool sticky = false,
  IconData? icon,
  VoidCallback? onDismissed,
}) {
  final container = ProviderScope.containerOf(context, listen: false);
  container
      .read(notificationsProvider.notifier)
      .show(
        message: message,
        variant: variant,
        action: action,
        duration:
            duration ??
            (variant == SokoVariant.loading ? null : _kDefaultDuration),
        sticky: sticky || variant == SokoVariant.loading,
        icon: icon,
        onDismissed: onDismissed,
      );
}

/// Dismiss the current notification (if any). Fires its `onDismissed`.
void dismissSoko(WidgetRef ref) {
  ref.read(notificationsProvider.notifier).dismiss();
}

void dismissSokoFromContext(BuildContext context) {
  final container = ProviderScope.containerOf(context, listen: false);
  container.read(notificationsProvider.notifier).dismiss();
}

/// Visual: Soko/Paper card, 12 px radius, soft shadow, icon + status text
/// + optional action + X dismiss. Action renders as a `sokoInk` pill with
/// a `sokoPaper` label so the CTA reads as a button on the pink toast
/// surface (PROD-1885 — was previously a `sokoPink` text link).
class SokoCard extends ConsumerWidget {
  final SokoState state;
  const SokoCard({super.key, required this.state});

  IconData _defaultIcon() {
    switch (state.variant) {
      case SokoVariant.info:
        return LucideIcons.info;
      case SokoVariant.success:
        return LucideIcons.circle_check;
      case SokoVariant.error:
        return LucideIcons.triangle_alert;
      case SokoVariant.loading:
        return LucideIcons.image_plus; // unused — spinner replaces it
    }
  }

  Color _iconTint() {
    switch (state.variant) {
      case SokoVariant.error:
        return AppColors.error;
      case SokoVariant.success:
      case SokoVariant.info:
      case SokoVariant.loading:
        return AppColors.sokoInk;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final Widget leading;
    if (state.variant == SokoVariant.loading) {
      leading = const SizedBox(
        width: 20,
        height: 20,
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.sokoInk,
            ),
          ),
        ),
      );
    } else {
      leading = Icon(
        state.icon ?? _defaultIcon(),
        size: 20,
        color: _iconTint(),
      );
    }

    return Material(
      color: Colors.transparent,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppColors.sokoLight3,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.sokoPink, width: 1),
          boxShadow: [
            BoxShadow(
              color: AppColors.sokoInk.withValues(alpha: 0.12),
              blurRadius: 12,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                state.message,
                style: const TextStyle(
                  fontFamily: 'Zalando Sans',
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  height: 1.3,
                  letterSpacing: -0.14,
                  color: AppColors.sokoInk,
                ),
              ),
            ),
            if (state.action != null) ...[
              const SizedBox(width: 8),
              // PROD-1885: action now reads as a button — `sokoInk` fill +
              // `sokoPaper` (near-white) label — instead of a pink text
              // link, which on the `sokoLight3` toast bg blended with the
              // surface and was easy to miss as an interactive element.
              Clickable(
                onTap: () {
                  // Fire user action, then auto-dismiss the notification
                  // so the surface doesn't linger after the user's intent
                  // has been satisfied. Matches SnackBarAction semantics.
                  state.action!.onTap();
                  ref.read(notificationsProvider.notifier).dismiss();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: AppColors.sokoInk,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    state.action!.label,
                    style: const TextStyle(
                      fontFamily: 'Zalando Sans',
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      height: 1.2,
                      letterSpacing: -0.13,
                      color: AppColors.sokoPaper,
                    ),
                  ),
                ),
              ),
            ],
            const SizedBox(width: 4),
            Clickable(
              onTap: () => ref.read(notificationsProvider.notifier).dismiss(),
              child: const Padding(
                padding: EdgeInsets.all(4),
                child: Icon(
                  LucideIcons.x,
                  size: 16,
                  color: AppColors.sokoShade3,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
