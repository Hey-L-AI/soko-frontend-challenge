import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';

import '../../utils/zine_cover_recipe.dart';
import 'list_zine_tease_peel.dart';

/// Per-card probability used by the fallback hash gate when the host
/// doesn't pass an [indexInShelf]. Surfaces that DO pass an index get
/// the deterministic banded pattern in [_shouldPeel] instead, which is
/// stricter — exactly one peel per band.
const double _kListCoverPeelProbability = 0.25;

/// Size of bands 1+ in the deterministic shelf pattern. Band 0 is fixed
/// at 2 (the first-impression guarantee). Bands 1, 2, 3, ... contain
/// the next [_kBandSize] cards each and have exactly one peeler.
const int _kBandSize = 4;

/// Peak flip progress for list-cover peels on small cards (shelves,
/// search grid, smart-list grid). Smaller than the zine's 0.15 because
/// the cover artwork tile is small — a 0.15 peel would eat noticeably
/// into the cover.
const double _kListCoverPeelPeakProgress = 0.10;

/// Stable 32-bit FNV-1a hash. Used to deterministically decide whether
/// a given card peels and to derive its phase offset, so the same card
/// always behaves the same way and concurrent cards stagger.
int _fnv1a32(String s) {
  var hash = 0x811c9dc5;
  for (final code in s.codeUnits) {
    hash = (hash ^ code) & 0xffffffff;
    hash = (hash * 0x01000193) & 0xffffffff;
  }
  return hash;
}

/// Decorative overlay that hosts the corner-peel hint for any list-cover
/// card — Discovery shelves, search-result grids, smart-list grid,
/// hub grids, etc.
///
/// Drop this inside the host card's `Stack` as `Positioned.fill` (or
/// just as a child). It:
///
///   - skips entirely when [coverRecipe] is null (non-list cards don't
///     open the zine, so the page-turn affordance would be a lie),
///   - waits for the cover photo to load via [CachedNetworkImageProvider]
///     (shared cache with [CachedImage] under the hood) before
///     animating — never appears on top of a still-loading tile,
///   - guarantees a peel on index 0 OR 1 within its container (picked
///     by name hash) so the affordance is visible without scrolling,
///   - falls back to a ~25% probability gate for slots past the
///     first/second, with a phase offset so peeling cards don't
///     all hit peak at the same time.
///
/// Returns a zero-sized widget whenever the gate decides not to peel,
/// so it's safe to drop into every list-cover card unconditionally.
class ZineCoverPeelOverlay extends StatefulWidget {
  /// The cover's recipe. Null = not a list cover (e.g. venues / events)
  /// — the overlay renders nothing.
  final ZineCoverRecipe? coverRecipe;

  /// The list name — seeds the deterministic hash that drives both the
  /// peel-or-not decision and the phase offset.
  final String name;

  /// 0-based position of the host card within its row / grid / list.
  /// Ignored when [alwaysPeel] is true. When 0 or 1, one of them is
  /// guaranteed to peel (picked by hash bit). When null or >= 2, ~25%
  /// probability gate — only used if [alwaysPeel] is false.
  final int? indexInShelf;

  /// When true, every list cover peels (staggered by name hash). Library
  /// and the home-feed zine grid want the fold on every card, animating.
  final bool alwaysPeel;

  /// Border radius to clip the peel to — should match the host card's
  /// cover `ClipRRect`. Use [BorderRadius.zero] when the host doesn't
  /// clip its cover.
  final BorderRadius clipRadius;

  const ZineCoverPeelOverlay({
    super.key,
    required this.coverRecipe,
    required this.name,
    this.indexInShelf,
    this.alwaysPeel = false,
    this.clipRadius = BorderRadius.zero,
  });

  @override
  State<ZineCoverPeelOverlay> createState() => _ZineCoverPeelOverlayState();
}

class _ZineCoverPeelOverlayState extends State<ZineCoverPeelOverlay> {
  /// True once the cover photo is on screen — either it loaded (or
  /// failed, which falls back to the recipe's solid-colour cover), or
  /// the recipe had no photo to begin with.
  bool _coverReady = false;
  ImageStream? _coverStream;
  ImageStreamListener? _coverListener;

  @override
  void initState() {
    super.initState();
    _initCoverReadiness();
  }

  @override
  void didUpdateWidget(ZineCoverPeelOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    final newUrl = widget.coverRecipe?.photoUrl;
    final oldUrl = oldWidget.coverRecipe?.photoUrl;
    if (newUrl != oldUrl) {
      _detachCoverStream();
      _coverReady = false;
      _initCoverReadiness();
    }
  }

  @override
  void dispose() {
    _detachCoverStream();
    super.dispose();
  }

  void _initCoverReadiness() {
    final recipe = widget.coverRecipe;
    final photoUrl = recipe?.photoUrl;
    if (recipe == null || !recipe.hasPhoto || photoUrl == null) {
      _coverReady = true;
      return;
    }
    // Share the cover's cache: [CachedImage] uses [CachedNetworkImage]
    // backed by this provider, so the first listener kicks off the
    // network load (or a cache hit) and subsequent overlays on the
    // same URL resolve synchronously off the shared cache.
    final stream = CachedNetworkImageProvider(
      photoUrl,
    ).resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (info, _) => _markCoverReady(),
      onError: (error, _) => _markCoverReady(),
    );
    stream.addListener(listener);
    _coverStream = stream;
    _coverListener = listener;
  }

  void _markCoverReady() {
    if (!mounted || _coverReady) return;
    setState(() => _coverReady = true);
  }

  void _detachCoverStream() {
    final listener = _coverListener;
    if (listener != null) _coverStream?.removeListener(listener);
    _coverStream = null;
    _coverListener = null;
  }

  bool _shouldPeel(int hash) {
    if (widget.coverRecipe == null) return false;
    if (!_coverReady) return false;
    if (widget.alwaysPeel) return true;
    final idx = widget.indexInShelf;
    if (idx == null) {
      // No position awareness — fall back to per-card probability gate.
      // Used by call sites that don't (yet) plumb an index.
      return (hash & 0xffff) / 0xffff < _kListCoverPeelProbability;
    }
    // Deterministic banded pattern — exactly one peel per band.
    //
    //   Band 0: indices [0, 1]            → card 0 always peels.
    //           Guarantees a first-impression hint the user can't
    //           miss without scrolling.
    //   Band N≥1: indices [2 + (N-1)·4 ... 1 + N·4] (size 4)
    //           → position cycles 0, 1, 2, 3, 0, 1, 2, 3 across
    //           bands so peelers don't all line up in the same
    //           column.
    if (idx < 2) {
      return idx == 0;
    }
    final bandIndex = 1 + (idx - 2) ~/ _kBandSize;
    final positionInBand = (idx - 2) % _kBandSize;
    final pickPosition = bandIndex % _kBandSize;
    return positionInBand == pickPosition;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.coverRecipe == null) return const SizedBox.shrink();
    final hash = _fnv1a32(widget.name);
    if (!_shouldPeel(hash)) return const SizedBox.shrink();
    final peelPhase = ((hash >> 16) & 0xffff) / 0xffff;
    final peel = ListZineTeasePeel(
      peakRealFlipProgress: _kListCoverPeelPeakProgress,
      initialProgress: peelPhase,
    );
    if (widget.clipRadius == BorderRadius.zero) return peel;
    return ClipRRect(borderRadius: widget.clipRadius, child: peel);
  }
}
