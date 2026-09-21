import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_theme.dart';
import '../../../../shared/widgets/soko_dotted_rule.dart';
import '../../../../core/utils/month_abbr.dart';

/// Shared editorial chrome for the Discovery Daily Drop and Weekly Bundle
/// covers (PROD-1518). Paints, top → bottom:
///
/// 1. Thin dotted rule near the top.
/// 2. Header row: short date (locale-aware) · Soko wordmark · year.
/// 3. Optional [middle] band — Weekly Bundle uses this for its row of
///    thumbnails; Daily Drop leaves it null so the cover photo shows
///    through.
/// 4. A second dotted rule above the lockup.
/// 5. The [lockup] widget filling the bottom band.
///
/// All chrome paints in [foregroundColor] (Soko pink for Daily Drop,
/// Soko ink for Weekly Bundle). Header text optionally gets a [shadows]
/// halo for legibility on photographic backgrounds.
///
/// Figma reference: node `3841:2309` (file `nJJ4z2UO58wWMxZstpFVle`).
/// Positions are pinned to ratios of the 399 × 213 base frame so the
/// chrome scales cleanly with the rendered card width.
class EditorialOverlay extends StatelessWidget {
  final Color foregroundColor;
  final DateTime date;
  final String locale;
  final Widget lockup;
  final Widget? middle;
  final List<Shadow>? textShadows;

  /// Optional tint painted behind the chrome (Daily Drop uses 40 % black
  /// over the cover photo to keep the pink chrome legible — figma node
  /// 3841:2289 layer order).
  final Color? backgroundTint;

  const EditorialOverlay({
    super.key,
    required this.foregroundColor,
    required this.date,
    required this.locale,
    required this.lockup,
    this.middle,
    this.textShadows,
    this.backgroundTint,
  });

  // Figma frame baseline.
  static const double _baseW = 399;
  static const double _baseH = 213;

  // Y positions as ratios of the 213-tall frame, per figma node 3841:2289
  // (Daily Drop) and 3841:2326 (Weekly Bundle).
  static const double _topRuleY = 11 / _baseH;
  static const double _headerY = 18 / _baseH;
  // Thumbnail strip on Weekly Bundle: each thumb 71×83 centred at y ≈ 98
  // (`top: calc(37.5% + 17.63px)` minus translateY 50%). Strip top edge
  // sits ~57 px down (98 − 41), height 83.
  static const double _middleY = 57 / _baseH;
  static const double _middleH = 83 / _baseH;
  // Bottom dotted rule at `top: calc(50% + 38.5px)` = 145.
  static const double _bottomRuleY = 145 / _baseH;
  static const double _lockupY = 148 / _baseH;
  static const double _lockupH = 60 / _baseH;

  // Horizontal padding (matches Figma's `left: 11.83 px`).
  static const double _hPadRatio = 11.83 / _baseW;

  @override
  Widget build(BuildContext context) {
    final shortDate = _formatShortDate(date, locale);
    final year = DateFormat('y', locale).format(date);

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final scale = w / _baseW;
        final hPad = w * _hPadRatio;
        final headerFontSize = 18.0 * scale;
        final logoHeight = 22.0 * scale;

        return Stack(
          fit: StackFit.expand,
          clipBehavior: Clip.hardEdge,
          children: [
            if (backgroundTint != null)
              Positioned.fill(child: ColoredBox(color: backgroundTint!)),

            // Top dotted rule.
            Positioned(
              top: h * _topRuleY,
              left: hPad,
              right: hPad,
              child: SokoDottedRule(color: foregroundColor),
            ),

            // Header strip: date · Soko wordmark · year. Date / year are
            // [Expanded]; the wordmark renders at its natural aspect from
            // the SVG, with explicit `height` so it doesn't fall back to
            // the asset's intrinsic 1619 px width and blow up the Row.
            Positioned(
              top: h * _headerY,
              left: hPad,
              right: hPad,
              height: headerFontSize * 1.6,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      shortDate,
                      textAlign: TextAlign.left,
                      style: _headerStyle(headerFontSize),
                    ),
                  ),
                  SvgPicture.asset(
                    'assets/images/logos/soko-logo-paper.svg',
                    height: logoHeight,
                    fit: BoxFit.contain,
                    colorFilter: ColorFilter.mode(
                      foregroundColor,
                      BlendMode.srcIn,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      year,
                      textAlign: TextAlign.right,
                      style: _headerStyle(headerFontSize),
                    ),
                  ),
                ],
              ),
            ),

            // Optional middle band (Weekly Bundle thumbnail strip).
            if (middle != null)
              Positioned(
                top: h * _middleY,
                left: hPad,
                right: hPad,
                height: h * _middleH,
                child: middle!,
              ),

            // Bottom dotted rule.
            Positioned(
              top: h * _bottomRuleY,
              left: hPad,
              right: hPad,
              child: SokoDottedRule(color: foregroundColor),
            ),

            // Bottom lockup band — the consumer owns the contents.
            Positioned(
              left: hPad,
              right: hPad,
              top: h * _lockupY,
              height: h * _lockupH,
              child: lockup,
            ),
          ],
        );
      },
    );
  }

  TextStyle _headerStyle(double size) => AppTheme.body(
    fontSize: size,
    fontWeight: FontWeight.w500,
    color: foregroundColor,
    height: 1.0,
  ).copyWith(shadows: textShadows);

  String _formatShortDate(DateTime d, String locale) {
    return '${formatMonthAbbr(d, locale)}. ${d.day}';
  }
}
