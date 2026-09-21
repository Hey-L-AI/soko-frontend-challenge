import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:posthog_flutter/posthog_flutter.dart';

import '../../../core/exceptions/api_exceptions.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart' hide AuthMethod;
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/page_layout.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../profile/providers/public_profile_providers.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../../shared/widgets/clickable.dart';
import '../../../shared/widgets/dotted_section_divider.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../../shared/widgets/soko_form_input.dart';
import '../../discovery/widgets/discovery_shell.dart' show popOrFallback;
import '../../moderation/content_blocked_handler.dart';
import '../widgets/add_email_inline.dart';
import '../widgets/add_phone_inline.dart';

/// Handle validation status for account editing. Moved here from
/// `profile_sheet.dart` since `_AccountContent` + `_AccountHandleSection`
/// are the only consumers and they now live in this file.
enum HandleValidationStatus { idle, checking, available, unavailable, invalid }

/// `/menu/account` page (PROD-2020). Replaces the legacy `_AccountContent`
/// case inside `ProfileSheet`'s drawer. Mirrors `menu_screen.dart`'s shell:
/// `ColoredBox(sokoPaper) → PageContent → SafeArea → Column(_AccountHeader,
/// Expanded(_AccountBody))`. Back button uses `popOrFallback` so deep
/// links work.
///
/// The Merge Accounts sub-flow temporarily falls back to opening the
/// legacy drawer on its merge page until PROD-2023 extracts
/// `/menu/account/merge`. The fallback is rare — merge is only triggered
/// when AddPhoneInline / AddEmailInline detects an identifier that
/// belongs to another account.
class AccountScreen extends ConsumerWidget {
  const AccountScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    return ColoredBox(
      color: AppColors.sokoPaper,
      child: PageContent(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _AccountHeader(
                title: l10n.accountTitle,
                onBack: () => popOrFallback(context),
              ),
              const Expanded(child: _AccountBody()),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountHeader extends StatelessWidget {
  final String title;
  final VoidCallback onBack;

  const _AccountHeader({required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          MouseRegion(
            cursor: SystemMouseCursors.click,
            child: IconButton(
              icon: const Icon(
                LucideIcons.arrow_left,
                color: AppColors.sokoInk,
              ),
              onPressed: onBack,
              tooltip: MaterialLocalizations.of(context).backButtonTooltip,
            ),
          ),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _AccountBody extends ConsumerStatefulWidget {
  const _AccountBody();

  @override
  ConsumerState<_AccountBody> createState() => _AccountBodyState();
}

class _AccountBodyState extends ConsumerState<_AccountBody> {
  final _nameController = TextEditingController();
  final _handleController = TextEditingController();
  bool _isEditingName = false;
  bool _isEditingHandle = false;
  bool _isAddingPhone = false;
  bool _isAddingEmail = false;
  HandleValidationStatus _handleStatus = HandleValidationStatus.idle;
  String? _handleValidationMessage;
  Timer? _handleDebounceTimer;

  // Handle format regex: starts with letter, 3-20 chars, alphanumeric + underscore
  static final _handleRegex = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{2,19}$');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Analytics: same event the legacy drawer fired on _navigateToAccount.
      ref.read(unifiedAnalyticsProvider).trackAccountOpen();
      ref.read(accountProvider.notifier).loadAuthMethods();

      // Deep-link: `?edit=handle` opens the handle field in edit mode (so
      // taps on the "Set your handle" / `@handle` line on /menu route here
      // and land the user directly in the input). `?edit=name` mirrors it
      // for the display-name section. Each value is reset by the cancel /
      // save callbacks; we don't strip the query param afterwards because
      // a stale `?edit=...` on refresh just re-opens the same input.
      final editParam = GoRouterState.of(context).uri.queryParameters['edit'];
      if (editParam == 'handle') {
        setState(() => _isEditingHandle = true);
      } else if (editParam == 'name') {
        setState(() => _isEditingName = true);
      }
    });

    // Initialize name from current user
    final user = ref.read(currentUserProvider);
    _nameController.text = user?.fullName ?? '';
  }

  @override
  void dispose() {
    _nameController.dispose();
    _handleController.dispose();
    _handleDebounceTimer?.cancel();
    super.dispose();
  }

  Future<void> _saveName() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      showSoko(
        ref,
        message: Lt.of(context).accountDisplayNameEmpty,
        variant: SokoVariant.error,
      );
      return;
    }

    bool success = false;
    try {
      success = await ref.read(accountProvider.notifier).updateName(name);
    } catch (e) {
      if (!mounted) return;
      // PROD-2264 — wordlist filter rejection. Renders the backend
      // message in a snackbar and fires `content_blocked` analytics.
      // Falls through to the generic error path if the exception is
      // anything else.
      if (handleContentBlocked(
        ref,
        context,
        e,
        field: ContentBlockedField.profileName,
      )) {
        return;
      }
      rethrow;
    }
    if (!mounted) return;
    if (success) {
      // The profile header reads fullName from publicProfileProvider, so
      // refresh it here — otherwise the name only updates on a manual reload.
      final myHandle = ref.read(currentUserProvider)?.handle;
      if (myHandle != null && myHandle.isNotEmpty) {
        ref.invalidate(publicProfileProvider(myHandle));
      }
      setState(() => _isEditingName = false);
      showSoko(
        ref,
        message: Lt.of(context).accountNameUpdated,
        variant: SokoVariant.success,
      );
    } else {
      // Failure with no thrown moderation error — surface whatever
      // `accountProvider.state.error` carries (the previous version of
      // this method swallowed the failure silently). The provider
      // already wrote a generic message there.
      final err = ref.read(accountProvider).error;
      if (err != null && err.isNotEmpty) {
        showSoko(ref, message: err, variant: SokoVariant.error);
      }
    }
  }

  void _cancelEditName() {
    final user = ref.read(currentUserProvider);
    setState(() {
      _isEditingName = false;
      _nameController.text = user?.fullName ?? '';
    });
  }

  void _onHandleChanged(String value) {
    _handleDebounceTimer?.cancel();

    final handle = value.trim();
    if (handle.isEmpty) {
      setState(() {
        _handleStatus = HandleValidationStatus.idle;
        _handleValidationMessage = null;
      });
      return;
    }

    if (!_handleRegex.hasMatch(handle)) {
      setState(() {
        _handleStatus = HandleValidationStatus.invalid;
        _handleValidationMessage = Lt.of(context).accountHandleInvalid;
      });
      return;
    }

    setState(() {
      _handleStatus = HandleValidationStatus.checking;
      _handleValidationMessage = null;
    });

    _handleDebounceTimer = Timer(const Duration(milliseconds: 500), () async {
      final response = await ref
          .read(accountProvider.notifier)
          .checkHandleAvailability(handle);

      if (!mounted) return;

      if (response == null) {
        setState(() {
          _handleStatus = HandleValidationStatus.idle;
          _handleValidationMessage = null;
        });
      } else if (response.available) {
        setState(() {
          _handleStatus = HandleValidationStatus.available;
          _handleValidationMessage = Lt.of(context).accountHandleAvailable;
        });
      } else {
        setState(() {
          _handleStatus = HandleValidationStatus.unavailable;
          _handleValidationMessage =
              response.message ?? Lt.of(context).accountHandleUnavailable;
        });
      }
    });
  }

  Future<void> _saveHandle() async {
    final handle = _handleController.text.trim();
    if (handle.isEmpty || _handleStatus != HandleValidationStatus.available) {
      return;
    }

    final HandleUpdateResult result;
    try {
      result = await ref.read(accountProvider.notifier).updateHandle(handle);
    } catch (e) {
      if (!mounted) return;
      // PROD-2264 — wordlist filter rejection on profile handle.
      // Inline message under the field (matches the existing
      // `_handleValidationMessage` UX for unavailable/invalid handles)
      // in addition to the snackbar fired by [handleContentBlocked].
      final blocked = ContentBlockedException.tryFrom(e);
      if (blocked != null) {
        final message = resolveContentBlockedMessage(
          blocked,
          Lt.of(context),
          field: ContentBlockedField.profileHandle,
        );
        setState(() {
          _handleStatus = HandleValidationStatus.invalid;
          _handleValidationMessage = message;
        });
        handleContentBlocked(
          ref,
          context,
          blocked,
          field: ContentBlockedField.profileHandle,
        );
        return;
      }
      rethrow;
    }
    if (!mounted) return;

    final l10n = Lt.of(context);

    switch (result) {
      case HandleUpdateResult.success:
        setState(() {
          _isEditingHandle = false;
          _handleStatus = HandleValidationStatus.idle;
          _handleValidationMessage = null;
        });
        showSoko(
          ref,
          message: l10n.accountHandleUpdated,
          variant: SokoVariant.success,
        );
        break;
      case HandleUpdateResult.error:
        final error = ref.read(accountProvider).error;
        setState(() {
          _handleStatus = HandleValidationStatus.invalid;
          _handleValidationMessage = error ?? l10n.accountHandleUpdateFailed;
        });
        break;
    }
  }

  void _cancelEditHandle() {
    _handleDebounceTimer?.cancel();
    setState(() {
      _isEditingHandle = false;
      _handleController.text = '';
      _handleStatus = HandleValidationStatus.idle;
      _handleValidationMessage = null;
    });
  }

  void _addPhone() {
    setState(() {
      _isAddingPhone = true;
      _isAddingEmail = false;
    });
  }

  void _cancelAddPhone() {
    ref.read(accountProvider.notifier).cancelFlow();
    setState(() => _isAddingPhone = false);
  }

  void _onPhoneAdded() {
    setState(() => _isAddingPhone = false);
    ref.read(accountProvider.notifier).loadAuthMethods();
    showSoko(
      ref,
      message: Lt.of(context).verifyAddPhoneSuccess,
      variant: SokoVariant.success,
    );
  }

  void _addEmail() {
    setState(() {
      _isAddingEmail = true;
      _isAddingPhone = false;
    });
  }

  void _cancelAddEmail() {
    ref.read(accountProvider.notifier).cancelFlow();
    setState(() => _isAddingEmail = false);
  }

  void _onEmailAdded() {
    setState(() => _isAddingEmail = false);
    ref.read(accountProvider.notifier).loadAuthMethods();
    showSoko(
      ref,
      message: Lt.of(context).verifyAddEmailSuccess,
      variant: SokoVariant.success,
    );
  }

  void _handleMergeRequired(VerifyResult result) {
    setState(() {
      _isAddingPhone = false;
      _isAddingEmail = false;
    });
    // PROD-2023: the merge sub-flow lives at `/menu/account/merge`.
    // The destination reads `accountState.mergeData` (already
    // populated by AddPhone/AddEmail's verify step) and routes back
    // to `/menu/account` on cancel or success.
    context.push(AppRoutes.menuAccountMerge);
  }

  Future<void> _removeMethod(AuthMethod method) async {
    final confirmed = await showBottomSheetWithHiddenNav<bool>(
      context: context,
      ref: ref,
      builder: (context) =>
          _RemoveMethodSheet(identifier: method.authIdentifier),
    );

    if (confirmed == true && mounted) {
      final success = await ref
          .read(accountProvider.notifier)
          .removeAuthMethod(method.id);
      if (success && mounted) {
        showSoko(
          ref,
          message: Lt.of(context).accountMethodRemoved,
          variant: SokoVariant.success,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final accountState = ref.watch(accountProvider);
    final user = ref.watch(currentUserProvider);
    final l10n = Lt.of(context);

    if (!_isEditingName && _nameController.text != (user?.fullName ?? '')) {
      _nameController.text = user?.fullName ?? '';
    }

    if (accountState.isLoading && accountState.authMethods.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _AccountNameSection(
          displayName: user?.fullName,
          controller: _nameController,
          isEditing: _isEditingName,
          isLoading: accountState.isLoading,
          onEditTap: () => setState(() => _isEditingName = true),
          onSave: _saveName,
          onCancel: _cancelEditName,
        ),
        const SizedBox(height: 16),
        _AccountHandleSection(
          handle: user?.handle,
          hasHandle: user?.hasHandle ?? false,
          controller: _handleController,
          isEditing: _isEditingHandle,
          isLoading: accountState.isLoading,
          validationStatus: _handleStatus,
          validationMessage: _handleValidationMessage,
          onEditTap: () => setState(() => _isEditingHandle = true),
          onChanged: _onHandleChanged,
          onSave: _saveHandle,
          onCancel: _cancelEditHandle,
        ),
        const DottedSectionDivider(),
        // Session-replay: the phone + email sections render the user's own
        // identifiers (and their inline add/verify inputs), so they're masked
        // in native recordings — this is the settings surface where the user
        // views/changes them. Everything else on the account screen stays
        // visible. See posthog_service.dart and auth_shell.dart.
        PostHogMaskWidget(
          child: _AccountAuthMethodSection(
            title: l10n.accountPhone,
            icon: LucideIcons.phone,
            methods: accountState.phoneAuthMethods,
            effectivePrimaryId: accountState.effectivePrimaryId,
            canAdd: accountState.canAddPhone && !_isAddingPhone,
            isAdding: _isAddingPhone,
            onAdd: _addPhone,
            onRemove: _removeMethod,
            inlineAddWidget: _isAddingPhone
                ? AddPhoneInline(
                    onCancel: _cancelAddPhone,
                    onSuccess: _onPhoneAdded,
                    onMergeRequired: _handleMergeRequired,
                  )
                : null,
          ),
        ),
        const SizedBox(height: 16),
        PostHogMaskWidget(
          child: _AccountAuthMethodSection(
            title: l10n.accountEmail,
            icon: LucideIcons.mail,
            methods: accountState.emailAuthMethods,
            effectivePrimaryId: accountState.effectivePrimaryId,
            canAdd: accountState.canAddEmail && !_isAddingEmail,
            isAdding: _isAddingEmail,
            onAdd: _addEmail,
            onRemove: _removeMethod,
            inlineAddWidget: _isAddingEmail
                ? AddEmailInline(
                    onCancel: _cancelAddEmail,
                    onSuccess: _onEmailAdded,
                    onMergeRequired: _handleMergeRequired,
                  )
                : null,
          ),
        ),
        if (accountState.socialAuthMethods.isNotEmpty) ...[
          const SizedBox(height: 16),
          _AccountSocialMethodsSection(
            methods: accountState.socialAuthMethods,
            effectivePrimaryId: accountState.effectivePrimaryId,
            onRemove: _removeMethod,
          ),
        ],
        if (accountState.error != null) ...[
          const SizedBox(height: 16),
          Text(
            accountState.error!,
            style: const TextStyle(color: AppColors.error),
            textAlign: TextAlign.center,
          ),
        ],
        const DottedSectionDivider(),
        // PROD-2264 — Blocked Users management (required by Apple
        // Guideline 1.2). Slotted above Delete Account so it appears
        // with the other "account hygiene" items.
        const _BlockedUsersNavRow(),
        const DottedSectionDivider(),
        const _DeleteAccountSection(),
      ],
    );
  }
}

/// PROD-2264 — Single-row nav entry that pushes the Blocked Users
/// management screen. Mirrors the visual weight of the existing menu
/// rows (icon + label + chevron).
class _BlockedUsersNavRow extends StatelessWidget {
  const _BlockedUsersNavRow();

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return InkWell(
      onTap: () => context.push(AppRoutes.menuAccountBlockedUsers),
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 16),
        child: Row(
          children: [
            const Icon(
              LucideIcons.shield_off,
              size: 20,
              color: AppColors.sokoInk,
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                l10n.accountMenuBlockedUsers,
                style: AppTheme.body(fontSize: 16, color: AppColors.sokoInk),
              ),
            ),
            const Icon(
              LucideIcons.chevron_right,
              size: 20,
              color: AppColors.sokoInkSecondary,
            ),
          ],
        ),
      ),
    );
  }
}

/// Name section with edit functionality.
class _AccountNameSection extends StatelessWidget {
  final String? displayName;
  final TextEditingController controller;
  final bool isEditing;
  final bool isLoading;
  final VoidCallback onEditTap;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  const _AccountNameSection({
    required this.displayName,
    required this.controller,
    required this.isEditing,
    required this.isLoading,
    required this.onEditTap,
    required this.onSave,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(LucideIcons.user, size: 20, color: AppColors.sokoInk),
            const SizedBox(width: 8),
            Text(
              l10n.accountDisplayName,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (isEditing)
          TapRegion(
            onTapOutside: (_) {
              if (isLoading) return;
              FocusManager.instance.primaryFocus?.unfocus();
              onCancel();
            },
            child: SokoFormInput(
              controller: controller,
              hintText: l10n.accountDisplayNameHint,
              autofocus: true,
              textInputAction: TextInputAction.done,
              onSubmitted: isLoading ? null : (_) => onSave(),
              showClearButton: false,
              suffix: _FieldSuffixButton(
                onPressed: isLoading ? null : onSave,
                isLoading: isLoading,
              ),
            ),
          )
        else
          _AccountFieldRow(
            onTap: onEditTap,
            value: displayName?.isEmpty ?? true
                ? l10n.accountDisplayNameNotSet
                : displayName!,
            isPlaceholder: displayName?.isEmpty ?? true,
            trailing: const Icon(
              LucideIcons.pencil,
              size: 18,
              color: AppColors.sokoShade3,
            ),
          ),
      ],
    );
  }
}

/// Handle section with edit functionality and real-time validation.
class _AccountHandleSection extends StatelessWidget {
  final String? handle;
  final bool hasHandle;
  final TextEditingController controller;
  final bool isEditing;
  final bool isLoading;
  final HandleValidationStatus validationStatus;
  final String? validationMessage;
  final VoidCallback onEditTap;
  final ValueChanged<String> onChanged;
  final VoidCallback onSave;
  final VoidCallback onCancel;

  const _AccountHandleSection({
    required this.handle,
    required this.hasHandle,
    required this.controller,
    required this.isEditing,
    required this.isLoading,
    required this.validationStatus,
    this.validationMessage,
    required this.onEditTap,
    required this.onChanged,
    required this.onSave,
    required this.onCancel,
  });

  Color _getValidationColor() {
    switch (validationStatus) {
      case HandleValidationStatus.available:
        return AppColors.success;
      case HandleValidationStatus.unavailable:
      case HandleValidationStatus.invalid:
        return AppColors.error;
      case HandleValidationStatus.checking:
      case HandleValidationStatus.idle:
        return AppColors.sokoShade3;
    }
  }

  IconData? _getValidationIcon() {
    switch (validationStatus) {
      case HandleValidationStatus.available:
        return LucideIcons.circle_check;
      case HandleValidationStatus.unavailable:
      case HandleValidationStatus.invalid:
        return LucideIcons.circle_x;
      case HandleValidationStatus.checking:
      case HandleValidationStatus.idle:
        return null;
    }
  }

  /// Suffix slot for the handle input. Hosts (in priority order) the
  /// in-flight save spinner, the live-validation spinner, the tappable
  /// save check (only when the handle is available), or the validation
  /// error glyph. ALWAYS returns a 48 × 48 widget — even in the `idle`
  /// state — so the field's pill height stays locked at 48 px across
  /// every validation transition. Returning `null` here would collapse
  /// the suffix area and visibly shrink the input on first focus.
  Widget _buildHandleSuffix() {
    if (isLoading || validationStatus == HandleValidationStatus.checking) {
      return const _FieldSuffixButton(onPressed: null, isLoading: true);
    }
    if (validationStatus == HandleValidationStatus.available) {
      return _FieldSuffixButton(onPressed: onSave, isLoading: false);
    }
    final glyph = _getValidationIcon();
    if (glyph != null) {
      return SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: Icon(glyph, size: 20, color: _getValidationColor()),
        ),
      );
    }
    // Idle: invisible 48 × 48 placeholder to keep the input height
    // identical to the display row before the user types anything.
    return const SizedBox(width: 48, height: 48);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(LucideIcons.at_sign, size: 20, color: AppColors.sokoInk),
            const SizedBox(width: 8),
            Text(
              l10n.accountHandle,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (isEditing)
          TapRegion(
            onTapOutside: (_) {
              if (isLoading) return;
              FocusManager.instance.primaryFocus?.unfocus();
              onCancel();
            },
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SokoFormInput(
                  controller: controller,
                  onChanged: onChanged,
                  hintText: l10n.accountHandleHint,
                  autofocus: true,
                  textInputAction: TextInputAction.done,
                  onSubmitted:
                      validationStatus == HandleValidationStatus.available &&
                          !isLoading
                      ? (_) => onSave()
                      : null,
                  showClearButton: false,
                  suffix: _buildHandleSuffix(),
                ),
                // Validation message sits INSIDE the TapRegion on purpose —
                // tapping the hint shouldn't count as "tap outside the input"
                // and therefore shouldn't cancel the edit.
                if (validationMessage != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    validationMessage!,
                    style: TextStyle(
                      color: _getValidationColor(),
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          )
        else
          _AccountFieldRow(
            onTap: onEditTap,
            value: hasHandle ? '@$handle' : l10n.accountHandleNotSet,
            isPlaceholder: !hasHandle,
            trailing: const Icon(
              LucideIcons.pencil,
              size: 18,
              color: AppColors.sokoShade3,
            ),
          ),
      ],
    );
  }
}

/// Auth method section (Phone or Email).
class _AccountAuthMethodSection extends StatelessWidget {
  final String title;
  final IconData icon;
  final List<AuthMethod> methods;
  final String? effectivePrimaryId;
  final bool canAdd;
  final bool isAdding;
  final VoidCallback onAdd;
  final Function(AuthMethod) onRemove;
  final Widget? inlineAddWidget;

  const _AccountAuthMethodSection({
    required this.title,
    required this.icon,
    required this.methods,
    required this.effectivePrimaryId,
    required this.canAdd,
    this.isAdding = false,
    required this.onAdd,
    required this.onRemove,
    this.inlineAddWidget,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 20, color: AppColors.sokoInk),
            const SizedBox(width: 8),
            Text(
              title,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (methods.isNotEmpty)
          ...methods.map(
            (method) => _AccountAuthMethodTile(
              method: method,
              isPrimary: method.id == effectivePrimaryId,
              onRemove: () => onRemove(method),
            ),
          ),
        if (inlineAddWidget != null) ...[
          if (methods.isNotEmpty) const SizedBox(height: 8),
          inlineAddWidget!,
        ] else if (methods.isEmpty)
          _AccountFieldRow(
            onTap: canAdd ? onAdd : null,
            value: l10n.accountAddTitle(title),
            isPlaceholder: true,
            trailing: const Icon(
              LucideIcons.plus,
              size: 18,
              color: AppColors.sokoShade3,
            ),
          )
        else if (canAdd) ...[
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: onAdd,
            icon: const Icon(LucideIcons.plus, size: 18),
            label: Text(l10n.accountAddAnotherTitle(title)),
            style: TextButton.styleFrom(foregroundColor: AppColors.sokoInk),
          ),
        ],
      ],
    );
  }
}

/// Single auth method tile with hover/tap-to-reveal delete.
class _AccountAuthMethodTile extends StatefulWidget {
  final AuthMethod method;
  final bool isPrimary;
  final VoidCallback onRemove;

  const _AccountAuthMethodTile({
    required this.method,
    required this.isPrimary,
    required this.onRemove,
  });

  @override
  State<_AccountAuthMethodTile> createState() => _AccountAuthMethodTileState();
}

class _AccountAuthMethodTileState extends State<_AccountAuthMethodTile> {
  bool _isHovering = false;
  bool _isDeleteRevealed = false;
  Timer? _autoHideTimer;

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    super.dispose();
  }

  void _handleTap() {
    if (widget.isPrimary) return;

    if (kIsWeb) {
      widget.onRemove();
    } else {
      if (_isDeleteRevealed) {
        widget.onRemove();
      } else {
        setState(() => _isDeleteRevealed = true);
        _startAutoHideTimer();
      }
    }
  }

  void _startAutoHideTimer() {
    _autoHideTimer?.cancel();
    _autoHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _isDeleteRevealed = false);
    });
  }

  bool get _showDeleteIcon {
    if (widget.isPrimary) return false;
    return kIsWeb ? _isHovering : _isDeleteRevealed;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _AccountFieldRow(
          isPlaceholder: false,
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  widget.method.authIdentifier,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.sokoInk),
                ),
              ),
              if (widget.isPrimary) ...[
                const SizedBox(width: 8),
                _PrimaryChip(label: l10n.accountPrimary),
              ],
            ],
          ),
          trailing: _buildStatusIcon(context),
        ),
      ),
    );
  }

  Widget _buildStatusIcon(BuildContext context) {
    final l10n = Lt.of(context);

    return Clickable(
      onTap: widget.isPrimary ? null : _handleTap,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: _showDeleteIcon
            ? Tooltip(
                message: l10n.accountRemove,
                child: const Icon(
                  key: ValueKey('delete'),
                  LucideIcons.circle_minus,
                  color: AppColors.error,
                  size: 20,
                ),
              )
            : const Icon(
                key: ValueKey('check'),
                LucideIcons.circle_check,
                color: AppColors.success,
                size: 20,
              ),
      ),
    );
  }
}

/// Social auth methods section (Google / Apple / Facebook).
class _AccountSocialMethodsSection extends StatelessWidget {
  final List<AuthMethod> methods;
  final String? effectivePrimaryId;
  final Function(AuthMethod) onRemove;

  const _AccountSocialMethodsSection({
    required this.methods,
    required this.effectivePrimaryId,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final hasPrimary = methods.any((m) => m.id == effectivePrimaryId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(LucideIcons.link_2, size: 20, color: AppColors.sokoInk),
            const SizedBox(width: 8),
            Text(
              l10n.accountConnectedAccounts,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 14,
                fontWeight: FontWeight.w500,
              ),
            ),
            if (hasPrimary) ...[
              const SizedBox(width: 8),
              _PrimaryChip(label: l10n.accountPrimary),
            ],
          ],
        ),
        const SizedBox(height: 12),
        ...methods.map(
          (method) => _AccountSocialMethodTile(
            method: method,
            isPrimary: method.id == effectivePrimaryId,
            onRemove: () => onRemove(method),
          ),
        ),
      ],
    );
  }
}

/// Single social auth method tile with hover/tap-to-reveal delete.
class _AccountSocialMethodTile extends StatefulWidget {
  final AuthMethod method;
  final bool isPrimary;
  final VoidCallback onRemove;

  const _AccountSocialMethodTile({
    required this.method,
    required this.isPrimary,
    required this.onRemove,
  });

  @override
  State<_AccountSocialMethodTile> createState() =>
      _AccountSocialMethodTileState();
}

class _AccountSocialMethodTileState extends State<_AccountSocialMethodTile> {
  bool _isHovering = false;
  bool _isDeleteRevealed = false;
  Timer? _autoHideTimer;

  @override
  void dispose() {
    _autoHideTimer?.cancel();
    super.dispose();
  }

  void _handleTap() {
    if (widget.isPrimary) return;

    if (kIsWeb) {
      widget.onRemove();
    } else {
      if (_isDeleteRevealed) {
        widget.onRemove();
      } else {
        setState(() => _isDeleteRevealed = true);
        _startAutoHideTimer();
      }
    }
  }

  void _startAutoHideTimer() {
    _autoHideTimer?.cancel();
    _autoHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _isDeleteRevealed = false);
    });
  }

  bool get _showDeleteIcon {
    if (widget.isPrimary) return false;
    return kIsWeb ? _isHovering : _isDeleteRevealed;
  }

  Widget _buildProviderIcon() {
    if (widget.method.authType == 'google') {
      return Image.asset(
        'assets/images/google.png',
        width: 24,
        height: 24,
        errorBuilder: (context, error, stackTrace) {
          return const Icon(LucideIcons.user, size: 24);
        },
      );
    }
    if (widget.method.authType == 'apple') {
      return SvgPicture.asset(
        'assets/images/apple.svg',
        width: 24,
        height: 24,
        colorFilter: const ColorFilter.mode(AppColors.sokoInk, BlendMode.srcIn),
        placeholderBuilder: (_) => const Icon(LucideIcons.apple, size: 24),
      );
    }
    return Icon(_getIcon(widget.method.authType), size: 24);
  }

  IconData _getIcon(String authType) {
    switch (authType) {
      case 'apple':
        return LucideIcons.apple;
      case 'facebook':
        return LucideIcons.facebook;
      default:
        return LucideIcons.log_in;
    }
  }

  String _getLabel(String authType) {
    switch (authType) {
      case 'google':
        return 'Google';
      case 'apple':
        return 'Apple';
      case 'facebook':
        return 'Facebook';
      default:
        return authType;
    }
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _isHovering = true),
      onExit: (_) => setState(() => _isHovering = false),
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _AccountFieldRow(
          isPlaceholder: false,
          leading: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildProviderIcon(),
              const SizedBox(width: 12),
              Flexible(
                child: Text(
                  _getLabel(widget.method.authType),
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: AppColors.sokoInk),
                ),
              ),
            ],
          ),
          trailing: _buildStatusIcon(context),
        ),
      ),
    );
  }

  Widget _buildStatusIcon(BuildContext context) {
    final l10n = Lt.of(context);

    return Clickable(
      onTap: widget.isPrimary ? null : _handleTap,
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 200),
        child: _showDeleteIcon
            ? Tooltip(
                message: l10n.accountRemove,
                child: const Icon(
                  key: ValueKey('delete'),
                  LucideIcons.circle_minus,
                  color: AppColors.error,
                  size: 20,
                ),
              )
            : const Icon(
                key: ValueKey('check'),
                LucideIcons.circle_check,
                color: AppColors.success,
                size: 20,
              ),
      ),
    );
  }
}

/// Danger-zone "Delete account" section. The legacy version took an
/// `onClose` callback (to close the drawer post-delete); on the new
/// page we just `popOrFallback` after sign-out.
class _DeleteAccountSection extends ConsumerStatefulWidget {
  const _DeleteAccountSection();

  @override
  ConsumerState<_DeleteAccountSection> createState() =>
      _DeleteAccountSectionState();
}

class _DeleteAccountSectionState extends ConsumerState<_DeleteAccountSection> {
  bool _isDeleting = false;
  bool _expanded = false;

  Future<void> _showDeleteConfirmation() async {
    final confirmed = await showBottomSheetWithHiddenNav<bool>(
      context: context,
      ref: ref,
      isDismissible: false,
      enableDrag: false,
      builder: (context) => const _DeleteAccountSheet(),
    );

    if (confirmed == true && mounted) {
      await _deleteAccount();
    }
  }

  Future<void> _deleteAccount() async {
    setState(() => _isDeleting = true);

    // Track before deletion so the event is attributed to the user
    ref.read(unifiedAnalyticsProvider).trackAccountDelete();

    try {
      final accountApi = ref.read(accountApiProvider);
      await accountApi.deleteAccount(
        const DeleteAccountRequest(confirmation: 'DELETE'),
      );

      if (mounted) {
        final l10n = Lt.of(context);
        await ref.read(authStateProvider.notifier).logout();
        if (mounted) {
          context.go(AppRoutes.login);
          showSoko(
            ref,
            message: l10n.deleteAccountSuccess,
            variant: SokoVariant.success,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isDeleting = false);
        final l10n = Lt.of(context);
        showSoko(
          ref,
          message: l10n.deleteAccountError,
          variant: SokoVariant.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    final deleteButton = SokoCtaButton(
      icon: LucideIcons.trash_2,
      label: l10n.deleteAccountButton,
      variant: SokoCtaVariant.red,
      loading: _isDeleting,
      onPressed: _showDeleteConfirmation,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    l10n.deleteAccountDangerZone,
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      color: AppColors.error,
                      fontSize: 13,
                    ),
                  ),
                ),
                Icon(
                  _expanded ? LucideIcons.chevron_up : LucideIcons.chevron_down,
                  size: 18,
                  color: AppColors.sokoShade3,
                ),
              ],
            ),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeInOut,
          alignment: Alignment.topCenter,
          child: _expanded
              ? Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: deleteButton,
                )
              : const SizedBox(width: double.infinity),
        ),
      ],
    );
  }
}

/// Delete-account confirmation sheet. Replaces the previous
/// [AlertDialog] so every destructive confirm in `/menu` lives in a
/// `DSSheetShell` bottom sheet (matches `_RemoveMethodSheet`,
/// `_DisconnectInstagramSheet`, etc.). User must type the localized
/// confirmation word ([Lt.deleteAccountConfirmHint] — "DELETE" in en/pt,
/// "ELIMINAR" in es) before the destructive button enables.
class _DeleteAccountSheet extends StatefulWidget {
  const _DeleteAccountSheet();

  @override
  State<_DeleteAccountSheet> createState() => _DeleteAccountSheetState();
}

class _DeleteAccountSheetState extends State<_DeleteAccountSheet> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    // Rebuild only. Validity is judged in `build`, because the word the user
    // must type is localized ([Lt.deleteAccountConfirmHint]) and `l10n` is not
    // available here.
    _controller.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

    // The confirmation word is whatever the sheet asked the reader to type, so
    // the hint is the single source of truth. It used to be the hardcoded
    // English literal 'DELETE' while es-MX had already been translated to
    // "ELIMINAR" — a Spanish reader typed exactly what the label told them to
    // and the button stayed disabled forever, with no error. Reading the key
    // here means a future translation of the hint can never desync from the
    // check again.
    final isValid = _controller.text == l10n.deleteAccountConfirmHint;

    return AnimatedPadding(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
      padding: EdgeInsets.only(bottom: keyboardInset),
      child: DSSheetShell(
        bodyPadding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.deleteAccountDialogTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'ZalandoSans',
                fontSize: 18,
                fontWeight: FontWeight.w700,
                height: 1.0,
                letterSpacing: -0.36,
                color: AppColors.sokoInk,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.deleteAccountDialogContent,
              style: const TextStyle(
                fontFamily: 'ZalandoSans',
                fontSize: 14,
                fontWeight: FontWeight.w300,
                height: 1.3,
                letterSpacing: -0.14,
                color: AppColors.sokoInk,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              l10n.deleteAccountConfirmLabel,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            SokoFormInput(
              controller: _controller,
              hintText: l10n.deleteAccountConfirmHint,
              autofocus: true,
              showClearButton: false,
            ),
            const SizedBox(height: 20),
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: BtSqIco(
                    icon: LucideIcons.x,
                    label: l10n.commonCancel,
                    variant: BtSqIcoVariant.normal,
                    expand: true,
                    onTap: () => Navigator.of(context).pop(false),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: IgnorePointer(
                    ignoring: !isValid,
                    child: Opacity(
                      opacity: isValid ? 1.0 : 0.5,
                      child: BtSqIco(
                        icon: LucideIcons.trash_2,
                        label: l10n.deleteAccountConfirmButton,
                        variant: BtSqIcoVariant.selected,
                        selectedBackgroundOverride: AppColors.sokoRed,
                        expand: true,
                        onTap: () => Navigator.of(context).pop(true),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Confirmation sheet for removing an auth method (phone, email, or
/// connected Google account). Replaces the previous [AlertDialog] —
/// matches the Soko sheet pattern used by [LoginPromptSheet] so the
/// account screen flows feel consistent with the rest of the app.
class _RemoveMethodSheet extends StatelessWidget {
  const _RemoveMethodSheet({required this.identifier});

  final String identifier;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return DSSheetShell(
      // Canonical 14 px gap from buttons → sheet bottom (the value every
      // other DS sticky footer uses). The nav is already hidden while
      // the sheet is open via `showBottomSheetWithHiddenNav`, so we
      // don't need to layer in `bottomNavClearance` here.
      bodyPadding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            l10n.accountRemoveMethodTitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'ZalandoSans',
              fontSize: 18,
              fontWeight: FontWeight.w700,
              height: 1.0,
              letterSpacing: -0.36,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            l10n.accountRemoveMethodContent(identifier),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'ZalandoSans',
              fontSize: 14,
              fontWeight: FontWeight.w300,
              height: 1.2,
              letterSpacing: -0.14,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: BtSqIco(
                  icon: LucideIcons.x,
                  label: l10n.commonCancel,
                  variant: BtSqIcoVariant.normal,
                  expand: true,
                  onTap: () => Navigator.of(context).pop(false),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: BtSqIco(
                  icon: LucideIcons.trash_2,
                  label: l10n.accountRemoveMethodConfirm,
                  variant: BtSqIcoVariant.selected,
                  selectedBackgroundOverride: AppColors.sokoRed,
                  expand: true,
                  onTap: () => Navigator.of(context).pop(true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Pill chip used to mark the primary auth method. Sits inline beside the
/// method's identifier (phone/email tiles) OR beside the section title
/// for "Connected Accounts" (social methods) — see `docs/ui/design-decisions.md`
/// **D156** for the section-vs-row placement rationale (it avoids arbitrarily
/// flagging one of two visually-identical "Google" rows as primary when the
/// backend has `people/<sub>` and bare `<sub>` duplicates).
/// Soko-branded display-row used by every `/menu/account` field
/// (display name, handle, phone/email tile, social-provider tile,
/// empty-state add button). Matches the canonical chat-input visual
/// language — `sokoShade5` fill, no border, 6 px radius — so the
/// read-only state of each field reads as the same family as the
/// `SokoFormInput` it swaps into on edit. When `onTap` is non-null
/// the row is tappable (cursor + InkWell ripple); otherwise it's
/// non-interactive.
class _AccountFieldRow extends StatelessWidget {
  const _AccountFieldRow({
    this.onTap,
    this.value,
    this.leading,
    this.trailing,
    this.isPlaceholder = false,
  });

  /// Right-most affordance (pencil for editable, lock for locked,
  /// `circle_check` for verified, `plus` for empty-state add).
  final Widget? trailing;

  /// Tap callback. When null the row is non-interactive (e.g. the
  /// locked-handle row, or a verified phone/email with no action).
  final VoidCallback? onTap;

  /// Simple text value. Pass `value` for the standard display rows;
  /// for tiles that need richer content (e.g. provider icon + label,
  /// or identifier + primary chip), pass `leading` instead.
  final String? value;

  /// Custom leading widget — takes precedence over `value`. Used by
  /// the phone/email and social-provider tiles which need a leading
  /// glyph + chip.
  final Widget? leading;

  /// When true, the text renders in `sokoShade3` (used for empty-state
  /// placeholders like "Not set" or "Add Email").
  final bool isPlaceholder;

  @override
  Widget build(BuildContext context) {
    // Fixed 48 px height matches the unfocused edit-mode `SokoFormInput`
    // (drawn here at the row level with a 1 px bottom border so display
    // ↔ edit transition is pixel-stable). Border colour and weight match
    // `SokoFormInput`'s unfocused state.
    final content = SizedBox(
      height: 48,
      child: Row(
        children: [
          Expanded(
            child:
                leading ??
                Text(
                  value ?? '',
                  style: TextStyle(
                    fontFamily: 'Zalando Sans',
                    fontSize: 16,
                    fontWeight: FontWeight.w300,
                    height: 1.2,
                    letterSpacing: -0.14,
                    color: isPlaceholder
                        ? AppColors.sokoShade3
                        : AppColors.sokoInk,
                  ),
                ),
          ),
          if (trailing != null) ...[const SizedBox(width: 12), trailing!],
        ],
      ),
    );

    final decoration = const BoxDecoration(
      border: Border(bottom: BorderSide(color: AppColors.border, width: 1)),
    );

    if (onTap == null) {
      return DecoratedBox(decoration: decoration, child: content);
    }

    return DecoratedBox(
      decoration: decoration,
      child: Material(
        color: Colors.transparent,
        child: InkWell(onTap: onTap, child: content),
      ),
    );
  }
}

/// Fixed 48 × 48 suffix slot for edit-mode `SokoFormInput` in the
/// account screen. Renders either a tappable check (`onPressed`
/// provided + not loading) or a centered inline spinner (`isLoading`).
/// Locking both states to the same 48 px height keeps the field's
/// overall height constant across idle / loading / available
/// transitions, so the input doesn't jitter when validation runs.
class _FieldSuffixButton extends StatelessWidget {
  const _FieldSuffixButton({required this.onPressed, required this.isLoading});

  final VoidCallback? onPressed;
  final bool isLoading;

  @override
  Widget build(BuildContext context) {
    if (isLoading) {
      return const SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.sokoInk,
            ),
          ),
        ),
      );
    }
    return SizedBox(
      width: 48,
      height: 48,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: const Center(
            child: Icon(LucideIcons.check, size: 20, color: AppColors.sokoInk),
          ),
        ),
      ),
    );
  }
}

class _PrimaryChip extends StatelessWidget {
  final String label;

  const _PrimaryChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.sokoPink,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppColors.sokoInk,
          fontSize: 11,
          fontWeight: FontWeight.w500,
          height: 1.0,
        ),
      ),
    );
  }
}
