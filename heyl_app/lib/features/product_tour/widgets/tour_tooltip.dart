import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';

/// Viewport-aware max-width for any product-tour tooltip card. Lives
/// here so every step shares the same upper bound:
///   - On wide viewports (web desktop, tablets): capped at the value
///     below — chosen as the MINIMUM width that still keeps the
///     three-pill action row (Voltar + Saltar + Próximo + the
///     `N/total` step counter) on a SINGLE line. An earlier 300-px
///     cap looked nicer but wrapped Próximo onto its own row from
///     step 2 onward, which the user explicitly forbade.
///   - On narrow viewports (small phones, browser at iPhone width):
///     viewport-width minus 32 px of side padding so the card never
///     touches the screen edge. On viewports narrow enough that even
///     this falls below 340 px, the action row will start wrapping —
///     there's no card width that fits three pills on a 320-px
///     phone — but in practice the discovery shell already gates
///     access to such viewports.
///
/// Use this as the source of truth instead of hardcoding a width per
/// call site — it keeps the searchBar/discoverCity/createSheet/
/// yoursNav/profileMenu cards consistent across phones, tablets, and
/// web. For anchored cards (Procurar's body width matches the chat
/// bar's width), take the min of the anchor width and this value.
double tourCardMaxWidth(BuildContext context) {
  final viewportWidth = MediaQuery.sizeOf(context).width;
  const cap = 360.0;
  const sidePadding = 32.0;
  return math.min(viewportWidth - sidePadding, cap);
}

/// Soko-styled coachmark tooltip used by every step of the product tour.
///
/// Refreshed at Figma node 6777:16450 (frame 9378) — the card now
/// reads as a hand-drawn editorial annotation:
///   • Dashed Soko-Ink border on a Soko-Paper background, radius 6.
///   • Display-font headline at 42 px (Season Mix Light).
///   • Body in Zalando Sans Light.
///   • Action row with Skip + Próximo pills on the left and an
///     `N/total` step counter on the right.
class TourTooltip extends StatefulWidget {
  const TourTooltip({
    super.key,
    required this.headline,
    required this.body,
    required this.currentStep,
    required this.totalSteps,
    required this.isLastStep,
    required this.onNext,
    required this.onSkip,
    this.onBack,
    this.showCounter = true,
    this.nextLabel,
    this.skipLabel,
  });

  final String headline;
  final String body;

  /// 1-indexed current step. Drives the `N/total` counter on the right.
  final int currentStep;

  /// Total visible steps in the tour.
  final int totalSteps;

  final bool isLastStep;
  final VoidCallback onNext;
  final VoidCallback onSkip;

  /// Optional back-step callback. When provided, a "Voltar" pill
  /// renders to the LEFT of the Skip pill. Null on the first step.
  final VoidCallback? onBack;

  /// Show the `N/total` counter on the action row. False for the
  /// welcome intro card, which sits OUTSIDE the numbered step flow.
  final bool showCounter;

  /// Override the Next pill's label (e.g. "Vamos" on the welcome
  /// card). When null, falls back to `productTourDone` /
  /// `productTourNext` based on [isLastStep].
  final String? nextLabel;

  /// Override the Skip pill's label (e.g. "Let me explore" on the welcome
  /// card). When null, falls back to the shared `productTourSkip` used on
  /// every mid-tour step.
  final String? skipLabel;

  @override
  State<TourTooltip> createState() => _TourTooltipState();
}

class _TourTooltipState extends State<TourTooltip>
    with SingleTickerProviderStateMixin {
  /// Drives the OUTER Soko-Blue solid rectangle's draw-in animation.
  /// Auto-forwards on mount so every step's card gets the same
  /// "frame draws in around the card" entrance (user spec
  /// 2026-05-30: "deve fazer a animação de desenhar o retangulo azul
  /// em todos os passos do onboarding"). The body (headline / pills)
  /// appears instantly; only the outer rect strokes in.
  late final AnimationController _borderController;

  static const Duration _borderDuration = Duration(milliseconds: 650);

  @override
  void initState() {
    super.initState();
    _borderController = AnimationController(
      vsync: this,
      duration: _borderDuration,
    )..forward();
  }

  @override
  void dispose() {
    _borderController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    const bg = AppColors.sokoPaper; // #F9F0F0
    const ink = AppColors.sokoInk; // #3B0F18 (Soko/Ink)
    const ink8 = Color(0xFF44131D); // Soko/Ink 8 per Figma
    const pillBg = Color(0x14441D1D); // rgba(68,19,29,0.08)
    // Per user spec (2026-05-30): the dashed inner border is Soko
    // Ink (matches the editorial annotation look), while the OUTER
    // solid rectangle is Soko Blue (matches the chat-bar
    // [TourSecondaryHighlight] rectangle so the two read as the
    // same family of hand-drawn strokes).
    const dashedColor = AppColors.sokoInk;
    const solidColor = AppColors.sokoBlue;

    // No Center wrapper — the showcaseview package positions this
    // container by its natural (shrink-wrapped) size. A Center makes
    // the widget claim infinite width in the overlay and the package
    // mis-positions the card.
    return AnimatedBuilder(
      animation: _borderController,
      builder: (context, _) => ConstrainedBox(
        constraints: BoxConstraints(maxWidth: tourCardMaxWidth(context)),
        child: Material(
          color: Colors.transparent,
          // Border stack per Figma frame 9378 + user's reference shot
          // (2026-05-30 153428):
          //   1. **Outer 6 px solid Soko-Blue rounded rectangle** — the
          //      "retangulo azul à volta". Positioned 14 px OUTSIDE the
          //      card body via [Stack] + [Positioned] with negative
          //      offsets so the card body keeps its natural size. An
          //      earlier implementation wrapped the card in
          //      `Padding(14)` and squeezed the body — the Descobre
          //      card's three pills (Voltar / Saltar / Seguinte) then
          //      wrapped onto a second row. The Stack approach keeps
          //      the body's intrinsic width unchanged so the pills
          //      stay on a single row across every step.
          //   2. **Inner 2 px dashed Soko-Blue border** — the "picotado".
          //      Drawn as a `foregroundPainter` (paints AFTER the child)
          //      so the Soko-Paper container background doesn't cover
          //      it. The previous `painter:` slot painted UNDER the
          //      container, leaving the dashes invisible.
          //   3. **Soko-Paper card body** — natural size, padded
          //      content (headline, body, pill row).
          // Both border layers are progress-driven by [borderProgress]
          // so they draw in together after the connector finishes.
          // Card body absorbs taps so the [_TourTapAdvancer] overlay
          // below doesn't fire `next()` when the user just taps the
          // card. Button taps still work because their own
          // GestureDetectors are children — Flutter dispatches hit
          // tests to children first.
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              // Layer 1 — outer 6 px solid Soko-Blue rectangle, drawn
              // 14 px outside the card body. `Positioned` with
              // negative offsets renders past the Stack's bounds;
              // `Clip.none` on the Stack lets that overflow paint.
              // [IgnorePointer] so the outer rect doesn't steal taps
              // from the card body or the underlying [_TourTapAdvancer].
              Positioned(
                // -8 on every side so the solid stroke's inner edge
                // lands exactly at the card body's outer edge — the
                // outer rect "encosta" against the picotado. With
                // strokeWidth 8 + painter inset 4, the stroke spans
                // (-8 → 0) in card-edge coordinates; its inner edge
                // meets the dashed border's outer edge at card y=0.
                left: -8,
                top: -8,
                right: -8,
                bottom: -8,
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _SolidBorderPainter(
                      color: solidColor,
                      strokeWidth: 8.0,
                      // Stroke centre is 4 px outside the card; for
                      // its inner edge (at the card edge) to follow
                      // the 6 px inner radius, the centre-line radius
                      // is 6 + 4 = 10.
                      borderRadius: 10.0,
                      progress: _borderController.value.clamp(0.0, 1.0),
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
              // Layer 2 — card body with dashed border painted BEHIND
              // the content. The Soko-Paper fill is drawn by the same
              // painter (not the Container) so the dashed perimeter
              // lives UNDER the children — including the animated
              // mãozinha on the Next pill, which would otherwise be
              // crossed by the bottom edge of the dashes (user spec
              // 2026-06-03 — "picotado dos cards, aparece em cima da
              // maozinha, deve ficar por tras").
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: CustomPaint(
                  painter: _DashedBorderPainter(
                    color: dashedColor,
                    strokeWidth: 1.2,
                    dashLength: 3.0,
                    dashGap: 4.0,
                    borderRadius: 6.0,
                    progress: 1.0,
                    fillColor: bg,
                  ),
                  child: Container(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.headline,
                          style: const TextStyle(
                            fontFamily: 'SeasonMix',
                            fontWeight: FontWeight.w300,
                            color: ink,
                            fontSize: 40,
                            height: 0.94,
                            letterSpacing: -0.80,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          widget.body,
                          style: const TextStyle(
                            fontFamily: 'ZalandoSans',
                            fontWeight: FontWeight.w300,
                            color: ink,
                            fontSize: 14,
                            height: 1.2,
                            letterSpacing: -0.14,
                          ),
                        ),
                        const SizedBox(height: 18),
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Expanded(
                              child: Wrap(
                                spacing: 6,
                                runSpacing: 6,
                                children: [
                                  if (widget.onBack != null)
                                    _ActionPill(
                                      label: l10n.productTourBack,
                                      backgroundColor: pillBg,
                                      textColor: ink8,
                                      onPressed: widget.onBack!,
                                    ),
                                  if (!widget.isLastStep)
                                    _ActionPill(
                                      label:
                                          widget.skipLabel ??
                                          l10n.productTourSkip,
                                      backgroundColor: pillBg,
                                      textColor: ink8,
                                      onPressed: widget.onSkip,
                                    ),
                                  _NextPillWithHand(
                                    label:
                                        widget.nextLabel ??
                                        (widget.isLastStep
                                            ? l10n.productTourDone
                                            : l10n.productTourNext),
                                    onPressed: widget.onNext,
                                  ),
                                ],
                              ),
                            ),
                            if (widget.showCounter) ...[
                              const SizedBox(width: 6),
                              Padding(
                                padding: const EdgeInsets.only(bottom: 14),
                                child: Text(
                                  '${widget.currentStep}/${widget.totalSteps}',
                                  style: const TextStyle(
                                    fontFamily: 'ZalandoSans',
                                    fontWeight: FontWeight.w300,
                                    color: ink,
                                    fontSize: 14,
                                    height: 1.2,
                                    letterSpacing: -0.14,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One Saltar / Voltar / Próximo pill. 42 px tall, 14 px horizontal
/// padding, 8 px corner radius, Zalando Sans Light 15 px label.
/// `leadingIcon`, when set, renders a 15 px Lucide icon with a 6 px
/// gap before the label (matches the arrow-up-right glyph on the
/// Próximo pill).
class _ActionPill extends StatelessWidget {
  const _ActionPill({
    required this.label,
    required this.backgroundColor,
    required this.textColor,
    required this.onPressed,
    this.leadingIcon,
  });

  final String label;
  final Color backgroundColor;
  final Color textColor;
  final VoidCallback onPressed;
  final IconData? leadingIcon;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: backgroundColor,
      borderRadius: BorderRadius.circular(8),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onPressed,
        child: Container(
          height: 42,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leadingIcon != null) ...[
                Icon(leadingIcon, size: 15, color: textColor),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontFamily: 'ZalandoSans',
                  fontWeight: FontWeight.w300,
                  color: textColor,
                  fontSize: 15,
                  height: 1.2,
                  letterSpacing: -0.15,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Wraps the Next / Concluído pill (now Soko-Blue) in a Stack that
/// overlays an animated `tour_hand.png` cursor. After the card's
/// border draws in (650 ms) plus a short beat, the hand rises in
/// from below the pill (easeOut over 600 ms) and then loops a small
/// upward pulse so it reads as "tap here." `IgnorePointer` lets taps
/// pass through to the pill below.
class _NextPillWithHand extends StatefulWidget {
  const _NextPillWithHand({required this.label, required this.onPressed});

  final String label;
  final VoidCallback onPressed;

  @override
  State<_NextPillWithHand> createState() => _NextPillWithHandState();
}

class _NextPillWithHandState extends State<_NextPillWithHand>
    with TickerProviderStateMixin {
  late final AnimationController _hoverIn;
  late final AnimationController _pulse;
  // PROD-2705: hold the hover-in delay as a cancellable Timer (not a bare
  // `Future.delayed`) so dispose() can cancel it. Without this, disposing the
  // pill within the 800 ms delay (e.g. tour aborted, or any widget test that
  // tears down before the delay elapses) leaves a pending timer — which trips
  // the test framework's "A Timer is still pending after the tree was
  // disposed" invariant. Mirrors `_yoursIntroTimer` in product_tour_host.dart.
  Timer? _hoverInTimer;

  static const Duration _hoverInDelay = Duration(milliseconds: 800);
  static const Duration _hoverInDuration = Duration(milliseconds: 600);
  static const Duration _pulseDuration = Duration(milliseconds: 1400);

  @override
  void initState() {
    super.initState();
    _hoverIn = AnimationController(vsync: this, duration: _hoverInDuration);
    _pulse = AnimationController(vsync: this, duration: _pulseDuration);

    _hoverInTimer = Timer(_hoverInDelay, () {
      if (!mounted) return;
      _hoverIn.forward().whenComplete(() {
        if (!mounted) return;
        _pulse.repeat();
      });
    });
  }

  @override
  void dispose() {
    _hoverInTimer?.cancel();
    _hoverIn.dispose();
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    const ink8 = Color(0xFF44131D);
    return Stack(
      clipBehavior: Clip.none,
      children: [
        _ActionPill(
          label: widget.label,
          backgroundColor: AppColors.sokoBlue,
          textColor: ink8,
          leadingIcon: LucideIcons.arrow_up_right,
          onPressed: widget.onPressed,
        ),
        Positioned(
          // tour_hand.png is 46×52 with the fingertip at (15, 4).
          // Displayed at 40×46 here so the fingertip sits ~3 px below
          // the pill's bottom edge in rest pose. The outer card Stack
          // uses Clip.none so the hand body overflows the card.
          right: 12,
          top: 38,
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: Listenable.merge([_hoverIn, _pulse]),
              builder: (context, _) {
                final hoverT = Curves.easeOut.transform(_hoverIn.value);
                final pulseY = math.sin(_pulse.value * math.pi) * 3.0;
                return Opacity(
                  opacity: hoverT,
                  child: Transform.translate(
                    offset: Offset(0, (1 - hoverT) * 24 - pulseY),
                    child: Image.asset(
                      'assets/images/tour_hand.png',
                      width: 40,
                      height: 46,
                      fit: BoxFit.contain,
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

/// Paints a dashed rounded-rectangle border around the child's bounding
/// box, optionally only up to a `progress` fraction of the perimeter.
/// Used by [TourTooltip] for the editorial dashed frame look — a
/// painted dashed `BoxDecoration.border` doesn't exist in Flutter, so
/// this walks the rounded rect's perimeter with [PathMetric] and draws
/// alternating dash + gap segments. `progress` ∈ [0, 1] lets callers
/// animate the dashes appearing around the perimeter (e.g. the
/// searchBar step's "draw the rectangle around the card" beat after
/// the connector finishes).
class _DashedBorderPainter extends CustomPainter {
  const _DashedBorderPainter({
    required this.color,
    required this.strokeWidth,
    required this.dashLength,
    required this.dashGap,
    required this.borderRadius,
    this.progress = 1.0,
    this.fillColor,
  });

  final Color color;
  final double strokeWidth;
  final double dashLength;
  final double dashGap;
  final double borderRadius;
  final double progress;

  /// Optional Soko-Paper background fill, painted UNDER the dashes.
  /// Wired by [TourTooltip] when the painter sits behind the card body
  /// (`painter:` slot) so the same rounded-rect shape carries both the
  /// fill and the perimeter — and the children paint on top of both,
  /// keeping the animated hand from being crossed by the bottom dashes.
  final Color? fillColor;

  @override
  void paint(Canvas canvas, Size size) {
    final inset = strokeWidth / 2;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTRB(inset, inset, size.width - inset, size.height - inset),
      Radius.circular(borderRadius),
    );
    if (fillColor != null) {
      canvas.drawRRect(rrect, Paint()..color = fillColor!);
    }
    if (progress <= 0) return;
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt;

    for (final metric in path.computeMetrics()) {
      final visibleLength = metric.length * progress.clamp(0.0, 1.0);
      var distance = 0.0;
      while (distance < visibleLength) {
        final segmentEnd = (distance + dashLength)
            .clamp(0, visibleLength)
            .toDouble();
        canvas.drawPath(metric.extractPath(distance, segmentEnd), paint);
        distance = segmentEnd + dashGap;
      }
    }
  }

  @override
  bool shouldRepaint(_DashedBorderPainter old) =>
      color != old.color ||
      strokeWidth != old.strokeWidth ||
      dashLength != old.dashLength ||
      dashGap != old.dashGap ||
      borderRadius != old.borderRadius ||
      progress != old.progress ||
      fillColor != old.fillColor;
}

/// Paints the editorial OUTER frame around the tooltip card — a solid
/// Soko-Blue rounded rectangle, 6 px stroke per Figma frame 9378
/// (`border: 6px solid #8BDFFF; border-radius: 6px;`). Wraps the
/// dashed-border inner card with a ~14 px gap so the two layers read
/// as separate annotation strokes. Honours [progress] so the outer
/// frame draws in along the same timeline as the inner dashed border.
class _SolidBorderPainter extends CustomPainter {
  const _SolidBorderPainter({
    required this.color,
    required this.strokeWidth,
    required this.borderRadius,
    this.progress = 1.0,
  });

  final Color color;
  final double strokeWidth;
  final double borderRadius;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    final inset = strokeWidth / 2;
    final rrect = RRect.fromRectAndRadius(
      Rect.fromLTRB(inset, inset, size.width - inset, size.height - inset),
      Radius.circular(borderRadius),
    );
    final path = Path()..addRRect(rrect);
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.butt
      ..strokeJoin = StrokeJoin.miter;

    for (final metric in path.computeMetrics()) {
      final visibleLength = metric.length * progress.clamp(0.0, 1.0);
      canvas.drawPath(metric.extractPath(0, visibleLength), paint);
    }
  }

  @override
  bool shouldRepaint(_SolidBorderPainter old) =>
      color != old.color ||
      strokeWidth != old.strokeWidth ||
      borderRadius != old.borderRadius ||
      progress != old.progress;
}
