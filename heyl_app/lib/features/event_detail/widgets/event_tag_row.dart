import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/social_proof.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/soko_pop_in.dart';
import '../../../shared/widgets/soko_tag.dart';

/// Inline tag row for the event detail page (Figma `6181:5697`):
///   - Type tag    ("Evento")            — Soko/Blue, always.
///   - Saves tag   (bookmark + count)    — Soko/Red, hidden when count == 0.
///
/// Intentional divergence from Figma `6181:5699` (the rating tag): the
/// Figma comp shows a "★ 4.9 (176)" tag, but `EventDetailOut` carries no
/// `rating`/`rating_count` and BE is not adding them — design doc § 11.0
/// row 16 says FE hides the rating tag entirely on event pages.
///
/// All tags use [SokoTag] chrome (radius 2, padding 6/2, gap 6, Zalando Sans
/// Light 14 px Soko/Ink).
class EventTagRow extends StatelessWidget {
  final EventDetailResponse2 event;

  const EventTagRow({super.key, required this.event});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final saveCount = event.socialProof.saveCount;

    // NOTE (PROD-3379): the recurrence chip was intentionally REMOVED from this
    // event-level tag row. The phase is a per-OCCURRENCE property (where a
    // specific occurrence sits in the run), but this is a by-event header
    // anchored on only the next-future occurrence — ambiguous for a
    // multi-occurrence event whose "Datas" section lists many. The chip lives on
    // the map drawer cards (each card = one occurrence). A proper detail-page
    // treatment would annotate the "Datas" ranges per-occurrence (needs BE to
    // expose phase per occurrence).
    final tags = <Widget>[
      SokoTag(
        background: AppColors.sokoEventAccent,
        child: Text(l10n.eventDetailTagTypeEvent, style: SokoTag.textStyle),
      ),
    ];

    // The "Past event" state is NOT a tag here — a past event surfaces its
    // real date in the "Datas" section (the occurrence provider falls back to
    // past occurrences), and the zine card marks it with a subtle muted row.
    if (saveCount > 0) {
      // The saves tag is never in the seed shell — it arrives with the
      // hydrated detail, so pop it in over the already-painted type tag.
      tags.add(
        SokoPopIn(
          child: SokoTag(
            background: AppColors.sokoRed,
            leading: SvgPicture.asset(
              'assets/images/icons/detail/bookmark-tag.svg',
              width: 10,
              height: 10,
            ),
            child: Text('$saveCount', style: SokoTag.textStyle),
          ),
        ),
      );
    }

    return Wrap(spacing: 6, runSpacing: 6, children: tags);
  }
}
