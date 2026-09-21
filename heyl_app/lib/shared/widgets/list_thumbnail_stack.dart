import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../core/theme/app_colors.dart';
import '../../features/lists/utils/zine_cover_recipe.dart';
import '../../features/lists/widgets/zine/list_zine_cover.dart';
import 'cached_image.dart';

/// Small thumbnail tile for a `UserList`, used in the new add-to-list sheet
/// (PROD-1861) and reusable elsewhere.
///
/// Renders up to 4 of [previewImages] as a collage. When previews are
/// empty AND [coverRecipe] is supplied (PROD-2300), falls through to a
/// chrome-off [ListZineCover] so the picker reuses the canonical list-cover
/// pipeline (background colour, texture, photo, recipe-driven) instead of a
/// raw `cover_image_url`. Last-ditch fallback is the legacy [coverImageUrl]
/// single-image branch (kept so non-list callers without a recipe still
/// work), then a list-icon placeholder.
///
/// Layouts (collage): 1 image → full tile, 2 → horizontal halves, 3 →
/// big-left + two-right, 4+ → 2×2 grid.
class ListThumbnailStack extends StatelessWidget {
  const ListThumbnailStack({
    super.key,
    this.previewImages,
    this.coverImageUrl,
    this.coverRecipe,
    this.title,
    this.size = const Size(45, 60),
    this.borderRadius = const BorderRadius.only(
      topLeft: Radius.circular(6),
      bottomLeft: Radius.circular(6),
    ),
  });

  final List<String>? previewImages;
  final String? coverImageUrl;
  final ZineCoverRecipe? coverRecipe;
  final String? title;
  final Size size;
  final BorderRadius borderRadius;

  @override
  Widget build(BuildContext context) {
    final images = _resolveImages();
    return ClipRRect(
      borderRadius: borderRadius,
      child: SizedBox.fromSize(size: size, child: _buildContent(images)),
    );
  }

  List<String> _resolveImages() {
    final previews =
        previewImages?.where((u) => u.isNotEmpty).toList() ?? const [];
    if (previews.isNotEmpty) return previews.take(4).toList();
    // Recipe-aware fallback takes priority over the raw URL — handled in
    // [_buildContent]. Returning empty here drops through to the recipe
    // branch when one is supplied, else to the legacy URL branch.
    if (coverRecipe != null) return const [];
    if (coverImageUrl != null && coverImageUrl!.isNotEmpty) {
      return [coverImageUrl!];
    }
    return const [];
  }

  Widget _buildContent(List<String> images) {
    if (images.isEmpty) {
      final recipe = coverRecipe;
      if (recipe != null) {
        // Title/logo off — at 45 × 60 px the chrome glyphs would render
        // at < 8 px and read as noise. Recipe still drives background
        // colour, texture, and photo (via legacyCoverImageUrl fallback).
        return ListZineCover(
          recipe: recipe,
          title: title ?? '',
          showTitle: false,
          showLogo: false,
        );
      }
      return _placeholder();
    }
    if (images.length == 1) return _image(images[0]);
    if (images.length == 2) {
      return Row(
        children: [
          Expanded(child: _image(images[0])),
          const SizedBox(width: 1),
          Expanded(child: _image(images[1])),
        ],
      );
    }
    if (images.length == 3) {
      return Row(
        children: [
          Expanded(child: _image(images[0])),
          const SizedBox(width: 1),
          Expanded(
            child: Column(
              children: [
                Expanded(child: _image(images[1])),
                const SizedBox(height: 1),
                Expanded(child: _image(images[2])),
              ],
            ),
          ),
        ],
      );
    }
    // 4+
    return Column(
      children: [
        Expanded(
          child: Row(
            children: [
              Expanded(child: _image(images[0])),
              const SizedBox(width: 1),
              Expanded(child: _image(images[1])),
            ],
          ),
        ),
        const SizedBox(height: 1),
        Expanded(
          child: Row(
            children: [
              Expanded(child: _image(images[2])),
              const SizedBox(width: 1),
              Expanded(child: _image(images[3])),
            ],
          ),
        ),
      ],
    );
  }

  Widget _image(String url) {
    return CachedImage(
      imageUrl: url,
      fit: BoxFit.cover,
      errorWidget: _placeholder(),
    );
  }

  Widget _placeholder() {
    return ColoredBox(
      color: AppColors.sokoShade5,
      child: Center(
        child: Icon(LucideIcons.list, size: 16, color: AppColors.sokoShade3),
      ),
    );
  }
}
