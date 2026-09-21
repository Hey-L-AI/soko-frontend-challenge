// Unified search — the full stand-alone search surface: input pill + the toggle
// filter chips + the shared grouped results. Drop it in anywhere a surface wants
// "the same search as everywhere else" without wiring the pieces itself (the
// library uses it; onboarding and the feed compose the parts by hand because
// they add a like button / live inside a morphing row).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../l10n/generated/l10n.dart';
import '../soko_search_input_pill.dart';
import '../soko_tag_chip.dart';
import 'unified_content_results_view.dart';
import 'unified_content_search.dart'
    show CatalogueUnifiedSearchSource, UnifiedContentSearchSource;
import 'unified_search_labels.dart';
import 'unified_search_models.dart';

class UnifiedContentSearch extends ConsumerStatefulWidget {
  const UnifiedContentSearch({
    super.key,
    required this.hintText,
    this.categories = kUnifiedContentCategories,
    this.source = const CatalogueUnifiedSearchSource(),
    this.showCategoryChips = true,
    this.latitude,
    this.longitude,
    this.guestWall = false,
    this.autofocus = true,
    this.onCloseWhenEmpty,
    this.debounce = const Duration(milliseconds: 300),
    this.fillHeight = false,
    this.inputHeroTag,
    this.inputHeroFlightShuttleBuilder,
    this.showLike = false,
    this.provenance,
    this.onLikeToggled,
    this.onOpen,
    this.onSearch,
    this.emptyLabel,
    this.onDismiss,
  });

  final String hintText;
  final List<SokoSearchCategory> categories;

  /// Where rows come from — defaults to Soko's global catalogue. Pass a scoped
  /// source (e.g. the library's) to reuse this UI with different data.
  final UnifiedContentSearchSource source;

  /// Whether the category toggle-chip row is shown. Off for surfaces that carry
  /// their own scope control (the library, whose filter bar sets scope and is
  /// already applied by its source).
  final bool showCategoryChips;

  final double? latitude;
  final double? longitude;
  final bool guestWall;
  final bool autofocus;

  /// Add-ons (onboarding): thumbs-up like on rows, tagged [provenance], toggle
  /// reports via [onLikeToggled]; [onOpen] intercepts a row tap (return true if
  /// handled); [onSearch] fires once per settled non-empty query; [emptyLabel]
  /// overrides the empty-state copy.
  final bool showLike;
  final String? provenance;
  final void Function(UnifiedSearchRow row, bool nowLiked)? onLikeToggled;
  final bool Function(UnifiedSearchRow row)? onOpen;
  final void Function(String query)? onSearch;
  final String? emptyLabel;

  /// Called when the ✕ is tapped on an already-empty field — the host closes the
  /// search surface. When null the ✕ only ever clears.
  final VoidCallback? onCloseWhenEmpty;

  /// Closes the hosting overlay before a default-path result tap navigates.
  /// Forwarded to [UnifiedContentResultsView.onDismiss]; null for non-overlay hosts.
  final VoidCallback? onDismiss;

  final Duration debounce;

  /// When true, the input pill + chips stay pinned at the top and only the
  /// results scroll beneath them (the overlay's behaviour). Requires a bounded
  /// height from the host (the overlay panel's `ConstrainedBox`). When false the
  /// whole thing is an intrinsic column the host scrolls.
  final bool fillHeight;

  /// When set, the input pill is wrapped in a [Hero] so the collapsed entry
  /// (feed circle / library search icon) flies into it. Autofocus is deferred
  /// until the flight settles so the keyboard doesn't fight the animation.
  final Object? inputHeroTag;
  final HeroFlightShuttleBuilder? inputHeroFlightShuttleBuilder;

  @override
  ConsumerState<UnifiedContentSearch> createState() =>
      _UnifiedContentSearchState();
}

class _UnifiedContentSearchState extends ConsumerState<UnifiedContentSearch> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  Timer? _debounceTimer;
  Timer? _focusTimer;

  String _debounced = '';
  String _lastText = '';
  SokoSearchCategory? _selected;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onChanged);
    if (widget.autofocus) {
      // With a Hero flight, focus AFTER it settles so the keyboard doesn't pop
      // mid-animation and fight it. Without one, focus next frame as before.
      if (widget.inputHeroTag != null) {
        _focusTimer = Timer(const Duration(milliseconds: 280), () {
          if (mounted) _focusNode.requestFocus();
        });
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _focusNode.requestFocus();
        });
      }
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _debounceTimer?.cancel();
    _focusTimer?.cancel();
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged() {
    final text = _controller.text;
    if (text == _lastText) return;
    _lastText = text;
    final q = text.trim();
    _debounceTimer?.cancel();
    _debounceTimer = Timer(widget.debounce, () {
      if (!mounted || _debounced == q) return;
      setState(() => _debounced = q);
      if (q.isNotEmpty) widget.onSearch?.call(q);
    });
  }

  void _onClear() {
    if (_controller.text.isNotEmpty) {
      _controller.clear();
    } else {
      widget.onCloseWhenEmpty?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final results = UnifiedContentResultsView(
      query: _debounced,
      selectedCategory: _selected,
      categories: widget.categories,
      source: widget.source,
      latitude: widget.latitude,
      longitude: widget.longitude,
      guestWall: widget.guestWall,
      emptyLabel: widget.emptyLabel,
      showLike: widget.showLike,
      provenance: widget.provenance,
      onLikeToggled: widget.onLikeToggled,
      onOpen: widget.onOpen,
      onDismiss: widget.onDismiss,
    );
    Widget inputPill = SokoSearchInputPill(
      controller: _controller,
      focusNode: _focusNode,
      hintText: widget.hintText,
      clearSemanticLabel: l10n.discoveryActionBarSearchClose,
      onClear: _onClear,
    );
    if (widget.inputHeroTag != null) {
      inputPill = Hero(
        tag: widget.inputHeroTag!,
        flightShuttleBuilder: widget.inputHeroFlightShuttleBuilder,
        child: Material(type: MaterialType.transparency, child: inputPill),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        inputPill,
        if (widget.showCategoryChips) ...[
          const SizedBox(height: 12),
          SokoTagBar(
            items: [
              for (final category in widget.categories)
                SokoTagBarItem(
                  id: category,
                  child: SokoTagChip(
                    label: unifiedChipLabel(l10n, category),
                    icon: category.icon,
                    selected: category == _selected,
                    onTap: () => setState(
                      () => _selected = _selected == category ? null : category,
                    ),
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        // Pinned mode (overlay): input + chips stay put, the results shrink to
        // content and scroll once they exceed the bounded panel. Intrinsic mode:
        // the host scrolls the whole column.
        if (widget.fillHeight)
          Flexible(child: SingleChildScrollView(child: results))
        else
          results,
      ],
    );
  }
}
