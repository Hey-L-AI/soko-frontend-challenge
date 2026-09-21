import 'package:flutter/material.dart';

import 'package:heyl_app/core/theme/app_colors.dart';

/// PROD-2785 — Spotify-spirit channel tile used in [SokoShareSheet]'s
/// bottom-row channel grid. Circular 56 px icon button + 12 px label
/// underneath. Tap → [onTap]; shows a circular spinner while [busy].
///
/// Background color [iconBackground] defaults to `AppColors.sokoShade5`;
/// brand channels pass their own (`#25D366` for WhatsApp, IG-pink gradient
/// for Story, etc. — gradient handled by [iconBackgroundGradient]).
class ShareChannelTile extends StatelessWidget {
  const ShareChannelTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.iconColor = AppColors.sokoInk,
    this.iconBackground = AppColors.sokoShade5,
    this.iconBackgroundGradient,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final Color iconColor;
  final Color iconBackground;
  final Gradient? iconBackgroundGradient;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: label,
      button: true,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: busy ? null : onTap,
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: iconBackgroundGradient == null ? iconBackground : null,
                  gradient: iconBackgroundGradient,
                ),
                child: Center(
                  child: busy
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation(iconColor),
                          ),
                        )
                      : Icon(icon, size: 24, color: iconColor),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: 72,
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'Zalando Sans',
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                    height: 1.2,
                    color: AppColors.sokoInk,
                  ),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
