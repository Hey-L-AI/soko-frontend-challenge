import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/soko_tag.dart';

/// The canonical onboarding Yes/No chip pair (Figma `7285:23262`).
///
/// Shared by every chat-onboarding decision (the "anything else?" composer, the
/// notification-consent ask) so the two chips always render and behave
/// identically: No on the left, Yes (the default, `emphasized`) on the right and
/// a touch larger. Yes carries a pink border for emphasis; No takes a gray
/// border to de-emphasize it. Both fill pink on hover/press, and stay filled
/// once [noSelected]/[yesSelected] locks in a choice.
///
/// Wiring stays at the call site: pass `null` for [onNo]/[onYes] to disable a
/// chip (e.g. while the step is busy or already answered).
class OnboardingChoiceRow extends StatelessWidget {
  const OnboardingChoiceRow({
    super.key,
    required this.noLabel,
    required this.yesLabel,
    required this.onNo,
    required this.onYes,
    this.noKey,
    this.yesKey,
    this.noSelected = false,
    this.yesSelected = false,
  });

  final String noLabel;
  final String yesLabel;

  /// Tapping No / Yes. `null` disables (and greys the cursor for) that chip.
  final VoidCallback? onNo;
  final VoidCallback? onYes;

  /// Optional keys forwarded to each chip (used by widget tests / analytics).
  final Key? noKey;
  final Key? yesKey;

  /// Locks a chip visually active once a choice is committed.
  final bool noSelected;
  final bool yesSelected;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        _OnboardingChoiceChip(
          key: noKey,
          label: noLabel,
          selected: noSelected,
          onTap: onNo,
        ),
        const SizedBox(width: 8),
        _OnboardingChoiceChip(
          key: yesKey,
          label: yesLabel,
          emphasized: true,
          selected: yesSelected,
          onTap: onYes,
        ),
      ],
    );
  }
}

/// One chip in [OnboardingChoiceRow]: `sokoPaper` fill, radius 6, `SokoTag`
/// label. The pink fill is a hover/press affordance (or permanent once
/// [selected]). At rest the default choice (Yes, [emphasized]) carries a pink
/// border for emphasis while No takes a gray border.
class _OnboardingChoiceChip extends StatefulWidget {
  const _OnboardingChoiceChip({
    super.key,
    required this.label,
    required this.onTap,
    this.selected = false,
    this.emphasized = false,
  });

  final String label;
  final VoidCallback? onTap;
  final bool selected;

  /// The default choice (Yes) sits on the right and is a touch larger.
  final bool emphasized;

  @override
  State<_OnboardingChoiceChip> createState() => _OnboardingChoiceChipState();
}

class _OnboardingChoiceChipState extends State<_OnboardingChoiceChip> {
  bool _isPressed = false;
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected || _isPressed || _isHovered;
    return MouseRegion(
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => setState(() => _isPressed = false),
        onTapCancel: () => setState(() => _isPressed = false),
        onTap: widget.onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: widget.emphasized ? 36 : 30,
          padding: EdgeInsets.symmetric(
            horizontal: widget.emphasized ? 24 : 18,
            vertical: 2,
          ),
          decoration: BoxDecoration(
            color: active ? AppColors.sokoPink : AppColors.sokoPaper,
            border: Border.all(
              color: widget.emphasized
                  ? AppColors.sokoPink
                  : AppColors.sokoShade4,
            ),
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: Text(widget.label, style: SokoTag.textStyle),
        ),
      ),
    );
  }
}
