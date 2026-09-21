// PROD-4179 — the rounded search input, extracted from `SearchOverlay`.
//
// It moved out because a **second** surface now draws it: the feed's inline
// Procura mode morphs its filter-row circle into this pill, and it has to be
// the same pill, at the same metrics, or the two drift the first time the
// design changes. `SearchOverlay` still owns the controller, the debounce and
// the clear semantics — this widget is chrome and nothing else.

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../core/theme/app_colors.dart';

/// Pill height, from the Figma redesign. The feed's morph lerps the filter
/// row's 30 px circle up to this, so it is a shared measurement rather than a
/// private one.
const double kSokoSearchInputHeight = 44;

/// Corner radius — fully rounded at [kSokoSearchInputHeight], and the value the
/// morph lerps from the circle's own radius toward.
const double kSokoSearchInputRadius = 22;

/// The input pill: magnifier · field · clear.
///
/// **Draws nothing about state.** Whether the ✕ clears or closes, and what the
/// typed text does, belong to the host — this renders a controller and calls
/// back. That is what lets the overlay keep its two-stage ✕ (PROD-2280) while
/// the feed's Procura mode exits on the first tap (Zé, 2026-09-03) without
/// either behaviour leaking into the other.
class SokoSearchInputPill extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final String hintText;

  /// Accessible name for the trailing ✕.
  final String clearSemanticLabel;
  final VoidCallback onClear;

  /// Attached to the ✕. The product tour reads this key's `RenderBox` to steer
  /// its cursor, which is why it is threaded through rather than owned here.
  final Key? clearButtonKey;

  /// Opacity of the pill's own content, so a caller mid-morph can fade the
  /// field in without fading the shape it is growing into.
  final double contentOpacity;

  const SokoSearchInputPill({
    super.key,
    required this.controller,
    required this.hintText,
    required this.clearSemanticLabel,
    required this.onClear,
    this.focusNode,
    this.clearButtonKey,
    this.contentOpacity = 1,
  });

  /// The pill's resting decoration, exposed so the feed's morph can paint the
  /// same border and fill on a box it is still growing.
  static BoxDecoration decorationFor(double radius) => BoxDecoration(
    // Sits on the page's own paper with a hairline outline, not the old ink @
    // 6 % fill.
    color: Colors.transparent,
    border: Border.all(color: AppColors.sokoShade45, width: 1),
    borderRadius: BorderRadius.circular(radius),
  );

  static const TextStyle _fieldStyle = TextStyle(
    fontSize: 14,
    fontWeight: FontWeight.w300,
    height: 1.2,
    letterSpacing: -0.14,
    color: AppColors.sokoInk,
  );

  @override
  Widget build(BuildContext context) {
    return Container(
      height: kSokoSearchInputHeight,
      decoration: decorationFor(kSokoSearchInputRadius),
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Opacity(
        opacity: contentOpacity,
        child: Row(
          children: [
            const Icon(LucideIcons.search, size: 18, color: AppColors.sokoInk),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                controller: controller,
                focusNode: focusNode,
                textInputAction: TextInputAction.search,
                style: _fieldStyle,
                cursorColor: AppColors.sokoInk,
                decoration: InputDecoration(
                  isDense: true,
                  filled: false,
                  contentPadding: EdgeInsets.zero,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  disabledBorder: InputBorder.none,
                  errorBorder: InputBorder.none,
                  focusedErrorBorder: InputBorder.none,
                  hintText: hintText,
                  hintStyle: _fieldStyle.copyWith(
                    color: AppColors.sokoInk.withValues(alpha: 0.45),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Semantics(
              label: clearSemanticLabel,
              button: true,
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  key: clearButtonKey,
                  behavior: HitTestBehavior.opaque,
                  onTap: onClear,
                  child: const Icon(
                    LucideIcons.x,
                    size: 18,
                    color: AppColors.sokoInk,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
