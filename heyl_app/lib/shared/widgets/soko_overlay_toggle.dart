// The one toggle that sits ON a card's photo — save, like, dislike.
//
// It exists because the rule it encodes (D310) had already been written three
// times, and one of the three drifted: the venue grid tile still flipped its
// circle to opaque paper on selection, the treatment D310 replaced. A rule
// spelled once in three files is a rule that will disagree with itself again.

import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import 'circle_icon_button.dart';

/// A frosted circular toggle overlaid on a card image.
///
/// **The ground never changes.** At rest and when selected the circle paints
/// the same translucent [ground]; the state is carried entirely by the glyph
/// swapping its paper *outline* for a paper *fill* (D310, revising D295).
/// Hovering previews the fill without committing anything.
///
/// That is the whole contract, and it is the half that keeps getting lost — a
/// selected-state background is the reflex, and it reads as a second, louder
/// control sitting on the photo. The glyph is always [AppColors.sokoPaper] in
/// both states, so it stays legible over any image without the ground having to
/// do the work.
///
/// **Not for buttons that sit on paper.** The bundle row's save button is a
/// bare [CircleIconButton] on the page's own ground, where an ink glyph on a
/// light circle is correct and this widget's white-on-translucent would vanish.
/// The rule here is specifically about drawing on top of a photograph.
class SokoOverlayToggle extends StatelessWidget {
  const SokoOverlayToggle({
    super.key,
    required this.selected,
    required this.semanticLabel,
    required this.onTap,
    required this.glyph,
    this.flip = false,
    this.size = thumbnailSize,
    this.ground = frostedInk30,
    this.blurSigma = defaultBlur,
  });

  /// Whether the control is on. Drives the glyph only — never the ground.
  final bool selected;

  final String semanticLabel;
  final VoidCallback onTap;

  /// `(active, colour) -> glyph`. The colour is passed for BOTH states because
  /// a two-state glyph paints its outline and its fill in the same ink here;
  /// what changes between rest and selection is only which of the two is drawn.
  final Widget Function(bool active, Color color) glyph;

  /// Rotate the glyph 180°. 👎 is the 👍 asset turned over, not a second file —
  /// the same relationship the detail row and the chat cards use.
  final bool flip;

  final double size;

  /// The constant translucent circle. See [frostedInk30] / [frostedPaper30].
  final Color ground;

  /// Backdrop blur behind the circle. `0` skips the [BackdropFilter] entirely
  /// rather than blurring by zero — a no-op filter still forces a saveLayer.
  final double blurSigma;

  /// 30 px — a chip on a thumbnail or a shared card. The hero poster draws 40.
  static const double thumbnailSize = 30;

  /// `Soko/Ink 30` (`rgba(121,121,121,0.3)`) — the ground on a thumbnail-sized
  /// cover, where a darker circle keeps a white glyph legible over a bright
  /// photo. Figma `7674:37414` (shared card) and `7675:38686` (venue grid).
  static const Color frostedInk30 = Color(0x4D797979);

  /// `Soko/Paper 30` — the hero poster's lighter scrim. Deliberately a
  /// different token from [frostedInk30]: on a large photo the paper tint reads
  /// as a scrim rather than a smudge.
  static const Color frostedPaper30 = Color(0x4DF9F0F0);

  /// The 4 px backdrop blur the frosted chips carry on the frame.
  static const double defaultBlur = 4;

  @override
  Widget build(BuildContext context) {
    final button = CircleIconButton(
      size: size,
      // #1435 rolled the shared release-overshoot out to every like/dislike/
      // save control. Every instance of this widget is one of those, so the
      // flag is unconditional here rather than a parameter.
      popOnTap: true,
      background: ground,
      // Unused by the glyph path, but `CircleIconButton` blends it into the
      // press/hover background tint, so it must still be the on-circle colour.
      iconColor: AppColors.sokoPaper,
      semanticLabel: semanticLabel,
      selected: selected,
      onTap: onTap,
      glyphBuilder: (hovered) {
        final child = glyph(selected || hovered, AppColors.sokoPaper);
        return flip ? Transform.rotate(angle: math.pi, child: child) : child;
      },
    );

    if (blurSigma <= 0) return button;

    // The blur must be clipped to the circle, or it bleeds across the whole
    // cover — `BackdropFilter` samples everything painted beneath its subtree.
    return ClipOval(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: button,
      ),
    );
  }
}
