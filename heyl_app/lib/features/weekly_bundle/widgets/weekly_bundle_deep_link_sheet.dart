import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart'
    show AuthReferrer;
import '../../../l10n/generated/l10n.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/deep_link_empty_state_sheet.dart';

/// PROD-2564 — show-helpers for the empty/gated-state bottom sheet shown when a
/// `/weekly-bundle` deep link can't open the Weekly Bundle overlay.
///
/// Reuses the shared [DeepLinkEmptyStateSheet] shell. Three variants (no
/// profiling — the weekly-bundle provider has no `cta_profiling` state):
/// come-back, unsupported-area, and logged-out.

/// Come-back — no bundle this week (`hasError` / poll cap while `isGenerating`
/// / ready-without-pages). The CTA simply closes onto Discovery.
Future<void> showWeeklyBundleComeBackSheet(
  BuildContext context,
  WidgetRef ref,
) {
  final l10n = Lt.of(context);
  return showBottomSheetWithHiddenNav<void>(
    context: context,
    ref: ref,
    builder: (context) => DeepLinkEmptyStateSheet(
      title: l10n.weeklyBundleDeepLinkEmptyTitle,
      body: l10n.weeklyBundleDeepLinkEmptyBody,
      ctaLabel: l10n.weeklyBundleDeepLinkEmptyCta,
      ctaIcon: LucideIcons.compass,
    ),
  );
}

/// Unsupported-area — the resolved city is outside the launch markets
/// (`isUnsupportedCity`). Distinct copy because "check back" wouldn't help here.
Future<void> showWeeklyBundleUnsupportedAreaSheet(
  BuildContext context,
  WidgetRef ref,
) {
  final l10n = Lt.of(context);
  return showBottomSheetWithHiddenNav<void>(
    context: context,
    ref: ref,
    builder: (context) => DeepLinkEmptyStateSheet(
      title: l10n.weeklyBundleDeepLinkUnsupportedTitle,
      body: l10n.weeklyBundleDeepLinkUnsupportedBody,
      ctaLabel: l10n.weeklyBundleDeepLinkUnsupportedCta,
      ctaIcon: LucideIcons.compass,
    ),
  );
}

/// Logged-out — unauthenticated tap (PROD-2564, mirrors Daily Drop Decision
/// #12). The Log-in CTA captures `/weekly-bundle` as the return URL so the
/// bundle reopens after auth; dismissing keeps the user on guest Discovery.
Future<void> showWeeklyBundleLoginSheet(BuildContext context, WidgetRef ref) {
  final l10n = Lt.of(context);
  final router = GoRouter.of(context);
  final returnUrlNotifier = ref.read(returnUrlProvider.notifier);
  return showBottomSheetWithHiddenNav<void>(
    context: context,
    ref: ref,
    builder: (context) => DeepLinkEmptyStateSheet(
      title: l10n.weeklyBundleDeepLinkLoginTitle,
      body: l10n.weeklyBundleDeepLinkLoginBody,
      ctaLabel: l10n.weeklyBundleDeepLinkLoginCta,
      ctaIcon: LucideIcons.log_in,
      cancelLabel: l10n.commonCancel,
      onCta: () {
        // Restore `/weekly-bundle` after login so the deep link reopens and the
        // handler re-runs (now authenticated). `/weekly-bundle` carries no
        // tokens, so no redaction is needed.
        returnUrlNotifier.state = AppRoutes.weeklyBundle;
        router.push('${AppRoutes.login}?from=${AuthReferrer.guestGateHome}');
      },
    ),
  );
}
