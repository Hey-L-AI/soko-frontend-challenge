import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/dotted_line.dart';

/// Dotted divider between Discovery shelves. Matches Figma node `6144:5109`
/// from `d4BCnyUHe2705J7ecQtaIH`: a row of `Soko/Shade4` (`#C1B2B5`) dots.
///
/// Spacing (tightened from the original 30/30 Figma spec per PROD-1961):
///   - 12 px above the dots — tight hand-off from the previous shelf's
///     last card row.
///   - 20 px below the dots — gives the next shelf's title a touch more
///     breathing room before its H1 line so the divider doesn't sit
///     right against the headline.
///
/// Tuned to the Figma `stroke-dasharray="0.07 3.42"` rhythm — ~1 px round
/// dots with a ~3.5 px centre-to-centre pitch — which is denser than the
/// shared `DottedLine` defaults (1 px dots, 6 px pitch) used elsewhere in
/// the app.
class ShelfDivider extends StatelessWidget {
  const ShelfDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.only(top: 12, bottom: 20),
      child: DottedLine(
        color: AppColors.sokoShade4,
        spacing: 3.5,
        dotSize: 0.5,
      ),
    );
  }
}
