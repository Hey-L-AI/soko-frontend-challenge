// PROD-4006 — one row of a `bundle`. Figma `7304:23655` (400 × 80).
//
// Thumb, title, two meta lines, and a save button that acts on **this row's own
// item** (D22). The bundle has no block-level CTA in v0; the per-row save is it.
//
// **The row renders whichever entity the block declared** (D34, PROD-4108). The
// box, the thumb and the save button are identical for both; only the meta
// content differs, which is why this is one widget with a `switch` rather than
// two lookalikes that would drift the first time either changed.
//
// **The venue variant has no Figma frame** (Zé, 2026-09-01) and none was
// wanted — it is specified in prose, and the prose has moved once already. It
// shipped as PROD-4106 wrote it (name, then a single `neighbourhood · type`
// line); on 2026-09-08 Zé asked for the two facts on two meta lines, type
// first, so a venue row and an event row read the same way down the page. That
// is what `_venueContent` now builds, and the three-line venue lands on the
// same 66 px content column the event row already occupies inside the fixed
// 80 px box.
//
// Still deliberately absent, and both are decisions rather than gaps: opening
// hours (D134 — 7–16 % production coverage, stored as locale-formatted display
// strings, so a field blank for ~9 venues in 10 reads as broken rather than
// sparse) and the attribution line, deferred until bundles are reworked
// together.

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/app_theme.dart';
import '../../../../../core/utils/feed_event_date.dart';
import '../../../../../core/utils/soko_texture.dart';
import '../../../../../data/models/feed_home.dart';
import '../../../../../l10n/generated/l10n.dart';
import '../../../../../shared/widgets/cached_image.dart';
import '../../../../../shared/widgets/soko_card_image.dart';
import '../../../../../shared/widgets/circle_icon_button.dart';
import '../../../../../shared/widgets/soko_toggle_glyph.dart';
import '../../../../../shared/widgets/clickable.dart';
import '../../../../../shared/widgets/notched_edge.dart';
import '../../../../../shared/widgets/person_dot.dart';
import '../../../../../shared/widgets/soko_zine_corner_fold.dart';
import '../../../../entity_signals/providers/feed_going_seeds.dart';
import '../../../../lists/widgets/zine/list_zine_cover.dart';
import '../../../utils/attribution_prefix.dart';
import '../../utils/feed_item_save.dart';
import '../../utils/feed_zine_cover.dart';
import '../../utils/feed_zine_follow.dart';
import 'feed_block_atoms.dart';
import 'feed_going_row.dart';

class FeedBundleRow extends ConsumerWidget {
  final FeedItem? item;

  /// Opens the row's entity (PROD-4076). Null leaves the row inert.
  ///
  /// **The row body only** — the save button is a child of this row and wins
  /// the hit test, so tapping the bookmark still saves rather than navigating.
  final VoidCallback? onTap;

  /// Set by [FeedBundleRow.custom] (`/library` rows).
  final Widget? thumbnail;
  final String? title;
  final Widget? meta;
  final Widget? trailing;
  final double height;

  /// Whether this row's bundle opted into the friends-going social-proof line
  /// (`show_social_proof`). Off by default so a bundle that didn't ask — or a
  /// pre-flag backend — renders the plain venue line, never the going line.
  /// Only meaningful for event rows; venue/zine rows ignore it.
  final bool socialProof;

  const FeedBundleRow({
    super.key,
    required FeedItem this.item,
    this.onTap,
    this.socialProof = false,
  }) : thumbnail = null,
       title = null,
       meta = null,
       trailing = null,
       height = rowHeight;

  /// Same 400 × 80 chrome as the feed (`7304:23655`).
  const FeedBundleRow.custom({
    super.key,
    required Widget this.thumbnail,
    required String this.title,
    required Widget this.meta,
    this.trailing,
    this.onTap,
    this.height = rowHeight,
  }) : item = null,
       socialProof = false;

  /// Row box (`7304:23655`).
  static const double rowHeight = 80;

  /// Portrait thumbnail (`7304:23656`).
  static const double thumbWidth = 64;

  /// Content column starts at x76 — a 12 px gap after the thumb, and the same
  /// 12 again between the column's right edge (x348) and the save button at
  /// x360. One measurement, one name.
  static const double _thumbGap = 12;

  /// Gap between two things on a meta line — icon to text, text to the "•",
  /// the "•" to the next icon. `7304:23671` is one auto-layout row with
  /// `gap-[6px]` between **all** of its children, so the same number does all
  /// three jobs.
  ///
  /// This was 20 (and 12 around the separator) because the frame puts the date
  /// text at `x20` — but the icon in front of it is 14 wide starting at x0, so
  /// 20 is the text's offset and 6 is the gap.
  static const double _metaGap = 6;

  /// Radius on the thumbnail's BOTTOM corners only (`7304:23656`,
  /// `rounded-bl-[2px] rounded-br-[2px]`).
  ///
  /// On the **event** thumb it is handed to [NotchedTopEdgeClip] rather than to
  /// an outer `ClipRRect`, because two clips cannot make one shape: a corner
  /// clip would round a rectangle the notches had already bitten into, and the
  /// seam shows wherever a notch lands near a corner. Venue and zine thumbs have
  /// no notches, so they take a plain `ClipRRect` with the same radius — same
  /// silhouette, no perforation.
  static const double _thumbRadius = 2;

  /// Notch diameter on this surface. The frame draws circles of radius 1.714
  /// (`7304:23657`), and the diameter is an input per D283 — the event hero
  /// picks Ø12 on its 386 px run, this thumbnail Ø3.428 on 60.
  static const double _notchDiameter = 3.428;

  /// Inset at each end before the notch run starts: the frame's group spans
  /// 59.998 inside a 64 px thumb.
  static const double _notchInset = 2;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feedItem = item;
    if (feedItem == null) {
      return Clickable(
        onTap: onTap,
        child: SizedBox(
          height: height,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              thumbnail!,
              const SizedBox(width: _thumbGap),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.mobileB1Reg(color: AppColors.sokoInk),
                    ),
                    const SizedBox(height: 12),
                    meta!,
                  ],
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: _thumbGap),
                trailing!,
              ],
            ],
          ),
        ),
      );
    }

    final l10n = Lt.of(context);
    return Clickable(
      onTap: onTap,
      child: SizedBox(
        height: rowHeight,
        child: _body(context, ref, l10n, feedItem),
      ),
    );
  }

  /// Event photo well — tear-off-ticket top (PROD-4118). Places and people
  /// must not use this; see [placePhotoThumb].
  static Widget eventPhotoThumb(
    String? imageUrl, {
    double height = rowHeight,
    bool paperGrain = true,
  }) => NotchedTopEdgeClip(
    diameter: _notchDiameter,
    horizontalInset: _notchInset,
    borderRadius: const BorderRadius.vertical(
      bottom: Radius.circular(_thumbRadius),
    ),
    child: SizedBox(
      width: thumbWidth,
      height: height,
      child: _photoThumb(imageUrl, height: height, paperGrain: paperGrain),
    ),
  );

  /// Venue / place photo well — the same 64×80 rectangle as a feed venue
  /// row: square top, 2 px on the bottom corners, no perforation.
  static Widget placePhotoThumb(
    String? imageUrl, {
    double height = rowHeight,
    bool paperGrain = true,
  }) => ClipRRect(
    borderRadius: const BorderRadius.vertical(
      bottom: Radius.circular(_thumbRadius),
    ),
    child: SizedBox(
      width: thumbWidth,
      height: height,
      child: _photoThumb(imageUrl, height: height, paperGrain: paperGrain),
    ),
  );

  static Widget _photoThumb(
    String? imageUrl, {
    required double height,
    bool paperGrain = true,
    String? seed,
    SokoEntityKind? kind,
  }) => Stack(
    fit: StackFit.expand,
    children: [
      // When the caller knows the entity ([seed] + [kind]) — the feed rows —
      // use the shared brand-floor image so a slow photo reveals the type
      // colour and never flashes a flat grey block that pops to the photo (the
      // "snap"). Callers that don't (legacy library thumbs) keep the plain
      // grey-placeholder path unchanged.
      if (seed != null && kind != null)
        SokoCardImage(
          imageUrl: imageUrl,
          seed: seed,
          kind: kind,
          width: thumbWidth,
          height: height,
          // The paper grain below is the texture layer; the floor stays flat.
          showTexture: false,
        )
      else
        CachedImage(
          imageUrl: imageUrl ?? '',
          width: thumbWidth,
          height: height,
          fit: BoxFit.cover,
          placeholder: const ColoredBox(color: AppColors.sokoShade45),
          errorWidget: const ColoredBox(color: AppColors.sokoShade45),
        ),
      if (paperGrain)
        // Paper grain over photo and placeholder (`7304:23656`, opacity-50).
        Opacity(
          opacity: kSokoPaperGrainOpacity,
          child: sokoTextureImage(kSokoPaperGrainTexture, fit: BoxFit.cover),
        ),
    ],
  );

  /// The row's trailing control.
  ///
  /// **Two different rails behind one glyph.** Events and venues get *saved*
  /// into a zine; a zine itself is *followed* — there is nothing to save it
  /// into. The app already draws both as a bookmark that fills when active
  /// (`list_page_header.dart` does exactly this for follow), so the row keeps
  /// one visual vocabulary while acting on whichever rail the entity belongs to.
  ///
  /// Exhaustive over the sealed [FeedItem] with no `default`, so a fourth entity
  /// type is a compile error here rather than a row whose button silently does
  /// nothing.
  Widget _trailingAction(
    BuildContext context,
    WidgetRef ref,
    Lt l10n,
    FeedItem row,
  ) => switch (row) {
    FeedEventItem() || FeedVenueItem() => _saveButton(context, ref, l10n, row),
    final FeedZineItem zine => _followButton(context, ref, l10n, zine),
  };

  Widget _saveButton(
    BuildContext context,
    WidgetRef ref,
    Lt l10n,
    FeedItem row,
  ) {
    final saved = isFeedItemSaved(ref, row);
    return CircleIconButton(
      // Saved → the solid bookmark, the same two-state glyph the detail page
      // and the hero card use. Not `bookmark_check`: a checkmark reads as
      // "done", and the row's affordance is "kept", which is what a filled
      // bookmark says everywhere else in the app.
      glyphBuilder: (hovered) =>
          SokoToggleGlyph.bookmarkChip(active: saved || hovered),
      // On paper here, unlike the hero's paper-30 over a photo — so the
      // circle keeps its resting ink-8 ground in both states and the fill
      // alone carries the signal.
      background: AppColors.sokoInk8,
      iconColor: AppColors.sokoInk,
      semanticLabel: l10n.feedHeroSaveA11y,
      // D22: the row's CTA acts on the row's item, never on the block.
      onTap: () => openFeedItemSave(context, ref, row),
      popOnTap: true,
    );
  }

  Widget _followButton(
    BuildContext context,
    WidgetRef ref,
    Lt l10n,
    FeedZineItem zine,
  ) {
    final following = isFeedZineFollowed(ref, zine);
    return CircleIconButton(
      glyphBuilder: (hovered) =>
          SokoToggleGlyph.bookmarkChip(active: following || hovered),
      background: AppColors.sokoInk8,
      iconColor: AppColors.sokoInk,
      // The same two strings the zine page's own follow button announces
      // ("Guardar" / "Guardada"). Worth noting because they read as *save*
      // copy: the app has always presented zine-follow to the user as saving,
      // and the follow/save distinction is an API one, not a user-facing one.
      // Coining a "Seguir" string here would introduce that distinction to the
      // user in one row of one feed and nowhere else.
      semanticLabel: following
          ? l10n.listActionSavedZine
          : l10n.listActionSaveZine,
      onTap: () => toggleFeedZineFollow(
        context,
        ref,
        zine,
        currentlyFollowing: following,
      ),
      popOnTap: true,
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, Lt l10n, FeedItem row) =>
      Row(
        // `items-center` on `7304:23655`: the content column (66) and the save
        // button (40) are both centred in the 80 px row, which is where the
        // frame's y7 and y20 come from. Only the thumbnail is the full height.
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _thumb(row),
          const SizedBox(width: _thumbGap),
          // The friends-going line arrives as a per-page side-map (D26 — it is
          // viewer-relative, so it never rides on the cached block). Read it
          // here, keyed by the event's id; an absent entry is the common case
          // and simply leaves the venue line in place.
          Expanded(
            child: _content(
              context,
              row,
              row is FeedEventItem
                  ? ref.watch(feedGoingSeedsProvider)[row.id]
                  : null,
            ),
          ),
          const SizedBox(width: _thumbGap),
          _trailingAction(context, ref, l10n, row),
        ],
      );

  /// The row's thumbnail — a different treatment per entity, deliberately.
  ///
  /// ⚠️ **The notched top edge is an EVENT thing only** (Zé, 2026-09-02). It is
  /// the tear-off-ticket perforation, which says "event" — it was applied to all
  /// three types only because the row started life event-only and the clip sat
  /// above the type switch. A venue is a photo, and a zine is a cover; neither
  /// is a ticket, and perforating them made all three read as the same object.
  ///
  ///   * **event** — notched top edge, photo, paper grain over it
  ///   * **venue** — photo + the same grain, square top edge
  ///   * **zine**  — the cover recipe (which paints its own texture) plus the
  ///     static turned corner, square top edge
  Widget _thumb(FeedItem row) => switch (row) {
    FeedEventItem() => NotchedTopEdgeClip(
      // The frame paints filled `Soko/Paper` circles ON the image; the shared
      // widget removes the pixels instead, which is the same picture on a paper
      // page and still right on any other ground (D283). Feeding it the frame's
      // Ø3.428 over a 60 px run reproduces the export exactly: 10 notches at a
      // 6.2858 pitch against the SVG's 6.286, centres matching to three
      // decimals.
      diameter: _notchDiameter,
      horizontalInset: _notchInset,
      borderRadius: const BorderRadius.vertical(
        bottom: Radius.circular(_thumbRadius),
      ),
      child: _thumbBox(
        _photoThumb(
          row.imageUrl,
          height: rowHeight,
          seed: row.id,
          kind: SokoEntityKind.event,
        ),
      ),
    ),
    // Same rounded bottom corners as the event thumb, without the perforation —
    // so the three rows still share a silhouette and differ only where the
    // design says they should.
    FeedVenueItem() => ClipRRect(
      borderRadius: const BorderRadius.vertical(
        bottom: Radius.circular(_thumbRadius),
      ),
      child: _thumbBox(
        _photoThumb(
          row.imageUrl,
          height: rowHeight,
          seed: row.id,
          kind: SokoEntityKind.venue,
        ),
      ),
    ),
    final FeedZineItem zine => ClipRRect(
      borderRadius: const BorderRadius.vertical(
        bottom: Radius.circular(_thumbRadius),
      ),
      child: _thumbBox(_zineThumb(zine)),
    ),
  };

  Widget _thumbBox(Widget child) =>
      SizedBox(width: thumbWidth, height: rowHeight, child: child);

  /// A zine's thumbnail is its COVER, composed from the recipe — not a photo
  /// URL. `FeedZineItem.imageUrl` is deliberately null for exactly this reason,
  /// so the photo path would render an error box for every zine row.
  ///
  /// The cover replaces the whole photo stack rather than sitting under the
  /// row's paper grain: `ListZineCover` already paints its own texture from
  /// `recipe.showTexture`, and laying the grain over it would double the overlay
  /// and darken every zine thumb relative to its own full-size cover on the page
  /// it opens.
  ///
  /// Static corner fold (PROD-4118) — same as the home zine grid, not animated.
  Widget _zineThumb(FeedZineItem zine) {
    final recipe = zineCoverRecipeFor(zine);
    return Stack(
      fit: StackFit.expand,
      children: [
        ListZineCover(
          recipe: recipe,
          title: zine.name,
          showTitle: false,
          showLogo: false,
        ),
        SokoZineCornerFold(
          pageColor: SokoZineCornerFold.pageColorFor(
            zine.id,
            coverColor: recipe.color,
          ),
        ),
      ],
    );
  }

  /// Title + meta, chosen from the entity the block declared.
  ///
  /// Exhaustive over the sealed [FeedItem] with **no `default` arm**, so a third
  /// entity type is a compile error here rather than a row that silently renders
  /// nothing — the same guarantee `buildFeedBlock` gets over `FeedBlock`.
  Widget _content(BuildContext context, FeedItem row, FeedGoingEntry? going) =>
      switch (row) {
        final FeedEventItem event => _eventContent(context, event, going),
        final FeedVenueItem venue => _venueContent(context, venue),
        final FeedZineItem zine => _zineContent(context, zine),
      };

  /// The zine row — name, then `curator • item count`. Figma `7675-38094`.
  ///
  /// One meta line like the venue row, not the event row's two.
  ///
  /// The count reuses **`listsItemCount`**, the plural the lists hub already
  /// prints ("Sem itens" / "1 item" / "N itens"). A second key for the same
  /// sentence is how two surfaces end up saying it differently in one locale —
  /// and `item_count` is never zero here (an empty zine is a draft and is
  /// dropped before composition), so the `=0` arm is unreachable rather than
  /// wrong.
  ///
  /// The curator prefix comes from `attributionPrefixFor`, which picks "Pela"
  /// for Soko's own handle and "Por" otherwise — a gendered agreement the app
  /// already makes on every other zine attribution line.
  Widget _zineContent(BuildContext context, FeedZineItem zine) {
    final l10n = Lt.of(context);
    final curator = zine.curatorName;
    final hasCurator = curator != null && curator.isNotEmpty;
    final avatar = zine.curatorAvatarUrl;
    final hasAvatar = avatar != null && avatar.isNotEmpty;
    final count = zine.itemCount;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          zine.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTheme.mobileB1Reg(color: AppColors.sokoInk),
        ),
        if (hasCurator || count != null) ...[
          const SizedBox(height: 12),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (hasCurator)
                Flexible(
                  child: FeedMetaLine(
                    // **The glyph is the no-photo fallback** (Zé,
                    // 2026-09-02), NOT the seeded initial-letter dot the zine
                    // page header and the Descobrir shelf cards degrade to.
                    // Those two try a URL first and show a letter only for a
                    // curator who uploaded nothing; a letter here — where most
                    // curators have no photo — would be a column of unrelated
                    // coloured letters, which reads as noise where one uniform
                    // glyph reads as "a person".
                    //
                    // So `leading` is supplied only when there is an actual
                    // photo, and `icon` carries the rest.
                    icon: LucideIcons.user,
                    leading: hasAvatar
                        // No `seed`: the block carries no curator id, and the
                        // seed only tints `PersonDot`'s NAME fallback — which
                        // cannot be reached here, because this branch runs
                        // only when there is a photo. The url is rendered raw,
                        // already an absolute backend image-proxy URL that
                        // every other owner projection emits unwrapped
                        // (BE v1.123.0).
                        ? PersonDot(url: zine.curatorAvatarUrl)
                        : null,
                    // `attributionPrefixFor` returns a trailing-space prefix
                    // ("Por " / "Pela ") — it is built to be concatenated.
                    text: '${attributionPrefixFor(l10n, null)}$curator',
                    color: AppColors.sokoInk,
                    gap: _metaGap,
                    expand: false,
                  ),
                ),
              // The separator belongs to the PAIR — a row missing either half
              // must not leave a dangling dot, same rule as the other two.
              if (hasCurator && count != null) ...[
                const SizedBox(width: _metaGap),
                const FeedMetaSeparator(color: AppColors.sokoInk),
                const SizedBox(width: _metaGap),
              ],
              if (count != null)
                Flexible(
                  child: FeedMetaLine(
                    icon: LucideIcons.book_open,
                    text: l10n.listsItemCount(count),
                    color: AppColors.sokoInk,
                    gap: _metaGap,
                    expand: false,
                  ),
                ),
            ],
          ),
        ],
      ],
    );
  }

  /// The venue row — name, then `type` and then the location, on two meta
  /// lines.
  ///
  /// The same shape as the event row above it (a kind line, then a place line),
  /// not the single `neighbourhood · type` line PROD-4106 specified: Zé asked
  /// for the split on 2026-09-08 so a venue row and an event row read the same
  /// way down the page.
  ///
  /// Type leads and location follows, which is the reverse of the order the
  /// single line used — the grid tile was flipped to match in the same change,
  /// so a venue still reads identically wherever it appears.
  ///
  /// Each line is independently present-or-absent, which is what retires the
  /// dangling-separator guard the shared line needed: with a line of its own,
  /// a missing half is simply a missing line.
  ///
  /// **Location is the neighbourhood alone** (Zé, 2026-09-08), never the city.
  /// Every bundle on the page is city-scoped by the backend — a radius around
  /// the caller's own city — so the city is a constant across every row and
  /// spending line 2 on it would say nothing. The line is dropped when the
  /// neighbourhood is null rather than falling back, exactly as the event row
  /// drops its own location line. `FeedVenueItem.city` stays parsed and
  /// unrendered here; do not wire it in without revisiting that scoping.
  Widget _venueContent(BuildContext context, FeedVenueItem venue) {
    final type = venue.type;
    final hasType = type != null && type.isNotEmpty;
    final neighborhood = venue.neighborhood;
    final hasNeighborhood = neighborhood != null && neighborhood.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          venue.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: AppTheme.mobileB1Reg(color: AppColors.sokoInk),
        ),
        if (hasType) ...[
          const SizedBox(height: 12),
          FeedMetaLine(
            icon: LucideIcons.move_right,
            // Backend-localized display label for the PRIMARY type, not a slug
            // (ADR-043). Render as received.
            text: type,
            color: AppColors.sokoInk,
            gap: _metaGap,
          ),
        ],
        if (hasNeighborhood) ...[
          // 12 under the title, 8 between two meta lines — so a venue with no
          // type keeps the title's own gap rather than inheriting the tighter
          // inter-meta one.
          SizedBox(height: hasType ? 8 : 12),
          FeedMetaLine(
            icon: LucideIcons.map_pin,
            text: neighborhood,
            color: AppColors.sokoInk,
            gap: _metaGap,
          ),
        ],
      ],
    );
  }

  Widget _eventContent(
    BuildContext context,
    FeedEventItem item,
    FeedGoingEntry? going,
  ) {
    final category = item.category;
    final hasCategory = category != null && category.isNotEmpty;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          // `Mobile/B1 Reg` (`7304:23669`), and the design system already has
          // it: Zalando Sans Light 18, leading 1, tracking −0.36. Not a heading
          // weight — the row title is the same face as the meta lines below it,
          // one step larger. It shipped as `body(17, w600)`, which reads as a
          // bold list row rather than the frame's editorial one.
          //
          // Via the token helper rather than `AppTheme.body`, which derives
          // `Mobile/B2`'s −1 % tracking from the size and would put −0.18 here.
          style: AppTheme.mobileB1Reg(color: AppColors.sokoInk),
        ),
        const SizedBox(height: 12),
        // Date · category. The separator belongs to the pair — a row with no
        // category must not leave a dangling dot after the date.
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: FeedMetaLine(
                icon: LucideIcons.calendar,
                text: formatFeedEventDate(context, item),
                color: AppColors.sokoInk,
                gap: _metaGap,
                expand: false,
              ),
            ),
            if (hasCategory) ...[
              const SizedBox(width: _metaGap),
              const FeedMetaSeparator(color: AppColors.sokoInk),
              const SizedBox(width: _metaGap),
              Flexible(
                child: FeedMetaLine(
                  icon: LucideIcons.move_right,
                  // Backend-localized display label, not a slug.
                  text: category,
                  color: AppColors.sokoInk,
                  gap: _metaGap,
                  expand: false,
                ),
              ),
            ],
          ],
        ),
        // The friends-going line (`7740-46783`) swaps in for the venue line, but
        // ONLY when this bundle opted into social proof (`show_social_proof`).
        // The backend decides per bundle whether the "{name} vai" line belongs;
        // the client never shows it for a bundle that didn't ask, even if the
        // page's `going` side-map happens to name a friend for the event. The
        // two never stack — the row is a fixed 80 px box — and a bundle without
        // the flag renders exactly as before.
        if (_goingPeopleFor(going) case final people?) ...[
          const SizedBox(height: 8),
          FeedGoingRow(people: people, totalCount: going!.count),
        ] else if (item.locationLine != null) ...[
          const SizedBox(height: 8),
          FeedMetaLine(
            icon: LucideIcons.map_pin,
            text: item.locationLine!,
            color: AppColors.sokoInk,
            gap: _metaGap,
          ),
        ],
      ],
    );
  }

  /// The friends to render on the going line for THIS row, honouring the
  /// bundle's [socialProof] opt-in first: a bundle that didn't ask for social
  /// proof never shows the line, whatever the `going` map holds.
  List<FeedReaction>? _goingPeopleFor(FeedGoingEntry? going) =>
      socialProof ? _goingPeople(going) : null;

  /// The friends to render on the going line, or null to keep the venue line.
  /// An absent entry, an empty preview, and a preview of only unnameable people
  /// all collapse to the same "no line" — better the venue line than a blank
  /// third slot or a nameless "+N pessoas".
  static List<FeedReaction>? _goingPeople(FeedGoingEntry? going) {
    final preview = going?.preview;
    if (preview == null || preview.isEmpty) return null;
    if (!FeedGoingRow.hasNameable(preview)) return null;
    return preview;
  }
}
