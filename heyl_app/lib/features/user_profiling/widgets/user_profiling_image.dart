import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';

/// Smart-loader for onboarding images. Detects the URL scheme and picks
/// the right loader:
/// * `asset:foo/bar.jpg` → `AssetImage('assets/foo/bar.jpg')` (bundled,
///   CORS-safe on web).
/// * Anything else (e.g. `https://...`) → `NetworkImage`.
///
/// This indirection supports bundled assets and backend/CDN image URLs with
/// the same rendering path.
class UserProfilingImage extends StatelessWidget {
  final String? url;
  final BoxFit fit;
  final Widget? fallback;

  const UserProfilingImage({
    super.key,
    required this.url,
    this.fit = BoxFit.cover,
    this.fallback,
  });

  @override
  Widget build(BuildContext context) {
    final src = url;
    if (src == null || src.isEmpty) {
      return fallback ?? Container(color: AppColors.muted);
    }
    if (src.startsWith('asset:')) {
      // Strip the scheme; pubspec assets are registered under "assets/...".
      final assetPath = 'assets/${src.substring('asset:'.length)}';
      return Image.asset(
        assetPath,
        fit: fit,
        errorBuilder: (_, __, ___) =>
            fallback ?? Container(color: AppColors.muted),
      );
    }
    return Image.network(
      src,
      fit: fit,
      errorBuilder: (_, __, ___) =>
          fallback ?? Container(color: AppColors.muted),
      loadingBuilder: (_, child, progress) {
        if (progress == null) return child;
        return Container(color: AppColors.muted);
      },
    );
  }
}
