// PROD-4006 — resolving a banner's colours and artwork.
//
// Three sources, in priority order, and the order is the design:
//
//   1. **The wire** (`block.style`) — what the backend sent. Requested for
//      v1.106.0 and not shipping yet, so today this is always null.
//   2. **The client registry** below, keyed on the asset key — what v0 ships,
//      and the fallback for any app version older than a new banner's colours.
//   3. **The default** — for a banner this build has never heard of.
//
// Layering rather than switching is what makes the contract change a no-op on
// arrival: nothing needs a flag day, an older app keeps rendering the two v0
// banners correctly from its registry, and a newer backend can override them
// without one.
//
// **Why colour moved onto the wire at all.** The original argument against it —
// mine, and the backend hardened their code around it — was that a new banner
// needs an app release for its artwork regardless, so a colour field buys
// nothing the asset key does not already cost. That is true for `kind: asset`
// and false for `kind: url`: a URL illustration needs no release, so a fully
// backend-authored banner could arrive with its own artwork and still be stuck
// with a ground colour hardcoded in an app build. The premise was too narrow.

import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/utils/hex_color.dart';
import '../../../../data/models/feed_home.dart';

/// The colours one banner is painted with, after all three sources are
/// resolved. Every field is non-null — resolution always terminates.
@immutable
class FeedBannerPalette {
  /// Fill behind the whole card.
  final Color ground;

  /// Fill of the CTA button.
  final Color button;

  const FeedBannerPalette({required this.ground, required this.button});

  /// Copy colour, derived rather than configured.
  ///
  /// The ground can be any hex a backoffice author types, and the app has to
  /// stay legible on all of it. Deriving from luminance means an author cannot
  /// produce unreadable copy; asking them for a text colour as well would just
  /// move the failure one field along.
  Color get onGround => foregroundOn(
    ground,
    onLight: AppColors.sokoInk,
    onDark: AppColors.sokoPaper,
  );

  /// Button label colour, derived from the button fill for the same reason.
  Color get onButton => foregroundOn(
    button,
    onLight: AppColors.sokoInk,
    onDark: AppColors.sokoPaper,
  );
}

/// Per-banner colours this app version ships, keyed by the backend's asset key.
///
/// The **fallback**, not the source of truth — `block.style` wins when present.
/// These exist so the two v0 banners look right today, and so any app older
/// than a future banner's colours still renders it sensibly instead of dropping
/// to the generic default.
///
/// Keys must stay in step with [FeedImage.assetRegistry] and with the
/// backend's `BannerContent.image_key`; `feed_banner_block_test.dart` asserts
/// the first half, and the backend has its own test for the second.
const Map<String, FeedBannerPalette> kFeedBannerPalettes =
    <String, FeedBannerPalette>{
      // Figma `7304-23823` — "Posso ajudar-te a descobrir o que procuras".
      'banner_chat': FeedBannerPalette(
        ground: AppColors.sokoPink,
        button: AppColors.sokoYellow,
      ),
      // Figma `7304-24204` — "Queres bares e restaurantes para esta semana?".
      'banner_map': FeedBannerPalette(
        ground: AppColors.sokoBlue,
        button: AppColors.sokoYellow,
      ),
    };

/// Colours for a banner this build has never heard of, and for the pre-v1.105.0
/// case where no `image` was sent at all.
///
/// `Soko/Pink` + `Soko/Yellow` rather than a neutral: a banner is a promotional
/// surface, and a grey one reads as a rendering failure rather than a
/// deliberate degrade. It is also the first v0 banner's own pairing, so the
/// common case is right by construction.
const FeedBannerPalette kFeedBannerDefaultPalette = FeedBannerPalette(
  ground: AppColors.sokoPink,
  button: AppColors.sokoYellow,
);

/// Resolves the palette for [block]: wire → registry → default, per field.
///
/// Resolution is **per field, not per source**. A backend that sends only a
/// ground keeps the registry's button rather than falling all the way to the
/// default, so a partial `style` improves the banner instead of degrading the
/// half it did not mention.
FeedBannerPalette resolveFeedBannerPalette(FeedBlockBanner block) {
  final fallback =
      kFeedBannerPalettes[block.image?.value] ?? kFeedBannerDefaultPalette;

  final style = block.style;
  if (style == null || style.isEmpty) return fallback;

  return FeedBannerPalette(
    ground: style.backgroundColor ?? fallback.ground,
    button: style.buttonBackgroundColor ?? fallback.button,
  );
}
