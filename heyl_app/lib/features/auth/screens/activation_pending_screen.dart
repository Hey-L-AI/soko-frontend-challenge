import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/widgets/soko_cta_button.dart';

/// PROD-2073: "Check your email" screen shown after a successful email
/// register. Hosted inside [AuthShell], so the Scaffold + SafeArea +
/// SokoBrandHeader + back chevron + language picker + [PageContent]
/// 480-px max-width column come from the shell — this widget only paints
/// the body content over the shell's sokoPaper surface.
class ActivationPendingScreen extends ConsumerStatefulWidget {
  final String? email;

  const ActivationPendingScreen({super.key, this.email});

  @override
  ConsumerState<ActivationPendingScreen> createState() =>
      _ActivationPendingScreenState();
}

class _ActivationPendingScreenState
    extends ConsumerState<ActivationPendingScreen> {
  DateTime? _lastResendTime;

  String get _email =>
      widget.email ?? ref.read(authStateProvider).pendingActivationEmail ?? '';

  bool get _canResend {
    if (_lastResendTime == null) return true;
    return DateTime.now().difference(_lastResendTime!) >
        const Duration(seconds: 60);
  }

  Future<void> _handleResend() async {
    if (!_canResend || _email.isEmpty) return;

    final success = await ref
        .read(authStateProvider.notifier)
        .resendActivation(_email);

    if (mounted) {
      setState(() {
        _lastResendTime = DateTime.now();
      });

      if (success) {
        showSoko(
          ref,
          message: Lt.of(context).authActivationResendSuccess,
          variant: SokoVariant.success,
        );
      }
    }
  }

  void _handleBackToLogin() {
    ref.read(authStateProvider.notifier).clearPendingActivation();
    context.go(AppRoutes.login);
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authStateProvider);
    final l10n = Lt.of(context);

    // ColoredBox keeps the layer opaque during the shell slide transition
    // so the previous screen doesn't bleed through (same pattern as
    // `email_register_screen.dart`).
    return ColoredBox(
      color: AppColors.sokoPaper,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 32),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              l10n.authActivationTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'SeasonMix',
                fontSize: 32,
                fontWeight: FontWeight.w400,
                height: 1.05,
                color: AppColors.sokoInk,
              ),
            ),
          ),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              l10n.authActivationSubtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 15,
                height: 1.35,
                color: AppColors.sokoInk,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              _email,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: AppColors.sokoInk,
              ),
            ),
          ),
          const SizedBox(height: 24),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppColors.sokoPaper,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l10n.authActivationStepsHeader,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: AppColors.sokoInk,
                          ),
                        ),
                        const SizedBox(height: 12),
                        _buildStep('1', l10n.authActivationStep1),
                        const SizedBox(height: 8),
                        _buildStep('2', l10n.authActivationStep2),
                        const SizedBox(height: 8),
                        _buildStep('3', l10n.authActivationStep3),
                      ],
                    ),
                  ),
                  if (authState.error != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: AppColors.sokoRed.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.error_outline,
                            color: AppColors.sokoInk,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              authState.error!,
                              style: const TextStyle(
                                color: AppColors.sokoInk,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  SokoCtaButton(
                    label: _canResend
                        ? l10n.authActivationButtonResend
                        : l10n.authActivationButtonWait,
                    icon: Icons.refresh,
                    onPressed: authState.isLoading || !_canResend
                        ? null
                        : _handleResend,
                    loading: authState.isLoading,
                  ),
                  const SizedBox(height: 16),
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
                            l10n.authActivationSpamNotice,
                            style: const TextStyle(
                              color: AppColors.sokoInk,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 24),
                ],
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  l10n.authActivationAlreadyText,
                  style: const TextStyle(
                    color: AppColors.sokoShade3,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(width: 4),
                GestureDetector(
                  onTap: _handleBackToLogin,
                  child: Text(
                    l10n.authButtonSignIn,
                    style: const TextStyle(
                      color: AppColors.sokoInk,
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      decoration: TextDecoration.underline,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStep(String number, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 24,
          height: 24,
          decoration: const BoxDecoration(
            color: AppColors.sokoPink,
            shape: BoxShape.circle,
          ),
          child: Center(
            child: Text(
              number,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontWeight: FontWeight.w600,
                fontSize: 12,
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            text,
            style: const TextStyle(
              color: AppColors.sokoInk,
              fontSize: 15,
              height: 1.35,
            ),
          ),
        ),
      ],
    );
  }
}
