import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/config/environment.dart';
import '../../../l10n/generated/l10n.dart';
import '../providers/public_profile_providers.dart';
import '../utils/profile_style.dart';
import 'textured_avatar.dart';

/// Compact Soko-account row used inside the `profile_v1` feature spotlight:
/// avatar + "Soko / @soko" + a presentational "Following" pill, with a
/// "you follow each other" caption below. Illustrative only — the pill is not
/// interactive (the spotlight teaches, it doesn't act).
///
/// Reads the official Soko profile ([EnvironmentConfig.sokoHandle]) for the
/// live avatar + name, falling back to "Soko" / "@soko" + an initial avatar
/// while it loads or if the fetch fails, so the card always renders.
class SokoMutualFollowCard extends ConsumerWidget {
  const SokoMutualFollowCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final profile = ref
        .watch(publicProfileProvider(EnvironmentConfig.sokoHandle))
        .valueOrNull;
    final name = (profile?.fullName?.isNotEmpty ?? false)
        ? profile!.fullName!
        : 'Soko';
    final handle = '@${profile?.handle ?? EnvironmentConfig.sokoHandle}';

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: pInk8),
          ),
          child: Row(
            children: [
              TexturedAvatar(
                url: profile?.avatarUrl,
                name: name,
                width: 40,
                height: 40,
                // The Soko illustration is on a white background — contain +
                // white card shows it whole, mirroring the profile avatar.
                fit: BoxFit.contain,
                placeholderColor: Colors.white,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(name, style: Pt.b1, maxLines: 1),
                    Text(
                      handle,
                      style: Pt.b2.copyWith(color: pInk50),
                      maxLines: 1,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // Presentational "Following" pill (matches the follow button's
              // following state; not tappable here).
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: pInk8,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(l10n.listActionFollowing, style: Pt.b2),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            l10n.spotlightProfileV1MutualFollow,
            style: Pt.b2.copyWith(color: pInk50),
          ),
        ),
      ],
    );
  }
}
