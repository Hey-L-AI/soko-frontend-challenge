import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/cached_image.dart';
import '../../../core/utils/soko_texture.dart';
import '../../../shared/widgets/soko_grunge_surface.dart';
import '../utils/profile_style.dart';

/// Profile avatar with the Soko paper-grain texture overlay (matches Figma —
/// every profile photo carries the same printed-paper "Gstaik" texture, at 50%
/// opacity as in the design). Shows the photo when [url] is set, else a Season
/// Mix initial on a tinted card. The texture sits on top of both so the
/// initial-placeholder reads the same as a photo.
///
/// **The shape is a rounded square, and it lives here rather than at each call
/// site.** The canonical box is Figma's 80×80 suggestion card with a 16-px
/// radius; every other size derives from it through [kRadiusRatio]. Passing an
/// explicit [radius] per surface is what let the app drift into a mix of
/// portrait cards, circles and squircles — three shapes for one thing.
class TexturedAvatar extends StatelessWidget {
  final String? url;
  final String? name;
  final double width;
  final double height;

  /// Corner radius in logical pixels. Leave null (the default) and the shape
  /// scales with the box — see [kRadiusRatio]. Override only for a surface that
  /// deliberately is not a person's avatar.
  final double? radius;

  /// Explicit placeholder tint. When null (the default) the tint is derived
  /// deterministically from [colorSeed] (falling back to [name]) over the
  /// Soko palette — so each person gets their own stable colour instead of
  /// the old always-yellow card, and keeps it on every surface.
  final Color? placeholderColor;

  /// Stable per-person key (pass the user id where available) driving the
  /// seeded placeholder tint. Falls back to [name] when null.
  final String? colorSeed;

  /// Initial-letter size as a fraction of [height]. Defaults to the profile
  /// avatar's 0.42; small list rows pass a lower value for a subtler initial.
  final double initialFontScale;

  /// Texture asset overlaid on the avatar. Defaults to the light paper grain.
  final String texture;

  /// How the [texture] composites over the avatar. Defaults to a plain 50%
  /// overlay ([BlendMode.srcOver]); Figma list rows pass [BlendMode.hardLight]
  /// with [textureOpacity] 1 for the printed grunge look.
  final BlendMode textureBlendMode;
  final double textureOpacity;

  /// How the photo composites into the avatar box. Defaults to [BoxFit.cover]
  /// (fill + crop) — right for user photos. The official Soko illustration
  /// passes [BoxFit.contain] so the whole artwork shows without cropping.
  final BoxFit fit;

  /// Corner radius as a fraction of the avatar's shortest side.
  ///
  /// Figma's follow-suggestion card is 80×80 with a 16-px radius — 20%. Held as
  /// a ratio rather than a constant so a 24-px list thumbnail and a 360-px
  /// full-screen viewer read as the SAME shape; a fixed 16 px would be a near
  /// circle at one end and a near square at the other.
  static const double kRadiusRatio = 0.20;

  /// The default light paper grain (Figma "Gstaik Textures").
  static const _defaultTexture = kSokoPaperGrainTexture;

  /// Curated card tints for the no-photo placeholder — the Soko surface
  /// family already used across shelves and personas.
  static const List<Color> _placeholderPalette = [
    AppColors.sokoPink,
    AppColors.sokoYellow,
    AppColors.sokoGreen,
    AppColors.sokoBlue,
    AppColors.sokoLilac,
  ];

  /// Deterministic palette pick for [seed] — same person, same colour, on
  /// every surface and across sessions/platforms (hand-rolled hash because
  /// `String.hashCode` isn't guaranteed stable across Dart embedders).
  /// With nothing to seed at all there's no identity to derive — settle on
  /// pink (the brand primary), not the old always-yellow card.
  static Color seededPlaceholderColor(String? seed) {
    if (seed == null || seed.isEmpty) return AppColors.sokoPink;
    var h = 0;
    for (final unit in seed.codeUnits) {
      h = (h * 31 + unit) & 0x7fffffff;
    }
    return _placeholderPalette[h % _placeholderPalette.length];
  }

  const TexturedAvatar({
    super.key,
    this.url,
    this.name,
    required this.width,
    required this.height,
    this.radius,
    this.placeholderColor,
    this.colorSeed,
    this.initialFontScale = 0.42,
    this.texture = _defaultTexture,
    this.textureBlendMode = BlendMode.srcOver,
    this.textureOpacity = 0.5,
    this.fit = BoxFit.cover,
  });

  @override
  Widget build(BuildContext context) {
    // No name at all → no letter (a clean tinted card), never a "?" — a
    // question mark reads as an error, not a person.
    final initial = (name != null && name!.isNotEmpty)
        ? name!.characters.first.toUpperCase()
        : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(
        radius ?? math.min(width, height) * kRadiusRatio,
      ),
      child: SizedBox(
        width: width,
        height: height,
        child: Stack(
          fit: StackFit.expand,
          children: [
            // Background fill — always drawn so it doubles as (a) the
            // initial-letter card when there's no photo, and (b) the letterbox
            // behind a [BoxFit.contain] photo. Without it, a contained photo
            // (the official Soko illustration) would leave see-through gaps that
            // read as "ghost margins" over whatever sits behind the avatar.
            Container(
              color:
                  placeholderColor ?? seededPlaceholderColor(colorSeed ?? name),
              alignment: Alignment.center,
              child: (url != null && url!.isNotEmpty || initial == null)
                  ? null
                  : Text(
                      initial,
                      style: Pt.name.copyWith(
                        fontSize: height * initialFontScale,
                      ),
                    ),
            ),
            if (url != null && url!.isNotEmpty)
              CachedImage(imageUrl: url!, fit: fit),
            // Texture overlay — plain 50% grain by default, or Hard-Light
            // grunge for the Figma list rows.
            IgnorePointer(
              child: BlendMask(
                blendMode: textureBlendMode,
                opacity: textureOpacity,
                child: Image(image: AssetImage(texture), fit: BoxFit.cover),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
