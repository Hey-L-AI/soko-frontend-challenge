import 'dart:ui';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';

/// Shared image-with-text-overlay template chrome used by the Discovery
/// Daily Drop and Weekly Bundle sections (PROD-1518).
///
/// Layout (per `docs/ui/figma-cache/screens/discovery/daily-drop.md` and
/// `weekly-bundle.md`, node `3932:1948` / `3932:1979`):
/// - 399 × 213 cover image, 6px corner radius, `BoxFit.cover`.
/// - 8.7px gap, then a caption block with bold title + tonal inline date
///   suffix, followed by a 4.6px gap and a muted byline.
///
/// Overlays (date label, "Soko" wordmark, year, "DAILY DROP" / "Weekly
/// Bundle" display lockup) are baked into the cover asset by the design
/// pipeline — the client only renders one rounded image. No client-side
/// compositing, no gradient overlay.
class DiscoveryImageTemplateCard extends StatelessWidget {
  /// URL of a network cover image. Used by Daily Drop. Ignored when
  /// [cover] is supplied (Weekly Bundle paints its own composed cover
  /// with no network photo).
  final String? imageUrl;

  /// Optional fully-composed cover widget that replaces the network
  /// image. Sized to the 399 × 213 frame. Used by Weekly Bundle, which
  /// paints a solid lime background + dynamic thumbnails + chrome
  /// directly rather than serving a single composite photo.
  final Widget? cover;

  final String titleBold;
  final String titleLight;
  final String byline;
  final VoidCallback? onTap;

  /// Optional overlay rendered on top of the cover, sized to the
  /// 399 × 213 frame. Used by the Daily Drop section to layer the dynamic
  /// date / Soko logo / "DAILY DROP" template over the BE-served cover.
  final Widget? imageOverlay;

  /// PROD-1979 — when `true`, only the cover photo layer (the
  /// `CachedNetworkImage` / [cover] widget) renders blurred. The
  /// [imageOverlay] on top, plus the title row and byline below the
  /// frame, stay fully crisp. Used by the Daily Drop section for
  /// guests: the layout + template chrome stays readable while the
  /// actual recommendation photo is gated.
  final bool blurImage;

  const DiscoveryImageTemplateCard({
    super.key,
    this.imageUrl,
    this.cover,
    required this.titleBold,
    required this.titleLight,
    required this.byline,
    this.onTap,
    this.imageOverlay,
    this.blurImage = false,
  }) : assert(
         imageUrl != null || cover != null,
         'DiscoveryImageTemplateCard requires either imageUrl or cover.',
       );

  /// Skeleton placeholder rendered while the section's data is loading.
  /// Matches the final card's outer bounds so shelves below don't shift
  /// when the section resolves.
  static Widget skeleton({Key? key}) {
    return const _ImageTemplateSkeleton();
  }

  /// The photo layer — either the caller-supplied [cover] widget, or a
  /// `CachedNetworkImage` built from [imageUrl]. Factored out so the
  /// build can optionally wrap it in `ImageFiltered` for the blurred
  /// variant without duplicating the placeholder / error chrome.
  ///
  /// Placeholder / errorWidget paint a Soko-pink soft gradient (not a
  /// flat near-transparent fill) so that when the network image is
  /// loading or fails — common in guest sessions where the BE-returned
  /// URL may not resolve — the [imageOverlay] still has something
  /// visibly "content-like" beneath it instead of reading as a blank
  /// card. PROD-1979.
  Widget _coverLayer(Color inkColor) {
    if (cover != null) return cover!;
    return CachedNetworkImage(
      imageUrl: imageUrl!,
      fit: BoxFit.cover,
      placeholder: (_, __) => const _PhotoFallback(),
      errorWidget: (_, url, error) {
        debugPrint(
          '[DiscoveryImageTemplateCard] image load failed → $url ($error)',
        );
        return const _PhotoFallback();
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 399 / 213,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // Cover photo layer — optionally blurred (PROD-1979
                    // guest treatment). The overlay above stays crisp.
                    // σ=10 is a heavy blur: the photo silhouette is
                    // visible but no detail leaks, even under the
                    // overlay's 40 % black tint.
                    if (blurImage)
                      ImageFiltered(
                        imageFilter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                        child: _coverLayer(inkColor),
                      )
                    else
                      _coverLayer(inkColor),
                    if (imageOverlay != null) imageOverlay!,
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8.687),
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: titleBold,
                    style: AppTheme.body(
                      fontSize: 18,
                      fontWeight: FontWeight.w500,
                      color: inkColor,
                      height: 1.0,
                    ).copyWith(letterSpacing: -0.36),
                  ),
                  TextSpan(
                    text: titleLight,
                    style: AppTheme.body(
                      fontSize: 18,
                      fontWeight: FontWeight.w300,
                      color: AppColors.sokoShade3,
                      height: 1.0,
                    ).copyWith(letterSpacing: -0.36),
                  ),
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 4.633),
            Text(
              byline,
              style: AppTheme.body(
                fontSize: 14,
                fontWeight: FontWeight.w300,
                color: AppColors.sokoShade3,
                height: 1.2,
              ).copyWith(letterSpacing: -0.14),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

/// Soko-pink gradient stand-in painted when the network image is
/// loading or fails. Sits behind the `imageOverlay` so the card still
/// reads as "content present, gated" instead of a blank slot.
class _PhotoFallback extends StatelessWidget {
  const _PhotoFallback();

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [AppColors.sokoLight2, AppColors.sokoPink],
        ),
      ),
    );
  }
}

/// Loading-state placeholder matching the real card's outer bounds.
/// Holds the layout while the section's provider resolves so shelves
/// below don't reflow when data arrives.
class _ImageTemplateSkeleton extends StatelessWidget {
  const _ImageTemplateSkeleton();

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;
    final block = inkColor.withValues(alpha: 0.06);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AspectRatio(
          aspectRatio: 399 / 213,
          child: Container(
            decoration: BoxDecoration(
              color: block,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
        ),
        const SizedBox(height: 8.687),
        Container(
          height: 18,
          width: 220,
          decoration: BoxDecoration(
            color: block,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(height: 4.633 + 4),
        Container(
          height: 14,
          width: 96,
          decoration: BoxDecoration(
            color: block,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      ],
    );
  }
}
