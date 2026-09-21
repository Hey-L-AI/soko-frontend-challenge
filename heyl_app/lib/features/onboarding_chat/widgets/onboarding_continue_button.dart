import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../shared/widgets/bt_sq_ico.dart';

/// The chat-onboarding "Continuar" CTA (Figma `7285:23415`): a full-width
/// Soko/Purple [BtSqIco] with a leading ArrowFront (→) glyph and a
/// Light-weight label. Shared by the interests and "anything else?" composers
/// so the two confirm buttons stay pixel-identical.
///
/// When [enabled] is false the button dims and stops accepting taps (same
/// disabled idiom the name composer uses on its whole chat bar).
class OnboardingContinueButton extends StatelessWidget {
  const OnboardingContinueButton({
    super.key,
    required this.label,
    required this.onTap,
    this.enabled = true,
  });

  final String label;
  final VoidCallback onTap;
  final bool enabled;

  /// Matches the Figma `7285:23415` instance frame (400×80), a taller,
  /// prominent CTA than the DS-standard 40 px `Bt_Sq_Ico`.
  static const double _height = 80;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      ignoring: !enabled,
      child: AnimatedOpacity(
        opacity: enabled ? 1 : 0.5,
        duration: const Duration(milliseconds: 150),
        child: BtSqIco(
          icon: LucideIcons.arrow_right,
          label: label,
          variant: BtSqIcoVariant.purple,
          expand: true,
          height: _height,
          onTap: onTap,
        ),
      ),
    );
  }
}
