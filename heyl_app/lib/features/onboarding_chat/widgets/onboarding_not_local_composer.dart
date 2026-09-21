import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/soko_tag.dart';
import '../data/onboarding_supported_cities.dart';

/// The not-local "Fala comigo" handoff pill — right-aligned, outlined by default
/// (pink fill only on hover/press), leading ↗. Delivered inline as a content
/// turn in the transcript.
class OnboardingNotLocalFalaComigo extends StatelessWidget {
  const OnboardingNotLocalFalaComigo({
    super.key,
    required this.label,
    required this.onTap,
    this.enabled = true,
  });

  final String label;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerRight,
    child: NotLocalChip(
      label: label,
      icon: LucideIcons.arrow_up_right,
      onTap: enabled ? onTap : null,
    ),
  );
}

/// The supported-city chips — a right-aligned wrap; the [selected] chip shows
/// the pink fill. Delivered inline as a content turn.
class OnboardingNotLocalCities extends StatelessWidget {
  const OnboardingNotLocalCities({
    super.key,
    required this.selected,
    required this.onSelected,
    this.cities = onboardingSupportedCities,
    this.enabled = true,
  });

  final OnboardingSupportedCity? selected;
  final ValueChanged<OnboardingSupportedCity> onSelected;
  final List<OnboardingSupportedCity> cities;
  final bool enabled;

  @override
  Widget build(BuildContext context) => Wrap(
    alignment: WrapAlignment.end,
    spacing: 6,
    runSpacing: 6,
    children: [
      for (final city in cities)
        NotLocalChip(
          key: Key('onboarding-not-local-city-${city.name}'),
          label: city.label,
          selected: city.name == selected?.name,
          onTap: enabled ? () => onSelected(city) : null,
        ),
    ],
  );
}

/// Outlined by default, `sokoPink` fill when [selected] or on hover/press
/// (matches the extra-step chips).
class NotLocalChip extends StatefulWidget {
  const NotLocalChip({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.selected = false,
    this.fillWidth = false,
  });

  final String label;
  final IconData? icon;
  final bool selected;
  final VoidCallback? onTap;

  /// Fill the parent's width and auto-shrink the label to fit, instead of
  /// hugging the label (PROD-4288).
  ///
  /// Default `false` — the onboarding step lays these out in a `Wrap`, which
  /// hands children UNBOUNDED width, and a `Flexible` in an unbounded `Row`
  /// asserts. Only a caller that has already bounded the chip may opt in.
  ///
  /// The shrink is `FittedBox(scaleDown)`, the same device `SokoCtaButton` uses
  /// in its `expand` mode, and for the same reason the design system gives:
  /// a button label wraps or auto-sizes, it never single-line clips. Ellipsis
  /// would turn "Rio de Janeiro, BR" into "Rio de Janeiro, …", which loses the
  /// country the label exists to carry.
  final bool fillWidth;

  @override
  State<NotLocalChip> createState() => _NotLocalChipState();
}

class _NotLocalChipState extends State<NotLocalChip> {
  bool _pressed = false;
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final active = widget.selected || _pressed || _hovered;
    return MouseRegion(
      cursor: widget.onTap == null
          ? SystemMouseCursors.basic
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
          decoration: BoxDecoration(
            color: active ? AppColors.sokoPink : AppColors.sokoPaper,
            border: Border.all(color: AppColors.sokoPink),
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: Row(
            mainAxisSize: widget.fillWidth
                ? MainAxisSize.max
                : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 14, color: AppColors.sokoInk),
                const SizedBox(width: 6),
              ],
              if (widget.fillWidth)
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(widget.label, style: SokoTag.textStyle),
                  ),
                )
              else
                Text(widget.label, style: SokoTag.textStyle),
            ],
          ),
        ),
      ),
    );
  }
}
