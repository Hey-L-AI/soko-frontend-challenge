import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../features/profile/widgets/textured_avatar.dart'
    show TexturedAvatar;
import 'cached_image.dart';

/// Small round person marker (the "bolinha") shown next to a curator /
/// username: their photo when one exists, else their initial on their seeded
/// colour — the same deterministic tint [TexturedAvatar] gives that person on
/// every avatar surface, so the dot still reads as "them" before they upload
/// a photo. Renders nothing when there's neither a photo nor a name.
class PersonDot extends StatelessWidget {
  final String? url;
  final String? name;

  /// Stable per-person key (user id) for the fallback colour; falls back to
  /// [name] inside the seeding function.
  final String? seed;
  final double size;

  const PersonDot({super.key, this.url, this.name, this.seed, this.size = 14});

  @override
  Widget build(BuildContext context) {
    if (url != null && url!.isNotEmpty) {
      return CachedThumbnail(
        imageUrl: url!,
        size: size,
        borderRadius: BorderRadius.circular(size / 2),
        errorIcon: Icons.person,
      );
    }
    if (name == null || name!.isEmpty) return const SizedBox.shrink();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: TexturedAvatar.seededPlaceholderColor(seed ?? name),
        shape: BoxShape.circle,
      ),
      child: Text(
        name!.characters.first.toUpperCase(),
        style: TextStyle(
          color: AppColors.sokoInk,
          fontSize: size * 0.64,
          fontWeight: FontWeight.w600,
          height: 1.0,
        ),
      ),
    );
  }
}
