import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/event_timing_chip.dart';
import '../../../core/utils/event_when_formatter.dart';
import '../../../core/utils/orientation_utils.dart';
import '../../../data/models/entity_signal.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/lazy_mount.dart';
import '../../../shared/widgets/rotated_date_tag.dart';
import '../../../shared/widgets/soko_card_image.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../../shared/widgets/soko_photo_collage.dart';
import '../../../shared/widgets/soko_pop_in.dart';
import '../../../shared/widgets/soko_reveal_on_settle.dart';
import '../../entity_signals/widgets/signal_chips_section.dart';
import '../../entity_signals/widgets/interested_row.dart';
import '../../../shared/widgets/view_item_tracker.dart';
import '../../share/widgets/detail_share_cell.dart';
import '../providers/event_detail_provider.dart';
import '../utils/event_share.dart';
import 'event_sharers_attribution.dart';
import 'event_action_grid.dart';
import 'event_appears_in_shelf.dart';
import 'event_details_row.dart';
import 'event_inline_actions.dart';
import 'event_map_block.dart';
import 'event_occurrence_section.dart';
import 'event_save_button.dart';
import 'event_reminder_bell_button.dart';
import 'event_tag_row.dart';

/// The body composition of the event detail page — section column,
/// gating, and spacing. Public widget so the list-embed wrapper (the
/// in-list "Vê mais" detail card on the list page) can mount the same
/// body inside its own scaffold without duplicating the layout.
///
/// Two modes, gated by [embedded] (default `false`):
///   - **Full-screen** (`embedded: false`) — the standalone screen mode.
///     Renders the 71 px top inset, the bottom-nav clearance padding,
///     and the back-button row. This is what [EventDetailScreen] mounts.
///   - **Embedded**    (`embedded: true`)  — for the in-list detail card.
///     All three pieces above are toggled off; the embedding wrapper is
///     responsible for its own chrome (card bounds, background paint,
///     close affordance). The section column itself is identical between
///     the two modes.
///
/// Stays a `StatelessWidget` — provider watching and the loading/error
/// switch live on the host (e.g. [EventDetailScreen]). This widget renders a
/// resolved snapshot and owns the **`view_item` analytics** (via the wrapping
/// [ViewItemTracker]) so every host — full screen, in-list detail, map sheet
/// — fires the view exactly when the full detail is shown.
class EventDetailBody extends StatelessWidget {
  final EventDetailSnapshot snapshot;

  /// Toggles full-screen chrome off (top inset, bottom-nav clearance,
  /// back-button row). Default `false` keeps full-screen behaviour for
  /// existing callers.
  final bool embedded;

  /// PROD-3219 — overrides the save button's `list_item_add` source. Null keeps
  /// the default ([ListSource.detail]); the Map page passes [ListSource.map].
  final String? listAddSource;

  /// PROD-3888 — onboarding "vibe" preview. When true the body keeps the in-app
  /// taste actions live (Save + 👍/👎) but suppresses every external link
  /// (site/maps/calendar/share) and cross-screen nav (venue row, appears-in,
  /// sharers→profile, reminder); the launcher/nav content (hero, details row,
  /// map) is wrapped in [IgnorePointer]. Default `false` — normal callers
  /// untouched.
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
  /// title/tags/description (side-by-side), with the action row full-width
  /// beneath. Keeps the map visible behind a shorter sheet. Only the map sheet
  /// passes `true`; the full-screen `/events` page keeps its big hero.
  final bool compactHeader;

  const EventDetailBody({
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
  Widget build(BuildContext context) {
    // Top padding is owned by `DiscoveryShell.PinnedPageChrome` — the
    // shell reserves the chrome's height (incl. safe area) above the
    // page body, so the body itself starts at 0 padding regardless of
    // embedded vs full-screen.
    final topPad = 0.0;
    final bottomPad = embedded
        ? 0.0
        : OrientationUtils.bottomNavClearance(context) + 16;
    final event = snapshot.event;
    // PROD-4074 — the hero is now [SokoPhotoCollage]. `images` collapses to
    // `[imageUrl]` today (single-image backend), so a lone photo renders
    // centred and the gate stays equivalent to the old `imageUrl` one; a real
    // multi-image array (PROD-1676) lights up the collage with no app release.
    final heroImages = event.images;
    final hasHero = heroImages.isNotEmpty;
    // Relative-timing chip (Past event / Today / … / Recurring event / an
    // exhibition phase) — overlaid on the hero photo when there is one;
    // otherwise `_NameAndTagBlock` falls it back over the title. Resolved from
    // the whole timing shape (dateRanges + authoritative isPast), NOT a single
    // start date — so a recurring series whose first occurrence has passed
    // isn't mislabelled "Past event". Suppressed while the seed shell is
    // hydrating: the seed carries only a lone startAt (no dateRanges), which
    // can misclassify (recurring → "Past event", mid-run exhibition → a label
    // the hydrated detail then drops), so the chip would flash wrong and flip.
    final heroTimingChip = snapshot.isHydrating
        ? const EventTimingChip.none()
        : chipForEventDetail(context, event);
    final hasDetails =
        (event.venueName ?? '').isNotEmpty ||
        (event.venueAddress ?? '').isNotEmpty ||
        (event.venueCity ?? '').isNotEmpty;
    final hasFullDescription = (event.descriptionLong ?? '').isNotEmpty;
    // PROD-3134 / PROD-3160 — "Shared by <user>" credit, scaling from one
    // sharer to "A, B and others". Present when the BE resolves any sharer
    // (`sharers_preview`, or the single-sharer `shared_by` back-compat
    // primary); system/scraped events carry neither and render nothing here.
    final hasSharedBy =
        event.sharersPreview.isNotEmpty || event.sharedBy != null;
    final hasOccurrences = snapshot.occurrences.isNotEmpty;
    final hasMap = event.latitude != null && event.longitude != null;
    final hasAppearsIn = event.socialProof.lists.isNotEmpty;
    // Mount the note surface for any in-list view; the widget reads the tip +
    // ownership live and decides visibility (owner-editable, non-owner
    // read-only, or hidden when there's nothing to show).
    final showInlineActions = snapshot.effectiveListId != null;

    // Vertical rhythm — Figma `6181:5531` (mirrors the venue page):
    //   - default inter-section gap: 30 px (top-level container is
    //     `flex-col gap-[30px]`).
    //   - intra-section: 10 px between details row and description (one
    //     section per Figma `6181:5555`); 6 px between action grid and
    //     map (one section per Figma `6181:5628`'s `flex-col gap-[6px]`).
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
      if (!sandbox && showInlineActions) EventInlineActions(snapshot: snapshot),
      // Details row + full description are ONE section per Figma
      // `6181:5555` (gap-[10px] between them).
      if (hasDetails || hasFullDescription || hasSharedBy) ...[
        const SizedBox(height: 30),
        if (hasDetails)
          IgnorePointer(
            ignoring: sandbox,
            child: EventDetailsRow(event: event),
          ),
        if (hasDetails && hasFullDescription) const SizedBox(height: 10),
        if (hasFullDescription)
          Text(
            event.descriptionLong!,
            style: const TextStyle(
              fontFamily: 'ZalandoSans',
              fontWeight: FontWeight.w300,
              fontSize: 14,
              height: 1.2,
              letterSpacing: -0.14,
              color: AppColors.sokoInk,
            ),
          ),
        // "Shared by <user>" / "Shared by A, B and others" credit sits
        // directly below the description (10 px) as part of this section
        // (PROD-3134 / PROD-3160).
        if (hasSharedBy) ...[
          if (hasDetails || hasFullDescription) const SizedBox(height: 10),
          IgnorePointer(
            ignoring: sandbox,
            child: EventSharersAttribution(
              sharersPreview: event.sharersPreview,
              sharersCount: event.sharersCount,
              sharedBy: event.sharedBy,
              eventId: event.id,
            ),
          ),
        ],
        // "… têm interesse" sits under the attribution — same visual
        // family, and it self-hides (flag off, or nobody yet).
        if (!sandbox)
          InterestedRow(
            preview: event.interestedPreview,
            totalCount: event.interestedCount,
            entityType: SignalEntityType.event,
            entityId: event.id,
          ),
      ],
      // Past-only event (no future occurrences): the "Dates" section
      // shows the event's real, absolute date — the "past" status now
      // lives in the rotated tag over the title (see [_NameAndTagBlock]),
      // so the date reads as a clean calendar date, not a caveat.
      // Upcoming events keep the full occurrence list.
      if (event.isPast) ...[
        const SizedBox(height: 30),
        _PastEventDatesBlock(startAt: event.startAt),
      ] else if (hasOccurrences) ...[
        const SizedBox(height: 30),
        EventOccurrenceSection(snapshot: snapshot),
      ],
      // Action buttons + map are ONE section (Figma `6181:5628` is a
      // `flex-col gap-[6px]` container with the action grid and the
      // map tile as siblings). Action grid's internal row→row gap
      // (6 px) lives inside EventActionGrid; the action-grid → map
      // gap (6 px) is applied here.
      if (!sandbox) ...[
        const SizedBox(height: 30),
        // Sheet preview (compactHeader): a single "See full detail" CTA
        // that closes the sheet and opens the full page, instead of the
        // external-action grid (Report/Website/Maps/Calendar). The
        // full-screen and in-list bodies keep the grid.
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
                  router.push('/events/${event.id}');
                },
          )
        else
          EventActionGrid(snapshot: snapshot),
      ],
      // The bottom mini-map is dropped in the sheet preview: it duplicates
      // the "Open in Maps" action and, on the map pin sheet, the live map
      // right behind it. The live Mapbox instance is the heaviest mount on
      // the page and sits below the fold, so it is lazily mounted on scroll
      // (see [LazyMount]) — kept off both the flight and the reveal frames.
      if (hasMap && !compactHeader) ...[
        SizedBox(height: sandbox ? 30 : 6),
        LazyMount(
          visibilityKey: ValueKey('event-map-${event.id}'),
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
                ? EventMapBlock(event: event)
                : SokoPopIn(
                    startDelay: const Duration(milliseconds: 180),
                    beginScale: 0.92,
                    child: EventMapBlock(event: event),
                  ),
          ),
        ),
      ],
      if (!sandbox && hasAppearsIn) ...[
        const SizedBox(height: 30),
        EventAppearsInShelf(snapshot: snapshot),
      ],
    ];

    return ViewItemTracker(
      itemId: event.id,
      itemType: 'event',
      child: Padding(
        padding: EdgeInsets.fromLTRB(15, topPad, 15, bottomPad),
        // sandbox (onboarding preview): keep the in-app actions live — Save +
        // 👍/👎 (via _NameAndTagBlock) — but suppress every external link /
        // cross-screen nav: the action grid, reminder, inline actions and
        // appears-in are dropped, and the launcher/nav content (hero, details
        // row → venue, sharers → profile, map) is wrapped in IgnorePointer.
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
            // the title; the full-width hero is skipped there.
            if (hasHero && !compactHeader) ...[
              // The relative-timing sticker (Past event / Today / Tomorrow /
              // This weekend / This week / Next week) rides the hero photo's
              // top-right corner, tilted — a slapped-on sticker on the actual
              // big tile (not the brand margin beside a single-image tile).
              // When there's no hero it falls back over the title (see
              // [_NameAndTagBlock]).
              IgnorePointer(
                ignoring: sandbox,
                child: SokoPhotoCollage(
                  imageUrls: heroImages,
                  seed: event.id,
                  kind: SokoEntityKind.event,
                  cornerBadgeBuilder: heroTimingChip.isVisible
                      ? (imageLoaded) => RotatedDateTag(
                          label: heroTimingChip.label!,
                          background: RotatedDateTag.backgroundFor(
                            heroTimingChip.style,
                          ),
                          // Stamp in only once the hero photo has painted.
                          active: imageLoaded,
                        )
                      : null,
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

/// The "Dates" section for a past-only event: the same "Dates" heading as
/// [EventOccurrenceSection] followed by the event's real, **absolute** date.
/// The "past" status is carried by the rotated tag over the title (see
/// [eventRelativeTagLabel] + [RotatedDateTag]), so this row stays a clean
/// calendar date rather than a "Past event" caveat.
class _PastEventDatesBlock extends StatelessWidget {
  const _PastEventDatesBlock({required this.startAt});

  /// The event's start (its real, possibly-past date). Null hides the date row
  /// but keeps the heading, matching the section's shape.
  final DateTime? startAt;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final start = startAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Same heading as EventOccurrenceSection (ZalandoSans w500 / 18).
        Text(
          l10n.eventDetailDatesTitle,
          style: const TextStyle(
            fontFamily: 'ZalandoSans',
            fontWeight: FontWeight.w500,
            fontSize: 18,
            height: 1.0,
            letterSpacing: -0.36,
            color: AppColors.sokoInk,
          ),
        ),
        if (start != null) ...[
          const SizedBox(height: 30),
          Text(
            formatEventDateAbsolute(
              context: context,
              startsAt: start,
              timeKnown: start.hour != 0 || start.minute != 0,
            ),
            style: AppTheme.body(fontSize: 14, color: AppColors.sokoInk),
          ),
        ],
      ],
    );
  }
}

/// Name (Mobile/H1, Season Mix Light 42), optional short-description
/// blurb, the tag row, then the action row. The row is gated: signals ON
/// (admin) → the new full-width captioned row (Guarda · Lembrete · Partilha
/// · 👍 · 👎); OFF → the legacy compact 40 px circle chips.
class _NameAndTagBlock extends StatelessWidget {
  final EventDetailSnapshot snapshot;

  /// PROD-3219 — see `EventDetailBody.listAddSource`. Forwarded to the save
  /// button so map-origin saves record `source: 'map'`.
  final String? listAddSource;

  /// See `EventDetailBody.sandbox` — drops the Save/Reminder/Share/thumb action
  /// row, leaving just the title, blurb, and tags.
  final bool sandbox;

  /// See `EventDetailBody.closeOnSignal` — when true, a set 👍/👎 auto-closes
  /// this (pushed/sheet) detail.
  final bool closeOnSignal;

  /// See `EventDetailBody.compactHeader` — small thumbnail beside the
  /// title/tags/description, action row full-width beneath.
  final bool compactHeader;

  const _NameAndTagBlock({
    required this.snapshot,
    this.listAddSource,
    this.sandbox = false,
    this.closeOnSignal = false,
    this.compactHeader = false,
  });

  /// True when `description_short` is non-empty AND distinct (after a
  /// cheap whitespace trim) from the long `description`.
  static bool _shouldRenderShort(String? shortDesc, String? longDesc) {
    final s = shortDesc?.trim() ?? '';
    if (s.isEmpty) return false;
    final l = longDesc?.trim() ?? '';
    return s != l;
  }

  @override
  Widget build(BuildContext context) {
    final event = snapshot.event;
    // Relative-timing chip over the title (Past event / Today / … / Recurring
    // event / an exhibition phase), or null when the date is far out / unknown.
    // The clean absolute date always lives in the "Dates" section below.
    // Resolved from the whole timing shape so a recurring series isn't
    // mislabelled "Past event". Suppressed while the seed shell is hydrating —
    // the seed's lone startAt can misclassify; the chip stamps in with the
    // hydrated detail (see the hero chip above).
    final timingChip = snapshot.isHydrating
        ? const EventTimingChip.none()
        : chipForEventDetail(context, event);
    final showShort = _shouldRenderShort(
      event.descriptionShort,
      event.descriptionLong,
    );
    final shortWidget = showShort
        ? Text(
            event.descriptionShort!,
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
    final tagRow = EventTagRow(event: event);

    // PROD-2939 — the signals action row: full-width captioned cells
    // (Guarda · Lembrete · Partilha · 👍 · 👎), spaced evenly. Thumbs
    // auth-gate themselves (signalThumbCells returns [] when signed out).
    // Onboarding sandbox preview keeps only 👍/👎 — Save is dropped (no
    // lists yet in onboarding, so a live Save button led nowhere; PROD-3888).
    final actionRow = Consumer(
      builder: (context, ref, _) {
        if (sandbox) {
          final cells = signalThumbCells(
            context,
            ref,
            entityType: SignalEntityType.event,
            entityId: event.id,
            provenance: SignalProvenance.detail,
            // Pushed/sheet detail (incl. the onboarding sandbox preview) →
            // a set 👍/👎 closes it; the embedded in-list card has no route.
            closeOnSignal: closeOnSignal,
          );
          return Padding(
            padding: const EdgeInsets.only(top: 16),
            child: Row(
              // Top-align so a wrapped 2-line caption grows downward and the
              // glyphs stay level across cells.
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final cell in cells) Expanded(child: cell)],
            ),
          );
        }
        // Hide the reminder bell on past-only events — no future
        // occurrence exists for a reminder to attach to. Matches the
        // bell's own `upcoming` filter (instant granularity).
        final hasReminderSlot = snapshot.occurrences.any(
          (o) => o.startAt.isAfter(DateTime.now()),
        );

        // Equal-width cells (each wrapped in Expanded) so the row spacing
        // stays uniform regardless of caption width — a past-tense flip
        // (Like → Liked, Save → Saved) no longer shifts its neighbours.
        final cells = <Widget>[
          EventSaveButton(
            event: event,
            occurrences: snapshot.occurrences,
            bare: true,
            source: listAddSource,
          ),
          // Rendered whenever the event has a future occurrence to remind
          // about, OR while the seed shell is still hydrating (occurrences
          // unknown) — in which case it shows DISABLED, reserving its slot so
          // it doesn't pop in when the network detail lands. Omitted only on a
          // fully-loaded past-only event (no future occurrence), where dropping
          // the cell keeps the remaining Expanded cells evenly spaced.
          if (hasReminderSlot || snapshot.isHydrating)
            EventReminderBellButton(
              snapshot: snapshot,
              enabled: hasReminderSlot && !snapshot.isHydrating,
            ),
          DetailShareCell(
            shareContext: 'event',
            entityId: event.id,
            shareUrl: buildEventShareUrl(
              eventIdentifier: event.id,
              listIdentifier: snapshot.effectiveListId,
            ),
          ),
          ...signalThumbCells(
            context,
            ref,
            entityType: SignalEntityType.event,
            entityId: event.id,
            provenance: SignalProvenance.detail,
            // Pushed/sheet detail → a set 👍/👎 closes it; the embedded
            // in-list card has no route to pop.
            closeOnSignal: closeOnSignal,
          ),
        ];
        // 16px top gap; spans the full content column so the buttons
        // breathe on narrow screens (Pixel 4).
        return Padding(
          padding: const EdgeInsets.only(top: 16),
          child: Row(
            // Top-align so a wrapped 2-line caption grows downward and the
            // glyphs stay level across cells.
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [for (final cell in cells) Expanded(child: cell)],
          ),
        );
      },
    );

    // Compact map-sheet header: small thumbnail beside the title/tags/blurb
    // (side-by-side), the action row full-width beneath. Keeps the sheet short
    // so the map stays visible behind it.
    if (compactHeader) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Sticker rides the thumbnail's top-right corner (tilted, bleeds
              // past the rounded corner via clipBehavior none).
              Stack(
                clipBehavior: Clip.none,
                children: [
                  SokoCardImage(
                    imageUrl: event.images.isNotEmpty
                        ? event.images.first
                        : null,
                    seed: event.id,
                    kind: SokoEntityKind.event,
                    width: 96,
                    height: 120,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  if (timingChip.isVisible)
                    Positioned(
                      top: 6,
                      right: 6,
                      child: RotatedDateTag(
                        label: timingChip.label!,
                        background: RotatedDateTag.backgroundFor(
                          timingChip.style,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      event.title,
                      style: const TextStyle(
                        fontFamily: 'SeasonMix',
                        fontSize: 28,
                        fontWeight: FontWeight.w300,
                        height: 0.96,
                        letterSpacing: -0.56,
                        color: AppColors.sokoInk,
                      ),
                    ),
                    const SizedBox(height: 8),
                    tagRow,
                    if (shortWidget != null) ...[
                      const SizedBox(height: 8),
                      shortWidget,
                    ],
                  ],
                ),
              ),
            ],
          ),
          actionRow,
        ],
      );
    }

    final titleText = Text(
      event.title,
      style: const TextStyle(
        fontFamily: 'SeasonMix',
        fontSize: 42,
        fontWeight: FontWeight.w300,
        height: 0.94,
        letterSpacing: -0.84,
        color: AppColors.sokoInk,
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The relative-timing sticker normally lives on the hero photo (see
        // `EventDetailBody`); here it only falls back over the title's
        // lower-right when the event has no hero image to sit on.
        Stack(
          // Let the tilted sticker bleed past the title box instead of being
          // clipped at the corner.
          clipBehavior: Clip.none,
          children: [
            titleText,
            if (timingChip.isVisible && event.images.isEmpty)
              Positioned(
                right: 0,
                bottom: 0,
                child: RotatedDateTag(
                  label: timingChip.label!,
                  background: RotatedDateTag.backgroundFor(timingChip.style),
                ),
              ),
          ],
        ),
        if (shortWidget != null) ...[const SizedBox(height: 10), shortWidget],
        const SizedBox(height: 10),
        tagRow,
        actionRow,
      ],
    );
  }
}
