import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Numbered section header for the Business Home dashboard ("1 · Phone number",
/// "2 · Instagram", "3 · Your venues"). Serif label over a hairline rule,
/// echoing the wireframe's dotted section dividers.
class BusinessHomeSectionHeader extends StatelessWidget {
  const BusinessHomeSectionHeader({
    super.key,
    this.number,
    required this.title,
  });

  final String? number;
  final String title;

  @override
  Widget build(BuildContext context) {
    final label = number == null ? title : '$number · $title';
    return Container(
      padding: const EdgeInsets.only(bottom: 8),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppColors.sokoInk8, width: 1.5),
        ),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'UnJamoBatang',
          fontSize: 17,
          color: AppColors.sokoInk,
        ),
      ),
    );
  }
}
