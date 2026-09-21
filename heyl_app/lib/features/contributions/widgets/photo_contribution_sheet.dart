import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/exceptions/api_exceptions.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../providers/contribution_polling_provider.dart';
import '../providers/contribution_submit_provider.dart';
import 'photo_contribution_form.dart';
import 'photo_contribution_image_picker.dart';

/// Open the photo→event contribution sheet.
///
/// Refuses (with an info snackbar via `showSoko` if a previous contribution
/// is still being polled — keeps both flows from coexisting in a confusing
/// way. Caller responsibilities:
///   - guard against guests upstream (`CreateMenuSheet` already does this)
///   - hide the bottom nav (handled by `showBottomSheetWithHiddenNav`)
Future<void> showPhotoContributionSheet(
  BuildContext context, {
  required WidgetRef ref,
  required String source,
}) async {
  final polling = ref.read(contributionPollingProvider);
  if (polling.isProcessing) {
    // Don't open a second sheet while one is still in flight; the banner
    // (or the user's own awareness) covers the existing submission.
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.showSnackBar(
      SnackBar(content: Text(Lt.of(context).photoContributionWaitForPrevious)),
    );
    return;
  }
  ref.read(unifiedAnalyticsProvider).trackPhotoContributionOpen(source: source);
  await showBottomSheetWithHiddenNav(
    context: context,
    ref: ref,
    builder: (sheetCtx) => _PhotoContributionSheet(source: source),
  );
}

/// Two-step orchestrator: pick → form. After submit the sheet pops
/// immediately and the global `NotificationHost` adapter takes over,
/// driving the loading/success/failure toasts off
/// [contributionPollingProvider] — same shape as IG share and Maps import.
class _PhotoContributionSheet extends ConsumerStatefulWidget {
  final String source;
  const _PhotoContributionSheet({required this.source});

  @override
  ConsumerState<_PhotoContributionSheet> createState() =>
      _PhotoContributionSheetState();
}

enum _Step { pick, form }

class _PhotoContributionSheetState
    extends ConsumerState<_PhotoContributionSheet> {
  final _picker = ContributionImagePicker();
  _Step _step = _Step.pick;
  PickedContributionImage? _image;
  String? _pickError; // localized
  String? _submitError; // localized

  /// Captured in `didChangeDependencies` so `_closeSheet` can pop the
  /// SHEET specifically — `Navigator.maybePop` would pop whatever's on
  /// top, which may be the fullscreen image viewer the user opened
  /// while the upload was in flight (PROD-2429 item 2).
  ModalRoute<dynamic>? _sheetRoute;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sheetRoute ??= ModalRoute.of(context);
  }

  @override
  Widget build(BuildContext context) {
    return DSSheetShell(
      body: switch (_step) {
        // Pick step sizes to its intrinsic content (title + two CTAs); no
        // explicit height cap so the sheet hugs the buttons.
        _Step.pick => _PickStep(
          onPickCamera: () => _handlePick(camera: true),
          onPickGallery: () => _handlePick(camera: false),
          errorMessage: _pickError,
        ),
        _Step.form => PhotoContributionForm(
          image: _image!,
          onSubmit: _handleFormSubmit,
          onRetake: () => setState(() {
            _step = _Step.pick;
            _image = null;
            _pickError = null;
          }),
          onCancel: _closeSheet,
          isSubmitting: ref.watch(contributionSubmitProvider).isSubmitting,
          topLevelError: _submitError,
        ),
      },
    );
  }

  Future<void> _handlePick({required bool camera}) async {
    final l10n = Lt.of(context);
    setState(() => _pickError = null);

    final result = camera
        ? await _picker.pickFromCamera()
        : await _picker.pickFromGallery();
    if (!mounted) return;

    if (result.isSuccess) {
      setState(() {
        _image = result.image;
        _step = _Step.form;
        _submitError = null;
      });
      return;
    }
    setState(() => _pickError = _mapPickFailure(result.failure!, l10n));
  }

  Future<void> _handleFormSubmit(PhotoContributionFormValues values) async {
    final image = _image;
    if (image == null) return;
    setState(() => _submitError = null);

    ref
        .read(unifiedAnalyticsProvider)
        .trackEventSuggested(
          source: widget.source,
          hasNote: values.note != null,
          hasVenue: values.venueId != null,
          city: values.city,
          country: values.country,
        );

    final submitted = await ref
        .read(contributionSubmitProvider.notifier)
        .submit(
          bytes: image.bytes,
          filename: image.filename,
          contentType: image.contentType,
          city: values.city,
          country: values.country,
          note: values.note,
          venueId: values.venueId,
          link: values.link,
        );
    if (!mounted) return;
    if (submitted != null) {
      // Submit provider already kicked the polling banner. Close the sheet
      // and let `NotificationHost` show the processing → success/failure
      // toasts — same shape as the IG-share flow.
      _closeSheet();
      return;
    }
    final err = ref.read(contributionSubmitProvider).error;
    setState(() => _submitError = _mapSubmitError(err, Lt.of(context)));
  }

  void _closeSheet() {
    final route = _sheetRoute;
    final nav = Navigator.of(context, rootNavigator: true);
    if (route == null || !route.isActive) {
      nav.maybePop();
      return;
    }
    if (route.isCurrent) {
      // Sheet is the topmost route → standard pop runs the
      // slide-down animation.
      nav.pop();
    } else {
      // Something is layered above the sheet (e.g. the fullscreen
      // image viewer the user opened while the upload was in flight).
      // `removeRoute` drops the sheet silently from underneath; the
      // top-of-stack route stays put so closing it lands the user on
      // the page beneath the sheet.
      nav.removeRoute(route);
    }
  }

  String _mapPickFailure(ContributionPickFailure f, Lt l10n) {
    switch (f) {
      case ContributionPickFailure.tooLarge:
        return l10n.photoContributionErrorTooLarge;
      case ContributionPickFailure.unsupportedType:
        return l10n.photoContributionErrorWrongType;
      case ContributionPickFailure.dismissed:
        return ''; // no error visible if the user cancelled the OS picker
      case ContributionPickFailure.unknown:
        return l10n.photoContributionErrorGeneric;
    }
  }

  String _mapSubmitError(Object? error, Lt l10n) {
    if (error is ContentBlockedException) {
      final msg = error.userMessage.trim();
      return msg.isNotEmpty ? msg : l10n.photoContributionErrorContentRejected;
    }
    if (error is ImageModerationUnavailableException) {
      return l10n.photoContributionErrorModerationDown;
    }
    if (error is ContributionWaitForPreviousException) {
      return l10n.photoContributionWaitForPrevious;
    }
    if (error is ApiException) {
      final code = error.statusCode;
      // PROD-2430 link rejections come back as 422 / 503 with
      // `detail.error_code` set to one of the LINK_* strings.
      final errorCode = _extractErrorCode(error.data);
      switch (errorCode) {
        case 'LINK_TOO_LONG':
          return l10n.photoContributionLinkErrorTooLong;
        case 'LINK_MALFORMED':
          return l10n.photoContributionLinkErrorMalformed;
        case 'LINK_NOT_HTTPS':
          return l10n.photoContributionLinkErrorNotHttps;
        case 'LINK_UNSAFE':
          return l10n.photoContributionLinkErrorUnsafe;
        case 'LINK_VALIDATION_UNAVAILABLE':
          return l10n.photoContributionLinkErrorValidationUnavailable;
      }
      if (code == 413) return l10n.photoContributionErrorTooLarge;
      if (code == 415) return l10n.photoContributionErrorWrongType;
    }
    return l10n.photoContributionErrorGeneric;
  }

  String? _extractErrorCode(dynamic data) {
    if (data is Map) {
      final detail = data['detail'];
      if (detail is Map) {
        final code = detail['error_code'];
        if (code is String) return code;
      }
    }
    return null;
  }
}

class _PickStep extends StatelessWidget {
  const _PickStep({
    required this.onPickCamera,
    required this.onPickGallery,
    this.errorMessage,
  });

  final VoidCallback onPickCamera;
  final VoidCallback onPickGallery;
  final String? errorMessage;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.photoContributionSheetTitle,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w500,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.photoContributionSheetSubtitle,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w300,
              color: AppColors.sokoInk.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 20),
          SokoCtaButton(
            label: l10n.photoContributionPickFromCamera,
            icon: Icons.camera_alt_outlined,
            variant: SokoCtaVariant.ink,
            onPressed: onPickCamera,
          ),
          const SizedBox(height: 10),
          SokoCtaButton(
            label: l10n.photoContributionPickFromGallery,
            icon: Icons.photo_library_outlined,
            variant: SokoCtaVariant.pink,
            onPressed: onPickGallery,
          ),
          if (errorMessage != null && errorMessage!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              errorMessage!,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: Color(0xFFE45757)),
            ),
          ],
        ],
      ),
    );
  }
}
