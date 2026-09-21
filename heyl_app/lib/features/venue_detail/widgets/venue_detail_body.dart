import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/orientation_utils.dart';
import '../../../data/models/entity_signal.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/shared_by_attribution.dart';
import '../../../shared/widgets/lazy_mount.dart';
import '../../../shared/widgets/soko_card_image.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../../shared/widgets/soko_photo_collage.dart';
import '../../../shared/widgets/soko_pop_in.dart';
import '../../../shared/widgets/soko_reveal_on_settle.dart';
import '../../entity_signals/widgets/signal_chips_section.dart';
import '../../entity_signals/widgets/interested_row.dart';
import '../../venue_claim/providers/venue_claim_provider.dart';
import '../../venue_claim/widgets/venue_claim_cta.dart';
import '../../venue_claim/widgets/venue_owner_affordance.dart';
import '../../../shared/widgets/view_item_tracker.dart';
import '../../share/widgets/detail_share_cell.dart';
import '../providers/venue_detail_provider.dart';
import '../utils/venue_share.dart';
import 'soko_save_button.dart';
import 'venue_action_grid.dart';
import 'venue_appears_in_shelf.dart';
import 'venue_details_grid.dart';
import 'venue_events_here_section.dart';
import 'venue_inline_actions.dart';
import 'venue_map_block.dart';
import 'venue_tag_row.dart';

/// The body composition of the venue detail page — section column,
/// gating, and spacing. Public widget so the list-embed wrapper (the
/// in-list "Vê mais" detail card on the list page) can mount the same
/// body inside its own scaffold without duplicating the layout.
///
/// Two modes, gated by [embedded] (default `false`):
///   - **Full-screen** (`embedded: false`) — the standalone screen mode.
///     Renders the 71 px top inset, the bottom-nav clearance padding,
///     and the back-button row. This is what [VenueDetailScreen] mounts.
///   - **Embedded**    (`embedded: true`)  — for the in-list detail card.
///     All three pieces above are toggled off; the embedding wrapper is
///     responsible for its own chrome (card bounds, background paint,
///     close affordance). The section column itself is identical between
///     the two modes.
///
/// A `ConsumerWidget` — the loading/error switch still lives on the host (e.g.
/// [VenueDetailScreen]); this reads the resolved snapshot and overlays any
/// in-flight owner edit (via [ownerMergedVenue]) so a just-saved change shows
/// on every owner-editable surface. It owns the **`view_item` analytics** (via
/// the wrapping [ViewItemTracker]) so every host — full screen, in-list detail,
/// map sheet — fires the view exactly when the full detail is shown.
class VenueDetailBody extends ConsumerWidget {
  final VenueDetailSnapshot snapshot;

  /// Toggles full-screen chrome off (top inset, bottom-nav clearance,
  /// back-button row). Default `false` keeps full-screen behaviour for
  /// existing callers.
  final bool embedded;

  /// PROD-3219 — overrides the save button's `list_item_add` source. Null keeps
  /// the default ([ListSource.detail]); the Map page passes [ListSource.map] so
  /// map-origin saves are attributable.
  final String? listAddSource;

  /// PROD-3888 — onboarding "vibe" preview. When true the body keeps the in-app
  /// taste actions live (Save + 👍/👎) but suppresses every external link
  /// (site/maps/phone/share) and cross-screen nav (events-here, appears-in,
  /// claim/edit/report); the launcher/nav content (hero, details phone, map) is
  /// wrapped in [IgnorePointer]. Default `false` — normal callers untouched.
  final bool sandbox;

  /// When true, setting a 👍/👎 in the thumb row auto-closes this detail (a
  /// quick triage gesture that drops the user back where they came from).
  /// Opt-in per presenter — the pushed screen, the bottom sheet, and the
  /// onboarding sandbox page pass `true`; the embedded in-list detail card
  /// (which has no route to pop) leaves it `false`. Toggling a sentiment back
  /// off never closes. Default `false`.
  final bool closeOnSignal;

  /// What the sheet-preview "See full detail" CTA does. Sheet hosts that can
  /// expand IN PLACE (the chat/results sibling sheet) pass a handler that grows
  /// the sheet to full and morphs this body into the full detail. When null the
  /// CTA falls back to opening the full-screen route directly (the map pin
  /// sheet). Only relevant in the sheet preview ([compactHeader]).
  final VoidCallback? onSeeFullDetail;

  /// Compact header for the map pin-tap sheet: instead of the full-width hero
  /// on top of the name block, the small square thumbnail sits *beside* the
  /// name/tags/description (side-by-side), with the Save/Share/👍/👎 action row
  /// full-width beneath. Keeps the map visible behind a shorter sheet. Only the
  /// map sheet passes `true`; the full-screen `/venues` page keeps its big hero.
  final bool compactHeader;

  const VenueDetailBody({
    super.key,
    required this.snapshot,
    this.embedded = false,
    this.listAddSource,
    this.sandbox = false,
    this.closeOnSignal = false,
    this.compactHeader = false,
    this.onSeeFullDetail,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Top padding is owned by `DiscoveryShell.PinnedPageChrome` — the
    // shell reserves the chrome's height (incl. safe area) above the
    // page body, so the body itself starts at 0 padding regardless of
    // embedded vs full-screen.
    final topPad = 0.0;
    final bottomPad = embedded
        ? 0.0
        : OrientationUtils.bottomNavClearance(context) + 16;
    // Overlay any in-flight owner edit so the details grid + `hasDetails` gate
    // below reflect a just-saved change (opening hours, phone, …) immediately —
    // the detail fetch is not re-issued in-session, so the raw snapshot would
    // otherwise keep showing the pre-edit value. Mirrors [_NameAndTagBlock].
    final venue = ownerMergedVenue(ref, snapshot.venue);
    // PROD-4074 — the hero is now [SokoPhotoCollage]. `images` collapses to
    // `[imageUrl]` today (single-image backend), so a lone photo renders
    // centred and the gate stays equivalent to the old `imageUrl` one; a real
    // multi-image array (PROD-1676) lights up the collage with no app release.
    final heroImages = venue.images;
    final hasHero = heroImages.isNotEmpty;
    // Note: `venue.address` (street) is intentionally excluded — the details
    // grid shows city/area, not the street address, so an address-only venue
    // has nothing to render here (see VenueDetailsGrid).
    final hasDetails =
        (venue.phone ?? '').isNotEmpty ||
        (venue.city ?? '').isNotEmpty ||
        (venue.openingHours?.isNotEmpty ?? false);
    final hasFullDescription = (venue.descriptionLong ?? '').isNotEmpty;
    // PROD-3134 — "Shared by <user>" credit for user-created venues. Only
    // present when the BE resolves a creator (`shared_by`); system/scraped
    // venues carry null and render nothing here.
    final hasSharedBy = venue.sharedBy != null;
    final hasEvents = venue.upcomingEvents.isNotEmpty;
    final hasMap = venue.latitude != null && venue.longitude != null;
    final hasAppearsIn = venue.socialProof.lists.isNotEmpty;
    // Mount the note surface for any in-list view; the widget reads the tip +
    // ownership live and decides visibility (owner-editable, non-owner
    // read-only, or hidden when there's nothing to show). The Save button
    // moved up next to the venue name (intentional Figma divergence).
    final showInlineActions = snapshot.effectiveListId != null;

    // Vertical rhythm — Figma `6181:5531` (PROD-1670 follow-up):
    //   - default inter-section gap: 30 px (top-level container is
    //     `flex-col gap-[30px]`).
    //   - intra-section: 10 px (most), 5 px (details grid rows), 6 px
    //     (the action-buttons block: 3-up row → Maps button → map tile
    //     are siblings of a `flex-col gap-[6px]` container).
    //   - Details grid + full description are ONE section (gap-[10px]
    //     between them in Figma `6181:5555`).
    //
    // Each section's preceding spacer is gated on the section's data,
    // so absent sections don't double-stack their neighbours' gaps.
    // The staged reveal (defer + fade/slide-up after the Hero flight lands)
    // applies to the pushed detail routes that receive a flight: the
    // standalone page AND the in-list detail (`embedded`, but still a pushed
    // route with a poster + colour-panel Hero). It stays OFF for the map-pin
    // sheet (`compactHeader` — no push flight, content must be there under the
    // shorter sheet) and the onboarding preview (`sandbox` — lives in a
    // carousel, not a flight). `SokoRevealOnSettle` self-detects the no-flight
    // case, so this gate is belt-and-braces for the surfaces we know.
    final useReveal = !compactHeader && !sandbox;

    // Content below the hero poster, in order. Extracted so it can be either
    // wrapped in [SokoRevealOnSettle] (standalone) or spread inline (embed /
    // sheet) without duplicating the column.
    final belowHero = <Widget>[
      _NameAndTagBlock(
        snapshot: snapshot,
        listAddSource: listAddSource,
        sandbox: sandbox,
        closeOnSignal: closeOnSignal,
        compactHeader: compactHeader,
      ),
      if (!sandbox)
        VenueClaimCta(
          venueId: venue.id,
          venueName: venue.name,
          showAction: false,
        ),
      if (!sandbox && showInlineActions) VenueInlineActions(snapshot: snapshot),
      if (hasDetails || hasFullDescription || hasSharedBy) ...[
        const SizedBox(height: 30),
        if (hasDetails)
          IgnorePointer(
            ignoring: sandbox,
            child: VenueDetailsGrid(venue: venue),
          ),
        if (hasDetails && hasFullDescription) const SizedBox(height: 10),
        if (hasFullDescription)
          // Long-form description (Mobile/B2 Reg, Soko/Ink). Same
          // section as the details grid per Figma `6181:5555`
          // (gap-[10px]). Reads `description_long` (PROD-1686 part 2)
          // — never the deprecated `description` alias, which the BE
          // falls back to `description_short` on conf-0.2-0.5 venues
          // and would duplicate the line above the name.
          Text(
            venue.descriptionLong!,
            style: const TextStyle(
              fontFamily: 'ZalandoSans',
              fontWeight: FontWeight.w300,
              fontSize: 14,
              height: 1.2,
              letterSpacing: -0.14,
              color: AppColors.sokoInk,
            ),
          ),
        // "Shared by <user>" credit sits directly below the description
        // (10 px) as part of this section (PROD-3134).
        if (hasSharedBy) ...[
          if (hasDetails || hasFullDescription) const SizedBox(height: 10),
          IgnorePointer(
            ignoring: sandbox,
            child: SharedByAttribution(
              sharedBy: venue.sharedBy!,
              entityType: SharedByEntity.venue,
              entityId: venue.id,
            ),
          ),
        ],
        // "… têm interesse" sits under the attribution — same visual
        // family, and it self-hides (flag off, or nobody yet).
        if (!sandbox)
          InterestedRow(
            preview: venue.interestedPreview,
            totalCount: venue.interestedCount,
            entityType: SignalEntityType.venue,
            entityId: venue.id,
          ),
      ],
      if (!sandbox && hasEvents) ...[
        const SizedBox(height: 30),
        VenueEventsHereSection(snapshot: snapshot),
      ],
      // Action buttons + map are ONE section (Figma `6181:5628` is a
      // `flex-col gap-[6px]` container with the 3-up button row, the
      // full-width Maps button, and the map tile as siblings). The
      // 3-up row → Maps button gap (6 px) lives inside
      // VenueActionGrid; the Maps button → map tile gap (6 px) is
      // applied here.
      if (!sandbox) ...[
        const SizedBox(height: 30),
        // Sheet preview (compactHeader): a single "See full detail" CTA
        // that closes the sheet and opens the full page, instead of the
        // external-action grid (Report/Website/Maps/…). The full-screen
        // and in-list bodies keep the grid.
        if (compactHeader)
          SokoCtaButton(
            label: Lt.of(context).detailButtonSeeFull,
            variant: SokoCtaVariant.ink,
            // In the sibling sheet, the host expands in place (grow +
            // morph). Otherwise (map pin sheet) fall back to opening the
            // full-screen route, dismissing the sheet behind it.
            onPressed:
                onSeeFullDetail ??
                () {
                  final router = GoRouter.of(context);
                  Navigator.of(context).pop();
                  router.push('/venues/${venue.id}');
                },
          )
        else
          VenueActionGrid(snapshot: snapshot),
      ],
      // The bottom mini-map is dropped in the sheet preview: it duplicates
      // the "Open in Maps" action and, on the map pin sheet, the live map
      // right behind it. The live Mapbox instance is the heaviest mount on
      // the page and sits below the fold, so it is lazily mounted on scroll
      // (see [LazyMount]) — kept off both the flight and the reveal frames.
      if (hasMap && !compactHeader) ...[
        SizedBox(height: sandbox ? 30 : 6),
        LazyMount(
          visibilityKey: ValueKey('venue-map-${venue.id}'),
          placeholder: const ClipRRect(
            borderRadius: BorderRadius.all(Radius.circular(6)),
            child: AspectRatio(
              aspectRatio: 1,
              child: ColoredBox(color: AppColors.sokoShade5),
            ),
          ),
          // The map pops in (fade + gentle scale, short delay) when it replaces
          // the grey placeholder, rather than snapping in — the last piece of
          // the page to arrive gets a small, deliberate entrance. Wrapped on the
          // LazyMount CHILD so the pop plays when the real map mounts, not when
          // the placeholder does. Skipped in the onboarding preview (sandbox).
          child: IgnorePointer(
            ignoring: sandbox,
            child: sandbox
                ? VenueMapBlock(venue: venue)
                : SokoPopIn(
                    startDelay: const Duration(milliseconds: 180),
                    beginScale: 0.92,
                    child: VenueMapBlock(venue: venue),
                  ),
          ),
        ),
      ],
      if (!sandbox && hasAppearsIn) ...[
        const SizedBox(height: 30),
        VenueAppearsInShelf(snapshot: snapshot),
      ],
    ];

    return ViewItemTracker(
      itemId: venue.id,
      itemType: 'place',
      child: Padding(
        padding: EdgeInsets.fromLTRB(15, topPad, 15, bottomPad),
        // sandbox (onboarding preview): keep only the in-app 👍/👎 taste actions
        // (via _NameAndTagBlock) — Save is dropped too (no lists yet in
        // onboarding) — and suppress every external link / cross-screen nav:
        // the action grid, claim, inline actions, events-here
        // and appears-in are dropped, and the launcher-bearing content (hero
        // fullscreen, details phone, map) is wrapped in IgnorePointer below.
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Back arrow is owned by the shell-level `PinnedPageChrome`.
            // PROD-3952 — the branded DAILY DROP header that used to replace
            // this gap for `?from=daily-drop` arrivals is gone: the drop has
            // its own page now and wears the header there. Otherwise the CTA
            // at the bottom of that page would walk the user from a DAILY
            // DROP surface onto a second page wearing the same wordmark.
            const SizedBox(height: 20),
            // Compact map-sheet header renders its own small thumbnail beside
            // the name; the full-width hero is skipped there.
            if (hasHero && !compactHeader) ...[
              IgnorePointer(
                ignoring: sandbox,
                child: SokoPhotoCollage(
                  imageUrls: heroImages,
                  seed: venue.id,
                  kind: SokoEntityKind.venue,
                ),
              ),
              const SizedBox(height: 30),
            ],
            // Everything below the hero poster, deferred off the Hero-flight
            // frames and revealed once the poster lands (fade + slide-up) on
            // the standalone page. Embedded / sheet hosts have no flight, so
            // they render it inline. See [SokoRevealOnSettle].
            if (useReveal)
              SokoRevealOnSettle(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: belowHero,
                ),
              )
            else
              ...belowHero,
          ],
        ),
      ),
    );
  }
}

/// Name (Mobile/H1, Season Mix Light 42) + 40 px circular Save button on
/// the right, optional short-description blurb, then the 3-tag row.
///
/// **Intentional divergence from Figma `6144:4126`:** the Figma comp puts
/// the Save button next to "Deixar nota" in the row beneath the tags. We
/// move it up next to the name so it's always visible (the inline-actions
/// row only renders when the user owns the parent list, and a globally
/// usable Save needs a permanent home). The button sits at the right edge
/// of the content column with the same 15 px gutter the page uses.
///
/// **Short description rendering (PROD-1686 parts 1 + 2 live in prod):**
/// `description_short` is read from `VenueDetailOut` and rendered in
/// Mobile/B2 Reg + Soko/Shade1 between the name and the tag row, per
/// figma cache `6144:4128`. NULL for venues never enriched (~55 % of
/// prod) in which case the slot collapses cleanly.
///
/// **De-dupe (defensive only):** the long-form block above the description
/// reads `description_long`, which the BE guarantees never duplicates
/// `description_short` (the tier gating in PROD-1686 part 2 splits short
/// vs medium/full cleanly). The whitespace-trimmed compare below is kept
/// as belt-and-braces against future BE regressions, not because any
/// current code path produces duplicates.
class _NameAndTagBlock extends ConsumerWidget {
  final VenueDetailSnapshot snapshot;

  /// PROD-3219 — see `VenueDetailBody.listAddSource`. Forwarded to the save
  /// button so map-origin saves record `source: 'map'`.
  final String? listAddSource;

  /// See `VenueDetailBody.sandbox` — drops the Save/Share/thumb/owner
  /// affordances, leaving just the name, blurb, and tags.
  final bool sandbox;

  /// See `VenueDetailBody.closeOnSignal` — when true, a set 👍/👎 auto-closes
  /// this (pushed/sheet) detail.
  final bool closeOnSignal;

  /// See `VenueDetailBody.compactHeader` — small thumbnail beside the
  /// name/tags/description, action row full-width beneath.
  final bool compactHeader;

  const _NameAndTagBlock({
    required this.snapshot,
    this.listAddSource,
    this.sandbox = false,
    this.closeOnSignal = false,
    this.compactHeader = false,
  });

  /// True when `description_short` is non-empty AND distinct (after a
  /// cheap whitespace trim) from `description_long`. With PROD-1686
  /// part 2 live the BE never produces duplicates here, but the compare
  /// is cheap and protects against future regressions.
  static bool _shouldRenderShort(String? shortDesc, String? longDesc) {
    final s = shortDesc?.trim() ?? '';
    if (s.isEmpty) return false;
    final l = longDesc?.trim() ?? '';
    return s != l;
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ownerMergedVenue(ref, snapshot.venue);
    final showShort = _shouldRenderShort(
      venue.descriptionShort,
      venue.descriptionLong,
    );
    const nameStyle = TextStyle(
      fontFamily: 'SeasonMix',
      fontSize: 42,
      fontWeight: FontWeight.w300,
      height: 0.94,
      letterSpacing: -0.84,
      color: AppColors.sokoInk,
    );
    final shortText = showShort
        ? Text(
            venue.descriptionShort!,
            style: const TextStyle(
              fontFamily: 'ZalandoSans',
              fontWeight: FontWeight.w300,
              fontSize: 14,
              height: 1.2,
              letterSpacing: -0.14,
              color: AppColors.sokoShade1,
            ),
          )
        : null;

    // Onboarding preview: keep only 👍/👎 (the in-app taste actions). Save is
    // dropped too — there are no lists yet during onboarding, so a live Save
    // button led nowhere (PROD-3888). Share (external) and the owner affordance
    // stay dropped.
    if (sandbox) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(venue.name, style: nameStyle),
          if (shortText != null) ...[const SizedBox(height: 10), shortText],
          const SizedBox(height: 10),
          VenueTagRow(venue: venue),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final cell in signalThumbCells(
                context,
                ref,
                entityType: SignalEntityType.venue,
                entityId: venue.id,
                provenance: SignalProvenance.detail,
                // Pushed/sheet detail → a set 👍/👎 closes it; the embedded
                // in-list card has no route to pop.
                closeOnSignal: closeOnSignal,
              ))
                Expanded(child: cell),
            ],
          ),
        ],
      );
    }

    final ownerAffordance = VenueOwnerAffordance(
      venue: venue,
      onSaved: () => ref.invalidate(
        venueDetailProvider(
          VenueDetailKey(venueId: venue.id, listId: snapshot.effectiveListId),
        ),
      ),
    );

    // PROD-2939 — the signals action row below the tags: full-width captioned
    // cells (Guarda · Partilha · 👍 · 👎). Thumbs auth-gate themselves
    // (signalThumbCells returns [] when signed out).
    //
    // Equal-width cells (each wrapped in Expanded) keep the spacing uniform
    // regardless of caption width — a past-tense flip (Save → Saved) no longer
    // shifts its neighbours. The row spans the full content column; the old
    // 20px side inset is dropped so the buttons breathe on narrow screens.
    final actionRow = Row(
      // Top-align so a caption that wraps to 2 lines grows downward and the
      // glyphs stay level across cells.
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final cell in <Widget>[
          SokoSaveButton(venue: venue, bare: true, source: listAddSource),
          DetailShareCell(
            shareContext: 'venue',
            entityId: venue.id,
            shareUrl: buildVenueShareUrl(
              venueIdentifier: venue.id,
              listIdentifier: snapshot.effectiveListId,
            ),
          ),
          ...signalThumbCells(
            context,
            ref,
            entityType: SignalEntityType.venue,
            entityId: venue.id,
            provenance: SignalProvenance.detail,
            // Pushed/sheet detail → a set 👍/👎 closes it; the embedded
            // in-list card has no route to pop.
            closeOnSignal: closeOnSignal,
          ),
        ])
          Expanded(child: cell),
      ],
    );

    // Compact map-sheet header: small thumbnail beside the name/tags/blurb
    // (side-by-side), the action row full-width beneath. Keeps the sheet short
    // so the map stays visible behind it.
    if (compactHeader) {
      const compactNameStyle = TextStyle(
        fontFamily: 'SeasonMix',
        fontSize: 28,
        fontWeight: FontWeight.w300,
        height: 0.96,
        letterSpacing: -0.56,
        color: AppColors.sokoInk,
      );
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SokoCardImage(
                imageUrl: venue.images.isNotEmpty ? venue.images.first : null,
                seed: venue.id,
                kind: SokoEntityKind.venue,
                width: 96,
                height: 120,
                borderRadius: BorderRadius.circular(12),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(venue.name, style: compactNameStyle),
                    const SizedBox(height: 8),
                    VenueTagRow(venue: venue),
                    if (shortText != null) ...[
                      const SizedBox(height: 8),
                      shortText,
                    ],
                  ],
                ),
              ),
            ],
          ),
          ownerAffordance,
          const SizedBox(height: 16),
          actionRow,
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(venue.name, style: nameStyle),
        if (shortText != null) ...[const SizedBox(height: 10), shortText],
        const SizedBox(height: 10),
        VenueTagRow(venue: venue),
        ownerAffordance,
        const SizedBox(height: 16),
        actionRow,
      ],
    );
  }
}
