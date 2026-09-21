import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../shared/widgets/avatar_name_label.dart';
import '../../../shared/widgets/clickable.dart';
import '../../../shared/widgets/hero_image_warmup.dart';
import '../../discovery/feed_v2/widgets/blocks/feed_bundle_row.dart';
import '../models/library_filter.dart';
import '../providers/library_filter_provider.dart';
import 'library_pin_button.dart';

const double kLibraryRowHeight = FeedBundleRow.rowHeight;
const double kLibraryPersonRowHeight = 64;
const double kLibraryRowGap = 10;
const double kLibraryThumbWidth = FeedBundleRow.thumbWidth;
const double _kMetaGap = 6;

/// Library list row via [FeedBundleRow.custom], not a fork.
class LibraryItemRow extends ConsumerWidget {
  const LibraryItemRow({
    super.key,
    required this.title,
    required this.metaLines,
    required this.thumbnail,
    this.fallbackColor,
    this.trailingLine,
    this.showPin = false,
    this.height = kLibraryRowHeight,
    this.onTap,
    this.heroTag,
    this.heroImageUrl,
    this.trailing,
    this.forceListLayout = false,
  });

  final String title;

  /// One or two metadata rows. Each is a list of chips joined by a `•`.
  final List<List<MetaChip>> metaLines;

  final Color? fallbackColor;

  /// Cutout is the caller's: event ticket, place rectangle, person squircle,
  /// or zine cover. Do not wrap a second clip around this in the grid.
  final Widget thumbnail;

  /// Its own line under the chips — follower faces on a zine row. Sharing the
  /// chip line squeezed it to an ellipsis at every width.
  final Widget? trailingLine;

  final bool showPin;

  final double height;

  final VoidCallback? onTap;

  /// PROD-4160-followup — when non-null, the row thumbnail is wrapped in a
  /// [Hero] with this tag so it flies into the detail page's top collage on
  /// tap. Set only for event/place rows (keyed by entity id); zine rows leave
  /// it null (their thumbnail is a cover recipe, not the entity photo).
  final String? heroTag;

  /// The photo URL for a poster (event/place) row's Hero flight. When set, the
  /// row's Hero uses [detailPhotoHeroFlightShuttle] so the poster flies as a
  /// clean, warmed radius-6 tile into the detail collage instead of "cut, then
  /// snaps". Left null for zine-cover rows (their thumbnail is a recipe cover,
  /// which morphs cleanly on the default flight).
  final String? heroImageUrl;

  /// Control pinned to the row's right edge — the calendar agenda's save
  /// bookmark. The Library's own rows leave it null: they carry their state
  /// in [showPin], on the meta line, not as a button.
  final Widget? trailing;

  /// Ignore [libraryViewProvider] and always render the row, never the grid
  /// tile. Set by surfaces that are a list by nature and are not the Library
  /// grid — the calendar agenda, whose rows hang off a picked day and would
  /// otherwise flip to tiles just because the user last left the Library in
  /// grid mode.
  final bool forceListLayout;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lines = (metaLines.isEmpty && showPin)
        ? const [<MetaChip>[]]
        : metaLines;
    final view = ref.watch(libraryViewProvider);
    Widget wrapHero(Widget child) {
      if (heroTag == null) return child;
      return Hero(
        tag: heroTag!,
        // Poster (event/place) rows carry [heroImageUrl] and fly a clean warmed
        // tile into the detail collage; zine-cover rows pass no URL and keep the
        // default flight (their recipe cover already morphs cleanly).
        flightShuttleBuilder: heroImageUrl != null
            ? detailPhotoHeroFlightShuttle(heroImageUrl)
            : null,
        child: child,
      );
    }

    if (view == LibraryViewMode.grid && !forceListLayout) {
      return _GridTile(
        title: title,
        thumbnail: wrapHero(thumbnail),
        height: height,
        showPin: showPin,
        onTap: onTap,
      );
    }
    return FeedBundleRow.custom(
      thumbnail: wrapHero(thumbnail),
      title: title,
      meta: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < lines.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            _MetaLine(chips: lines[i], showPin: i == 0 && showPin),
          ],
          if (trailingLine != null) ...[
            // No chips above means no gap to open — otherwise the line would
            // start 8 px down from nothing.
            if (lines.isNotEmpty) const SizedBox(height: 8),
            trailingLine!,
          ],
        ],
      ),
      onTap: onTap,
      height: height,
      trailing: trailing,
    );
  }
}

class _GridTile extends StatelessWidget {
  const _GridTile({
    required this.title,
    required this.thumbnail,
    required this.height,
    required this.showPin,
    this.onTap,
  });

  final String title;
  final Widget thumbnail;
  final double height;
  final bool showPin;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Clickable(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: kLibraryThumbWidth / height,
            child: FittedBox(
              fit: BoxFit.cover,
              // The thumb already is the cutout (ticket / rect / squircle).
              // An extra ClipRRect here would square the ticket notches.
              clipBehavior: Clip.hardEdge,
              child: SizedBox(
                width: kLibraryThumbWidth,
                height: height,
                child: thumbnail,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              if (showPin) ...[
                const LibraryPinMark(),
                const SizedBox(width: _kMetaGap),
              ],
              Expanded(
                child: Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: AppTheme.mobileB1Reg(color: AppColors.sokoInk),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A glyph + label pair on a metadata line. A null [icon] renders label only.
/// [avatarUrl] paints a small round face right before this chip's label, so
/// the avatar stays glued to the name it belongs to (curator, follower).
/// [tight] chips ("Private", "215p") always render whole at natural width;
/// when the line overflows, only the non-tight chips (names) truncate.
class MetaChip {
  const MetaChip(this.label, {this.icon, this.avatarUrl, this.tight = false});
  final String label;
  final IconData? icon;
  final String? avatarUrl;
  final bool tight;
}

class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.chips, this.showPin = false});

  final List<MetaChip> chips;
  final bool showPin;

  @override
  Widget build(BuildContext context) {
    final style = AppTheme.mobileB2Reg(color: AppColors.sokoInk);
    final parts = <Widget>[];

    if (showPin) {
      parts.addAll([const LibraryPinMark(), const SizedBox(width: _kMetaGap)]);
    }

    for (var i = 0; i < chips.length; i++) {
      if (i > 0) {
        parts.addAll([
          const SizedBox(width: _kMetaGap),
          Text('•', style: style),
          const SizedBox(width: _kMetaGap),
        ]);
      }
      final c = chips[i];
      if (c.icon != null) {
        parts.addAll([
          Icon(c.icon, size: 14, color: AppColors.sokoInk),
          const SizedBox(width: _kMetaGap),
        ]);
      }
      final chipChild = c.avatarUrl != null
          ? AvatarNameLabel(
              label: c.label,
              avatarUrl: c.avatarUrl,
              style: style,
              gap: _kMetaGap,
            )
          : Text(
              c.label,
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            );
      parts.add(
        c.tight
            ? chipChild
            : Flexible(
                // Flex shares are proportional to label length, so a long chip
                // only truncates when the line genuinely overflows — equal
                // shares would clip it while a short sibling sits on empty
                // space. The avatar'd pair gets extra "chars" for the face.
                flex:
                    c.label.length.clamp(1, 100) +
                    (c.avatarUrl != null ? 4 : 0),
                child: chipChild,
              ),
      );
    }

    return Row(children: parts);
  }
}
