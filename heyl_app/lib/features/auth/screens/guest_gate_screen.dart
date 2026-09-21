import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/page_layout.dart';
import '../../../core/utils/auth_gating.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../discovery/widgets/shell_sliver_page.dart';

/// Gate page shown to unauthenticated visitors when they tap a bottom-nav
/// item that requires sign-in (Início / Zines / Criar) or land on one of
/// those routes via URL. Mirrors the visual chrome of
/// `DiscoveryFooter.comingSoon` (illustration tile + 42px greeting) plus
/// a body line and two action buttons:
///   - "Falar comigo" → `/chat` (Soko AI)
///   - "Iniciar sessão" → `/login` (preserves the return URL)
///
/// Rendered under [DiscoveryShell] in place of the route's real content
/// so the bottom nav remains visible — guests can still reach Conversar
/// and the Menu drawer. Authenticated users never see this widget; the
/// router wires the real screens for them.
///
/// [referrer] is forwarded to the auth analytics so the post-login funnel
/// can attribute conversions back to the nav item the user tapped.
class GuestGateScreen extends ConsumerWidget {
  const GuestGateScreen({super.key, required this.referrer});

  final String referrer;

  /// Matches `DiscoveryScreen.bottomNavReserve` (96 px) — the height the
  /// custom bottom nav consumes inside `Scaffold.bottomNavigationBar`,
  /// including its 20 px vertical padding. We can't read the slot's
  /// height from inside the body (Scaffold doesn't expose it), so we
  /// mirror the same constant the discovery scroll content uses.
  static const double _bottomNavReserve = 96.0;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final inkColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;
    final l10n = Lt.of(context);

    final mediaQuery = MediaQuery.of(context);
    // DiscoveryShell wraps non-full-bleed routes in a SingleChildScrollView,
    // which hands down unbounded vertical constraints — `Center`/`Expanded`
    // wouldn't actually center vertically. Pin the gate to the viewport
    // height minus the top safe-area inset and the bottom-nav reserve so
    // the content sits centered between the page top and the nav bar.
    final availableHeight =
        mediaQuery.size.height - mediaQuery.padding.top - _bottomNavReserve;

    // PROD-1977: page owns its scrollable via [ShellSliverHost].
    return ShellSliverHost(
      slivers: [
        SliverToBoxAdapter(
          child: PageContent(
            child: SizedBox(
              height: availableHeight > 0
                  ? availableHeight
                  : mediaQuery.size.height,
              child: Center(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 24,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Image.asset(
                        'assets/images/illustrations/soko-seating-and-reading.webp',
                        width: 115,
                        height: 115,
                        fit: BoxFit.contain,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        l10n.guestGateGreeting,
                        textAlign: TextAlign.center,
                        style: AppTheme.displayPrimary(
                          fontSize: 42,
                          fontWeight: FontWeight.w300,
                          color: inkColor,
                          height: 0.94,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l10n.guestGateBody,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w300,
                          height: 1.3,
                          color: inkColor,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Wrap(
                        alignment: WrapAlignment.center,
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          BtSqIco(
                            icon: LucideIcons.message_circle,
                            label: l10n.guestGateActionChat,
                            variant: BtSqIcoVariant.idle,
                            onTap: () => context.go(AppRoutes.chat),
                          ),
                          BtSqIco(
                            icon: LucideIcons.log_in,
                            label: l10n.guestGateActionLogin,
                            variant: BtSqIcoVariant.selected,
                            onTap: () => navigateToLoginPreservingReturn(
                              context,
                              ref,
                              referrer: referrer,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
