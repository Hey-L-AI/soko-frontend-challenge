// Unified search — the one results engine shared by every catalogue-searching
// surface (feed, library, and any future one). Given a query + an optional
// category filter it fans out ([fetchUnifiedContent]), groups the hits into the
// standard sectioned list ([UnifiedSearchResults]), and routes row taps to the
// detail pages. Onboarding keeps its own thin host only because it adds the
// like button + close-on-like + hero flight; the *rows it draws are these rows*.
//
// This is what makes library / feed / onboarding render byte-for-byte the same
// results — sections, iconed pills, pop expander — rather than three look-alikes.

import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../features/lists/widgets/guest_blur_cta_card.dart';
import 'unified_content_search.dart';
import 'unified_search_labels.dart';
import 'unified_search_models.dart';
import 'unified_search_result_row.dart';
import 'unified_search_results.dart';

/// The full offered set, in render order (events → places → zines → people).
const List<SokoSearchCategory> kUnifiedContentCategories = <SokoSearchCategory>[
  SokoSearchCategory.events,
  SokoSearchCategory.venues,
  SokoSearchCategory.zines,
  SokoSearchCategory.people,
];

/// Guests see this many crisp rows before the sign-in wall.
const int _kGuestVisibleCount = 4;
const double _kGuestBlurSigma = 8;

class UnifiedContentResultsView extends ConsumerStatefulWidget {
  const UnifiedContentResultsView({
    super.key,
    required this.query,
    this.selectedCategory,
    this.categories = kUnifiedContentCategories,
    this.source = const CatalogueUnifiedSearchSource(),
    this.latitude,
    this.longitude,
    this.perCategory = 12,
    this.guestWall = false,
    this.emptyLabel,
    this.showLike = false,
    this.provenance,
    this.onLikeToggled,
    this.onOpen,
    this.onDismiss,
  });

  /// The (already-trimmed/debounced) query. Empty renders nothing.
  final String query;

  /// Where rows come from. Defaults to Soko's global catalogue; a surface can
  /// pass its own (e.g. the library's saved-items source) to reuse this UI with
  /// scoped data.
  final UnifiedContentSearchSource source;

  /// Active chip filter, or null for "all offered categories".
  final SokoSearchCategory? selectedCategory;

  /// Offered categories, in render order.
  final List<SokoSearchCategory> categories;

  final double? latitude;
  final double? longitude;
  final int perCategory;

  /// Apply the guest sign-in wall (crisp head + blurred tail + CTA).
  final bool guestWall;

  /// Overrides the "No results for X" empty copy.
  final String? emptyLabel;

  /// Add-ons (onboarding): show the thumbs-up like on rows, tagged [provenance],
  /// and report toggles via [onLikeToggled].
  final bool showLike;
  final String? provenance;
  final void Function(UnifiedSearchRow row, bool nowLiked)? onLikeToggled;

  /// Intercepts a row tap. Return true if handled (skips the default detail
  /// routing); false/null falls through to the default route for that category.
  /// Onboarding handles events/places (its own detail page) and lets zines /
  /// people route normally.
  final bool Function(UnifiedSearchRow row)? onOpen;

  /// Closes the hosting overlay (if any) before a default-path navigation, so
  /// the pushed detail isn't left under the overlay's dim barrier. Null when the
  /// results aren't hosted in a dismissable overlay (e.g. the in-page feed
  /// morph). Taps a host fully handles via [onOpen] own their own dismissal.
  final VoidCallback? onDismiss;

  @override
  ConsumerState<UnifiedContentResultsView> createState() =>
      _UnifiedContentResultsViewState();
}

class _UnifiedContentResultsViewState
    extends ConsumerState<UnifiedContentResultsView> {
  bool _loading = false;
  Map<SokoSearchCategory, List<UnifiedSearchRow>> _rows = const {};
  CancelToken? _cancel;
  final Set<SokoSearchCategory> _expanded = {};
  String? _fetchedFor;

  @override
  void initState() {
    super.initState();
    _maybeFetch();
  }

  @override
  void didUpdateWidget(UnifiedContentResultsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.query != widget.query ||
        oldWidget.selectedCategory != widget.selectedCategory) {
      _maybeFetch();
    }
  }

  @override
  void dispose() {
    _cancel?.cancel();
    super.dispose();
  }

  Set<SokoSearchCategory> get _wanted => widget.selectedCategory != null
      ? {widget.selectedCategory!}
      : widget.categories.toSet();

  String get _fetchKey =>
      '${widget.query}|${widget.selectedCategory?.name ?? "all"}';

  Future<void> _maybeFetch() async {
    final key = _fetchKey;
    if (key == _fetchedFor) return;
    _fetchedFor = key;
    _expanded.clear();
    final q = widget.query.trim();
    if (q.isEmpty) {
      _cancel?.cancel();
      setState(() {
        _rows = const {};
        _loading = false;
      });
      return;
    }
    _cancel?.cancel();
    final cancel = _cancel = CancelToken();
    setState(() => _loading = true);
    try {
      final rows = await widget.source.fetch(
        ref: ref,
        query: q,
        categories: _wanted,
        latitude: widget.latitude,
        longitude: widget.longitude,
        perCategory: widget.perCategory,
        cancelToken: cancel,
        navigate: _navigate,
      );
      if (!mounted || cancel.isCancelled) return;
      setState(() {
        _rows = rows;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || cancel.isCancelled) return;
      setState(() => _loading = false);
    }
  }

  /// Route a row tap. Gives the host first refusal (onboarding routes
  /// events/places to its own detail); otherwise pushes the source's route.
  void _navigate(UnifiedSearchRow row, String route, {Object? extra}) {
    if (widget.onOpen?.call(row) ?? false) return;
    // Default path: close the hosting overlay (if any) before navigating so the
    // detail isn't pushed under the dim barrier. Capture the router first — the
    // pop makes this context defunct.
    final router = GoRouter.of(context);
    widget.onDismiss?.call();
    router.push(route, extra: extra);
  }

  void _toggleExpand(SokoSearchCategory category) {
    setState(() {
      if (!_expanded.remove(category)) _expanded.add(category);
    });
  }

  List<UnifiedSearchRow> _rowsFor(SokoSearchCategory category) =>
      _rows[category] ?? const [];

  List<UnifiedSearchSection> _sections(Lt l10n) {
    final out = <UnifiedSearchSection>[];
    for (final category in widget.categories) {
      if (widget.selectedCategory != null &&
          widget.selectedCategory != category) {
        continue;
      }
      final rows = _rowsFor(category);
      if (rows.isEmpty) continue;
      out.add(
        UnifiedSearchSection(
          category: category,
          label: unifiedSectionLabel(l10n, category),
          rows: rows,
          expanded: _expanded.contains(category),
          onToggleExpand: rows.length > kUnifiedSearchCollapsedCount
              ? () => _toggleExpand(category)
              : null,
        ),
      );
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final sections = _sections(l10n);
    final isGuest = widget.guestWall && !ref.watch(isAuthenticatedProvider);

    if (isGuest && sections.any((s) => s.rows.isNotEmpty)) {
      return _GuestClamped(sections: sections);
    }

    return UnifiedSearchResults(
      sections: sections,
      loading: _loading,
      query: widget.query,
      emptyLabel:
          widget.emptyLabel ?? l10n.discoverySearchNoResults(widget.query),
      expanderLabel: (ctx, c) => unifiedExpanderLabel(Lt.of(ctx), c),
      collapseLabel: unifiedCollapseLabel(l10n),
      showLikeButtons: widget.showLike,
      provenance: widget.provenance,
      onLikeToggled: widget.onLikeToggled,
    );
  }
}

/// Guest wall across the grouped sections: the first [_kGuestVisibleCount] rows
/// (in section order) crisp, everything after blurred + pointer-blocked behind a
/// sign-in CTA. Section pills stay crisp so the shape of what's behind the wall
/// is legible.
class _GuestClamped extends StatelessWidget {
  const _GuestClamped({required this.sections});

  final List<UnifiedSearchSection> sections;

  @override
  Widget build(BuildContext context) {
    final crisp = <Widget>[];
    final blurred = <Widget>[];
    var shown = 0;

    for (final section in sections) {
      if (section.rows.isEmpty) continue;
      final target = shown < _kGuestVisibleCount ? crisp : blurred;
      if (target.isNotEmpty) target.add(const SizedBox(height: 16));
      target.add(
        Align(
          alignment: Alignment.centerLeft,
          child: UnifiedSectionPill(
            category: section.category,
            label: section.label,
          ),
        ),
      );
      target.add(const SizedBox(height: 10));
      for (final row in section.rows) {
        final into = shown < _kGuestVisibleCount ? crisp : blurred;
        into.add(
          UnifiedSearchResultRow(
            key: ValueKey(row.rowKey),
            row: row,
            category: section.category,
          ),
        );
        shown++;
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ...crisp,
        if (blurred.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Stack(
              children: [
                ClipRect(
                  child: ImageFiltered(
                    imageFilter: ui.ImageFilter.blur(
                      sigmaX: _kGuestBlurSigma,
                      sigmaY: _kGuestBlurSigma,
                    ),
                    child: IgnorePointer(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        mainAxisSize: MainAxisSize.min,
                        children: blurred,
                      ),
                    ),
                  ),
                ),
                Positioned.fill(
                  child: Align(
                    alignment: Alignment.topCenter,
                    child: Padding(
                      padding: const EdgeInsets.only(
                        top: 24,
                        left: 24,
                        right: 24,
                      ),
                      child: const GuestBlurCtaCard(),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
