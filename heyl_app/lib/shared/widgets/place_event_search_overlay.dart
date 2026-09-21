import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import 'clickable.dart';
import 'search/unified_search_overlay.dart' show unifiedSearchHeroFlightShuttle;

/// Collapsed, tap-only entry that mirrors the search field's look
/// (`sokoShade5` fill, 6 px radius, search icon + hint) and opens the focused
/// search overlay on tap. Sits inline in a transcript/list where a live text
/// field would fight the surrounding scroll.
///
/// The overlay itself is the shared [openUnifiedSearchOverlay] — onboarding
/// wires its like / close-on-like / detail add-ons there.
class PlaceEventSearchTapField extends StatelessWidget {
  const PlaceEventSearchTapField({
    super.key,
    required this.hintText,
    required this.onTap,
    this.heroTag,
  });

  final String hintText;
  final VoidCallback onTap;

  /// When set (matching the overlay's `inputHeroTag`), this pill flies up into
  /// the opened search field as a shared element instead of the overlay just
  /// fading in over it.
  final Object? heroTag;

  @override
  Widget build(BuildContext context) {
    final field = Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AppColors.sokoShade5,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, size: 20, color: AppColors.sokoInk),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hintText,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'Zalando Sans',
                fontSize: 14,
                fontWeight: FontWeight.w300,
                height: 1.2,
                letterSpacing: -0.14,
                color: AppColors.sokoInk.withValues(alpha: 0.30),
              ),
            ),
          ),
        ],
      ),
    );
    final tag = heroTag;
    return Clickable(
      onTap: onTap,
      child: tag == null
          ? field
          : Hero(
              tag: tag,
              flightShuttleBuilder: unifiedSearchHeroFlightShuttle,
              child: field,
            ),
    );
  }
}
