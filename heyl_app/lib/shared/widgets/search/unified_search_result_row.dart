// Unified search — one result row: 56×56 thumbnail · title · subtitle ·
// (onboarding-only) thumbs-up like.
//
// Lifted from `_ResultRow` in `place_event_search_list.dart` and generalized to
// take a presentation-only [UnifiedSearchRow] instead of an `ItemSuggestion`, so
// every surface renders the identical row. The like button reads/writes the
// shared, id-keyed `signalControllerProvider` (same store the detail page and
// chat carousels use), so a like made here reflects everywhere and vice versa.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/entity_signal.dart';
import '../../../features/entity_signals/providers/signal_controller.dart';
import '../../../l10n/generated/l10n.dart';
import '../clickable.dart';
import '../soko_card_image.dart';
import '../soko_toggle_glyph.dart';
import 'unified_search_models.dart';

class UnifiedSearchResultRow extends ConsumerWidget {
  const UnifiedSearchResultRow({
    super.key,
    required this.row,
    required this.category,
    this.showLike = false,
    this.provenance,
    this.onLikeToggled,
  });

  final UnifiedSearchRow row;

  /// The section's category — drives the thumbnail placeholder kind unless the
  /// row overrides it via [UnifiedSearchRow.category].
  final SokoSearchCategory category;

  /// Whether the thumbs-up like is rendered. Onboarding passes true; every
  /// other surface leaves it false. A row with no [UnifiedSearchRow.signalTarget]
  /// never shows the thumb even when this is true (it can't be liked).
  final bool showLike;

  /// Surface-attribution label sent with each like write (see [SignalProvenance]).
  final String? provenance;

  /// Fired after a like toggle with the new (predicted) state, so the host can
  /// track picks-row membership / dismiss-on-like.
  final void Function(UnifiedSearchRow row, bool nowLiked)? onLikeToggled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = row.signalTarget;
    final canLike = showLike && target != null;

    SignalTaste taste = SignalTaste.none;
    if (canLike) {
      final key = (type: target.$1, id: target.$2);
      taste = ref.watch(signalControllerProvider(key)).signal.taste;
    }
    final liked = taste == SignalTaste.liked;

    Future<void> onToggleLike() async {
      if (target == null) return;
      final key = (type: target.$1, id: target.$2);
      // Announce the optimistic flip now, so the host's picks row moves in the
      // same frame as the thumb. Then correct it: the server owns the toggle
      // and may settle somewhere else, or the write may fail outright.
      final predicted = taste != SignalTaste.liked;
      onLikeToggled?.call(row, predicted);
      await ref
          .read(signalControllerProvider(key).notifier)
          .apply(SignalAction.like, provenance: provenance);
      final SignalControllerState settled;
      try {
        settled = ref.read(signalControllerProvider(key));
      } catch (_) {
        return; // row unmounted while the write was in flight
      }
      // A newer tap is still converging — its own call will report the result.
      if (settled.mutating) return;
      // Only correct when the server disagreed with the prediction. Re-sending
      // an unchanged value would require every host to be idempotent, which is
      // an invisible contract to break.
      final confirmed = settled.signal.taste == SignalTaste.liked;
      if (confirmed != predicted) onLikeToggled?.call(row, confirmed);
    }

    // Clickable (not a bare GestureDetector) so the whole row shows the pointer
    // cursor on web hover; it defaults to opaque hit-testing like before.
    return Clickable(
      onTap: row.onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SokoCardImage(
              imageUrl: row.imageUrl,
              seed: row.seed ?? row.rowKey,
              kind: (row.category ?? category).thumbKind,
              width: 56,
              height: 56,
              // People read as round avatars; every other category is a
              // square-ish thumbnail.
              borderRadius: BorderRadius.circular(
                (row.category ?? category) == SokoSearchCategory.people
                    ? 28
                    : 8,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    row.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: AppTheme.body(
                      fontSize: 17,
                      fontWeight: FontWeight.w500,
                      color: AppColors.sokoInk,
                    ),
                  ),
                  if ((row.subtitle ?? '').isNotEmpty) ...[
                    const SizedBox(height: 2),
                    Text(
                      row.subtitle!,
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
            if (canLike) ...[
              const SizedBox(width: 12),
              Clickable(
                onTap: onToggleLike,
                child: Semantics(
                  button: true,
                  selected: liked,
                  label: Lt.of(context).signalLike,
                  child: Container(
                    width: 40,
                    height: 40,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: AppColors.sokoInk.withValues(alpha: 0.06),
                    ),
                    child: SvgPicture.asset(
                      liked
                          ? SokoToggleGlyph.thumbUpFill
                          : SokoToggleGlyph.thumbUpOutline,
                      width: 16,
                      height: 16,
                      colorFilter: liked
                          ? null
                          : const ColorFilter.mode(
                              AppColors.sokoInk,
                              BlendMode.srcIn,
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
