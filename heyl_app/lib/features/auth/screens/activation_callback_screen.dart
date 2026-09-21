import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../helpers/activation_redirect_helper.dart';

/// PROD-2073: deep-link landing after the user clicks the activation link in
/// their inbox. Hosted inside [AuthShell] so it inherits the funnel's
/// SokoBrandHeader + back chevron + language picker + PageContent (480-px
/// max-width column) + sokoPaper surface. This widget only paints the body
/// over that shell.
class ActivationCallbackScreen extends ConsumerStatefulWidget {
  final String? token;

  const ActivationCallbackScreen({super.key, this.token});

  @override
  ConsumerState<ActivationCallbackScreen> createState() =>
      _ActivationCallbackScreenState();
}

class _ActivationCallbackScreenState
    extends ConsumerState<ActivationCallbackScreen> {
  bool _isProcessing = true;
  String? _errorMessage;
  bool _deepLinkAttempted = false;
  late final ActivationRedirectHelper _redirectHelper;

  @override
  void initState() {
    super.initState();
    _redirectHelper = createActivationRedirectHelper();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _handleActivation();
    });
  }

  Future<void> _handleActivation() async {
    if (widget.token == null || widget.token!.isEmpty) {
      setState(() {
        _isProcessing = false;
        _errorMessage = Lt.of(context).activationInvalidLink;
      });
      return;
    }

    if (kIsWeb && _redirectHelper.isMobileWeb() && !_deepLinkAttempted) {
      _deepLinkAttempted = true;
      _redirectHelper.tryOpenNativeApp(widget.token!);
      await Future.delayed(const Duration(milliseconds: 800));
      if (mounted) {
        _processActivation();
      }
    } else {
      _processActivation();
    }
  }

  Future<void> _processActivation() async {
    if (widget.token == null || widget.token!.isEmpty) {
      setState(() {
        _isProcessing = false;
        _errorMessage = Lt.of(context).activationInvalidLink;
      });
      return;
    }

    final success = await ref
        .read(authStateProvider.notifier)
        .activateAccount(widget.token!);

    if (success) {
      // Activation completes the account creation that register started.
      // `pendingActivationEmail` is now cleared, so the router's Siga
      // gate (driven entirely by the backend's `*_at` keys) will fire
      // on the next pass and redirect to /auth/soko-welcome.
      if (!mounted) return;
      context.go(AppRoutes.home);
      return;
    }

    if (mounted) {
      setState(() {
        _isProcessing = false;
        _errorMessage =
            ref.read(authStateProvider).error ??
            Lt.of(context).activationFailedSubtitle;
      });
    }
  }

  void _handleRequestNewLink() {
    context.go(AppRoutes.login);
  }

  void _handleTryAgain() {
    setState(() {
      _isProcessing = true;
      _errorMessage = null;
    });
    _processActivation();
  }

  @override
  Widget build(BuildContext context) {
    // ColoredBox keeps the layer opaque during the shell slide transition
    // so the previous screen doesn't bleed through.
    return ColoredBox(
      color: AppColors.sokoPaper,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 32, 24, 32),
        child: _buildContent(),
      ),
    );
  }

  Widget _buildContent() {
    if (_isProcessing) return _buildProcessingView();
    return _buildErrorView();
  }

  Widget _buildIllustration(String asset, {double width = 200}) {
    return Image.asset(
      asset,
      width: width,
      fit: BoxFit.contain,
      semanticLabel: 'Soko',
    );
  }

  Widget _buildHeading(String text) {
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

  Widget _buildBody(String text, {Color color = AppColors.sokoInk}) {
    return Text(
      text,
      textAlign: TextAlign.center,
      style: TextStyle(fontSize: 15, height: 1.35, color: color),
    );
  }

  Widget _buildProcessingView() {
    final l10n = Lt.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _buildIllustration(
          'assets/images/illustrations/soko-walking-and-reading.webp',
        ),
        const SizedBox(height: 24),
        _buildHeading(l10n.activationProcessing),
        const SizedBox(height: 12),
        _buildBody(l10n.activationProcessingSubtitle),
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

  Widget _buildErrorView() {
    final l10n = Lt.of(context);
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: _buildIllustration(
            'assets/images/illustrations/soko-walking-in-crowd.webp',
          ),
        ),
        const SizedBox(height: 24),
        _buildHeading(l10n.activationFailedTitle),
        const SizedBox(height: 12),
        _buildBody(
          _errorMessage ?? l10n.activationFailedSubtitle,
          color: AppColors.sokoShade3,
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.sokoYellow.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.info_outline,
                color: AppColors.sokoInk,
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.activationLinkExpiredNotice,
                  style: const TextStyle(
                    color: AppColors.sokoInk,
                    fontSize: 13,
                    height: 1.35,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        SokoCtaButton(
          label: l10n.oauthBackToLogin,
          onPressed: _handleRequestNewLink,
        ),
        const SizedBox(height: 16),
        Center(
          child: GestureDetector(
            onTap: _handleTryAgain,
            child: Text(
              l10n.activationTryAgain,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontWeight: FontWeight.w600,
                fontSize: 14,
                decoration: TextDecoration.underline,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
