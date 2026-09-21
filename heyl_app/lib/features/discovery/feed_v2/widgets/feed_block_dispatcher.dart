// PROD-4005 — block → widget dispatch.
//
// Rule 1 lives here: an unknown block `type` is skipped **silently**. Not an
// error, not a placeholder, not a zero-height box — the rendered tree must be
// identical to the same feed with that block absent, which is why unknown
// blocks are filtered out *before* the list builder rather than returning an
// empty widget from it. A `SizedBox.shrink()` would still occupy a list index
// and shift every key after it.

import 'package:flutter/material.dart';

import '../../../../data/models/feed_home.dart';
import 'blocks/feed_banner_block.dart';
import 'blocks/feed_block_atoms.dart';
import 'blocks/feed_bundle_block.dart';
import 'blocks/feed_create_cta_block.dart';
import 'blocks/feed_unknown_area_block.dart';
import 'blocks/feed_event_hero_block.dart';
import 'blocks/feed_people_grid_block.dart';
import 'blocks/feed_venue_grid_block.dart';
import 'blocks/feed_zine_grid_block.dart';
import 'blocks/feed_complete_block.dart';
import 'blocks/feed_end_block.dart';
import 'blocks/feed_weekly_bundle_block.dart';
import 'blocks/feed_sign_in_gate_block.dart';
import '../utils/feed_action_routes.dart';

/// The blocks of [blocks] this app version can draw, in backend order.
///
/// Two members are dropped, both for the same reason — the rendered tree must
/// be identical to the same feed with that block absent:
///
///   * **[FeedBlockUnknown]**, covering an unrecognised wire type and a known
///     type whose payload failed to parse (rule 1).
///   * **An empty [FeedBlockVenueGrid]** (PROD-4108). The backend *cannot* omit
///     this one: the block is placed during composition, before the per-caller
///     near-you query runs, and the cursor's layout digest is taken over that
///     composition — dropping it server-side after the page was sliced would
///     shorten a page the digest already covered. So the drop happens here.
///     Zé, 2026-09-01: *"if there are no results on the near you grid, we want
///     to not display that block"*. Rendering it would mean a "Perto de ti"
///     heading over a live chevron with nothing underneath, which reads as a
///     loading failure — and the contract is explicit that an empty block is
///     omitted entirely and there are no client-side empty states for blocks.
///
/// ⚠️ **[FeedBlockZineGrid] is deliberately NOT in that list** (PROD-4118), and
/// the asymmetry is the point rather than an oversight. The venue grid needs the
/// drop because of *when* it is filled, not because grids are special: all four
/// zine sources run during composition, so the backend knows an empty zine grid
/// is empty and omits the whole block, exactly as it does for every other type.
/// Confirmed against staging — a guest page omits `grid-featured` and
/// `grid-editor-picks` outright and pages the remaining blocks, rather than
/// sending them with `items: []`. A guard here would be dead code guarding an
/// impossible state, and `feed_zine_grid_block_test.dart` pins its absence so
/// nobody "fixes" the inconsistency back in.
///
/// ⚠️ **Dropping here costs the feed nothing.** Rendering and paging read
/// different lists: the paging ledger dedupes over the raw parsed blocks
/// (`feed_home_provider.dart`), so an unrendered block still advances the feed
/// and still counts toward `seenBlockIds`. That is already what stops an
/// unknown block reading as "nothing new" and truncating the feed.
///
/// And it must stay a *filter*, not an empty widget returned from the builder:
/// a `SizedBox.shrink()` still occupies a list index and shifts every key
/// after it.
List<FeedBlock> renderableFeedBlocks(
  List<FeedBlock> blocks, {
  required bool isAuthenticated,
}) => blocks
    .where(
      // The wildcard is correct HERE and forbidden in [buildFeedBlock]. This
      // switch answers a boolean — "may this be drawn?" — and the safe answer
      // for a type this function has not been taught about is **yes**, because
      // the builder below already knows how to draw every type that reaches it.
      // The builder's switch has no wildcard precisely so a new type is a
      // compile error there, which is where the omission actually matters.
      (b) => switch (b) {
        FeedBlockUnknown() => false,
        FeedBlockVenueGrid(:final items) => items.isNotEmpty,
        // PROD-4442. **The same exception as `venue_grid`, for the same
        // reason** — not the `zine_grid` case. Everything about a people block
        // is viewer-relative (who is suggested, the follow state, every word of
        // each details row), so the backend cannot fill it inside composition,
        // which is cached per `(filter, city, locale, slate)` with no user
        // dimension. It is placed as an empty shell and hydrated per request,
        // after the page is sliced and after the cursor's layout digest is
        // taken — so an empty one is already committed to the page by the time
        // anyone knows it is empty, and dropping it server-side would shorten a
        // page the digest already covered.
        //
        // Rendering it would mean a heading over nothing, which reads as a
        // loading failure — the same call Zé made for `venue_grid` on
        // 2026-09-01, and the contract is explicit that an empty block is
        // omitted entirely with no client-side empty states for blocks.
        FeedBlockPeopleGrid(:final items) => items.isNotEmpty,
        // PROD-4319. Both of its CTAs submit to endpoints that reject a guest
        // token, and a guest carries a REAL bearer token — so nothing fails
        // until submit: the sheet opens, the form fills, and it returns a
        // generic error with no route to sign-in.
        //
        // ⚠️ **This drop is the gate, not the widget's `SizedBox.shrink()`.**
        // A block that draws nothing must not still count as renderable, or a
        // page whose only block is this one renders blank instead of reaching
        // the empty state — the same failure as the chrome-only page
        // (PROD-4285). Exactly why the zero-item `venue_grid` above is dropped
        // here rather than shrunk in its widget.
        //
        // The backend deliberately does NOT gate this (Zé, 2026-09-09 — it
        // built a server-side gate on D10 grounds and had it removed), so this
        // is the only gate there is.
        //
        // On timing: `isAuthenticated` is false during auth restore, so this
        // errs toward HIDING when the answer is not yet known — the safe
        // direction, since a real user briefly missing an optional CTA beats a
        // guest briefly being offered a dead end. There is no window where a
        // guest reads as authenticated: the guest mint sets `accessToken` and
        // `isGuest` together, and `SplashGate` covers cold start (verified by
        // codex, 2026-09-09).
        // PROD-4446 — **forward-compat rule 2, changed**: a banner whose CTA
        // this build cannot use is dropped entirely, where it used to render
        // without its button. A banner with copy and nothing to tap is a dead
        // promo; absent beats dead (Zé, 2026-09-15).
        //
        // ⚠️ **`enabled: false` is NOT swept up by this.** It is a *designed*
        // disabled state — the backend asking for the finished design with the
        // behaviour withheld — so it keeps the block and the widget renders a
        // visibly disabled button. Everything else (an un-allowlisted route, an
        // action kind this build does not know, no action at all) is the app
        // failing to honour the block, and that is what drops it. Branching on
        // `enabled` FIRST is the whole distinction: `routeTarget` returns null
        // for both, and collapsing them was harmless only while both merely
        // omitted the button.
        //
        // The asymmetry with rule 3 is deliberate and stays: an unknown asset
        // key, an unknown image `kind` or a failed URL costs the illustration
        // only, because copy plus a live CTA on a coloured ground is still a
        // complete banner.
        //
        // In the filter rather than the widget for the reason the file header
        // gives: a `SizedBox.shrink()` still occupies a list index, shifts
        // every key after it, and lets an all-chrome page render blank instead
        // of reaching the empty state (PROD-4285, PROD-4319).
        //
        // Safe against the backend's empty-feed rule: a banner is **chrome**,
        // not content, so a banner we drop was never counted toward
        // page-has-content and dropping it cannot change whether a page
        // collapses to `blocks: []` (confirmed by backend).
        FeedBlockBanner(:final button) =>
          !button.enabled ||
              button.routeTarget(isAllowedFeedActionRoute) != null,
        FeedBlockCreateCta() => isAuthenticated,
        // PROD-4520 — **a pass-through, and deliberately NOT the mirror of
        // `create_cta` above.**
        //
        // Gating this on `!isAuthenticated` would look symmetrical and would be
        // a bug: `isAuthenticated` is false during auth restore, so the mirror
        // errs toward SHOWING the gate to a signed-in reader — but worse, the
        // block's mere presence is already the backend's answer. It is sent to
        // a guest and to nobody else, decided from the token that fetched the
        // page. Re-deciding it here from a client flag that is briefly wrong
        // could DROP a legitimately-sent gate, and a dropped gate on a
        // guest-only page means `blocks: []` — the blank Pessoas tab this whole
        // ticket exists to fix.
        //
        // `create_cta` is gated here because the backend deliberately does not
        // gate it (Zé, 2026-09-09). This one the backend does.
        FeedBlockSignInGate() => true,
        _ => true,
      },
    )
    .toList(growable: false);

/// Builds the widget for one block.
///
/// The `switch` is exhaustive over the sealed [FeedBlock] hierarchy and has
/// **no `default` / `_` arm on purpose**: that is what makes adding a block
/// type in PROD-4006 a compile error until every dispatcher handles it. Adding
/// a wildcard here silently gives that guarantee up.
///
Widget buildFeedBlock(FeedBlock block) {
  final key = feedBlockKey(block.id);
  return switch (block) {
    FeedBlockEventHero() => FeedEventHeroBlock(key: key, block: block),
    FeedBlockBundle() => FeedBundleBlock(key: key, block: block),
    FeedBlockVenueGrid() => FeedVenueGridBlock(key: key, block: block),
    FeedBlockZineGrid() => FeedZineGridBlock(key: key, block: block),
    FeedBlockPeopleGrid() => FeedPeopleGridBlock(key: key, block: block),
    FeedBlockBanner() => FeedBannerBlock(key: key, block: block),
    FeedBlockWeeklyBundle() => FeedWeeklyBundleBlock(key: key, block: block),
    FeedBlockFeedEnd() => FeedEndBlock(key: key, block: block),
    FeedBlockFeedComplete() => FeedCompleteBlock(key: key, block: block),
    FeedBlockUnknownArea() => FeedUnknownAreaBlock(key: key, block: block),
    FeedBlockCreateCta() => FeedCreateCtaBlock(key: key, block: block),
    FeedBlockSignInGate() => FeedSignInGateBlock(key: key, block: block),
    // Unreachable in practice — `renderableFeedBlocks` filters these out before
    // the builder runs. Kept as a real arm rather than a wildcard so the switch
    // stays exhaustive without `default`, which is the whole point.
    //
    // (An EMPTY `venue_grid` is filtered there too, but its arm above is very
    // much reachable — only the zero-item case is dropped.)
    FeedBlockUnknown() => const SizedBox.shrink(),
  };
}
