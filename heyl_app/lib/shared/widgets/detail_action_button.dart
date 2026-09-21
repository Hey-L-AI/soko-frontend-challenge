import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import 'press_pop.dart';

/// One cell in the detail-page action row (PROD-2939): a bare ~30 px glyph with
/// a caption beneath it. The row lays these out full-width with space-between
/// (Guarda · Lembrete · Partilha · 👍 · 👎), per Figma `7213-29087`.
///
/// No circular chrome — the glyph sits bare. Active state ports the prior chip
/// convention (pink when on): callers pass a glyph already tinted / filled for
/// its state; this widget only owns layout, press feedback, and the caption.
class DetailActionButton extends StatelessWidget {
  /// The 30 px glyph. Selection is shown by the caller swapping to the FILLED
  /// (solid brown) glyph variant; the unselected state is the thin outline.
  final Widget icon;

  /// Caption shown beneath the glyph.
  final String label;

  final VoidCallback onTap;

  /// When true, a tap plays the tactile grow-then-settle "pop" (the reactive
  /// buttons — Share, 👍/👎). Left `false` for the Save cell, which opens a
  /// full drawer on tap and keeps only the legacy press feedback.
  final bool popOnTap;

  const DetailActionButton({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.popOnTap = false,
  });

  /// Shared caption style so buttons that can't route through this widget
  /// (e.g. the reminder bell, which keeps its own spotlight/hint wrappers)
  /// still render an identical caption. Matches Figma `7213-29087`
  /// (Zalando Sans Light 14, Soko/Shade1).
  static const TextStyle captionStyle = TextStyle(
    fontFamily: 'ZalandoSans',
    fontWeight: FontWeight.w300,
    fontSize: 11,
    height: 1.2,
    letterSpacing: -0.14,
    color: AppColors.sokoShade1,
  );

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: true,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: PressPop(
          onTap: onTap,
          pop: popOnTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(width: 30, height: 30, child: Center(child: icon)),
              const SizedBox(height: 8),
              Text(
                label,
                // Wrap to a second line before truncating — some locales have
                // captions too long for one line at the cell's Expanded width
                // (e.g. "Partilhar"). Rows top-align their cells so a wrapped
                // caption grows downward and the glyphs stay aligned.
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: DetailActionButton.captionStyle,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
