import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/experiment_service.dart';
import '../../../core/services/klaviyo_service.dart';
import '../../../core/services/push_permission_service.dart';
import '../../../core/services/push_permission_state.dart';
import '../../../core/services/unified_analytics_service.dart' hide AuthMethod;
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../data/models/notification_item.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../../shared/widgets/dotted_section_divider.dart';
import '../../discovery/widgets/discovery_shell.dart' show popOrFallback;
import '../../notifications/providers/notification_preferences_provider.dart';
import '../../notifications/widgets/notification_categories_section.dart';
import '../widgets/location_consent_row.dart';
import '../widgets/preferences_header.dart';
import '../widgets/reminder_defaults_section.dart';

/// `/menu/preferences` page (PROD-2021). Replaces the legacy
/// `_PreferencesContent` case inside `ProfileSheet`'s drawer. Mirrors
/// `account_screen.dart`'s shell. Selector rows mirror the
/// `PickerRow` visual used in the Instagram-share + chat-items pickers
/// (solid sokoPink border + sokoLight3 fill when selected; dashed
/// sokoInk@30% border + transparent fill when unselected; 30 × 30 chip
/// on the right).
class PreferencesScreen extends ConsumerWidget {
  const PreferencesScreen({super.key});

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
              PreferencesHeader(
                title: l10n.preferencesTitle,
                onBack: () => popOrFallback(context),
              ),
              const Expanded(child: _PreferencesBody()),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreferencesBody extends ConsumerStatefulWidget {
  const _PreferencesBody();

  @override
  ConsumerState<_PreferencesBody> createState() => _PreferencesBodyState();
}

class _PreferencesBodyState extends ConsumerState<_PreferencesBody> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Analytics: same event the legacy drawer fired on _navigateToPreferences.
      ref.read(unifiedAnalyticsProvider).trackPreferencesOpen();
      ref.read(preferencesProvider.notifier).load();
      ref.read(accountProvider.notifier).loadAuthMethods();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final currentAppLocale = ref.watch(currentAppLocaleProvider);
    final user = ref.watch(currentUserProvider);
    final preferencesState = ref.watch(preferencesProvider);
    final preferences = preferencesState.preferences;
    // PROD-2439 — drive toggle visibility off the backend's authoritative
    // `applicability` map (PROD-2437) instead of the client-side
    // `account.hasReachable*` proxy, which overcounted social providers
    // (e.g. Apple private-relay) and led to 422s on opt-in. Show a row
    // when the channel is applicable OR the user is already opted in,
    // so previously-opted-in users can still opt OUT (backend allows
    // opt-out unconditionally). `*Applicable` defaults to true if the
    // backend hasn't shipped the block yet.
    final showEmail =
        (preferences?.emailApplicable ?? true) ||
        (preferences?.emailMarketingOptIn ?? false);
    final showPhone =
        (preferences?.smsApplicable ?? true) ||
        (preferences?.smsMarketingOptIn ?? false);
    final marketingLoading = preferences == null && preferencesState.isLoading;
    // Drive the inner-sub-card visibility off the same signal the header
    // toggle visually reflects — the OS-level Klaviyo auth mirrored into
    // PushPermissionService. `pnOptin` is the persisted backend opt-in;
    // it lags the toggle (PATCH only fires after the user returns from
    // OS Settings via the lifecycle resume, or never if they never
    // explicitly opted in). Driving off pushState matches what the
    // Notificações switch is actually showing right now.
    final pushState = ref.watch(pushPermissionServiceProvider).permission;
    // PROD-2511 — global kill-switch. When false, the entire
    // notifications section (header toggle + categories sub-card)
    // disappears from preferences.
    final notificationsEngineEnabled = ref.watch(
      experimentServiceProvider.select((s) => s.notificationsEngineEnabled),
    );
    final notificationsAvailable =
        notificationsEngineEnabled &&
        !kIsWeb &&
        preferences?.pushApplicable != false &&
        pushState is PushPermissionReady &&
        (pushState.sub == ReadySubState.verified ||
            pushState.sub == ReadySubState.osAuthorisedTokenMissing);
    // Default-reminder timing chips only make sense when the reminders
    // category is actually on. Reading the same provider the category
    // toggle writes to, so flipping it off rebuilds the column and the
    // chips disappear without any extra wiring.
    final remindersOn = ref
        .watch(notificationPreferencesProvider)
        .preferences
        .valueFor(NotificationCategory.reminders);
    final currentWhatsappRegion = user?.availableWhatsappNumbers
        .where((n) => n.isCurrent)
        .map((n) => n.region)
        .firstOrNull;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        // Language section — tap opens `/menu/preferences/language` detail page.
        _NavigationRow(
          icon: LucideIcons.languages,
          title: l10n.preferencesLanguage,
          subtitle:
              currentAppLocale?.nativeName ?? l10n.preferencesSystemDefault,
          onTap: () => context.push(AppRoutes.menuPreferencesLanguage),
        ),

        // PROD-2303 step 7 — single Location row replacing the prior
        // _LocationSharingHeaderToggle (OS permission) + _LocationConsentToggle
        // (server consent) pair. The row reads locationConsentStateProvider
        // and opens a picker sheet on tap. See the design doc at
        // docs/designs/prod-2301-location-consent-all-cohorts.md and the
        // step-7 plan in .context/2026-05-30-prod-2303-step7-settings-
        // consolidation-plan.md.
        const DottedSectionDivider(),
        const LocationConsentRow(),

        // Notifications section — mobile only. Web has no push surface
        // (Klaviyo Flutter SDK is mobile-only; browser push is a deferred
        // follow-up), so we hide the row entirely on web. PROD-2179.
        // PROD-2511 — also hidden when the kill-switch flag is off.
        if (!kIsWeb && notificationsEngineEnabled) ...[
          const DottedSectionDivider(),
          const _NotificationsHeaderToggle(),
          const SizedBox(height: 4),
          Text(
            l10n.preferencesNotificationsSubtitle,
            style: const TextStyle(fontSize: 13, color: AppColors.sokoShade3),
          ),
        ],

        // PROD-2525 T-K3 (reminder defaults) + PROD-2526 T-L (per-category
        // opt-ins) — grouped as inner categories under Notificações. The
        // ink-tinted rounded sub-card on the sokoPaper bg visually signals
        // "these belong to the toggle above" without needing a heavier
        // rule. Hidden entirely when push isn't available so the user
        // isn't tuning controls they can't act on.
        if (notificationsAvailable)
          Container(
            margin: const EdgeInsets.only(top: 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppColors.sokoInk.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const NotificationCategoriesSection(),
                if (remindersOn) ...[
                  const SizedBox(height: 16),
                  const ReminderDefaultsSection(),
                ],
              ],
            ),
          ),

        const DottedSectionDivider(),
        const _SectionHeader(
          icon: LucideIcons.mail,
          labelKey: _SectionLabel.marketing,
        ),
        const SizedBox(height: 4),
        Text(
          l10n.preferencesMarketingSubtitle,
          style: const TextStyle(fontSize: 13, color: AppColors.sokoShade3),
        ),
        const SizedBox(height: 12),
        if (marketingLoading)
          const _PreferencesLoadingRow()
        else ...[
          if (showEmail)
            _MarketingSwitchRow(
              title: l10n.preferencesEmailMarketing,
              subtitle: l10n.preferencesEmailMarketingSubtitle,
              value: preferences?.emailMarketingOptIn ?? false,
              isLoading: preferencesState.isSaving,
              onChanged: (value) {
                ref
                    .read(unifiedAnalyticsProvider)
                    .trackMarketingPreferencesChange(
                      channel: 'email',
                      enabled: value,
                    );
                ref
                    .read(preferencesProvider.notifier)
                    .update(emailMarketingOptIn: value);
              },
            ),
          if (showEmail && showPhone) const SizedBox(height: 8),
          if (showPhone)
            _MarketingSwitchRow(
              title: l10n.preferencesSmsMarketing,
              subtitle: l10n.preferencesSmsMarketingSubtitle,
              value: preferences?.smsMarketingOptIn ?? false,
              isLoading: preferencesState.isSaving,
              onChanged: (value) {
                ref
                    .read(unifiedAnalyticsProvider)
                    .trackMarketingPreferencesChange(
                      channel: 'sms',
                      enabled: value,
                    );
                ref
                    .read(preferencesProvider.notifier)
                    .update(smsMarketingOptIn: value);
              },
            ),
        ],
        if (preferencesState.error != null) ...[
          const SizedBox(height: 8),
          Text(
            preferencesState.error!,
            style: const TextStyle(color: AppColors.error, fontSize: 13),
          ),
        ],

        // WhatsApp section — only show if user has available numbers. Tap
        // opens `/menu/preferences/whatsapp` detail page (same nav pattern
        // as Language above).
        if (user != null && user.availableWhatsappNumbers.isNotEmpty) ...[
          const DottedSectionDivider(),
          _NavigationRow(
            icon: LucideIcons.message_circle,
            title: l10n.preferencesWhatsApp,
            subtitle: currentWhatsappRegion ?? l10n.preferencesWhatsAppSubtitle,
            onTap: () => context.push(AppRoutes.menuPreferencesWhatsapp),
          ),
        ],
      ],
    );
  }
}

/// Section labels resolved against the current localization at build time.
enum _SectionLabel { marketing }

class _SectionHeader extends StatelessWidget {
  final IconData icon;
  final _SectionLabel labelKey;

  const _SectionHeader({required this.icon, required this.labelKey});

  String _label(Lt l10n) {
    switch (labelKey) {
      case _SectionLabel.marketing:
        return l10n.preferencesMarketing;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Row(
      children: [
        Icon(icon, size: 20, color: AppColors.sokoInk),
        const SizedBox(width: 8),
        Text(
          _label(l10n),
          style: const TextStyle(
            color: AppColors.sokoInk,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _PreferencesLoadingRow extends StatelessWidget {
  const _PreferencesLoadingRow();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 48,
      child: Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}

class _MarketingSwitchRow extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool value;
  final bool isLoading;
  final ValueChanged<bool> onChanged;

  const _MarketingSwitchRow({
    required this.title,
    required this.subtitle,
    required this.value,
    required this.isLoading,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: const TextStyle(
                  color: AppColors.sokoInk,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                subtitle,
                style: const TextStyle(
                  color: AppColors.sokoShade3,
                  fontSize: 13,
                  height: 1.2,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        if (isLoading)
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          Switch.adaptive(
            value: value,
            onChanged: onChanged,
            activeThumbColor: AppColors.sokoInk,
            activeTrackColor: AppColors.sokoPink,
          ),
      ],
    );
  }
}

/// Header row for the Notifications section: bell icon + label on the left,
/// `Switch.adaptive` on the right. Mirrors `_LocationSharingHeaderToggle`
/// — reads the OS push authorization from `KlaviyoService`, requests
/// permission on toggle-on, opens app settings on toggle-off (or when
/// permission is already denied). Re-reads on app resume so returning
/// from Settings rebuilds the toggle.
///
/// Native only — `kIsWeb` guards in the caller prevent this widget from
/// mounting on web (Klaviyo push isn't wired for browsers).
class _NotificationsHeaderToggle extends ConsumerStatefulWidget {
  const _NotificationsHeaderToggle();

  @override
  ConsumerState<_NotificationsHeaderToggle> createState() =>
      _NotificationsHeaderToggleState();
}

class _NotificationsHeaderToggleState
    extends ConsumerState<_NotificationsHeaderToggle>
    with WidgetsBindingObserver {
  bool _isAuthorized = false;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _refresh();
    }
  }

  Future<void> _refresh() async {
    final klaviyo = ref.read(klaviyoServiceProvider);
    final authorized = await klaviyo.isPushAuthorized;
    if (!mounted) return;
    setState(() => _isAuthorized = authorized);
  }

  /// Master toggle ON = "enable everything" — opts into every category
  /// row the user can see below this toggle. Reminders/Discovery already
  /// default to `true` server-side (opt-OUT), so the PATCH is a no-op for
  /// them on a fresh user; `marketing.push` is opt-IN (default `false`)
  /// and only flips here. Marketing consent is recorded server-side with
  /// `source='preferences'` in `marketing_consent_logs`. Web users get a
  /// silent server-side skip on `marketing.push` per PROD-2464.
  Future<void> _enableAllVisibleCategories() async {
    final experiment = ref.read(experimentServiceProvider);
    final visible = visibleNotificationCategories(experiment);
    final body = <String, dynamic>{};
    for (final category in visible) {
      if (category == NotificationCategory.marketing) {
        body['marketing'] = <String, dynamic>{'push': true};
      } else {
        body[category.wireName] = true;
      }
    }
    if (body.isEmpty) return;
    try {
      await ref.read(notificationsApiProvider).updatePreferences(body);
      if (!mounted) return;
      await ref.read(notificationPreferencesProvider.notifier).refresh();
    } catch (e, st) {
      debugPrint('[Preferences] Batch enable categories failed: $e\n$st');
    }
  }

  Future<void> _toggle(bool value) async {
    if (_isLoading) return;
    // Fire on user gesture — the event reflects intent regardless of
    // whether the OS later denies the permission prompt (the actual
    // grant/deny outcome is tracked via the existing
    // `push_permission` event).
    ref
        .read(unifiedAnalyticsProvider)
        .trackMarketingPreferencesChange(channel: 'push', enabled: value);
    setState(() => _isLoading = true);
    final klaviyo = ref.read(klaviyoServiceProvider);

    try {
      if (value) {
        // Route opt-in through PushPermissionService so the `pn_optin`
        // PATCH (with the freshly-acquired Klaviyo token) fires
        // immediately. Calling the SDK directly would leave the
        // backend unaware of the consent until the next lifecycle
        // resume — long enough that the user might back out of the
        // screen first and the Siga gate keeps re-firing because
        // `push_notification_opt_in_at` is still NULL.
        final result = await ref
            .read(pushPermissionServiceProvider.notifier)
            .requestAndRegister(source: 'preferences_screen');
        if (!mounted) return;
        switch (result) {
          case PushRegResult.registered:
          case PushRegResult.registeredTokenUnknown:
            setState(() => _isAuthorized = true);
            await _enableAllVisibleCategories();
          case PushRegResult.permissionDenied:
            // iOS won't re-prompt once denied — deep-link to Settings.
            // Lifecycle observer refreshes when the user returns.
            await klaviyo.openNotificationSettings();
          case PushRegResult.sdkDisabled:
          case PushRegResult.sdkInitFailed:
          case PushRegResult.failed:
            debugPrint('[Preferences] Notifications toggle failed: $result');
            final messenger = ScaffoldMessenger.maybeOf(context);
            messenger?.showSnackBar(
              SnackBar(
                content: Text(
                  Lt.of(context).preferencesNotificationsUnavailable,
                ),
              ),
            );
        }
      } else {
        // OS doesn't expose a programmatic "revoke" — open Settings.
        // didChangeAppLifecycleState + the app-level lifecycle observer
        // (app.dart: pushPermissionServiceProvider.refresh) re-derive
        // state and PATCH `pn_optin: false` when the user returns with
        // notifications disabled.
        await klaviyo.openNotificationSettings();
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return Row(
      children: [
        const Icon(LucideIcons.bell, size: 20, color: AppColors.sokoInk),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            l10n.preferencesNotifications,
            style: const TextStyle(
              color: AppColors.sokoInk,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        if (_isLoading)
          const SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        else
          Switch.adaptive(
            value: _isAuthorized,
            onChanged: _toggle,
            activeThumbColor: AppColors.sokoInk,
            activeTrackColor: AppColors.sokoPink,
          ),
      ],
    );
  }
}

/// Tappable row used for sections that open a detail page (Language) or
/// an external view (Terms / Privacy). Icon + title on the left, optional
/// subtitle below the title, trailing chevron on the right.
class _NavigationRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback onTap;

  const _NavigationRow({
    required this.icon,
    required this.title,
    required this.onTap,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 20, color: AppColors.sokoInk),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: AppColors.sokoInk,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    if (subtitle != null && subtitle!.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        subtitle!,
                        style: const TextStyle(
                          color: AppColors.sokoShade3,
                          fontSize: 13,
                          height: 1.2,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              const Icon(
                LucideIcons.chevron_right,
                size: 20,
                color: AppColors.sokoShade3,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
