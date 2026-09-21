import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../core/theme/app_colors.dart';
import '../../l10n/generated/l10n.dart';
import 'soko_tag.dart';

/// Tag-pill row used on chat event/venue cards. Mirrors the detail-page
/// chrome (`EventTagRow` / `VenueTagRow`):
///   - Type pill ("Evento" / "Sítio") — accent fill per kind.
///   - Saves pill (bookmark + count) — `sokoRed` fill, hidden when 0.
///
/// All pills use the shared [SokoTag] primitive. Pass `compact: true` to
/// shrink to 12 px text for tight card layouts.
class CardTagRow extends StatelessWidget {
  const CardTagRow({
    super.key,
    required this.itemType,
    required this.saveCount,
    this.compact = false,
  });

  /// Either `'event'` (renders the event accent + "Evento" label) or any
  /// other value (renders the venue accent + "Sítio"/"Place" label).
  final String itemType;
  final int saveCount;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isEvent = itemType == 'event';
    final textStyle = compact ? SokoTag.textStyleCompact : SokoTag.textStyle;
    final iconSize = compact ? 9.0 : 10.0;

    final tags = <Widget>[
      SokoTag(
        background: isEvent
            ? AppColors.sokoEventAccent
            : AppColors.sokoVenueAccent,
        child: Text(
          isEvent ? l10n.eventDetailTagTypeEvent : l10n.venueDetailTagTypeVenue,
          style: textStyle,
        ),
      ),
      if (saveCount > 0)
        SokoTag(
          background: AppColors.sokoRed,
          leading: SvgPicture.asset(
            'assets/images/icons/detail/bookmark-tag.svg',
            width: iconSize,
            height: iconSize,
          ),
          child: Text('$saveCount', style: textStyle),
        ),
    ];

    return Wrap(spacing: 6, runSpacing: 6, children: tags);
  }
}
