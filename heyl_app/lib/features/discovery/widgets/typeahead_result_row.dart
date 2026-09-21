import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/event_when_formatter.dart';
import '../../../data/models/chat_message.dart';
import '../../../data/models/user_list.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/soko_card_image.dart';
import '../../lists/utils/zine_cover_recipe.dart';
import '../../lists/widgets/zine/list_zine_cover.dart';
import '../providers/search_results_provider.dart';

/// Color-codes a [SearchResultRow] by kind, matching the detail-page
/// background colors so the strip reads as "tap this row to land on a
/// page in this color":
/// - Event row → [AppColors.sokoEvent] (green — matches event detail bg)
/// - Venue row → [AppColors.sokoVenue] (blue — matches venue detail bg)
/// - Zine row  → [AppColors.sokoListAccent] (yellow — list detail uses
///   `sokoPaper`, same as the typeahead bg, so we keep an explicit
///   accent token instead)
Color typeaheadAccentColorFor(SearchResultRow row) => switch (row) {
  EventSearchResultRow() => AppColors.sokoEvent,
  PlaceSearchResultRow() => AppColors.sokoVenue,
  ListSearchResultRow() => AppColors.sokoListAccent,
};

/// Compact result row for the discovery chat typeahead (PROD-1909).
///
/// Layout: 3-px accent strip + 48-px square image thumb + name (1 line,
/// Soko/Ink) + subtitle (1 line, Soko/Shade3). Tap delegates to the
/// overlay which routes to the venue/event/list detail page. Mirrors the
/// iOS-native "search row" feel from the Linear screenshot, not the big
/// 195 × 304 `HighlightedShelfCard` chrome used by the action-bar grid
/// search.
class TypeaheadResultRow extends StatelessWidget {
  final SearchResultRow row;
  final VoidCallback onTap;

  const TypeaheadResultRow({super.key, required this.row, required this.onTap});

  static const double _thumbSize = 48;
  static const double _accentWidth = 3;
  static const double _accentRadius = 1.5;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final subtitle = row.subtitle;
    final attribution = row.attribution;
    // Event rows prepend the same "A acontecer"-style day+time the
    // Discovery grid uses (see `_composeEventSubtitle` in
    // `search_results_section.dart`). Format follows
    // `core/utils/event_when_formatter.dart`. Falls back silently when
    // the BE doesn't give us a parseable date so the row still renders
    // venue · city.
    final when = row is EventSearchResultRow
        ? _eventWhen(context, (row as EventSearchResultRow).event)
        : null;
    final rest = [
      if (when != null) when,
      if (subtitle != null && subtitle.isNotEmpty) subtitle,
      if (attribution.isNotEmpty) attribution,
    ].join(' · ');
    final kind = switch (row) {
      EventSearchResultRow() => _RowKind.event,
      ListSearchResultRow() => _RowKind.list,
      PlaceSearchResultRow() => _RowKind.place,
    };
    final tagLabel = switch (kind) {
      _RowKind.event => l10n.discoveryChatTypeaheadTagEvent,
      _RowKind.place => l10n.discoveryChatTypeaheadTagVenue,
      _RowKind.list => l10n.discoveryChatTypeaheadTagZine,
    };
    final accent = typeaheadAccentColorFor(row);

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Category accent — colored vertical strip, aligned to the
            // thumb height so the row's leading edge reads "this is an
            // event/venue/zine" at a glance.
            Container(
              width: _accentWidth,
              height: _thumbSize,
              decoration: BoxDecoration(
                color: accent,
                borderRadius: BorderRadius.circular(_accentRadius),
              ),
            ),
            const SizedBox(width: 10),
            // PROD-2300 audit close-out — list rows render via the
            // canonical `ListZineCover` so the typeahead chrome matches
            // every other list/zine surface (background colour, texture,
            // photo, recipe-driven). Title/logo are off at 48 px (the
            // glyphs would render at < 8 px and read as noise). Event /
            // place rows keep the legacy `_Thumb` — they're not lists
            // and don't have a cover recipe.
            switch (row) {
              ListSearchResultRow(:final list) => _ListThumb(list: list),
              _ => _Thumb(imageUrl: row.imageUrl, kind: kind, seed: row.rowKey),
            },
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    row.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w400,
                      height: 1.2,
                      letterSpacing: -0.16,
                      color: AppColors.sokoInk,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _KindTagPill(label: tagLabel, background: accent),
                      if (rest.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            rest,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w300,
                              height: 1.2,
                              letterSpacing: -0.13,
                              color: AppColors.sokoShade3,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Day+time string for an event typeahead row — returns `null` when the
/// BE doesn't ship a next occurrence so the row collapses back to the
/// venue · city subtitle. Mirrors `_composeEventSubtitle` in
/// `search_results_section.dart`. `event.date` from the search endpoint
/// is a pre-formatted display string and isn't parseable — the parsed
/// datetime lives on `occurrences.first.startAt`.
String? _eventWhen(BuildContext context, ItemSuggestion event) {
  if (event.occurrences.isEmpty) return null;
  final next = event.occurrences.first;
  return formatEventWhen(
    context: context,
    startsAt: next.startAt,
    timeKnown: next.timeKnown,
  );
}

/// Compact category pill used in the second line of [TypeaheadResultRow].
/// Mirrors `CardTagRow`'s `_Tag` chrome — radius 2, 6/2 padding, ZalandoSans
/// Light 12 — but takes a free-form background so it can adopt the row's
/// category accent (`sokoEvent` / `sokoVenue` / `sokoListAccent`).
class _KindTagPill extends StatelessWidget {
  const _KindTagPill({required this.label, required this.background});

  final String label;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(2),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontFamily: 'ZalandoSans',
          fontWeight: FontWeight.w300,
          fontSize: 12,
          height: 1.2,
          letterSpacing: -0.12,
          color: AppColors.sokoInk,
        ),
      ),
    );
  }
}

enum _RowKind { event, place, list }

class _Thumb extends StatelessWidget {
  final String? imageUrl;
  final _RowKind kind;
  final String seed;
  const _Thumb({
    required this.imageUrl,
    required this.kind,
    required this.seed,
  });

  static const double _size = TypeaheadResultRow._thumbSize;
  static const double _radius = 6;

  @override
  Widget build(BuildContext context) {
    return SokoCardImage(
      imageUrl: imageUrl,
      seed: seed,
      kind: switch (kind) {
        _RowKind.event => SokoEntityKind.event,
        _RowKind.place => SokoEntityKind.venue,
        _RowKind.list => SokoEntityKind.neutral,
      },
      width: _size,
      height: _size,
      borderRadius: BorderRadius.circular(_radius),
    );
  }
}

/// List-row thumbnail — drives `ListZineCover` from the `UserList`'s
/// recipe fields. Same outer 48-px clipped square as [_Thumb], chrome
/// off because title/logo are illegible at this size.
class _ListThumb extends StatelessWidget {
  const _ListThumb({required this.list});

  final UserList list;

  static const double _size = TypeaheadResultRow._thumbSize;
  static const double _radius = 6;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(_radius),
      child: SizedBox(
        width: _size,
        height: _size,
        child: ListZineCover(
          recipe: ZineCoverRecipe.fromUserList(list),
          title: list.name,
          showTitle: false,
          showLogo: false,
        ),
      ),
    );
  }
}
