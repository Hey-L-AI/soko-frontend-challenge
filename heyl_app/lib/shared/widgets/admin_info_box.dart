import 'package:flutter/material.dart';

import '../notifications/heyl_notification.dart';
import '../notifications/notification_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_colors.dart';
import '../../l10n/generated/l10n.dart';

/// Reusable admin-only info box with copy and share actions.
///
/// Displays a bordered container with lock icon, "Admin Only" label,
/// display text, and copy/share icon buttons on the right.
class AdminInfoBox extends StatelessWidget {
  /// The text shown in the box.
  final String displayText;

  /// The rich text copied to clipboard / shared.
  final String clipboardText;

  /// When false, the [displayText] (and its surrounding spacing) is
  /// omitted from the chip — useful in tight surfaces like the mobile
  /// chat header where only the "Admin Only" label + actions should be
  /// visible (PROD-1894).
  final bool showDisplayText;

  const AdminInfoBox({
    super.key,
    required this.displayText,
    required this.clipboardText,
    this.showDisplayText = true,
  });

  void _copy(BuildContext context) {
    Clipboard.setData(ClipboardData(text: clipboardText));
    showSokoFromContext(
      context,
      message: Lt.of(context).adminCopiedToClipboard,
      variant: SokoVariant.info,
      duration: const Duration(seconds: 2),
    );
  }

  void _share() {
    Share.share(clipboardText);
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;
    final secondaryAlpha = AppColors.textSecondary.withValues(alpha: 0.7);

    return Container(
      padding: const EdgeInsets.only(left: 12, top: 4, bottom: 4, right: 4),
      decoration: BoxDecoration(
        border: Border.all(
          color: primaryColor.withValues(alpha: 0.6),
          width: 1,
        ),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.lock, size: 14, color: secondaryAlpha),
          const SizedBox(width: 8),
          Text(
            'Admin Only',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w500,
              color: secondaryAlpha,
            ),
          ),
          if (showDisplayText) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                displayText,
                style: TextStyle(fontSize: 12, color: secondaryAlpha),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 6),
          ] else
            const SizedBox(width: 8),
          _ActionButton(
            icon: LucideIcons.copy,
            onTap: () => _copy(context),
            color: primaryColor,
          ),
          const SizedBox(width: 4),
          _ActionButton(
            icon: LucideIcons.share_2,
            onTap: _share,
            color: primaryColor,
          ),
        ],
      ),
    );
  }
}

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color color;

  const _ActionButton({
    required this.icon,
    required this.onTap,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 26,
          height: 26,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Icon(icon, size: 13, color: color.withValues(alpha: 0.6)),
        ),
      ),
    );
  }
}
