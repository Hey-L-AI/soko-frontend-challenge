import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/clickable.dart';
import '../../../shared/widgets/soko_tag.dart';
import 'onboarding_continue_button.dart';

/// One selectable interest (stable [id] for persistence, localized [label]).
@immutable
class OnboardingInterestOption {
  const OnboardingInterestOption({required this.id, required this.label});

  final String id;
  final String label;
}

/// The interests multi-select from the identity step (Figma `7285:23320`):
/// a right-aligned wrap of pill chips (`Soko/Pink` selected, `Soko/Paper`
/// unselected, 1px `Soko/Pink` border, radius 6, Zalando-Light-14 `Soko/Ink`
/// label) plus a confirm CTA gated on [minSelection].
class OnboardingInterestsComposer extends StatefulWidget {
  const OnboardingInterestsComposer({
    super.key,
    required this.options,
    required this.confirmLabel,
    required this.onConfirm,
    // PROD-4394 P1-12: min 3 → 1. The hard min-3 gate was the same trap class
    // as the vibe like-gate that stranded ~35% of users at step 2/5 — a user
    // with one genuine interest had no way forward. One pick seeds a themed
    // zine; the backend tops up from the twin as signals accumulate.
    this.minSelection = 1,
    this.enabled = true,
  });

  final List<OnboardingInterestOption> options;
  final String confirmLabel;

  /// Receives the selected ids (stable order = catalog order).
  final ValueChanged<List<OnboardingInterestOption>> onConfirm;
  final int minSelection;
  final bool enabled;

  @override
  State<OnboardingInterestsComposer> createState() =>
      _OnboardingInterestsComposerState();
}

class _OnboardingInterestsComposerState
    extends State<OnboardingInterestsComposer> {
  final _selected = <String>{};

  bool get _canConfirm =>
      widget.enabled && _selected.length >= widget.minSelection;

  void _toggle(String id) {
    if (!widget.enabled) return;
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.end,
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final option in widget.options)
              _InterestChip(
                label: option.label,
                selected: _selected.contains(option.id),
                onTap: () => _toggle(option.id),
              ),
          ],
        ),
        // The confirm CTA is hidden until the minimum picks are made — a
        // disabled-but-visible button read as "you can continue now" before any
        // selection (PROD-3888 reporter). It appears the moment the Nth pick
        // lands.
        if (_canConfirm) ...[
          const SizedBox(height: 12),
          OnboardingContinueButton(
            key: const Key('onboarding-interests-confirm'),
            label: widget.confirmLabel,
            enabled: true,
            onTap: () => widget.onConfirm(
              widget.options
                  .where((o) => _selected.contains(o.id))
                  .toList(growable: false),
            ),
          ),
        ],
      ],
    );
  }
}

class _InterestChip extends StatelessWidget {
  const _InterestChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // `Clickable` (not a bare GestureDetector) so the chip shows the web
    // pointer cursor on hover — the canonical clickable-cursor wrapper, matching
    // the editable answer pill's `MouseRegion(SystemMouseCursors.click)`.
    return Clickable(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      // No `alignment:` — a Container with an alignment expands to fill the
      // bounded width the stretched Wrap hands it, which would render each chip
      // as a full-width row. Without it the chip hugs its label (a pill) and the
      // Wrap right-aligns and wraps them, per Figma 7285:23320.
      child: Container(
        height: 30,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
        decoration: BoxDecoration(
          color: selected ? AppColors.sokoPink : AppColors.sokoPaper,
          border: Border.all(color: AppColors.sokoPink),
          borderRadius: BorderRadius.circular(6),
        ),
        // widthFactor: 1 hugs the label horizontally; the null heightFactor lets
        // Align fill the 30px height and centre the text vertically within it.
        child: Align(
          alignment: Alignment.center,
          widthFactor: 1,
          child: Text(label, style: SokoTag.textStyle),
        ),
      ),
    );
  }
}
