import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/services/storage_service.dart';
import '../../business_home/providers/business_session_provider.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/instagram_connection.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/bt_sq_ico.dart';

String? _claimResultFromStatus(String? status) =>
    status?.startsWith('claim_') == true
    ? status!.substring('claim_'.length)
    : null;

bool _isSuccessfulClaimResult(String? result) => switch (result) {
  'verified' || 'pending' || 'dispute' => true,
  _ => false,
};

/// Screen that handles the Instagram OAuth callback.
///
/// The backend redirects to `/integrations/instagram?status=success|error|duplicate&reason=<code>`
/// after the Instagram OAuth flow completes.
///
/// On web, the page does a full reload after returning from Instagram OAuth
/// (because `launchUrl(_self)` navigates the same tab). This screen waits for
/// auth initialization before processing, and handles the case where the
/// session was lost during the redirect (token expired while on Instagram).
class InstagramCallbackScreen extends ConsumerStatefulWidget {
  final String? status;
  final String? reason;
  final String? claimDuplicateKey;

  const InstagramCallbackScreen({
    super.key,
    this.status,
    this.reason,
    this.claimDuplicateKey,
  });

  @override
  ConsumerState<InstagramCallbackScreen> createState() =>
      _InstagramCallbackScreenState();
}

class _InstagramCallbackScreenState
    extends ConsumerState<InstagramCallbackScreen> {
  bool _processed = false;
  bool _isConfirming = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _processCallback();
    });
  }

  Future<void> _processCallback() async {
    if (_processed) return;
    _processed = true;

    // Wait for auth to initialize (on web, reads token from IndexedDB after page reload)
    await _waitForAuthInitialized();

    final claimResult = _claimResultFromStatus(widget.status);
    if (claimResult == 'duplicate') {
      await _handleClaimDuplicate();
      return;
    }
    if (claimResult != null) {
      await _handleClaimResult(claimResult);
      return;
    }

    final isDuplicate = widget.status == 'duplicate';
    final success = widget.status == 'success';
    final analytics = ref.read(unifiedAnalyticsProvider);
    analytics.trackInstagramConnectResult(
      success: success,
      reason: widget.reason,
    );

    // Business Connect (PROD-4040): a connect started from the portal persisted
    // where to return before the full-page OAuth reload. Consume it once here
    // (whatever the outcome) so it can't leak into a later, non-business
    // connect; the success branch below routes back to it.
    final storage = ref.read(storageServiceProvider);
    final businessReturn = storage.getBusinessConnectReturnPath();
    if (businessReturn != null) {
      await storage.clearBusinessConnectReturnPath();
    }

    if (isDuplicate) {
      await _handleDuplicate();
    } else if (success) {
      final authState = ref.read(authStateProvider);

      if (authState.isAuthenticated) {
        // Session survived — load connections and navigate home
        await ref
            .read(instagramProvider.notifier)
            .handleCallbackResult(true, null);

        if (!mounted) return;

        await Future.delayed(const Duration(milliseconds: 1500));
        if (mounted) {
          showSoko(
            ref,
            message: Lt.of(context).instagramConnectionSuccess,
            variant: SokoVariant.success,
          );
          if (businessReturn != null && businessReturn.isNotEmpty) {
            // Re-arm the business session the reload wiped, then return to the
            // portal — both keep the owner out of consumer onboarding.
            ref.read(businessSessionActiveProvider.notifier).state = true;
            context.go(businessReturn);
          } else {
            context.go(AppRoutes.home);
          }
        }
      } else {
        // Session lost during Instagram OAuth (token expired while away).
        // Instagram IS connected on the backend — the user just needs to re-login.
        if (!mounted) return;

        debugPrint(
          '[InstagramCallback] Session lost during OAuth — redirecting to login',
        );
        await Future.delayed(const Duration(milliseconds: 1000));
        if (mounted) {
          showSoko(
            ref,
            message: Lt.of(context).instagramSessionExpiredRelogin,
            variant: SokoVariant.info,
            duration: const Duration(seconds: 5),
          );
          context.go(AppRoutes.login);
        }
      }
    } else {
      // Error case — update provider state (UI is built from widget.status)
      await ref
          .read(instagramProvider.notifier)
          .handleCallbackResult(false, widget.reason);
    }
  }

  /// Claim OAuth returns `claim_verified` / `claim_pending` rather than the
  /// generic connection result. It must never load or create an Instagram
  /// connection: claim-only OAuth deliberately retains no long-lived token.
  Future<void> _handleClaimResult(String result) async {
    if (!mounted) return;
    final l10n = Lt.of(context);
    final (message, variant) = switch (result) {
      'verified' => (l10n.businessOwnershipClaimVerified, SokoVariant.success),
      'pending' ||
      'dispute' => (l10n.businessOwnershipClaimPending, SokoVariant.info),
      _ => (l10n.businessOwnershipClaimStartFailure, SokoVariant.error),
    };
    showSoko(ref, message: message, variant: variant);
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _returnToClaimVenue();
  }

  /// A duplicate Instagram account on a claim is distinct from the generic
  /// Instagram connection duplicate flow: the claimant may ask for a manual
  /// review instead of taking over the connection.
  Future<void> _handleClaimDuplicate() async {
    final pendingKey = widget.claimDuplicateKey;
    if (pendingKey == null || pendingKey.isEmpty) {
      await _showClaimDuplicateFailure();
      return;
    }

    final confirmed = await showBottomSheetWithHiddenNav<bool>(
      context: context,
      ref: ref,
      isDismissible: false,
      enableDrag: false,
      builder: (context) {
        final l10n = Lt.of(context);
        return DSSheetShell(
          bodyPadding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.businessOwnershipClaimDuplicateTitle,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Text(l10n.businessOwnershipClaimDuplicateDescription),
            ],
          ),
          footer: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 14),
            child: Row(
              children: [
                Expanded(
                  child: BtSqIco(
                    icon: LucideIcons.x,
                    label: l10n.commonCancel,
                    variant: BtSqIcoVariant.normal,
                    expand: true,
                    onTap: () => Navigator.pop(context, false),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: BtSqIco(
                    icon: LucideIcons.chevrons_right,
                    label: l10n.businessOwnershipClaimDuplicateConfirm,
                    variant: BtSqIcoVariant.selected,
                    expand: true,
                    onTap: () => Navigator.pop(context, true),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );

    if (!mounted) return;
    if (confirmed != true) {
      await _returnToClaimVenue();
      return;
    }

    setState(() => _isConfirming = true);
    try {
      await ref
          .read(venueClaimApiProvider)
          .confirmPendingVenueClaim(pendingKey);
      if (!mounted) return;
      showSoko(
        ref,
        message: Lt.of(context).businessOwnershipClaimPending,
        variant: SokoVariant.info,
      );
      await Future<void>.delayed(const Duration(milliseconds: 600));
      await _returnToClaimVenue();
    } catch (_) {
      if (!mounted) return;
      setState(() => _isConfirming = false);
      await _showClaimDuplicateFailure();
    }
  }

  Future<void> _showClaimDuplicateFailure() async {
    showSoko(
      ref,
      message: Lt.of(context).businessOwnershipClaimDuplicateFailure,
      variant: SokoVariant.error,
    );
    await Future<void>.delayed(const Duration(milliseconds: 600));
    await _returnToClaimVenue();
  }

  Future<void> _returnToClaimVenue() async {
    final storage = ref.read(storageServiceProvider);
    final venueId = storage.getPendingVenueClaimVenueId();
    await storage.clearPendingVenueClaimVenueId();
    // A claim started from the Business Connect portal returns there (re-arming
    // the business session the OAuth reload wiped) so the owner sees the venue
    // under "Your venues", rather than the public venue detail or /home.
    final businessReturn = storage.getBusinessConnectReturnPath();
    if (businessReturn != null && businessReturn.isNotEmpty) {
      await storage.clearBusinessConnectReturnPath();
      if (!mounted) return;
      ref.read(businessSessionActiveProvider.notifier).state = true;
      context.go(businessReturn);
      return;
    }
    if (!mounted) return;
    context.go(
      venueId == null || venueId.isEmpty ? AppRoutes.home : '/venues/$venueId',
    );
  }

  /// Handle duplicate status: fetch pending details, show warning dialog
  Future<void> _handleDuplicate() async {
    final pendingKey = widget.reason;
    if (pendingKey == null || pendingKey.isEmpty) {
      if (mounted) {
        _showErrorAndGoHome(Lt.of(context).instagramErrorDefault);
      }
      return;
    }

    try {
      final pending = await ref
          .read(instagramProvider.notifier)
          .fetchPendingConnection(pendingKey);

      if (!mounted) return;
      await _showDuplicateWarningDialog(pending, pendingKey);
    } on DioException catch (e) {
      if (!mounted) return;
      final l10n = Lt.of(context);
      if (e.response?.statusCode == 404) {
        _showErrorAndGoHome(l10n.instagramDuplicateExpired);
      } else {
        _showErrorAndGoHome(l10n.instagramErrorDefault);
      }
    } catch (e) {
      debugPrint('[InstagramCallback] fetchPendingConnection error: $e');
      if (mounted) {
        _showErrorAndGoHome(Lt.of(context).instagramErrorDefault);
      }
    }
  }

  /// Show the duplicate warning dialog
  Future<void> _showDuplicateWarningDialog(
    PendingConnectionResponse pending,
    String pendingKey,
  ) async {
    final l10n = Lt.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Row(
          children: [
            const Icon(
              Icons.warning_amber_rounded,
              color: AppColors.warning,
              size: 24,
            ),
            const SizedBox(width: 8),
            Expanded(child: Text(l10n.instagramDuplicateTitle)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.instagramDuplicateBody(pending.igUsername)),
            if (pending.existingConnections.isNotEmpty) ...[
              const SizedBox(height: 16),
              ...pending.existingConnections.map(
                (conn) => Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: Text(
                    l10n.instagramDuplicateConnectedTo(conn.displayName),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.warning),
            child: Text(l10n.instagramDuplicateConfirm),
          ),
        ],
      ),
    );

    if (!mounted) return;

    if (confirmed == true) {
      await _confirmDuplicateConnection(pendingKey);
    } else {
      context.go(AppRoutes.home);
    }
  }

  /// Confirm the pending connection
  Future<void> _confirmDuplicateConnection(String pendingKey) async {
    setState(() => _isConfirming = true);

    final success = await ref
        .read(instagramProvider.notifier)
        .confirmPendingConnection(pendingKey);

    if (!mounted) return;

    if (success) {
      showSoko(
        ref,
        message: Lt.of(context).instagramDuplicateSuccess,
        variant: SokoVariant.success,
      );
      context.go(AppRoutes.home);
    } else {
      setState(() => _isConfirming = false);
      _showErrorAndGoHome(Lt.of(context).instagramErrorDefault);
    }
  }

  void _showErrorAndGoHome(String message) {
    showSoko(
      ref,
      message: message,
      variant: SokoVariant.error,
      duration: const Duration(seconds: 4),
    );
    context.go(AppRoutes.home);
  }

  /// Wait for auth state to be initialized (token restored from storage).
  /// On web after a full page reload, this is async (IndexedDB read).
  Future<void> _waitForAuthInitialized() async {
    final authState = ref.read(authStateProvider);
    if (authState.isInitialized) return;

    final completer = Completer<void>();
    final sub = ref.listenManual(authStateProvider, (prev, next) {
      if (next.isInitialized && !completer.isCompleted) {
        completer.complete();
      }
    });

    try {
      await completer.future.timeout(
        const Duration(seconds: 10),
        onTimeout: () {
          debugPrint('[InstagramCallback] Auth init timed out after 10s');
        },
      );
    } finally {
      sub.close();
    }
  }

  void _tryAgain() {
    final analytics = ref.read(unifiedAnalyticsProvider);
    analytics.trackInstagramConnectStart();
    ref.read(instagramProvider.notifier).startConnect();
  }

  void _goHome() {
    context.go(AppRoutes.home);
  }

  /// Map error reason codes to localized user-facing messages
  String _getErrorMessage(String? reason) {
    final l10n = Lt.of(context);
    switch (reason) {
      case 'oauth_denied':
        return l10n.instagramErrorOauthDenied;
      case 'invalid_request':
        return l10n.instagramErrorInvalidRequest;
      case 'invalid_state':
        return l10n.instagramErrorInvalidState;
      case 'missing_user_id':
        return l10n.instagramErrorMissingUserId;
      case 'api_error':
        return l10n.instagramErrorApiError;
      case 'server_error':
        return l10n.instagramErrorServerError;
      case 'not_configured':
        return l10n.instagramErrorNotConfigured;
      default:
        return l10n.instagramErrorDefault;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final claimResult = _claimResultFromStatus(widget.status);
    final isClaimResult =
        _isSuccessfulClaimResult(claimResult) || claimResult == 'duplicate';
    final isSuccess = widget.status == 'success' || isClaimResult;
    final isDuplicate = widget.status == 'duplicate';

    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (isSuccess || isDuplicate || _isConfirming) ...[
                const Icon(Icons.check_circle, size: 64, color: Colors.green),
                const SizedBox(height: 24),
                Text(
                  isDuplicate
                      ? l10n.instagramCallbackProcessing
                      : switch (claimResult) {
                          'verified' => l10n.businessOwnershipClaimVerified,
                          'pending' ||
                          'dispute' => l10n.businessOwnershipClaimPending,
                          'duplicate' =>
                            l10n.businessOwnershipClaimDuplicateTitle,
                          _ => l10n.instagramConnectionSuccess,
                        },
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 8),
                const CircularProgressIndicator(),
              ] else ...[
                const Icon(
                  Icons.error_outline,
                  size: 64,
                  color: AppColors.error,
                ),
                const SizedBox(height: 24),
                Text(
                  _getErrorMessage(widget.reason),
                  style: Theme.of(context).textTheme.titleMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: 200,
                  child: ElevatedButton(
                    onPressed: _tryAgain,
                    child: Text(l10n.instagramTryAgain),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: 200,
                  child: OutlinedButton(
                    onPressed: _goHome,
                    child: Text(l10n.instagramBackToHome),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
