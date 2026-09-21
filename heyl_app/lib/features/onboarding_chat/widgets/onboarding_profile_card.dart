import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../providers/auth_provider.dart' show currentUserProvider;
import '../../profile/providers/public_profile_providers.dart';
import '../../profile/widgets/textured_avatar.dart';

/// The onboarding profile card (Figma `7285:24113`): the user's freshly-created
/// profile — textured avatar + display name + @handle — bracketed by a hairline
/// divider like the other step cards. Reads the current user for name/handle and
/// the by-handle public profile for the avatar photo (once one is set).
class OnboardingProfileCard extends ConsumerWidget {
  const OnboardingProfileCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    if (user == null) return const SizedBox.shrink();

    final name = user.displayName;
    final handle = user.handle;
    final avatarUrl = (handle != null && handle.isNotEmpty)
        ? ref.watch(publicProfileProvider(handle)).valueOrNull?.avatarUrl
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1, thickness: 1, color: AppColors.sokoInk8),
        const SizedBox(height: 16),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Square, like every avatar in the app — the shape comes from
            // TexturedAvatar, not from this card.
            TexturedAvatar(
              url: avatarUrl,
              name: name,
              colorSeed: user.userId,
              width: 96,
              height: 96,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    name,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.body(
                      fontSize: 24,
                      fontWeight: FontWeight.w600,
                      color: AppColors.sokoInk,
                    ),
                  ),
                  if (handle != null && handle.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      '@$handle',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: AppTheme.body(
                        fontSize: 14,
                        color: AppColors.sokoShade3,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }
}
