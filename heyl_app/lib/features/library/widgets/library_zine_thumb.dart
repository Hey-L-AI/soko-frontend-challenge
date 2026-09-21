import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../features/lists/utils/zine_cover_recipe.dart';
import '../../../features/lists/widgets/zine/list_zine_cover.dart';
import '../../../shared/widgets/soko_zine_corner_fold.dart';
import 'library_item_row.dart';

/// Zine thumbnail: full [ListZineCover] plus the static home-feed corner fold.
class LibraryZineThumb extends StatelessWidget {
  const LibraryZineThumb({
    super.key,
    required this.listId,
    required this.name,
    this.coverRecipe,
  });

  final String listId;
  final String name;
  final ZineCoverRecipe? coverRecipe;

  static final BorderRadius _radius = BorderRadius.circular(4);

  @override
  Widget build(BuildContext context) {
    final recipe = coverRecipe;
    return SizedBox(
      width: kLibraryThumbWidth,
      height: kLibraryRowHeight,
      child: ClipRRect(
        borderRadius: _radius,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (recipe != null)
              ListZineCover(recipe: recipe, title: name)
            else
              const ColoredBox(color: AppColors.sokoShade5),
            if (recipe != null)
              SokoZineCornerFold(
                pageColor: SokoZineCornerFold.pageColorFor(
                  listId,
                  coverColor: recipe.color,
                ),
              ),
          ],
        ),
      ),
    );
  }
}
