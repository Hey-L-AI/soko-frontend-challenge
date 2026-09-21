import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../data/models/country.dart';

/// Inline country code picker widget for use inside TextField prefix
class CountryCodePicker extends StatelessWidget {
  final Country selectedCountry;
  final VoidCallback onTap;

  const CountryCodePicker({
    super.key,
    required this.selectedCountry,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimaryColor = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textSecondaryColor = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final borderColor = isDark ? AppColors.borderDarkMode : AppColors.border;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.only(left: 16, right: 8),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(selectedCountry.flag, style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 6),
            Text(
              selectedCountry.dialCode,
              style: TextStyle(
                fontSize: 16,
                color: textPrimaryColor,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.keyboard_arrow_down,
              size: 20,
              color: textSecondaryColor,
            ),
            const SizedBox(width: 8),
            Container(width: 1, height: 24, color: borderColor),
          ],
        ),
      ),
    );
  }
}
