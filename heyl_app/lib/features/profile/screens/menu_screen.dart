import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../shared/widgets/soko_brain_icon.dart';
import '../../../core/theme/page_layout.dart';
import '../../../core/utils/auth_gating.dart';
import '../../../core/services/unified_analytics_service.dart' hide AuthMethod;
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../campaigns/widgets/fake_door_admin_sheet.dart';
import '../../discovery/widgets/discovery_shell.dart' show popOrFallback;
import '../../notifications/widgets/notifications_top_button.dart';
import '../../product_tour/providers/product_tour_controller.dart';
import '../../share/widgets/soko_share_sheet.dart';

/// `/menu` page (PROD-2019). Replaces the legacy right-side `ProfileDrawer`
/// for the Profile root. The 6 sub-screens (Account, Preferences, Business
/// Connections, Support, About, Merge) each live at their own `/menu/X`
/// route after the PROD-2020..2025 migration; rows here push to them.
///
/// Background painted by the outer [ColoredBox] (sokoPaper) edge-to-edge —
/// symmetric with `/`, `/chat`, `/yours`, which also own their own bg.
/// The body content is wrapped in [PageContent] so the menu honours the
/// same 480 px max-width column on desktop as Discovery and the Lists
/// hub. The bg paints the full viewport behind the constrained column.
class MenuScreen extends ConsumerWidget {
  const MenuScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAuthenticated = ref.watch(isAuthenticatedProvider);
    final user = ref.watch(currentUserProvider);

    return ColoredBox(
      color: AppColors.sokoPaper,
      child: PageContent(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _MenuHeader(
                isAuthenticated: isAuthenticated,
                displayName: user?.displayName ?? 'User',
                handle: user?.handle ?? '',
                hasDisplayName: user?.hasDisplayName ?? false,
                hasHandle: user?.hasHandle ?? false,
                // The menu is reached from the profile's gear for every signed-in
                // user now, so Back returns to the profile. Guests keep the
                // default (pop → /).
                onBack: () => isAuthenticated
                    ? context.go(AppRoutes.profile)
                    : popOrFallback(context),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
                  child: isAuthenticated
                      ? _AuthedMenuBody(
                          displayName: user?.displayName ?? 'User',
                          hasDisplayName: user?.hasDisplayName ?? false,
                        )
                      : const _GuestMenuBody(),
                ),
              ),
              if (isAuthenticated)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 24),
                  child: _SokoSignOutButton(
                    onSignOut: () => _signOut(context, ref),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _signOut(BuildContext context, WidgetRef ref) async {
    await ref.read(authStateProvider.notifier).logout();

    // Account-scoped caches are NOT cleared here. This used to be a
    // hand-maintained list of six `invalidate` calls, which covered
    // neither the `/yours` hub providers nor the three other ways a
    // session ends (expiry, suspension, account deletion) — so signing
    // out and back in as a different account leaked the first account's
    // data. `userScopedStatePurgeProvider` now owns that cleanup for
    // every path; see `core/session/user_scoped_state.dart`.
    //
    // `returnUrlProvider` isn't cleared here either any more (PROD-3580): it
    // was the last survivor of that hand-maintained pattern, clearing on this
    // one path only. It now self-clears on any identity departure — see its
    // declaration in `core/router/app_router.dart`.

    if (context.mounted) {
      context.go(AppRoutes.login);
    }
  }
}

class _MenuHeader extends StatelessWidget {
  final bool isAuthenticated;
  final String displayName;
  final String handle;
  final bool hasDisplayName;
  final bool hasHandle;
  final VoidCallback onBack;

  const _MenuHeader({
    required this.isAuthenticated,
    required this.displayName,
    required this.handle,
    required this.hasDisplayName,
    required this.hasHandle,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    final Widget centerContent = isAuthenticated
        ? Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                hasDisplayName ? displayName : l10n.profileDisplayNameNotSet,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontFamily: 'SeasonMix',
                  fontWeight: FontWeight.w400,
                  fontSize: 32,
                  height: 1.0,
                  letterSpacing: -0.64,
                  color: hasDisplayName
                      ? AppColors.sokoInk
                      : AppColors.sokoShade3,
                ),
              ),
              const SizedBox(height: 6),
              // Tappable handle line — routes to `/menu/account?edit=handle`,
              // which AccountScreen reads in `initState` to open the handle
              // input in edit mode. Works for both the empty "Set your handle"
              // prompt and the existing-handle case (the underline already
              // hinted clickability).
              MouseRegion(
                cursor: SystemMouseCursors.click,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () =>
                      context.go('${AppRoutes.menuAccount}?edit=handle'),
                  child: Text(
                    hasHandle ? '@$handle' : l10n.profileHandleNotSet,
                    textAlign: TextAlign.center,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.sokoShade3,
                      fontSize: 14,
                      decoration: TextDecoration.underline,
                      decorationColor: AppColors.sokoShade3,
                    ),
                  ),
                ),
              ),
            ],
          )
        : Text(
            l10n.profileTitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: AppColors.sokoInk,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          );

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
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
          Expanded(child: centerContent),
          // Authenticated users see the inbox affordance top-right
          // (replaces the in-list Notifications row). 40×40 is close
          // enough to the leading 48 px IconButton that the centered
          // title stays visually balanced. Unauthenticated keeps the
          // bare 48 px spacer.
          if (isAuthenticated)
            const NotificationsTopButton()
          else
            const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _AuthedMenuBody extends ConsumerWidget {
  final String displayName;
  final bool hasDisplayName;

  const _AuthedMenuBody({
    required this.displayName,
    required this.hasDisplayName,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final isAdmin = ref.watch(currentUserProvider)?.role == UserRole.admin;
    // Memory is an ADMIN-ONLY surface: visible to admins (role-based, like the
    // "Replay tour" row below) and in local DEBUG builds for testing. Was
    // `EnvironmentConfig.isDev`, which also rendered it for non-admins in
    // dev/staging RELEASE builds (PROD-3210 §4.5 — the one real leak the
    // audit found); kDebugMode matches the map-debug gate and is compile-time
    // false in anything shipped.
    final showMemory = isAdmin || kDebugMode;

    final user = ref.watch(currentUserProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: _AvatarTile(
            initial: _initialFor(displayName, hasDisplayName),
            // PROD-2785 — tap the avatar to share the user's persona.
            // Backend accepts `(persona, me)` as the share-asset key
            // (`ShareContext` enum at openapi spec).
            onTap: () => showSokoShareSheet(
              context: context,
              ref: ref,
              shareContext: 'persona',
              entityId: 'me',
              shareUrl: _buildPersonaShareUrl(user?.handle),
            ),
          ),
        ),
        const SizedBox(height: 16),
        _SokoMenuRow(
          icon: LucideIcons.user,
          tileColor: AppColors.sokoRed,
          title: l10n.profileMenuAccount,
          subtitle: l10n.profileMenuAccountSubtitle,
          onTap: () => context.push(AppRoutes.menuAccount),
        ),
        _SokoMenuRow(
          icon: LucideIcons.circle_plus,
          tileColor: AppColors.sokoLilac,
          title: l10n.profileMenuBusinessConnections,
          subtitle: l10n.profileMenuBusinessConnectionsSubtitle,
          onTap: () => context.push(AppRoutes.menuBusinessConnections),
        ),
        _SokoMenuRow(
          icon: LucideIcons.bell,
          tileColor: AppColors.sokoBlue,
          title: l10n.profileMenuPreferences,
          subtitle: l10n.profileMenuPreferencesSubtitle,
          onTap: () => context.push(AppRoutes.menuPreferences),
        ),
        _SokoMenuRow(
          // A helping hand, not an eye — the eye now belongs to "Ver como
          // visitante", and an eye never said "support" in the first place.
          icon: LucideIcons.hand_helping,
          tileColor: AppColors.sokoGreen,
          title: l10n.profileMenuSupport,
          subtitle: l10n.profileMenuSupportSubtitle,
          onTap: () => context.push(AppRoutes.menuSupport),
        ),
        _SokoMenuRow(
          icon: LucideIcons.sparkles,
          tileColor: AppColors.sokoPink,
          title: l10n.profileMenuAiData,
          subtitle: l10n.profileMenuAiDataSubtitle,
          onTap: () => context.push(AppRoutes.menuAiData),
        ),
        _SokoMenuRow(
          icon: LucideIcons.file_text,
          tileColor: AppColors.sokoYellow,
          title: l10n.profileMenuAbout,
          subtitle: l10n.profileMenuAboutSubtitle,
          onTap: () => context.push(AppRoutes.menuAbout),
        ),
        _SokoMenuRow(
          icon: LucideIcons.eye,
          tileColor: AppColors.sokoBlue,
          title: l10n.profileMenuPreviewAsVisitor,
          subtitle: l10n.profileMenuPreviewAsVisitorSubtitle,
          onTap: () => context.push(AppRoutes.profilePreview),
        ),
        // PROD-4164: the self profile's tab bar became Memória / Emblemas, so
        // the Ligações tab (which carried Locals + suggested people) and the
        // header's user-plus shortcut are gone. Find people keeps an entry
        // here so the surface isn't orphaned.
        _SokoMenuRow(
          icon: LucideIcons.user_plus,
          tileColor: AppColors.sokoGreen,
          title: l10n.profileFindPeople,
          subtitle: l10n.profileFindPeopleSubtitle,
          onTap: () => context.push(AppRoutes.findPeople),
        ),
        if (showMemory)
          _SokoMenuRow(
            glyph: const SokoBrainIcon(size: 20),
            tileColor: AppColors.sokoPink,
            title: '[Admin] ${l10n.memoryDrawerLabel}',
            subtitle: l10n.memoryDrawerSubtitle,
            onTap: () => context.push(AppRoutes.menuMemory),
          ),
        // PROD-2775 admin pilot — open a user's social profile by @handle.
        // Social profile pilot (PROD-2775..2821). ONE admin entry — the profile
        // is the hub: Edit, Find people and Follow requests all hang off the
        // self-view header; Followers/Following/Zines/Saved off the counts row.
        if (isAdmin)
          _SokoMenuRow(
            icon: LucideIcons.user_round,
            tileColor: AppColors.sokoBlue,
            title: '[admin] Social profile',
            subtitle: 'Your profile hub — edit, find people, requests (pilot)',
            onTap: () {
              final handle = user?.handle;
              if (handle == null || handle.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Your account has no handle yet.'),
                  ),
                );
                return;
              }
              context.push(AppRoutes.publicProfilePath(handle));
            },
          ),
        // Admin-only "Replay tour" row. Gated on the same local admin
        // signal as the rest of our admin-only surfaces (About build
        // info, chat feedback): `currentUser.role == UserRole.admin`,
        // derived client-side from the authed profile — no PostHog flag
        // needed. Regular users never see it; admins can re-trigger the
        // tour in any build (incl. release/production) without juggling
        // fresh accounts. start(force: true) bypasses both the hasSeen
        // persistence flag and the server-side onboardingComplete gate.
        if (isAdmin)
          _SokoMenuRow(
            icon: LucideIcons.refresh_cw,
            tileColor: AppColors.sokoPink,
            title: '[admin] Replay tour',
            subtitle: 'Admin-only; replays the onboarding product tour',
            onTap: () {
              context.go(AppRoutes.home);
              WidgetsBinding.instance.addPostFrameCallback((_) {
                ref
                    .read(productTourControllerProvider.notifier)
                    .start(force: true);
              });
            },
          ),
        // Admin-only "Replay onboarding" row — mirrors "Replay tour" above.
        // Resets the caller's server-side onboarding (clears state + flips
        // onboarding_complete back to false via POST /onboarding/reset), then
        // routes into the REAL API-backed flow so admins replay the production
        // gate/persistence from the top — not the in-memory preview.
        // Admin-only PERMANENTLY (a reset/replay control, not part of the
        // onboarding-cohort rollout — normal users must never see it, even
        // once the `unskippable-onboarding-v1` flag widens to them).
        if (isAdmin)
          _SokoMenuRow(
            icon: LucideIcons.messages_square,
            tileColor: AppColors.sokoLilac,
            title: '[admin] Replay onboarding',
            subtitle: 'Admin-only; resets + replays the real onboarding chat',
            onTap: () async {
              final messenger = ScaffoldMessenger.of(context);
              final router = GoRouter.of(context);
              final api = ref.read(onboardingStateApiProvider);
              final auth = ref.read(authStateProvider.notifier);
              // The walkthrough (product tour) "seen" marker lives ONLY on the
              // client (`product_tour_v1_seen_<userId>` pref) — the server
              // reset can't touch it, so without this the tour stays
              // suppressed forever after a replay. Capture before the awaits.
              final tourPersistence = ref.read(tourPersistenceProvider);
              final tourUserId = ref.read(tourUserIdProvider);
              try {
                await api.resetState();
                // Reset the walkthrough back to fresh-user state alongside the
                // server reset: clear the local seen flag, and return the
                // in-memory controller to `idle` so the tour host's
                // `_maybeStartTour` (which only fires from `idle`) can
                // re-evaluate later. NOT a force-start — the tour re-appears
                // only where its own gates already permit.
                if (tourUserId != null) {
                  await tourPersistence.clear(tourUserId);
                }
                ref.read(productTourControllerProvider.notifier).abort();
                // Re-read the profile so onboarding_complete=false propagates
                // and the gate re-engages before we enter the flow.
                await auth.refreshUserProfile();
                router.go(AppRoutes.onboardingChat);
              } catch (_) {
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Could not reset onboarding — the backend reset '
                      'endpoint may not be deployed yet.',
                    ),
                  ),
                );
              }
            },
          ),
        // Admin-only fake-door panel: opens a sheet to trigger any campaign
        // (sheet/fullscreen/page) and toggle the Discovery warm-up. Same
        // client-side admin gate as the rows above.
        if (isAdmin)
          _SokoMenuRow(
            icon: LucideIcons.sparkles,
            tileColor: AppColors.sokoYellow,
            title: '[admin] Fake-door',
            subtitle: 'Trigger a campaign / toggle warm-up',
            onTap: () => showFakeDoorAdminSheet(context, ref),
          ),
      ],
    );
  }

  String _initialFor(String name, bool hasDisplayName) {
    if (!hasDisplayName || name.isEmpty) return '?';
    return name.substring(0, 1).toUpperCase();
  }
}

class _GuestMenuBody extends ConsumerWidget {
  const _GuestMenuBody();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Center(
          child: Column(
            children: [
              Image.asset(
                'assets/images/illustrations/soko-seating-and-reading.webp',
                width: 115,
                height: 115,
                fit: BoxFit.contain,
              ),
              const SizedBox(height: 16),
              Text(
                l10n.guestModeProfileTitle,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w600,
                  color: AppColors.sokoInk,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l10n.guestModeProfileSubtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 14,
                  color: AppColors.sokoShade3,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),
        SokoCtaButton(
          label: l10n.authButtonSignIn,
          variant: SokoCtaVariant.pink,
          onPressed: () {
            ref
                .read(unifiedAnalyticsProvider)
                .trackAuthPrompt(
                  page: AuthPage.login,
                  action: AuthPromptAction.view,
                  referrer: AuthReferrer.guestProfile,
                );
            navigateToLoginPreservingReturn(
              context,
              ref,
              referrer: AuthReferrer.guestProfile,
            );
          },
        ),
        const SizedBox(height: 32),
        const Divider(color: AppColors.sokoInk8),
        const SizedBox(height: 16),
        _SokoMenuRow(
          // A helping hand, not an eye — the eye now belongs to "Ver como
          // visitante", and an eye never said "support" in the first place.
          icon: LucideIcons.hand_helping,
          tileColor: AppColors.sokoGreen,
          title: l10n.profileMenuSupport,
          subtitle: l10n.profileMenuSupportSubtitle,
          onTap: () => context.push(AppRoutes.menuSupport),
        ),
        _SokoMenuRow(
          icon: LucideIcons.file_text,
          tileColor: AppColors.sokoYellow,
          title: l10n.profileMenuAbout,
          subtitle: l10n.profileMenuAboutSubtitle,
          onTap: () => context.push(AppRoutes.menuAbout),
        ),
      ],
    );
  }
}

/// Large rounded-square avatar surface. The backend doesn't expose a
/// profile photo URL yet, so we render the first letter of the user's
/// display name inside a sokoPink tile. Sized down to ~2/3 on mobile
/// viewports (below [PageLayout.desktopBreakpoint]) so the avatar
/// doesn't dominate the column on phones.
///
/// Tap opens the persona share sheet (PROD-2785).
class _AvatarTile extends StatelessWidget {
  final String initial;
  final VoidCallback? onTap;

  const _AvatarTile({required this.initial, this.onTap});

  @override
  Widget build(BuildContext context) {
    final isMobile =
        MediaQuery.of(context).size.width < PageLayout.desktopBreakpoint;
    final double tileSize = isMobile ? 88 : 160;
    final double initialSize = isMobile ? 36 : 64;
    final double radius = isMobile ? 12 : 16;

    final tile = Container(
      width: tileSize,
      height: tileSize,
      decoration: BoxDecoration(
        color: AppColors.sokoPink,
        borderRadius: BorderRadius.circular(radius),
      ),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            fontFamily: 'SeasonMix',
            fontWeight: FontWeight.w400,
            color: AppColors.sokoInk,
            fontSize: initialSize,
            height: 1.0,
          ),
        ),
      ),
    );

    if (onTap == null) return tile;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: tile,
      ),
    );
  }
}

/// Builds the canonical Soko URL for the current user's persona, used as
/// the body of the copy-link / WhatsApp / system-share channels. The
/// IG-Story channel ignores this and uses the BE-supplied
/// `attribution_url` instead.
///
/// Prefers a handle-based URL (`/u/<handle>`) when the user set one;
/// falls back to `/me` so guests-with-no-handle still get a non-empty
/// link (the route on the webapp side decides what to render).
String _buildPersonaShareUrl(String? handle) {
  final webappUrl = ApiConstants.webappUrl;
  final path = (handle != null && handle.isNotEmpty) ? '/u/$handle' : '/me';
  return '$webappUrl$path'
      '?utm_source=soko_app&utm_medium=share&utm_campaign=persona_share';
}

/// Soko-rebranded menu list row. Renders disabled (40 % opacity, no
/// tap) when [onTap] is null; enabled rows wrap in `Material > InkWell`
/// for the standard ripple. Each menu row passes
/// `onTap: () => context.push(AppRoutes.menuX)`. The disabled state is
/// kept for guarding against in-progress migrations / feature flags.
class _SokoMenuRow extends StatelessWidget {
  final IconData? icon;

  /// Custom glyph in place of a Lucide one — the memory row uses the Figma
  /// `Icon/Brain` SVG. Exactly one of [icon] / [glyph] is set.
  final Widget? glyph;
  final Color tileColor;
  final String title;
  final String subtitle;
  final VoidCallback? onTap;

  const _SokoMenuRow({
    this.icon,
    this.glyph,
    required this.tileColor,
    required this.title,
    required this.subtitle,
    this.onTap,
  });

  bool get _enabled => onTap != null;

  @override
  Widget build(BuildContext context) {
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: tileColor,
              borderRadius: BorderRadius.circular(8),
            ),
            child: glyph ?? Icon(icon, color: AppColors.sokoInk, size: 20),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: AppColors.sokoInk,
                    fontWeight: FontWeight.w500,
                    fontSize: 17,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: const TextStyle(
                    color: AppColors.sokoShade3,
                    fontSize: 13,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Container(
            width: 32,
            height: 32,
            decoration: const BoxDecoration(
              color: AppColors.sokoInk8,
              shape: BoxShape.circle,
            ),
            child: const Icon(
              LucideIcons.arrow_up_right,
              color: AppColors.sokoInk,
              size: 16,
            ),
          ),
        ],
      ),
    );

    if (!_enabled) {
      return IgnorePointer(child: Opacity(opacity: 0.4, child: content));
    }
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: content,
      ),
    );
  }
}

class _SokoSignOutButton extends StatelessWidget {
  final VoidCallback onSignOut;

  const _SokoSignOutButton({required this.onSignOut});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    // Uses the canonical Soko CTA pattern (see `SokoCtaButton`) so the
    // Sign Out CTA matches Connect Instagram, Delete Account, and the
    // add-to-list Save button.
    return SokoCtaButton(
      label: l10n.profileButtonSignOut,
      onPressed: onSignOut,
    );
  }
}
