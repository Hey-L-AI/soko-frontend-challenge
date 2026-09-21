import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../core/utils/soko_texture.dart';

/// Composites its [child] onto whatever is painted below it (a sibling earlier
/// in a [Stack]) using [blendMode] — the widget-tree equivalent of CSS
/// `mix-blend-mode`. Used to lay the Soko grunge texture over a coloured fill
/// with Hard Light, matching the Figma export.
class BlendMask extends SingleChildRenderObjectWidget {
  final BlendMode blendMode;
  final double opacity;

  const BlendMask({
    super.key,
    required this.blendMode,
    this.opacity = 1.0,
    super.child,
  });

  @override
  RenderObject createRenderObject(BuildContext context) =>
      RenderBlendMask(blendMode, opacity);

  @override
  void updateRenderObject(BuildContext context, RenderBlendMask renderObject) {
    renderObject
      ..blendMode = blendMode
      ..opacity = opacity;
  }
}

class RenderBlendMask extends RenderProxyBox {
  BlendMode blendMode;
  double opacity;

  RenderBlendMask(this.blendMode, this.opacity);

  @override
  void paint(PaintingContext context, Offset offset) {
    context.canvas.saveLayer(
      offset & size,
      Paint()
        ..blendMode = blendMode
        ..color = Color.fromRGBO(255, 255, 255, opacity),
    );
    super.paint(context, offset);
    context.canvas.restore();
  }
}

/// A rounded coloured tile carrying the Soko paper grain blended over the fill
/// in Hard Light — the printed-paper look from Figma, kept subtle so the colour
/// stays vibrant. The optional [child] (glyph/label) sits on top of the texture
/// so it stays crisp.
///
/// ⚠️ This used to name the sheet "Texturelabs Grunge 340S". **It is not.**
/// `avatar-texture.png` is Figma's *Gstaik* paper grain (`kSokoPaperGrainTexture`,
/// correlation 0.996); it correlates **0.04** with the real
/// `Texturelabs_Grunge_340S 2`, which arrived separately as
/// [kSokoWeeklyBundleCardTexture]. The wrong name here sent one search for the
/// weekly card's grain to the wrong file.
class SokoGrungeSurface extends StatelessWidget {
  final double width;
  final double height;
  final double radius;
  final Color color;
  final Widget? child;

  /// Texture strength. Icons run at 1.0 with Hard Light (Figma spec).
  final double textureOpacity;

  /// Sheet over the fill. Defaults to the Gstaik photo grain; small colour
  /// tiles that want a regular cardstock speckle pass
  /// [kSokoWeeklyBundleCardTexture] instead.
  final String texture;

  const SokoGrungeSurface({
    super.key,
    required this.width,
    required this.height,
    required this.color,
    this.radius = 2,
    this.child,
    this.textureOpacity = 1.0,
    this.texture = kSokoPaperGrainTexture,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            ColoredBox(color: color),
            IgnorePointer(
              child: BlendMask(
                blendMode: BlendMode.hardLight,
                opacity: textureOpacity,
                // Fill (not cover) so the whole grain compresses into the small
                // tile as a fine, even grain — matching Figma's "scale: fill" —
                // instead of a cover-window showing one big crease.
                child: sokoTextureImage(texture),
              ),
            ),
            if (child != null) Center(child: child!),
          ],
        ),
      ),
    );
  }
}
