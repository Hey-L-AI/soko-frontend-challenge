// PROD-4179 — the filter row and the Procura search chrome, as ONE row that
// morphs between them (D-number pending; Zé, 2026-09-03).
//
// Before this, `Procura` pushed `/feed/search` and the two chromes were two
// screens. They are now two ends of a single animation on the feed itself:
//
//   t = 0   [🔍] [Eventos] [Sítios] [Zines] [Pessoas]
//   t = 1   [ 🔍  Pesquisa por título              ✕ ]
//           [Eventos] [Sítios] [Zines] [Pessoas]
//           [ Qualquer altura ⌄ ] [ Música ] [ Artes… ]
//
// Three movements, and their reverse on the way out:
//
//   1. the four chips slide down a row and left by the circle's width;
//   2. the circle expands slightly, then grows into the input pill;
//   3. the facet strips — which live under the chips at BOTH ends — stay put.
//
// **Why one widget rather than a cross-fade between two.** The chips are the
// same four `SokoTagChip`s at both ends, so a cross-fade would draw each of
// them twice, slightly offset — ghosting, not motion. Here they keep their
// element identity and simply move, which is what makes the transition read as
// the elements changing place.
//
// ⚠️ **The `t == 0` tree is deliberately different in ONE way**: the circle is
// *inside* the scrolling row, exactly as it shipped, so it scrolls with the
// chips on a narrow phone. From `t > 0` it is lifted out and positioned. The
// two agree at the seam because the lifted circle starts at the row's own
// margin and the chips' translation starts at exactly the width the circle
// occupied — see [_kLeadShift]. The row is also scrolled back to 0 as the morph
// starts, so "where the circle was" is answerable at all.

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../shared/widgets/soko_search_input_pill.dart';
import '../../../../shared/widgets/soko_tag_chip.dart';
import 'feed_filter_bar.dart';

/// How far the chips travel horizontally: the circle's width plus the row's
/// gap. At `t = 0` they sit that much to the right of the margin because the
/// circle is in front of them; at `t = 1` they start on the margin.
const double _kLeadShift = kSokoTagChipHeight + kSokoTagChipGap;

/// Gap between the input pill and the chips at `t = 1`, matching the Procura
/// screen's `SearchOverlay` column.
const double kProcuraInputChipsGap = 12;

/// Vertical distance the chips travel: the pill plus that gap.
const double _kChipDrop = kSokoSearchInputHeight + kProcuraInputChipsGap;

/// Chip-row height, re-exported under the name this file's geometry uses.
const double _kChipRow = kSokoTagChipHeight;

/// The morphing row.
///
/// [t] is 0 at the filter row and 1 at the Procura chrome. The page drives it
/// with an implicit tween, and hands the same value to both copies of the row
/// (the inline sliver and the pinned header's `below:` slot) so they cannot
/// disagree about where in the transition they are.
class FeedProcuraRow extends ConsumerStatefulWidget {
  /// 0 → filter row, 1 → search chrome. Everything else is the transition.
  final double t;

  /// The controller + focus node the input pill binds to. Owned by the page, so
  /// the text survives the row being rebuilt — and so the two mounted copies
  /// share one query rather than each keeping its own.
  final TextEditingController controller;
  final FocusNode focusNode;

  /// Enters Procura mode. Null leaves the circle disabled, exactly as
  /// [FeedFilterBar.onProcura] does — a row with nowhere to go must not look
  /// tappable.
  final VoidCallback? onProcura;

  /// Leaves Procura mode. Wired to the pill's ✕, which exits on the FIRST tap.
  final VoidCallback onExit;

  /// Called after a chip selection at `t == 0`, so the host can dismiss the
  /// overlay copy of the row (D38). Not called in Procura mode: picking a
  /// category there is not a "done" action.
  final VoidCallback? onFilterSelected;

  /// The facet strips for the selected FEED FILTER, or null when it has none
  /// (`Zines` / `Pessoas`). Rendered under the chips at every [t] — they are
  /// part of the resting row, not something the search chrome brings with it.
  final Widget? facets;

  /// Unified-search: wrap the Procura circle in the search Hero so it flies into
  /// the overlay's input. Only the inline copy sets this — the chrome is mounted
  /// twice and two Heroes with one tag would collide.
  final bool heroCircle;

  const FeedProcuraRow({
    super.key,
    required this.t,
    required this.controller,
    required this.focusNode,
    required this.onExit,
    this.onProcura,
    this.onFilterSelected,
    this.facets,
    this.heroCircle = false,
  });

  /// Height of the row at [t], excluding the facets.
  ///
  /// Used by the page to size the pinned block's `below:` slot, which is how
  /// the bar's reveal threshold stays true while the chrome is taller.
  static double leadExtentFor(double t) => _kChipRow + _kChipDrop * t;

  @override
  ConsumerState<FeedProcuraRow> createState() => _FeedProcuraRowState();
}

class _FeedProcuraRowState extends ConsumerState<FeedProcuraRow> {
  /// The chip row's horizontal position. Reset to 0 the moment the morph
  /// begins — see [FeedFilterBar.rowController].
  final ScrollController _rowController = ScrollController();

  /// Whether the morph has ever run.
  ///
  /// Once it has, the row drops `SokoTagBarMotion.reveal` for `standard`. The
  /// morph inserts and removes the leading chip, and `reveal` is a MEASURED
  /// motion that animates exactly that over 600 ms — against this widget's own
  /// 240 ms translate of the same chips. The mount entrance PROD-4201 added
  /// still plays, because it plays on mount and this is false until the reader
  /// first taps `Procura`.
  bool _hasMorphed = false;

  @override
  void didUpdateWidget(FeedProcuraRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Only on the 0 → moving edge. Doing it on every frame of the transition
    // would fight a user who flicks the row while it is animating.
    if (oldWidget.t <= 0 && widget.t > 0) {
      if (_rowController.hasClients) _rowController.jumpTo(0);
      if (!_hasMorphed) {
        // After this frame, not during it: `didUpdateWidget` runs inside the
        // build phase this update belongs to.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _hasMorphed = true);
        });
      }
    }
  }

  @override
  void dispose() {
    _rowController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final atRest = widget.t <= 0;

    // The lead's growth, held back briefly so the circle can bulge first. The
    // two intervals overlap: the bulge is still easing out as the box starts to
    // stretch, which is what makes it one gesture rather than two.
    final bulge = _pulse(_interval(widget.t, 0, 0.35));
    final morph = Curves.easeInOut.transform(_interval(widget.t, 0.18, 1));
    // The field only appears once there is a pill to put it in.
    final fieldIn = _interval(widget.t, 0.55, 1);

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final leadWidth = _lerp(
          kSokoTagChipHeight + 4 * bulge,
          width - 2 * kSokoTagBarMargin,
          morph,
        );
        final leadHeight = _lerp(
          kSokoTagChipHeight + 4 * bulge,
          kSokoSearchInputHeight,
          morph,
        );
        final leadRadius = _lerp(
          kSokoTagChipHeight / 2,
          kSokoSearchInputRadius,
          morph,
        );

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: FeedProcuraRow.leadExtentFor(widget.t),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 0,
                    right: 0,
                    top: _kChipDrop * widget.t,
                    height: _kChipRow,
                    child: Transform.translate(
                      offset: Offset(
                        atRest ? 0 : _kLeadShift * (1 - widget.t),
                        0,
                      ),
                      child: _chips(atRest: atRest),
                    ),
                  ),
                  if (!atRest)
                    Positioned(
                      left: kSokoTagBarMargin,
                      top: 0,
                      width: leadWidth,
                      height: leadHeight,
                      child: _lead(
                        l10n,
                        leadRadius,
                        fieldIn,
                        width - 2 * kSokoTagBarMargin,
                      ),
                    ),
                ],
              ),
            ),
            // **Rendered at every [t], including at rest.** The strips used to
            // grow in with the morph (`t > 0`) because they belonged to the
            // typed search; they now belong to the RESTING filter row — the
            // reader picks `Música` on the feed's own chips and gets results —
            // so they are part of the row at both ends of the animation and
            // there is nothing left to grow. The host decides whether there is
            // a strip at all (null for the categories that carry none), which
            // is what makes the block change height when the filter changes.
            if (widget.facets != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: widget.facets,
              ),
          ],
        );
      },
    );
  }

  /// The lead element: a circle that becomes the input pill.
  ///
  /// Below the point where the pill's own content can fit, this paints only the
  /// growing shape with the magnifier in it — dropping a `TextField` into a
  /// 40 px-wide box would overflow on every frame of the first half.
  Widget _lead(Lt l10n, double radius, double fieldIn, double targetWidth) {
    if (fieldIn <= 0) {
      return DecoratedBox(
        decoration: SokoSearchInputPill.decorationFor(radius),
        child: const Center(
          child: Icon(LucideIcons.search, size: 18, color: AppColors.sokoInk),
        ),
      );
    }
    // Laid out at its FINAL width inside an `OverflowBox`, then clipped to the
    // box it currently occupies. Letting the pill lay out at the animating
    // width instead would re-flow the field and the ✕ on every frame, and the
    // ✕ would visibly crawl in from the left rather than staying put.
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: OverflowBox(
        alignment: Alignment.centerLeft,
        minWidth: 0,
        maxWidth: double.infinity,
        child: SizedBox(
          width: targetWidth,
          child: SokoSearchInputPill(
            controller: widget.controller,
            focusNode: widget.focusNode,
            hintText: l10n.discoveryActionBarSearchHint,
            clearSemanticLabel: l10n.discoveryActionBarSearchClose,
            contentOpacity: fieldIn,
            onClear: widget.onExit,
          ),
        ),
      ),
    );
  }

  Widget _chips({required bool atRest}) {
    return FeedFilterBar(
      procuraT: widget.t,
      onProcura: widget.onProcura,
      onSelected: atRest ? widget.onFilterSelected : null,
      includeProcuraChip: atRest,
      rowController: _rowController,
      motion: _hasMorphed ? SokoTagBarMotion.standard : SokoTagBarMotion.reveal,
      heroCircle: widget.heroCircle,
    );
  }

  static double _lerp(double a, double b, double t) => a + (b - a) * t;

  /// [t] remapped onto `[start, end]` and clamped — the `Interval` curve's
  /// arithmetic, without needing an `Animation` to attach it to.
  static double _interval(double t, double start, double end) =>
      ((t - start) / (end - start)).clamp(0.0, 1.0);

  /// 0 → 1 → 0 across its input, so the circle swells and settles.
  static double _pulse(double t) => t <= 0 || t >= 1
      ? 0
      : Curves.easeOut.transform(t < 0.5 ? t * 2 : (1 - t) * 2);
}
