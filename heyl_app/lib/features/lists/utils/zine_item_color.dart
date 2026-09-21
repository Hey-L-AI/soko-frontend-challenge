import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:palette_generator/palette_generator.dart';

import '../../../core/services/storage_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/entity_ref.dart';
import '../../../providers/detail_seed_provider.dart';
import 'zine_item_color_cache.dart';

/// Identity for a zine detail-page background-colour lookup (PROD-4072).
///
/// [itemId] is the stable cache key (see [ZineItemColorCache]); [imageUrl]
/// is only used to compute the colour on a cache miss.
@immutable
class ZineItemColorKey {
  const ZineItemColorKey({required this.itemId, required this.imageUrl});

  final String itemId;
  final String? imageUrl;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ZineItemColorKey &&
          other.itemId == itemId &&
          other.imageUrl == imageUrl;

  @override
  int get hashCode => Object.hash(itemId, imageUrl);
}

/// The SharedPreferences-backed colour cache.
final zineItemColorCacheProvider = Provider<ZineItemColorCache>((ref) {
  return ZineItemColorCache(ref.watch(sharedPreferencesProvider));
});

/// Synchronously returns the *already-cached* derived colour for [itemId],
/// or null on a miss. Lets the detail card paint the correct colour on the
/// very first frame (no neutral-grey flash) whenever it has been computed
/// in a previous session.
Color? cachedZineItemColor(WidgetRef ref, String itemId) {
  final argb = ref.read(zineItemColorCacheProvider).read(itemId);
  return argb == null ? null : Color(argb);
}

/// Deterministic on-brand pastel from [itemId] alone — the same id-keyed pick
/// [zineItemColorProvider] falls back to for a colourless / not-yet-loaded
/// image. Public so surfaces that must paint a colour on the very first frame
/// (before any async derivation) get an on-brand value instead of neutral grey.
Color zineItemFallbackColor(String itemId) => _paletteForId(itemId);

/// The full-page background pastel for a standalone event/venue detail page
/// (PROD-4160-followup), derived from the entity's image the same way the zine
/// card + in-list detail derive theirs — so an item wears one consistent colour
/// everywhere. Resolves the image-derived pastel when available, else the sync
/// colour cache, else the deterministic id-keyed pastel (never neutral grey).
/// [imageUrl] is the tapped/loaded hero image; null → id-keyed pastel until the
/// entity's image is known.
Color standaloneDetailBgColor(
  WidgetRef ref,
  String entityId, {
  String? imageUrl,
}) =>
    ref
        .watch(
          zineItemColorProvider(
            ZineItemColorKey(itemId: entityId, imageUrl: imageUrl),
          ),
        )
        .valueOrNull ??
    cachedZineItemColor(ref, entityId) ??
    zineItemFallbackColor(entityId);

/// The image-derived detail background for an entity identified only by
/// kind + id — the shape the map/chat **detail sheets** and other hosts that
/// don't already plumb the hero URL need. Looks the tapped-item's image up from
/// the [DetailSeed] cache automatically, then delegates to the single resolver
/// [standaloneDetailBgColor] (image palette → colour cache → id-keyed pastel).
///
/// This is the app's one point of detail-colour truth: a venue/event wears the
/// SAME pastel whether it's opened as a full page, an in-list card, or a
/// bottom sheet from the map, feed, zine, chat, or a direct URL — never the old
/// fixed Soko/Blue (venue) / Soko/Green (event) split.
Color detailBgForEntity(
  WidgetRef ref, {
  required bool isEvent,
  required String entityId,
}) {
  final kind = isEvent ? EntityKind.event : EntityKind.venue;
  final seedImageUrl = ref.detailSeed(kind, entityId)?.imageUrl;
  return standaloneDetailBgColor(ref, entityId, imageUrl: seedImageUrl);
}

/// Pushes the image-derived detail colour for an entity into [target] whenever
/// it changes — the bridge that lets a bottom-sheet **frame** (which owns its
/// surface colour via a `ValueNotifier` passed to `showDsDraggableSheet`'s
/// `backgroundColorListenable`) recolour to the same pastel the routed detail
/// pages use, and keep updating live as the async palette lands. Renders
/// nothing; mount it anywhere inside the sheet content that knows the resolved
/// entity id.
class DetailBgColorSync extends ConsumerWidget {
  const DetailBgColorSync({
    super.key,
    required this.isEvent,
    required this.entityId,
    required this.target,
  });

  final bool isEvent;
  final String entityId;
  final ValueNotifier<Color> target;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bg = detailBgForEntity(ref, isEvent: isEvent, entityId: entityId);
    // Write post-frame: mutating the notifier synchronously here would notify
    // the sheet frame (an ancestor) mid-build — "setState during build".
    if (target.value != bg) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        target.value = bg;
      });
    }
    return const SizedBox.shrink();
  }
}

/// Resolves the background colour for a zine detail page.
///
/// Read-through: a cache hit returns immediately; a miss derives a colour
/// from the item's image (see [_deriveColor]), caches it, and returns it.
/// Always resolves to an on-brand colour — items with no image get a
/// deterministic brand pastel from their id, so every detail page is
/// intentionally coloured like the design (never a lone neutral card).
final zineItemColorProvider = FutureProvider.family<Color, ZineItemColorKey>((
  ref,
  key,
) async {
  final cache = ref.watch(zineItemColorCacheProvider);

  final cached = cache.read(key.itemId);
  if (cached != null) return Color(cached);

  final url = key.imageUrl;
  final derived = (url == null || url.isEmpty)
      ? _paletteForId(key.itemId)
      : await _deriveColor(url, key.itemId);
  await cache.write(key.itemId, derived.toARGB32());
  return derived;
});

/// PROD-4072 — the on-brand pastels a zine detail page can use. This is the
/// closed set the "snap" and greyscale-fallback paths pick from, so a zine
/// never lands on an off-brand or muddy colour.
/// Seven hue-distinct brand pastels — the closed set of colours a zine
/// detail page can use. The image's standout hue snaps to the nearest of
/// these (by hue), so a warm photo lands cleanly on red / yellow / pink
/// rather than a muddy in-between, and different hues stay visually
/// separated. Rendered at their native Soko values — already designed as
/// legible detail-page backgrounds for the dark `sokoInk` text.
const List<Color> _sokoPalette = [
  AppColors.sokoBlue,
  AppColors.sokoGreen,
  AppColors.sokoYellow,
  AppColors.sokoRed,
  AppColors.sokoPink,
  AppColors.sokoLilac,
  AppColors.sokoPurple,
];

/// A standout swatch below this saturation carries no usable hue (it's
/// essentially grey), so we treat the image as colourless and fall back to
/// the id-keyed pick.
const double _usableHueSaturation = 0.12;

/// Colour derivation (PROD-4072). The rule: take the image's **standout**
/// colour and **snap it to the nearest brand pastel by hue**, so every card
/// is a clean, separated, on-brand colour (never a muddy in-between). Order:
/// 1. a vibrant/standout swatch with a usable hue → nearest palette colour;
/// 2. else the dominant colour, if it has a usable hue → nearest palette colour;
/// 3. else (greyscale / undecodable / CORS-blocked) → deterministic palette
///    colour from the item id.
///
/// `palette_generator` computes the *vibrant* swatch (the colour that pops)
/// separately from the muddy `dominant`, which is why it's preferred.
Future<Color> _deriveColor(String imageUrl, String itemId) async {
  try {
    final palette = await PaletteGenerator.fromImageProvider(
      CachedNetworkImageProvider(imageUrl),
      // We only need the palette, not the pixels — downscale hard so the
      // decode + quantise stays cheap.
      size: const Size(120, 120),
      maximumColorCount: 16,
    );

    final standout =
        (palette.vibrantColor ??
                palette.lightVibrantColor ??
                palette.darkVibrantColor ??
                palette.dominantColor)
            ?.color;
    if (standout != null) {
      final hsl = HSLColor.fromColor(standout);
      if (hsl.saturation >= _usableHueSaturation) {
        return _nearestSokoByHue(hsl.hue);
      }
    }
    return _paletteForId(itemId);
  } catch (_) {
    return _paletteForId(itemId);
  }
}

/// The brand pastel whose hue is closest to [hue] on the colour wheel.
Color _nearestSokoByHue(double hue) {
  var best = _sokoPalette.first;
  var bestDistance = 360.0;
  for (final candidate in _sokoPalette) {
    final delta = (HSLColor.fromColor(candidate).hue - hue).abs();
    final distance = delta > 180 ? 360 - delta : delta;
    if (distance < bestDistance) {
      bestDistance = distance;
      best = candidate;
    }
  }
  return best;
}

/// Deterministic brand pastel keyed off the item id — stable across sessions
/// and devices, spread across the palette so colourless posters stay
/// visually distinct instead of clustering.
Color _paletteForId(String itemId) {
  var hash = 0;
  for (final unit in itemId.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  return _sokoPalette[hash % _sokoPalette.length];
}
