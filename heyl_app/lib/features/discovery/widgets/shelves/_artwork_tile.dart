import 'package:flutter/material.dart';

import '../../../../shared/widgets/soko_card_image.dart';

/// Design-system primitive for Discovery shelf cards: a clip-rounded
/// artwork tile that renders a venue/event photo over a deterministic
/// Soko brand-colour floor + texture (via [SokoCardImage]). When the
/// photo is absent or fails to load, the brand floor stays — never a
/// broken-image icon.
class ArtworkTile extends StatelessWidget {
  final String? imageUrl;
  final double width;
  final double height;
  final double borderRadius;

  /// Deterministic texture seed — pass the entity id. Defaults to empty
  /// (still stable) for callers that render lists/recipes and never reach
  /// this tile with a real entity.
  final String seed;

  /// Drives the fallback floor colour (venue blue / event green / neutral).
  final SokoEntityKind kind;

  const ArtworkTile({
    super.key,
    required this.imageUrl,
    required this.width,
    required this.height,
    this.borderRadius = 5,
    this.seed = '',
    this.kind = SokoEntityKind.neutral,
  });

  @override
  Widget build(BuildContext context) {
    return SokoCardImage(
      imageUrl: imageUrl,
      seed: seed,
      kind: kind,
      width: width,
      height: height,
      borderRadius: BorderRadius.circular(borderRadius),
    );
  }
}
