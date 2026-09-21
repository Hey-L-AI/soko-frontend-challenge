import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/social_proof.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/soko_pop_in.dart';
import '../../../shared/widgets/soko_tag.dart';

/// Inline tags rendered under the name + description block:
///   - Kind tag    ("Sítio")            — Soko/Purple, always.
///   - Venue-type tag ("Restaurante chinês") — Soko/Lilac, hidden when the
///     backend resolves no primary type.
///   - Rating tag  (star + score)       — Soko/Yellow, hidden when no rating.
///   - Saves tag   (bookmark + count)   — Soko/Red,    hidden when count == 0.
///
/// Figma: `6144:4129` (venue page). All tags use [SokoTag] chrome (radius 2,
/// padding 6/2, gap 6, Zalando Sans Light 14 px Soko/Ink). Event detail
/// (PROD-1671) uses the same rating + saves chrome with its own kind tag
/// (Soko/Blue).
///
/// **Deliberate divergence from Figma `6144:4129`, which specifies three tags**
/// (PROD-3978, decided by Zé 2026-08-25): the venue-type label has no slot in
/// that comp, and the two alternatives were worse. Replacing the kind tag would
/// break the venue↔event page pairing (the event page keeps "Evento"); putting
/// the type in a subtitle line would sit it directly above `description_short`,
/// which says nearly the same thing in better words. The tag row is where
/// categorical metadata already lives, and a 4th chip never competes with the
/// blurb. Logged in `docs/ui/design-decisions.md`.
class VenueTagRow extends StatelessWidget {
  final VenueDetailResponse venue;

  const VenueTagRow({super.key, required this.venue});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final saveCount = venue.socialProof.saveCount;

    final tags = <Widget>[
      SokoTag(
        background: AppColors.sokoVenueAccent,
        child: Text(l10n.venueDetailTagTypeVenue, style: SokoTag.textStyle),
      ),
    ];

    // PROD-3978 / ADR-048 — the backend-resolved venue type, already in the
    // caller's locale. Rendered VERBATIM: no humanize, no title-case, no
    // slug→label mapping. Null means the venue genuinely has no usable primary
    // type, and is the only case that renders nothing (the key itself is always
    // present on `VenueDetailOut`).
    final venueType = venue.primaryTag?.trim();
    if (venueType != null && venueType.isNotEmpty) {
      tags.add(
        SokoTag(
          background: AppColors.sokoLilac,
          child: Text(venueType, style: SokoTag.textStyle),
        ),
      );
    }

    // Rating + saves arrive only with the hydrated detail (never in the seed
    // shell, which carries just the kind + venue-type chips), so they pop in
    // over the already-painted tags. Stagger them by appearance order so a
    // venue with both plays a quick one-two rather than a simultaneous flash.
    var popIndex = 0;
    SokoPopIn popTag(Widget tag) => SokoPopIn(
      startDelay: Duration(milliseconds: 70 * popIndex++),
      child: tag,
    );

    final rating = venue.rating;
    if (rating != null) {
      final ratingCount = venue.ratingCount;
      final label = ratingCount != null
          ? '${rating.toStringAsFixed(1)} ($ratingCount)'
          : rating.toStringAsFixed(1);
      tags.add(
        popTag(
          SokoTag(
            background: AppColors.sokoYellow,
            leading: SvgPicture.asset(
              'assets/images/icons/detail/star.svg',
              width: 10,
              height: 10,
            ),
            child: Text(label, style: SokoTag.textStyle),
          ),
        ),
      );
    }

    if (saveCount > 0) {
      tags.add(
        popTag(
          SokoTag(
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
