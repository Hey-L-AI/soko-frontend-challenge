import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/push_permission_service.dart';
import '../../../core/services/push_permission_state.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../data/models/notification_item.dart';
import '../../../data/models/notification_preferences.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/deep_link_empty_state_sheet.dart';
import '../../notifications/providers/notification_preferences_provider.dart';
import '../../profile/widgets/push_settings_redirect_sheet.dart';

/// PROD-3730 — the sheet shown while today's Daily Drop is being generated.
///
/// Replaces the come-back-tomorrow sheet for the `isGenerating` branch of the
/// `/drop` deep link, and is also what the Discovery working card opens on
/// tap. Doubles as the push-enablement moment: this is the one place where
/// "turn on notifications" has an immediate, concrete payoff for the user
/// rather than being a generic ask.
///
/// `source` label for analytics: `daily_drop_generating`.
const String kDailyDropGeneratingSource = 'daily_drop_generating';

/// Analytics `source` for the same ask made from the failure card. Distinct
/// from [kDailyDropGeneratingSource] because the conversion rates are not
/// comparable: one is asked mid-wait with something coming, the other after
/// we've just failed the user.
const String kDailyDropFailedSource = 'daily_drop_failed';

/// The wire `notification_type` for the Daily Drop alert, as registered in the
/// BE TemplateSpec registry and exposed under the `discovery` category by
/// `GET /api/v1/app/notifications/preferences`.
const String kDailyDropNotificationType = 'daily_drop_ready';

/// Why the user cannot currently be told the drop is ready — and therefore
/// what the sheet should offer.
///
/// Two independent switches produce this, not one. The OS permission layer is
/// what [PushPermissionService] sees; the Soko preference layer
/// ([DailyDropNudge.sokoTypeOff]) is invisible to it — that user reads as
/// `verified` and would silently never receive the push.
enum DailyDropNudge {
  /// Push is on and `daily_drop_ready` is enabled — nothing to ask. The sheet
  /// simply confirms the promise.
  none,

  /// OS never prompted. CTA fires the OS dialog. Only ever from an explicit
  /// tap: `notDetermined` is one-shot and a wasted prompt is unrecoverable.
  osPrompt,

  /// OS denied. iOS will not re-prompt, so CTA deep-links to Settings.
  osSettings,

  /// OS is fine but the user turned the Daily Drop alert off in Soko's own
  /// settings. CTA flips it back via `PATCH /notifications/preferences`.
  sokoTypeOff,

  /// No push on this platform at all (web). Offer nothing.
  unavailable,
}

/// Resolves the nudge state from the two switches.
///
/// [prefsLoaded] is false while `notificationPreferencesProvider` is still
/// fetching — we return [DailyDropNudge.none] rather than flashing a wrong
/// ask, and the sheet re-resolves on the next build.
DailyDropNudge resolveDailyDropNudge({
  required PushPermissionState permission,
  required bool prefsLoaded,
  required bool dailyDropTypeEnabled,
}) {
  if (permission is! PushPermissionReady) {
    // `unavailable` (web / Klaviyo off) or still `loading`. Neither is
    // something the user can act on from here.
    return permission is PushPermissionUnavailable
        ? DailyDropNudge.unavailable
        : DailyDropNudge.none;
  }
  switch (permission.sub) {
    case ReadySubState.osNotDetermined:
      return DailyDropNudge.osPrompt;
    case ReadySubState.osDenied:
      return DailyDropNudge.osSettings;
    case ReadySubState.osAuthorisedTokenMissing:
      // A background registration retry is already in flight; asking the user
      // to do anything here would be noise. Mirrors PushSuggestionCard, which
      // deliberately does not render for this sub-state.
      return DailyDropNudge.none;
    case ReadySubState.verified:
      if (prefsLoaded && !dailyDropTypeEnabled)
        return DailyDropNudge.sokoTypeOff;
      return DailyDropNudge.none;
  }
}

/// Reads the resolved `discovery.types.daily_drop_ready` state.
///
/// The per-type value returned by the API is already resolved against the
/// category row (a per-type override wins over `discovery.enabled`), so this
/// single read covers both levels of the settings screen. Defaults to `true`
/// when the type isn't in the map — categories with no registered types are
/// opt-out, so "absent" means "on".
bool dailyDropTypeEnabledFrom(NotificationPreferences prefs) {
  final types = prefs.categoryFor(NotificationCategory.discovery).types;
  return types[kDailyDropNotificationType] ?? true;
}

/// Which wait the sheet is talking about — the same nudge machinery, two
/// different promises.
///
/// Added 2026-08-10 when Zé asked the failure card to offer the same ask:
/// *"when the daily drop generation fails we want it to have similar behavior
/// when users with notifications disabled click it: we show the bottom drawer
/// telling the user allow they can enable notifications to be notified the
/// next day's daily drop"*. Only the copy differs — the four-state resolution,
/// the CTAs and the analytics are shared, so the two can never drift.
enum DailyDropWaitOccasion {
  /// Today's drop is being generated right now. "We'll tell you when it's
  /// ready."
  generating,

  /// Today's drop failed and is not coming. "We'll tell you when tomorrow's
  /// is ready."
  failedTryTomorrow,
}

/// Shows the wait sheet. Returns when the sheet is dismissed.
Future<void> showDailyDropWaitSheet(
  BuildContext context,
  WidgetRef ref, {
  required DailyDropNudge nudge,
  DailyDropWaitOccasion occasion = DailyDropWaitOccasion.generating,
}) {
  final l10n = Lt.of(context);
  final analytics = ref.read(unifiedAnalyticsProvider);

  analytics.trackDailyDropGeneratingSheetShown(
    nudge: nudge.name,
    occasion: occasion.name,
  );

  final failed = occasion == DailyDropWaitOccasion.failedTryTomorrow;

  // Titles are shared where the sentence is about the user's settings rather
  // than about the drop ("Notifications are off" reads the same either way);
  // every body differs, because the promise does.
  final (String title, String body) = switch (nudge) {
    DailyDropNudge.none || DailyDropNudge.unavailable => (
      failed ? l10n.dailyDropFailedTitle : l10n.dailyDropGeneratingTitle,
      switch ((failed, nudge == DailyDropNudge.unavailable)) {
        (true, true) => l10n.dailyDropFailedBodyNoPush,
        (true, false) => l10n.dailyDropFailedBodyWillNotify,
        (false, true) => l10n.dailyDropGeneratingBodyNoPush,
        (false, false) => l10n.dailyDropGeneratingBodyWillNotify,
      },
    ),
    DailyDropNudge.osPrompt => (
      failed
          ? l10n.dailyDropFailedNudgeTitle
          : l10n.dailyDropGeneratingNudgeTitle,
      failed
          ? l10n.dailyDropFailedNudgeBody
          : l10n.dailyDropGeneratingNudgeBody,
    ),
    DailyDropNudge.osSettings => (
      l10n.dailyDropGeneratingDeniedTitle,
      failed
          ? l10n.dailyDropFailedDeniedBody
          : l10n.dailyDropGeneratingDeniedBody,
    ),
    DailyDropNudge.sokoTypeOff => (
      l10n.dailyDropGeneratingTypeOffTitle,
      failed
          ? l10n.dailyDropFailedTypeOffBody
          : l10n.dailyDropGeneratingTypeOffBody,
    ),
  };

  // Info variant (single CTA that just closes) when there is nothing to ask;
  // action variant (Cancel + primary pair) when there is a real choice.
  final bool hasAsk =
      nudge != DailyDropNudge.none && nudge != DailyDropNudge.unavailable;

  return showBottomSheetWithHiddenNav<void>(
    context: context,
    ref: ref,
    builder: (sheetContext) => DeepLinkEmptyStateSheet(
      title: title,
      body: body,
      ctaLabel: switch (nudge) {
        DailyDropNudge.osPrompt ||
        DailyDropNudge.sokoTypeOff => l10n.dailyDropGeneratingCtaEnable,
        DailyDropNudge.osSettings => l10n.pushCardDeniedCta,
        _ => l10n.dailyDropDeepLinkEmptyCta,
      },
      ctaIcon: hasAsk ? LucideIcons.bell : LucideIcons.compass,
      cancelLabel: hasAsk ? l10n.commonCancel : null,
      onCta: hasAsk
          ? () => _runNudge(
              context,
              ref,
              nudge,
              failed ? kDailyDropFailedSource : kDailyDropGeneratingSource,
            )
          : null,
    ),
  );
}

Future<void> _runNudge(
  BuildContext context,
  WidgetRef ref,
  DailyDropNudge nudge,
  String source,
) async {
  final analytics = ref.read(unifiedAnalyticsProvider);
  analytics.trackPushSuggestion(
    action: 'tapped',
    source: source,
    authStatus: nudge.name,
  );

  switch (nudge) {
    case DailyDropNudge.osPrompt:
      await ref
          .read(pushPermissionServiceProvider.notifier)
          .requestAndRegister(source: source);
    case DailyDropNudge.osSettings:
      if (!context.mounted) return;
      await PushSettingsRedirectSheet.show(context, source: source);
    case DailyDropNudge.sokoTypeOff:
      await ref
          .read(notificationPreferencesProvider.notifier)
          .toggleType(
            NotificationCategory.discovery,
            kDailyDropNotificationType,
            true,
          );
    case DailyDropNudge.none:
    case DailyDropNudge.unavailable:
      break;
  }
}
