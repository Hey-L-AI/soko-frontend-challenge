import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart' show AppRoutes;
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/instagram_provider.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import 'business_home_section_header.dart';

/// Instagram section of the Business Home dashboard (PROD-4040 T2.1). Reuses
/// the shared [instagramProvider]; deep management (disconnect) stays on the
/// dedicated `/menu/business-connections` screen so the flows aren't
/// duplicated. The screen owns the load-on-mount / reload-on-resume lifecycle.
class BusinessHomeInstagramSection extends ConsumerWidget {
  const BusinessHomeInstagramSection({super.key, this.sectionNumber});

  final String? sectionNumber;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final state = ref.watch(instagramProvider);
    final isConnected =
        state.status == InstagramStatus.connected ||
        state.status == InstagramStatus.disconnecting;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        BusinessHomeSectionHeader(
          number: sectionNumber,
          title: l10n.instagramBusinessTitle,
        ),
        const SizedBox(height: 12),
        Text(
          isConnected
              ? l10n.instagramConnectedDescription
              : l10n.businessHomeInstagramDescription,
          style: const TextStyle(
            fontSize: 14,
            color: AppColors.sokoShade3,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 14),
        _body(context, ref, state, l10n),
      ],
    );
  }

  Widget _body(
    BuildContext context,
    WidgetRef ref,
    InstagramState state,
    Lt l10n,
  ) {
    switch (state.status) {
      case InstagramStatus.loading:
        return const Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Center(
            child: SizedBox(
              height: 20,
              width: 20,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppColors.sokoPink,
              ),
            ),
          ),
        );
      case InstagramStatus.connected:
      case InstagramStatus.disconnecting:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final connection in state.connections)
              _ConnectedTile(username: connection.instagramUsername),
          ],
        );
      case InstagramStatus.error:
        return Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () =>
                ref.read(instagramProvider.notifier).loadConnections(),
            style: TextButton.styleFrom(foregroundColor: AppColors.sokoInk),
            child: Text(l10n.instagramTryAgain),
          ),
        );
      case InstagramStatus.noConnection:
      case InstagramStatus.connecting:
        final connecting = state.status == InstagramStatus.connecting;
        return SokoCtaButton(
          icon: LucideIcons.instagram,
          label: connecting
              ? l10n.instagramConnecting
              : l10n.instagramConnectButton,
          variant: SokoCtaVariant.lilac,
          loading: connecting,
          onPressed: () {
            ref.read(unifiedAnalyticsProvider).trackInstagramConnectStart();
            ref
                .read(instagramProvider.notifier)
                .startConnect(returnPath: AppRoutes.businessHome);
          },
        );
    }
  }
}

class _ConnectedTile extends StatelessWidget {
  const _ConnectedTile({required this.username});

  final String username;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.sokoInk8),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: AppColors.sokoPurple,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              LucideIcons.instagram,
              size: 18,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.businessHomeInstagramConnected('@$username'),
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: AppColors.sokoInk,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  l10n.businessHomeInstagramSyncing,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.sokoShade3,
                  ),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => context.push(AppRoutes.menuBusinessConnections),
            style: TextButton.styleFrom(foregroundColor: AppColors.sokoInk),
            child: Text(l10n.businessHomeInstagramManage),
          ),
        ],
      ),
    );
  }
}
