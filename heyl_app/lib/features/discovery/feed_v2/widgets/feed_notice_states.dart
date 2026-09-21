// PROD-4286 — the two states the feed can land in that are not a feed.
//
// Before this, both were the same non-answer: `_FeedError` rendered
// `Text('$error')` — the raw `DioException`/`NotFoundException` string, in
// English, with no retry — and a feed that produced zero blocks drew an empty
// `SliverList`, i.e. a blank page.
//
// ⚠️ **[FeedEmptyState]'s copy is neutral, and that is a constraint rather than
// a preference.** The client cannot tell these apart:
//
//   * a location outside seeded coverage (PROD-4290 will answer that with an
//     `unknown_area` block, but an app older than PROD-4288 skips it — rule 1
//     of the feed contract — and lands here instead);
//   * a city we *do* know that simply has nothing this week (which is exactly
//     what PROD-4290 sends `blocks: []` for, by design — Zé, 2026-09-08);
//   * a page whose blocks are all types this build cannot render.
//
// All three arrive as "zero renderable blocks" and nothing distinguishes them.
// Writing "I don't know this area" here would be the app inventing a diagnosis
// it does not have — the same failure `feed_complete` exists to prevent
// (PROD-4236: the app never renders an end-of-feed card on its own initiative).
// "Nothing to show (yet)" claims only what is observably true.
//
// The *reason* is the backend's to give, and it gives it by sending a block.

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/services/location_service.dart';
import '../../../../core/services/unified_analytics_service.dart';
import '../../../../core/utils/auth_gating.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../providers/location_provider.dart';
import '../../../../shared/utils/search_location_picker.dart';
import '../../../../shared/widgets/browser_instructions_sheet.dart';
import '../../../../shared/widgets/soko_cta_button.dart';
import '../providers/feed_chrome_providers.dart';
import '../providers/feed_home_provider.dart';

/// Illustration for both states, and for the `unknown_area` block (PROD-4288).
///
/// `soko-seating-and-reading.webp` rather than `soko-binoculars.png`: the
/// binoculars figure is already `banner_chat`'s art
/// (`FeedImage.assetRegistry`), and PROD-4290 emits that banner directly below
/// the out-of-coverage block — the same drawing twice, 100 px apart. This one
/// is also 506×494, so it has the resolution to render at 115 without the 1×
/// softness the binoculars PNG (134×124) would have had.
const String kFeedNoticeAsset =
    'assets/images/illustrations/soko-seating-and-reading.webp';

/// Rendered size of [kFeedNoticeAsset]. Square source, so 115 on both axes —
/// the same tile size `DiscoveryFooter` uses, which is what makes these read as
/// members of the same family rather than a new visual idea.
const double kFeedNoticeAssetSize = 115;

/// Illustration + heading + body + actions, centred.
///
/// **Deliberately not `DiscoveryFooter`'s chrome**, which `feed_complete`
/// reuses. That is a page full-stop — a tile plus one 42 px line — and it
/// works for "É tudo, malta" because that is three words. These states need a
/// heading *and* a body *and* buttons, and at 42 px the heading alone wraps to
/// three lines. Shared instead: the asset size and the type family.
///
/// PROD-4288's `unknown_area` block is the third caller — same shell, its own
/// actions (the suggested-city chips).
class FeedNotice extends StatelessWidget {
  /// Heading. One short line; wraps rather than clips.
  final String title;

  /// Supporting line under [title]. Optional — the `unknown_area` block may
  /// arrive without a subtitle.
  final String? body;

  /// The action row. Null renders the notice with nothing to do, which is a
  /// legitimate state for a server-supplied block that carried no suggestions.
  final Widget? actions;

  /// Space above the illustration.
  ///
  /// **40 is the BLOCK value and stays the default**, because that is what the
  /// `unknown_area` block needs: there it is one block among others and this is
  /// its separation from the one above.
  ///
  /// A page-level state has no block above it — only the page chrome, which has
  /// already contributed `kFeedPageBlockGap` (30) before this widget is built.
  /// Keeping 40 there stacked to 70 px of emptiness under the filter row (Zé, on
  /// device 2026-09-09), so the three full-page states pass 0 and land exactly
  /// one block-gap below the chrome, which is the page's own rhythm.
  final double topPadding;

  const FeedNotice({
    super.key,
    required this.title,
    this.body,
    this.actions,
    this.topPadding = 40,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final ink = isDark ? AppColors.sokoPaper : AppColors.sokoInk;
    final muted = isDark ? AppColors.sokoShade4 : AppColors.sokoShade3;

    return Padding(
      padding: EdgeInsets.only(top: topPadding, bottom: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Image.asset(
            kFeedNoticeAsset,
            width: kFeedNoticeAssetSize,
            height: kFeedNoticeAssetSize,
            fit: BoxFit.contain,
          ),
          const SizedBox(height: 18),
          Text(
            title,
            textAlign: TextAlign.center,
            style: AppTheme.displayPrimary(
              fontSize: 24,
              fontWeight: FontWeight.w300,
              color: ink,
              height: 1.1,
            ),
          ),
          if (body != null && body!.isNotEmpty) ...[
            const SizedBox(height: 8),
            ConstrainedBox(
              // The body reads as a caption under the heading, not as a
              // full-bleed paragraph. 260 keeps it to ~2 lines at the default
              // scale on a 430 pt frame and lets it grow to 3 at 1.3×, which
              // is the app-wide font-scale ceiling (design-system-rules § 9).
              constraints: const BoxConstraints(maxWidth: 260),
              child: Text(
                body!,
                textAlign: TextAlign.center,
                style: AppTheme.body(fontSize: 15, color: muted, height: 1.35),
              ),
            ),
          ],
          if (actions != null) ...[const SizedBox(height: 22), actions!],
        ],
      ),
    );
  }
}

/// Shown when the feed renders **zero** blocks, for any reason.
///
/// See the neutrality note at the top of this file before changing the copy.
class FeedEmptyState extends ConsumerWidget {
  const FeedEmptyState({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    return FeedNotice(
      // Page-level state: the chrome's block gap is the only space needed.
      topPadding: 0,
      title: l10n.feedEmptyStateTitle,
      body: l10n.feedEmptyStateBody,
      actions: Row(
        children: [
          Expanded(
            child: SokoCtaButton(
              label: l10n.feedEmptyStateChangeArea,
              // The one place the picker is opened from — a second opener
              // would fork the C-vs-U TTL rule, the tier normalization and the
              // active-chat commit that helper carries.
              onPressed: () => openSearchLocationPicker(context, ref),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SokoCtaButton(
              label: l10n.feedRetry,
              variant: SokoCtaVariant.ghost,
              onPressed: () => ref.invalidate(feedHomeProvider),
            ),
          ),
        ],
      ),
    );
  }
}

/// PROD-4301 — shown when **no location resolved at all**, so no feed request
/// was ever made.
///
/// Distinct from its two neighbours on purpose, and the distinction is the
/// whole feature:
///
///  * [FeedEmptyState] — we HAVE a location, it returned nothing.
///  * [FeedErrorState] — the request failed (timeout, 5xx, offline).
///  * this — we do not know where the user is, so there was nothing to ask.
///
/// Before this existed the no-location case fell into [FeedErrorState] via the
/// contract's 400, which offered **Retry** — a button that could never succeed,
/// because nothing about the next request would differ. So there is
/// deliberately no Retry here: the only move that changes anything is choosing
/// an area, and it is the only one offered.
class FeedNoLocationState extends ConsumerWidget {
  const FeedNoLocationState({super.key});

  /// Ask the OS for location, and fall back to whatever the platform still
  /// allows when it will not ask again.
  ///
  /// Same shape as chat's share-location handler — request first, then diverge
  /// by platform on refusal, because the OS prompts once and the browser never
  /// re-prompts after a denial.
  ///
  /// **Nothing here rebuilds the feed by hand.** `feedLocationGateProvider`
  /// watches the resolved location, so a granted permission that produces a fix
  /// flips the gate and the feed builds on its own. That is the derive-not-latch
  /// rule doing its job — and it is also why a grant that resolves *nothing*
  /// (a fix outside boundary coverage, PROD-4302) correctly leaves this state
  /// up with the area picker still offered.
  Future<void> _enableGps(BuildContext context, WidgetRef ref) async {
    final status = await ref
        .read(locationProvider.notifier)
        .requestPermissionOnly();
    if (status == LocationPermissionStatus.granted) return;
    if (!context.mounted) return;

    if (kIsWeb) {
      // No app-settings screen exists on web and the browser will not prompt
      // twice, so instructions are the only move left.
      await showBrowserLocationInstructions(context: context, ref: ref);
    } else {
      // The OS prompt has been spent; Settings is where it can still change.
      // `openSettings` picks app-settings vs location-settings by status.
      await ref.read(locationProvider.notifier).openSettings();
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);

    // Only when the device has not granted it. A permission-granted user in
    // this state is here for a different reason — an uncovered area, say — and
    // offering to turn on something already on would be noise.
    //
    // `null` means nothing has checked yet; treated as not-granted so the
    // affordance appears rather than hiding behind an unknown. Requesting when
    // already granted is idempotent, so the failure mode is a harmless extra
    // button, not a broken one.
    final granted = ref.watch(feedGpsPermissionGrantedProvider);

    return FeedNotice(
      // Page-level state: the chrome's block gap is the only space needed.
      topPadding: 0,
      title: l10n.feedNoLocationTitle,
      body: l10n.feedNoLocationBody,
      actions: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!granted) ...[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 200),
              child: SokoCtaButton(
                label: l10n.feedNoLocationEnableGps,
                // Pink, not the profiling step's green (Zé, on device
                // 2026-09-09): this sits on `sokoPaper` beside a pink-outline
                // sibling, and green read as a foreign accent there.
                variant: SokoCtaVariant.pink,
                onPressed: () => _enableGps(context, ref),
              ),
            ),
            const SizedBox(height: 8),
          ],
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: SokoCtaButton(
              label: l10n.feedNoLocationCta,
              // Secondary once GPS is on offer: picking an area always works,
              // but letting the device answer is the better outcome when it can.
              // Pink outline (D253's "pink as an accent, not a default fill")
              // while GPS is on offer, so the pair reads as primary + secondary
              // rather than two equal fills. Alone, it takes the solid pink and
              // becomes the primary action.
              variant: granted
                  ? SokoCtaVariant.pink
                  : SokoCtaVariant.pinkOutline,
              // The same single opener [FeedEmptyState] uses — a second one
              // would fork the C-vs-U TTL rule, the tier normalization and the
              // active-chat commit that helper carries.
              onPressed: () => openSearchLocationPicker(context, ref),
            ),
          ),
        ],
      ),
    );
  }
}

/// PROD-4445 — shown to a **signed-out** visitor on the *Pessoas* filter.
///
/// ⚠️ **Server-driven since PROD-4520**, and this doc used to say the exact
/// opposite. PROD-4445 shipped it as the one member of this family that was not
/// about what the server said — it was about *not asking*: no request was
/// issued for a guest on this filter at all (D9), which is what let the backend
/// skip building a guest path for `filter=people`.
///
/// The backend has since built that path. The app now calls `/feed/home` for a
/// guest like any other filter and renders this when the answer contains a
/// `sign_in_gate` block, through `FeedSignInGateBlock` and the ordinary
/// dispatcher. The client-side predicate that used to decide it
/// (`feedGuestGateProvider`) and all six of its wirings are gone.
///
/// **Nothing the reader sees changed.** The illustration, the copy and the CTA
/// below are PROD-4445's, unmodified — only the trigger moved.
///
/// Copy is Zé's, from the mockup round (Variant C, value-first): it says what
/// the reader gets, not what they are being denied.
///
/// ⚠️ **Deliberately not `GuestFeaturePlaceholder`**, the app's older
/// sign-in-gate widget (Memories, chat history). That one predates the design
/// system — bare Material `TextButton`, `AppColors.primary`, its own dark-mode
/// branch — and copying it here would drag all three onto the feed.
///
/// The CTA navigates hard rather than opening the login prompt sheet: this
/// surface **is** the explanation of the gate, so the sheet would explain it
/// twice. `navigateToLoginPreservingReturn` rather than a bare
/// `context.push(AppRoutes.login)` — a direct push leaves `returnUrlProvider`
/// null and the OAuth round-trip drops the reader on `/home` instead of back
/// here.
class FeedSignInGateState extends ConsumerWidget {
  const FeedSignInGateState({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    return FeedNotice(
      // Page-level state: the chrome's block gap is the only space needed.
      topPadding: 0,
      title: l10n.feedSignInGateTitle,
      body: l10n.feedSignInGateBody,
      actions: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 200),
        child: SokoCtaButton(
          // Its own key rather than `authButtonSignIn`: the feed's CTAs are
          // sentence case ("Mudar de área"), the auth screen's own button is
          // title case, and this is the copy Zé specified for this surface.
          label: l10n.feedSignInGateCta,
          onPressed: () => navigateToLoginPreservingReturn(
            context,
            ref,
            referrer: AuthReferrer.guestFeedPeople,
          ),
        ),
      ),
    );
  }
}

/// Shown when the feed request itself failed — a timeout, a 5xx, offline.
///
/// PROD-4290 removes the out-of-coverage 404 from this path, but nothing else
/// that reaches it.
///
/// [error] is **never rendered and never logged from here.** Logging it in
/// `build` looked harmless and was not: `build` re-runs on any unrelated
/// rebuild, so one failure would print repeatedly, and the raw
/// `DioException` string would keep reaching logs the UI had just stopped
/// showing (codex, 2026-09-08). The screen logs it once, on the transition
/// into the error state, via `ref.listen`.
class FeedErrorState extends ConsumerWidget {
  /// Carried for the widget's own identity and for tests — deliberately not
  /// rendered, and deliberately not logged here.
  final Object error;

  const FeedErrorState({super.key, required this.error});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    return FeedNotice(
      // Page-level state: the chrome's block gap is the only space needed.
      topPadding: 0,
      title: l10n.feedErrorStateTitle,
      body: l10n.feedErrorStateBody,
      actions: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 200),
        child: SokoCtaButton(
          label: l10n.feedRetry,
          onPressed: () => ref.invalidate(feedHomeProvider),
        ),
      ),
    );
  }
}
