import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/entity_signal.dart';
import '../../../data/models/social_proof.dart';
import '../../../l10n/generated/l10n.dart';
import '../../profile/widgets/mutual_avatars_row.dart';

/// "A, B e mais N têm interesse" on a venue/event detail page.
///
/// Replaces the separate "Liked by" row: one line covering everyone who liked
/// OR saved the entity, tapping through to the full paginated roster on
/// [InterestedScreen]. "Partilhado por" stays its own row above — it answers
/// who *created* the item, a different question.
///
/// No leading glyph, unlike its single-signal siblings ("Liked by" carried a
/// thumbs-up, the zines' "Seguido por" a bookmark): this line mixes both
/// signals, so any one glyph would misdescribe half the people in it.
class InterestedRow extends ConsumerWidget {
  /// Head of the roster, from `interested_preview`.
  final List<InterestedUser> preview;

  /// Distinct people who liked or saved, from `interested_count` —
  /// authoritative, and larger than [preview] whenever the sheet has more.
  final int totalCount;

  final SignalEntityType entityType;
  final String entityId;

  const InterestedRow({
    super.key,
    required this.preview,
    required this.totalCount,
    required this.entityType,
    required this.entityId,
  });

  /// Display name: prefer the full name, fall back to `@handle`, empty if
  /// neither — an unnameable person is dropped rather than rendered blank.
  static String _displayName(InterestedUser u) {
    final fullName = u.user.fullName?.trim() ?? '';
    if (fullName.isNotEmpty) return fullName;
    final handle = u.user.handle?.trim() ?? '';
    return handle.isNotEmpty ? '@$handle' : '';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (preview.isEmpty || totalCount <= 0) {
      return const SizedBox.shrink();
    }

    final names = preview
        .map(_displayName)
        .where((n) => n.isNotEmpty)
        .take(2)
        .toList();
    if (names.isEmpty) return const SizedBox.shrink();

    final l10n = Lt.of(context);
    // The label counts the people the names don't already cover, so "e mais 1
    // pessoa" never appears next to a name that IS that person.
    final others = totalCount - names.length;
    final label = others > 0
        ? l10n.interestedByWithOthers(names.join(', '), others)
        : l10n.interestedByNames(names.join(', '));

    // The gap lives INSIDE the row, not as a sibling `SizedBox` in the detail
    // body: this widget self-hides (flag off, nobody interested yet), and a
    // sibling spacer would leave a hole behind when it does.
    return Padding(
      padding: const EdgeInsets.only(top: 14),
      child: Semantics(
        button: true,
        label: label,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // The count rides in `extra` so the screen's header is right on
            // its first frame, before the first page lands.
            onTap: () => context.push(
              entityType == SignalEntityType.event
                  ? AppRoutes.eventInterestedPath(entityId)
                  : AppRoutes.venueInterestedPath(entityId),
              extra: totalCount,
            ),
            child: MutualAvatarsRow(
              avatars: preview
                  .map((u) => u.user.avatarUrl?.trim() ?? '')
                  .where((u) => u.isNotEmpty)
                  .toList(),
              totalCount: totalCount,
              text: label,
              textStyle: const TextStyle(
                fontFamily: 'ZalandoSans',
                fontWeight: FontWeight.w300,
                fontSize: 14,
                height: 1.2,
                letterSpacing: -0.14,
                color: AppColors.sokoShade1,
              ),
              size: 26,
            ),
          ),
        ),
      ),
    );
  }
}
