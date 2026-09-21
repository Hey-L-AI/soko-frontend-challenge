import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/page_layout.dart';
import '../../../data/models/moderation.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../discovery/widgets/discovery_shell.dart' show popOrFallback;
import '../../moderation/providers/blocked_users_provider.dart';

/// PROD-2264 — `/menu/account/blocked-users`. Lists every user the
/// caller has blocked via `POST /blocks`, with Unblock buttons that
/// call `DELETE /blocks/{id}`. Apple Guideline 1.2 requires the user
/// to be able to see and undo their blocks; this screen is the canonical
/// management UI for that.
///
/// Soko has no profile pages so the rows show `@handle` (or
/// "Deleted account" when the user closed their account and the
/// backend returns `blocked_user_display_name: null`) plus a Blocked
/// date — never an avatar.
class BlockedUsersScreen extends ConsumerStatefulWidget {
  const BlockedUsersScreen({super.key});

  @override
  ConsumerState<BlockedUsersScreen> createState() => _BlockedUsersScreenState();
}

class _BlockedUsersScreenState extends ConsumerState<BlockedUsersScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.read(blockedUsersProvider.notifier).load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final state = ref.watch(blockedUsersProvider);

    return ColoredBox(
      color: AppColors.sokoPaper,
      child: PageContent(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Header(
                title: l10n.blockedUsersScreenTitle,
                onBack: () => popOrFallback(context),
              ),
              Expanded(child: _body(context, state)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, BlockedUsersState state) {
    final l10n = Lt.of(context);
    if (state.loading && state.blocks.isEmpty) {
      return const Center(
        child: CircularProgressIndicator(color: AppColors.sokoInk),
      );
    }
    if (state.blocks.isEmpty) {
      return _EmptyState(message: l10n.blockedUsersEmpty);
    }
    return ListView.separated(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      itemCount: state.blocks.length,
      separatorBuilder: (_, _) => const SizedBox(height: 12),
      itemBuilder: (context, index) {
        final block = state.blocks[index];
        return _BlockedUserRow(block: block, onUnblock: () => _unblock(block));
      },
    );
  }

  Future<void> _unblock(BlockedUser block) async {
    final l10n = Lt.of(context);
    final ok = await ref
        .read(blockedUsersProvider.notifier)
        .unblock(block.blockId);
    if (!mounted) return;
    if (ok) {
      showSoko(
        ref,
        message: l10n.blockedUsersUnblockSuccess,
        variant: SokoVariant.success,
      );
    } else {
      showSoko(
        ref,
        message: l10n.blockedUsersUnblockFailure,
        variant: SokoVariant.error,
      );
    }
  }
}

class _Header extends StatelessWidget {
  final String title;
  final VoidCallback onBack;

  const _Header({required this.title, required this.onBack});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(LucideIcons.arrow_left, color: AppColors.sokoInk),
            onPressed: onBack,
            tooltip: MaterialLocalizations.of(context).backButtonTooltip,
          ),
          Expanded(
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: AppTheme.subtitle(color: AppColors.sokoInk),
            ),
          ),
          const SizedBox(width: 48),
        ],
      ),
    );
  }
}

class _BlockedUserRow extends StatelessWidget {
  final BlockedUser block;
  final VoidCallback onUnblock;

  const _BlockedUserRow({required this.block, required this.onUnblock});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final locale = Localizations.localeOf(context);
    final dateFormat = DateFormat.yMMMd(locale.toString());
    final displayName = block.blockedUserDisplayName ?? 'Deleted account';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppColors.sokoShade5,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.sokoInk8, width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  style: AppTheme.body(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: AppColors.sokoInk,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  dateFormat.format(block.createdAt.toLocal()),
                  style: AppTheme.body(
                    fontSize: 12,
                    color: AppColors.sokoInkSecondary,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          TextButton(
            onPressed: onUnblock,
            child: Text(
              l10n.blockedUsersUnblockAction,
              style: AppTheme.body(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: AppColors.sokoInk,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String message;

  const _EmptyState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              LucideIcons.shield_off,
              size: 48,
              color: AppColors.sokoInkSecondary,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: AppTheme.body(
                fontSize: 14,
                color: AppColors.sokoInkSecondary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
