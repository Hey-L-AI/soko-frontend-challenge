import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/deep_link_empty_state_sheet.dart';

/// PROD-2565 — show-helpers for the empty/gated-state bottom sheet shown when a
/// `/drop` deep link can't open today's Daily Drop detail page.
///
/// The shell widget itself was extracted to the shared
/// [DeepLinkEmptyStateSheet] (PROD-2564) so Daily Drop, Weekly Bundle, and the
/// future Profiling-Start deep links share one component. Four content
/// variants: come-back-tomorrow, unsupported-area, profiling, and logged-out.

/// Come-back-tomorrow — the drop isn't ready (`isGenerating` / poll
/// timeout / `hasError` / ready-without-a-detail-entity). The CTA simply
/// closes onto Discovery.
Future<void> showDailyDropComeBackTomorrowSheet(
  BuildContext context,
  WidgetRef ref,
) {
  final l10n = Lt.of(context);
  return showBottomSheetWithHiddenNav<void>(
    context: context,
    ref: ref,
    builder: (context) => DeepLinkEmptyStateSheet(
      title: l10n.dailyDropDeepLinkEmptyTitle,
      body: l10n.dailyDropDeepLinkEmptyBody,
      ctaLabel: l10n.dailyDropDeepLinkEmptyCta,
      ctaIcon: LucideIcons.compass,
    ),
  );
}

/// Unsupported-area — the resolved city is outside the launch markets
/// (`isUnsupportedCity`). Distinct copy because "come back tomorrow"
/// wouldn't help here.
Future<void> showDailyDropUnsupportedAreaSheet(
  BuildContext context,
  WidgetRef ref,
) {
  final l10n = Lt.of(context);
  return showBottomSheetWithHiddenNav<void>(
    context: context,
    ref: ref,
    builder: (context) => DeepLinkEmptyStateSheet(
      title: l10n.dailyDropDeepLinkUnsupportedTitle,
      body: l10n.dailyDropDeepLinkUnsupportedBody,
      ctaLabel: l10n.dailyDropDeepLinkUnsupportedCta,
      ctaIcon: LucideIcons.compass,
    ),
  );
}

/// Profiling — a brand-new, unprofiled user (`isCtaProfiling`). Explains
/// that Soko needs to learn their taste first and routes them into the
/// profiling flow, which unblocks their drop (BE: `_should_gate_for_cta_profiling`).
Future<void> showDailyDropProfilingSheet(BuildContext context, WidgetRef ref) {
  final l10n = Lt.of(context);
  final router = GoRouter.of(context);
  final analytics = ref.read(unifiedAnalyticsProvider);
  return showBottomSheetWithHiddenNav<void>(
    context: context,
    ref: ref,
    builder: (context) => DeepLinkEmptyStateSheet(
      title: l10n.dailyDropDeepLinkProfilingTitle,
      body: l10n.dailyDropDeepLinkProfilingBody,
      ctaLabel: l10n.dailyDropDeepLinkProfilingCta,
      ctaIcon: LucideIcons.sparkles,
      cancelLabel: l10n.commonCancel,
      onCta: () {
        analytics.trackDailyDropProfilingCtaTap();
        // PROD-2566: attribute `profiling_started` to the daily-drop CTA (the
        // route default is 'deep_link' for an external tap).
        router.push('${AppRoutes.userProfilingFlow}?source=daily_drop_cta');
      },
    ),
  );
}

/// Logged-out — unauthenticated tap (PROD-2565 Decision #12). The Log-in
/// CTA captures `/drop` as the return URL so the drop reopens after auth;
/// dismissing keeps the user on guest Discovery.
Future<void> showDailyDropLoginSheet(BuildContext context, WidgetRef ref) {
  final l10n = Lt.of(context);
  final router = GoRouter.of(context);
  final returnUrlNotifier = ref.read(returnUrlProvider.notifier);
  return showBottomSheetWithHiddenNav<void>(
    context: context,
    ref: ref,
    builder: (context) => DeepLinkEmptyStateSheet(
      title: l10n.dailyDropDeepLinkLoginTitle,
      body: l10n.dailyDropDeepLinkLoginBody,
      ctaLabel: l10n.dailyDropDeepLinkLoginCta,
      ctaIcon: LucideIcons.log_in,
      cancelLabel: l10n.commonCancel,
      onCta: () {
        // Restore `/drop` after login so the deep link reopens and the
        // handler re-runs (now authenticated). `/drop` carries no tokens,
        // so no redaction is needed.
        returnUrlNotifier.state = AppRoutes.dailyDrop;
        router.push('${AppRoutes.login}?from=${AuthReferrer.guestGateHome}');
      },
    ),
  );
}
