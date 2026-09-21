import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import 'cached_image.dart';

/// The canonical "face + name" pair: a small round avatar glued to a
/// single-line label. Use it anywhere a person is credited inline —
/// curator lines, follower social proof, shared-by attributions — so the
/// avatar always sits next to the name it belongs to.
///
/// A null/empty [avatarUrl] renders a person-glyph disc so the pair keeps
/// its shape; the label ellipsizes when the parent constrains it.
class AvatarNameLabel extends StatelessWidget {
  const AvatarNameLabel({
    super.key,
    required this.label,
    this.avatarUrl,
    this.style,
    this.avatarSize = 20,
    this.gap = 6,
  });

  final String label;
  final String? avatarUrl;
  final TextStyle? style;
  final double avatarSize;
  final double gap;

  @override
  Widget build(BuildContext context) {
    final url = avatarUrl?.trim() ?? '';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (url.isNotEmpty)
          ClipOval(
            child: CachedImage(
              imageUrl: url,
              width: avatarSize,
              height: avatarSize,
              fit: BoxFit.cover,
              errorIcon: Icons.person,
            ),
          )
        else
          Container(
            width: avatarSize,
            height: avatarSize,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppColors.sokoInk.withValues(alpha: 0.06),
            ),
            child: Icon(
              Icons.person,
              size: avatarSize * 0.6,
              color: AppColors.sokoShade1,
            ),
          ),
        SizedBox(width: gap),
        Flexible(
          child: Text(
            label,
            style: style,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }
}
