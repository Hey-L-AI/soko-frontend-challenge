import 'dart:math';

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/soko_texture.dart';
import '../../../data/models/user_list.dart';

// `stableHash`, `kZineTextureCatalog`, `kZineTextureKeys`, and
// `kZineDefaultTextureId` now live in `core/utils/soko_texture.dart` so
// non-list surfaces can reuse them. Re-export so existing zine call sites
// (change-cover sheet, tests) keep importing them from here unchanged.
export '../../../core/utils/soko_texture.dart'
    show
        stableHash,
        kZineTextureCatalog,
        kZineTextureKeys,
        kZineDefaultTextureId;

/// Which render path the zine cover takes — mirrors the BE
/// `user_lists.cover_type` column (PROD-1907). Wire format is
/// snake_case lowercase (`background_color` / `item_image` /
/// `uploaded_photo`); the [name] getter emits exactly that.
enum ZineCoverType {
  backgroundColor,
  itemImage,
  uploadedPhoto;

  String get wire => switch (this) {
    ZineCoverType.backgroundColor => 'background_color',
    ZineCoverType.itemImage => 'item_image',
    ZineCoverType.uploadedPhoto => 'uploaded_photo',
  };

  static ZineCoverType? fromWire(String? s) => switch (s) {
    'background_color' => ZineCoverType.backgroundColor,
    'item_image' => ZineCoverType.itemImage,
    'uploaded_photo' => ZineCoverType.uploadedPhoto,
    _ => null,
  };
}

/// The 6 Soko brand colours eligible as a cover background. Mirrors the
/// BE `cover_color` enum. [Color] resolution lives in [flutterColor].
enum ZineCoverColor {
  blue,
  green,
  lilac,
  purple,
  red,
  yellow;

  String get wire => name; // lowercase enum name matches wire 1:1

  static ZineCoverColor? fromWire(String? s) => switch (s) {
    'blue' => ZineCoverColor.blue,
    'green' => ZineCoverColor.green,
    'lilac' => ZineCoverColor.lilac,
    'purple' => ZineCoverColor.purple,
    'red' => ZineCoverColor.red,
    'yellow' => ZineCoverColor.yellow,
    _ => null,
  };

  Color get flutterColor => switch (this) {
    ZineCoverColor.blue => AppColors.sokoBlue,
    ZineCoverColor.green => AppColors.sokoGreen,
    ZineCoverColor.lilac => AppColors.sokoLilac,
    ZineCoverColor.purple => AppColors.sokoPurple,
    ZineCoverColor.red => AppColors.sokoRed,
    ZineCoverColor.yellow => AppColors.sokoYellow,
  };
}

/// 8 colours eligible for the title text + Soko logo glyph. Mirrors the
/// BE `cover_text_color` enum: 6 Soko brand colours plus [ink] and
/// [paper]. The 6 overlapping names are spelled identically to
/// [ZineCoverColor] on the wire.
enum ZineCoverTextColor {
  ink,
  paper,
  blue,
  green,
  lilac,
  purple,
  red,
  yellow;

  String get wire => name;

  static ZineCoverTextColor? fromWire(String? s) => switch (s) {
    'ink' => ZineCoverTextColor.ink,
    'paper' => ZineCoverTextColor.paper,
    'blue' => ZineCoverTextColor.blue,
    'green' => ZineCoverTextColor.green,
    'lilac' => ZineCoverTextColor.lilac,
    'purple' => ZineCoverTextColor.purple,
    'red' => ZineCoverTextColor.red,
    'yellow' => ZineCoverTextColor.yellow,
    _ => null,
  };

  Color get flutterColor => switch (this) {
    ZineCoverTextColor.ink => AppColors.sokoInk,
    ZineCoverTextColor.paper => AppColors.sokoPaper,
    ZineCoverTextColor.blue => AppColors.sokoBlue,
    ZineCoverTextColor.green => AppColors.sokoGreen,
    ZineCoverTextColor.lilac => AppColors.sokoLilac,
    ZineCoverTextColor.purple => AppColors.sokoPurple,
    ZineCoverTextColor.red => AppColors.sokoRed,
    ZineCoverTextColor.yellow => AppColors.sokoYellow,
  };
}

/// Deterministic order used by the FE fallback resolver. Iterating
/// `ZineCoverColor.values` is order-stable in Dart so this list is
/// equivalent — kept explicit for documentation and so future enum
/// reorderings don't silently change which fallback a list gets.
const List<ZineCoverColor> kZineColors = <ZineCoverColor>[
  ZineCoverColor.blue,
  ZineCoverColor.green,
  ZineCoverColor.lilac,
  ZineCoverColor.purple,
  ZineCoverColor.red,
  ZineCoverColor.yellow,
];

final Random _zineTextureRng = Random();

/// Pick a random texture id from [kZineTextureCatalog]. Used by the FE
/// create-list call sites so a freshly-created list gets one of the
/// available textures rather than always landing on `kZineDefaultTextureId`
/// (the BE-side default when FE doesn't send the field). Returns the
/// default id when the catalog is somehow empty.
String pickRandomZineTextureId() {
  final keys = kZineTextureCatalog.keys.toList();
  if (keys.isEmpty) return kZineDefaultTextureId;
  return keys[_zineTextureRng.nextInt(keys.length)];
}

const ZineCoverTextColor kZineDefaultTextColor = ZineCoverTextColor.ink;

/// Resolved, render-ready cover recipe for [ListZineCover]. The
/// resolver ([ZineCoverRecipe.fromFields]) consumes raw BE fields and
/// produces this value type with all fallbacks applied. Tests construct
/// it directly.
@immutable
class ZineCoverRecipe {
  final ZineCoverType type;
  final ZineCoverColor color;
  final String
  texture; // catalog id; resolver guarantees it's in [kZineTextureCatalog]
  final ZineCoverTextColor textColor;

  /// Resolved photo URL, or null in solid-colour mode. The resolver
  /// fills this from `cover_item_id` lookup or the legacy
  /// `cover_image_url` compat path.
  final String? photoUrl;

  /// PROD-2297 — per-list curator toggle for the cover title text.
  /// Default `true` matches the BE default. Combined with the
  /// widget-arg [ListZineCover.showTitle] via
  /// `effectiveShowTitle = widgetArg && recipe.showTitle` — either gate
  /// hiding wins.
  ///
  /// `from_profiling` lists (curated `Zine-Profiling-*.jpg` artwork)
  /// have this set to `false` by the BE backfill (PROD-2297) and by the
  /// `/user_profiling/submit` response. The pre-PROD-2300 coarse
  /// `recipe.plain` derived from `list.isFromProfiling` was retired in
  /// PROD-2300; the granular flag carries the same intent.
  final bool showTitle;

  /// PROD-2297 — per-list curator toggle for the paper-texture overlay.
  /// No widget-arg counterpart today; gated on `recipe.showTexture`
  /// alone.
  final bool showTexture;

  /// PROD-2297 — per-list curator toggle for the Soko logo glyph.
  /// Combined with the widget-arg [ListZineCover.showLogo] via the same
  /// "either-gate-hiding-wins" formula as [showTitle].
  final bool showLogo;

  const ZineCoverRecipe({
    required this.type,
    required this.color,
    required this.texture,
    required this.textColor,
    this.photoUrl,
    this.showTitle = true,
    this.showTexture = true,
    this.showLogo = true,
  });

  /// True when the cover should render a photo background + bottom
  /// colour stripe; false when the cover is a solid colour. Derived
  /// from [photoUrl] so legacy `cover_image_url` rows are handled
  /// uniformly with `cover_type=item_image/uploaded_photo`.
  bool get hasPhoto => photoUrl != null && photoUrl!.isNotEmpty;

  /// Asset path of the texture to overlay (always present — resolver
  /// guarantees the texture id resolves).
  String get textureAssetPath => kZineTextureCatalog[texture]!;

  /// Single resolver for every cover-rendering surface (PROD-1918 batch 3).
  /// Takes a [UserList] carrying the full BE recipe (`cover_type`,
  /// `cover_color`, `cover_texture`, `cover_text_color`, `cover_item_id`,
  /// plus the legacy `cover_image_url` channel) and produces a
  /// render-ready recipe.
  ///
  /// [itemLookup] is invoked when `cover_type=item_image` to resolve
  /// `cover_item_id` → image URL. Pass it from surfaces that have the
  /// full item collection (zine view, edit row, change-cover sheet).
  /// Surfaces without items (discovery shelves, lists hub cards, search
  /// results) omit it — those covers render in solid-colour mode for
  /// `cover_type=item_image` lists until the BE exposes a server-side
  /// `cover_item_image_url` (flagged follow-up).
  ///
  /// Replaces the legacy `forListSummary` and the inline `fromFields`
  /// duplication in `list_card.dart` — both silently overrode the user's
  /// `cover_type` choice and sneaked `previewImages[0]` into photo mode,
  /// causing the shelf-vs-zine divergence reported on PROD-1918.
  factory ZineCoverRecipe.fromUserList(
    UserList list, {
    String? Function(String itemId)? itemLookup,
  }) {
    // PROD-2040 — when the user hasn't picked a cover and the list has
    // items, fall back to the most recently added item's image. BE
    // populates `preview_images` ordered by `added_at DESC`, so index 0
    // is the newest. Resolver consumes this in the `backgroundColor`
    // branch only.
    final String? fallbackPhoto =
        (list.previewImages != null && list.previewImages!.isNotEmpty)
        ? list.previewImages!.first
        : null;

    return ZineCoverRecipe.fromFields(
      listId: list.id,
      coverType: list.coverType,
      coverColor: list.coverColor,
      coverTexture: list.coverTexture,
      coverTextColor: list.coverTextColor,
      coverItemId: list.coverItemId,
      coverItemImageUrl: list.coverItemImageUrl,
      legacyCoverImageUrl: list.coverImageUrl,
      fallbackItemImageUrl: fallbackPhoto,
      itemLookup: itemLookup,
      showTitle: list.coverShowTitle,
      showTexture: list.coverShowTexture,
      showLogo: list.coverShowLogo,
    );
  }

  /// Build a recipe from raw BE fields, applying deterministic
  /// fallbacks. `listId` seeds the fallback so legacy/incomplete rows
  /// still render the same colour across devices and refreshes.
  ///
  /// `coverItemImageUrl` is the BE-resolved image URL for the chosen
  /// cover item (PROD-1932). Already proxied, so the FE renders
  /// directly. When non-null AND `type=item_image`, this is the
  /// canonical source for the photo — every surface (shelves + lists
  /// hub cards + zine view + change-cover preview) sees the same image.
  /// Falls back to `itemLookup` for defensive resolution if the BE field
  /// is ever missing.
  ///
  /// `itemLookup` is invoked when `type=item_image` AND
  /// `coverItemImageUrl` is null (i.e. defensive fallback for surfaces
  /// that have the items collection — zine view, edit row, change-cover
  /// preview). Returning `null` (item missing or has no photo) falls
  /// through to solid-colour mode.
  ///
  /// `legacyCoverImageUrl` is the existing `cover_image_url` column.
  /// When it's set AND `type=background_color`, we treat it as a
  /// pre-PROD-1907 item-image-as-URL cover and render in photo mode.
  ///
  /// `fallbackItemImageUrl` is the most recently added item's image
  /// (PROD-2040). Consumed only in the `backgroundColor` branch, AFTER
  /// the legacy URL check — so explicit covers and legacy rows are
  /// untouched. When set, the recipe renders in photo mode visually
  /// identical to a user-chosen `item_image` cover. Pass
  /// `previewImages.first` (BE returns the list ordered by `added_at
  /// DESC`).
  factory ZineCoverRecipe.fromFields({
    required String listId,
    required String? coverType,
    required String? coverColor,
    required String? coverTexture,
    required String? coverTextColor,
    required String? coverItemId,
    String? coverItemImageUrl,
    String? legacyCoverImageUrl,
    String? fallbackItemImageUrl,
    String? Function(String itemId)? itemLookup,
    bool showTitle = true,
    bool showTexture = true,
    bool showLogo = true,
  }) {
    final ZineCoverType resolvedType =
        ZineCoverType.fromWire(coverType) ?? ZineCoverType.backgroundColor;

    final ZineCoverColor resolvedColor =
        ZineCoverColor.fromWire(coverColor) ??
        kZineColors[stableHash(listId) % kZineColors.length];

    // PROD-1918 — deterministic-by-listId texture fallback. Mirrors the
    // colour fallback two lines up so legacy lists (cover_texture null)
    // render varied textures across the catalog instead of all landing
    // on `kZineDefaultTextureId`. Stable across devices and refreshes.
    final String resolvedTexture =
        (coverTexture != null && kZineTextureCatalog.containsKey(coverTexture))
        ? coverTexture
        : (kZineTextureKeys.isEmpty
              ? kZineDefaultTextureId
              : kZineTextureKeys[stableHash(listId) % kZineTextureKeys.length]);

    final ZineCoverTextColor resolvedTextColor =
        ZineCoverTextColor.fromWire(coverTextColor) ?? kZineDefaultTextColor;

    String? resolvedPhoto;
    switch (resolvedType) {
      case ZineCoverType.itemImage:
        // PROD-1932 — BE-resolved URL is the canonical source. Same value
        // on every endpoint that returns the recipe (`ListIdentityOut`
        // and descendants), so shelves + lists-hub cards + search
        // results render the same photo as the zine view.
        if (coverItemImageUrl != null && coverItemImageUrl.isNotEmpty) {
          resolvedPhoto = coverItemImageUrl;
        } else if (coverItemId != null && itemLookup != null) {
          // Defensive fallback for surfaces that have the items
          // collection (zine view, edit row, change-cover preview) —
          // covers the optimistic-update window before the BE round-trip
          // re-populates `cover_item_image_url`, and any future endpoint
          // that for some reason doesn't surface the field.
          final String? url = itemLookup(coverItemId);
          if (url != null && url.isNotEmpty) resolvedPhoto = url;
        }
        // Else fall through to solid mode (resolvedPhoto stays null).
        break;
      case ZineCoverType.uploadedPhoto:
        if (legacyCoverImageUrl != null && legacyCoverImageUrl.isNotEmpty) {
          resolvedPhoto = legacyCoverImageUrl;
        }
        break;
      case ZineCoverType.backgroundColor:
        // Legacy compat: pre-PROD-1907 lists stored item-image as a URL
        // in `cover_image_url` with `cover_type` later backfilled to
        // `background_color`. If the URL is set, treat as photo mode.
        if (legacyCoverImageUrl != null && legacyCoverImageUrl.isNotEmpty) {
          resolvedPhoto = legacyCoverImageUrl;
        } else if (coverColor == null &&
            fallbackItemImageUrl != null &&
            fallbackItemImageUrl.isNotEmpty) {
          // PROD-2040 — non-empty list with no explicit cover: fall back
          // to the most recently added item's image so the cover
          // communicates "this list has content" instead of looking
          // empty next to neighbours with a chosen cover photo.
          //
          // PROD-2425 — gate the fallback on `coverColor == null` so an
          // explicit recipe (the user picked a swatch, or tapped "Sem
          // imagem" which writes the effective color as a sentinel)
          // suppresses the photo. Without this gate, "Sem imagem" is a
          // no-op visually: the resolver keeps painting `previewImages[0]`
          // and the `_NoImageTile` never flips to its selected state
          // (because `noImageSelected = !hasPhoto`).
          resolvedPhoto = fallbackItemImageUrl;
        }
        break;
    }

    return ZineCoverRecipe(
      type: resolvedType,
      color: resolvedColor,
      texture: resolvedTexture,
      showTitle: showTitle,
      showTexture: showTexture,
      showLogo: showLogo,
      textColor: resolvedTextColor,
      photoUrl: resolvedPhoto,
    );
  }
}
