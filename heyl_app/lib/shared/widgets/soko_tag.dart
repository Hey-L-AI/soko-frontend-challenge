import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Shared inline tag pill used across detail pages, chat cards, and the map
/// pin tooltip. Mirrors the Figma `Tag` primitive — radius 2, padding 6/2,
/// gap 6, Zalando Sans Light label with Soko/Ink.
///
/// Background is supplied by the caller so the same widget renders every
/// variant (Soko/Venue, Soko/Event, Soko/Yellow rating, Soko/Red saves).
/// Optional [leading] sits before the label (used for the bookmark + star
/// icons on detail pages).
///
/// Use [textStyle] for the standard 14 px label or [textStyleCompact] for
/// the 12 px variant on tight card layouts.
class SokoTag extends StatelessWidget {
  const SokoTag({
    super.key,
    required this.background,
    required this.child,
    this.leading,
  });

  static const TextStyle textStyle = TextStyle(
    fontFamily: 'ZalandoSans',
    fontWeight: FontWeight.w300,
    fontSize: 14,
    height: 1.2,
    letterSpacing: -0.14,
    color: AppColors.sokoInk,
  );

  static const TextStyle textStyleCompact = TextStyle(
    fontFamily: 'ZalandoSans',
    fontWeight: FontWeight.w300,
    fontSize: 12,
    height: 1.2,
    letterSpacing: -0.12,
    color: AppColors.sokoInk,
  );

  final Color background;
  final Widget? leading;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(2),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (leading != null) ...[leading!, const SizedBox(width: 6)],
          child,
        ],
      ),
    );
  }
}
