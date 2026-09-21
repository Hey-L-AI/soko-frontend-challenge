import 'dart:async';

import 'package:flutter/cupertino.dart' show CupertinoSliverRefreshControl;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../data/models/social/user_search_item.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/utils/share_helpers.dart';
import '../../../shared/widgets/expert_badge.dart';
import '../../../shared/widgets/soko_back_button.dart';
import '../../../shared/widgets/soko_grunge_surface.dart';
import '../../lists/utils/zine_cover_recipe.dart';
import '../../lists/widgets/zine/list_zine_cover.dart';
import '../providers/people_providers.dart';
import '../utils/profile_links.dart';
import '../utils/profile_style.dart';
import '../widgets/compact_follow_button.dart';
import '../widgets/mutual_avatars_row.dart';
import '../widgets/suggestions_load_more.dart';
import '../widgets/textured_avatar.dart';

/// Find people — search by @handle/name, quick ways to add friends (invite /
/// contacts / QR), and "Locals suggested" with zine-cover previews
/// (PROD-2777 / PROD-2821). Admin-gated pilot.
///
/// Contacts + QR are native-only in practice (the web has no reliable contacts
/// API and limited camera QR); on web they surface an "available on the app"
/// note so the layout is testable.
class DiscoverPeopleScreen extends ConsumerStatefulWidget {
  const DiscoverPeopleScreen({super.key});

  @override
  ConsumerState<DiscoverPeopleScreen> createState() =>
      _DiscoverPeopleScreenState();
}

class _DiscoverPeopleScreenState extends ConsumerState<DiscoverPeopleScreen> {
  final _ctrl = TextEditingController();
  Timer? _debounce;
  String _query = '';

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted) setState(() => _query = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Mirror peopleSearchProvider: a leading `@` doesn't count toward the
    // 2-char minimum, so "@jo" searches like "jo".
    final trimmedQuery = _query.trim();
    final searching =
        (trimmedQuery.startsWith('@')
                ? trimmedQuery.substring(1).trim()
                : trimmedQuery)
            .length >=
        2;
    return ColoredBox(
      color: AppColors.sokoPaper,
      child: PageContent(
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 16, 12),
                child: Row(
                  children: [
                    SokoBackButton(
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                    const SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        Lt.of(context).findPeopleTitle,
                        style: Pt.display,
                      ),
                    ),
                    const SizedBox(width: 8),
                    // Binoculars "spotting" character beside the title.
                    Image.asset(
                      'assets/images/illustrations/soko-binoculars.png',
                      width: 40,
                      height: 40,
                      fit: BoxFit.contain,
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: _SearchField(controller: _ctrl, onChanged: _onChanged),
              ),
              Expanded(
                child: searching
                    ? _Results(query: _query)
                    : const _DiscoverBody(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Soko-styled search input.
class _SearchField extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  const _SearchField({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      textInputAction: TextInputAction.search,
      style: Pt.b2,
      decoration: InputDecoration(
        isDense: true,
        hintText: Lt.of(context).discoverPeopleSearchHint,
        hintStyle: Pt.b2.copyWith(color: pInk50),
        prefixIcon: Icon(LucideIcons.search, size: 18, color: pInk50),
        prefixIconConstraints: const BoxConstraints(
          minWidth: 40,
          minHeight: 40,
        ),
        filled: true,
        fillColor: Colors.white,
        contentPadding: const EdgeInsets.symmetric(vertical: 11, horizontal: 4),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: pInk8),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: pInk8),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: const BorderSide(color: AppColors.sokoPinkMiddle),
        ),
      ),
    );
  }
}

/// The default (not-searching) body: quick add-friend actions + suggestions.
class _DiscoverBody extends ConsumerStatefulWidget {
  const _DiscoverBody();

  @override
  ConsumerState<_DiscoverBody> createState() => _DiscoverBodyState();
}

class _DiscoverBodyState extends ConsumerState<_DiscoverBody> {
  bool _suggestionsTracked = false;

  /// Batched on purpose — per-card impressions would be high-volume and tell
  /// us nothing extra, because the taps already arrive as `user_follow` with
  /// `source: 'suggestions'`. This is just the funnel's denominator: how many
  /// suggestions were actually put in front of someone.
  void _trackSuggestionsViewed(int count) {
    if (_suggestionsTracked || count == 0) return;
    _suggestionsTracked = true;
    ref
        .read(unifiedAnalyticsProvider)
        .trackSuggestedUsersViewed(
          suggestionCount: count,
          source: 'find_people',
        );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final async = ref.watch(suggestedUsersPagedProvider);
    async.whenData((state) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _trackSuggestionsViewed(state.items.length);
      });
    });
    // Pull-to-refresh, same motion as the home feed (see
    // `docs/learnings/cupertino-sliver-refresh-for-feeds.md`): the content
    // drags down with the finger and the spinner reveals beneath it, rather
    // than a Material overlay sliding on its own timeline.
    return CustomScrollView(
      // Bouncing so the control can expand on overscroll; `Always…` so the
      // pull still works when the content fits the viewport.
      physics: const AlwaysScrollableScrollPhysics(
        parent: BouncingScrollPhysics(),
      ),
      slivers: [
        // MUST be the first sliver — any sliver above it, even a zero-height
        // one, ratchets the viewport's negative overlap up to 0 and the
        // control never activates (PROD-2065).
        //
        // No safe-area extent bump here (unlike the shell's copy in
        // `shell_sliver_page.dart`): this scrollable starts below the title
        // row and the search field, so the spinner is never behind the notch.
        CupertinoSliverRefreshControl(
          onRefresh: () => refreshSuggestedPeople(ref),
        ),
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              _ActionRow(
                icon: LucideIcons.smile,
                iconBg: AppColors.sokoRed,
                title: l10n.findPeopleInviteFriendsTitle,
                subtitle: l10n.findPeopleInviteFriendsSubtitle,
                onTap: () => _inviteFriends(context, ref),
              ),
              const SizedBox(height: 8),
              _ActionRow(
                icon: LucideIcons.user_round,
                iconBg: AppColors.sokoLilac,
                title: l10n.findContactsTitle,
                subtitle: l10n.findPeopleContactsSubtitle,
                // Native only — the web has no reliable contacts API, so it
                // shows the "use the app" sheet instead of the real sync flow.
                onTap: () => kIsWeb
                    ? showFindPeopleOnAppSheet(
                        context,
                        title: l10n.findContactsTitle,
                        body: l10n.findPeopleContactsOnAppBody,
                      )
                    : context.push(AppRoutes.findPeopleContacts),
              ),
              const SizedBox(height: 8),
              _ActionRow(
                icon: LucideIcons.qr_code,
                iconBg: AppColors.sokoBlue,
                title: l10n.findPeopleQrTitle,
                subtitle: l10n.findPeopleQrSubtitle,
                // Just renders your profile QR — no camera involved — so it
                // works on every platform, webapp included.
                onTap: () => _showMyQrSheet(context, ref),
              ),
              const SizedBox(height: 26),
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(l10n.findPeopleLocalsSuggested, style: Pt.b1Bold),
              ),
              async.when(
                loading: () => const Padding(
                  padding: EdgeInsets.only(top: 24),
                  child: Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
                error: (_, __) => _Message(l10n.findPeopleSuggestionsError),
                data: (state) {
                  final dismissed = ref.watch(dismissedSuggestionsProvider);
                  final items = state.items
                      .where((i) => !dismissed.contains(i.userId))
                      .toList();
                  if (items.isEmpty && !state.hasMore) {
                    return _Message(l10n.findPeopleNoSuggestions);
                  }
                  final prefetchAt =
                      items.length - kSuggestionsPrefetchLookahead;
                  return Column(
                    children: [
                      for (final (index, item) in items.indexed)
                        _wrapPrefetch(
                          index == prefetchAt,
                          _SuggestedCard(
                            item: item,
                            onDismiss: () {
                              ref
                                  .read(dismissedSuggestionsProvider.notifier)
                                  .dismiss(item.userId);
                              // PROD-3209: negative signal for the people
                              // recommender — dismissals were client-state
                              // only.
                              ref
                                  .read(unifiedAnalyticsProvider)
                                  .trackPeopleSuggestionDismissed(
                                    dismissedPersonId: item.userId,
                                    position: index,
                                  );
                            },
                          ),
                        ),
                      SuggestionsLoadMore(state: state, keyId: 'find-people'),
                    ],
                  );
                },
              ),
            ]),
          ),
        ),
      ],
    );
  }

  Future<void> _inviteFriends(BuildContext context, WidgetRef ref) async {
    ref.read(unifiedAnalyticsProvider).trackInviteShared(source: 'find_people');
    final handle = ref.read(currentUserProvider)?.handle;
    // Same canonical profile link as the profile "Share" button.
    final url = (handle != null && handle.isNotEmpty)
        ? profileShareUrl(handle)
        : ApiConstants.webappUrl;
    await shareItem(
      context: context,
      ref: ref,
      title: Lt.of(context).inviteShareMessageTitle,
      url: url,
    );
  }
}

/// A tappable "add friends" entry row: a coloured square glyph + title/subtitle
/// and a circular ↗ affordance. Borderless — sits flat on the paper (Figma
/// 7140:22343).
class _ActionRow extends StatelessWidget {
  final IconData icon;

  /// Fill of the leading square glyph (per-action: red / lilac / blue).
  final Color iconBg;
  final String title;
  final String subtitle;
  final VoidCallback onTap;
  const _ActionRow({
    required this.icon,
    required this.iconBg,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            SokoGrungeSurface(
              width: 48,
              height: 60,
              radius: 2,
              color: iconBg,
              textureOpacity: 0.2,
              child: Icon(icon, size: 20, color: AppColors.sokoInk),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: Pt.b1),
                  const SizedBox(height: 2),
                  Text(subtitle, style: Pt.b2.copyWith(color: pInk50)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                color: AppColors.sokoShade45,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Icon(
                LucideIcons.arrow_up_right,
                size: 18,
                color: AppColors.sokoInk,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A suggested-user card: identity + follow button, with a row of zine-cover
/// previews underneath (tap a cover to open that zine). A top-right "X"
/// dismisses the suggestion.
/// Arm the next-page prefetch on one row near the end of the list; every other
/// row passes through untouched.
Widget _wrapPrefetch(bool armed, Widget child) =>
    armed ? SuggestionsPrefetch(keyId: 'find-people', child: child) : child;

class _SuggestedCard extends StatelessWidget {
  final UserSearchItem item;
  final VoidCallback? onDismiss;
  const _SuggestedCard({required this.item, this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final handle = item.handle;
    // Borderless — sits flat on the paper (Figma). The zine-cover previews are
    // kept, indented under the name so they still read as this user's row even
    // without a card outline.
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
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
                            Row(
                              children: [
                                Flexible(
                                  child: Text(
                                    item.fullName ?? '@${item.handle ?? ''}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: Pt.b1Bold,
                                  ),
                                ),
                                if (item.isExpert) ...[
                                  const SizedBox(width: 6),
                                  const ExpertBadge(compact: true),
                                ],
                              ],
                            ),
                            ..._subtitle(),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              CompactFollowButton(
                userId: item.userId,
                initialFollowing: item.isFollowing,
                followsYou: item.followsYou,
                requested: item.requested,
                analyticsSource: 'suggestions',
              ),
              if (onDismiss != null) ...[
                const SizedBox(width: 2),
                GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: onDismiss,
                  child: Padding(
                    padding: const EdgeInsets.all(4),
                    child: Icon(LucideIcons.x, size: 18, color: pInk30),
                  ),
                ),
              ],
            ],
          ),
          if (item.zinePreviews.isNotEmpty) ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.only(left: 62),
              child: Row(
                children: [
                  for (final z in item.zinePreviews.take(3)) ...[
                    _ZinePreviewTile(preview: z),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Subtitle: "@handle · signal" — handle first (Figma), then mutual
  /// followers' mini photos ("N in common"), else shared tastes, else zines.
  List<Widget> _subtitle() {
    final style = Pt.b2.copyWith(color: pInk50);
    final handle = item.handle;
    final handleText = (handle != null && handle.isNotEmpty)
        ? '@$handle'
        : null;
    Widget? signal;
    if (item.mutualFollowersCount > 0) {
      signal = MutualAvatarsRow(
        avatars: item.mutualFollowerAvatars,
        totalCount: item.mutualFollowersCount,
        text: '${item.mutualFollowersCount} in common',
        textStyle: style,
      );
    } else if (item.sharedTastesCount > 0) {
      signal = Text(
        '${item.sharedTastesCount} tastes in common',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    } else if (item.zinesCount > 0) {
      signal = Text(
        '${item.zinesCount} zines',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    if (handleText == null && signal == null) return const [];
    return [
      const SizedBox(height: 3),
      Row(
        children: [
          if (handleText != null)
            Text(signal != null ? '$handleText · ' : handleText, style: style),
          if (signal != null) Flexible(child: signal),
        ],
      ),
    ];
  }
}

/// A single small zine cover in a suggestion card, tappable to open the zine.
class _ZinePreviewTile extends StatelessWidget {
  final ZinePreview preview;
  const _ZinePreviewTile({required this.preview});

  @override
  Widget build(BuildContext context) {
    const width = 46.0;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => context.push('/lists/${preview.id}'),
      child: SizedBox(
        width: width,
        child: AspectRatio(
          aspectRatio: 195 / 242,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: ListZineCover(
              recipe: ZineCoverRecipe.fromFields(
                listId: preview.id,
                coverType: preview.coverType,
                coverColor: preview.coverColor,
                coverTexture: preview.coverTexture,
                coverTextColor: preview.coverTextColor,
                coverItemId: preview.coverItemId,
                coverItemImageUrl: preview.coverItemImageUrl,
                legacyCoverImageUrl: preview.coverImageUrl,
                fallbackItemImageUrl: preview.previewImage,
                showTitle: false,
                showTexture: preview.coverShowTexture,
                showLogo: false,
              ),
              title: preview.name,
              showTitle: false,
              showLogo: false,
            ),
          ),
        ),
      ),
    );
  }
}

class _Results extends ConsumerStatefulWidget {
  final String query;
  const _Results({required this.query});

  @override
  ConsumerState<_Results> createState() => _ResultsState();
}

class _ResultsState extends ConsumerState<_Results> {
  /// The last query already reported. The widget rebuilds on every parent
  /// setState, so without this a single search would emit repeatedly.
  String? _trackedQuery;

  /// Sends the query *length*, never the text: a people search is somebody
  /// typing a person's name or handle. The length still answers the question
  /// that matters — are short/partial queries coming back empty? — without
  /// putting personal data into PostHog.
  void _trackSearch(int resultCount) {
    if (_trackedQuery == widget.query) return;
    _trackedQuery = widget.query;
    // Mirror the provider's own normalisation so the length matches what was
    // actually searched ("@jo" searches as "jo").
    final trimmed = widget.query.trim();
    final normalised = trimmed.startsWith('@')
        ? trimmed.substring(1).trim()
        : trimmed;
    ref
        .read(unifiedAnalyticsProvider)
        .trackPeopleSearch(
          queryLength: normalised.length,
          resultCount: resultCount,
        );
  }

  @override
  Widget build(BuildContext context) {
    final async = ref.watch(peopleSearchProvider(widget.query));
    return async.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (_, __) => _Message(Lt.of(context).findPeopleSearchError),
      data: (res) {
        // Post-frame — a side effect, not part of building.
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _trackSearch(res.items.length);
        });
        if (res.items.isEmpty) {
          return _Message(Lt.of(context).findPeopleNoResults);
        }
        return ListView.separated(
          padding: const EdgeInsets.all(16),
          itemCount: res.items.length,
          // Rows self-space via their own vertical padding (matches the
          // suggestions list + follow lists).
          separatorBuilder: (_, __) => const SizedBox.shrink(),
          itemBuilder: (_, i) => _PersonRow(item: res.items[i]),
        );
      },
    );
  }
}

/// A compact identity + follow row for the search results surface.
class _PersonRow extends StatelessWidget {
  final UserSearchItem item;
  const _PersonRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final handle = item.handle;
    // Borderless + textured avatar, matching the suggestions list and the
    // followers/following rows across the app (Figma) — not a white card.
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
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                item.fullName ?? '@${item.handle ?? ''}',
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: Pt.b1Bold,
                              ),
                            ),
                            if (item.isExpert) ...[
                              const SizedBox(width: 6),
                              const ExpertBadge(compact: true),
                            ],
                          ],
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
          const SizedBox(width: 8),
          CompactFollowButton(
            userId: item.userId,
            initialFollowing: item.isFollowing,
            followsYou: item.followsYou,
            requested: item.requested,
            // Search row (not a suggestions list): refresh Locals so a
            // follow here isn't stale there. The _SuggestedCard above stays
            // default (it IS the suggestions list — would flicker).
            refreshSuggestionsOnChange: true,
            analyticsSource: 'people_search',
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  const _Message(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 24),
      child: Center(
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Pt.b2.copyWith(color: pInk50),
        ),
      ),
    );
  }
}

/// Bottom sheet showing the signed-in user's own profile QR code (native
/// Find people → "QR code"). A friend scans it with their camera to open the
/// profile and follow. It encodes the same canonical profile link the Share
/// button uses. Web keeps the info sheet — browsers have no reliable in-page
/// camera QR.
Future<void> _showMyQrSheet(BuildContext context, WidgetRef ref) {
  final handle = ref.read(currentUserProvider)?.handle;
  final url = (handle != null && handle.isNotEmpty)
      ? profileShareUrl(handle)
      : ApiConstants.webappUrl;
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.sokoPaper,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: pInk8,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Text(Lt.of(ctx).findPeopleQrTitle, style: Pt.b1Bold),
            const SizedBox(height: 4),
            Text(
              Lt.of(ctx).findPeopleQrSheetBody,
              textAlign: TextAlign.center,
              style: Pt.b2.copyWith(color: pInk50),
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: pInk8),
              ),
              child: QrImageView(
                data: url,
                version: QrVersions.auto,
                size: 220,
                backgroundColor: Colors.white,
                eyeStyle: const QrEyeStyle(
                  eyeShape: QrEyeShape.square,
                  color: AppColors.sokoInk,
                ),
                dataModuleStyle: const QrDataModuleStyle(
                  dataModuleShape: QrDataModuleShape.square,
                  color: AppColors.sokoInk,
                ),
              ),
            ),
            if (handle != null && handle.isNotEmpty) ...[
              const SizedBox(height: 14),
              Text('@$handle', style: Pt.b1Bold),
            ],
          ],
        ),
      ),
    ),
  );
}

/// Info sheet for native-only actions (contacts / QR) shown on web.
Future<void> showFindPeopleOnAppSheet(
  BuildContext context, {
  required String title,
  required String body,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppColors.sokoPaper,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 36,
              height: 4,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: pInk8,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Text(title, style: Pt.b1Bold),
            const SizedBox(height: 8),
            Text(body, style: Pt.b2.copyWith(color: pInk50)),
            const SizedBox(height: 16),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(LucideIcons.smartphone, size: 15, color: pInk50),
                const SizedBox(width: 6),
                Text(Lt.of(ctx).findPeopleAvailableOnApp, style: Pt.b2),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
