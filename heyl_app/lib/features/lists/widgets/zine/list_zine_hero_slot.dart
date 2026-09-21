import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../shared/widgets/cached_image.dart';
import 'list_zine_hero_placeholder.dart';

/// The hero region of a zine cover or item page — wraps the photo (if any),
/// the prev/next zine tap-zones (cover only), and the bordered "Add photo"
/// button.
///
/// Layering inside the internal `Stack` (bottom → top, hits go top → bottom):
/// 1. **Photo or dim bg.** When the URL is non-empty, [CachedImage]
///    renders the photo (with the shared shimmer placeholder used across
///    discovery + detail components); if it fails, the `onError` callback
///    flips [_imageFailed] and we fall through to the dim bg. The photo
///    is wrapped in [IgnorePointer] so its render box doesn't absorb
///    taps — the tap-zones in layer 2 must catch them.
/// 2. **Prev/next tap-zones** — two opaque [GestureDetector]s splitting
///    the hero 50/50. Mounted only when the host passes [onPrev] /
///    [onNext] (cover-only behaviour after PROD-1738).
/// 3. **Bordered "Add photo" button** ([ListZineHeroPlaceholder]) — only
///    mounts when there's no photo to display. Uses opaque hit-testing so
///    taps inside its bounds are absorbed and never bubble to layer 2.
///    Taps on the dim bg outside the button still hit layer 2 → navigate.
///
/// During load (URL set, image not yet ready) the shimmer occupies the
/// hero — the placeholder is intentionally NOT shown so the user doesn't
/// briefly see "Add photo" before the real photo appears.
class ListZineHeroSlot extends StatefulWidget {
  /// The image URL to display, or null/empty when the item has no photo.
  final String? imageUrl;

  /// Called on a tap inside the LEFT half of the hero (placeholder bg
  /// outside the button counts as the hero, so this still fires there).
  final VoidCallback? onPrev;

  /// Called on a tap inside the RIGHT half of the hero.
  final VoidCallback? onNext;

  /// Called when the bordered "Add photo" button is tapped. Wire this to
  /// show a "coming soon" SnackBar — the BE doesn't support user uploads
  /// yet (see [PROD-1729]).
  final VoidCallback? onAddPhotoTap;

  const ListZineHeroSlot({
    super.key,
    required this.imageUrl,
    this.onPrev,
    this.onNext,
    this.onAddPhotoTap,
  });

  @override
  State<ListZineHeroSlot> createState() => _ListZineHeroSlotState();
}

class _ListZineHeroSlotState extends State<ListZineHeroSlot> {
  /// Set to true once [CachedNetworkImage]'s `errorWidget` builder has
  /// fired for the current URL — at that point we fall through to the
  /// placeholder. Reset when the URL changes (a new URL might succeed).
  bool _imageFailed = false;

  @override
  void didUpdateWidget(covariant ListZineHeroSlot oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageUrl != widget.imageUrl) {
      _imageFailed = false;
    }
  }

  bool get _hasUrl =>
      widget.imageUrl != null && widget.imageUrl!.isNotEmpty;

  bool get _showPlaceholder => !_hasUrl || _imageFailed;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // Layer 1 — photo or dim bg.
        if (_showPlaceholder)
          Container(color: AppColors.sokoInk.withValues(alpha: 0.04))
        else
          IgnorePointer(
            child: CachedImage(
              imageUrl: widget.imageUrl!,
              fit: BoxFit.cover,
              onError: () {
                if (mounted && !_imageFailed) {
                  setState(() => _imageFailed = true);
                }
              },
              // Don't render any error widget — when the load fails the
              // `onError` callback flips us to the placeholder branch on
              // the next build. Until then, transparency keeps the dim
              // bg + bordered button drawing cleanly.
              errorWidget: const SizedBox.expand(),
            ),
          ),

        // Layer 2 — prev/next tap-zones. Mounted only when the parent
        // wires at least one nav callback (cover-only after PROD-1738;
        // item pages no longer flip via the hero image).
        if (widget.onPrev != null || widget.onNext != null)
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onPrev,
                ),
              ),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: widget.onNext,
                ),
              ),
            ],
          ),

        // Layer 3 — bordered "Add photo" button (only when no photo).
        if (_showPlaceholder)
          Center(
            child: ListZineHeroPlaceholder(onTap: widget.onAddPhotoTap),
          ),
      ],
    );
  }
}
