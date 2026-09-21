// PROD-4006 — the optional people-reactions row under an `event_hero` (D36).
//
// Figma `7304-23766`. It sits **below the card, on the page background** — not
// inside the poster — and appears only when the backend sends `reactions`. A
// null list means the row does not exist; an empty list means nobody, which is
// the same absence. D36 made this a variant of `event_hero` rather than a sixth
// block type precisely because it costs one optional row.
//
// This is the **one string on the whole card the client composes**. Everything
// else on a feed card arrives localized from the backend (D7); names and a
// count cannot, so it needs real ARB plurals.

import 'package:flutter/material.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../data/models/feed_home.dart';
import '../../../../../l10n/generated/l10n.dart';
import '../../../../profile/widgets/mutual_avatars_row.dart';

class FeedReactionsRow extends StatelessWidget {
  final List<FeedReaction> reactions;

  const FeedReactionsRow({super.key, required this.reactions});

  /// Names shown before the row spills into "+N". Two is what the frame shows
  /// and what `InterestedRow` already uses for the same shape of line.
  static const int maxNames = 2;

  /// Avatar diameter (`7304:23816`, 20 × 20 at x 0 / 16 / 32 — a 4 px overlap).
  static const double avatarSize = 20;

  /// Gap between the card and this row (card ends at 500, row starts at 512).
  static const double topGap = 12;

  /// Display name for one reaction: full name, else `@handle`, else nothing.
  ///
  /// An unnameable person is **dropped from the names but still counted** —
  /// they liked it, so omitting them entirely would understate the row, and
  /// rendering a blank would look broken.
  static String? displayName(FeedReaction r) {
    final name = r.displayName?.trim() ?? '';
    if (name.isNotEmpty) return name;
    final handle = r.handle?.trim() ?? '';
    return handle.isNotEmpty ? '@$handle' : null;
  }

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();

    final names = reactions
        .map(displayName)
        .whereType<String>()
        .take(maxNames)
        .toList(growable: false);

    // Nobody could be named — a row reading "Liked by  +3 people" is worse than
    // no row at all.
    if (names.isEmpty) return const SizedBox.shrink();

    final l10n = Lt.of(context);
    // The overflow count excludes the people already named, so "+1 person"
    // never appears beside the very person it is counting.
    final others = reactions.length - names.length;
    final label = others > 0
        ? l10n.feedReactionsLikedByWithOthers(names.join(', '), others)
        : l10n.feedReactionsLikedBy(names.join(', '));

    return Padding(
      padding: const EdgeInsets.only(top: topGap),
      child: MutualAvatarsRow(
        // Full people, so a reactor with no photo still shows a seeded initial
        // avatar instead of dropping out of the cluster.
        people: reactions
            .map(
              (r) => MutualAvatar(
                url: r.avatarUrl,
                name: r.displayName?.trim().isNotEmpty == true
                    ? r.displayName
                    : r.handle,
                seed: r.userId,
              ),
            )
            .toList(growable: false),
        totalCount: reactions.length,
        text: label,
        textStyle: const TextStyle(
          fontFamily: 'ZalandoSans',
          fontWeight: FontWeight.w300,
          fontSize: 14,
          height: 1.2,
          letterSpacing: -0.14,
          color: AppColors.sokoInk,
        ),
        size: avatarSize,
      ),
    );
  }
}
