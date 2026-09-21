// PROD-4006 — the `banner` block. Figma `7304-23823` / `7304-24204`.
//
// Text top-left, CTA bottom-left, illustration right. Structure is fixed;
// everything in it is server-defined.
//
// Two of the contract's three forward-compatibility rules meet here:
//
//   * **Rule 2 — an unknown `action.route` hides the CTA.** Validated by raw
//     string against `kFeedActionRoutes`, never by `Uri.path`: `/chat?search=x`
//     auto-sends `x` as the user's own message (PROD-2315), so a normalising
//     comparison would turn a backend-supplied CTA into message injection.
//   * **Rule 3 — an unknown asset key costs the illustration and nothing
//     else.** The banner still renders; it just loses its art.
//
// Colours come from `resolveFeedBannerPalette`: the wire first, then this
// build's registry, then a default — per field, so a partial `style` improves
// the banner rather than degrading the half it did not mention.
//
// Both are "degrade, don't break", and both are what let the backend ship a
// banner before the app release that understands it.

import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../../../../core/theme/app_theme.dart';
import '../../../../../data/models/feed_home.dart';
import '../../../../../shared/widgets/bt_sq_ico.dart';
import '../../../../../shared/widgets/cached_image.dart';
import '../../utils/feed_action_routes.dart';
import '../../utils/feed_banner_assets.dart';
import 'feed_block_atoms.dart';

class FeedBannerBlock extends StatelessWidget {
  final FeedBlockBanner block;

  const FeedBannerBlock({super.key, required this.block});

  /// Frame height of the illustration (`7304:23829`, `7304:24210`). The width
  /// differs per art (113 / 92), so only the height is pinned and the aspect
  /// ratio carries the rest.
  static const double illustrationHeight = 101;

  /// Gap between the copy column and the art (`gap-[20px]`).
  static const double _artGap = 20;

  /// Gap between the text and the CTA. The frame uses `justify-between` over a
  /// fixed 141 px card; a fixed gap is the honest translation, because in the
  /// app the card's height is set by its content, not by a design frame.
  ///
  /// **25 is that gap as the comp actually resolves it** — copy box 0 → 36,
  /// button at y61 (`7304:23825` / `7304:23826`). It was 16, which is what
  /// `justify-between` looks like when you read the intent and not the frame.
  static const double _textToButtonGap = 25;

  @override
  Widget build(BuildContext context) {
    final image = block.image;
    final art = _buildIllustration(image);
    final palette = resolveFeedBannerPalette(block);

    return FeedBlockSurface(
      block: block,
      child: Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: palette.ground,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (block.text != null && block.text!.isNotEmpty) ...[
                    Text(
                      // Backend-localized (D7) — render exactly as received.
                      block.text!,
                      style: AppTheme.body(
                        fontSize: 18,
                        fontWeight: FontWeight.w300,
                        // Derived from the ground, which the backend may set to
                        // anything — an author must not be able to produce
                        // unreadable copy.
                        color: palette.onGround,
                        height: 1.1,
                      ),
                    ),
                    const SizedBox(height: _textToButtonGap),
                  ],
                  _buildCta(context, palette),
                ],
              ),
            ),
            if (art != null) ...[const SizedBox(width: _artGap), art],
          ],
        ),
      ),
    );
  }

  /// The CTA, or nothing at all.
  ///
  /// `routeTarget` is all four conditions in one call — enabled, has an action,
  /// the action is a **route**, and the route is **allowlisted** — and it hands
  /// back the destination rather than a boolean, so there is no second step
  /// where a caller could push something the check never saw. Leaving any of it
  /// to the call site is how a CTA eventually navigates somewhere
  /// server-supplied and unvetted.
  ///
  /// ⚠️ **`isLive` is the wrong question here** (PROD-4238). Since slates it is
  /// also true for a `next_slate` action, which names no route — a banner
  /// carrying one would render a live CTA over nothing. The backend does not
  /// send that combination; this asks the question whose answer stays correct
  /// if it ever does.
  ///
  /// A dead CTA is **omitted**, not disabled. `feed_end`'s button is disabled
  /// because the backend explicitly says `enabled: false` — a designed state
  /// (D24). This one is dead because the app does not understand where it
  /// points, which is not something to show the user a control for.
  /// The CTA — live, or **visibly disabled** when the backend asked for that.
  ///
  /// ⚠️ **Two different things used to collapse into one `SizedBox.shrink()`
  /// here** (PROD-4446), and they must not:
  ///
  ///   * `enabled: false` is the backend *deliberately* disabling the button —
  ///     a designed state. Honour it: the button renders, dimmed and inert.
  ///     `onTap: null` is what does that (`BtSqIco` drops to 50 % opacity and
  ///     stops hover, press and taps), so there is no second definition of what
  ///     disabled looks like. Same mechanism `feed_end` uses.
  ///   * A route this build cannot use is the app failing to honour the block,
  ///     and since PROD-4446 that **drops the whole block** in
  ///     `renderableFeedBlocks` — so it never reaches this method. The shrink
  ///     below is a defensive floor, not a path anyone should see.
  ///
  /// Collapsing them was harmless while both merely omitted the button. It
  /// stopped being harmless the moment one of them deletes the block: a banner
  /// the backend deliberately disabled would vanish instead of showing the
  /// disabled button it asked for — the app overriding its decision.
  ///
  /// Purely defensive today: the backend confirms `enabled: false` has never
  /// reached the wire on any block. It is constructed in exactly one place, an
  /// internal terminal shell that is always replaced before the response is
  /// assembled, and banners never touch it. Pinned by a test; do not let it
  /// grow.
  ///
  /// Note the spec's *"`enabled: false` … carries no `action`"* describes that
  /// internal shell and is **not** a constraint — nothing validates it, so this
  /// must not assume the action is absent.
  Widget _buildCta(BuildContext context, FeedBannerPalette palette) {
    final route = block.button.routeTarget(isAllowedFeedActionRoute);
    if (!block.button.enabled) {
      return BtSqIco(
        icon: null,
        label: block.button.label,
        variant: BtSqIcoVariant.selected,
        selectedBackgroundOverride: palette.button,
        foregroundOverride: palette.onButton,
        onTap: null,
      );
    }
    if (route == null) {
      return const SizedBox.shrink();
    }
    return BtSqIco(
      icon: null,
      label: block.button.label,
      // `selected` is the only variant that takes a background override, which
      // is what lets a server-supplied fill flow through the design-system
      // button instead of forking it. With no `style` on the wire the override
      // is the registry's colour, so today this renders exactly as the fixed
      // `yellow` variant did.
      variant: BtSqIcoVariant.selected,
      selectedBackgroundOverride: palette.button,
      foregroundOverride: palette.onButton,
      onTap: () => context.push(route),
    );
  }

  /// The illustration, or null when this app version cannot draw it.
  ///
  /// Null covers three cases that all degrade identically and deliberately:
  /// no `image` at all (every v0 banner today), an `asset` key this build does
  /// not ship, and an unknown `kind`. The banner renders either way.
  Widget? _buildIllustration(FeedImage? image) {
    if (image == null || !image.isRenderable) return null;

    if (image.kind == FeedImage.kindUrl) {
      return SizedBox(
        height: illustrationHeight,
        child: CachedImage(
          imageUrl: image.value,
          height: illustrationHeight,
          fit: BoxFit.contain,
          // A remote illustration that fails to load degrades to the same
          // place an unknown asset key does: a banner without its art.
          placeholder: const SizedBox.shrink(),
          errorWidget: const SizedBox.shrink(),
        ),
      );
    }

    return Image.asset(
      image.assetPath!,
      height: illustrationHeight,
      fit: BoxFit.contain,
    );
  }
}
