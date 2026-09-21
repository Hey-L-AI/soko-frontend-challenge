import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import 'dotted_line.dart';

/// Soko/Shade4 dotted-line section divider with 20 px breathing space
/// above and below. Defines the list-page section rhythm; same dot
/// styling as Discovery's [ShelfDivider] (1 px round dots, ~3.5 px
/// centre-to-centre pitch — denser than the shared [DottedLine]
/// defaults).
///
/// Use between major sections on Soko/Paper backgrounds — list page,
/// detail page, etc. For Discovery shelves keep using `ShelfDivider`
/// (same visual; the name is part of the Discovery vocabulary).
class DottedSectionDivider extends StatelessWidget {
  const DottedSectionDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 20),
      child: DottedLine(
        color: AppColors.sokoShade4,
        spacing: 3.5,
        dotSize: 0.5,
      ),
    );
  }
}
