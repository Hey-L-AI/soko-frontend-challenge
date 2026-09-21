import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/password_validator.dart';
import '../../../l10n/generated/l10n.dart';

/// Maps a [PasswordStrengthLevel] to a localized label.
String labelForStrength(PasswordStrengthLevel level, Lt l10n) {
  switch (level) {
    case PasswordStrengthLevel.weak:
      return l10n.authPasswordStrengthWeak;
    case PasswordStrengthLevel.fair:
      return l10n.authPasswordStrengthFair;
    case PasswordStrengthLevel.good:
      return l10n.authPasswordStrengthGood;
    case PasswordStrengthLevel.strong:
      return l10n.authPasswordStrengthStrong;
  }
}

/// Maps a [PasswordRequirement] to a localized label.
String labelForRequirement(PasswordRequirement req, Lt l10n) {
  switch (req) {
    case PasswordRequirement.minLength:
      return l10n.authPasswordReqMinLength;
    case PasswordRequirement.uppercase:
      return l10n.authPasswordReqUppercase;
    case PasswordRequirement.lowercase:
      return l10n.authPasswordReqLowercase;
    case PasswordRequirement.digit:
      return l10n.authPasswordReqDigit;
  }
}

/// Visual password strength indicator widget
///
/// Shows a progress bar indicating password strength and
/// a checklist of requirements with icons.
class PasswordStrengthIndicator extends StatelessWidget {
  final String password;
  final bool showRequirements;

  const PasswordStrengthIndicator({
    super.key,
    required this.password,
    this.showRequirements = true,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final strength = PasswordValidator.calculateStrength(password);
    final validation = PasswordValidator.validate(password);
    final strengthLabel = labelForStrength(
      PasswordValidator.getStrengthLevel(strength),
      l10n,
    );
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final borderColor = isDark ? AppColors.borderDarkMode : AppColors.border;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Strength bar with label
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: strength,
                  backgroundColor: borderColor,
                  valueColor: AlwaysStoppedAnimation(
                    _getStrengthColor(strength),
                  ),
                  minHeight: 6,
                ),
              ),
            ),
            if (password.isNotEmpty) ...[
              const SizedBox(width: 12),
              Text(
                strengthLabel,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: _getStrengthColor(strength),
                ),
              ),
            ],
          ],
        ),

        // Requirements checklist
        if (showRequirements && password.isNotEmpty) ...[
          const SizedBox(height: 12),
          _RequirementItem(
            met: validation.hasMinLength,
            text: l10n.authPasswordReqMinLength,
          ),
          const SizedBox(height: 4),
          _RequirementItem(
            met: validation.hasUppercase,
            text: l10n.authPasswordReqUppercase,
          ),
          const SizedBox(height: 4),
          _RequirementItem(
            met: validation.hasLowercase,
            text: l10n.authPasswordReqLowercase,
          ),
          const SizedBox(height: 4),
          _RequirementItem(
            met: validation.hasDigit,
            text: l10n.authPasswordReqDigit,
          ),
        ],
      ],
    );
  }

  Color _getStrengthColor(double strength) {
    if (strength < 0.3) return AppColors.error;
    if (strength < 0.6) return AppColors.warning;
    if (strength < 0.8) return AppColors.primary;
    return AppColors.success;
  }
}

/// Single requirement item with check/X icon
class _RequirementItem extends StatelessWidget {
  final bool met;
  final String text;

  const _RequirementItem({required this.met, required this.text});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSecondaryColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final textTertiaryColor = isDark
        ? AppColors.textTertiaryDark
        : AppColors.textTertiary;

    return Row(
      children: [
        Icon(
          met ? Icons.check_circle : Icons.circle_outlined,
          size: 16,
          color: met ? AppColors.success : textTertiaryColor,
        ),
        const SizedBox(width: 8),
        Text(
          text,
          style: TextStyle(
            fontSize: 12,
            color: met ? textSecondaryColor : textTertiaryColor,
          ),
        ),
      ],
    );
  }
}
