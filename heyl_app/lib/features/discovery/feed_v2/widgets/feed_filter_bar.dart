// PROD-4005 / PROD-4081 — the "Procura" + filter bar (D29/D38, Figma
// `7598-24582`).
//
// **Rebuilt onto `SokoTagBar` (PROD-4081).** It used to be five equal columns
// of icon-above-label, each ellipsizing when its share ran out — which is how
// "Pessoas" came to clip on a narrow phone. It is now content-sized chips in a
// horizontally scrolling row: the labels always render in full and the row
// scrolls instead. That row is shared with "Descobre a cidade" and the Procura
// screen, so all three surfaces carry one control.
//
// `Procura` is the icon-only circle at the head of the row — not a filter, and
// live only where a host wires [FeedFilterBar.onProcura]. It used to push its
// own screen (D121); since PROD-4179 it puts THIS row into Procura mode, and
// the circle grows into the search input. `Eventos`, `Sítios`, `Zines` and —
// since PROD-4447 — `Pessoas` are the enabled FILTERS. All four are live; the
// `disabledHint` path below is kept because the gate itself still exists
// (`FeedFilter.isEnabledInV0`), and the next filter to be built will need it.
//
// **The row means two different things depending on [FeedFilterBar.procuraT].**
// At rest the chips write `feedFilterProvider` (which feed to compose). In
// Procura mode they write `procuraSearchCategoryProvider` (which corpus to
// search) — and, only while nothing is typed, the feed filter too, so the feed
// still visible underneath agrees with the chip above it.
//
// **`Pessoas` used to be live on the search screens and greyed here** (D131),
// because the two surfaces gate on different things: a search CATEGORY needs a
// query endpoint, which people search has always had, while a feed FILTER needs
// a lead block type, and `/feed/home?filter=people` had none to return. That is
// no longer a gap — PROD-4441 built the `people_grid` block and PROD-4449 serves
// it, so the tile is enabled and the two surfaces finally agree.
//
// ⚠️ The order that mattered: the tile was flipped only after the endpoint was
// verified **live on staging**, not merely merged. Flipping first ships a filter
// that 422s. See `FeedFilter.isEnabledInV0`.

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../data/models/feed_home.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../shared/widgets/search/unified_search_overlay.dart'
    show kFeedSearchHeroTag, unifiedSearchHeroFlightShuttle;
import '../../../../shared/widgets/soko_tag_chip.dart';
import '../../providers/search_category_provider.dart';
import '../providers/feed_filter_provider.dart';
import '../providers/procura_search_providers.dart';

/// Row height. An alias of [kSokoTagChipHeight] — the bar is as tall as the
/// chips in it, and that number belongs to the shared component now. Kept so
/// feed code and its tests can keep naming the thing they measure.
const double kFeedFilterBarHeight = kSokoTagChipHeight;

/// One entry in the bar. `Procura` is not a [FeedFilter] — it is the existing
/// "Discover the city" entry point (D5), rendered here so the row matches the
/// design, and disabled in v0 like the other three.
@immutable
class FeedFilterEntry {
  final IconData icon;
  final String Function(Lt) label;

  /// Null for `Procura`, which is an entry point rather than a filter value.
  final FeedFilter? filter;

  const FeedFilterEntry({required this.icon, required this.label, this.filter});

  /// The one entry that is an entry point rather than a filter value. Its
  /// enablement is the host's to decide (`onProcura`), not this table's — see
  /// [FeedFilterBar.onProcura].
  bool get isProcura => filter == null;

  /// Whether this entry selects a filter the app can actually render. Answers
  /// `false` for `Procura`, which selects nothing.
  bool get isEnabled => filter?.isEnabledInV0 ?? false;

  /// The search CATEGORY this tile means once the row is in Procura mode
  /// (PROD-4179). Null for `Procura` itself, which is not a tile there at all.
  ///
  /// The two enums stay separate on purpose — see the bridge's warning in
  /// [FeedFilterBar._onTapFor] — so this is a lookup, never an implicit cast.
  DiscoverySearchCategory? get category {
    final f = filter;
    return f == null ? null : searchCategoryForFeedFilter(f);
  }
}

/// The search category that means the same thing as [filter].
///
/// Used twice, and the pairing must be identical in both: the chips read it to
/// decide which one is selected, and entering Procura reads it to carry the
/// feed the reader was looking at into the search (Zé, 2026-09-03) — arriving
/// on the Sítios feed and finding `Eventos` selected is the search silently
/// changing what they asked for.
DiscoverySearchCategory searchCategoryForFeedFilter(FeedFilter filter) =>
    switch (filter) {
      FeedFilter.events => DiscoverySearchCategory.eventos,
      FeedFilter.venues => DiscoverySearchCategory.sitios,
      FeedFilter.zines => DiscoverySearchCategory.zines,
      FeedFilter.people => DiscoverySearchCategory.leitores,
    };

const List<FeedFilterEntry> kFeedFilterEntries = [
  FeedFilterEntry(icon: LucideIcons.search, label: _procura),
  FeedFilterEntry(
    icon: LucideIcons.calendar,
    label: _eventos,
    filter: FeedFilter.events,
  ),
  FeedFilterEntry(
    icon: LucideIcons.map_pin,
    label: _sitios,
    filter: FeedFilter.venues,
  ),
  FeedFilterEntry(
    icon: LucideIcons.book_open,
    label: _zines,
    filter: FeedFilter.zines,
  ),
  FeedFilterEntry(
    icon: LucideIcons.user,
    label: _pessoas,
    filter: FeedFilter.people,
  ),
];

String _procura(Lt l) => l.feedFilterProcura;
String _eventos(Lt l) => l.feedFilterEventos;
String _sitios(Lt l) => l.feedFilterSitios;
String _zines(Lt l) => l.feedFilterZines;
String _pessoas(Lt l) => l.feedFilterPessoas;

class FeedFilterBar extends ConsumerWidget {
  /// Called after a selection so the host can dismiss the overlay (D38).
  final VoidCallback? onSelected;

  /// PROD-4081 — opens the Procura search screen (D121).
  ///
  /// **Null leaves the tile disabled**, which is deliberate rather than
  /// defensive: `Procura` selects no filter, so this callback is the only thing
  /// it can possibly do, and a host that has not wired a destination has no
  /// business rendering it as tappable. That also keeps the bar honest in
  /// tests and anywhere it is mounted without a router above it.
  final VoidCallback? onProcura;

  /// PROD-4179 — how far into Procura mode the row is. 0 is the filter row.
  ///
  /// Anything above 0 flips what the chips *mean*, immediately rather than at
  /// the end of the animation: the user has already committed by the time the
  /// morph starts, and a chip that still changed the feed filter halfway
  /// through would act on the wrong provider for a fifth of a second.
  final double procuraT;

  /// Whether to draw the leading circle.
  ///
  /// False from the first frame of the morph, because [FeedProcuraRow] lifts
  /// the circle out of this scrolling row and animates it separately. The row
  /// does not know that; it just stops drawing it.
  final bool includeProcuraChip;

  /// The row's own motion (PROD-4201).
  ///
  /// Defaults to develop's `reveal` — the unfold Zé asked for on the feed. The
  /// Procura morph passes `standard` once it has run; see the note at the
  /// `SokoTagBar` below for why the two cannot both animate.
  final SokoTagBarMotion motion;

  /// Drives the underlying [SokoTagBar]'s horizontal position.
  ///
  /// `FeedProcuraRow` uses it to return the row to offset 0 as the morph
  /// starts. Without that, a row the user had scrolled would have its circle
  /// somewhere other than the margin, and the lifted circle the morph draws AT
  /// the margin would appear to teleport there.
  final ScrollController? rowController;

  /// Unified-search: wrap the Procura circle in the search Hero so it flies into
  /// the overlay's input. Only the inline chrome copy sets this.
  final bool heroCircle;

  const FeedFilterBar({
    super.key,
    this.onSelected,
    this.onProcura,
    this.procuraT = 0,
    this.includeProcuraChip = true,
    this.rowController,
    this.motion = SokoTagBarMotion.reveal,
    this.heroCircle = false,
  });

  /// Wrap the Procura circle in the search Hero when this copy owns it.
  Widget _maybeHero(Widget child) {
    if (!heroCircle) return child;
    return Hero(
      tag: kFeedSearchHeroTag,
      flightShuttleBuilder: unifiedSearchHeroFlightShuttle,
      child: child,
    );
  }

  /// Whether the chips currently select a search category rather than a feed
  /// filter.
  bool get _inProcura => procuraT > 0;

  /// What a tap on [entry] does here, or null if it does nothing.
  ///
  /// A filter change calls [onSelected], which closes the bar per D38.
  ///
  /// ⚠️ **`Procura` deliberately does not.** It used to: the tile pushed a
  /// route, and leaving the row open behind it meant coming back to a filter
  /// row the reader never dismissed. Since PROD-4179 it navigates nowhere — it
  /// turns THIS row into the search chrome — so closing the row is closing the
  /// thing the reader is about to use, and the ✕ then drops them onto a bare
  /// pinned bar instead of the row they opened (Zé, 2026-09-03).
  VoidCallback? _onTapFor(FeedFilterEntry entry, WidgetRef ref) {
    if (entry.isProcura) {
      final open = onProcura;
      if (open == null) return null;
      return open;
    }
    if (_inProcura) {
      final category = entry.category;
      if (category == null) return null;
      return () {
        // Unified-search: the chips are TOGGLE FILTERS over the grouped
        // results. They start deselected (null = every section shows); tapping
        // narrows to one category, re-tapping the active one clears back to all.
        final current = ref.read(procuraSearchCategoryProvider);
        ref.read(procuraSearchCategoryProvider.notifier).state =
            current == category ? null : category;
        // No `onSelected` — that closes the row (D38), and picking a category
        // mid-search is not a "done" action.
      };
    }
    if (!entry.isEnabled) return null;
    return () {
      // Changing filter refetches from the backend (D4) — `feedHomeProvider`
      // watches this and rebuilds. The chrome does not watch it, so a filter
      // change leaves the headers in place and only the feed area shows a
      // loading state (D16).
      ref.read(feedFilterProvider.notifier).state = entry.filter!;
      onSelected?.call();
    };
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    // Watch only the one that is driving the row, so a feed-filter change made
    // by the bridge above does not rebuild every chip a second time.
    final activeFilter = _inProcura ? null : ref.watch(feedFilterProvider);
    final activeCategory = _inProcura
        ? ref.watch(procuraSearchCategoryProvider)
        : null;

    return SokoTagBar(
      // develop's structure (PROD-4201), this ticket's behaviour grafted in.
      //
      // ⚠️ **`motion` is not always `reveal`, and that is the load-bearing part
      // of this reconciliation.** `reveal` is a MEASURED motion: the bar
      // positions each slot itself and animates any insertion or removal over
      // 600 ms. The Procura morph removes the leading chip and puts it back —
      // so with `reveal` left on, the bar would slide the chips left over
      // 600 ms while `FeedProcuraRow` translates the same chips left over
      // 240 ms. Two animations on the same pixels, and a clean merge either
      // way. The morph therefore hands `standard` once it has run; the mount
      // entrance Zé asked for still plays, because it plays on mount and the
      // morph has not happened yet.
      motion: motion,
      controller: rowController,
      items: [
        for (final entry in kFeedFilterEntries)
          // A collection-`if` that omits the chip ENTIRELY rather than handing
          // the bar an empty child: a slot with no content still occupies a
          // slot and contributes its gap, leaving 6 px of nothing at the head
          // of the row for the whole morph.
          if (!entry.isProcura || includeProcuraChip)
            SokoTagBarItem(
              id: entry.filter ?? 'procura',
              child: entry.isProcura
                  // Icon-only, circular, and NOT a filter. The label is its
                  // accessible name because the chip has no text.
                  ? _maybeHero(
                      SokoTagIconChip(
                        icon: entry.icon,
                        semanticsLabel: entry.label(l10n),
                        enabled: onProcura != null,
                        onTap: _onTapFor(entry, ref),
                      ),
                    )
                  : SokoTagChip(
                      label: entry.label(l10n),
                      icon: entry.icon,
                      selected: _inProcura
                          ? entry.category == activeCategory
                          : entry.filter == activeFilter,
                      // **Every tile is live in Procura mode**, `Pessoas`
                      // included: a search category needs a query endpoint and
                      // people search has one. Only the FEED filter needs a
                      // lead block type (D131).
                      enabled: _inProcura || entry.isEnabled,
                      disabledHint: l10n.feedFilterDisabledHint,
                      onTap: _onTapFor(entry, ref),
                    ),
            ),
      ],
    );
  }
}
