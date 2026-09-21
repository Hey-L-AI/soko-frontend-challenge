import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/event_timing_chip.dart';

/// A small "slapped-on" status sticker for a detail title — the relative timing
/// of an event (Past event / Today / This weekend / …) as a rotated pill that
/// overlaps the title (Figma `7660:27990`). The label text comes from
/// `eventRelativeTagLabel`; this widget is just the chrome.
///
/// Figma "Tag" (`7660:27990`): radius 6, Zalando Sans Light 14 / Soko/Ink,
/// tilted +5°. The pill hugs the label — snug symmetric padding around the 14px
/// text rather than a fixed tall height — so it reads as a small slapped-on
/// sticker, not a chunky band.
///
/// Fill signals urgency: **Soko/Red** for a past event ([isPast]), **Soko/Paper**
/// for an upcoming one (Today / Tomorrow / This weekend / …) — a neutral chip
/// for what's coming, a warning accent for what's already gone. Text stays
/// Soko/Ink on both.
///
/// **Entrance:** the sticker *stamps* on — an oversized, transparent ghost that
/// slams down to full size with a small overshoot and fades in, like a rubber
/// stamp hitting paper. One-shot; never replays.
///
/// The stamp is *armed* one of two ways:
///   - [active] `null` (default) → armed when the tag first scrolls into view
///     (VisibilityDetector). Right for a normal page/sheet where becoming
///     visible == being seen.
///   - [active] non-null → armed when it flips to `true`. Right for the zine
///     `TurnPageView`, where every page occupies the same on-screen slot (so
///     geometric visibility fires for all of them at once, while the cover is
///     showing) — the card passes its `isActive` so each tag stamps only when
///     its page actually turns to the front.
class RotatedDateTag extends StatefulWidget {
  const RotatedDateTag({
    super.key,
    required this.label,
    this.isPast = false,
    this.background,
    this.active,
    this.maxWidth,
  });

  final String label;

  /// Optional hard cap on the pill's width. Without it the sticker sizes to its
  /// label and, on a narrow card, spills over the neighbouring cards (a long
  /// localized label like "Este fim de semana" is wider than a 105–170px
  /// poster). With it the label wraps onto a second line inside the cap, at the
  /// full Figma type size.
  final double? maxWidth;

  /// A past event → the Soko/Red warning fill; upcoming → the neutral
  /// Soko/Paper chip. Ignored when [background] is set.
  final bool isPast;

  /// Explicit fill, overriding the [isPast] red/paper default. Lets the timing
  /// chip express the exhibition-phase palette (Soko/Yellow novelty, Soko/Red
  /// last-day) via [backgroundFor] without widening the boolean.
  final Color? background;

  /// The fill for an [EventChipStyle] — the phase palette mirrors
  /// [RecurrencePhaseChip]: novelty → Soko/Yellow, last-chance / past →
  /// Soko/Red, everything else neutral Soko/Paper. Text stays Soko/Ink on all.
  static Color backgroundFor(EventChipStyle style) => switch (style) {
    EventChipStyle.pastRed => AppColors.sokoRed,
    EventChipStyle.neutralPaper => AppColors.sokoPaper,
    EventChipStyle.phaseFirst => AppColors.sokoYellow,
    EventChipStyle.phaseLast => AppColors.sokoRed,
  };

  /// Explicit stamp gate. Null → arm on first visibility. Non-null → arm when
  /// this becomes `true` (e.g. the zine card's `isActive`).
  final bool? active;

  @override
  State<RotatedDateTag> createState() => _RotatedDateTagState();
}

class _RotatedDateTagState extends State<RotatedDateTag>
    with SingleTickerProviderStateMixin {
  /// +5° — a light clockwise tilt, per the Figma frame.
  static const double _angle = 5 * math.pi / 180;

  /// Beat between arming and the stamp landing, so it reads as arriving
  /// deliberately rather than snapping in the instant it appears.
  static const Duration _delay = Duration(milliseconds: 260);
  static const Duration _stamp = Duration(milliseconds: 380);

  /// Fraction of the tag that must be on-screen before the stamp is armed
  /// (visibility path only).
  static const double _visibleThreshold = 0.35;

  late final AnimationController _controller;
  late final Animation<double> _scale;
  late final Animation<double> _opacity;
  // Unique per instance — VisibilityDetector requires distinct keys across the
  // tree (several tags can be alive at once: zine neighbours, map sheet, …).
  late final Key _visibilityKey;
  Timer? _delayTimer;
  bool _armed = false;

  @override
  void initState() {
    super.initState();
    _visibilityKey = UniqueKey();
    _controller = AnimationController(vsync: this, duration: _stamp);
    // Slam down from an oversized ghost. `easeOutBack` overshoots the 1.0
    // target (dipping just under, then settling) — the little press that sells
    // "stamped on".
    _scale = Tween<double>(
      begin: 1.6,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutBack));
    // Fade in over the first stretch of the slam so the oversized ghost never
    // shows fully — it's already shrinking as it becomes visible.
    _opacity = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.45, curve: Curves.easeOut),
    );
    // Explicit gate that's already open on mount → arm straight away.
    if (widget.active == true) _arm();
  }

  @override
  void didUpdateWidget(covariant RotatedDateTag oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Explicit gate flipping open (e.g. the zine card turning to the front).
    if (widget.active == true && oldWidget.active != true) _arm();
  }

  /// Fire the stamp once, after the settle beat.
  void _arm() {
    if (_armed) return;
    _armed = true;
    _delayTimer = Timer(_delay, () {
      if (mounted) _controller.forward();
    });
  }

  void _onVisibilityChanged(VisibilityInfo info) {
    if (info.visibleFraction >= _visibleThreshold) _arm();
  }

  @override
  void dispose() {
    _delayTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final capped = widget.maxWidth != null;
    Widget label = Text(
      widget.label,
      // Capped: wrap onto a second line at full type size rather than
      // shrinking. Uncapped (detail / zine, where there's room): one line.
      maxLines: capped ? 2 : 1,
      softWrap: capped,
      overflow: TextOverflow.ellipsis,
      textAlign: TextAlign.center,
      // Figma `Mobile/B2 Reg` — Zalando Sans Light 14 / Soko/Ink.
      style: TextStyle(
        fontFamily: 'ZalandoSans',
        fontWeight: FontWeight.w300,
        fontSize: 14,
        // A wrapped sticker needs leading between its two lines; the
        // single-line case keeps the Figma 1.0 so the pill stays snug.
        height: capped ? 1.15 : 1.0,
        letterSpacing: -0.14,
        color: AppColors.sokoInk,
      ),
    );
    if (capped) {
      // Cap the pill at its card so a long label wraps instead of spilling
      // over the neighbouring cards. Minus the 10px padding on each side.
      label = ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: math.max(0, widget.maxWidth! - 20),
        ),
        child: label,
      );
    }

    final pill = Transform.rotate(
      angle: _angle,
      child: FadeTransition(
        opacity: _opacity,
        child: ScaleTransition(
          scale: _scale,
          // Size to the label. `UnconstrainedBox` drops the bounded constraints
          // an `Align`/`Positioned.fill` parent (the zine title band) hands
          // down — a padded `Container` given bounded constraints expands to
          // fill them, which is what blew the sticker up to the whole band.
          // Without them it shrinks to the text + Figma padding.
          child: UnconstrainedBox(
            child: Container(
              // Figma `Tag` (7660:27990): 10px horizontal / 2px vertical
              // padding — snug to the 14px text, not a fixed tall height.
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              decoration: BoxDecoration(
                // Soko/Red warning for a past event, neutral Soko/Paper chip
                // for an upcoming one — both distinct hues on any page
                // background. An explicit [background] (the timing-chip palette)
                // wins when provided.
                color:
                    widget.background ??
                    (widget.isPast ? AppColors.sokoRed : AppColors.sokoPaper),
                borderRadius: BorderRadius.circular(6),
              ),
              child: label,
            ),
          ),
        ),
      ),
    );

    // Visibility path only when there's no explicit gate.
    if (widget.active != null) return pill;
    return VisibilityDetector(
      key: _visibilityKey,
      onVisibilityChanged: _onVisibilityChanged,
      child: pill,
    );
  }
}
