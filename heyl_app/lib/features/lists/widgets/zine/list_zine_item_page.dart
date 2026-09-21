import 'dart:ui';

import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';

import '../../../../shared/notifications/heyl_notification.dart';
import '../../../../shared/notifications/notification_state.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/router/list_item_routes.dart';
import '../../../../core/services/unified_analytics_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/event_timing_chip.dart';
import '../../../../core/utils/event_when_formatter.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/auth_gating.dart';
import '../../../../data/models/models.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../providers/lists_provider.dart' show isItemSavedProvider;
import '../../../../shared/widgets/rotated_date_tag.dart';
import '../../../../shared/widgets/soko_toggle_glyph.dart';
import '../../../../providers/location_provider.dart';
import '../../../../shared/utils/user_location_marker.dart';
import '../../../../shared/widgets/dotted_line.dart';
import '../../../../shared/widgets/dotted_section_divider.dart';
import '../../../../shared/widgets/person_dot.dart';
import '../../../../shared/widgets/press_pop.dart';
import '../../../map/utils/map_pin_labels.dart' show truncateMapPinTitle;
import '../../../../shared/utils/map_pin_assets.dart';
import '../../../../shared/widgets/mapbox_map_widget.dart';
import '../../providers/unified_list_provider.dart';
import '../../providers/venue_events_provider.dart';
import '../../utils/list_calendar_map_helpers.dart';
import '../../utils/zine_item_color.dart';
import '../../utils/occurrence_markers.dart';
import '../../utils/open_in_list_item_detail.dart';
import '../../utils/zine_hero_tags.dart';
import '../add_to_list_sheet.dart';
import '../guest_blur_cta_card.dart';
import '../list_calendar_view.dart';
import 'dart:async';

import 'list_zine_hero_slot.dart';
import 'list_zine_tease_peel.dart';

/// Content floor for the zine `TurnPageView` page height (cover + item
/// pages share the same slot). `ListZineView` sizes each page as
/// `max(width × 5/4, kListZinePageMinHeight)` — pure 4:5 on every
/// viewport except SE-class phones, where the floor kicks in to preserve
/// the item card's `Expanded` hero photo `minHeight: 150` against the
/// worst-case content stack (title + 2-line description + 40 px buttons +
/// address + hours + paddings ≈ 375 px). 400 leaves a ~25 px safety
/// buffer over that worst case for font-metric variance. Above ~320 px
/// viewport widths, `width × 5/4` exceeds this floor and the cover
/// renders at true 4:5 (D110).
const double kListZinePageMinHeight = 400;

/// PROD-4072 — the category • type eyebrow style on zine detail pages.
/// HEX Franklin (condensed semibold) uppercased, Soko/Ink. The font is
/// bundled as `HEXFranklin`; if the asset is missing Flutter falls back to
/// the default sans until it's added.
const TextStyle kZineEyebrowStyle = TextStyle(
  fontFamily: 'HEXFranklin',
  fontWeight: FontWeight.w600,
  fontSize: 14,
  height: 1.0,
  letterSpacing: -0.14,
  color: AppColors.sokoInk,
);

/// PROD-4072 — the single circular bookmark affordance on a zine detail
/// page (Soko/Ink at 10% fill, 40px). Reflects saved state with the shared
/// Soko saved-language: an ink outline bookmark at rest, a solid Soko/Ink
/// filled bookmark when saved (see D295). Taps open the add-to-list sheet.
class _ZineBookmarkButton extends StatelessWidget {
  const _ZineBookmarkButton({required this.saved, required this.onTap});

  final bool saved;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // Same tap pop as the detail-row save/like/dislike (PressPop), replacing
    // the Material ink ripple so the save feels consistent everywhere.
    return PressPop(
      onTap: onTap,
      child: Container(
        width: 40,
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.sokoInk.withValues(alpha: 0.1),
          shape: BoxShape.circle,
        ),
        child: SokoToggleGlyph.bookmarkChip(active: saved),
      ),
    );
  }
}

/// One zine item card (page N >= 1) — pure visual, sized by its parent
/// (the zine view's `TurnPageView` slot). Tap on the card body opens
/// the in-list item detail; horizontal drag is owned by the parent
/// `TurnPageView` which handles the page-flip animation.
///
/// The map / calendar / suggestions content for the item lives in
/// [ListZineItemAux] which the zine view places below the pager.
class ListZineItemCard extends ConsumerStatefulWidget {
  final UserListItem item;
  final int pageNumber;
  final String listId;

  /// Static page-number label shown at the top-right corner of the
  /// card. The cover renders no label (`null` from the host); items
  /// render the new display numbering ("1", "2", …). When the tease
  /// peel opens, the clip-triangle paints over this label — the
  /// tease's "next page" number takes over visually until the peel
  /// retracts.
  final String? pageLabel;

  /// Optional next-page label rendered inside the looping corner-peel
  /// "tease" overlay. Pass null on the last page to disable the tease.
  final String? teaseNextLabel;

  /// Whether this card is currently the foreground page in the pager.
  /// Drives the auto-fade of the [pageLabel]: visible *throughout*
  /// any flip in or out of this page, then fades out 1s after the
  /// page settles as the active one. Inactive cards keep the label at
  /// opacity 1 so when they're revealed mid-flip (the back of the
  /// outgoing page peels back to expose this card's front), the
  /// label reads through. Only the currently-active card auto-fades
  /// after sitting idle for 1s.
  final bool isActive;

  /// Full list of items the card belongs to (used to seed swipe-sibling
  /// navigation in the in-list detail). Order is the rendered zine
  /// order. Optional — when null, swipe is disabled in the destination.
  final List<UserListItem>? allItems;

  /// PROD-1979 — when true, the card content is rendered blurred with a
  /// sign-in CTA card overlaid. Tap is blocked. Set by the parent zine
  /// view for pages beyond the guest cap (`guestVisibleItemCount`).
  final bool isBlurred;

  /// Onboarding "sandbox" mode (mirrors the `sandbox` flag on
  /// `VenueDetailBody` / `EventDetailBody`). When true, the card keeps
  /// its visual content but suppresses every external/cross-screen
  /// action (add-to-list, share, IG, add-photo) and re-routes the
  /// card-body tap + "Vê mais" to [onSandboxTap] instead of the in-list
  /// detail route — so the whole flow stays inside the onboarding gate.
  final bool sandbox;

  /// Sandbox tap handler — invoked with [item] when the card body or
  /// "Vê mais" is tapped in [sandbox] mode. Null → taps are inert.
  final void Function(UserListItem item)? onSandboxTap;

  const ListZineItemCard({
    super.key,
    required this.item,
    required this.pageNumber,
    required this.listId,
    this.allItems,
    this.pageLabel,
    this.teaseNextLabel,
    this.isActive = false,
    this.isBlurred = false,
    this.sandbox = false,
    this.onSandboxTap,
  });

  @override
  ConsumerState<ListZineItemCard> createState() => _ListZineItemCardState();
}

class _ListZineItemCardState extends ConsumerState<ListZineItemCard> {
  /// Whether this item is in any list the user owns — the same source every
  /// other bookmark in the app watches, so the icon here can't drift from the
  /// one on the item's own detail page. `watch`, not `read`: the quicksave
  /// flips this synchronously now, so the icon fills on the tap.
  bool get _isSaved => ref.watch(isItemSavedProvider)(
    eventId: widget.item.eventId,
    venueId: widget.item.venueId,
    googlePlaceId: widget.item.googlePlaceId,
  );

  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    final l10n = Lt.of(context);
    // PROD-4072 — two distinct texts: the item's own description sits under
    // the title, and the curator's note (the saved item's `tip`) sits in
    // the lower-left band (where the page indicator used to be). Either may
    // be absent, in which case its slot is simply omitted.
    final description = item.descriptionShort;
    final note = item.tip?.trim();
    final imageUrl = item.imageUrl;

    // PROD-4160-followup — the entity this card taps through to, and whether
    // this card should own the shared-element Hero pair (poster + colour
    // panel) that flies into the in-list detail page. Only the currently
    // front page mounts the Heroes (the pager keeps neighbours + the cover's
    // tease-underlay mounted, so an un-gated Hero would assert a duplicate
    // tag). Blurred/sandbox cards never reach the real detail route, so they
    // stay Hero-free. `entityId` matches [openInListItemDetail]'s id.
    final entityId = item.eventId ?? item.venueId;
    final heroEnabled =
        widget.isActive &&
        !widget.isBlurred &&
        !widget.sandbox &&
        entityId != null;

    // PROD-4072 — the card background is a light pastel derived once from
    // the item's poster image and cached forever (keyed by stable item id).
    // Sync cache hit paints the right colour on the first frame; a miss
    // fills in via the FutureProvider and eases in through AnimatedContainer.
    // Falls back to the neutral Shade5 while loading / on failure / no image.
    final colorItemId =
        item.eventId ?? item.venueId ?? item.googlePlaceId ?? item.id;
    final bgColor =
        ref
            .watch(
              zineItemColorProvider(
                ZineItemColorKey(itemId: colorItemId, imageUrl: imageUrl),
              ),
            )
            .valueOrNull ??
        cachedZineItemColor(ref, colorItemId) ??
        AppColors.sokoShade5;

    // PROD-4072 — eyebrow (category • type) + in-card page indicator.
    final categoryLabel = (item.category ?? '').trim().toUpperCase();
    final typeLabel =
        (item.itemType == SavedItemType.event
                ? l10n.detailTypeBadgeEvent
                : l10n.detailTypeBadgePlace)
            .toUpperCase();

    // PROD-4160-followup — the background colour is its own layer (behind the
    // card content) so it (and only it) can fly as a Hero into the detail
    // page's coloured card region, while the poster flies separately. Keeping
    // them as two sibling layers (rather than one coloured container wrapping
    // the content) is what lets both be Heroes without nesting, which Flutter
    // forbids. The 250ms colour ease is preserved on the panel.
    Widget colourPanel = AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
      ),
    );
    if (heroEnabled) {
      colourPanel = Hero(
        tag: zineDetailColorHeroTag(entityId),
        child: colourPanel,
      );
    }

    final cardContent = Padding(
      padding: const EdgeInsets.all(15),
      child: LayoutBuilder(
        builder: (context, cardConstraints) {
          // Everything below is proportioned off the card's inner content
          // width so it tracks the Figma reference (400px card → 370px
          // content) at any screen size.
          final contentW = cardConstraints.maxWidth;
          // Figma title band is a fixed 127px zone on a 370px-content card:
          // solid rule pinned top, title top-aligned, dashed rule pinned
          // bottom. Scale it with the card and clamp so it neither collapses
          // on tiny phones nor blows out into a huge gap on wide/desktop.
          final bandH = (contentW * 127 / 370).clamp(80.0, 140.0);
          // Bottom row splits into equal halves per Figma (left details +
          // poster), 10px gutter; poster is 4:5 (180×225 on a 400px card).
          final posterW = (contentW - 10) / 2;
          final posterH = posterW * 5 / 4;
          // The rotated relative-timing chip over the title (Past event /
          // Today / … / Recurring event / an exhibition phase). Events only;
          // resolved from the whole occurrence set so a recurring series isn't
          // mislabelled "Past event". The clean absolute date always lives in
          // the details row below.
          final timingChip = chipForUserListItem(context, item);
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // PROD-4072 — category • type eyebrow (HEX Franklin condensed),
              // left/right justified like the Figma header.
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (categoryLabel.isNotEmpty)
                    Flexible(
                      child: Text(
                        categoryLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: kZineEyebrowStyle,
                      ),
                    ),
                  const SizedBox(width: 8),
                  Text(typeLabel, maxLines: 1, style: kZineEyebrowStyle),
                ],
              ),
              const SizedBox(height: 12),
              // Title band (fixed-height per Figma): solid rule pinned top,
              // big SeasonMix title top-aligned, dashed rule pinned bottom —
              // so a short title leaves the Figma gap above the dashed rule.
              // The relative-timing sticker rides the poster thumbnail below,
              // not the title.
              SizedBox(
                height: bandH,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(height: 1, color: AppColors.sokoInk),
                    const SizedBox(height: 6),
                    if (item.title != null)
                      // `applyHeightToLastDescent: false` keeps the tight 0.9
                      // ascent (the design rhythm) while letting descenders
                      // (g, p, q, y) use the font's natural descent so they
                      // don't clip. Expanded gives AutoSizeText the full band
                      // to shrink the 66px display size into for long titles.
                      Expanded(
                        child: Align(
                          alignment: Alignment.topLeft,
                          child: AutoSizeText(
                            item.title!,
                            maxLines: 2,
                            minFontSize: 20,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontFamily: 'SeasonMix',
                              fontSize: 66,
                              fontWeight: FontWeight.w400,
                              height: 0.9,
                              letterSpacing: -1.32,
                              color: AppColors.sokoInk,
                            ),
                          ),
                        ),
                      )
                    else
                      const Spacer(),
                    const DottedLine(
                      color: AppColors.sokoInk,
                      spacing: 3.5,
                      dotSize: 0.5,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // Description (Mobile/B1 Reg — Zalando Light 18px, Soko/Ink).
              if (description != null && description.isNotEmpty)
                Text(
                  description,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.mobileB1Reg(color: AppColors.sokoInk),
                ),
              const SizedBox(height: 12),
              // Bottom row: details + curator note + bookmark (left column)
              // beside the poster thumbnail (right). Replaces the old
              // full-width hero + multi-action row: per the Figma the card
              // shows only the bookmark; the whole card still taps through to
              // the in-list detail (handled by the wrapping GestureDetector).
              // Flexible spacer absorbs the free vertical space so the bottom
              // group is anchored to the BOTTOM of the card (per the Figma) —
              // the details are NOT pinned directly under the title; they sit
              // in the lower band, aligned with the top of the poster.
              const Spacer(),
              SizedBox(
                // Poster is half the card width at 4:5, so it drives the row
                // height and the left-column details line up with its top.
                height: posterH,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        // Figma distributes the left column top→bottom: detail
                        // rows at the top, the curator note in the middle, the
                        // bookmark pinned to the bottom.
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          // Detail rows (icons + Soko/Ink text), top-aligned to
                          // the poster.
                          _DetailsGrid(item: item),
                          // Curator's note (the saved item's tip) — occupies
                          // the middle band. Prefixed with the note author's
                          // avatar (the "liked by" PersonDot: their photo when
                          // available, else their seeded initial), aligned like
                          // a detail row.
                          if (note != null && note.isNotEmpty)
                            Flexible(
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  if ((item.addedByAvatarUrl?.isNotEmpty ??
                                          false) ||
                                      (item.addedByName?.isNotEmpty ??
                                          false)) ...[
                                    PersonDot(
                                      url: item.addedByAvatarUrl,
                                      name: item.addedByName,
                                      seed: item.addedById,
                                      size: 14,
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                  Expanded(
                                    child: Text(
                                      note,
                                      maxLines: 4,
                                      overflow: TextOverflow.ellipsis,
                                      style: AppTheme.mobileB2Reg(
                                        color: AppColors.sokoInk,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            )
                          else
                            const SizedBox.shrink(),
                          if (!widget.sandbox)
                            _ZineBookmarkButton(
                              saved: _isSaved,
                              onTap: _openAddToListSheet,
                            )
                          else
                            const SizedBox.shrink(),
                        ],
                      ),
                    ),
                    const SizedBox(width: 10),
                    // Poster thumbnail (4:5), replacing the old full-width hero.
                    // The relative-timing sticker rides its top-right corner,
                    // tilted (layered outside the ClipRRect so it can bleed past
                    // the rounded corner via clipBehavior none).
                    SizedBox(
                      width: posterW,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // PROD-4160-followup — the poster flies up to the
                          // detail page's top collage tile (same Hero tag; the
                          // collage main tile already carries it). The rotated
                          // date tag stays a sibling OUTSIDE the Hero so it
                          // doesn't fly, mirroring the collage's cornerBadge.
                          _maybeHero(
                            enabled: heroEnabled,
                            tag: heroEnabled
                                ? zineDetailPosterHeroTag(entityId)
                                : '',
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: ListZineHeroSlot(
                                imageUrl: imageUrl,
                                // Sandbox is read-only — no add-photo affordance.
                                onAddPhotoTap: widget.sandbox
                                    ? null
                                    : () => _showAddPhotoComingSoon(context),
                              ),
                            ),
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
                                // Zine pages share one on-screen slot; stamp
                                // only when this card turns to the front.
                                active: widget.isActive,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );

    final card = ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Stack(
        children: [
          // Background colour panel behind the content (non-positioned
          // `cardContent` sizes the Stack; the fill layers ride its bounds).
          Positioned.fill(child: colourPanel),
          cardContent,
          // PROD-4072 — the page indicator now lives inside the card's
          // left column ("Pág. N", per the Figma), so there's no longer a
          // fading top-right corner label here; only the tease overlay.
          if (widget.teaseNextLabel != null)
            Positioned.fill(
              child: ListZineTeasePeel(nextLabel: widget.teaseNextLabel!),
            ),
        ],
      ),
    );

    // PROD-1979 — guest blur. The card content is rendered behind a
    // sign-in CTA. Taps on the card body are absorbed by IgnorePointer;
    // the only interactive surface is the CTA's sign-in button.
    if (widget.isBlurred) {
      return Stack(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: ImageFiltered(
              imageFilter: ImageFilter.blur(sigmaX: 6, sigmaY: 6),
              child: IgnorePointer(child: Opacity(opacity: 0.5, child: card)),
            ),
          ),
          Positioned.fill(
            child: Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: GuestBlurCtaCard(
                  compact: true,
                  onSignIn: () => navigateToLoginPreservingReturn(
                    context,
                    ref,
                    referrer: AuthReferrer.guestListBlurCta,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }

    // Card body owns the tap (open in-list detail). Horizontal drag is
    // handled by the parent `TurnPageView`, so this detector only
    // listens for taps. Guardar / Vê mais GestureDetectors win the
    // gesture arena for taps inside themselves.
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => _handleCardTap(context),
      child: card,
    );
  }

  /// Wraps [child] in a [Hero] with [tag] when [enabled]; otherwise returns
  /// [child] unchanged. Keeps the shared-element flight opt-in to the active,
  /// non-blurred, non-sandbox card only.
  Widget _maybeHero({
    required bool enabled,
    required String tag,
    required Widget child,
  }) => enabled ? Hero(tag: tag, child: child) : child;

  /// Whole-card / "Vê mais" tap. In [ListZineItemCard.sandbox] mode the
  /// tap is handed to [ListZineItemCard.onSandboxTap] (opens the onboarding
  /// sandbox detail); otherwise it opens the real in-list item detail.
  void _handleCardTap(BuildContext context) {
    if (widget.sandbox) {
      widget.onSandboxTap?.call(widget.item);
      return;
    }
    _openInListDetail(context);
  }

  void _openInListDetail(BuildContext context) {
    openInListItemDetail(
      context,
      ref: ref,
      listId: widget.listId,
      tapped: widget.item,
      allItems: widget.allItems ?? const <UserListItem>[],
    );
    // Reference AppRoutes to keep the import meaningful in case the path
    // shape changes — kept inline so the cancellation of an unused import
    // doesn't fire when the lint runs.
    assert(AppRoutes.listVenueDetail.startsWith('/lists'));
  }

  void _showAddPhotoComingSoon(BuildContext context) {
    showAddPhotoComingSoonSnackBar(context);
  }

  /// PROD-1861 — open the redesigned add-to-list bottom sheet for this
  /// item. Mirrors the conversion logic in `list_item_row.dart`: maps the
  /// `UserListItem` we already have to the `ItemSuggestion` shape that
  /// `showAddToListSheet` expects.
  Future<void> _openAddToListSheet() async {
    final item = widget.item;
    final place = ItemSuggestion(
      id: item.venueId ?? item.eventId ?? item.id,
      type: item.itemType == SavedItemType.event ? 'event' : 'place',
      eventId: item.eventId,
      venueId: item.venueId,
      googlePlaceId: item.googlePlaceId,
      name: item.title ?? '',
      imageUrl: item.imageUrl,
      category: item.category,
      address: item.address,
      city: item.city,
      latitude: item.latitude,
      longitude: item.longitude,
      // PROD-3829: forward the facet so a re-save from this surface keeps it.
      primaryFacet: item.primaryFacet,
    );
    await showAddToListSheet(
      context,
      place,
      ref: ref,
      source: ListSource.listUi,
      // PROD-3873 — quicksave on tap, half-open peek on a fresh save.
      quickSaveIfUnsaved: true,
      skipDrawerWhenSaving: true,
    );
  }
}

/// Auxiliary content rendered beneath an item card: the item's map (one
/// pin) + the calendar (venue items: every event at the venue; event
/// items: this event's occurrences) + (owner-only) the suggestions
/// section. See `docs/designs/list-page-redesign.md` § 7.
class ListZineItemAux extends ConsumerWidget {
  final UserListItem item;
  final UnifiedListState state;

  const ListZineItemAux({super.key, required this.item, required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final list = state.list;
    if (list == null) return const SizedBox.shrink();

    final isVenue = item.itemType == SavedItemType.place;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ── Map ──────────────────────────────────────────────────
        if (item.latitude != null && item.longitude != null) ...[
          const DottedSectionDivider(),
          _ItemMap(item: item, state: state),
        ],

        // ── Calendar (per § 31 + § 7) ─────────────────────────────
        // Venue with events: every event at the venue (PROD-1680
        // pagination). Event item: this event's occurrences. § 9.2 #9:
        // hide when no events.
        if (isVenue && item.venueId != null)
          _VenueEventsCalendar(venueId: item.venueId!)
        else if (!isVenue && item.eventDate != null)
          _EventOccurrencesCalendar(item: item),

        // ListSuggestionsSection removed (PROD-2004 final) — the
        // owner-only "Suggestions" block sat here. Feature disabled
        // while the search pipeline's Google-fallback parsing is sorted
        // out.
      ],
    );
  }
}

/// Shared notification shown when a user taps the bordered "Add photo"
/// placeholder on a zine hero. Lives at top-level so both the cover and
/// item pages reuse the exact same look + duration.
void showAddPhotoComingSoonSnackBar(BuildContext context) {
  final l10n = Lt.of(context);
  showSokoFromContext(
    context,
    message: l10n.listZineAddPhotoComingSoon,
    variant: SokoVariant.info,
    duration: const Duration(seconds: 3),
  );
}

class _DetailsGrid extends StatelessWidget {
  final UserListItem item;

  const _DetailsGrid({required this.item});

  @override
  Widget build(BuildContext context) {
    // PROD-4072 — the Figma detail block, populated from the info the
    // list-item actually carries. Icons + order match the design:
    //   Event : calendar (when) → pin (venue name, falling back to address)
    //           → ticket (price)
    //   Venue : pin (address)
    // Price is now carried on the list-item event payload as `price_label`
    // (added in PROD-4072, mirroring the discovery feed's `FeedEventItem
    // .price_label`) — an already-localized, already-formatted string that
    // is rendered verbatim and omitted when null (the common case). Venue
    // rating / opening-hours are still absent from the payload, so those
    // Figma rows remain omitted.
    final rows = <Widget>[];
    if (item.itemType == SavedItemType.event) {
      final start = item.eventDate;
      if (start != null) {
        // Always the clean, absolute calendar date ("Sex 12 Jul, 21h") — never
        // "Today" / "This weekend" / "Past event". The relative status (incl.
        // the past-event caveat) now lives in the rotated tag over the title
        // (see [eventRelativeTagLabel] + [RotatedDateTag]), so this row stays a
        // plain date and the two never compete.
        final dateText = formatEventDateAbsolute(
          context: context,
          startsAt: start,
          timeKnown: start.hour != 0 || start.minute != 0,
        );
        rows.add(_DetailRow(icon: LucideIcons.calendar, text: dateText));
      }
      // Show the location — venue name, then neighbourhood (finer than city),
      // then city. Never the full street address. PROD-4115 added venue_name +
      // neighbourhood to the list-item payload.
      final venueName = (item.event?['venue_name'] as String?)?.trim();
      final neighbourhood = item.neighbourhood?.trim();
      final location = (venueName != null && venueName.isNotEmpty)
          ? venueName
          : (neighbourhood != null && neighbourhood.isNotEmpty)
          ? neighbourhood
          : item.city;
      if (location != null && location.isNotEmpty) {
        rows.add(_DetailRow(icon: LucideIcons.map_pin, text: location));
      }
      // Sub-category (e.g. "Festival" under "Culture") + price share ONE line
      // (Figma `→ Festival · 🛒 Grátis`), mirroring the discovery hero card's
      // meta row (`feed_hero_card.dart`): category takes the move_right glyph,
      // price the shopping-cart. Either may be absent; the separator belongs to
      // the pair. `price_label` is rendered exactly as received (already
      // localized/formatted) — never re-format from the raw price fields.
      final subcategory = item.subcategory?.trim();
      final price = item.priceLabel?.trim();
      final hasSub = subcategory != null && subcategory.isNotEmpty;
      final hasPrice = price != null && price.isNotEmpty;
      if (hasSub || hasPrice) {
        rows.add(
          _CategoryPriceRow(
            category: hasSub ? subcategory : null,
            price: hasPrice ? price : null,
          ),
        );
      }
    } else {
      // Venue: the title is already the venue name, so surface the finer area —
      // neighbourhood, falling back to city (PROD-4115). Never the street.
      final neighbourhood = item.neighbourhood?.trim();
      final location = (neighbourhood != null && neighbourhood.isNotEmpty)
          ? neighbourhood
          : item.city;
      if (location != null && location.isNotEmpty) {
        rows.add(_DetailRow(icon: LucideIcons.map_pin, text: location));
      }
      // Secondary venue type (backend `types[1]`), beneath the eyebrow type.
      // move_right glyph to match the event category row + the discovery card.
      final subtype = item.subcategory;
      if (subtype != null && subtype.isNotEmpty) {
        rows.add(_DetailRow(icon: LucideIcons.move_right, text: subtype));
      }
    }
    if (rows.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var i = 0; i < rows.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          rows[i],
        ],
      ],
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String text;

  const _DetailRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    const color = AppColors.sokoInk;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Expanded(
          child: Text(text, style: AppTheme.mobileB2Reg(color: color)),
        ),
      ],
    );
  }
}

/// Category + price on a single detail line (Figma `→ Festival · 🛒 Grátis`),
/// mirroring the discovery hero card's combined meta row. Each half is a
/// content-sized icon+label (category = move_right, price = shopping_cart)
/// wrapped in `Flexible` (loose) so a short category hugs its content and the
/// price follows immediately, while a long category yields — ellipsizing —
/// rather than pushing the price off the card. The "·" separator only renders
/// when both are present. At least one of [category]/[price] is non-null by
/// construction.
class _CategoryPriceRow extends StatelessWidget {
  final String? category;
  final String? price;

  const _CategoryPriceRow({this.category, this.price});

  Widget _half(IconData icon, String text) {
    const color = AppColors.sokoInk;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.mobileB2Reg(color: color),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    const color = AppColors.sokoInk;
    final category = this.category;
    final price = this.price;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (category != null)
          Flexible(child: _half(LucideIcons.move_right, category)),
        if (category != null && price != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Text('·', style: AppTheme.mobileB2Reg(color: color)),
          ),
        if (price != null)
          Flexible(child: _half(LucideIcons.shopping_cart, price)),
      ],
    );
  }
}

class _ItemMap extends ConsumerWidget {
  final UserListItem item;
  final UnifiedListState state;

  const _ItemMap({required this.item, required this.state});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final locationState = ref.watch(locationProvider);
    final listId = state.list!.id;

    // PROD-2159 + PROD-2205: render every list pin so the user keeps
    // spatial context while paging through items. `state.mapPins` is
    // the whole-list pin set deduped server-side (PROD-1967). Falls
    // back to the current item alone when the pin set is empty
    // (defensive — shouldn't happen when the item itself has coords).
    final pinItems = state.mapPins.isNotEmpty
        ? state.mapPins.map((p) => slimMapPinToHeavy(p, listId)).toList()
        : <UserListItem>[item];

    final markers = <MapMarker>[];
    for (final it in pinItems) {
      if (it.latitude == null || it.longitude == null) continue;
      final category = it.itemType == SavedItemType.event
          ? MapMarkerCategory.event
          : MapMarkerCategory.venue;
      markers.add(
        MapMarker.letter(
          id: it.id,
          lat: it.latitude!,
          lng: it.longitude!,
          letter: 'A',
          category: category,
          data: it,
          // PROD-3830: teardrop from the item's facet (null → pink default).
          iconImage: mapPinKey(primaryFacet: it.primaryFacet),
          // PROD-3830: captions are ON here, so the marker has to carry the
          // text — `showPinCaptions` only installs the layer. See the twin
          // note in `list_map_view.dart`.
          pinTitle: (it.title?.trim().isNotEmpty ?? false)
              ? truncateMapPinTitle(it.title!.trim())
              : null,
        ),
      );
    }
    appendUserLocationMarker(markers, locationState);

    // PROD-2205: subset of pins that "belong to" the current zine
    // page's item — one pin for a place / single-venue event, N pins
    // for a multi-venue event. Matched by venueId / coord-key so it
    // survives the `SlimMapPin.itemId == earliest-added-item` aliasing.
    final selectedIds = selectedPinIdsForItem(item, state.mapPins);
    final selectedMarkers = markers
        .where((m) => selectedIds.contains(m.id))
        .toList(growable: false);
    final hasSelection = selectedMarkers.isNotEmpty;

    // PROD-2205: camera focus on the selected subset.
    //   1 pin  → centre + zoom 16 (beats `MapClusterTokens
    //            .sourceClusterMaxZoom` of 14 so the yellow pin never
    //            hides inside a cluster bubble).
    //   N pins → fit bbox of just those N (still `maxZoom: 16` so we
    //            don't over-zoom on co-located venues).
    //   none   → fall through to fit-all over `markers` (defensive;
    //            slim pins may not have arrived yet on first paint).
    double? centerLat;
    double? centerLng;
    double zoom = 14;
    MapBoundsConfig? boundsConfig;
    if (selectedMarkers.length == 1) {
      centerLat = selectedMarkers.first.lat;
      centerLng = selectedMarkers.first.lng;
      zoom = 16;
    } else if (selectedMarkers.length >= 2) {
      double minLat = selectedMarkers.first.lat;
      double maxLat = selectedMarkers.first.lat;
      double minLng = selectedMarkers.first.lng;
      double maxLng = selectedMarkers.first.lng;
      for (final m in selectedMarkers.skip(1)) {
        if (m.lat < minLat) minLat = m.lat;
        if (m.lat > maxLat) maxLat = m.lat;
        if (m.lng < minLng) minLng = m.lng;
        if (m.lng > maxLng) maxLng = m.lng;
      }
      boundsConfig = MapBoundsConfig(
        north: maxLat,
        south: minLat,
        east: maxLng,
        west: minLng,
        paddingTop: 40,
        paddingBottom: 40,
        paddingLeft: 40,
        paddingRight: 40,
        maxZoom: 16,
      );
    }

    return SizedBox(
      // PROD-2205-followup: unified zine map height. Cover map,
      // list-view body map, and this item-page map all share
      // kZineMapHeight so paging doesn't feel like the canvas
      // shrinks.
      height: kZineMapHeight,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: MapboxMapWidget(
          markers: markers,
          centerLat: centerLat ?? item.latitude,
          centerLng: centerLng ?? item.longitude,
          zoom: zoom,
          // PROD-2205: when we have a selection the camera is driven
          // by the explicit centre+zoom (single pin) or boundsConfig
          // (multi-pin). Only fall back to fit-all when the slim pins
          // haven't resolved yet.
          fitMarkers: !hasSelection,
          interactive: true,
          // PROD-2205-followup: chip gated behind a single flag
          // (kListMapsStaticByDefault = false today). Flip to true
          // for a rollback or A/B test.
          staticByDefault: kListMapsStaticByDefault,
          showFitAllButton: true,
          showMyLocationButton: true,
          // detailDefault is the fit-all fallback; the multi-pin
          // boundsConfig above overrides when we have ≥2 selected
          // markers.
          boundsConfig: boundsConfig ?? MapBoundsConfig.detailDefault,
          // PROD-2016: single rendering pipeline (cluster source-layer
          // path; legacy DOM-overlay path retired).
          cluster: true,
          // PROD-3830: facet teardrop pins. Full asset set + per-marker
          // `mapPinKey(primaryFacet:)`; `selectedMarkerIds` below now shows
          // as an icon-size bump (PROD-3828) rather than a circle radius,
          // since the circle is transparent under `categoryIcons`.
          categoryIcons: true,
          categoryIconAssets: kMapPinAssets,
          // Captions ON (umbrella decision #2) — a list map.
          showPinCaptions: true,
          // PROD-2205: highlight every pin belonging to the current
          // item (1 for places / single-venue events, N for multi-
          // venue events).
          selectedMarkerIds: hasSelection ? selectedIds : null,
          tooltipContentResolver: (marker) {
            final tappedItem = marker.data;
            if (tappedItem is! UserListItem) return null;
            final title = tappedItem.title;
            if (title == null || title.isEmpty) return null;
            final lt = Lt.of(context);
            return MapPinTooltipContent(
              title: title,
              subtitle: tappedItem.itemType == SavedItemType.event
                  ? lt.eventDetailTagTypeEvent
                  : lt.venueDetailTagTypeVenue,
            );
          },
          onViewDetails: (marker) {
            // Resolve back to the full heavy item from `state.items` —
            // slim-derived pins don't carry `eventId`, so navigation
            // for events would no-op without this lookup.
            final tapped = marker.data;
            if (tapped is! UserListItem) return;
            final full = state.items.firstWhere(
              (it) => it.id == tapped.id,
              orElse: () => tapped,
            );
            openInListItemDetail(
              context,
              ref: ref,
              listId: listId,
              tapped: full,
              allItems: state.items,
            );
          },
          analyticsContext: 'zine_item_aux',
        ),
      ),
    );
  }
}

/// Single-event calendar for event items in the zine. § 31 of the design
/// doc calls for "this event's occurrences" — `UserListItem.event` only
/// surfaces a single `eventDate` today (the list-items endpoint doesn't
/// inline occurrences). For richer multi-occurrence support, fetch the
/// full event via `getEventDetail` — deferred to a follow-up to avoid
/// per-page network fan-out.
class _EventOccurrencesCalendar extends ConsumerWidget {
  final UserListItem item;

  const _EventOccurrencesCalendar({required this.item});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final date = item.eventDate;
    if (date == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const DottedSectionDivider(),
        Container(
          decoration: BoxDecoration(
            color: AppColors.sokoInk.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(6),
          ),
          padding: const EdgeInsets.all(16),
          child: ListCalendarView(
            items: [item],
            currentMonth: DateTime(date.year, date.month, 1),
            // PROD-2018 follow-up — tap → push the event detail via
            // the shared helper; falls back to the standalone route
            // for items without a parent list.
            onItemTap: (tapped) => openItemDetail(context, ref, tapped),
          ),
        ),
      ],
    );
  }
}

class _VenueEventsCalendar extends ConsumerWidget {
  final String venueId;

  const _VenueEventsCalendar({required this.venueId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final eventsAsync = ref.watch(venueEventsProvider(venueId));
    return eventsAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (events) {
        if (events.isEmpty) return const SizedBox.shrink();

        // Convert to UserListItem-shaped wrappers for ListCalendarView.
        // The calendar widget reads `item.eventDate` from `event.start_datetime`.
        final calendarItems = [
          for (final e in events)
            UserListItem(
              id: e.eventId,
              listId: '',
              addedById: '',
              itemType: SavedItemType.event,
              eventId: e.eventId,
              addedAt: DateTime.now(),
              event: {
                'title': e.name,
                'start_datetime': e.startAt,
                'end_datetime': e.endAt,
                'category': e.category,
                'image_url': e.imageUrl,
                'url': e.url,
                'description_short': e.descriptionShort,
              },
            ),
        ];

        final autoMonth = autoPickMonthFromDates(
          events.map((e) => e.startDateTime),
        );
        if (autoMonth == null) return const SizedBox.shrink();

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const DottedSectionDivider(),
            Container(
              decoration: BoxDecoration(
                color: AppColors.sokoInk.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(6),
              ),
              padding: const EdgeInsets.all(16),
              child: ListCalendarView(
                items: calendarItems,
                currentMonth: autoMonth,
                // PROD-2018 follow-up — venue-events calendar items
                // are synthesised with empty listId, so the shared
                // helper falls back to the standalone event route.
                onItemTap: (tapped) => openItemDetail(context, ref, tapped),
              ),
            ),
          ],
        );
      },
    );
  }
}
