import 'package:flutter/material.dart';

import '../theme.dart';

/// Small standalone version of Soko's pink primary action.
class SokoButton extends StatelessWidget {
  const SokoButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: ElevatedButton(
      style: ElevatedButton.styleFrom(
        backgroundColor: SokoColors.pink,
        foregroundColor: SokoColors.ink,
        disabledBackgroundColor: SokoColors.pink.withValues(alpha: 0.5),
        elevation: 0,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      ),
      onPressed: onPressed,
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 8,
        children: [if (icon != null) Icon(icon, size: 18), Text(label)],
      ),
    ),
  );
}
