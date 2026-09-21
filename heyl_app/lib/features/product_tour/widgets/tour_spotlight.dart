import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:showcaseview/showcaseview.dart';

import '../../../core/theme/app_colors.dart';
import '../models/tour_step.dart';
import '../providers/product_tour_controller.dart';
import 'tour_tooltip.dart';

/// Tour target wrapper that replaces showcaseview's default dim-and-cutout
/// look with a Soko Blue rectangle border around the target widget. The
/// rest of the app paints normally (no scrim) — only the active target
/// gets the coloured frame so the user's eye lands on it without losing
/// the surrounding context.
///
/// Wraps [Showcase.withWidget] with consistent visual config + the shared
/// [TourTooltip] container. Each call site supplies the [tourKey] from
/// `productTourKeysProvider`, the localized body string, and the child to
/// spotlight. Next / Skip are wired to [ProductTourController] for the
/// caller automatically.
class TourSpotlight extends ConsumerWidget {
  const TourSpotlight({
    super.key,
    required this.tourKey,
    required this.headline,
    required this.body,
    required this.currentStep,
    required this.isLastStep,
    required this.child,
    this.targetCornerRadius = 12.0,
    this.targetPadding = EdgeInsets.zero,
    this.totalSteps = 5,
    this.tooltipPosition,
    this.step,
    this.blockTargetTap = false,
  });

  /// When `true`, taps on the spotlight target do nothing — the
  /// showcase doesn't dismiss, no callback fires, no navigation
  /// triggers. Wired by setting the package's paired
  /// `disposeOnTap: false` + `onTargetClick: () {}` props (per the
  /// 5.0.2 paired-assertion at `showcase.dart:133–138`).
  ///
  /// Used by the last (profileMenu) step: the Home button is the
  /// showcase target, but the user must complete the tour via the
  /// card's Concluído pill — a real Home tap would race the cursor
  /// demo and dismiss the showcase mid-flight.
  final bool blockTargetTap;

  /// The [TourStep] this spotlight represents. When non-null, the
  /// child is wrapped with a drawn-border highlight that activates
  /// while `state.step == step`. Pass null for "key-only" spotlights
  /// whose border is drawn by a wrapper inside the child (e.g. the
  /// Create-+ nav slot whose inner [TourSecondaryHighlight] already
  /// handles the visual — TourSpotlight there is just a key holder
  /// so the package can position any future overlay).
  final TourStep? step;

  /// `GlobalKey` from `productTourKeysProvider` used by the controller's
  /// listener to call `ShowCaseWidget.of(...).startShowCase([key])`.
  final GlobalKey tourKey;

  /// Localized one-word display headline (e.g. `Procurar`).
  final String headline;

  /// Localized tooltip body copy (one of the `productTourStepN` strings).
  final String body;

  /// 1-indexed current step. Drives the dots indicator inside the tooltip
  /// so the user can see "2 of 5" at a glance.
  final int currentStep;

  /// Total number of visible steps in the tour. Defaults to 5.
  final int totalSteps;

  /// `true` only for the final step in the sequence — drives the
  /// "Done" vs "Next" label on the tooltip's primary pill.
  final bool isLastStep;

  /// The widget that should receive the spotlight frame.
  final Widget child;

  /// Border radius of the rectangle drawn around the target. Default 12 px
  /// matches the Soko chat-bar radius; bottom-nav items pass a larger
  /// value for the rounded-pill look.
  final double targetCornerRadius;

  /// Extra space between the target's bounding box and the rectangle
  /// frame. Bottom-nav items pass a small inset so the frame doesn't
  /// hug the icon edges.
  final EdgeInsets targetPadding;

  /// Optional anchor for the tooltip card relative to the spotlight
  /// target. Default `null` lets the package pick automatically
  /// (usually below the target). Step 2 (Sente) passes
  /// `TooltipPosition.bottom` explicitly to push the card down so it
  /// doesn't sit on top of the spotlight rectangle on the Daily
  /// Drop card.
  final TooltipPosition? tooltipPosition;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notifier = ref.read(productTourControllerProvider.notifier);
    // If [step] is non-null, wrap the child with a drawn-border
    // highlight that activates on the matching step. Uses the same
    // painter as [TourSecondaryHighlight] so all rectangles share
    // visual language. When null, render the bare child (the inner
    // wrappers handle their own borders).
    final wrappedChild = step == null
        ? child
        : TourSecondaryHighlight(
            activeOnSteps: {step!},
            borderRadius: targetCornerRadius,
            child: child,
          );
    return Showcase.withWidget(
      key: tourKey,
      container: Builder(
        builder: (ctx) => TourTooltip(
          headline: headline,
          body: body,
          currentStep: currentStep,
          totalSteps: totalSteps,
          isLastStep: isLastStep,
          onNext: notifier.next,
          onSkip: notifier.skip,
        ),
      ),
      // The app paints normally underneath — no dim scrim. The Soko
      // Blue border is drawn by the wrapping [TourSecondaryHighlight]
      // above (when [step] is set), so the package's hardcoded static
      // border would just pop in instantly and clash with the
      // animated entrance. Keep the shape (for hit-testing) but make
      // the stroke invisible.
      overlayColor: Colors.transparent,
      overlayOpacity: 0.0,
      targetShapeBorder: RoundedRectangleBorder(
        side: BorderSide.none,
        borderRadius: BorderRadius.circular(targetCornerRadius),
      ),
      targetPadding: targetPadding,
      tooltipPosition: tooltipPosition,
      // Per user spec (2026-05-30): taps anywhere outside the
      // Saltar / Próximo pills must NOT advance the tour. Disabling
      // the package's barrier interaction prevents the showcaseview
      // package from auto-advancing on stray taps on the
      // (transparent) overlay outside the spotlight + card.
      //
      // [disposeOnTap] + [onTargetClick] form a paired-required pair
      // (see showcaseview 5.0.2 showcase.dart:133–138). Wired together
      // when [blockTargetTap] is true so a tap on the target itself
      // (e.g. the Home nav icon on the final step) is a no-op instead
      // of the package's default "dismiss + advance" behaviour.
      disableBarrierInteraction: true,
      disposeOnTap: blockTargetTap ? false : null,
      onTargetClick: blockTargetTap ? () {} : null,
      child: wrappedChild,
    );
  }
}

/// Companion to [TourSpotlight] that paints the same Soko Blue rectangle
/// border around a widget that is NOT the active showcase target, but
/// SHOULD be visually called out alongside it.
///
/// Use case: step 3's primary target is the create sheet; we also want
/// the Create-+ nav button and the "Adiciona à Soko" pill to wear the
/// same blue frame so the user sees both entry-points into the sheet.
///
/// Two visual layers:
///   * the border is painted via an overlaid [Stack] (not via an
///     enclosing [Container.decoration]), so toggling the highlight
///     does NOT inflate the child by 6 px on each axis;
///   * the border itself is DRAWN PROGRESSIVELY along its perimeter
///     each time it appears — corner to corner over ~650 ms instead
///     of fading in as a finished rectangle. Reads as "hand-drawn",
///     matches Soko's zine voice.
class TourSecondaryHighlight extends ConsumerStatefulWidget {
  const TourSecondaryHighlight({
    super.key,
    required this.activeOnSteps,
    required this.child,
    this.borderRadius = 12.0,
    this.extraActive = false,
    this.hideDuringCursorTransition = false,
    this.strokeWidth = 3.0,
    this.startFraction = 0.0,
  });

  /// The set of [TourStep]s during which the border paints in Soko Blue.
  /// On any other step (including `idle` and `done`), the border is
  /// transparent.
  final Set<TourStep> activeOnSteps;

  /// OR-ed with [activeOnSteps]. Lets the caller force the highlight on
  /// from a transient flag (e.g. the Create-+ preview window during
  /// the step 2 → step 3 hand-off) without polluting the enum.
  final bool extraActive;

  /// When true, the highlight hides while a cursor transition is in
  /// flight (`tourCursorTargetProvider != null`) AND [extraActive] is
  /// false. Used on highlights that are activated by an [activeOnSteps]
  /// baseline but should disappear the moment the user taps Next —
  /// e.g. the Create-+ rectangle during the Adiciona step goes dark
  /// once the cursor starts heading for Biblioteca.
  /// When [extraActive] is true the highlight stays lit regardless,
  /// so this flag plays nicely with the in-transition preview flags
  /// (e.g. `tourCreateButtonPreviewProvider`).
  final bool hideDuringCursorTransition;

  final Widget child;

  final double borderRadius;

  /// Stroke width of the drawn-in rectangle border. Defaults to the
  /// 3 px used by most highlights; the searchBar step overrides this
  /// to 6 px so the chat-bar rect matches the Procurar card's outer
  /// rect + connector strokeWidth — per user spec (2026-05-30) all
  /// step-1 strokes share the same thickness.
  final double strokeWidth;

  /// Perimeter offset (0.0–1.0) where the rect's draw-in starts.
  /// The searchBar step passes 0.5 so the ink begins at the chat-bar
  /// rect's bottom-left and ends there too — visually flush with
  /// the connector that follows immediately.
  final double startFraction;

  @override
  ConsumerState<TourSecondaryHighlight> createState() =>
      _TourSecondaryHighlightState();
}

class _TourSecondaryHighlightState extends ConsumerState<TourSecondaryHighlight>
    with SingleTickerProviderStateMixin {
  /// Drives the "lines being drawn" entrance.
  /// `value` ∈ [0, 1] = fraction of the perimeter drawn so far.
  late final AnimationController _drawController;

  /// Tracks an in-flight delay between `active` becoming true and the
  /// draw animation actually starting. Lets the step's tooltip card
  /// land FIRST, then the rectangle is drawn around the button — per
  /// spec the card appears before the highlight animation kicks in.
  Timer? _delayTimer;
  bool _wasActive = false;

  @override
  void initState() {
    super.initState();
    _drawController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 650),
    );
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _drawController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final step = ref.watch(productTourControllerProvider.select((s) => s.step));
    final cursorInFlight = ref.watch(tourCursorTargetProvider) != null;
    var active = widget.activeOnSteps.contains(step) || widget.extraActive;
    if (widget.hideDuringCursorTransition &&
        cursorInFlight &&
        !widget.extraActive) {
      active = false;
    }

    // Edge-triggered: fire the draw animation only on the false → true
    // transition. Going active → inactive just snaps the perimeter
    // back to 0 ready for the next entrance.
    if (active != _wasActive) {
      _wasActive = active;
      _delayTimer?.cancel();
      if (active) {
        // Wait for the step's tooltip card to settle before the
        // border starts being drawn. Without this the rectangle and
        // the card pop in simultaneously, which feels rushed.
        _delayTimer = Timer(const Duration(milliseconds: 400), () {
          if (!mounted) return;
          _drawController.forward(from: 0);
        });
      } else {
        _drawController.value = 0;
      }
    }

    return Stack(
      clipBehavior: Clip.none,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: AnimatedBuilder(
              animation: _drawController,
              builder: (_, __) {
                return CustomPaint(
                  painter: DrawnBorderPainter(
                    progress: active ? _drawController.value : 0.0,
                    color: AppColors.sokoBlue,
                    strokeWidth: widget.strokeWidth,
                    borderRadius: widget.borderRadius,
                    startFraction: widget.startFraction,
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

/// Paints a rounded-rectangle border progressively along its
/// perimeter. `progress` ∈ [0, 1] = fraction of the perimeter that
/// should be drawn (starting from the top-mid and going clockwise).
///
/// Implementation: builds the full RRect path once per frame, then
/// uses [Path.computeMetrics] + `metric.extractPath(0, length)` to
/// take a leading sub-path matching the requested progress. The
/// `start` of the path lives at the top-mid corner so the two
/// "drawing hands" radiate outward symmetrically when [progress]
/// grows — visually echoes a marker being dragged around the frame.
class DrawnBorderPainter extends CustomPainter {
  DrawnBorderPainter({
    required this.progress,
    required this.color,
    required this.strokeWidth,
    required this.borderRadius,
    this.startFraction = 0.0,
  });

  final double progress;
  final Color color;
  final double strokeWidth;
  final double borderRadius;

  /// Perimeter offset (0.0–1.0) where the draw-in starts. Defaults
  /// to 0.0 (top-right area, where the RRect path natively begins).
  /// The searchBar step's chat-bar rect passes 0.5 so the ink
  /// starts at the bottom-left and traces CW around the perimeter,
  /// ending back at the bottom-left exactly where the connector
  /// then continues downward — reads as one fluid stroke from rect
  /// to connector to card.
  final double startFraction;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;

    final inset = strokeWidth / 2;
    final rect = Rect.fromLTRB(
      inset,
      inset,
      size.width - inset,
      size.height - inset,
    );
    final rrect = RRect.fromRectAndRadius(rect, Radius.circular(borderRadius));
    final fullPath = Path()..addRRect(rrect);

    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final metrics = fullPath.computeMetrics().toList();
    if (metrics.isEmpty) return;
    // RRect path is a SINGLE closed subpath, so metrics.first is
    // the whole perimeter. Compute the desired start position and
    // extract the [startOffset → startOffset + visibleLength]
    // sub-segment, wrapping past the path end if needed.
    final metric = metrics.first;
    final totalLength = metric.length;
    final visibleLength = totalLength * progress.clamp(0.0, 1.0);
    final startOffset = totalLength * startFraction.clamp(0.0, 1.0);

    final segmentEnd = startOffset + visibleLength;
    if (segmentEnd <= totalLength) {
      canvas.drawPath(metric.extractPath(startOffset, segmentEnd), paint);
    } else {
      // Wraps past the path end — paint [startOffset → totalLength]
      // then [0 → leftover].
      canvas.drawPath(metric.extractPath(startOffset, totalLength), paint);
      final leftover = segmentEnd - totalLength;
      canvas.drawPath(metric.extractPath(0, leftover), paint);
    }
  }

  @override
  bool shouldRepaint(DrawnBorderPainter old) =>
      old.progress != progress ||
      old.color != color ||
      old.strokeWidth != strokeWidth ||
      old.borderRadius != borderRadius;
}
