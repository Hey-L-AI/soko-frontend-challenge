import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/theme/app_colors.dart';

/// 14×14 library glyphs from the Figma file (not Lucide stand-ins).
class LibraryGlyph {
  static const double size = 14;

  static const pinAsset = 'assets/images/icons/library/icon-pin.svg';
  static const arrowDownAsset =
      'assets/images/icons/library/icon-arrow-down.svg';
  static const listAsset = 'assets/images/icons/library/icon-list.svg';
  static const gridAsset = 'assets/images/icons/library/icon-grid.svg';

  static Widget pin() => SvgPicture.asset(pinAsset, width: size, height: size);

  static Widget ink(String asset) => SvgPicture.asset(
    asset,
    width: size,
    height: size,
    colorFilter: const ColorFilter.mode(AppColors.sokoInk, BlendMode.srcIn),
  );
}
