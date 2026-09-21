import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import 'memory_glyph.dart';

/// Every circular control on the memory surface — trash, -, +, and the section
/// arrow — is one size. The Figma icons all export from the same 26x26 box, and
/// the mockup draws them as a single family down the right edge of each row.
const double kMemoryControlSize = 31;

/// A small outlined circular icon button — the trash / − / + controls that
/// flank a [MemoryBarRow], and the ↑↓ hinge on a section header.
///
/// Deliberately borderless-on-fill: the design draws them as a hairline ring
/// on paper, never a filled button, so they read as quiet controls next to the
/// pink bar rather than competing with it.
class MemoryCircleButton extends StatelessWidget {
  /// A Lucide glyph drawn inside a ring this widget paints (the trash).
  final IconData? icon;

  /// One of the design's circled marks, which carry their OWN ring (+, -, the
  /// section arrow). Mutually exclusive with [icon].
  final MemoryGlyphKind? glyph;
  final double size;
  final double iconSize;
  final VoidCallback? onTap;
  final String? tooltip;

  const MemoryCircleButton({
    super.key,
    required this.onTap,
    this.icon,
    this.glyph,
    this.size = kMemoryControlSize,
    this.iconSize = 15,
    this.tooltip,
  }) : assert(
         (icon == null) != (glyph == null),
         'Provide exactly one of `icon` or `glyph`.',
       );

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final Widget child = glyph != null
        // The exported marks (+, -, arrow) carry their own full-opacity,
        // full-bleed ink ring.
        ? MemoryGlyph(
            kind: glyph!,
            size: size,
            color: AppColors.sokoInk.withValues(alpha: enabled ? 1 : 0.28),
          )
        // The trash and the pencil are NOT part of that export set — they keep
        // the original quieter hairline ring on purpose. Do not fold them into
        // the glyph treatment.
        : Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: AppColors.sokoInk.withValues(
                  alpha: enabled ? 0.35 : 0.15,
                ),
              ),
            ),
            child: Center(
              child: Icon(
                icon,
                size: iconSize,
                color: AppColors.sokoInk.withValues(alpha: enabled ? 1 : 0.3),
              ),
            ),
          );

    final button = GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: child,
    );
    if (tooltip == null) return button;
    return Tooltip(message: tooltip!, child: button);
  }
}

/// One memory value, drawn as a horizontal strength bar instead of a chip.
///
/// The bar is the whole row's surface: the label sits on the left, the level
/// number on the right, and a pink fill runs from the left edge to
/// `level / maxLevel` of the width. Tapping the bar does nothing — provenance
/// ("where Soko learned this") is deliberately not reachable from here; the
/// only affordances are the three controls around it, so the page reads as
/// something you tune, not something you inspect.
class MemoryBarRow extends StatelessWidget {
  final String label;

  /// Current strength, 1..[maxLevel]. Drives the number and the − / + rails.
  final int level;
  final int maxLevel;

  /// Continuous fill fraction (0..1). When set, the pink bar renders the RAW
  /// proportional strength — 19 acts of live music visibly outfill 5 acts of
  /// DJ even inside the same numeric band. Null falls back to level/maxLevel.
  final double? fill;

  /// Null disables the control (greyed ring, no tap).
  final VoidCallback? onDelete;
  final VoidCallback? onDecrease;
  final VoidCallback? onIncrease;

  /// Hides the number + fill entirely — used for values that aren't graded
  /// (the home location, and "avoided" values where a strong bar would read
  /// as a strong *like*).
  final bool showLevel;

  const MemoryBarRow({
    super.key,
    required this.label,
    required this.level,
    required this.onDelete,
    required this.onDecrease,
    required this.onIncrease,
    this.maxLevel = 5,
    this.fill,
    this.showLevel = true,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        children: [
          MemoryCircleButton(
            icon: LucideIcons.trash_2,
            size: 30,
            iconSize: 15,
            onTap: onDelete,
          ),
          const SizedBox(width: 7),
          Expanded(child: _bar()),
          // No meter, no nudge: an ungraded row (an avoided value, the home
          // location) has no level for - / + to move, so the controls are
          // omitted rather than rendered dead. Two permanently greyed circles
          // on every avoid row read as broken, not as "not applicable".
          if (showLevel) ...[
            const SizedBox(width: 9),
            MemoryCircleButton(
              glyph: MemoryGlyphKind.minus,
              onTap: level > 1 ? onDecrease : null,
            ),
            const SizedBox(width: 10),
            MemoryCircleButton(
              glyph: MemoryGlyphKind.plus,
              onTap: level < maxLevel ? onIncrease : null,
            ),
          ],
        ],
      ),
    );
  }

  Widget _bar() {
    // A row at the TOP band always draws a full bar. `fill` is the raw
    // certainty, and the strongest bands the system emits are 0.95 (earned
    // five) and 0.97 (a user pin) — proportional fill would leave a "5"
    // visibly short of the right edge, reading as "almost max" when the
    // meter says max (2026-09-11). Proportionality still applies below the
    // ceiling, where bands have real headroom between them.
    final fraction = !showLevel
        ? 0.0
        : level >= maxLevel
        ? 1.0
        : (fill ?? (level.clamp(1, maxLevel)) / maxLevel).clamp(0.08, 1.0);
    return Container(
      height: 28,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.sokoInk.withValues(alpha: 0.10)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          if (fraction > 0)
            Positioned.fill(
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: fraction,
                child: const ColoredBox(color: AppColors.sokoPink),
              ),
            ),
          Positioned.fill(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontFamily: 'ZalandoSans',
                        fontSize: 14,
                        height: 1.2,
                        letterSpacing: -0.14,
                        fontWeight: FontWeight.w300,
                        color: AppColors.sokoInk,
                      ),
                    ),
                  ),
                  if (showLevel) ...[
                    const SizedBox(width: 8),
                    Text(
                      '$level',
                      style: const TextStyle(
                        fontFamily: 'ZalandoSans',
                        fontSize: 14,
                        height: 1.2,
                        fontWeight: FontWeight.w400,
                        color: AppColors.sokoInk,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
