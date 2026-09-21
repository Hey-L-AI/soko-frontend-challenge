import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// Soko design-system tooltip.
///
/// Two surfaces, **one source of truth** for the styling tokens
/// ([_kBackground], [_kTextStyle], [_kPadding], [_kRadius]) — change
/// them here and every Soko tooltip in the app updates at once.
///
/// * [SokoTooltip] — the standard form. Use when you have a single
///   child widget to anchor on. Wraps Flutter's built-in [Tooltip] so
///   you inherit its hover-on-desktop / long-press-on-mobile trigger
///   logic and overlay positioning for free.
///
/// * [SokoTooltipChip] — the standalone bubble. Use when you need to
///   render the tooltip at a manually computed position (e.g. floating
///   above a cursor on a scrubber, or anchored to a paint location
///   that doesn't correspond to a child widget). Drop it inside a
///   [Stack] / [Positioned].
///
/// Both forms render the same visual: a Soko-Shade-2 bubble with
/// paper-coloured text, 4 px corner radius, 12 px medium-weight body.

// ── Design tokens (single source of truth) ─────────────────────────
const Color _kBackground = AppColors.sokoShade2;
const Color _kTextColor = AppColors.sokoPaper;
const double _kRadius = 4;
const EdgeInsets _kPadding = EdgeInsets.symmetric(horizontal: 8, vertical: 4);
const TextStyle _kTextStyle = TextStyle(
  color: _kTextColor,
  fontSize: 12,
  fontWeight: FontWeight.w500,
  height: 1.2,
);
const Duration _kDefaultWaitDuration = Duration(milliseconds: 200);

BoxDecoration _decoration() => BoxDecoration(
  color: _kBackground,
  borderRadius: BorderRadius.circular(_kRadius),
);

/// Soko-styled wrapper around Flutter's [Tooltip]. Drop it around any
/// widget that should surface a hover / long-press tooltip with the
/// Soko look.
///
/// Example:
/// ```dart
/// SokoTooltip(
///   message: 'Save list',
///   child: IconButton(icon: Icon(Icons.bookmark), onPressed: ...),
/// )
/// ```
class SokoTooltip extends StatelessWidget {
  /// Message to render inside the bubble.
  final String message;

  /// Widget the tooltip anchors on.
  final Widget child;

  /// Delay before the tooltip appears on hover. Matches the Material
  /// default (no `waitDuration` makes the tooltip near-instant which
  /// feels jumpy on a hover-heavy UI).
  final Duration waitDuration;

  const SokoTooltip({
    super.key,
    required this.message,
    required this.child,
    this.waitDuration = _kDefaultWaitDuration,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      waitDuration: waitDuration,
      decoration: _decoration(),
      textStyle: _kTextStyle,
      padding: _kPadding,
      preferBelow: false,
      child: child,
    );
  }
}

/// Standalone Soko-styled tooltip bubble for manual positioning. Use
/// when [SokoTooltip] doesn't fit (no anchor child / cursor-following
/// tooltip / overlay rendered alongside a custom painter).
///
/// Wrap with [IgnorePointer] if you don't want it to swallow taps —
/// this widget already does so internally so the bubble never blocks
/// pointer events on whatever sits beneath.
class SokoTooltipChip extends StatelessWidget {
  /// Text rendered inside the bubble.
  final String label;

  const SokoTooltipChip({super.key, required this.label});

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        padding: _kPadding,
        decoration: _decoration(),
        child: Text(label, style: _kTextStyle),
      ),
    );
  }
}
