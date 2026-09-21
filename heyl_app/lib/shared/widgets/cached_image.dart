import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:shimmer/shimmer.dart';

import '../../core/theme/app_colors.dart';

/// A reusable cached network image widget with shimmer loading placeholder.
///
/// Features:
/// - Disk caching on mobile (memory cache on web)
/// - Shimmer skeleton loading animation
/// - Error fallback with customizable placeholder
/// - Consistent styling across the app
class CachedImage extends StatelessWidget {
  /// The URL of the image to load
  final String imageUrl;

  /// Width of the image container
  final double? width;

  /// Height of the image container
  final double? height;

  /// How the image should fit in its container
  final BoxFit fit;

  /// Border radius for the image container
  final BorderRadius? borderRadius;

  /// Optional custom placeholder widget (uses shimmer by default)
  final Widget? placeholder;

  /// Optional custom error widget. When null and [onError] is provided,
  /// the default broken-image fallback is suppressed (a transparent
  /// `SizedBox.expand` is rendered) so the caller can paint its own
  /// error UI on top — useful for parents that already overlay a
  /// placeholder via a `Stack`.
  final Widget? errorWidget;

  /// Icon to show in error state (default: place icon).
  final IconData errorIcon;

  /// Paint the photo instantly with no fade when its bytes are already warm
  /// (memory cache) — for a tile that is a **Hero-flight destination** (e.g.
  /// the zine cover the Library thumbnail flies into). Mirrors
  /// [SokoCardImage.instant]: `CachedNetworkImage`'s ~500 ms placeholder→image
  /// fade otherwise re-runs on landing and drops the flown poster back to its
  /// backdrop for a frame ("snap at the finish"). A genuinely cold first frame
  /// still fades in. When set, [placeholder] is unused (the backdrop shows
  /// through until the first frame) and [errorWidget] (or a transparent box)
  /// is the failure UI.
  final bool instant;

  /// Optional callback fired (post-frame) the first time
  /// [CachedNetworkImage] reports an `errorWidget` build. Lets parents
  /// react to load failure (e.g., flip a state flag to surface a
  /// custom placeholder) without losing the shared shimmer + cache
  /// behavior. Suppresses the default broken-image fallback when
  /// [errorWidget] is null.
  final VoidCallback? onError;

  /// Optional callback fired (post-frame) the first time the photo has
  /// decoded and painted — the default path fires from `imageBuilder`, the
  /// [instant] path from the first non-null `frameBuilder` frame. Lets a parent
  /// defer an overlay (e.g. the timing chip's stamp-in) until the image lands,
  /// so a sticker never appears over a blank tile.
  final VoidCallback? onLoaded;

  const CachedImage({
    super.key,
    required this.imageUrl,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius,
    this.placeholder,
    this.errorWidget,
    this.errorIcon = Icons.image_outlined,
    this.onError,
    this.onLoaded,
    this.instant = false,
  });

  /// Post-frame one-shot for [onLoaded], so parents can `setState` safely.
  void _notifyLoaded() {
    final cb = onLoaded;
    if (cb == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => cb());
  }

  @override
  Widget build(BuildContext context) {
    if (instant) {
      // Hero-landing path: the EXACT same `Image(CachedNetworkImageProvider,
      // gaplessPlayback)` — with no fade — the flight shuttle paints, so the
      // handoff is pixel-continuous. No `frameBuilder` fade on purpose: on web
      // `wasSynchronouslyLoaded` is almost always false even for a warm image,
      // so a fade there re-fades the just-flown poster (the "snap at the
      // finish"). Warm → paints on frame 1; cold → paints when decoded (the
      // caller's backdrop shows through until then); failure → [errorWidget].
      Widget instantImage = Image(
        image: CachedNetworkImageProvider(imageUrl),
        width: width,
        height: height,
        fit: fit,
        gaplessPlayback: true,
        frameBuilder: (context, child, frame, wasSyncLoaded) {
          if (wasSyncLoaded || frame != null) _notifyLoaded();
          return child;
        },
        errorBuilder: (_, __, ___) => errorWidget ?? const SizedBox.expand(),
      );
      if (borderRadius != null) {
        instantImage = ClipRRect(
          borderRadius: borderRadius!,
          child: instantImage,
        );
      }
      return instantImage;
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final shimmerBaseColor = isDark
        ? AppColors.surfaceDark
        : AppColors.surfaceVariant;
    final shimmerHighlightColor = isDark
        ? AppColors.surfaceVariant.withValues(alpha: 0.5)
        : Colors.white.withValues(alpha: 0.8);
    final errorBgColor = isDark
        ? AppColors.surfaceDark
        : AppColors.surfaceVariant;
    final errorIconColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;

    Widget image = CachedNetworkImage(
      imageUrl: imageUrl,
      width: width,
      height: height,
      fit: fit,
      placeholder: (context, url) =>
          placeholder ?? _buildShimmer(shimmerBaseColor, shimmerHighlightColor),
      imageBuilder: onLoaded == null
          ? null
          : (context, imageProvider) {
              // `imageBuilder` fires only once the image has resolved — the
              // clean "loaded" signal. We re-render the same image so the
              // default fit/size is preserved.
              _notifyLoaded();
              return Image(
                image: imageProvider,
                width: width,
                height: height,
                fit: fit,
              );
            },
      errorWidget: (context, url, error) {
        if (onError != null) {
          // Schedule notification post-frame so parents can setState
          // without mutating during this build.
          WidgetsBinding.instance.addPostFrameCallback((_) => onError!());
        }
        if (errorWidget != null) return errorWidget!;
        // When the caller wants to paint its own error UI (onError set,
        // errorWidget null), suppress the default broken-image fallback.
        if (onError != null) return const SizedBox.expand();
        return _buildError(errorBgColor, errorIconColor);
      },
    );

    if (borderRadius != null) {
      image = ClipRRect(borderRadius: borderRadius!, child: image);
    }

    return image;
  }

  Widget _buildShimmer(Color baseColor, Color highlightColor) {
    return Shimmer.fromColors(
      baseColor: baseColor,
      highlightColor: highlightColor,
      child: Container(width: width, height: height, color: baseColor),
    );
  }

  Widget _buildError(Color bgColor, Color iconColor) {
    final iconSize = (width != null && height != null)
        ? (width! < height! ? width! : height!) * 0.4
        : 24.0;

    return Container(
      width: width,
      height: height,
      color: bgColor,
      child: Center(
        child: Icon(
          errorIcon,
          color: iconColor,
          size: iconSize.clamp(16.0, 48.0),
        ),
      ),
    );
  }
}

/// A square cached image optimized for thumbnails
class CachedThumbnail extends StatelessWidget {
  final String imageUrl;
  final double size;
  final BorderRadius? borderRadius;
  final IconData errorIcon;

  const CachedThumbnail({
    super.key,
    required this.imageUrl,
    this.size = 56,
    this.borderRadius,
    this.errorIcon = Icons.place,
  });

  @override
  Widget build(BuildContext context) {
    return CachedImage(
      imageUrl: imageUrl,
      width: size,
      height: size,
      borderRadius: borderRadius ?? BorderRadius.circular(8),
      errorIcon: errorIcon,
    );
  }
}
