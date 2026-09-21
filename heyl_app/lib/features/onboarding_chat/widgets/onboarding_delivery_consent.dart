import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/push_permission_service.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../providers/preferences_provider.dart';
import 'onboarding_choice_row.dart';

/// Yes/No consent for the rituals step's delivery ask ("can I send you push
/// notifications or emails?"). Rendered in the pinned bottom composer (like the
/// other chat-step inputs) and GATES the transcript: "You're ready!" and the
/// finish CTAs are held until the user answers here ([onAnswered] resumes them).
///
/// - **Yes** opts the user into every applicable marketing channel (email + SMS +
///   push) and fires the OS push-permission prompt (native only).
/// - **No** records an explicit opt-out on the same channels — no OS prompt.
///
/// Mirrors the Siga consent flow in `soko_welcome_screen._onContinue`: PATCH the
/// applicable channels with the boolean (true OR false), reload the preferences
/// cache, then only on Yes fire `requestAndRegister` (which registers the device
/// and emits `push_prompt_shown` / `push_permission` internally with
/// `source='onboarding_rituals'`). Replaces the covers carousel's old auto-fired
/// OS prompt, so the prompt now needs an explicit Yes.
///
/// The whole side-effect is best-effort — it never blocks onboarding, and the
/// finish CTAs below remain independently tappable. Once a choice is made both
/// chips lock so the OS prompt can't be re-fired.
class OnboardingDeliveryConsent extends ConsumerStatefulWidget {
  const OnboardingDeliveryConsent({
    super.key,
    required this.yesLabel,
    required this.noLabel,
    this.onAnswered,
  });

  final String yesLabel;
  final String noLabel;

  /// Called the instant the user picks Yes/No — before the best-effort consent
  /// side-effect runs — so the caller can resume the paused transcript ("You're
  /// ready!" + finish CTAs) immediately instead of waiting on the OS prompt.
  final VoidCallback? onAnswered;

  @override
  ConsumerState<OnboardingDeliveryConsent> createState() =>
      _OnboardingDeliveryConsentState();
}

class _OnboardingDeliveryConsentState
    extends ConsumerState<OnboardingDeliveryConsent> {
  /// Null until the user answers, then the chosen value. Locks both chips and
  /// keeps the picked one visually active.
  bool? _accepted;

  Future<void> _submitConsent(bool accepted) async {
    if (_accepted != null) return;
    setState(() => _accepted = accepted);

    // Capture everything tied to `ref` up front: `onAnswered` resumes the
    // transcript, which unmounts this widget mid-flight, so the best-effort
    // side-effect below must not touch `ref`/`mounted` afterwards. The consent
    // must still complete even after the widget is gone.
    final prefsNotifier = ref.read(preferencesProvider.notifier);
    final prefs = ref.read(preferencesProvider).preferences;
    final pushService = ref.read(pushPermissionServiceProvider.notifier);

    ref
        .read(unifiedAnalyticsProvider)
        .trackOnboardingStep(
          step: 'rituals.ready',
          action: accepted ? 'notify_yes' : 'notify_no',
        );

    // Resume the transcript immediately — "You're ready!" and the finish CTAs
    // should appear the moment the user answers, not after the (up to 10s) OS
    // push prompt below.
    widget.onAnswered?.call();

    // Fire the OS prompt FIRST on Yes (mobile only) so the dialog appears the
    // instant the user answers — not after the two awaited preference PATCH
    // round-trips below, which previously delayed it. `requestAndRegister` is
    // mutexed and waits for foreground-active internally, so firing it up front
    // is safe. On No we never prompt (explicit opt-out only).
    if (accepted && !kIsWeb) {
      try {
        await pushService
            .requestAndRegister(source: 'onboarding_rituals')
            .timeout(const Duration(seconds: 10));
      } catch (_) {
        // Best-effort: a hung/failed prompt must never block the step.
      }
    }

    try {
      // Gate each channel on the backend's applicability map so we never stamp
      // consent on an unreachable channel (e.g. a phone-only user has no email).
      // Sending `false` is a real opt-out — it stamps the opt-in-at timestamps.
      final emailApplicable = prefs?.emailApplicable ?? true;
      final smsApplicable = prefs?.smsApplicable ?? true;
      final pushApplicable = prefs?.pushApplicable ?? true;

      await prefsNotifier.update(
        emailMarketingOptIn: emailApplicable ? accepted : null,
        smsMarketingOptIn: smsApplicable ? accepted : null,
        // Web can never acquire a push token; omit pn_optin there.
        pnOptin: (kIsWeb || !pushApplicable) ? null : accepted,
      );
      // On Yes the push registration above also PATCHed pn_optin directly, so a
      // single reload after the marketing PATCH refreshes the whole cache.
      await prefsNotifier.load();
    } catch (_) {
      // Best-effort: never block onboarding on a preferences write.
    }
  }

  @override
  Widget build(BuildContext context) {
    final answered = _accepted != null;
    return OnboardingChoiceRow(
      noKey: const Key('onboarding-notify-no'),
      yesKey: const Key('onboarding-notify-yes'),
      noLabel: widget.noLabel,
      yesLabel: widget.yesLabel,
      noSelected: _accepted == false,
      yesSelected: _accepted == true,
      onNo: answered ? null : () => _submitConsent(false),
      onYes: answered ? null : () => _submitConsent(true),
    );
  }
}
