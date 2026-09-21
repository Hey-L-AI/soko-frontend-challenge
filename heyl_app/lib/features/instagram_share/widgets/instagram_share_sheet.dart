import 'package:flutter/material.dart';

import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/instagram_url.dart';
import '../../../data/datasources/api/instagram_share_failure.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../../shared/widgets/soko_text_field.dart';
import '../providers/instagram_share_polling_provider.dart';
import '../providers/instagram_share_provider.dart';

/// Shows the Instagram share sheet (hides bottom nav while open).
///
/// [source] identifies which surface opened the sheet for analytics — one of
/// `lists_hub_menu`, `list_detail`, `discovery_help_us`. Other surfaces
/// (chat dialog, native share) bypass this sheet and emit their own events.
///
/// Refuses to open while a previous share is still pending/processing —
/// shows a snackbar pointing back at the active banner instead. The
/// notifier's submit gate is the second line of defense for the chat
/// dialog and native-share paths that bypass this entry point.
Future<void> showInstagramShareSheet(
  BuildContext context, {
  required WidgetRef ref,
  required String source,
  String? listId,
}) async {
  final polling = ref.read(instagramSharePollingProvider);
  if (polling.isProcessing) {
    showSoko(
      ref,
      message: Lt.of(context).instagramShareWaitForPrevious,
      variant: SokoVariant.info,
    );
    return;
  }
  ref
      .read(unifiedAnalyticsProvider)
      .trackInstagramShareOpen(source: source, listId: listId);
  await showBottomSheetWithHiddenNav(
    context: context,
    ref: ref,
    builder: (context) => InstagramShareSheet(listId: listId, source: source),
  );
}

/// Bottom sheet for submitting an Instagram link to Soko.
///
/// PROD-1863: rebuilt on the new `DSSheetShell` foundation (PROD-1860) with
/// `SokoTextField` for input and a `BtSqIco`-based Cancel/Submit footer
/// matching the create-zine page.
class InstagramShareSheet extends ConsumerStatefulWidget {
  final String? listId;
  final String source;

  const InstagramShareSheet({super.key, this.listId, required this.source});

  @override
  ConsumerState<InstagramShareSheet> createState() =>
      _InstagramShareSheetState();
}

class _InstagramShareSheetState extends ConsumerState<InstagramShareSheet> {
  final _controller = TextEditingController();
  String? _validationError;

  @override
  void initState() {
    super.initState();
    // Rebuild on text changes so the clear suffix and the Submit-button
    // enabled state both react to keystrokes (the controller's value is
    // read directly in build()).
    _controller.addListener(_onControllerChanged);
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    super.dispose();
  }

  void _onControllerChanged() {
    if (_validationError != null) {
      setState(() => _validationError = null);
    } else {
      setState(() {});
    }
  }

  Future<void> _pasteFromClipboard() async {
    final l10n = Lt.of(context);
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) {
      setState(() => _validationError = l10n.instagramSharePasteEmpty);
      return;
    }
    _controller.text = text;
    _controller.selection = TextSelection.collapsed(offset: text.length);
  }

  Future<void> _onSubmit() async {
    final l10n = Lt.of(context);
    final text = _controller.text.trim();

    if (text.isEmpty) {
      setState(() => _validationError = l10n.instagramShareErrorInvalidUrl);
      return;
    }

    final parsed = InstagramUrl.extract(text);
    if (parsed == null) {
      setState(() => _validationError = l10n.instagramShareErrorInvalidUrl);
      return;
    }

    if (parsed.type == InstagramUrlType.tv) {
      setState(() => _validationError = l10n.instagramShareErrorTvNotSupported);
      return;
    }

    ref
        .read(unifiedAnalyticsProvider)
        .trackInstagramLinkSubmitted(
          source: widget.source,
          urlType: parsed.type.name,
          listId: widget.listId,
        );
    final result = await ref
        .read(instagramShareProvider.notifier)
        .submit(parsed.url, listId: widget.listId);

    if (!mounted) return;

    if (result != null) {
      final message = result.status == 'already_pending'
          ? l10n.instagramShareAlreadyPending
          : result.status == 'already_connected'
          ? l10n.instagramShareAlreadyConnected
          : result.isProfile
          ? l10n.instagramShareSuccessProfile
          : l10n.instagramShareSuccessPost;

      showSoko(ref, message: message, variant: SokoVariant.success);

      ref
          .read(instagramSharePollingProvider.notifier)
          .startPollingForResult(result, listId: widget.listId);

      Navigator.of(context).pop();
    } else {
      final error = ref.read(instagramShareProvider).error;
      setState(() {
        _validationError = _errorMessage(error, l10n, parsed.type);
      });
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
    final hasText = _controller.text.trim().isNotEmpty;
    final canSubmit = hasText && !shareState.isSubmitting;

    // Keyboard-aware padding so the sheet rides above the soft keyboard
    // instead of being covered by it. `showModalBottomSheet` with
    // `isScrollControlled: true` does not auto-apply `viewInsets`; the
    // sheet content is responsible for it (same pattern as
    // `import_list_sheet.dart` and `add_to_list_sheet.dart`).
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: DSSheetShell(
        header: _Header(title: l10n.instagramShareSheetTitle),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                l10n.instagramShareSheetDescription,
                style: TextStyle(
                  fontFamily: 'Zalando Sans',
                  fontSize: 14,
                  fontWeight: FontWeight.w300,
                  height: 1.3,
                  letterSpacing: -0.14,
                  color: AppColors.sokoInk.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 16),
              SokoTextField(
                controller: _controller,
                hintText: l10n.instagramShareInputHint,
                autofocus: false,
                textInputAction: TextInputAction.send,
                onSubmitted: (_) {
                  if (canSubmit) _onSubmit();
                },
                prefix: const Icon(
                  Icons.link,
                  size: 18,
                  color: AppColors.sokoShade3,
                ),
                suffix: _controller.text.isEmpty
                    ? IconButton(
                        icon: const Icon(Icons.content_paste, size: 18),
                        color: AppColors.sokoShade3,
                        splashRadius: 18,
                        tooltip: l10n.instagramSharePasteButton,
                        onPressed: _pasteFromClipboard,
                      )
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        color: AppColors.sokoShade3,
                        splashRadius: 18,
                        onPressed: () {
                          _controller.clear();
                          if (_validationError != null) {
                            setState(() => _validationError = null);
                          }
                        },
                      ),
              ),
              if (_validationError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8, left: 4),
                  child: Text(
                    _validationError!,
                    style: const TextStyle(
                      fontFamily: 'Zalando Sans',
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      height: 1.3,
                      letterSpacing: -0.13,
                      color: AppColors.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
        footer: _Footer(
          cancelLabel: MaterialLocalizations.of(context).cancelButtonLabel,
          submitLabel: shareState.isSubmitting
              ? l10n.instagramShareSubmitting
              : l10n.instagramShareSubmitButton,
          canSubmit: canSubmit,
          isSubmitting: shareState.isSubmitting,
          onCancel: () => Navigator.of(context).pop(),
          onSubmit: _onSubmit,
        ),
      ),
    );
  }
}

/// Left-aligned title in Zalando Sans Medium 18 / sokoInk — matches the
/// `_Header` pattern from `location_scope_picker_sheet.dart`.
class _Header extends StatelessWidget {
  final String title;
  const _Header({required this.title});

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

/// Sticky Cancel + Submit footer using the DS `BtSqIco` button — same shape
/// as the create-zine page (`create_zine_screen.dart:307-335`).
class _Footer extends StatelessWidget {
  final String cancelLabel;
  final String submitLabel;
  final bool canSubmit;
  final bool isSubmitting;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  const _Footer({
    required this.cancelLabel,
    required this.submitLabel,
    required this.canSubmit,
    required this.isSubmitting,
    required this.onCancel,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.sokoPaper,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Row(
        children: [
          Expanded(
            child: BtSqIco(
              icon: LucideIcons.x,
              label: cancelLabel,
              variant: BtSqIcoVariant.normal,
              expand: true,
              onTap: isSubmitting ? () {} : onCancel,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Opacity(
              opacity: canSubmit ? 1.0 : 0.5,
              child: isSubmitting
                  ? _SubmittingButton(label: submitLabel)
                  : BtSqIco(
                      icon: LucideIcons.send,
                      label: submitLabel,
                      variant: BtSqIcoVariant.selected,
                      expand: true,
                      onTap: canSubmit ? onSubmit : () {},
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Loading variant of the submit button — mirrors `_CreatingButton` in
/// `create_zine_screen.dart`. Kept private until a third caller appears
/// (PROD-1864 will likely promote this to a shared widget).
class _SubmittingButton extends StatelessWidget {
  final String label;

  const _SubmittingButton({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.sokoPink,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.sokoInk),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              fontFamily: 'Zalando Sans',
              fontSize: 14,
              fontWeight: FontWeight.w300,
              height: 1.2,
              letterSpacing: -0.14,
              color: AppColors.sokoInk,
            ),
          ),
        ],
      ),
    );
  }
}
