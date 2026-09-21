import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/app_colors.dart';

/// `Icon/Brain` — the memory mark, straight from Figma
/// (`7532:24627`, the "Adiciona algo às tuas memórias" pill).
///
/// Two mirrored hemispheres, not Lucide's `brain`: the lobes are squarer and
/// the stem runs the full height. Shipped as SVG rather than a PNG so it stays
/// crisp at every size and takes a tint — the source paints its strokes
/// `#3B0F18` (Soko ink) and the [color] filter recolours them wholesale, which
/// is safe here because the glyph is monochrome by construction.
class SokoBrainIcon extends StatelessWidget {
  final double size;
  final Color color;

  const SokoBrainIcon({
    super.key,
    this.size = 18,
    this.color = AppColors.sokoInk,
  });

  @override
  Widget build(BuildContext context) {
    return SvgPicture.asset(
      'assets/images/icons/memory/brain.svg',
      width: size,
      height: size,
      colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
    );
  }
}
