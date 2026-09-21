import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/storage_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../business_home/providers/business_session_provider.dart';
import '../../business_home/utils/business_return_state.dart';

/// Status of the OAuth callback processing
enum OAuthStatus { processing, verifying, success, error }

/// Screen that handles the OAuth callback (Google sign-in deep-link return).
/// Lives inside [AuthShell] so the SokoBrandHeader + sokoPaper surface
/// match the rest of the auth funnel.
class OAuthCallbackScreen extends ConsumerStatefulWidget {
  final String? accessToken;
  final String? refreshToken;
  final String? error;

  /// PROD-4040 T2.4: the backend-validated Business Connect return target from
  /// the callback URL. When present, it's the authoritative post-login
  /// destination (an owner who logged in from a business link).
  final String? businessReturnTo;

  const OAuthCallbackScreen({
    super.key,
    this.accessToken,
    this.refreshToken,
    this.error,
    this.businessReturnTo,
  });

  @override
  ConsumerState<OAuthCallbackScreen> createState() =>
      _OAuthCallbackScreenState();
}

class _OAuthCallbackScreenState extends ConsumerState<OAuthCallbackScreen> {
  OAuthStatus _status = OAuthStatus.processing;
  String? _errorMessage;
  bool _isRetrying = false;

  @override
  void initState() {
    super.initState();
    // Delay to avoid modifying provider state during widget build
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _processCallback();
    });
  }

  Future<void> _processCallback() async {
    final authNotifier = ref.read(authStateProvider.notifier);

    if (widget.error != null) {
      authNotifier.handleOAuthError(widget.error!);
      if (mounted) {
        setState(() {
          _status = OAuthStatus.error;
          _errorMessage = _getOAuthErrorMessage(widget.error!);
        });
      }
      return;
    }

    if (widget.accessToken == null || widget.accessToken!.isEmpty) {
      authNotifier.handleOAuthError('No access token received');
      if (mounted) {
        setState(() {
          _status = OAuthStatus.error;
          _errorMessage = 'No access token received from Google';
        });
      }
      return;
    }

    if (mounted) {
      setState(() => _status = OAuthStatus.verifying);
    }

    // Restore persisted return URL into in-memory provider before login completes.
    final storageService = ref.read(storageServiceProvider);
    final persistedReturnUrl = storageService.getOAuthReturnUrl();
    if (persistedReturnUrl != null &&
        persistedReturnUrl.isNotEmpty &&
        persistedReturnUrl.startsWith('/')) {
      ref.read(returnUrlProvider.notifier).state = persistedReturnUrl;
      await storageService.clearOAuthReturnUrl();
    }
    // PROD-4040 T2.4: the backend-validated business_return_to is authoritative.
    // When present, it wins over the client-persisted return, and re-arms the
    // business session so the owner isn't swept into consumer onboarding.
    final businessReturn = routableBusinessReturn(widget.businessReturnTo);
    if (businessReturn != null) {
      ref.read(returnUrlProvider.notifier).state = businessReturn;
      ref.read(businessSessionActiveProvider.notifier).state = true;
      await storageService.clearOAuthReturnUrl();
    }

    final success = await authNotifier.completeGoogleLogin(
      widget.accessToken!,
      refreshToken: widget.refreshToken,
    );

    if (!mounted) return;

    if (success) {
      setState(() => _status = OAuthStatus.success);
      // Brief delay to show success before navigating.
      await Future.delayed(const Duration(milliseconds: 300));
      if (mounted) {
        final returnUrl = ref.read(returnUrlProvider);
        if (returnUrl != null) {
          ref.read(returnUrlProvider.notifier).state = null;
          context.go(returnUrl);
        } else {
          context.go(AppRoutes.home);
        }
      }
    } else {
      final authState = ref.read(authStateProvider);
      setState(() {
        _status = OAuthStatus.error;
        _errorMessage = authState.error ?? 'Failed to complete sign in';
      });
    }
  }

  Future<void> _retryLogin() async {
    if (_isRetrying) return;
    setState(() {
      _isRetrying = true;
      _status = OAuthStatus.processing;
      _errorMessage = null;
    });
    await _processCallback();
    if (mounted) {
      setState(() => _isRetrying = false);
    }
  }

  void _goToLogin() {
    context.go(AppRoutes.login);
  }

  /// Map backend OAuth error codes to user-friendly localized messages
  String _getOAuthErrorMessage(String errorCode) {
    final l10n = Lt.of(context);
    switch (errorCode) {
      case 'oauth_denied':
        return l10n.oauthErrorDenied;
      case 'invalid_state':
        return l10n.oauthErrorSessionExpired;
      case 'invalid_request':
      case 'token_exchange_failed':
      case 'auth_failed':
        return l10n.oauthErrorGeneric;
      case 'missing_email':
        return l10n.oauthErrorMissingEmail;
      default:
        return l10n.oauthErrorDefault;
    }
  }

  @override
  Widget build(BuildContext context) {
    // ColoredBox keeps the layer opaque during the shell slide transition
    // so the previous screen doesn't bleed through. LayoutBuilder +
    // IntrinsicHeight stretches the column to the available height so
    // `mainAxisAlignment.center` actually centres the content vertically.
    // SingleChildScrollView is the fallback when a very short viewport
    // can't fit the natural height (PROD-695 lesson).
    return ColoredBox(
      color: AppColors.sokoPaper,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
            child: ConstrainedBox(
              constraints: BoxConstraints(
                minHeight: constraints.maxHeight - 64,
              ),
              child: Center(child: _buildContent()),
            ),
          );
        },
      ),
    );
  }

  Widget _buildContent() {
    final l10n = Lt.of(context);
    switch (_status) {
      case OAuthStatus.processing:
        return _LoadingView(
          headingText: l10n.oauthProcessing,
          subtitleText: l10n.oauthVerifying,
        );
      case OAuthStatus.verifying:
        return _LoadingView(
          headingText: l10n.oauthVerifying,
          subtitleText: l10n.oauthProcessing,
        );
      case OAuthStatus.success:
        return _SuccessView(headingText: l10n.oauthSuccess);
      case OAuthStatus.error:
        return _ErrorView(
          headingText: l10n.oauthFailedTitle,
          bodyText: _errorMessage ?? l10n.errorUnknown,
          showRetry: widget.accessToken != null,
          isRetrying: _isRetrying,
          onRetry: _retryLogin,
          onBackToLogin: _goToLogin,
          retryLabel: l10n.oauthRetry,
          backToLoginLabel: l10n.oauthBackToLogin,
        );
    }
  }
}

class _LoadingView extends StatelessWidget {
  const _LoadingView({required this.headingText, required this.subtitleText});

  final String headingText;
  final String subtitleText;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _Illustration(
          'assets/images/illustrations/soko-walking-and-reading.webp',
        ),
        const SizedBox(height: 24),
        _Heading(headingText),
        const SizedBox(height: 12),
        _Body(subtitleText, color: AppColors.sokoShade3),
        const SizedBox(height: 24),
        const SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(
            strokeWidth: 2.5,
            color: AppColors.sokoInk,
          ),
        ),
      ],
    );
  }
}

class _SuccessView extends StatelessWidget {
  const _SuccessView({required this.headingText});

  final String headingText;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _Illustration(
          'assets/images/illustrations/soko-walking-and-reading.webp',
        ),
        const SizedBox(height: 24),
        _Heading(headingText),
      ],
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({
    required this.headingText,
    required this.bodyText,
    required this.showRetry,
    required this.isRetrying,
    required this.onRetry,
    required this.onBackToLogin,
    required this.retryLabel,
    required this.backToLoginLabel,
  });

  final String headingText;
  final String bodyText;
  final bool showRetry;
  final bool isRetrying;
  final VoidCallback onRetry;
  final VoidCallback onBackToLogin;
  final String retryLabel;
  final String backToLoginLabel;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(
          child: _Illustration(
            'assets/images/illustrations/soko-walking-in-crowd.webp',
          ),
        ),
        const SizedBox(height: 24),
        _Heading(headingText),
        const SizedBox(height: 12),
        _Body(bodyText, color: AppColors.sokoShade3),
        const SizedBox(height: 24),
        if (showRetry) ...[
          SokoCtaButton(
            label: retryLabel,
            onPressed: isRetrying ? null : onRetry,
            loading: isRetrying,
          ),
          const SizedBox(height: 16),
          Center(
            child: GestureDetector(
              onTap: onBackToLogin,
              child: Text(
                backToLoginLabel,
                style: const TextStyle(
                  color: AppColors.sokoInk,
                  fontWeight: FontWeight.w600,
                  fontSize: 14,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ),
        ] else
          SokoCtaButton(label: backToLoginLabel, onPressed: onBackToLogin),
      ],
    );
  }
}

class _Illustration extends StatelessWidget {
  const _Illustration(this.asset);

  final String asset;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      asset,
      width: 200,
      fit: BoxFit.contain,
      semanticLabel: 'Soko',
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: const TextStyle(
        fontFamily: 'SeasonMix',
        fontSize: 32,
        fontWeight: FontWeight.w400,
        height: 1.05,
        color: AppColors.sokoInk,
      ),
    );
  }
}

class _Body extends StatelessWidget {
  const _Body(this.text, {this.color = AppColors.sokoInk});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 15, height: 1.35, color: color),
    );
  }
}
