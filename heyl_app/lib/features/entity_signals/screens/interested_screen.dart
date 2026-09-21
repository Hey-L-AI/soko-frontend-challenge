import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../data/models/entity_signal.dart';
import '../../../data/models/social_proof.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/widgets/expert_badge.dart';
import '../../../shared/widgets/soko_back_button.dart';
import '../../profile/utils/profile_style.dart';
import '../../profile/widgets/compact_follow_button.dart';
import '../../profile/widgets/textured_avatar.dart';
import '../providers/interested_provider.dart';

/// Everyone who liked or saved a venue/event — the full roster
/// behind the "… têm interesse" row on the detail page.
///
/// A screen rather than the bottom sheet the "Liked by" row used, matching the
/// zine's follower list: these are people lists, they page, and a route gives
/// them a shareable URL and browser back. Rows are the same format as every
/// other people list in the app.
class InterestedScreen extends ConsumerStatefulWidget {
  final SignalEntityType entityType;
  final String entityId;

  /// Total handed in by the caller so the header reads right on the first
  /// frame, before the first page lands. The server's count wins once loaded —
  /// it is viewer-relative and can move while the page is open.
  final int? initialCount;

  const InterestedScreen({
    super.key,
    required this.entityType,
    required this.entityId,
    this.initialCount,
  });

  @override
  ConsumerState<InterestedScreen> createState() => _InterestedScreenState();
}

class _InterestedScreenState extends ConsumerState<InterestedScreen> {
  final _scroll = ScrollController();

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    _scroll.removeListener(_onScroll);
    _scroll.dispose();
    super.dispose();
  }

  /// Pull the next page while there is still a screenful below, so paging never
  /// shows a gap at the bottom.
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final remaining =
        _scroll.position.maxScrollExtent - _scroll.position.pixels;
    if (remaining < 400) {
      ref
          .read(
            interestedProvider((
              type: widget.entityType,
              id: widget.entityId,
            )).notifier,
          )
          .loadMore();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final key = (type: widget.entityType, id: widget.entityId);
    final async = ref.watch(interestedProvider(key));
    final count = async.valueOrNull?.total ?? widget.initialCount ?? 0;

    return ColoredBox(
      color: AppColors.sokoPaper,
      child: PageContent(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 16, 8),
                child: Row(
                  children: [
                    SokoBackButton(
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        l10n.interestedSheetTitle(count),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Pt.b1Bold,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: async.when(
                  loading: () => const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  error: (_, __) => Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Text(
                        l10n.commonSomethingWrong,
                        textAlign: TextAlign.center,
                        style: Pt.b2.copyWith(color: pInk50),
                      ),
                    ),
                  ),
                  data: (state) => ListView.builder(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                    itemCount:
                        state.items.length + (state.isLoadingMore ? 1 : 0),
                    itemBuilder: (_, i) {
                      if (i >= state.items.length) {
                        return const Padding(
                          padding: EdgeInsets.symmetric(vertical: 16),
                          child: Center(
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        );
                      }
                      return InterestedPersonRow(person: state.items[i]);
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One person: the standard people-row (card avatar, name, @handle) shared with
/// the zine and profile follower lists, plus the Follow button.
///
/// Deliberately built from the same pieces as `list_followers_screen.dart`'s
/// row — [TexturedAvatar] at 50×63, [Pt.b1Bold] / [Pt.b2], [ExpertBadge],
/// [CompactFollowButton]. Every list of people in the app should read as the
/// same list.
///
/// The row does NOT show whether the person liked or saved. The distinction is
/// still carried per-person on the wire ([InterestedUser.liked] / `.saved`) —
/// it is what makes the list one list rather than two — but showing it turned
/// every row into a small puzzle for no decision the reader has to make.
class InterestedPersonRow extends ConsumerWidget {
  final InterestedUser person;
  const InterestedPersonRow({super.key, required this.person});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = person.user;
    final fullName = user.fullName?.trim() ?? '';
    final handle = user.handle?.trim() ?? '';
    final displayName = fullName.isNotEmpty
        ? fullName
        : (handle.isNotEmpty ? '@$handle' : '');
    if (displayName.isEmpty) return const SizedBox.shrink();

    // No Follow button on your own row — the same rule the follower lists use.
    final isSelf = ref.watch(currentUserProvider)?.id == user.id;

    final identity = Row(
      children: [
        TexturedAvatar(
          url: user.avatarUrl,
          name: fullName.isNotEmpty ? fullName : handle,
          colorSeed: user.id,
          width: 50,
          height: 50,
          initialFontScale: 0.34,
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Flexible(
                    child: Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Pt.b1Bold,
                    ),
                  ),
                  if (user.isExpert) ...[
                    const SizedBox(width: 6),
                    const ExpertBadge(compact: true),
                  ],
                ],
              ),
              if (handle.isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(
                  '@$handle',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Pt.b2.copyWith(color: pInk50),
                ),
              ],
            ],
          ),
        ),
      ],
    );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          // Only the identity half navigates — a tap on the glyphs or the
          // button must not also push the profile.
          Expanded(
            child: (handle.isEmpty)
                ? identity
                : GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () =>
                        context.push(AppRoutes.publicProfilePath(handle)),
                    child: identity,
                  ),
          ),
          if (!isSelf) ...[
            const SizedBox(width: 8),
            CompactFollowButton(
              userId: user.id,
              initialFollowing: person.isFollowing,
              requested: person.requested,
              followsYou: person.followsYou,
              analyticsSource: 'interested_list',
              refreshSuggestionsOnChange: true,
            ),
          ],
        ],
      ),
    );
  }
}
