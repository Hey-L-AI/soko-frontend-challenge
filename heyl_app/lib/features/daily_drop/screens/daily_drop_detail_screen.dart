import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/environment.dart';
import '../../../core/constants/api_constants.dart';
import '../../../core/services/experiment_service.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../core/utils/google_maps_url.dart';
import '../../../core/utils/event_time.dart';
import '../../../core/utils/orientation_utils.dart';
import '../../../data/models/daily_drop.dart';
import '../../../data/models/entity_signal.dart';
import '../../../data/models/user_list.dart' show ListSource;
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/soko_card_image.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../../shared/widgets/soko_photo_collage.dart';
import '../../../shared/widgets/soko_reveal_on_settle.dart';
import '../../../shared/widgets/soko_tag.dart';
import '../../discovery/widgets/shell_sliver_page.dart';
import '../../entity_signals/widgets/signal_chips_section.dart';
import '../../event_detail/providers/event_detail_provider.dart';
import '../../event_detail/utils/event_share.dart';
import '../../event_detail/widgets/event_reminder_bell_button.dart';
import '../../event_detail/widgets/event_save_button.dart';
import '../../share/widgets/detail_share_cell.dart';
import '../../venue_detail/providers/venue_detail_provider.dart';
import '../../venue_detail/utils/venue_share.dart';
import '../../venue_detail/widgets/soko_save_button.dart';
import '../providers/daily_drop_entity_detail_provider.dart';
import '../utils/daily_drop_destination.dart';
import '../widgets/daily_drop_detail_header.dart';
import '../widgets/daily_drop_tip_slot.dart';

/// The **Daily Drop's own detail page** (PROD-3949 / PROD-3950).
///
/// Before this, a drop backed by a local venue/event opened the *ordinary*
/// venue/event detail page wearing a branded header, threaded through
/// `?from=daily-drop&dropId=&dropDate=`; only the rare drop with no local
/// entity (0.05 % of volume) got a screen of its own. The drop is its own
/// product surface and is about to diverge further — the tip lands here next —
/// so it gets one page, and every ready drop opens it.
///
/// Structure, top → bottom (umbrella PROD-3949):
///   1. back arrow — the shell's `PinnedPageChrome`, not ours
///   2. branded DAILY DROP header ([DailyDropDetailHeader], reused as-is)
///   3. name + tag chip row
///   4. [DailyDropTipSlot] — the tip's slot; v1 renders the drop's `reason`.
///      Admin-only for now (PostHog `daily-drop-tip`)
///   5. photo ([SokoPhotoCollage] — same block as venue/event detail)
///   6. short description off the fetched detail response
///   7. action bar — save · share · 👍 · 👎
///   8. CTA onto venue/event detail (external "Open in Maps / link" instead,
///      for a drop with no local entity)
///
/// ## Two things this page deliberately does NOT do
///
/// **It fires no `view_item`.** Opening a drop is not viewing the entity. The
/// entity view begins when the user asks for it — the element-8 CTA — and the
/// destination page fires `view_item` on its own mount, exactly once. The tap
/// itself is recorded as `daily_drop_entity_cta_tap`; `daily_drop_open` already
/// covers opening the drop and is unchanged.
///
/// **It writes no server-side interest signal.** It *does* fetch venue/event
/// detail — that's what makes the save button, tag row, short description and
/// share URL reuse the real widgets instead of re-implementing them from the
/// drop payload — but with `?source=` **omitted**, the backend's documented
/// no-capture path. See [dailyDropVenueDetailProvider] for why that needs its
/// own provider rather than the ordinary detail one.
///
/// ## Rendering model
///
/// Everything above the fold comes from the in-memory [DailyDrop] the router
/// hands over as `extra`, so the page paints on the first frame; the short
/// description and the action bar fill in when the fetch lands. A drop whose
/// entity has been deleted since it was generated (a 404) degrades to the
/// payload-only shape: no save, no thumbs, no CTA.
///
/// Mounts inside `DiscoveryShell`, so the pinned back arrow, top inset,
/// per-page background and bottom-nav hiding all come from the shell chrome.
/// The background it paints below must agree with the two shell-side sites that
/// resolve the same colour — see `dailyDropChromeIsEvent`.
class DailyDropDetailScreen extends StatelessWidget {
  final DailyDrop drop;

  const DailyDropDetailScreen({super.key, required this.drop});

  @override
  Widget build(BuildContext context) {
    final viewportHeight = MediaQuery.of(context).size.height;
    final kind = SokoEntityKind.fromTypeString(drop.itemType);
    // Must match what the shell paints for this route (`_pageBgForRoute`) and
    // what the chrome paints behind the back arrow (`_resolveSpec`) — all three
    // key off the drop's `item_type`. A mismatch shows as a colour seam under
    // the chrome, which is exactly the bug PROD-3950 fixed for event drops.
    final background = kind == SokoEntityKind.event
        ? AppColors.sokoEvent
        : AppColors.sokoVenue;

    // Page owns its scrollable via [ShellSliverHost]; the shell-level
    // [PinnedPageChrome] renders the back arrow over the top. Inner
    // ColoredBox + minHeight keep short content filling the viewport
    // without leaking the Scaffold bg.
    return ColoredBox(
      // Full-bleed page background BEHIND the whole scroll view. The
      // chrome-reserved top gap is a transparent CustomScrollView region that
      // otherwise reveals the shell Scaffold bg — which lags for a frame or two
      // during the push transition and flashes a white row across the top.
      // Painting `background` here makes the page self-sufficient. See
      // docs/learnings/detail-page-shell-bg-paint.md.
      color: background,
      child: ShellSliverHost(
        slivers: [
          SliverToBoxAdapter(
            child: PageContent(
              child: ColoredBox(
                color: background,
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: viewportHeight),
                  child: _DailyDropDetailBody(drop: drop, kind: kind),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DailyDropDetailBody extends ConsumerWidget {
  final DailyDrop drop;
  final SokoEntityKind kind;

  const _DailyDropDetailBody({required this.drop, required this.kind});

  /// The drop's own instant, for the branded header. `generated_at` only — the
  /// header takes its UTC day for the palette seed and its local day for the
  /// date row, and conflating those with the *item's* `start_at` would colour
  /// the wordmark off the event's date instead of the drop's.
  DateTime? _generatedAt() {
    final iso = drop.generatedAt;
    if (iso == null) return null;
    return DateTime.tryParse(iso);
  }

  /// A Google Maps URL for the pick (place-id / name / coords), or a raw
  /// external URL — drives the entity-less "Open in Maps / Open link" CTA.
  String? _externalUrl() {
    final external = drop.externalUrl;
    if (external != null && external.isNotEmpty) return external;
    return GoogleMapsUrl.canonicalPlaceUrl(
      placeId: drop.googlePlaceId,
      name: drop.title,
      latitude: drop.latitude,
      longitude: drop.longitude,
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final bottomPad = OrientationUtils.bottomNavClearance(context) + 16;

    // One classifier for all three shapes, shared with the routing layer so
    // the page and the router can't disagree about what a drop *is*.
    final destination = resolveDailyDropEntity(drop);

    // The fetched entity, when there is one. `AsyncValue` carries all three
    // states the page needs to distinguish: still loading (render the payload
    // half), loaded (fill in description + action bar + CTA), and failed —
    // which must NOT fall back to a half-built action bar.
    final AsyncValue<VenueDetailSnapshot>? venueAsync = switch (destination) {
      DailyDropVenue(:final venueId) => ref.watch(
        dailyDropVenueDetailProvider(venueId),
      ),
      _ => null,
    };
    final AsyncValue<EventDetailSnapshot>? eventAsync = switch (destination) {
      DailyDropEvent(:final eventId) => ref.watch(
        dailyDropEventDetailProvider(eventId),
      ),
      _ => null,
    };
    final venue = venueAsync?.valueOrNull;
    final event = eventAsync?.valueOrNull;
    final hasEntity = venue != null || event != null;

    // Photo: the drop's own image first (it's already in memory, so the hero
    // paints on frame one), falling back to the fetched entity's — which only
    // ever *adds* a photo where the payload had none, never swaps one.
    //
    // PROD-4074 parity: the hero is now [SokoPhotoCollage], matching venue /
    // event detail. A lone image renders as the right-aligned 4:5 big tile;
    // when the drop has no own image it borrows the entity's full `images[]`,
    // so a real multi-photo set (PROD-1676) lights up the collage with no app
    // release. The drop's own single image keeps winning on frame one, so the
    // no-swap rule above still holds.
    final ownImage = _firstNonEmpty([drop.imageUrl, drop.coverImageUrl]);
    final List<String> heroImages = ownImage != null
        ? <String>[ownImage]
        : (venue?.venue.images ?? event?.event.images ?? const <String>[]);

    // The collage's `seed` drives its main-tile Hero tag
    // (`detail-collage-photo:$seed:main`). Venue and event detail render the
    // *same* [SokoPhotoCollage] seeded with the entity id, so seeding this one
    // with the entity id too makes the cover photo share a Hero tag with the
    // destination page — the "learn more about this place" CTA
    // (`context.push('/venues|events/$id')`) then flies the image from here into
    // the entity detail instead of cross-fading.
    //
    // Available exactly when it matters: the CTA only renders once the entity
    // fetch lands (`hasEntity`), and the seed lands in the same rebuild, so by
    // the time a push is possible the tag already matches. Entity-less drops
    // have no CTA and no push, so they keep the recommendation-id seed.
    final String collageSeed =
        venue?.venue.id ??
        event?.event.id ??
        drop.recommendationId ??
        drop.title ??
        'daily-drop';

    final descriptionShort = _firstNonEmpty([
      venue?.venue.descriptionShort,
      event?.event.descriptionShort,
    ]);

    // The action bar is all-or-nothing per the progressive-render rule: it
    // "fills in when the fetch lands". Rendering share alone while an
    // entity-backed drop is still loading would put up a single full-width
    // cell that then jumps left as save and the thumbs appear beside it — a
    // layout shift, not a progressive fill. An entity-less drop has no fetch
    // to wait on, and a failed one has nothing more coming, so both render
    // immediately (share-only, which is the documented degraded shape).
    final entityPending =
        (venueAsync?.isLoading ?? false) || (eventAsync?.isLoading ?? false);
    final tipEnabled =
        EnvironmentConfig.dailyDropTipEnabled ||
        ref.watch(experimentServiceProvider).enableDailyDropTip;

    final actionCells = entityPending
        ? const <Widget>[]
        : _actionCells(context, ref, venue: venue, event: event);

    // Everything below the branded header, in order. The header carries the
    // wordmark Hero that flies in from the feed card; this block is deferred
    // off those flight frames and revealed once it lands (fade + slide-up),
    // matching venue/event detail. See [SokoRevealOnSettle].
    final belowHeader = <Widget>[
      // 3 — name, then the tag chip row directly under it.
      Text(
        drop.title ?? l10n.discoveryDailyDropTitle,
        style: const TextStyle(
          fontFamily: 'SeasonMix',
          fontSize: 42,
          fontWeight: FontWeight.w300,
          height: 0.94,
          letterSpacing: -0.84,
          color: AppColors.sokoInk,
        ),
      ),
      _TypeChip(kind: kind),
      // Event drops carry a `category · city · date` line under the chip;
      // it fills in with the fetch, because every field it needs lives on
      // the detail/occurrence payloads rather than the drop.
      if (event != null) _EventSubtitle(snapshot: event),
      // Venue drops carry the same shape one field shorter — `type · city`
      // (PROD-3978). It fills in with the fetch for the same reason.
      if (venue != null) _VenueSubtitle(snapshot: venue),
      // 4 — the tip's slot, admin-only for now behind the PostHog
      // `daily-drop-tip` flag. Off (the default, and where a PostHog
      // outage lands) collapses it to nothing — the same shape the page
      // already has for a drop with no reason, so the rhythm is unchanged
      // either way.
      if (tipEnabled) DailyDropTipSlot(reason: drop.reason),
      if (heroImages.isNotEmpty) ...[
        const SizedBox(height: 30),
        // 5 — photo.
        SokoPhotoCollage(imageUrls: heroImages, seed: collageSeed, kind: kind),
      ],
      if (descriptionShort != null) ...[
        const SizedBox(height: 30),
        // 6 — curated short description, for the right subject: it comes
        // off the entity's own detail response, so an event drop shows the
        // event's description rather than its venue's.
        Text(
          descriptionShort,
          style: const TextStyle(
            fontFamily: 'ZalandoSans',
            fontWeight: FontWeight.w300,
            fontSize: 14,
            height: 1.2,
            letterSpacing: -0.14,
            color: AppColors.sokoShade1,
          ),
        ),
      ],
      if (actionCells.isNotEmpty) ...[
        const SizedBox(height: 16),
        // 7 — action bar. Equal-width cells, as on venue/event detail, so
        // a past-tense caption flip (Save → Saved) doesn't shift its
        // neighbours.
        Row(
          // Top-align so a wrapped 2-line caption grows downward and the
          // glyphs stay level across cells.
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [for (final cell in actionCells) Expanded(child: cell)],
        ),
      ],
      // 8 — CTA. Entity-backed drops walk onto the entity; entity-less
      // ones keep the external link. A drop whose entity 404'd gets
      // neither: the destination page would 404 the same way.
      ..._ctaSlot(
        context,
        ref,
        hasEntity: hasEntity,
        venue: venue,
        event: event,
      ),
    ];

    return Padding(
      padding: EdgeInsets.fromLTRB(15, 0, 15, bottomPad),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 2 — branded header. Owns its own 30 px rhythm above and below.
          DailyDropDetailHeader(kind: kind, dropDate: _generatedAt()),
          SokoRevealOnSettle(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: belowHeader,
            ),
          ),
        ],
      ),
    );
  }

  /// The action-bar cells for this drop's shape.
  ///
  ///   - entity-backed + loaded → save · share · 👍 · 👎 (thumbs auth-gate
  ///     themselves and return nothing when signed out)
  ///   - entity-less, still loading, or the fetch failed → share only
  ///
  /// Save and the thumbs both need a real entity, so they simply aren't built
  /// without one — which is also what makes the 404 path fall out for free
  /// rather than needing a branch of its own. Share always works: an
  /// entity-less drop shares its external URL, and a drop mid-fetch already
  /// knows the entity id it will share.
  List<Widget> _actionCells(
    BuildContext context,
    WidgetRef ref, {
    required VenueDetailSnapshot? venue,
    required EventDetailSnapshot? event,
  }) {
    final share = _shareCell();
    return [
      if (venue != null)
        SokoSaveButton(
          venue: venue.venue,
          bare: true,
          source: ListSource.dailyDrop,
        ),
      if (event != null)
        EventSaveButton(
          event: event.event,
          occurrences: event.occurrences,
          bare: true,
          source: ListSource.dailyDrop,
        ),
      // Event drops get the reminder bell too — the same widget event detail
      // mounts, so reminder state is shared rather than re-implemented. It
      // keeps its own self-hiding rule: omitted entirely on a past-only event
      // (no future occurrence to remind about), which also keeps the remaining
      // Expanded cells evenly spaced instead of leaving a blank one.
      if (event != null && _hasFutureOccurrence(event))
        EventReminderBellButton(snapshot: event),
      if (share != null) share,
      if (venue != null)
        ...signalThumbCells(
          context,
          ref,
          entityType: SignalEntityType.venue,
          entityId: venue.venue.id,
          provenance: SignalProvenance.dailyDrop,
        ),
      if (event != null)
        ...signalThumbCells(
          context,
          ref,
          entityType: SignalEntityType.event,
          entityId: event.event.id,
          provenance: SignalProvenance.dailyDrop,
        ),
    ];
  }

  /// Share, with the URL rule that matters most on this page.
  ///
  /// An entity-backed drop shares the **entity's** public URL — exactly what
  /// venue/event detail sends today — attributed as `daily-drop` + the
  /// recommendation id. Only an entity-less drop shares `externalUrl ?? /drop`.
  /// Reusing the entity-less URL for everyone would send every recipient to
  /// *their own* daily drop instead of the pick that was shared.
  ///
  /// The id travels from the drop payload, not the fetch, so share is available
  /// before the entity lands and survives a 404.
  Widget? _shareCell() {
    final recommendationId = drop.recommendationId;

    final (
      String url,
      String fallbackContext,
      String? fallbackId,
    ) = switch (resolveDailyDropEntity(drop)) {
      DailyDropVenue(:final venueId) => (
        buildVenueShareUrl(venueIdentifier: venueId),
        'venue',
        venueId,
      ),
      DailyDropEvent(:final eventId) => (
        buildEventShareUrl(eventIdentifier: eventId),
        'event',
        eventId,
      ),
      DailyDropNoEntity() => (
        _firstNonEmpty([drop.externalUrl]) ?? '${ApiConstants.webappUrl}/drop',
        'daily-drop',
        null,
      ),
    };

    // Drop-context attribution when we have a recommendation to attribute to;
    // otherwise fall back to plain entity attribution rather than dropping the
    // affordance. An entity-less drop with no recommendation id has neither, so
    // it renders no share cell — as today's screen already does.
    final entityId = recommendationId ?? fallbackId;
    if (entityId == null) return null;
    return DetailShareCell(
      shareContext: recommendationId != null ? 'daily-drop' : fallbackContext,
      entityId: entityId,
      shareUrl: url,
    );
  }

  List<Widget> _ctaSlot(
    BuildContext context,
    WidgetRef ref, {
    required bool hasEntity,
    required VenueDetailSnapshot? venue,
    required EventDetailSnapshot? event,
  }) {
    final l10n = Lt.of(context);

    if (hasEntity) {
      final isEvent = event != null;
      final entityId = isEvent ? event.event.id : venue!.venue.id;
      return [
        const SizedBox(height: 30),
        SokoCtaButton(
          label: isEvent
              ? l10n.dailyDropDetailMoreAboutEvent
              : l10n.dailyDropDetailMoreAboutVenue,
          icon: LucideIcons.arrow_right,
          variant: SokoCtaVariant.ink,
          onPressed: () {
            ref
                .read(unifiedAnalyticsProvider)
                .trackDailyDropEntityCtaTap(
                  recommendationId: drop.recommendationId,
                  itemType: drop.itemType,
                  entityType: isEvent ? 'event' : 'venue',
                  entityId: entityId,
                  hasReason: (drop.reason?.trim().isNotEmpty ?? false),
                );
            context.push(isEvent ? '/events/$entityId' : '/venues/$entityId');
          },
        ),
      ];
    }

    // No local entity: keep the external link. Absent entirely when the entity
    // fetch failed — see the class doc.
    if (resolveDailyDropEntity(drop) is! DailyDropNoEntity) return const [];
    final externalUrl = _externalUrl();
    if (externalUrl == null) return const [];
    return [
      const SizedBox(height: 30),
      SokoCtaButton(
        label: (drop.externalUrl?.isNotEmpty ?? false)
            ? l10n.dailyDropDetailOpenLink
            : l10n.dailyDropDetailOpenMaps,
        icon: LucideIcons.external_link,
        variant: SokoCtaVariant.ink,
        onPressed: () => _openExternal(externalUrl),
      ),
    ];
  }

  Future<void> _openExternal(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(
      uri,
      mode: kIsWeb
          ? LaunchMode.platformDefault
          : LaunchMode.externalApplication,
      webOnlyWindowName: '_blank',
    );
  }
}

/// Element 3's type chip — `Sítio` for a place pick, `Evento` for an event.
///
/// **Only the type chip.** Not `VenueTagRow` / `EventTagRow`: those bundle the
/// ★ rating + count and save-count chips, which this page deliberately drops,
/// and the entity's own `tags` are raw untranslated slugs
/// (`botanical_garden · attraction · park`) so they are not shown either.
///
/// It reads `drop.itemType`, which is in memory, so the chip paints on the
/// first frame and never waits on — or changes with — the entity fetch. The
/// drop payload's own `tags` are not an alternative source: `user_recommendations`
/// has no tags column and the response builder never populates one, so
/// `DailyDrop.tags` is `[]` for every drop by construction.
class _TypeChip extends StatelessWidget {
  final SokoEntityKind kind;

  const _TypeChip({required this.kind});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isEvent = kind == SokoEntityKind.event;
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Align(
        alignment: Alignment.centerLeft,
        child: SokoTag(
          background: isEvent
              ? AppColors.sokoEventAccent
              : AppColors.sokoVenueAccent,
          child: Text(
            isEvent
                ? l10n.eventDetailTagTypeEvent
                : l10n.venueDetailTagTypeVenue,
            style: SokoTag.textStyle,
          ),
        ),
      ),
    );
  }
}

/// `type · city` under the type chip — **venue drops only** (PROD-3978).
///
/// The venue half of [_EventSubtitle], and it needs neither of that widget's
/// two workarounds: a venue's city is right there on `VenueDetailOut.city`
/// (it is the event case where the top-level city is null and the occurrence
/// has to answer instead), and a venue has no date.
///
///   - **type** is `primary_tag`, which the backend resolves into the caller's
///     locale (ADR-048). Rendered verbatim — see [VenueDetailResponse.primaryTag].
///     Until PROD-3960 this response carried no type label at all, which is why
///     this line did not exist before rather than why it was short.
///
/// Both halves are independently optional, so a typeless venue degrades to
/// city-only and a venue with neither renders nothing.
class _VenueSubtitle extends StatelessWidget {
  final VenueDetailSnapshot snapshot;

  const _VenueSubtitle({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final venue = snapshot.venue;
    // Trimmed, matching the venue page's chip: "verbatim" is about not
    // transforming the LABEL (no humanize, no title-case, no slug→label
    // mapping), not about preserving insignificant surrounding whitespace,
    // which inside a subtitle would render as a visible gap. `_nonEmpty` is
    // deliberately left alone — it is shared with `_EventSubtitle`, whose
    // fields belong to PROD-3950.
    final type = _nonEmpty(venue.primaryTag)?.trim();
    final city = _nonEmpty(venue.city)?.trim();
    final parts = <String>[if (type != null) type, if (city != null) city];
    if (parts.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        parts.join(' · '),
        style: const TextStyle(
          fontFamily: 'ZalandoSans',
          fontWeight: FontWeight.w300,
          fontSize: 14,
          height: 1.2,
          letterSpacing: -0.14,
          color: AppColors.sokoShade1,
        ),
      ),
    );
  }
}

/// `category · city · date` under the type chip — **event drops only**.
///
/// Every field here has a non-obvious source, and the obvious one is wrong for
/// each:
///
///   - **category** comes off the detail response, which the backend localizes
///     (`Música`). `drop.category` is the raw English slug (`music`) — the same
///     untranslated-slug problem that kept the entity tags off this page.
///   - **city** comes off the *occurrence*: an event's city lives there, and the
///     detail response's top-level `city` is null for events without a linked
///     venue. Falls back to the occurrence venue's city.
///   - **date** comes off the legacy occurrences. `EventDetailResponse2` returns
///     none, and `drop.startAt` / `drop.date` are always null — neither column
///     exists on `user_recommendations`.
///
/// The time is appended only when it is genuinely known: a `start_at` of exactly
/// `00:00:00` is the crawler's "time unknown" sentinel, not midnight.
class _EventSubtitle extends StatelessWidget {
  final EventDetailSnapshot snapshot;

  const _EventSubtitle({required this.snapshot});

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    final occurrence = snapshot.occurrences.isNotEmpty
        ? snapshot.occurrences.first
        : null;

    String? dateLabel;
    if (occurrence != null) {
      final local = occurrence.startAt.toLocal();
      dateLabel = DateFormat('d MMMM', locale).format(local);
      if (occurrence.hasKnownStartTime) {
        dateLabel = '$dateLabel, ${DateFormat('HH:mm', locale).format(local)}';
      }
    }

    final category = _nonEmpty(snapshot.event.category);
    final city = _nonEmpty(occurrence?.locationCity ?? occurrence?.venueCity);
    final parts = <String>[
      if (category != null) category,
      if (city != null) city,
      if (dateLabel != null) dateLabel,
    ];
    if (parts.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        parts.join(' · '),
        style: const TextStyle(
          fontFamily: 'ZalandoSans',
          fontWeight: FontWeight.w300,
          fontSize: 14,
          height: 1.2,
          letterSpacing: -0.14,
          color: AppColors.sokoShade1,
        ),
      ),
    );
  }
}

/// Mirrors the bell's own `upcoming` filter on event detail (instant
/// granularity), so the two surfaces agree on when the cell exists.
bool _hasFutureOccurrence(EventDetailSnapshot snapshot) {
  final now = DateTime.now();
  return snapshot.occurrences.any((o) => o.startAt.isAfter(now));
}

String? _nonEmpty(String? s) => (s != null && s.trim().isNotEmpty) ? s : null;

String? _firstNonEmpty(List<String?> candidates) {
  for (final c in candidates) {
    if (c != null && c.isNotEmpty) return c;
  }
  return null;
}
