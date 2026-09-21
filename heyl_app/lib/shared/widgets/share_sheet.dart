import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import '../../l10n/generated/l10n.dart';
import '../notifications/heyl_notification.dart';
import '../notifications/notification_state.dart';
import '../utils/bottom_sheet_utils.dart';
import 'bottom_sheet/ds_sheet_shell.dart';
import 'bt_sq_ico.dart';

/// PROD-2071 — Generic share bottom sheet used on web by every share entry
/// point (list/zine cover, event detail, venue detail, daily drop).
///
/// Layout mirrors PROD-1992 `ShareListSheet` so the four surfaces stay
/// visually identical: title header, caller-supplied [preview] tile, URL
/// pill, sticky Copy + Share footer.
class ShareSheet extends ConsumerWidget {
  const ShareSheet({
    super.key,
    required this.title,
    required this.preview,
    required this.url,
    this.onCopyAnalytics,
    this.onShareAnalytics,
  });

  final String title;
  final Widget preview;
  final String url;
  final VoidCallback? onCopyAnalytics;
  final VoidCallback? onShareAnalytics;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);

    return DSSheetShell(
      header: _Header(title: title),
      bodyPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          preview,
          const SizedBox(height: 16),
          _UrlRow(url: url),
        ],
      ),
      footer: _Footer(
        copyLabel: l10n.shareListCopyButton,
        shareLabel: l10n.shareListButton,
        onCopy: () => _copy(context, ref, l10n),
        onShare: () => _share(context),
      ),
    );
  }

  void _copy(BuildContext context, WidgetRef ref, Lt l10n) {
    onCopyAnalytics?.call();
    Clipboard.setData(ClipboardData(text: url));
    showSoko(ref, message: l10n.shareListCopied, variant: SokoVariant.success);
    Navigator.of(context).pop();
  }

  void _share(BuildContext context) {
    onShareAnalytics?.call();
    // URL only — no title/description per PROD-2071.
    Share.share(url);
    Navigator.of(context).pop();
  }
}

/// Show the generic share sheet via `showBottomSheetWithHiddenNav`.
Future<void> showShareSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String title,
  required Widget preview,
  required String url,
  VoidCallback? onCopyAnalytics,
  VoidCallback? onShareAnalytics,
}) {
  return showBottomSheetWithHiddenNav<void>(
    context: context,
    ref: ref,
    backgroundColor: Colors.transparent,
    builder: (_) => ShareSheet(
      title: title,
      preview: preview,
      url: url,
      onCopyAnalytics: onCopyAnalytics,
      onShareAnalytics: onShareAnalytics,
    ),
  );
}

/// Standard preview tile shown inside [ShareSheet] — Soko/Shade5 rounded
/// container with a Soko/Pink-tinted icon square and a 1–2-line title.
/// Used by event/venue/daily-drop share entry points; the list share entry
/// point uses its own bespoke tile with item count + public chip.
class ShareSheetItemTile extends StatelessWidget {
  const ShareSheetItemTile({
    super.key,
    required this.icon,
    required this.title,
  });

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.sokoShade5,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.sokoPink.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 22, color: AppColors.sokoPink),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              title,
              style: const TextStyle(
                fontFamily: 'Zalando Sans',
                fontSize: 16,
                fontWeight: FontWeight.w500,
                height: 1.2,
                letterSpacing: -0.16,
                color: AppColors.sokoInk,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title});
  final String title;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        title,
        style: const TextStyle(
          fontFamily: 'Zalando Sans',
          fontSize: 18,
          fontWeight: FontWeight.w500,
          height: 1.2,
          letterSpacing: -0.36,
          color: AppColors.sokoInk,
        ),
      ),
    ),
  );
}

class _UrlRow extends StatelessWidget {
  const _UrlRow({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.sokoInk.withValues(alpha: 0.12)),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          const Icon(LucideIcons.link, size: 18, color: AppColors.sokoShade4),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              url,
              style: AppTheme.mobileB2Reg(color: AppColors.sokoShade4),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer({
    required this.copyLabel,
    required this.shareLabel,
    required this.onCopy,
    required this.onShare,
  });

  final String copyLabel;
  final String shareLabel;
  final VoidCallback onCopy;
  final VoidCallback onShare;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.sokoPaper,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Row(
        children: [
          Expanded(
            child: BtSqIco(
              icon: LucideIcons.copy,
              label: copyLabel,
              variant: BtSqIcoVariant.normal,
              expand: true,
              onTap: onCopy,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: BtSqIco(
              icon: LucideIcons.share,
              label: shareLabel,
              variant: BtSqIcoVariant.selected,
              expand: true,
              onTap: onShare,
            ),
          ),
        ],
      ),
    );
  }
}
