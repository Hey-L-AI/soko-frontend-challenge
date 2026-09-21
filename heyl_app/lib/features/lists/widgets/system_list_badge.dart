import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../../../core/theme/app_colors.dart';

/// Small "Auto" pill rendered next to the list name on any system-managed
/// list (`UserList.isSystemManaged`, i.e. `system_kind != null`). Identifies
/// the list as auto-populated so users understand why they can't rename or
/// delete it.
///
/// Originally PROD-1741 (gear icon, IG-only). Extended in PROD-1953 to all
/// system kinds with a per-kind leading icon:
///   - `from_instagram_share` → Instagram glyph SVG
///   - `saved_items`          → bookmark
///   - `saved_places`         → map pin (PROD-3873, "Os meus sítios")
///   - `saved_events`         → calendar (PROD-3873, "Os meus eventos")
///   - `weekly_bundle`        → open book
///   - `from_onboarding` / unknown / null → cog (generic fallback)
///
/// Mounted by:
///   - [ListPageHeader] (default variant) — sokoInk on cream.
///   - [ListCard] hub card (`onImage` variant) — overlaid on the cover
///     image, opaque light fill + dark text for contrast on the gradient.
///   - [CanonicalShelfCard] on the Discovery "Yours" shelf (`onImage`).
class SystemListBadge extends StatelessWidget {
  final String label;
  final String tooltip;

  /// Backend `system_kind` for the list. Drives the leading icon. Null /
  /// unknown values render the cog fallback — matches the OpenAPI
  /// forward-compat contract ("clients MUST treat unknown values as opaque").
  final String? systemKind;

  /// When true, render with high-contrast chrome (opaque light pill,
  /// dark text) suitable for overlaying on top of an image. Default
  /// is the subtle `sokoInk @ 6 %` pill used in card headers.
  final bool onImage;

  const SystemListBadge({
    super.key,
    required this.label,
    required this.tooltip,
    this.systemKind,
    this.onImage = false,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    // In light mode the ink colour is the deep brown `sokoInk`; dark
    // mode flips to the light cream `sokoPaper` so the icon + text stay
    // legible on a dark background. The `onImage` variant always paints
    // dark glyphs on a near-opaque pale fill — the cover image itself is
    // theme-independent, so the badge is too.
    final fg = onImage
        ? AppColors.sokoInk
        : (isDark ? AppColors.sokoPaper : AppColors.sokoInk);
    final fill = onImage
        ? AppColors.sokoPaper.withValues(alpha: 0.92)
        : fg.withValues(alpha: 0.08);
    return Tooltip(
      message: tooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _iconFor(systemKind, fg),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                letterSpacing: 0.2,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _iconFor(String? kind, Color fg) {
    switch (kind) {
      case 'from_instagram_share':
        return SvgPicture.asset(
          'assets/images/icons/discovery/icon-ig.svg',
          width: 11,
          height: 11,
          colorFilter: ColorFilter.mode(fg, BlendMode.srcIn),
        );
      case 'saved_items':
        return Icon(LucideIcons.bookmark, size: 11, color: fg);
      case 'saved_places':
        return Icon(LucideIcons.map_pin, size: 11, color: fg);
      case 'saved_events':
        return Icon(LucideIcons.calendar, size: 11, color: fg);
      case 'weekly_bundle':
        return Icon(LucideIcons.book_open, size: 11, color: fg);
      case 'user_contributions':
        // PROD-2404 — auto-managed "As minhas contribuições" list. Camera
        // glyph signals the photo-based contribution origin; swap to a
        // design-system icon if/when product provides a dedicated mark.
        return Icon(LucideIcons.camera, size: 11, color: fg);
      case 'from_onboarding':
      default:
        return Icon(LucideIcons.cog, size: 11, color: fg);
    }
  }
}
