import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart' show SharedByUser;
import '../../../l10n/generated/l10n.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/cached_image.dart';
import '../providers/event_sharers_provider.dart';

/// Opens the "everyone who shared this event" popup (PROD-3163): a bottom sheet
/// listing every sharer, each row a link to their `/u/{handle}` profile. Backed
/// by the paginated [eventSharersProvider]. Only meaningful when there are 2+
/// sharers — the caller ([EventSharersAttribution]) gates on that.
Future<void> showSharersSheet({
  required BuildContext context,
  required WidgetRef ref,
  required String eventId,
  required int totalCount,
}) {
  return showBottomSheetWithHiddenNav<void>(
    context: context,
    ref: ref,
    builder: (_) => DSSheetShell(
      header: _SharersSheetHeader(count: totalCount),
      body: _SharersSheetBody(eventId: eventId),
    ),
  );
}

class _SharersSheetHeader extends StatelessWidget {
  final int count;
  const _SharersSheetHeader({required this.count});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
      child: Row(
        children: [
          Expanded(
            child: Text(
              Lt.of(context).sharersSheetTitle,
              style: const TextStyle(
                fontFamily: 'ZalandoSans',
                fontWeight: FontWeight.w600,
                fontSize: 16,
                letterSpacing: -0.16,
                color: AppColors.sokoInk,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SharersSheetBody extends ConsumerStatefulWidget {
  final String eventId;
  const _SharersSheetBody({required this.eventId});

  @override
  ConsumerState<_SharersSheetBody> createState() => _SharersSheetBodyState();
}

class _SharersSheetBodyState extends ConsumerState<_SharersSheetBody> {
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 300) {
      ref.read(eventSharersProvider(widget.eventId).notifier).loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(eventSharersProvider(widget.eventId));
    final l10n = Lt.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.6;

    if (state.isInitialLoad) {
      return const SizedBox(
        height: 160,
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }

    if (state.items.isEmpty && state.error != null) {
      return _ErrorRetry(
        message: l10n.commonSomethingWrong,
        onRetry: () =>
            ref.read(eventSharersProvider(widget.eventId).notifier).retry(),
      );
    }

    // One trailing slot for the loading spinner / retry affordance.
    final itemCount = state.items.length + (state.hasMore ? 1 : 0);

    return ConstrainedBox(
      constraints: BoxConstraints(maxHeight: maxHeight),
      child: ListView.builder(
        controller: _scrollController,
        shrinkWrap: true,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
        itemCount: itemCount,
        itemBuilder: (context, i) {
          if (i >= state.items.length) {
            // Trailing loader / inline retry for subsequent pages.
            if (state.error != null) {
              return _ErrorRetry(
                message: l10n.commonSomethingWrong,
                onRetry: () => ref
                    .read(eventSharersProvider(widget.eventId).notifier)
                    .retry(),
                compact: true,
              );
            }
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            );
          }
          // Every sharer links to their profile — public profiles are live for
          // all users (was admin-only during rollout). Still guarded by a
          // resolvable handle inside _SharerRow.
          return _SharerRow(sharer: state.items[i], canLinkProfile: true);
        },
      ),
    );
  }
}

class _SharerRow extends StatelessWidget {
  final SharedByUser sharer;

  /// Whether the row links through to the profile — admin-only while the
  /// public-profile route is a pilot (PROD-2775), mirroring PROD-3134.
  final bool canLinkProfile;

  const _SharerRow({required this.sharer, required this.canLinkProfile});

  @override
  Widget build(BuildContext context) {
    final fullName = sharer.fullName?.trim() ?? '';
    final handle = sharer.handle?.trim() ?? '';
    final displayName = fullName.isNotEmpty
        ? fullName
        : (handle.isNotEmpty ? '@$handle' : '');
    if (displayName.isEmpty) return const SizedBox.shrink();

    final avatarUrl = sharer.avatarUrl?.trim() ?? '';
    final tappable = canLinkProfile && handle.isNotEmpty;

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          if (avatarUrl.isNotEmpty)
            CachedThumbnail(
              imageUrl: avatarUrl,
              size: 44,
              borderRadius: BorderRadius.circular(22),
              errorIcon: Icons.person,
            )
          else
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.sokoInk.withValues(alpha: 0.06),
              ),
              child: const Icon(
                Icons.person,
                size: 22,
                color: AppColors.sokoShade1,
              ),
            ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontFamily: 'ZalandoSans',
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                    letterSpacing: -0.15,
                    color: AppColors.sokoInk,
                  ),
                ),
                if (handle.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    '@$handle',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'ZalandoSans',
                      fontWeight: FontWeight.w400,
                      fontSize: 13,
                      letterSpacing: -0.13,
                      color: AppColors.sokoInk.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (tappable)
            const Icon(
              Icons.chevron_right,
              size: 20,
              color: AppColors.sokoShade1,
            ),
        ],
      ),
    );

    if (!tappable) return row;

    return Semantics(
      button: true,
      label: displayName,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            Navigator.of(context).maybePop();
            context.push(AppRoutes.publicProfilePath(handle));
          },
          child: row,
        ),
      ),
    );
  }
}

class _ErrorRetry extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  final bool compact;

  const _ErrorRetry({
    required this.message,
    required this.onRetry,
    this.compact = false,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(
        vertical: compact ? 16 : 32,
        horizontal: 20,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'ZalandoSans',
              fontSize: 13,
              color: AppColors.sokoShade1,
            ),
          ),
          const SizedBox(height: 8),
          // Plain tappable text, not a Material TextButton (design-system rule:
          // bare Material buttons render the old theme). Inline recovery
          // affordance, not a screen/sheet primary CTA.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onRetry,
            child: MouseRegion(
              cursor: SystemMouseCursors.click,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                child: Text(
                  Lt.of(context).commonRetry,
                  style: const TextStyle(
                    fontFamily: 'ZalandoSans',
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                    color: AppColors.sokoInk,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
