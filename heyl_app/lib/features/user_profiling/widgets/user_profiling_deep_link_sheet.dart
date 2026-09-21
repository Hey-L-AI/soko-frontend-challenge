import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/deep_link_empty_state_sheet.dart';

/// PROD-2566 — show-helper for the "log in to do the profiling" bottom sheet a
/// LOGGED-OUT user sees when they tap the `/user-profiling/flow` deep link.
///
/// Mirrors `showDailyDropLoginSheet` (PROD-2565): reuses the shared
/// [DeepLinkEmptyStateSheet] shell, and the Log-in CTA seeds `/user-profiling/
/// flow` as the return URL so the flow reopens after auth — PROD-2689 honors
/// the returnUrl across phone-OTP + native Google/Apple + web callback, so the
/// returning user (now a fresh, not-yet-profiled account) lands on the survey.
/// Dismissing keeps the guest on Discovery.
Future<void> showUserProfilingLoginSheet(BuildContext context, WidgetRef ref) {
  final l10n = Lt.of(context);
  final router = GoRouter.of(context);
  final returnUrlNotifier = ref.read(returnUrlProvider.notifier);
  // Preserve the original deep-link query on the return URL — notably `?reset=1`
  // (the campaign fresh-start link), plus any `utm_*` — dropping only the
  // Discovery `user_profiling` marker. Without this, a logged-out EXISTING user
  // who taps `…/user-profiling/flow?reset=1` would return to the bare path after
  // login and the gate would send them to the already-profiled landing instead
  // of a fresh run (PROD-2566). The path carries no tokens, so no redaction.
  final query = Map<String, String>.from(
    GoRouterState.of(context).uri.queryParameters,
  )..remove('user_profiling');
  final returnUrl = query.isEmpty
      ? AppRoutes.userProfilingFlow
      : Uri(
          path: AppRoutes.userProfilingFlow,
          queryParameters: query,
        ).toString();
  return showBottomSheetWithHiddenNav<void>(
    context: context,
    ref: ref,
    builder: (context) => DeepLinkEmptyStateSheet(
      title: l10n.profilingDeepLinkLoginTitle,
      body: l10n.profilingDeepLinkLoginBody,
      ctaLabel: l10n.profilingDeepLinkLoginCta,
      ctaIcon: LucideIcons.log_in,
      cancelLabel: l10n.commonCancel,
      onCta: () {
        // Restore the flow (with preserved query) after login so the deep link
        // reopens and the gate re-runs (now authenticated).
        returnUrlNotifier.state = returnUrl;
        router.push('${AppRoutes.login}?from=${AuthReferrer.guestGateHome}');
      },
    ),
  );
}
