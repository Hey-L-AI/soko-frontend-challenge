import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../providers/api_provider.dart';
import '../utils/daily_drop_destination.dart';

/// PROD-3730 — resolves `/recommendations/:recommendationId`.
///
/// **Why this route exists.** The backend's `daily_drop_ready` push has always
/// carried `route_path=/recommendations/{rec_id}`
/// (`heyl/apps/recommendations/daily_tasks.py`), and **nothing in the app
/// matched it** — so `errorBuilder` → `_UnknownRouteRedirect` silently sent
/// every tap to `/`. It half-worked, because a *ready* drop's card is sitting
/// on Discovery, but the backend's actual intent — a per-id route so a
/// three-day-old push opens *that* day's picks rather than today's — was lost,
/// and the notification-inbox tap (`notifications_screen.dart`, which calls
/// `router.go(item.routePath!)`) was broken outright.
///
/// Ownership was agreed with `heyl-backend-search-03` on 2026-08-07: the FE
/// adds the route, the BE keeps emitting the per-id `route_path` (it also
/// becomes load-bearing for PROD-3436's visibility contract, since
/// `GET /recommendations/{id}` is one of the three endpoints gaining
/// `visibility`).
///
/// **Shape.** This screen renders nothing the user is meant to look at. It
/// fetches the recommendation, replaces itself with Discovery so there is a
/// real back-stack, and pushes the drop's own destination on top — the same
/// landing the `/drop` deep link produces. Any failure falls back to `/drop`,
/// which re-resolves today's drop through the existing handler.
class RecommendationDeepLinkScreen extends ConsumerStatefulWidget {
  const RecommendationDeepLinkScreen({
    super.key,
    required this.recommendationId,
  });

  final String recommendationId;

  @override
  ConsumerState<RecommendationDeepLinkScreen> createState() =>
      _RecommendationDeepLinkScreenState();
}

class _RecommendationDeepLinkScreenState
    extends ConsumerState<RecommendationDeepLinkScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
  }

  Future<void> _resolve() async {
    if (!mounted) return;
    // Capture the router now: after `go()` this widget's context is defunct,
    // but the router outlives it.
    final router = GoRouter.of(context);
    final analytics = ref.read(unifiedAnalyticsProvider);
    final actionContext = analytics.actionContext;

    try {
      final drop = await ref
          .read(dailyDropApiProvider)
          .getRecommendationById(widget.recommendationId);

      if (!mounted || !analytics.isActionContextCurrent(actionContext)) return;
      if (!drop.hasRecommendation) {
        // User-scoped and mode-restricted server-side: a forged id, another
        // user's id, or a weekly-bundle id lands here (or throws below).
        analytics.trackDailyDropOpen(reason: 'recommendation_not_found');
        router.go(AppRoutes.dailyDrop);
        return;
      }

      analytics.trackDailyDropOpen(
        recommendationId: drop.recommendationId,
        itemType: drop.itemType,
        category: drop.category,
        reason: 'push_recommendation',
      );

      final (path, extra) = dailyDropDestinationRoute(drop);
      router.go(AppRoutes.home);
      router.push(path, extra: extra);
    } catch (_) {
      if (!mounted || !analytics.isActionContextCurrent(actionContext)) return;
      // 404 / 401 / offline. `/drop` re-resolves today's drop through the
      // existing handler, which owns every cause-specific empty state.
      analytics.trackDailyDropOpen(reason: 'recommendation_fetch_failed');
      router.go(AppRoutes.dailyDrop);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Paper-coloured, not an empty white flash — this is on screen for one
    // network round-trip on a cold push tap.
    return const Scaffold(
      backgroundColor: AppColors.sokoPaper,
      body: Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sokoInkSecondary,
          ),
        ),
      ),
    );
  }
}
