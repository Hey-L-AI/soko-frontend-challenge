import 'dart:async';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/services/push_permission_service.dart';
import '../../../../core/services/unified_analytics_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/auth_gating.dart';
import '../../../../core/utils/text_line_break.dart';
import '../../../../data/models/daily_drop.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../daily_drop/providers/daily_drop_provider.dart';
import '../../../daily_drop/utils/daily_drop_destination.dart';
import '../../../daily_drop/widgets/daily_drop_generating_sheet.dart';
import '../../../notifications/providers/notification_preferences_provider.dart';
import '../../../user_profiling/providers/user_profiling_gate_provider.dart';
import '_daily_drop_status_cards.dart';
import '_image_template_card.dart';

/// Discovery — Daily Drop section (PROD-1518).
///
/// Renders the shared image-template card when today's recommendation is
/// ready. Tapping routes to the venue/event detail page (the legacy
/// `DailyDropOverlay` at `/drop` is reserved for the old home flow).
///
/// Layout-shift handling: while the provider resolves, a fixed-height
/// skeleton holds the layout. On error / no-recommendation the section
/// animates a collapse to zero height via `AnimatedSize` so shelves below
/// don't jump when data arrives.
///
/// Cover image source: `coverImageUrl` from the BE
/// (`/api/v1/app/recommendations/daily`, populated by PROD-1570 with a
/// type-mapped curated image and generic placeholder fallback).
class DailyDropSection extends ConsumerStatefulWidget {
  /// PROD-1979 — when true, the cover photo renders blurred while the
  /// "DAILY DROP" template overlay, title, and byline stay crisp.
  /// Tapping the card opens the shared login bottom sheet instead of
  /// routing to detail. The provider still runs — the BE returns a
  /// dummy drop for guest tokens so the layout is stable and the user
  /// sees what they're missing.
  final bool guestMode;

  const DailyDropSection({super.key, this.guestMode = false});

  @override
  ConsumerState<DailyDropSection> createState() => _DailyDropSectionState();
}

class _DailyDropSectionState extends ConsumerState<DailyDropSection> {
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _initialized) return;
      _initialized = true;
      final state = ref.read(dailyDropProvider);
      // If we land here with a stuck `isCtaProfiling` but the FE knows
      // profiling is done (e.g. the post-submit `initialize` raced ahead
      // of the BE catching up), force a re-init so the notifier takes
      // the "stale BE" branch and starts polling.
      final shouldReInit =
          state.isCtaProfiling &&
          ref.read(hasFinishedUserProfilingLocallyProvider);
      if (state.drop == null &&
          !state.isGenerating &&
          !state.isReady &&
          !state.isUnsupportedCity &&
          (!state.isCtaProfiling || shouldReInit)) {
        ref.read(dailyDropProvider.notifier).initialize();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(dailyDropProvider);

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: _buildBody(context, state),
    );
  }

  Widget _buildBody(BuildContext context, DailyDropState state) {
    // PROD-2036 / PROD-2045 — resolved city is outside the supported
    // launch markets. Hide the whole section (no card, no skeleton);
    // collapse via the surrounding `AnimatedSize`. Analytics still fires
    // once per session per surface from the notifier.
    if (state.isUnsupportedCity) {
      return const SizedBox.shrink();
    }

    // PROD-1988 — new-user profiling window: show the profiling CTA in the
    // daily-drop slot instead of the regular card. Render-time safety net:
    // if the FE knows profiling is finished (local gate set), never show
    // the CTA even if the BE is still returning `cta_profiling` — render
    // a skeleton while we wait for the BE to catch up.
    if (state.isCtaProfiling) {
      final hasFinishedLocally = ref.watch(
        hasFinishedUserProfilingLocallyProvider,
      );
      if (hasFinishedLocally) {
        return DiscoveryImageTemplateCard.skeleton();
      }
      return _DailyDropProfilingCtaCard(onTap: _onProfilingCtaTap);
    }

    if (state.drop == null) {
      // PROD-3730 — the drop is being generated right now. This used to
      // collapse the section, which left an on-demand user (no precomputed
      // drop, so nothing to push, so no reason to look anywhere else) staring
      // at a feed with no Daily Drop and no explanation. Say what's happening.
      if (state.isGenerating) {
        return _buildGeneratingCard(context);
      }
      // PROD-3730 — the poller gave up at its 2-minute cap. Distinct from a
      // transient error: the user watched us work and deserves an outcome.
      if (state.hasTimedOut) {
        return _buildTimedOutCard(context);
      }
      // A transient request failure stays silent — the drop is optional and
      // the notifier deliberately swallows errors. Collapse as before.
      if (state.hasError) {
        return const SizedBox.shrink();
      }
      // Pre-init / first fetch in flight: hold layout with a skeleton.
      return DiscoveryImageTemplateCard.skeleton();
    }

    final drop = state.drop!;

    // Resolved with no recommendation, or missing data we need to render
    // the card → collapse the section.
    if (!drop.hasRecommendation ||
        drop.title == null ||
        drop.coverImageUrl == null) {
      return const SizedBox.shrink();
    }

    final dateForTitle = _resolveDate(drop);

    // The ready card is no longer a photo card (Zé, 2026-08-27, Figma
    // `7285:24358`): it is the same frame the generating and timed-out states
    // use, so the slot stops changing species as the drop resolves. The drop's
    // cover and title now live behind the tap rather than on the card.
    //
    // PROD-1979 (guests) survives as the **tap**, not as a blur. The blur
    // existed to withhold the cover photo and title; this card shows neither,
    // so blurring it would obscure nothing and just look broken. Tap still
    // routes to the shared login sheet instead of the detail page.
    return DailyDropReadyCard(
      date: dateForTitle,
      onTap: widget.guestMode ? _onGuestTap : () => _onTap(drop),
    );
  }

  /// PROD-3730 — the working card, plus the push-nudge resolution behind it.
  ///
  /// `notificationPreferencesProvider` is watched **here** rather than at the
  /// top of `build` on purpose: that keeps its `GET /notifications/preferences`
  /// to users who are actually mid-generation, instead of firing on every
  /// Discovery mount for everyone.
  Widget _buildGeneratingCard(BuildContext context) {
    final l10n = Lt.of(context);
    final nudge = _resolveNudge();

    _trackGeneratingImpressionOnce(nudge);

    // No push on this platform → nothing to promise and nothing to ask, so
    // the card is inert (Decision 22).
    final isInert = nudge == DailyDropNudge.unavailable;

    // Headline only — Zé, 2026-08-10. The subtitle that carried the "a few
    // minutes" expectation and the "tap to be notified" hint is gone; both
    // still appear in the sheet.
    return DailyDropGeneratingCard(
      title: l10n.discoveryDailyDropGeneratingTitle,
      onTap: isInert ? null : () => _openWaitSheet(context, nudge),
    );
  }

  /// PROD-3730 — the failure card, which offers the same notifications ask as
  /// the generating card but for **tomorrow's** drop (Zé, 2026-08-10).
  Widget _buildTimedOutCard(BuildContext context) {
    final l10n = Lt.of(context);
    final nudge = _resolveNudge();
    final isInert = nudge == DailyDropNudge.unavailable;

    return DailyDropTimedOutCard(
      title: l10n.discoveryDailyDropTimedOutTitle,
      subtitle: l10n.discoveryDailyDropTimedOutSubtitle,
      onTap: isInert
          ? null
          : () => _openWaitSheet(
              context,
              nudge,
              occasion: DailyDropWaitOccasion.failedTryTomorrow,
            ),
    );
  }

  void _openWaitSheet(
    BuildContext context,
    DailyDropNudge nudge, {
    DailyDropWaitOccasion occasion = DailyDropWaitOccasion.generating,
  }) {
    FocusManager.instance.primaryFocus?.unfocus();
    unawaited(
      showDailyDropWaitSheet(context, ref, nudge: nudge, occasion: occasion),
    );
  }

  /// The resolved push-nudge state, honouring the GEN debug override.
  DailyDropNudge _resolveNudge() {
    final pushUi = ref.watch(pushPermissionServiceProvider);
    final prefsState = ref.watch(notificationPreferencesProvider);
    return resolveDailyDropNudge(
      permission: pushUi.permission,
      prefsLoaded: prefsState.hasLoadedOnce,
      dailyDropTypeEnabled: dailyDropTypeEnabledFrom(prefsState.preferences),
    );
  }

  /// One impression per mount per nudge state. The nudge can legitimately
  /// change while the card is up (the user grants permission from the sheet),
  /// and each distinct state is worth counting — but a rebuild storm is not.
  String? _trackedGeneratingNudge;
  void _trackGeneratingImpressionOnce(DailyDropNudge nudge) {
    if (_trackedGeneratingNudge == nudge.name) return;
    _trackedGeneratingNudge = nudge.name;
    // Post-frame: this runs from build(), and the analytics dispatch can
    // synchronously touch providers.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref
          .read(unifiedAnalyticsProvider)
          .trackDailyDropGeneratingImpression(pushState: nudge.name);
    });
  }

  DateTime _resolveDate(DailyDrop drop) {
    final iso = drop.generatedAt ?? drop.startAt ?? drop.date;
    if (iso != null) {
      try {
        return DateTime.parse(iso).toLocal();
      } catch (_) {
        /* fall through */
      }
    }
    return DateTime.now();
  }

  void _onTap(DailyDrop drop) {
    final analytics = ref.read(unifiedAnalyticsProvider);
    analytics.trackDailyDropOpen(
      recommendationId: drop.recommendationId,
      itemType: drop.itemType,
      category: drop.category,
    );

    // PROD-3951 — every ready drop opens the Daily Drop detail page, whether
    // or not it resolves to a local venue/event. This used to fork: local
    // picks went to `/venues|events/{id}` decorated with
    // `?from=daily-drop&dropId=`, and only an entity-less pick got a page of
    // its own.
    pushDailyDropDestination(context, drop);
  }

  void _onProfilingCtaTap() {
    FocusManager.instance.primaryFocus?.unfocus();
    ref.read(unifiedAnalyticsProvider).trackDailyDropProfilingCtaTap();
    // PROD-2566: attribute `profiling_started` to the daily-drop CTA.
    context.push('${AppRoutes.userProfilingFlow}?source=daily_drop_cta');
  }

  void _onGuestTap() {
    // PROD-1979 — tapping the (image-blurred) guest drop opens the
    // shared login bottom sheet (consistent with other guest-gated CTAs
    // via [requireAuth]). The `onAuthenticated` branch is unreachable
    // from this surface since we only wire this callback when
    // `guestMode` is true, but the helper still owns the analytics +
    // sheet flow.
    requireAuth(
      context,
      ref,
      action: Lt.of(context).guestDailyDropAction,
      referrer: AuthReferrer.guestGateHome,
      onAuthenticated: () {},
    );
  }
}

/// PROD-1988 — profiling-CTA card rendered in the Daily Drop slot when the
/// BE returns `cta_profiling` (new user, < 3 days since signup AND profiling
/// not completed). Matches the 399×213 / 6 px-radius footprint of
/// [DiscoveryImageTemplateCard] so adjacent shelves don't shift when the
/// section resolves. Visual is a sokoPink card with the canonical paper
/// texture overlay, the seated-and-reading Soko character top-center, and
/// a SeasonMix display title + Zalando subtitle stacked at the bottom.
class _DailyDropProfilingCtaCard extends StatelessWidget {
  final VoidCallback onTap;

  const _DailyDropProfilingCtaCard({required this.onTap});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: AspectRatio(
          aspectRatio: 399 / 213,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              fit: StackFit.expand,
              children: [
                Container(color: AppColors.sokoPink),
                // Dust/grain texture — source `Soko-texture-21.png`
                // (white speckles on a black field, derived-alpha so the
                // black drops to transparent). Sits cleanly on top of
                // the sokoPink card and gives the CTA a starlit-paper
                // feel that pairs with the curated profiling zine covers.
                IgnorePointer(
                  child: Image.asset(
                    'assets/images/textures/cover-texture-25.webp',
                    fit: BoxFit.cover,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 20),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Expanded(
                        child: Center(
                          child: Image.asset(
                            'assets/images/illustrations/soko-seating-and-reading.webp',
                            fit: BoxFit.contain,
                          ),
                        ),
                      ),
                      // PROD-2796: AutoSizeText so the headline renders fully
                      // for any locale / viewport width. Stays a single line
                      // and shrinks the font (down to a 16px floor) instead of
                      // ellipsising at the fixed 28px — the card is a
                      // fixed-proportion box (AspectRatio 399/213) so longer
                      // strings on narrow phones would otherwise get clipped.
                      // Mirrors the zine-cover title pattern in
                      // list_zine_cover.dart (_TitleText).
                      AutoSizeText(
                        l10n.discoveryDailyDropProfilingCtaHeadline,
                        textAlign: TextAlign.center,
                        maxLines: 1,
                        minFontSize: 16,
                        stepGranularity: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.displayPrimary(
                          fontSize: 28,
                          fontWeight: FontWeight.w400,
                          color: AppColors.sokoInk,
                          height: 1.0,
                        ),
                      ),
                      const SizedBox(height: 6),
                      AutoSizeText(
                        // PROD-2796: balance the 2-line wrap so it splits in the
                        // middle of the sentence instead of dropping a lone word
                        // onto line 2. Locale-generic (see balancedTwoLineBreak);
                        // AutoSizeText still shrinks as a last resort.
                        balancedTwoLineBreak(
                          l10n.discoveryDailyDropProfilingCtaSubtitle,
                        ),
                        textAlign: TextAlign.center,
                        maxLines: 2,
                        minFontSize: 11,
                        stepGranularity: 1,
                        overflow: TextOverflow.ellipsis,
                        style: AppTheme.body(
                          fontSize: 14,
                          fontWeight: FontWeight.w300,
                          color: AppColors.sokoInk,
                          height: 1.25,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
