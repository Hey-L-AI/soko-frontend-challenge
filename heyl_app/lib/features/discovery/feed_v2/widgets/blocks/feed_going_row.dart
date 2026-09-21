// The "Dos teus amigos" bundle's per-row social line (Figma `7740-46799`).
//
// It sits where a normal bundle event row draws its venue line, and swaps it
// for friends' interest: an overlapping avatar cluster and a line like
// "John is interested", "Denise and Louise are interested", or "Emily + 3
// people interested". The people + count arrive on the page's `going` side-map;
// the **wording is the client's** — names and a count cannot be localized on
// the backend (same reasoning as `FeedReactionsRow`, D7), so this is one of the
// few strings the app composes itself, with real ARB plurals.
//
// The copy is "interested", not "going": the underlying signal is a friend's
// like OR save on the event (interest), never an RSVP — which is also why the
// data reuses the `FeedReaction` shape `event_hero` already carries and this
// widget reuses the same `MutualAvatarsRow`.

import 'package:flutter/material.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../core/theme/app_theme.dart';
import '../../../../../data/models/feed_home.dart';
import '../../../../../l10n/generated/l10n.dart';
import '../../../../profile/widgets/mutual_avatars_row.dart';

class FeedGoingRow extends StatelessWidget {
  /// The viewer's friends interested in this event (cap 3 from the backend).
  final List<FeedReaction> people;

  /// The true friends-interested total, `>= people.length`. Drives both the
  /// "+N" avatar overflow badge and the "+N pessoas" copy. Falls back to
  /// [people] length when the backend omitted it.
  final int? totalCount;

  const FeedGoingRow({super.key, required this.people, this.totalCount});

  /// Avatar diameter — the frame's `7740:46809` is 20 × 20, same as
  /// [FeedReactionsRow].
  static const double avatarSize = 20;

  /// Display name for one person: full name, else `@handle`, else nothing.
  /// An unnameable person is dropped from the names **but still counted** — the
  /// same rule [FeedReactionsRow.displayName] uses, so the count never
  /// understates the group even when a name is missing.
  static String? displayName(FeedReaction r) {
    final name = r.displayName?.trim() ?? '';
    if (name.isNotEmpty) return name;
    final handle = r.handle?.trim() ?? '';
    return handle.isNotEmpty ? '@$handle' : null;
  }

  /// Whether at least one person can be named — the row's gate for choosing the
  /// going line over the venue line. A preview of only unnameable people
  /// produces no line here, so the caller should fall back rather than draw an
  /// empty third slot.
  static bool hasNameable(Iterable<FeedReaction> people) =>
      people.any((p) => displayName(p) != null);

  /// Composes the line the four Figma examples encode, from the nameable names
  /// and the true total:
  ///   • 1        → "{name} is interested"
  ///   • 2 (named)→ "{a} and {b} are interested"
  ///   • ≥3, or 2 with only one nameable → "{name} + {N} people interested"
  ///
  /// Returns null when nobody can be named — a row of a bare "+N pessoas vão"
  /// with no name reads as broken, so it is better not drawn (the widget then
  /// falls back to the venue line).
  static String? label(Lt l10n, List<String> names, int total) {
    if (names.isEmpty) return null;
    // Guard bad data: the total must cover the people we can already name.
    final count = total < names.length ? names.length : total;

    if (count <= 1) return l10n.feedInterestedOne(names.first);
    if (count == 2 && names.length >= 2) {
      return l10n.feedInterestedTwo(names[0], names[1]);
    }
    // One name leads, everyone else folds into the "+N pessoas" tail.
    return l10n.feedInterestedWithOthers(names.first, count - 1);
  }

  @override
  Widget build(BuildContext context) {
    if (people.isEmpty) return const SizedBox.shrink();

    final l10n = Lt.of(context);
    final names = people
        .map(displayName)
        .whereType<String>()
        .toList(growable: false);

    final total = (totalCount == null || totalCount! < people.length)
        ? people.length
        : totalCount!;

    final text = label(l10n, names, total);
    if (text == null) return const SizedBox.shrink();

    return MutualAvatarsRow(
      // Pass full people (not just non-empty URLs) so a friend with no photo
      // still draws a seeded initial avatar rather than vanishing from the
      // cluster while their name stays in the line.
      people: people
          .map(
            (p) => MutualAvatar(
              url: p.avatarUrl,
              name: p.displayName?.trim().isNotEmpty == true
                  ? p.displayName
                  : p.handle,
              seed: p.userId,
            ),
          )
          .toList(growable: false),
      totalCount: total,
      text: text,
      // Match the sibling meta lines exactly (`FeedMetaLine`): `Mobile/B2 Reg`,
      // leading pinned to 1 — the bundle row is a fixed 80 px box and an
      // unpinned 14 px line would push the column past it.
      textStyle: AppTheme.body(
        fontSize: 14,
        fontWeight: FontWeight.w300,
        color: AppColors.sokoInk,
        height: 1,
      ),
      size: avatarSize,
    );
  }
}
