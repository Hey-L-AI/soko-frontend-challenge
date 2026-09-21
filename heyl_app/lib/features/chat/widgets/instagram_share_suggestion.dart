import 'package:flutter/material.dart';

import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/instagram_url.dart';
import '../../../data/datasources/api/instagram_share_failure.dart';
import '../../../l10n/generated/l10n.dart';
import '../../instagram_share/providers/instagram_share_polling_provider.dart';
import '../../instagram_share/providers/instagram_share_provider.dart';

/// Dialog shown when a user tries to send an Instagram URL in the chat.
/// Offers to share the link with Soko for scraping instead of sending
/// it as a regular chat message.
class InstagramShareSuggestionDialog extends ConsumerStatefulWidget {
  final String url;
  final InstagramUrlType urlType;
  final VoidCallback onDismiss;
  final VoidCallback onSendAsMessage;

  const InstagramShareSuggestionDialog({
    super.key,
    required this.url,
    required this.urlType,
    required this.onDismiss,
    required this.onSendAsMessage,
  });

  @override
  ConsumerState<InstagramShareSuggestionDialog> createState() =>
      _InstagramShareSuggestionDialogState();
}

class _InstagramShareSuggestionDialogState
    extends ConsumerState<InstagramShareSuggestionDialog> {
  Future<void> _onShare() async {
    ref
        .read(unifiedAnalyticsProvider)
        .trackInstagramLinkSubmitted(
          source: 'chat_dialog',
          urlType: widget.urlType.name,
        );

    final result = await ref
        .read(instagramShareProvider.notifier)
        .submit(widget.url);

    if (!mounted) return;

    final l10n = Lt.of(context);

    if (result != null) {
      final message = result.status == 'already_pending'
          ? l10n.instagramShareAlreadyPending
          : result.status == 'already_connected'
          ? l10n.instagramShareAlreadyConnected
          : result.isProfile
          ? l10n.instagramShareSuccessProfile
          : l10n.instagramShareSuccessPost;

      showSoko(ref, message: message, variant: SokoVariant.success);

      // Start polling this submitted post so the banner appears in the Lists hub.
      ref
          .read(instagramSharePollingProvider.notifier)
          .startPollingForResult(result);

      Navigator.of(context).pop();
    } else {
      final error = ref.read(instagramShareProvider).error;
      final errorMsg = _errorMessage(error, l10n, widget.urlType);

      showSoko(ref, message: errorMsg, variant: SokoVariant.error);
    }
  }

  String _errorMessage(
    InstagramShareFailure? error,
    Lt l10n,
    InstagramUrlType submittedType,
  ) {
    return switch (error) {
      InstagramShareInvalidUrl() when submittedType == InstagramUrlType.reel =>
        l10n.instagramShareErrorReelNotSupported,
      InstagramShareInvalidUrl() => l10n.instagramShareErrorInvalidUrl,
      InstagramShareRateLimited() => l10n.instagramShareErrorRateLimit,
      InstagramShareNetworkError() => l10n.instagramShareErrorNetwork,
      InstagramShareWaitForPrevious() => l10n.instagramShareWaitForPrevious,
      InstagramShareUnknown() => l10n.instagramShareErrorGeneric,
      null => l10n.instagramShareErrorGeneric,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final shareState = ref.watch(instagramShareProvider);

    return AlertDialog(
      backgroundColor: AppColors.sokoPaper,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          const Icon(
            Icons.camera_alt_outlined,
            size: 20,
            color: AppColors.sokoInk,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.instagramShareChatDetected,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppColors.sokoInk,
              ),
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.instagramShareChatPrompt,
            style: const TextStyle(fontSize: 14, color: AppColors.sokoShade3),
          ),
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: AppColors.sokoShade5,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              widget.url,
              style: const TextStyle(
                fontSize: 12,
                color: AppColors.sokoShade3,
                fontFamily: 'monospace',
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: shareState.isSubmitting ? null : widget.onSendAsMessage,
          style: TextButton.styleFrom(foregroundColor: AppColors.sokoInk),
          child: Text(l10n.instagramShareChatDismiss),
        ),
        FilledButton(
          onPressed: shareState.isSubmitting ? null : _onShare,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.sokoPink,
            foregroundColor: AppColors.sokoInk,
          ),
          child: shareState.isSubmitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.sokoInk,
                  ),
                )
              : Text(l10n.instagramShareChatShareButton),
        ),
      ],
    );
  }
}

/// Shows the Instagram share suggestion dialog.
///
/// Returns `true` if the URL was shared with Soko, `false` if the user
/// chose to send it as a regular message, or `null` if dismissed.
Future<bool?> showInstagramShareSuggestion(
  BuildContext context, {
  required String url,
  required InstagramUrlType urlType,
  required VoidCallback onSendAsMessage,
}) {
  return showDialog<bool>(
    context: context,
    builder: (dialogContext) => InstagramShareSuggestionDialog(
      url: url,
      urlType: urlType,
      onDismiss: () => Navigator.of(dialogContext).pop(null),
      onSendAsMessage: () {
        Navigator.of(dialogContext).pop(false);
        onSendAsMessage();
      },
    ),
  );
}
