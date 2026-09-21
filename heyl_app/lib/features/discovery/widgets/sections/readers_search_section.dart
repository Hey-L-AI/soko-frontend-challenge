import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../../core/router/app_router.dart';
import '../../../../core/services/unified_analytics_service.dart';
import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/auth_gating.dart';
import '../../../../data/models/social/user_search_item.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../../providers/auth_provider.dart';
import '../../../lists/widgets/guest_blur_cta_card.dart';
import '../../../profile/providers/people_providers.dart';
import '../../../profile/utils/profile_style.dart';
import '../../../profile/widgets/compact_follow_button.dart';
import '../../../profile/widgets/textured_avatar.dart';
import '../../providers/search_query_provider.dart';

/// Leitores (readers/people) state of the Discovery search overlay — the
/// fourth category tab (Figma redesign; supersedes the D54-skipped
/// Membros tab). Two modes off the shared [searchQueryProvider]:
///
///   - **typed query (≥ 2 chars, leading `@` not counted)** — user rows
///     from `peopleSearchProvider` (`GET /users/search`).
///   - **browse (no/short query)** — "Locais sugeridos" rows from
///     `orderedSuggestedUsersProvider` (`GET /users/suggested`, then
///     [shuffleLocals]), minus the ones dismissed this session.
///
/// Rows mirror the find-people screen's person row (textured avatar +
/// name/@handle + [CompactFollowButton]); tapping the identity opens the
/// public profile. Both endpoints are auth-gated, so guests get the
/// sign-in CTA instead of a broken list.
class ReadersSearchSection extends ConsumerWidget {
  /// PROD-4081 — the surface's query state. Null means Discovery's own
  /// [searchQueryProvider]; the Procura screen passes its forked one. Nullable
  /// rather than defaulted because the provider is top-level `final`, not
  /// `const`, so it cannot be a default parameter value.
  final StateProvider<String>? queryProvider;

  const ReadersSearchSection({super.key, this.queryProvider});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final isGuest = !ref.watch(isAuthenticatedProvider);
    if (isGuest) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(24, 48, 24, 24),
        child: Center(
          child: GuestBlurCtaCard(
            onSignIn: () => navigateToLoginPreservingReturn(
              context,
              ref,
              referrer: AuthReferrer.guestGateHome,
            ),
          ),
        ),
      );
    }

    final query = ref.watch(queryProvider ?? searchQueryProvider).trim();
    // Mirror peopleSearchProvider's normalization: a leading `@` doesn't
    // count toward the 2-char minimum ("@jo" searches like "jo").
    final normalized = (query.startsWith('@') ? query.substring(1) : query)
        .trim();
    final searching = normalized.length >= 2;

    if (searching) {
      final asyncResults = ref.watch(peopleSearchProvider(query));
      return _ResultsList(
        async: asyncResults,
        emptyText: l10n.discoverySearchNoResults(query),
        filterDismissed: false,
      );
    }

    final asyncSuggested = ref.watch(orderedSuggestedUsersProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 4),
          child: Text(l10n.findPeopleLocalsSuggested, style: Pt.b1Bold),
        ),
        _ResultsList(
          async: asyncSuggested,
          emptyText: l10n.searchNoResults,
          filterDismissed: true,
        ),
      ],
    );
  }
}

class _ResultsList extends ConsumerWidget {
  final AsyncValue<UserSearchListResponse> async;
  final String emptyText;

  /// Browse mode hides suggestions the user dismissed this session on
  /// the find-people screen (shared session state).
  final bool filterDismissed;

  const _ResultsList({
    required this.async,
    required this.emptyText,
    required this.filterDismissed,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final dismissed = filterDismissed
        ? ref.watch(dismissedSuggestionsProvider)
        : const <String>{};
    return async.when(
      loading: () => const Padding(
        padding: EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      ),
      error: (_, __) => _CenteredNote(text: l10n.discoverySearchError),
      data: (response) {
        final items = response.items
            .where((item) => !dismissed.contains(item.userId))
            .toList();
        if (items.isEmpty) return _CenteredNote(text: emptyText);
        return Column(
          children: [for (final item in items) _ReaderRow(item: item)],
        );
      },
    );
  }
}

/// Person row — avatar + name/@handle + follow button. Mirrors the
/// find-people screen's row chrome (borderless, textured avatar).
class _ReaderRow extends StatelessWidget {
  final UserSearchItem item;

  const _ReaderRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final handle = item.handle;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: (handle == null || handle.isEmpty)
                  ? null
                  : () => context.push(AppRoutes.publicProfilePath(handle)),
              child: Row(
                children: [
                  TexturedAvatar(
                    url: item.avatarUrl,
                    name: item.fullName ?? item.handle,
                    colorSeed: item.userId,
                    width: 50,
                    height: 50,
                    initialFontScale: 0.34,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          item.fullName ?? '@${item.handle ?? ''}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Pt.b1Bold,
                        ),
                        if (item.handle != null) ...[
                          const SizedBox(height: 3),
                          Text(
                            '@${item.handle}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Pt.b2.copyWith(color: pInk50),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          CompactFollowButton(
            userId: item.userId,
            initialFollowing: item.isFollowing,
            requested: item.requested,
            followsYou: item.followsYou,
            analyticsSource: 'discovery_readers',
          ),
        ],
      ),
    );
  }
}

class _CenteredNote extends StatelessWidget {
  final String text;

  const _CenteredNote({required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: AppTheme.body(
            fontSize: 14,
            fontWeight: FontWeight.w300,
            color: AppColors.sokoInk.withValues(alpha: 0.6),
          ),
        ),
      ),
    );
  }
}
