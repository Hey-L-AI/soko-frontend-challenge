// PROD-4118 — turning a feed zine item into a render-ready cover recipe.
//
// **One line of real work, and it exists so there is exactly one of it.** Every
// zine surface in the app — the zine view, the lists hub, search results, the
// see-all shelves — resolves its cover through `ZineCoverRecipe.fromFields`,
// and that shared resolver is precisely what makes a feed card render
// identically to the zine it opens into. A second, feed-local resolver would
// drift the first time either side gained a cover mode, and the symptom would
// be "the card looks different from the page" rather than an error.
//
// ⚠️ **Three mappings carry almost all the risk**, measured against staging's
// live payload (34 items):
//
//   * `coverItemImageUrl` is read FIRST by the `item_image` branch. Omit it and
//     all 5 item-image covers fall through to flat colour.
//   * `fallbackItemImageUrl` feeds the PROD-2040 branch, which fires only for
//     `background_color` with a null `cover_color` — **18 of 34 items**. This is
//     the common path, not an edge case; dropping it blanks half the grid.
//   * `legacyCoverImageUrl` serves `uploaded_photo` plus legacy rows later
//     backfilled to `background_color`.

import '../../../../data/models/feed_home.dart';
import '../../../lists/utils/zine_cover_recipe.dart';

/// The cover recipe for [item], with every fallback the shared resolver applies.
///
/// `coverItemId` and `itemLookup` are deliberately omitted: the feed has no item
/// collection to look a cover item up in, and it does not need one — the backend
/// resolves `cover_item_image_url` server-side, which is the canonical source
/// for exactly this reason (PROD-1932).
ZineCoverRecipe zineCoverRecipeFor(FeedZineItem item) =>
    ZineCoverRecipe.fromFields(
      listId: item.id,
      coverType: item.coverType,
      coverColor: item.coverColor,
      coverTexture: item.coverTexture,
      coverTextColor: item.coverTextColor,
      coverItemId: null,
      coverItemImageUrl: item.coverItemImageUrl,
      legacyCoverImageUrl: item.coverImageUrl,
      fallbackItemImageUrl: item.previewImageUrl,
      showTitle: item.coverShowTitle,
      showTexture: item.coverShowTexture,
      showLogo: item.coverShowLogo,
    );
