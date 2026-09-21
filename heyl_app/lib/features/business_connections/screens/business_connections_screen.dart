import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/router/app_router.dart' show AppRoutes;
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../data/models/instagram_connection.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/instagram_provider.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../discovery/widgets/discovery_shell.dart' show popOrFallback;

/// `/menu/business-connections` page (PROD-2022). Replaces the legacy
/// `_BusinessConnectionsContent` case inside `ProfileSheet`'s drawer.
/// Mirrors `account_screen.dart`'s shell — `ColoredBox(sokoPaper) →
/// PageContent → SafeArea → Column(_BCHeader, Expanded(_BCBody))`. Back
/// button uses `popOrFallback` so deep links work.
class BusinessConnectionsScreen extends ConsumerWidget {
  const BusinessConnectionsScreen({super.key});

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
              _BCHeader(
                title: l10n.businessConnectionsTitle,
                onBack: () => popOrFallback(context),
              ),
              const Expanded(child: _BCBody()),
            ],
          ),
        ),
      ),
    );
  }
}

class _BCHeader extends StatelessWidget {
  final String title;
  final VoidCallback onBack;

  const _BCHeader({required this.title, required this.onBack});

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

class _BCBody extends ConsumerStatefulWidget {
  const _BCBody();

  @override
  ConsumerState<_BCBody> createState() => _BCBodyState();
}

class _BCBodyState extends ConsumerState<_BCBody> with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Skip the spinner flash on revisits: only fetch when we have no
      // cached data (initial `.loading`) or are in an error state. The
      // `didChangeAppLifecycleState` branch below still refreshes after
      // OAuth returns, so post-connect data stays fresh.
      final status = ref.read(instagramProvider).status;
      if (status == InstagramStatus.loading ||
          status == InstagramStatus.error) {
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
    // When returning from Custom Tab (Android) or Safari (iOS) after OAuth,
    // reload connections to detect if a new connection was established.
    if (state == AppLifecycleState.resumed) {
      final igState = ref.read(instagramProvider);
      if (igState.status == InstagramStatus.connecting) {
        ref.read(instagramProvider.notifier).loadConnections();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: const [_InstagramSection()],
    );
  }
}

/// Instagram Business integration section — soko-rebranded shell.
class _InstagramSection extends ConsumerWidget {
  const _InstagramSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final state = ref.watch(instagramProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              LucideIcons.instagram,
              size: 20,
              color: AppColors.sokoInk,
            ),
            const SizedBox(width: 8),
            Text(
              l10n.instagramBusinessTitle,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.sokoInk,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          (state.status == InstagramStatus.connected ||
                  state.status == InstagramStatus.disconnecting)
              ? l10n.instagramConnectedDescription
              : l10n.instagramConnectDescription,
          style: const TextStyle(
            fontSize: 14,
            color: AppColors.sokoShade3,
            height: 1.4,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.instagramPublicOnly,
          style: const TextStyle(
            fontSize: 12,
            color: AppColors.sokoShade3,
            fontStyle: FontStyle.italic,
          ),
        ),
        const SizedBox(height: 16),
        _buildBody(context, ref, state, l10n),
      ],
    );
  }

  Widget _buildBody(
    BuildContext context,
    WidgetRef ref,
    InstagramState state,
    Lt l10n,
  ) {
    if (state.status == InstagramStatus.loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.symmetric(vertical: 12),
          child: SizedBox(
            height: 24,
            width: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: AppColors.sokoPink,
            ),
          ),
        ),
      );
    }

    if (state.status == InstagramStatus.noConnection ||
        state.status == InstagramStatus.connecting) {
      final isConnecting = state.status == InstagramStatus.connecting;
      return SokoCtaButton(
        icon: LucideIcons.instagram,
        label: isConnecting
            ? l10n.instagramConnecting
            : l10n.instagramConnectButton,
        loading: isConnecting,
        onPressed: () {
          ref.read(unifiedAnalyticsProvider).trackInstagramConnectStart();
          // Return here (not /home) after the OAuth round-trip, so an owner who
          // reached this from the portal isn't dropped on /home or swept into
          // consumer onboarding by the reload wiping the business session
          // (PROD-4040).
          ref
              .read(instagramProvider.notifier)
              .startConnect(returnPath: AppRoutes.menuBusinessConnections);
        },
      );
    }

    if (state.status == InstagramStatus.connected ||
        state.status == InstagramStatus.disconnecting) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final connection in state.connections)
            _ConnectionTile(
              connection: connection,
              isDisconnecting: state.status == InstagramStatus.disconnecting,
              onDisconnect: () => _confirmDisconnect(context, ref, connection),
            ),
        ],
      );
    }

    if (state.status == InstagramStatus.error) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _errorMessage(l10n, state.errorReason),
            style: const TextStyle(color: AppColors.sokoRed, fontSize: 14),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: () {
              ref.read(instagramProvider.notifier).loadConnections();
            },
            style: TextButton.styleFrom(foregroundColor: AppColors.sokoInk),
            child: Text(l10n.instagramTryAgain),
          ),
        ],
      );
    }

    return const SizedBox.shrink();
  }

  String _errorMessage(Lt l10n, String? reason) {
    switch (reason) {
      case 'oauth_denied':
        return l10n.instagramErrorOauthDenied;
      case 'invalid_request':
        return l10n.instagramErrorInvalidRequest;
      case 'invalid_state':
        return l10n.instagramErrorInvalidState;
      case 'missing_user_id':
        return l10n.instagramErrorMissingUserId;
      case 'api_error':
        return l10n.instagramErrorApiError;
      case 'server_error':
        return l10n.instagramErrorServerError;
      case 'not_configured':
        return l10n.instagramErrorNotConfigured;
      case 'load_failed':
      case 'connect_failed':
      case 'disconnect_failed':
        return l10n.instagramErrorServerError;
      default:
        return l10n.instagramErrorDefault;
    }
  }

  Future<void> _confirmDisconnect(
    BuildContext context,
    WidgetRef ref,
    InstagramConnection connection,
  ) async {
    final confirmed = await showBottomSheetWithHiddenNav<bool>(
      context: context,
      ref: ref,
      builder: (context) =>
          _DisconnectInstagramSheet(username: connection.instagramUsername),
    );

    if (confirmed != true || !context.mounted) return;

    ref
        .read(unifiedAnalyticsProvider)
        .trackInstagramDisconnect(connectionId: connection.id);

    final success = await ref
        .read(instagramProvider.notifier)
        .disconnect(connection.id);

    if (success && context.mounted) {
      await showBottomSheetWithHiddenNav<void>(
        context: context,
        ref: ref,
        builder: (context) => const _DisconnectSuccessSheet(),
      );
    }
  }
}

/// Single connected Instagram account tile — soko-rebranded.
class _ConnectionTile extends StatelessWidget {
  final InstagramConnection connection;
  final bool isDisconnecting;
  final VoidCallback onDisconnect;

  const _ConnectionTile({
    required this.connection,
    required this.isDisconnecting,
    required this.onDisconnect,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final dateStr = _formatDate(connection.connectedAt);

    return Opacity(
      opacity: isDisconnecting ? 0.5 : 1.0,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          '@${connection.instagramUsername}',
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: AppColors.sokoInk,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (connection.accountTypeDisplay.isNotEmpty) ...[
                        const SizedBox(width: 8),
                        _AccountTypeChip(label: connection.accountTypeDisplay),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l10n.instagramConnectedSince(dateStr),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.sokoShade3,
                    ),
                  ),
                  if (connection.isTokenExpiringSoon) ...[
                    const SizedBox(height: 2),
                    Text(
                      l10n.instagramTokenExpiring,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.sokoRed,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            if (isDisconnecting)
              const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.sokoPink,
                ),
              )
            else
              TextButton(
                onPressed: onDisconnect,
                style: TextButton.styleFrom(foregroundColor: AppColors.sokoRed),
                child: Text(l10n.instagramDisconnect),
              ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime date) {
    const months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    return '${months[date.month - 1]} ${date.day}, ${date.year}';
  }
}

/// Pink-tinted chip mirroring `_PublicChip` in `share_list_sheet.dart`.
class _AccountTypeChip extends StatelessWidget {
  final String label;
  const _AccountTypeChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.sokoPink.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: AppColors.sokoPink,
        ),
      ),
    );
  }
}

/// Confirm-disconnect bottom sheet. Same shape as `_RemoveMethodSheet`
/// (`account_screen.dart`) — body-only DSSheetShell with title + content
/// + paired BtSqIco row. Destructive primary uses `sokoRed`.
class _DisconnectInstagramSheet extends StatelessWidget {
  final String username;
  const _DisconnectInstagramSheet({required this.username});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return DSSheetShell(
      bodyPadding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            l10n.instagramDisconnectTitle,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'ZalandoSans',
              fontSize: 18,
              fontWeight: FontWeight.w700,
              height: 1.0,
              letterSpacing: -0.36,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            l10n.instagramDisconnectContent(username),
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'ZalandoSans',
              fontSize: 14,
              fontWeight: FontWeight.w300,
              height: 1.3,
              letterSpacing: -0.14,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: BtSqIco(
                  icon: LucideIcons.x,
                  label: l10n.commonCancel,
                  variant: BtSqIcoVariant.normal,
                  expand: true,
                  onTap: () => Navigator.of(context).pop(false),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: BtSqIco(
                  icon: LucideIcons.unlink_2,
                  label: l10n.instagramDisconnectConfirm,
                  variant: BtSqIcoVariant.selected,
                  selectedBackgroundOverride: AppColors.sokoRed,
                  expand: true,
                  onTap: () => Navigator.of(context).pop(true),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Post-disconnect success sheet — explains the Instagram-side revoke
/// step and links out to the user's Instagram authorizations page.
class _DisconnectSuccessSheet extends StatelessWidget {
  const _DisconnectSuccessSheet();

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    return DSSheetShell(
      bodyPadding: const EdgeInsets.fromLTRB(20, 20, 20, 14),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                LucideIcons.circle_check,
                color: AppColors.sokoPink,
                size: 22,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  l10n.instagramDisconnectedTitle,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontFamily: 'ZalandoSans',
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    height: 1.0,
                    letterSpacing: -0.36,
                    color: AppColors.sokoInk,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            l10n.instagramDisconnectedBody,
            style: const TextStyle(
              fontFamily: 'ZalandoSans',
              fontSize: 14,
              fontWeight: FontWeight.w300,
              height: 1.4,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            l10n.instagramDisconnectedRevokeHint,
            style: const TextStyle(fontSize: 13, color: AppColors.sokoShade3),
          ),
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppColors.sokoShade5,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              l10n.instagramDisconnectedRevokeSteps,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.sokoInk,
                height: 1.4,
              ),
            ),
          ),
          const SizedBox(height: 20),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: BtSqIco(
                  icon: LucideIcons.check,
                  label: MaterialLocalizations.of(context).okButtonLabel,
                  variant: BtSqIcoVariant.normal,
                  expand: true,
                  onTap: () => Navigator.of(context).pop(),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: BtSqIco(
                  icon: LucideIcons.external_link,
                  label: l10n.instagramDisconnectedOpenInstagram,
                  variant: BtSqIcoVariant.selected,
                  expand: true,
                  onTap: () {
                    launchUrl(
                      Uri.parse(
                        'https://www.instagram.com/accounts/manage_access/',
                      ),
                      mode: LaunchMode.externalApplication,
                    );
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
