import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '_editorial_overlay.dart';

/// Daily Drop editorial overlay (PROD-1518). Layers the dotted rules,
/// date/Soko/year header, and the "DAILY DROP" lockup over the BE-served
/// cover photo. All chrome paints in Soko pink with a soft black halo
/// for legibility on warm-toned curated covers.
///
/// Figma reference: node `3841:2309` (file `nJJ4z2UO58wWMxZstpFVle`).
class DailyDropOverlay extends StatelessWidget {
  final DateTime date;
  final String locale;

  const DailyDropOverlay({super.key, required this.date, required this.locale});

  @override
  Widget build(BuildContext context) {
    return EditorialOverlay(
      foregroundColor: AppColors.sokoPink,
      date: date,
      locale: locale,
      // 40 % black tint over the cover photo, per figma node 3841:2289
      // layer order. Keeps the pink chrome legible regardless of cover
      // brightness without resorting to per-element halos.
      backgroundTint: const Color(0x66000000),
      // Belt-and-braces halo on the small text so it survives covers
      // with stark gradients beneath the 40 % tint.
      textShadows: const [Shadow(blurRadius: 6, color: Color(0x66000000))],
      lockup: LayoutBuilder(
        builder: (context, constraints) {
          final scale = constraints.maxWidth / 376; // approx Figma usable width
          final fontSize = 70.0 * scale;
          return FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: Text(
              'DAILY DROP',
              textAlign: TextAlign.center,
              style:
                  AppTheme.display(
                    fontSize: fontSize,
                    fontWeight: FontWeight.w400, // Figma weight 420 ≈ w400
                    color: AppColors.sokoPink,
                    height: 0.86,
                  ).copyWith(
                    letterSpacing: fontSize * -0.03,
                    shadows: const [
                      Shadow(blurRadius: 8, color: Color(0x55000000)),
                    ],
                  ),
            ),
          );
        },
      ),
    );
  }
}
