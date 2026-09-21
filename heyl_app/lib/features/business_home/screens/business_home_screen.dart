import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/account_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/instagram_provider.dart';
import '../../discovery/widgets/discovery_shell.dart' show popOrFallback;
import '../providers/business_session_provider.dart';
import '../widgets/business_home_instagram_section.dart';
import '../widgets/business_home_phone_section.dart';
import '../widgets/business_venues_section.dart';

/// Business Home dashboard (PROD-4040 T2.1). App-native shell (Option B): the
/// authed portal renders inside the app's own chrome (back + title), not the
/// marketing landing's chrome. Composes phone-verify, Instagram connect, and
/// venue claim/edit. Reachable at `/business` behind BUSINESS_OWNERSHIP_ENABLED.
class BusinessHomeScreen extends ConsumerStatefulWidget {
  const BusinessHomeScreen({super.key});

  @override
  ConsumerState<BusinessHomeScreen> createState() => _BusinessHomeScreenState();
}

class _BusinessHomeScreenState extends ConsumerState<BusinessHomeScreen>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Mark the business portal active so business tasks that route through
      // shared consumer routes (verify phone → /menu/account, manage IG →
      // /menu/business-connections, edit venue → /venues/:id) aren't re-trapped
      // in consumer onboarding. Session-scoped; see [businessSessionActiveProvider].
      ref.read(businessSessionActiveProvider.notifier).state = true;
      // Phone-verify status needs the auth methods; only fetch when we have
      // none cached so revisits don't flash.
      if (ref.read(accountProvider).authMethods.isEmpty) {
        ref.read(accountProvider.notifier).loadAuthMethods();
      }
      final igStatus = ref.read(instagramProvider).status;
      if (igStatus == InstagramStatus.loading ||
          igStatus == InstagramStatus.error) {
        ref.read(instagramProvider.notifier).loadConnections();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Returning from the Instagram OAuth tab: refresh so a fresh connection is
    // detected (mirrors BusinessConnectionsScreen).
    if (state == AppLifecycleState.resumed) {
      if (ref.read(instagramProvider).status == InstagramStatus.connecting) {
        ref.read(instagramProvider.notifier).loadConnections();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return ColoredBox(
      color: AppColors.sokoPaper,
      child: PageContent(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                title: l10n.businessHomeTitle,
                onBack: () => popOrFallback(context),
              ),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
                  children: const [
                    _Greeting(),
                    SizedBox(height: 28),
                    BusinessHomePhoneSection(sectionNumber: '1'),
                    SizedBox(height: 28),
                    BusinessHomeInstagramSection(sectionNumber: '2'),
                    SizedBox(height: 28),
                    BusinessVenuesSection(sectionNumber: '3'),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header({required this.title, required this.onBack});

  final String title;
  final VoidCallback onBack;

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

class _Greeting extends ConsumerWidget {
  const _Greeting();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final user = ref.watch(currentUserProvider);
    final firstName = (user?.fullName ?? '').trim().split(' ').first;
    final greeting = firstName.isEmpty
        ? l10n.businessHomeGreetingNoName
        : l10n.businessHomeGreeting(firstName);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          greeting,
          style: const TextStyle(
            fontFamily: 'UnJamoBatang',
            fontSize: 34,
            height: 1.05,
            letterSpacing: -1,
            color: AppColors.sokoInk,
          ),
        ),
        const SizedBox(height: 6),
        Text(
          l10n.businessHomeSubtitle,
          style: const TextStyle(fontSize: 15, color: AppColors.sokoShade3),
        ),
      ],
    );
  }
}
