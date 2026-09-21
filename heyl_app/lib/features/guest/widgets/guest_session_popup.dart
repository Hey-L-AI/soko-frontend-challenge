import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../utils/open_app_url.dart';

/// Once-per-session "Find more on Soko" popup (PROD-2072 — Figma node
/// `6628:15502`). A dismissible card with the Soko mascot, two-line H1,
/// body copy, and a pink `[↗ Open Soko]` CTA that opens
/// `soko.fyi/get/<currentPath>`. Top-right X dismisses.
///
/// Designed to be rendered inside a transparent [Dialog] from
/// [DiscoveryShell]. The session-shown flag lives in
/// [guestSessionPopupShownProvider] — the caller flips it to `true`
/// before opening so a re-build in the same frame doesn't reopen.
class GuestSessionPopup extends StatelessWidget {
  const GuestSessionPopup({super.key, required this.currentPath});

  /// GoRouter `matchedLocation` passed through so the CTA opens the same
  /// path-preserving deep link the banner uses.
  final String currentPath;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 432),
      child: CustomPaint(
        // Figma: 1 px dashed border, Soko/Ink, 6 px corner radius. No
        // `dotted_border` dep — paint inline. See [_DashedRRectPainter].
        painter: const _DashedRRectPainter(
          color: AppColors.sokoInk,
          strokeWidth: 1,
          dashLength: 4,
          gapLength: 4,
          radius: 6,
        ),
        child: Material(
          // Card surface lives inside `Material` so InkWell ripples (none
          // here yet, but X tap target benefits from a Material ancestor)
          // and a11y semantics behave normally inside `Dialog`.
          color: AppColors.sokoPaper,
          borderRadius: BorderRadius.circular(6),
          child: Stack(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 36, 28, 36),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // Mascot. `soko-walking-and-reading.webp` is the
                    // closest existing illustration to the Figma "reading
                    // newspaper" mascot; if design wants the exact Figma
                    // asset, upload it to `assets/images/illustrations/`
                    // and swap the path.
                    Image.asset(
                      'assets/images/illustrations/soko-walking-and-reading.webp',
                      width: 126,
                      height: 115,
                      fit: BoxFit.contain,
                    ),
                    const SizedBox(height: 30),
                    Text(
                      l10n.guestPopupTitle,
                      textAlign: TextAlign.center,
                      style: AppTheme.displayPrimary(
                        fontSize: 42,
                        fontWeight: FontWeight.w300,
                        color: AppColors.sokoInk,
                        height: 0.94,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      l10n.guestPopupBody,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w300,
                        height: 1.2,
                        letterSpacing: -0.14,
                        color: AppColors.sokoShade1,
                      ),
                    ),
                    const SizedBox(height: 30),
                    BtSqIco(
                      icon: LucideIcons.arrow_up_right,
                      label: l10n.guestPopupCta,
                      variant: BtSqIcoVariant.selected,
                      onTap: () {
                        // Close the popup first so the user isn't left
                        // looking at the modal after the new tab opens.
                        Navigator.of(context).pop();
                        launchUrl(
                          Uri.parse(openAppUrl(currentPath)),
                          mode: LaunchMode.externalApplication,
                        );
                      },
                    ),
                  ],
                ),
              ),
              // X close button (Figma `6628:15509`) — 30×30 hit target in
              // the top-right corner, 11 px inset from edges.
              Positioned(
                top: 11,
                right: 11,
                child: Semantics(
                  label: l10n.guestPopupCloseLabel,
                  button: true,
                  child: InkResponse(
                    onTap: () => Navigator.of(context).pop(),
                    radius: 20,
                    child: const SizedBox(
                      width: 30,
                      height: 30,
                      child: Icon(
                        LucideIcons.x,
                        size: 24,
                        color: AppColors.sokoInk,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Paints a dashed 1 px rounded-rectangle border around the popup card.
/// Inline because `dotted_border` is not a project dependency and the
/// painter is one widget's worth of code.
class _DashedRRectPainter extends CustomPainter {
  const _DashedRRectPainter({
    required this.color,
    required this.strokeWidth,
    required this.dashLength,
    required this.gapLength,
    required this.radius,
  });

  final Color color;
  final double strokeWidth;
  final double dashLength;
  final double gapLength;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke;

    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);

    // Walk the path metrics in fixed-length increments alternating
    // between dash and gap. PathMetric.extractPath handles corner
    // wrapping for us — the dash pattern flows smoothly around the
    // rounded corners.
    for (final metric in path.computeMetrics()) {
      double distance = 0;
      while (distance < metric.length) {
        final next = (distance + dashLength).clamp(0, metric.length).toDouble();
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gapLength;
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRRectPainter old) =>
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.dashLength != dashLength ||
      old.gapLength != gapLength ||
      old.radius != radius;
}
