// Unified search — the presentation-only data model shared by every search
// surface (map, chat, onboarding, library, discovery feed).
//
// The component ([UnifiedContentSearch]) knows nothing about endpoints, camera
// flies or routing. Each surface fans out to its own data sources, maps the
// results into [UnifiedSearchSection]s, and supplies the per-row [onTap] +
// (onboarding only) a like target. That is what lets one widget carry the map's
// camera behaviour and onboarding's thumbs-up without either leaking into the
// other.

import 'package:flutter/widgets.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/entity_signal.dart';
import '../soko_card_image.dart';
import '../soko_tag_chip.dart' show SokoTagTone;

/// The full set of things Soko can search for. Each surface exposes a subset as
/// filter chips (map/chat = locations/venues/events/zines; onboarding, library
/// and the feed = events/venues/zines/people) — the component renders whatever
/// ordered subset the host passes.
enum SokoSearchCategory { locations, venues, events, zines, people }

extension SokoSearchCategoryChrome on SokoSearchCategory {
  /// Filter-chip + section-header glyph — the SINGLE source of truth for these
  /// icons across every surface (chips, section pills, map domain tags). Matches
  /// the feed's filter row: Events=calendar, Places=map_pin, Zines=book_open,
  /// People=user. `locations` (map/chat only) uses `map` so it stays distinct
  /// from `venues`/Places (`map_pin`) where both appear at once.
  IconData get icon => switch (this) {
    SokoSearchCategory.locations => LucideIcons.map,
    SokoSearchCategory.venues => LucideIcons.map_pin,
    SokoSearchCategory.events => LucideIcons.calendar,
    SokoSearchCategory.zines => LucideIcons.book_open,
    SokoSearchCategory.people => LucideIcons.user,
  };

  /// Section-header pill tone. Mirrors the vibe carousels / library filter
  /// tones so the coloured section chip reads as the same design-system object.
  SokoTagTone get sectionTone => switch (this) {
    SokoSearchCategory.locations => SokoTagTone.pink,
    SokoSearchCategory.venues => SokoTagTone.blue,
    SokoSearchCategory.events => SokoTagTone.green,
    SokoSearchCategory.zines => SokoTagTone.purple,
    SokoSearchCategory.people => SokoTagTone.yellow,
  };

  /// The card-image kind used for a row's thumbnail placeholder when the item
  /// has no image.
  SokoEntityKind get thumbKind => switch (this) {
    SokoSearchCategory.events => SokoEntityKind.event,
    SokoSearchCategory.venues => SokoEntityKind.venue,
    SokoSearchCategory.locations ||
    SokoSearchCategory.zines ||
    SokoSearchCategory.people => SokoEntityKind.neutral,
  };
}

/// A single result row, already mapped from its domain shape by the host.
class UnifiedSearchRow {
  const UnifiedSearchRow({
    required this.rowKey,
    required this.title,
    this.subtitle,
    this.imageUrl,
    this.seed,
    this.category,
    this.signalTarget,
    this.onTap,
    this.payload,
  });

  /// Stable identity for [Key] equality across re-fetches (`'event_<id>'`,
  /// `'venue_<id>'`, `'list_<id>'`, `'user_<id>'`, `'loc_<id>'`).
  final String rowKey;

  final String title;
  final String? subtitle;

  /// Raw image URL for the 56×56 thumbnail. Null → the seeded placeholder.
  final String? imageUrl;

  /// Placeholder seed (usually the item id) so a missing image is stable.
  final String? seed;

  /// Overrides the section's category for the thumbnail kind — normally left
  /// null (rows inherit their section's category).
  final SokoSearchCategory? category;

  /// The entity-signal target `(type, id)` for the thumbs-up like. Null when the
  /// item can't be liked (a Google-only place, a location) — the like button is
  /// then omitted even on surfaces that show likes.
  final (SignalEntityType, String)? signalTarget;

  /// Opens the item — detail page on most surfaces, a camera fly on the map.
  /// The like button (when shown) has its own gesture and wins taps in its
  /// bounds; a tap anywhere else on the row fires this.
  final VoidCallback? onTap;

  /// The source domain object (`ItemSuggestion` / `UserList` / `UserSearchItem`),
  /// carried so a host that intercepts taps or likes (onboarding) can recover it
  /// without re-fetching. Null when a surface has no need for it.
  final Object? payload;
}

/// One grouped section of results (an Events block, a Places block, …), with
/// the chat-style collapse/expand state the component renders as the animated
/// "View other {category}…" control.
class UnifiedSearchSection {
  const UnifiedSearchSection({
    required this.category,
    required this.label,
    required this.rows,
    this.expanded = false,
    this.onToggleExpand,
  });

  final SokoSearchCategory category;

  /// Section-header pill text (localized by the host — "Eventos", "Sítios", …).
  final String label;

  /// All rows for the section. The component shows the first
  /// [kUnifiedSearchCollapsedCount] then the expander when [expanded] is false.
  final List<UnifiedSearchRow> rows;

  final bool expanded;

  /// Fired when the expander is tapped. Null keeps the section always-collapsed
  /// (no expander shown). Map/chat additionally fire a deep search here.
  final VoidCallback? onToggleExpand;
}

/// Rows shown per section before the "View other …" expander appears. 3 matches
/// both onboarding's `_collapsedCount` and the map's collapsed-visible count, so
/// every surface previews the same amount.
const int kUnifiedSearchCollapsedCount = 3;

/// Section-header pill background for a category, resolved to a concrete colour
/// so callers don't reach into [SokoTagTone].
Color sectionPillColor(SokoSearchCategory category) => category.sectionTone.color;

/// The onboarding section colours, kept as named aliases for readability at the
/// call sites that still think in "event green / venue blue".
const Color kUnifiedEventsPill = AppColors.sokoEvent;
const Color kUnifiedVenuesPill = AppColors.sokoVenue;
