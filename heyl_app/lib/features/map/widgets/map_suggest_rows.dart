import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/event_when_formatter.dart';
import '../../../data/models/area_prediction.dart';
import '../../../data/models/map_suggest.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/clickable.dart';
import '../../../shared/widgets/soko_card_image.dart';
import '../../memory/utils/memory_value_label.dart';
import '../models/map_query.dart';

/// PROD-3497 — the fixed-height rows of the v2 map-search typed dropdown.
///
/// Rows have a FIXED height (Decision #33 — the dropdown container is
/// content-sized against `focusedDropdownMaxHeight`, so rows must never
/// expand/contract with available space) and are flat: the leading type
/// icon alone communicates the domain, no section headers (Decision #26).
/// Anatomy mirrors `TypeaheadResultRow` (48 px thumb + name + subtitle);
/// visual polish is deliberately minimal — the designer's final UI pass
/// restyles the whole mode later (umbrella Decision #4).
///
/// Subtitles are composed client-side from raw BE fields (Decision #42):
/// venue = localized category · neighborhood · city; event = localized
/// "when" · venue name (via [formatEventWhen], honoring `time_known`);
/// list = @handle (fallback owner name) · item count.
const double kMapSuggestRowHeight = 64;

const double _kThumbSize = 48;
const double _kIconSize = 20;

IconData mapSuggestIconFor(MapSuggestDomain domain) => switch (domain) {
  MapSuggestDomain.venues => LucideIcons.store,
  MapSuggestDomain.events => LucideIcons.calendar,
  MapSuggestDomain.lists => LucideIcons.book_open,
};

/// A venue / event / list suggestion row.
class MapSuggestItemRow extends StatelessWidget {
  const MapSuggestItemRow({super.key, required this.item, required this.onTap});

  final MapSuggestItem item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final domain = switch (item.type) {
      'event' => MapSuggestDomain.events,
      'list' => MapSuggestDomain.lists,
      _ => MapSuggestDomain.venues,
    };
    return MapSuggestRowShell(
      onTap: onTap,
      icon: mapSuggestIconFor(domain),
      thumb: SokoCardImage(
        imageUrl: item.imageUrl,
        seed: item.id,
        kind: switch (domain) {
          MapSuggestDomain.venues => SokoEntityKind.venue,
          MapSuggestDomain.events => SokoEntityKind.event,
          MapSuggestDomain.lists => SokoEntityKind.neutral,
        },
        width: _kThumbSize,
        height: _kThumbSize,
        borderRadius: BorderRadius.circular(6),
      ),
      title: item.name,
      subtitle: mapSuggestSubtitleFor(context, item),
    );
  }
}

/// A location suggestion row (client-composed domain — no thumb; the
/// leading pin icon carries the domain).
class MapSuggestLocationRow extends StatelessWidget {
  const MapSuggestLocationRow({
    super.key,
    required this.prediction,
    required this.onTap,
  });

  final AreaPrediction prediction;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MapSuggestRowShell(
      onTap: onTap,
      icon: LucideIcons.map_pin,
      title: prediction.name,
      subtitle: prediction.secondaryText,
    );
  }
}

/// PROD-3662 — which bounded corpus the dropdown is showing. Copy only: the
/// wire values live on [MapQuery] (`scopeWire`/`listIdWire`) and the two must
/// not be conflated — this exists so a *sentence* can be picked per scope,
/// since "A pesquisar em Os teus" doesn't read as Portuguese.
enum MapSuggestScopeKind { list, yours, following }

/// The bounded corpus behind [query], or null when it is all of Soko.
///
/// Keyed on [MapQuery.isScopeBounded] (i.e. on `scopeWire`), so the chrome can
/// never claim a bound the request didn't actually send — a half-set list state
/// reads as unbounded here exactly as it does on the wire.
MapSuggestScopeKind? mapSuggestScopeKindOf(MapQuery query) {
  if (!query.isScopeBounded) return null;
  return switch (query.source) {
    MapSource.list => MapSuggestScopeKind.list,
    MapSource.yours => MapSuggestScopeKind.yours,
    MapSource.following => MapSuggestScopeKind.following,
    // Unreachable: `all` is never bounded. Falling back to null keeps the
    // invariant one-directional — no banner unless the request was scoped.
    MapSource.all => null,
  };
}

/// The pinned "Search events or venues related to 'X'" row (Decision #13).
///
/// PROD-3662 — under a bounded corpus it **names the scope** instead
/// ("Pesquisar 'sushi' nesta Zine"). This row is also the reason there is no
/// "no results" state: `/map/suggest` is a NAME match while tapping here runs
/// the full keyword search (name + description + semantic), so a Zine with
/// nothing *called* "vinho" can still hold three wine bars. Zero suggestions
/// therefore never licenses the words "sem resultados" — Decision #17 stands.
class MapSuggestGeneralRow extends StatelessWidget {
  const MapSuggestGeneralRow({
    super.key,
    required this.query,
    required this.onTap,
    this.scope,
  });

  final String query;
  final VoidCallback onTap;

  /// The bounded corpus, or null for all of Soko.
  final MapSuggestScopeKind? scope;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return MapSuggestRowShell(
      onTap: onTap,
      icon: LucideIcons.search,
      title: switch (scope) {
        null => l10n.mapSuggestGeneralSearch(query),
        MapSuggestScopeKind.list => l10n.mapSuggestGeneralSearchInList(query),
        MapSuggestScopeKind.yours => l10n.mapSuggestGeneralSearchInYours(query),
        MapSuggestScopeKind.following =>
          l10n.mapSuggestGeneralSearchInFollowing(query),
      },
      titleMaxLines: 2,
    );
  }
}

/// PROD-3662 (Decision #53) — the scope banner: the first thing in the
/// dropdown card whenever the corpus is narrower than all of Soko.
///
/// It exists because a **bounded dropdown and a poor dropdown look identical** —
/// the same query that returned six rows returns one, and the default reading
/// is "Soko's search is bad", not "I'm inside a Zine". The "De quem?" chip
/// can't do this job: it sits in the results-drawer footer, dimmed under the
/// focused-mode scrim, and reads "Zine" rather than the Zine's name.
///
/// Rules, all deliberate: **one line** with the name ellipsised (a Zine title
/// can be long and the dropdown's vertical space is the scarce resource with a
/// keyboard up), and the escape is an **×** rather than a text link — dark
/// enough to be a real control, muted enough not to compete with the search
/// field's own × sitting ~20 px above it and meaning something much smaller.
class MapSuggestScopeBanner extends StatelessWidget {
  const MapSuggestScopeBanner({
    super.key,
    required this.scope,
    required this.listName,
    required this.onClear,
  });

  final MapSuggestScopeKind scope;

  /// The active Zine's name. Null/blank falls back to the unnamed copy — a
  /// restored session can hold a list id without ever having seen its name.
  final String? listName;

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final name = listName?.trim();
    final label = switch (scope) {
      MapSuggestScopeKind.list =>
        name == null || name.isEmpty
            ? l10n.mapSearchScopeBannerListFallback
            : l10n.mapSearchScopeBannerList(name),
      MapSuggestScopeKind.yours => l10n.mapSearchScopeBannerYours,
      MapSuggestScopeKind.following => l10n.mapSearchScopeBannerFollowing,
    };

    return ColoredBox(
      color: AppColors.sokoLight3,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: [
            Expanded(
              child: Text(
                label,
                // The whole point of the one-line rule: a long Zine name
                // truncates, it never pushes rows off the dropdown.
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.2,
                  letterSpacing: -0.13,
                  color: AppColors.sokoInk,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              button: true,
              label: l10n.mapSearchScopeClear,
              child: Clickable(
                onTap: onClear,
                child: const Padding(
                  padding: EdgeInsets.all(6),
                  child: Icon(
                    LucideIcons.x,
                    size: 16,
                    // Zé: "dark pink … part of the banner, not too highlighted".
                    // Ink at 55% is the dark end of the Soko pink ramp and
                    // clears the 3:1 contrast floor for a control on
                    // `sokoLight3`; `sokoPinkMiddle` reads as the right hue but
                    // lands near 1.8:1, which is an × you can't find.
                    color: Color(0x8C44131D),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// PROD-3662 (Decision #55) — the muted line above the locations block while a
/// scope is active. The dropdown's only header, amending #26 for exactly one
/// row, because locations are the one domain the corpus scope can't bound.
class MapSuggestLocationsScopeMarkerRow extends StatelessWidget {
  const MapSuggestLocationsScopeMarkerRow({super.key});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 2),
      child: Text(
        Lt.of(context).mapSuggestLocationsUnscoped,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
          height: 1.2,
          color: AppColors.sokoShade3,
        ),
      ),
    );
  }
}

/// Arrow-led "view other {section}…" expander row (Decision #8; C4 — the
/// leading arrow signals collapsed results).
class MapSuggestExpanderRow extends StatelessWidget {
  const MapSuggestExpanderRow({
    super.key,
    required this.label,
    required this.onTap,
  });

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MapSuggestRowShell(
      onTap: onTap,
      icon: LucideIcons.chevron_down,
      title: label,
      muted: true,
    );
  }
}

/// The collapse line under an expanded block (C5a).
class MapSuggestCollapseRow extends StatelessWidget {
  const MapSuggestCollapseRow({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MapSuggestRowShell(
      onTap: onTap,
      icon: LucideIcons.chevron_up,
      title: Lt.of(context).mapSuggestCollapse,
      muted: true,
    );
  }
}

/// Quiet "Couldn't search — tap to retry" full-row error state (B6/B7).
class MapSuggestRetryRow extends StatelessWidget {
  const MapSuggestRetryRow({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return MapSuggestRowShell(
      onTap: onRetry,
      icon: LucideIcons.refresh_cw,
      title: Lt.of(context).mapSuggestRetry,
      muted: true,
    );
  }
}

/// Decision #42 subtitle composition — pure per-domain field joins; null
/// when no raw field survives (the row then renders the title only).
String? mapSuggestSubtitleFor(BuildContext context, MapSuggestItem item) {
  final parts = switch (item.type) {
    'venue' => [
      if (item.category != null && item.category!.isNotEmpty)
        humanizeMemoryValue(context, item.category!, family: 'venue_types'),
      if (item.neighborhood != null && item.neighborhood!.isNotEmpty)
        item.neighborhood!,
      if (item.city != null && item.city!.isNotEmpty) item.city!,
    ],
    'event' => [
      if (item.startAt != null)
        formatEventWhen(
          context: context,
          startsAt: item.startAt!,
          timeKnown: item.timeKnown ?? true,
        ),
      if (item.venueName != null && item.venueName!.isNotEmpty) item.venueName!,
    ],
    'list' => [
      if (item.ownerHandle != null && item.ownerHandle!.isNotEmpty)
        '@${item.ownerHandle}'
      else if (item.ownerName != null && item.ownerName!.isNotEmpty)
        item.ownerName!,
      if (item.itemCount != null)
        Lt.of(context).listsItemCount(item.itemCount!),
    ],
    _ => const <String>[],
  };
  if (parts.isEmpty) return null;
  return parts.join(' · ');
}

/// The shared fixed-height row anatomy of the map-search dropdown —
/// `{leading icon, title, subtitle?, thumb?, onTap}` at [kMapSuggestRowHeight].
/// PROD-3499 (past-searches UI) consumes this same shell for history rows
/// (E2: history rows share anatomy with live suggestions), so treat its
/// parameter surface as a cross-ticket contract.
class MapSuggestRowShell extends StatelessWidget {
  const MapSuggestRowShell({
    super.key,
    required this.onTap,
    required this.icon,
    required this.title,
    this.subtitle,
    this.thumb,
    this.muted = false,
    this.titleMaxLines = 1,
    this.trailing,
    this.onLongPress,
  });

  final VoidCallback onTap;
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? thumb;
  final bool muted;
  final int titleMaxLines;

  /// Trailing widget after the text block (PROD-3499: the history rows'
  /// per-row delete affordance). Null for suggestion rows.
  final Widget? trailing;

  /// Secondary gesture (PROD-3499: long-press-to-delete on history rows).
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kMapSuggestRowHeight,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            children: [
              // Unified-search: the leading domain icon is redundant once a row
              // has a thumbnail (and the grouped section pill above already names
              // the category). Rows WITHOUT a thumb — locations, the general
              // row, expanders, retry — keep the icon as their only leading mark.
              if (thumb != null)
                thumb!
              else
                Icon(
                  icon,
                  size: _kIconSize,
                  color: muted ? AppColors.sokoShade3 : AppColors.sokoInk,
                ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: titleMaxLines,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w400,
                        height: 1.2,
                        letterSpacing: -0.15,
                        color: muted ? AppColors.sokoShade3 : AppColors.sokoInk,
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
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
                    ],
                  ],
                ),
              ),
              if (trailing != null) trailing!,
            ],
          ),
        ),
      ),
    );
  }
}
