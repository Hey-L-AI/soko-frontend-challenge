import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart' show AppRoutes;
import '../../core/theme/app_colors.dart';
import '../../features/product_tour/providers/product_tour_controller.dart';
import '../../features/product_tour/providers/product_tour_keys_provider.dart';
import '../../features/product_tour/widgets/tour_spotlight.dart';
import '../../l10n/generated/l10n.dart';
import '../../providers/auth_provider.dart' show isAuthenticatedProvider;
import 'action_bar_location_pill.dart';
import 'bt_sq_ico.dart';
import 'circle_icon_button.dart';

/// Shared action bar: magnifier (search) + "Cria nova zine" + location pill.
///
/// One widget instance powers both `/discovery` and `/lists` (and any future
/// surface that needs the same 3-button row). The visual is fixed in v0
/// (YAGNI — no `trailing` slot or builder pattern yet); when a real need
/// arises to differ per host, refactor.
///
/// Search overlay state is owned by the host:
/// - [showSearchOverlay]: when true, [searchOverlay] is rendered in place of
///   the idle row, swapped with the same animation the bar uses today.
/// - [onSearchTap]: fired when the user taps the magnifier — the host
///   flips its own "search open" state to true and provides the overlay.
/// - The host owns close behavior too; the overlay it provides is
///   responsible for rendering its X button and clearing host state.
///
/// Location pill is internal — opens [showLocationScopePicker], writes to
/// [cityScopeProvider]. Same behavior across all hosts.
///
/// Source-of-truth design: Figma `3972:4238` (Soko -- shared,
/// `d4BCnyUHe2705J7ecQtaIH`) — see
/// `docs/ui/figma-cache/screens/discovery/action-bar.md`.
class CityActionBar extends ConsumerWidget {
  /// Tap on the magnifier in idle state. Host flips its own search-open
  /// state and provides a [searchOverlay].
  final VoidCallback onSearchTap;

  /// When true, [searchOverlay] is rendered in place of the idle row.
  /// Driven by the host's own search-open provider (forked per surface).
  final bool showSearchOverlay;

  /// Widget rendered in place of the idle row when [showSearchOverlay] is
  /// true. Typically a search input + tabs/results filter chrome; owns its
  /// own debounce, controller, focus, and X-close behavior.
  final Widget? searchOverlay;

  /// Tap on the "Cria nova zine" pill. Defaults to pushing
  /// [AppRoutes.discoveryListCreate] — the canonical create-zine route,
  /// shared between /discovery and /lists. Override to redirect the
  /// affordance elsewhere.
  final VoidCallback? onCreateZineTap;

  /// When false, the location pill is omitted from the idle row — the
  /// remaining magnifier + create-zine pill take the full width. Used by
  /// `/yours` (PROD-2145), which no longer scopes its content by city.
  final bool showLocationPill;

  /// Visual variant for the create-zine pill. Defaults to
  /// [BtSqIcoVariant.shade5] (matches the magnifier circle on
  /// `/discovery` for a uniform low-emphasis treatment). `/yours`
  /// overrides to [BtSqIcoVariant.yellow] (PROD-2145) so the CTA carries
  /// the primary visual weight on a pill-less bar — same yellow used by
  /// the `_YoursEmptyState` "Create your first zine!" hero.
  final BtSqIcoVariant createZineVariant;

  /// PROD-2221 — when `false`, the "Cria nova zine" pill is omitted from
  /// the idle row entirely. `/discovery` flips this off; `/yours` keeps
  /// it on (the pill is the surface's primary CTA).
  final bool showCreateZinePill;

  /// PROD-2221 — when non-null, the leading search affordance becomes a
  /// `BtSqIco` pill with this label instead of the bare
  /// [CircleIconButton] magnifier. `/discovery` passes "Discover the
  /// city" so the search entry reads as a CTA; `/yours` leaves it null
  /// and keeps the circle.
  final String? searchPillLabel;

  /// PROD-2221 — visual variant for the search pill when
  /// [searchPillLabel] is non-null. Discovery passes
  /// [BtSqIcoVariant.lilac] so the pill paints purple.
  final BtSqIcoVariant searchPillVariant;

  /// Optional trailing-action slot rendered at the right edge of the
  /// legacy (`/yours`) layout, after the create-zine pill. Used by
  /// `/yours` to mount the "My reminders" button next to the
  /// create-zine CTA without forking the action-bar widget.
  ///
  /// Ignored on the search-pill layout (used by `/discovery`) — that
  /// surface already exposes the equivalent affordance via
  /// `DiscoveryEndActions` and we don't want it to appear twice.
  final Widget? trailingAction;

  const CityActionBar({
    super.key,
    required this.onSearchTap,
    this.showSearchOverlay = false,
    this.searchOverlay,
    this.onCreateZineTap,
    this.showLocationPill = true,
    this.createZineVariant = BtSqIcoVariant.shade5,
    this.showCreateZinePill = true,
    this.searchPillLabel,
    this.searchPillVariant = BtSqIcoVariant.lilac,
    this.trailingAction,
  });

  void _defaultCreateZineTap(BuildContext context) {
    context.push(AppRoutes.discoveryListCreate);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDesktop = MediaQuery.of(context).size.width >= 1024;

    // PROD-1953: previous pair was AnimatedSize(250 easeInOut) wrapping
    // AnimatedSwitcher(200 easeOut/In) — two animations on different
    // controllers and curves, causing the height to keep settling after
    // the cross-fade so the input visibly snapped when growing/shrinking.
    // Now a single AnimatedSwitcher drives both size and opacity through
    // one controller (SizeTransition + FadeTransition share `animation`),
    // anchored at the top so the bar grows downward. The inactive child
    // is unmounted after switch-out, matching the prior testable behavior.
    Widget bar = AnimatedSwitcher(
      duration: const Duration(milliseconds: 260),
      switchInCurve: Curves.easeOutCubic,
      switchOutCurve: Curves.easeInCubic,
      transitionBuilder: (child, animation) {
        return SizeTransition(
          sizeFactor: animation,
          axisAlignment: -1.0,
          child: FadeTransition(opacity: animation, child: child),
        );
      },
      layoutBuilder: (currentChild, previousChildren) {
        return Stack(
          alignment: Alignment.topCenter,
          children: [
            ...previousChildren,
            if (currentChild != null) currentChild,
          ],
        );
      },
      child: showSearchOverlay && searchOverlay != null
          ? KeyedSubtree(key: const ValueKey('search'), child: searchOverlay!)
          : KeyedSubtree(
              key: const ValueKey('idle'),
              child: _IdleRow(
                onSearchTap: onSearchTap,
                onCreateZineTap: () =>
                    (onCreateZineTap ?? () => _defaultCreateZineTap(context))(),
                showLocationPill: showLocationPill,
                showCreateZinePill: showCreateZinePill,
                createZineVariant: createZineVariant,
                searchPillLabel: searchPillLabel,
                searchPillVariant: searchPillVariant,
                trailingAction: trailingAction,
              ),
            ),
    );

    // Mirror the chat-bar's desktop cap so the two rows align on wide
    // viewports until dedicated desktop designs land.
    if (isDesktop) {
      bar = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: bar,
        ),
      );
    }

    return bar;
  }
}

// ---------------------------------------------------------------------------
// Idle row — magnifier + create-zine pill + location pill.
// ---------------------------------------------------------------------------

class _IdleRow extends ConsumerWidget {
  final VoidCallback onSearchTap;
  final VoidCallback onCreateZineTap;
  final bool showLocationPill;
  final bool showCreateZinePill;
  final BtSqIcoVariant createZineVariant;
  final String? searchPillLabel;
  final BtSqIcoVariant searchPillVariant;
  final Widget? trailingAction;

  const _IdleRow({
    required this.onSearchTap,
    required this.onCreateZineTap,
    required this.showLocationPill,
    required this.showCreateZinePill,
    required this.createZineVariant,
    required this.searchPillLabel,
    required this.searchPillVariant,
    required this.trailingAction,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    // PROD-1979 — hide the create-zine pill for guests. The /discovery/
    // lists/new route is gated separately as a backstop for direct URL
    // hits, but the affordance shouldn't appear in the action bar at
    // all (the create menu sheet is the single primary entry point and
    // it's hidden for guests as well).
    final isGuest = !ref.watch(isAuthenticatedProvider);
    // PROD-2221 — Discovery flips [searchPillLabel] non-null (the pill
    // replaces the 40-px magnifier circle and reads as a labeled CTA)
    // and [showCreateZinePill] off (the create-zine affordance lives
    // elsewhere). Together those collapse the idle row to a single pair
    // of pills: [search pill] [location pill]. `/yours` keeps the
    // legacy magnifier circle + create-zine pill.
    final useSearchPill = searchPillLabel != null;
    final showCreateZine = showCreateZinePill && !isGuest;

    final tourKeys = ref.watch(productTourKeysProvider);

    final createZineLabel = l10n.discoveryActionBarCreateZine;
    // PROD-4167 — the step-4 tour highlight is gone: that step now lands
    // on `/library`, where this bar isn't mounted.
    final createZinePill = BtSqIco(
      icon: LucideIcons.circle_plus,
      label: createZineLabel,
      variant: createZineVariant,
      onTap: onCreateZineTap,
    );

    // PROD-2221 — the labeled search pill that replaces the circle when
    // [searchPillLabel] is non-null. `expand: true` so its inner Row
    // fills the parent `Expanded` and the label centers within the
    // pill's allotted width. The TourSecondaryHighlight here lights up
    // ONLY after the tour cursor has finished moving and is hovering
    // over this pill (the searchBar → discoverCity transition). Per
    // user spec (2026-05-30): the rectangle must NOT lead the hand
    // while it's still travelling — it's summoned by the hand's
    // arrival, then draws around the pill. Reads
    // [tourCursorArrivedProvider] (set after the move duration
    // completes) rather than [tourCursorTargetProvider] (set at the
    // start of the move).
    final cursorOnPill =
        ref.watch(tourCursorArrivedProvider) == CursorTarget.discoverCityPill;
    final searchPill = useSearchPill
        ? TourSecondaryHighlight(
            activeOnSteps: const {},
            extraActive: cursorOnPill,
            borderRadius: 22,
            child: KeyedSubtree(
              key: tourKeys.discoverCity,
              child: BtSqIco(
                icon: LucideIcons.search,
                label: searchPillLabel!,
                variant: searchPillVariant,
                onTap: onSearchTap,
                expand: true,
              ),
            ),
          )
        : null;

    // The location pill (Soko/Pink "City, ISO2") owns its own responsive
    // cascade — see [ActionBarLocationPill]. We just compute the budget
    // it gets from the parent's LayoutBuilder, after subtracting whatever
    // other controls in the row need.
    return LayoutBuilder(
      builder: (context, constraints) {
        final rowWidth = constraints.maxWidth;
        final locationAvailableWidth = showLocationPill
            ? _locationPillBudget(
                rowWidth: rowWidth,
                hasSearchCircle: !useSearchPill,
                leadingPillLabel: useSearchPill
                    ? searchPillLabel!
                    : (showCreateZine ? createZineLabel : null),
                // Reserve the 36-px width of `MyRemindersButton`
                // (matches `NotificationsTopButton`) + the 6-px
                // separator. Only the `/yours` layout actually renders
                // the trailing action, but the budget rules apply
                // uniformly — passing it here keeps the location pill
                // honest if a future caller mixes both.
                hasTrailingAction: !useSearchPill && trailingAction != null,
              )
            : 0.0;
        final locationPill = showLocationPill
            ? ActionBarLocationPill(availableWidth: locationAvailableWidth)
            : null;
        // PROD-2221 — Discovery layout (search pill, no create-zine):
        //   [Expanded(searchPill)] [SizedBox(6)] [locationPill]
        // The search pill is the only flexible child; it grows to fill
        // the gap between the left edge and the location pill.
        if (useSearchPill) {
          return Row(
            children: [
              Expanded(child: searchPill!),
              if (locationPill != null) ...[
                const SizedBox(width: 6),
                locationPill,
              ],
            ],
          );
        }
        // `/yours` legacy layout: magnifier circle + (optional create-zine)
        // + (optional trailing action) + (optional location pill).
        return Row(
          children: [
            CircleIconButton(
              icon: LucideIcons.search,
              background: AppColors.sokoShade5,
              iconColor: AppColors.sokoInk,
              semanticLabel: l10n.discoveryActionBarSearchLabel,
              onTap: onSearchTap,
            ),
            if (showCreateZine) ...[
              if (locationPill != null) ...[
                const SizedBox(width: 6),
                Expanded(child: createZinePill),
              ] else ...[
                const Spacer(),
                createZinePill,
              ],
            ] else if (locationPill != null)
              const Spacer(),
            if (trailingAction != null) ...[
              const SizedBox(width: 6),
              trailingAction!,
            ],
            if (locationPill != null) ...[
              const SizedBox(width: 6),
              locationPill,
            ],
          ],
        );
      },
    );
  }

  /// Computes how much horizontal room the location pill gets. Reserves
  /// the natural widths of every other control in the row so their
  /// labels never ellipsize — the location pill is the one that yields
  /// (PROD-2145 + PROD-2221).
  double _locationPillBudget({
    required double rowWidth,
    required bool hasSearchCircle,
    required String? leadingPillLabel,
    bool hasTrailingAction = false,
  }) {
    const hPadding = 28.0; // BtSqIco horizontal padding (14 + 14)
    const iconChrome = 22.0; // icon (14) + gap (8)
    const searchCircle = 40.0;
    const trailingActionCircle = 36.0;
    const gapBetweenSearchAndLeadingPill = 6.0;
    const gapBeforeLocationPill = 6.0;
    const gapBeforeTrailingAction = 6.0;
    const labelStyle = TextStyle(
      fontSize: 14,
      fontWeight: FontWeight.w300,
      height: 1.2,
      letterSpacing: -0.14,
    );

    double measure(String text) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: labelStyle),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      return tp.width;
    }

    double reserved = gapBeforeLocationPill;
    if (hasSearchCircle) reserved += searchCircle;
    if (leadingPillLabel != null) {
      reserved += measure(leadingPillLabel) + iconChrome + hPadding;
      if (hasSearchCircle) reserved += gapBetweenSearchAndLeadingPill;
    }
    if (hasTrailingAction) {
      reserved += trailingActionCircle + gapBeforeTrailingAction;
    }
    return (rowWidth - reserved).clamp(60.0, rowWidth);
  }
}
