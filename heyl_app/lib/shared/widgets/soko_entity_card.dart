import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/event_timing_chip.dart';
import '../../data/models/entity_signal.dart';
import '../../l10n/generated/l10n.dart';
import 'attention_pulse.dart';
import 'clickable.dart';
import 'rotated_date_tag.dart';
import 'soko_card_image.dart';
import 'soko_overlay_toggle.dart';
import 'soko_toggle_glyph.dart';

/// The shared portrait-poster card for a place/event, used by BOTH the
/// onboarding vibe carousels and the main-chat card carousel.
///
/// Layout (Figma `7674:37412`): a portrait image with 👍/👎 overlaid
/// bottom-right as frosted-glass circular buttons,
/// then a 2-line name and a 2-line "type · location" subtitle — no background
/// chrome, it sits directly on the paper surface. Deliberately model-agnostic:
/// callers map their own model (`VibeCandidate`, `ItemSuggestion`, …) to these
/// primitive props so a single widget renders every surface identically.
class SokoEntityCard extends StatefulWidget {
  const SokoEntityCard({
    super.key,
    required this.name,
    required this.kind,
    this.taste = SignalTaste.none,
    this.onLike,
    this.onDislike,
    this.imageUrl,
    this.seed,
    this.subtitle = '',
    this.subcategoryLabel,
    this.subcategoryIcon,
    this.dateChip,
    this.onTap,
    this.width = 105,
    this.imageHeight = 140,
    this.highlightLike = false,
  });

  final String name;
  final String subtitle;

  /// Optional subcategory shown under the name as an icon + label row (e.g.
  /// "🍷 Wine bar", "🌳 Garden"). When set, it replaces the plain [subtitle]
  /// line. Chat cards populate this; onboarding leaves it null and keeps the
  /// [subtitle] path. [subcategoryIcon] is the leading glyph (optional).
  final String? subcategoryLabel;
  final IconData? subcategoryIcon;

  final String? imageUrl;

  /// Stable seed for the deterministic placeholder texture (entity id).
  final String? seed;
  final SokoEntityKind kind;

  /// Optional relative-timing chip ("Today", "This weekend", "Recurring event",
  /// "First day", …) shown on the top-right of the image (clear of the top-left
  /// dismiss X and the bottom-right thumbs). Used for events; null hides it. The
  /// chip's stamp-in is gated on the poster loading. Resolve it with
  /// [chipForItemSuggestion] / [chipForSingleStart].
  final EventTimingChip? dateChip;

  final SignalTaste taste;

  /// 👍 / 👎 handlers. The thumb cluster is rendered only when BOTH are
  /// provided — a card with no signal target (e.g. a generic result with no
  /// venue/event id) passes neither and shows the poster without thumbs.
  final VoidCallback? onLike;
  final VoidCallback? onDislike;

  /// Opens the entity's detail. The 👍/👎 buttons have their own gesture
  /// handlers, so they win taps within their bounds; a tap anywhere else fires
  /// this.
  final VoidCallback? onTap;
  final double width;
  final double imageHeight;

  /// When true, the 👍 button breathes with a soft glow to nudge the user to
  /// like (used by the gated onboarding vibe step). Opt-in — every other caller
  /// leaves it false and renders the plain thumb cluster.
  final bool highlightLike;

  @override
  State<SokoEntityCard> createState() => _SokoEntityCardState();
}

class _SokoEntityCardState extends State<SokoEntityCard> {
  /// Whether the poster has painted — gates the date chip's stamp-in so the
  /// sticker never lands on a blank/loading tile.
  bool _imageLoaded = false;
  Timer? _fallbackTimer;

  bool get _hasImage => widget.imageUrl?.isNotEmpty ?? false;

  @override
  void initState() {
    super.initState();
    _armFallback();
  }

  @override
  void didUpdateWidget(SokoEntityCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A recycled card pointing at a new image must wait for the new poster.
    if (oldWidget.imageUrl != widget.imageUrl) {
      _imageLoaded = false;
      _armFallback();
    }
  }

  /// Safety net: a photo that 404s / times out never fires `onLoaded`, so
  /// reveal the chip anyway after a short beat rather than hiding it forever.
  /// Only relevant when there is an image to wait for.
  void _armFallback() {
    _fallbackTimer?.cancel();
    if (!_hasImage) return;
    _fallbackTimer = Timer(const Duration(milliseconds: 2500), () {
      if (mounted && !_imageLoaded) setState(() => _imageLoaded = true);
    });
  }

  @override
  void dispose() {
    _fallbackTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Clickable(
      // Web: pointer cursor on hover when the card is tappable (raw
      // GestureDetector shows the default arrow). Defaults to opaque hit-test,
      // matching the previous behaviour.
      onTap: widget.onTap,
      child: SizedBox(
        width: widget.width,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              // Let the 👍 nudge glow (see [AttentionPulse]) bleed past the
              // image edge instead of being clipped at the top-right corner.
              // Inert for every other card — nothing else overflows the image.
              clipBehavior: Clip.none,
              children: [
                SokoCardImage(
                  imageUrl: widget.imageUrl,
                  seed: widget.seed ?? '',
                  kind: widget.kind,
                  width: widget.width,
                  height: widget.imageHeight,
                  borderRadius: BorderRadius.circular(8),
                  onLoaded: () {
                    if (!_imageLoaded && mounted) {
                      setState(() => _imageLoaded = true);
                    }
                  },
                ),
                if (widget.onLike != null && widget.onDislike != null)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: SokoThumbCluster(
                      taste: widget.taste,
                      onLike: widget.onLike!,
                      onDislike: widget.onDislike!,
                      highlightLike: widget.highlightLike,
                    ),
                  ),
                if (widget.dateChip?.isVisible ?? false)
                  Positioned(
                    top: 6,
                    right: 6,
                    // Unified with the detail/zine sticker: the same tilted
                    // [RotatedDateTag]. The chip resolver (`event_timing_chip`)
                    // decides the label + fill (past red, recurring/phase, …);
                    // the stamp-in waits for the poster to load.
                    child: RotatedDateTag(
                      label: widget.dateChip!.label!,
                      background: RotatedDateTag.backgroundFor(
                        widget.dateChip!.style,
                      ),
                      // Gate the stamp-in on the poster loading; with no photo
                      // to wait for, fall back to arming on visibility (null).
                      active: _hasImage ? _imageLoaded : null,
                      // Keep the sticker inside its own poster — a long label
                      // ("Este fim de semana") otherwise sizes past the card
                      // and lands on the neighbouring ones. Full card width
                      // less the 6px inset on each side.
                      maxWidth: widget.width - 12,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              widget.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              // Card name = Figma `Mobile/B1 Reg` (Zalando Light 18, height 1,
              // tracking -2%), per node `7507:28049`.
              style: AppTheme.mobileB1Reg(color: AppColors.sokoInk),
            ),
            // Subcategory row (icon + label) — the chat-card treatment. Falls
            // back to the plain [subtitle] text when no subcategory is set
            // (onboarding vibe cards).
            if (widget.subcategoryLabel != null &&
                widget.subcategoryLabel!.isNotEmpty) ...[
              const SizedBox(height: 4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (widget.subcategoryIcon != null) ...[
                    Icon(
                      widget.subcategoryIcon,
                      size: 14,
                      color: AppColors.sokoShade4,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: Text(
                      widget.subcategoryLabel!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      // Muted sub-line = Figma `Mobile/B2 Reg` + Soko/Shade4.
                      style: AppTheme.mobileB2Reg(color: AppColors.sokoShade4),
                    ),
                  ),
                ],
              ),
            ] else if (widget.subtitle.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(
                widget.subtitle,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.mobileB2Reg(color: AppColors.sokoShade4),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Diameter of each frosted circular thumb button. The shared card-overlay
/// toggle's own default — named here only because [AttentionPulse] needs the
/// matching corner radius.
const double _kThumbSize = SokoOverlayToggle.thumbnailSize;

/// The paired 👍 / 👎 control overlaid at the bottom-right of a [SokoEntityCard]
/// image (Figma `7674:37412`). Two 30×30 frosted-glass circular buttons —
/// 👍 then 👎 — each a translucent Soko/Ink 30 ground under a 4px backdrop blur
/// with a white thumb glyph. Selecting a thumb swaps its glyph from the white
/// outline to the white fill; the frosted ground never changes. 👎 reuses the
/// 👍 glyph rotated 180°.
class SokoThumbCluster extends StatelessWidget {
  const SokoThumbCluster({
    super.key,
    required this.taste,
    required this.onLike,
    required this.onDislike,
    this.highlightLike = false,
  });

  final SignalTaste taste;
  final VoidCallback onLike;
  final VoidCallback onDislike;

  /// Breathe the 👍 button with a soft glow to nudge a like. Only the like
  /// button pulses — a 👎 never satisfies the onboarding gate.
  final bool highlightLike;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AttentionPulse(
          enabled: highlightLike,
          borderRadius: BorderRadius.circular(_kThumbSize / 2),
          child: _thumb(
            context,
            selected: taste == SignalTaste.liked,
            onTap: onLike,
            semanticLabel: Lt.of(context).signalLike,
          ),
        ),
        const SizedBox(width: 6),
        _thumb(
          context,
          selected: taste == SignalTaste.disliked,
          flip: true,
          onTap: onDislike,
          semanticLabel: Lt.of(context).signalThumbDown,
        ),
      ],
    );
  }

  /// One thumb, on the shared card-overlay toggle (D310). 👎 is the 👍 asset
  /// rotated 180°, which is why `flip` exists rather than a second glyph.
  Widget _thumb(
    BuildContext context, {
    required bool selected,
    required VoidCallback onTap,
    required String semanticLabel,
    bool flip = false,
  }) => SokoOverlayToggle(
    selected: selected,
    flip: flip,
    onTap: onTap,
    semanticLabel: semanticLabel,
    glyph: (active, color) => SokoToggleGlyph.thumbUp(
      active: active,
      height: 14,
      fillColor: color,
      lineColor: color,
    ),
  );
}
