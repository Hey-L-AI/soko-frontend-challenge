import 'package:flutter/material.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../shared/widgets/cached_image.dart';
import '_daily_drop_status_cards.dart';

/// Fully-composed cover for the Discovery Weekly Bundle (PROD-1518), rebuilt
/// on the **shared ritual-card frame** (Zé, 2026-08-27, Figma `7285:24364`).
///
/// It used to paint its own chrome via `EditorialOverlay` — a Stack with the
/// rules and the header at fractional offsets. It now uses the same
/// [DailyDropCardShell] the Daily Drop cards do, so corners, mat and inset rule
/// match by construction rather than by two sets of numbers agreeing. What
/// differs is deliberate and small: the palette, and a **dotted** rule where
/// Daily Drop's is dashed.
///
/// Everything is still painted client-side — there is no BE-served photo here,
/// only the bundle's own thumbnails.
class WeeklyBundleCover extends StatelessWidget {
  /// Thumbnail URLs, already filtered of empties by the caller.
  ///
  /// PROD-4006 widened this from `List<WeeklyBundleItem>`: the cover only ever
  /// read `item.imageUrl`, and the server-driven feed delivers the same cover
  /// as a bare `cover_image_urls` list inside the block rather than as items
  /// fetched from `/recommendations/weekly`. Taking the narrower type lets both
  /// callers share one cover instead of forking the editorial chrome.
  final List<String> imageUrls;

  final DateTime date;
  final String locale;

  const WeeklyBundleCover({
    super.key,
    required this.imageUrls,
    required this.date,
    required this.locale,
  });

  static const int _maxThumbs = 5;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final visibleThumbs = imageUrls
        .where((url) => url.isNotEmpty)
        .take(_maxThumbs)
        .toList(growable: false);

    return DailyDropCardShell(
      palette: kWeeklyBundleCardPalette,
      // Its own paper: `Texturelabs_Grunge_340S 2`, a fine even grain, where
      // the Daily Drop's sheet is creased and folded. Different sheet AND a
      // different placement — see [RitualCardTexture].
      texture: kWeeklyBundleCardTexture,
      // The one thing that tells the two ritual cards apart beyond colour —
      // Daily Drop's rule is dashed, this one's is dotted (Zé, 2026-08-27).
      border: RitualCardBorder.dotted,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          RitualCardHeaderRow(
            date: date,
            locale: locale,
            color: AppColors.sokoInk,
          ),
          // The thumbnails take the slack; the lockup below sizes itself.
          if (visibleThumbs.isNotEmpty) ...[
            const SizedBox(height: 8),
            Expanded(child: _ThumbnailRow(imageUrls: visibleThumbs)),
            // The rule between the strip and the lockup (Figma `7675:37875`),
            // missing until 2026-09-01. Without it the thumbnails and the
            // title read as one block; the rule is what makes the card a
            // masthead over a contact sheet.
            //
            // Figma (350-wide frame): strip ends 109.4, rule at 117.7, lockup
            // box starts 124.5 — 8.3 above, 6.8 below, which is 9.5 / 7.7 at
            // our 399. Rounded to whole pixels, the rule being a hairline.
            const SizedBox(height: 9),
            RitualCardDottedRule(color: AppColors.sokoInk),
            const SizedBox(height: 8),
          ] else
            // No strip, no separation to draw — the rule would be a line under
            // nothing.
            const Spacer(),
          // `FittedBox` rather than a computed size: the lockup has to fit
          // whatever width the card ends up at, and the carousel renders it at
          // roughly two thirds of the full-width card.
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.center,
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: l10n.discoveryWeeklyBundleCoverLockupRegular,
                    style: _lockupStyle(_lockupBaseSize),
                  ),
                  TextSpan(
                    text: l10n.discoveryWeeklyBundleCoverLockupItalic,
                    // Figma names this face `Season Mix TRIAL: Regular_Italic`,
                    // but the trial family we bundle ships four UPRIGHT cuts
                    // and no italic — so Figma is synthesising the slant here
                    // and so are we. `FontStyle.italic` on a family with no
                    // italic face makes the engine skew the upright cut, which
                    // is the same transform, and is why this does not need a
                    // fifth font file.
                    style: _lockupStyle(
                      _lockupBaseSize,
                    ).copyWith(fontStyle: FontStyle.italic),
                  ),
                ],
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  /// Figma `7675:37885` sizes the lockup at 50.884 px on a 350-wide frame —
  /// **58.0 on our 399**. The `FittedBox` scales it down from here, so this is
  /// a ceiling rather than a fixed size: a long locale renders smaller, a short
  /// one stops here instead of growing to fill the card.
  ///
  /// Was 63.083, off the superseded frame `3841:2326`.
  static const double _lockupBaseSize = 58.008;

  /// **Season Mix, not Zalando** (Zé, 2026-09-01). The frame sets both words in
  /// `Season Mix TRIAL: Regular` — `AppTheme.display` is the Zalando family, so
  /// this lockup had been rendering in the wrong typeface since it was built,
  /// and reading as a heading rather than as a masthead. `displayPrimary` is
  /// the Season Mix door.
  ///
  /// Weight is **w400**: the frame says Regular, and `displayPrimary` defaults
  /// to w300. Tracking −3 % is Figma's `-1.5265px` at 50.884, expressed as the
  /// ratio so it survives the size above changing.
  ///
  /// The italic half is the same style with [FontStyle.italic] — see the note
  /// at the call site about there being no italic cut to reach.
  TextStyle _lockupStyle(double size) => AppTheme.displayPrimary(
    fontSize: size,
    fontWeight: FontWeight.w400,
    color: AppColors.sokoInk,
    height: 0.86,
    letterSpacing: size * -0.03,
  );
}

/// Up to 5 portrait thumbnails distributed evenly across the strip.
/// `MainAxisAlignment.spaceEvenly` keeps the gaps at edges and between
/// thumbs equal regardless of how many images are available, so a
/// 3-image row spreads with four equal gaps.
class _ThumbnailRow extends StatelessWidget {
  final List<String> imageUrls;
  const _ThumbnailRow({required this.imageUrls});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final h = constraints.maxHeight;
        // Even distribution: equal gaps for n items + (n+1) gaps. Cap
        // each thumb so the row never tries to render wider than the
        // strip allows.
        final n = imageUrls.length;
        final maxThumbWidth = (constraints.maxWidth - (n + 1) * 6) / n;
        final thumbWidth = (h * 0.78).clamp(0.0, maxThumbWidth);
        return Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            for (final url in imageUrls)
              _Thumbnail(imageUrl: url, width: thumbWidth, height: h),
          ],
        );
      },
    );
  }
}

class _Thumbnail extends StatelessWidget {
  final String imageUrl;
  final double width;
  final double height;

  const _Thumbnail({
    required this.imageUrl,
    required this.width,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        width: width,
        height: height,
        child: CachedImage(
          imageUrl: imageUrl,
          width: width,
          height: height,
          fit: BoxFit.cover,
          placeholder: const ColoredBox(color: Color(0x22000000)),
          errorWidget: const ColoredBox(color: Color(0x22000000)),
        ),
      ),
    );
  }
}
