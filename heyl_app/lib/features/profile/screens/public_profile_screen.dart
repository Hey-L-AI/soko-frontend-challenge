import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/page_layout.dart';
import '../../../data/models/models.dart';
import '../../../data/models/social/public_profile.dart';
import '../../../data/models/social/user_search_item.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/lists_provider.dart';
import '../../../shared/utils/share_helpers.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../../shared/widgets/cached_image.dart';
import '../../../shared/widgets/circle_icon_button.dart';
import '../../../shared/widgets/clickable.dart';
import '../../../shared/widgets/expert_badge.dart';
import '../../../shared/widgets/search_category_tabs.dart';
import '../../../shared/widgets/soko_back_button.dart';
import '../../../shared/widgets/soko_brain_icon.dart';
import '../../discovery/providers/search_category_provider.dart'
    show DiscoverySearchCategory;
import '../../discovery/widgets/discovery_shell.dart' show popOrFallback;
import '../../library/models/library_filter.dart' show LibraryCategory;
import '../../memory/widgets/memory_tab_view.dart';
import '../../notifications/widgets/notifications_top_button.dart';
import '../../share/widgets/soko_share_sheet.dart';
import '../../venue_claim/widgets/owned_businesses_profile_shelf.dart';
import '../../lists/utils/zine_cover_recipe.dart';
import '../../lists/widgets/zine/sandbox_zine_page.dart';
import '../../lists/widgets/visibility_menu_chip.dart' show visibilityIcon;
import '../../lists/widgets/zine/list_zine_cover.dart';
import '../utils/bio_text.dart';
import 'follow_list_screen.dart' show FollowListBody, FollowListMode;
import '../utils/profile_links.dart';
import '../utils/profile_style.dart';
import '../utils/saved_liked_merge.dart';
import '../providers/people_providers.dart';
import '../providers/public_profile_providers.dart';
import '../widgets/compact_follow_button.dart';
import '../widgets/follow_button.dart';
import '../widgets/mutual_avatars_row.dart';
import '../widgets/suggestions_load_more.dart';
import '../widgets/textured_avatar.dart';

/// Social profile by @handle (PROD-2775), styled to Seb's Figma (node
/// 7058:19395). Self-view is the social hub: identity + inline stats + "what
/// you like" taste chips + Zines / Saved / Activity / Locals, with Edit + Share
/// actions. Others' profiles show the public subset with a Follow action;
/// privacy is enforced server-side.
class PublicProfileScreen extends ConsumerStatefulWidget {
  final String handle;

  /// Read-only "sandbox" mode (onboarding): the profile renders exactly as
  /// normal, but every escape hatch is disabled and the back button pops back
  /// to whoever pushed it (via [Navigator.maybePop]) instead of routing through
  /// GoRouter. Off everywhere except when opened from onboarding. Escape points
  /// read it through [_ProfileSandbox]; in-app actions (Follow) stay live.
  final bool sandbox;

  /// Render your own profile through the visitor layout — what `/profile/preview`
  /// shows. Has no effect on anyone else's profile.
  final bool previewAsVisitor;

  const PublicProfileScreen({
    super.key,
    required this.handle,
    this.sandbox = false,
    this.previewAsVisitor = false,
  });

  @override
  ConsumerState<PublicProfileScreen> createState() =>
      _PublicProfileScreenState();
}

/// Marks the subtree as a sandboxed profile. Leaf widgets with a navigation
/// escape (top-bar share, stat lists, zine/saved taps, connection rows) read
/// this instead of threading a bool through every constructor.
class _ProfileSandbox extends InheritedWidget {
  const _ProfileSandbox({required this.enabled, required super.child});

  final bool enabled;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ProfileSandbox>()?.enabled ??
      false;

  @override
  bool updateShouldNotify(_ProfileSandbox oldWidget) =>
      oldWidget.enabled != enabled;
}

class _PublicProfileScreenState extends ConsumerState<PublicProfileScreen> {
  /// One `profile_open` per screen entry. `initState` invalidates the provider,
  /// so `data:` runs again on the refetch — without this guard every profile
  /// view would be counted at least twice.
  bool _openTracked = false;

  /// The denominator of the social funnel (profile_open → user_follow).
  ///
  /// `source` reuses the attribution trick from `list_link_opened`
  /// (`unified_list_provider.dart`): a session carrying UTM params or an
  /// external referrer arrived from a shared link, anything else is internal
  /// navigation. Profile share URLs carry `utm_campaign=profile_share` (see
  /// `profile_links.dart`), so shared-profile landings — previously invisible,
  /// unlike zines — are now measurable. `profile_open` is in
  /// `_utmEnrichedEvents`, so the UTM props ride along and Growth can slice by
  /// `utm_source`.
  void _trackOpen(PublicProfile profile) {
    if (_openTracked) return;
    _openTracked = true;
    final analytics = ref.read(unifiedAnalyticsProvider);
    final String relationship;
    if (profile.isSelf) {
      relationship = 'self';
    } else if (profile.isMutualFollow) {
      relationship = 'mutual';
    } else if (profile.viewerRelationship == 'following') {
      relationship = 'following';
    } else if (profile.viewerRelationship == 'requested') {
      relationship = 'requested';
    } else if (profile.followsYou) {
      relationship = 'follower';
    } else {
      relationship = 'none';
    }
    analytics.trackProfileOpen(
      source: analytics.hasSessionAttribution ? 'deep_link' : 'in_app',
      isSelf: profile.isSelf,
      isSoko: profile.isOfficial,
      isPrivate: profile.isPrivate,
      relationship: relationship,
      targetUserId: profile.userId,
    );
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      ref.invalidate(followRequestsProvider);
      // Refresh the profile's section data on every entry so changes made
      // elsewhere in the app (a newly saved item in Activity, an edited zine
      // cover, updated tastes, a new/removed saved zine…) show up instantly
      // instead of serving a stale Riverpod cache. skipLoadingOnRefresh (the
      // Riverpod default for `.when`) keeps the current content on screen while
      // the refetch is in flight, so there's no loading flash.
      final handle = widget.handle;
      ref.invalidate(publicProfileProvider(handle));
      ref.invalidate(profileZinesProvider(handle));
      ref.invalidate(profileSavedProvider(handle));
      ref.invalidate(profileSavedZinesProvider(handle));
      ref.invalidate(profileTastesProvider(handle));
      ref.invalidate(profileSocialProofProvider(handle));
    });
  }

  @override
  Widget build(BuildContext context) {
    final handle = widget.handle;
    // On my own profile, a save/unsave or zine follow/unfollow made anywhere in
    // the app mutates the global lists state. Refresh the saved count + Saved
    // tab the instant it changes so the number tracks live and an unsaved item
    // disappears immediately (no waiting, no manual refresh). Gated to self —
    // another user's saved count is unaffected by my saves. The record's fields
    // are the saved-id set instances (copyWith preserves them until a save
    // replaces the set) plus the followed-zines count, so the listener fires
    // only on an actual save/unsave/follow, not on unrelated lists rebuilds.
    final myHandle = ref.watch(currentUserProvider)?.handle;
    if (myHandle != null && myHandle == handle) {
      ref.listen(
        listsProvider.select(
          (s) => (
            s.savedEventIds,
            s.savedVenueIds,
            s.savedGooglePlaceIds,
            s.followingLists.length,
            // Total items across my lists — flips when a place/event is added
            // to or removed from ANY list (incl. a zine), which the saved-id
            // sets alone can miss (re-saving an already-saved entity into a
            // different zine doesn't change the sets, but does change a zine's
            // itemCount). Keeps the Saved tab instant, not just on re-entry.
            s.lists.fold<int>(0, (sum, l) => sum + l.itemCount),
          ),
        ),
        (_, _) {
          ref.invalidate(publicProfileProvider(handle));
          ref.invalidate(profileSavedProvider(handle));
          ref.invalidate(profileSavedZinesProvider(handle));
        },
      );
      // Likes need nothing here: `myLikedItemsProvider` depends on
      // `signalRevisionProvider` directly, so it refetches on any chip tap
      // whether or not this screen is mounted to notice.
      // My "following" count is optimistic (myFollowingCountDeltaProvider) so it
      // tracks a follow/unfollow instantly from ANY surface. Reset the delta
      // whenever my own profile refetches an authoritative count — the fresh
      // value already folds in every change, so pairing the reset with the
      // refetch (whatever triggered it) means it never double-counts.
      ref.listen(publicProfileProvider(handle), (_, next) {
        next.whenData((_) => resetMyProfileCountDeltas(ref));
      });
    }
    final profileAsync = ref.watch(publicProfileProvider(handle));
    return _VisitorPreview(
      enabled: widget.previewAsVisitor,
      child: _ProfileSandbox(
        enabled: widget.sandbox,
        child: ColoredBox(
          color: AppColors.sokoPaper,
          child: PageContent(
            child: Material(
              type: MaterialType.transparency,
              child: SafeArea(
                child: profileAsync.when(
                  loading: () => const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  error: (e, _) => _ProfileError(
                    handle: handle,
                    // Only a genuine 404 means "doesn't exist". A timeout / network
                    // / 5xx is transient — show a "try again" copy, not a scary
                    // "profile may not exist".
                    notFound:
                        e is DioException && e.response?.statusCode == 404,
                    onRetry: () =>
                        ref.invalidate(publicProfileProvider(handle)),
                  ),
                  data: (profile) {
                    // Post-frame: tracking is a side effect, and firing it during
                    // build is how you get "modified during build" surprises.
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted) _trackOpen(profile);
                    });
                    return _ProfileBody(handle: handle, profile: profile);
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// `/profile` shell tab — your own social profile.
class SelfProfileScreen extends ConsumerStatefulWidget {
  /// `/profile/preview` mounts this same screen through the visitor layout.
  final bool previewAsVisitor;
  const SelfProfileScreen({super.key, this.previewAsVisitor = false});

  @override
  ConsumerState<SelfProfileScreen> createState() => _SelfProfileScreenState();
}

class _SelfProfileScreenState extends ConsumerState<SelfProfileScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.invalidate(followRequestsProvider);
    });
  }

  @override
  Widget build(BuildContext context) {
    final handle = ref.watch(currentUserProvider)?.handle;
    if (handle == null || handle.isEmpty) {
      return ColoredBox(
        color: AppColors.sokoPaper,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              Lt.of(context).profileNoHandle,
              style: const TextStyle(color: AppColors.sokoInkSecondary),
            ),
          ),
        ),
      );
    }
    return PublicProfileScreen(
      handle: handle,
      previewAsVisitor: widget.previewAsVisitor,
    );
  }
}

/// Canonical Soko share URL for a profile (PROD-2823) — see [profileShareUrl].
String _profileShareUrl(String handle) => profileShareUrl(handle);

/// The bio to render: whitespace-collapsed and capped at 4 paragraphs, so a bio
/// stored with many blank lines doesn't render as a tall column of empty space.
/// Returns null when there's nothing to show (so the caller omits the row).
String? _bioText(String? raw) {
  if (raw == null) return null;
  final bio = collapseBioWhitespace(raw);
  return bio.isEmpty ? null : bio;
}

/// Full-screen viewer for the profile photo — tap the avatar to enlarge the
/// SAME textured avatar (photo + paper grain). Pinch/drag to zoom; tap anywhere
/// (or the ✕) to dismiss. The scrim is light so the paper feel stays.
void _showAvatarViewer(
  BuildContext context,
  String url,
  String? name, {
  bool official = false,
}) {
  showDialog<void>(
    context: context,
    barrierColor: AppColors.sokoInk.withValues(alpha: 0.55),
    builder: (ctx) {
      final size = MediaQuery.of(ctx).size;
      final w = (size.width * 0.82).clamp(200.0, 360.0);
      // Square, because that is the shape of the avatar it enlarges — a
      // portrait box would letterbox the photo against the crop the user
      // tapped.
      final h = w;
      return GestureDetector(
        onTap: () => Navigator.of(ctx).pop(),
        behavior: HitTestBehavior.opaque,
        child: Stack(
          children: [
            Center(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: TexturedAvatar(
                  url: url,
                  name: name,
                  width: w,
                  height: h,
                  fit: official ? BoxFit.contain : BoxFit.cover,
                  placeholderColor: official
                      ? Colors.white
                      : AppColors.sokoYellow,
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: SafeArea(
                child: IconButton(
                  icon: const Icon(
                    LucideIcons.x,
                    color: AppColors.sokoInk,
                    size: 26,
                  ),
                  onPressed: () => Navigator.of(ctx).pop(),
                ),
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// The visitor's first name (or @handle) for section titles / locked copy.
String _shortName(PublicProfile p, String handle) {
  final n = p.fullName;
  if (n != null && n.isNotEmpty) return n.split(' ').first;
  return '@${p.handle ?? handle}';
}

class _ProfileBody extends ConsumerWidget {
  final String handle;
  final PublicProfile profile;
  const _ProfileBody({required this.handle, required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // In preview mode your own profile deliberately takes the visitor path.
    final isSelf = profile.isSelf && !_VisitorPreview.of(context);
    // PROD-4164: your own profile is now the Memory surface — identity block,
    // then Memória / Emblemas. The Zines / Guardados / Calendário / Ligações
    // tabs moved to the Library. A VISITOR's profile is untouched: they still
    // get the four-tab public view below.
    if (isSelf && !_ProfileSandbox.of(context)) {
      return _SelfProfileBody(handle: handle, profile: profile);
    }
    final hasIncomingRequest =
        !isSelf &&
        (ref
                .watch(followRequestsProvider)
                .valueOrNull
                ?.items
                .any((r) => r.userId == profile.userId) ??
            false);

    final fullyPrivate =
        !isSelf && profile.isPrivate && !profile.canViewPrivateSections;

    if (fullyPrivate) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TopBar(handle: handle, profile: profile),
          Expanded(
            child: ListView(
              children: [
                if (hasIncomingRequest)
                  _IncomingRequestBanner(
                    userId: profile.userId,
                    name: _shortName(profile, handle),
                  ),
                _ProfileHeader(handle: handle, profile: profile),
                _StatsRow(handle: handle, profile: profile),
                _ActionButtons(handle: handle, profile: profile),
                _SocialLinksRow(profile: profile),
                _PrivateProfileBlock(name: _shortName(profile, handle)),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      );
    }

    final savedHidden = isSelf && !profile.showSaved;

    final l10n = Lt.of(context);
    final List<Tab> tabs;
    final List<Widget> views;
    if (profile.isOfficial) {
      // The official Soko account (brand/editorial, not a person) shows a
      // curated 3-tab set — its own Zines, everything Saved into them, and the
      // Editor Picks shelf (crown) — instead of the person-oriented Activity /
      // Connections tabs.
      // Word tabs here too — a profile that mixed icon tabs with the word
      // tabs next door would read as two different screens.
      tabs = <Tab>[
        Tab(height: 40, text: l10n.profileTabZines),
        Tab(height: 40, text: l10n.profileTabEditorPicks),
        Tab(height: 40, text: l10n.profileTabSaved),
      ];
      views = <Widget>[
        _ZinesTab(handle: handle, isSelf: isSelf),
        _EditorPicksTab(handle: handle),
        _SavedTab(
          handle: handle,
          profile: profile,
          hiddenFromOthers: savedHidden,
        ),
      ];
    } else {
      // The calendar is self-only — it aggregates events across all your zines,
      // so it's never shared with other users. Like Locals, the tab appears
      // only on your own profile, always with an "only visible to you" notice.
      // A visitor sees just Zines + Saved.
      // Word tabs, not icons: the redesign labels them Zines / Guardados /
      // Pessoas. (Emblemas sits between Guardados and Pessoas in the mock; it
      // is left out until badges exist.) The calendar was self-only and the
      // self profile no longer uses this tab set at all, so a visitor's three
      // tabs are the whole story here.
      tabs = <Tab>[
        Tab(height: 40, text: l10n.profileTabZines),
        Tab(height: 40, text: l10n.profileTabSaved),
        Tab(height: 40, text: l10n.profileTabPeople),
      ];
      views = <Widget>[
        _ZinesTab(handle: handle, isSelf: isSelf),
        _SavedTab(
          handle: handle,
          profile: profile,
          hiddenFromOthers: savedHidden,
        ),
        _ConnectionsTab(handle: handle, includeLocals: false),
      ];
    }

    return DefaultTabController(
      length: tabs.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _TopBar(handle: handle, profile: profile),
          Expanded(
            child: NestedScrollView(
              headerSliverBuilder: (context, _) => [
                SliverToBoxAdapter(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (hasIncomingRequest)
                        _IncomingRequestBanner(
                          userId: profile.userId,
                          name: _shortName(profile, handle),
                        ),
                      if (_VisitorPreview.of(context)) const _PreviewBanner(),
                      // Same identity block as your own profile — avatar +
                      // name, stacked stats, location · @handle, bio, links —
                      // with the follow pill where the self actions sit.
                      _IdentityBlock(
                        handle: handle,
                        profile: profile,
                        actions: _FollowPill(handle: handle, profile: profile),
                      ),
                      _StatsBlock(handle: handle, profile: profile),
                      _MetaLine(handle: handle, profile: profile),
                      _SocialLinksRow(profile: profile),
                      _SocialProofLine(handle: handle),
                      const _DottedRule(),
                    ],
                  ),
                ),
              ],
              body: Column(
                children: [
                  TabBar(
                    labelColor: AppColors.sokoInk,
                    unselectedLabelColor: AppColors.sokoInk,
                    indicatorColor: AppColors.sokoPink,
                    indicatorWeight: 3,
                    dividerColor: pInk8,
                    labelStyle: Pt.b2.copyWith(fontSize: 15),
                    unselectedLabelStyle: Pt.b2.copyWith(fontSize: 15),
                    tabs: tabs,
                  ),
                  Expanded(child: TabBarView(children: views)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TopBar extends ConsumerWidget {
  final String handle;
  final PublicProfile profile;
  const _TopBar({required this.handle, required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Memory is admin-only — the brain icon (→ Memory screen) shows only for
    // an admin viewer, even though the rest of the profile is open to all.
    final isAdmin = ref.watch(currentUserProvider)?.role == UserRole.admin;
    // Preview renders the visitor chrome — back + share — not your own hub
    // actions, which is the point of previewing.
    final isSelf = profile.isSelf && !_VisitorPreview.of(context);
    // In sandbox (onboarding) the back button pops the root-pushed route back
    // to onboarding — popOrFallback uses GoRouter and would dump into Discovery.
    final sandbox = _ProfileSandbox.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        children: [
          SokoBackButton(
            variant: SokoBackButtonVariant.shaded,
            onTap: sandbox
                ? () => Navigator.of(context).maybePop()
                : () => popOrFallback(context),
          ),
          if (isSelf) ...[
            const SizedBox(width: _headerActionGap),
            _HeaderAction(
              icon: LucideIcons.user_plus,
              tooltip: Lt.of(context).profileFindPeople,
              onTap: () => context.push(AppRoutes.findPeople),
            ),
          ],
          const Spacer(),
          if (isSelf) ...[
            if (isAdmin) ...[
              _HeaderAction(
                glyph: const SokoBrainIcon(size: 16),
                tooltip: Lt.of(context).profileMemoriesTitle,
                onTap: () => context.push(AppRoutes.memory),
              ),
              const SizedBox(width: _headerActionGap),
            ],
            const NotificationsTopButton(),
            const SizedBox(width: _headerActionGap),
            _HeaderAction(
              icon: LucideIcons.settings,
              tooltip: Lt.of(context).discoveryNavMenu,
              onTap: () => context.go(AppRoutes.menu),
            ),
          ] else if (!sandbox)
            // Visiting someone else's profile — share their profile LINK to
            // another app. No persona card / stories (those are always the
            // viewer's own persona, so they make no sense for a visited
            // profile). Hidden in sandbox (no leaving onboarding via a share).
            _HeaderAction(
              icon: LucideIcons.share,
              tooltip: Lt.of(context).profileShareProfileTooltip,
              onTap: () => showSokoShareSheet(
                context: context,
                ref: ref,
                shareContext: 'profile',
                entityId: profile.handle ?? handle,
                shareUrl: _profileShareUrl(profile.handle ?? handle),
                showPersonaCard: false,
              ),
            ),
        ],
      ),
    );
  }
}

/// Identity block — portrait avatar left, name + @handle · city · "near you",
/// bio below. Matches Figma Frame 9533/9534.
class _ProfileHeader extends ConsumerWidget {
  final String handle;
  final PublicProfile profile;
  const _ProfileHeader({required this.handle, required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final handleStr = profile.handle ?? handle;
    final hasName = profile.fullName != null && profile.fullName!.isNotEmpty;
    final displayName = hasName ? profile.fullName! : handleStr;

    // Only your own profile offers "add a photo", and preview-as-visitor is
    // meant to hide exactly that chrome — so it takes the visitor path too.
    // `isNeighbor` below deliberately keeps the raw `profile.isSelf`: it
    // describes who the person IS, not which actions you get.
    final canEditProfile = profile.isSelf && !_VisitorPreview.of(context);

    final myCity = ref.watch(currentUserProvider)?.city;
    final isNeighbor =
        !profile.isSelf &&
        profile.city != null &&
        profile.city!.isNotEmpty &&
        myCity != null &&
        myCity.isNotEmpty &&
        profile.city!.toLowerCase() == myCity.toLowerCase();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: (profile.avatarUrl != null && profile.avatarUrl!.isNotEmpty)
                // With a photo: tap enlarges it (unchanged).
                ? () => _showAvatarViewer(
                    context,
                    profile.avatarUrl!,
                    displayName,
                    official: profile.isOfficial,
                  )
                // No photo (initial placeholder): on your own profile, tapping
                // the letter jumps to Edit profile to add one. On others' it
                // does nothing.
                : (canEditProfile
                      ? () => context.push(AppRoutes.editProfile)
                      : null),
            child: _Avatar(
              url: profile.avatarUrl,
              name: displayName,
              official: profile.isOfficial,
              seed: profile.userId,
            ),
          ),
          const SizedBox(width: 20),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(displayName, style: Pt.name),
                if (profile.isExpert) ...[
                  const SizedBox(height: 8),
                  const ExpertBadge(),
                ],
                const SizedBox(height: 10),
                // "@handle · City · Near you" — dot-separated present parts.
                Wrap(
                  spacing: 6,
                  runSpacing: 2,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (hasName)
                      Text('@$handleStr', style: Pt.b2.copyWith(color: pInk50)),
                    if (hasName &&
                        (profile.city != null && profile.city!.isNotEmpty))
                      _Dot(),
                    if (profile.city != null && profile.city!.isNotEmpty)
                      Text(profile.city!, style: Pt.b2.copyWith(color: pInk50)),
                    if (isNeighbor) _Dot(),
                    if (isNeighbor)
                      Text(
                        l10n.profileNeighbor,
                        style: Pt.b2.copyWith(color: pInk50),
                      ),
                  ],
                ),
                if (profile.isPrivate && !profile.isSelf) ...[
                  const SizedBox(height: 8),
                  const _PrivatePill(),
                ],
                // The official Soko account (brand/editorial, not a person)
                // shows no free-text bio.
                if (_bioText(profile.bio) case final bio?
                    when !profile.isOfficial) ...[
                  const SizedBox(height: 10),
                  Text(bio, style: Pt.b2),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Dot extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
      Text('•', style: Pt.b2.copyWith(color: pInk30));
}

class _PrivatePill extends StatelessWidget {
  const _PrivatePill();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: pInk8,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.lock, size: 12, color: pInk50),
          const SizedBox(width: 5),
          Text(
            Lt.of(context).profilePrivateTitle,
            style: Pt.b2.copyWith(color: pInk50),
          ),
        ],
      ),
    );
  }
}

/// Portrait avatar — 100×125, radius 6 (Figma Frame 9322), with the paper
/// texture overlay. Photo when set, else a Season Mix initial on a tinted card.
class _Avatar extends StatelessWidget {
  final String? url;
  final String? name;

  /// Official Soko profile: show the whole illustration ([BoxFit.contain])
  /// instead of the default cover-crop, so nothing gets clipped.
  final bool official;

  /// Per-person placeholder seed (the profile's user id).
  final String? seed;
  const _Avatar({this.url, this.name, this.official = false, this.seed});

  @override
  Widget build(BuildContext context) {
    return TexturedAvatar(
      url: url,
      name: name,
      colorSeed: seed,
      width: 100,
      height: 100,
      fit: official ? BoxFit.contain : BoxFit.cover,
      // The Soko mark fills 83% of its own file. Contained in a CIRCLE that put
      // it right against the rim, so it used to be inset by 14%; the rounded
      // square leaves ~8% of clear box on each side by itself, and the extra
      // inset now just shrinks the mark for no reason.
      // White letterbox behind the contained illustration (its own background
      // is white), so the fit gaps read as one clean card, not ghost margins.
      // Non-official profiles derive their tint from the seed.
      placeholderColor: official ? Colors.white : null,
    );
  }
}

/// Inline dot-separated stats: "134 Followers · 87 Following · 48 Saved · 7
/// Zines". Followers / Following open the respective lists.
class _StatsRow extends ConsumerWidget {
  final String handle;
  final PublicProfile profile;
  const _StatsRow({required this.handle, required this.profile});

  void _openList(BuildContext context, {required bool followers}) {
    context.push(
      AppRoutes.followListPath(handle, followers ? 'followers' : 'following'),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    // Official Soko profile: only Saved · Zines, centred on the line. Its
    // follower / following counts aren't a person-to-person signal (everyone
    // follows Soko and Soko follows everyone), so they're dropped here.
    if (profile.isOfficial) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: Wrap(
          spacing: 8,
          runSpacing: 6,
          alignment: WrapAlignment.center,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            _InlineStat(
              value: profile.savedCount,
              label: l10n.profileStatSaved,
            ),
            _Dot(),
            _InlineStat(
              value: profile.zinesCount,
              label: l10n.profileStatZines,
            ),
          ],
        ),
      );
    }
    // Follower / following lists open only on a mutual follow (or your own).
    // Followers/following lists: public → anyone; private → accepted followers
    // (same person-surface gating the backend enforces). Not mutual-only.
    // Sandbox (onboarding) disables the lists — they'd escape onboarding.
    final canOpenLists =
        (profile.isSelf || profile.canViewPrivateSections) &&
        !_ProfileSandbox.of(context);
    // On my own profile the following count is server value + optimistic delta,
    // so it drops/rises the instant I follow/unfollow anywhere (Locals, lists,
    // a profile, contacts…). Others' counts are unaffected by my taps.
    final int followingDelta = profile.isSelf
        ? ref.watch(myFollowingCountDeltaProvider)
        : 0;
    final int followerDelta = profile.isSelf
        ? ref.watch(myFollowerCountDeltaProvider)
        : 0;
    final followingRaw = profile.followingCount + followingDelta;
    final followingCount = followingRaw < 0 ? 0 : followingRaw;
    final followersRaw = profile.followersCount + followerDelta;
    final followersCount = followersRaw < 0 ? 0 : followersRaw;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _InlineStat(
            value: followersCount,
            label: l10n.profileStatFollowers,
            onTap: canOpenLists
                ? () => _openList(context, followers: true)
                : null,
          ),
          _Dot(),
          _InlineStat(
            value: followingCount,
            label: l10n.profileStatFollowing,
            onTap: canOpenLists
                ? () => _openList(context, followers: false)
                : null,
          ),
          _Dot(),
          _InlineStat(value: profile.savedCount, label: l10n.profileStatSaved),
          _Dot(),
          _InlineStat(value: profile.zinesCount, label: l10n.profileStatZines),
        ],
      ),
    );
  }
}

class _InlineStat extends StatelessWidget {
  final int value;
  final String label;
  final VoidCallback? onTap;
  const _InlineStat({required this.value, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final text = Text.rich(
      TextSpan(
        children: [
          TextSpan(text: '$value ', style: Pt.b2.copyWith(fontSize: 16)),
          TextSpan(
            text: label,
            style: Pt.b2.copyWith(color: pInk50, fontSize: 16),
          ),
        ],
      ),
    );
    if (onTap == null) return text;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: text,
    );
  }
}

/// Social-link banners — Instagram / TikTok / website under the action
/// buttons, dot-separated like the stats row (Figma Frame 9534/9535). Only the
/// links the owner set are shown; the whole row collapses when there are none.
/// Each opens externally (new tab on web).
class _SocialLinksRow extends StatelessWidget {
  final PublicProfile profile;
  const _SocialLinksRow({required this.profile});

  static Future<void> _open(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Website as displayed: scheme + trailing slash stripped ("joaoalbino.com").
  static String _bareWebsite(String url) => url
      .replaceFirst(RegExp(r'^https?://', caseSensitive: false), '')
      .replaceFirst(RegExp(r'/+$'), '');

  /// Website as launched: the stored URL, with https:// prepended when the
  /// owner typed it bare.
  static String _websiteLaunchUrl(String url) =>
      RegExp(r'^https?://', caseSensitive: false).hasMatch(url)
      ? url
      : 'https://$url';

  @override
  Widget build(BuildContext context) {
    final ig = profile.instagramHandle;
    final tk = profile.tiktokHandle;
    final web = profile.websiteUrl;

    final links = <Widget>[
      if (ig != null && ig.isNotEmpty)
        _SocialLink(
          icon: Icon(LucideIcons.instagram, size: 15, color: pInk50),
          label: '@$ig',
          onTap: () => _open('https://instagram.com/$ig'),
        ),
      if (tk != null && tk.isNotEmpty)
        _SocialLink(
          icon: SvgPicture.asset(
            'assets/images/tiktok.svg',
            width: 14,
            height: 14,
            colorFilter: ColorFilter.mode(pInk50, BlendMode.srcIn),
          ),
          label: '@$tk',
          onTap: () => _open('https://www.tiktok.com/@$tk'),
        ),
      if (web != null && web.isNotEmpty)
        _SocialLink(
          icon: Icon(LucideIcons.globe, size: 15, color: pInk50),
          label: _bareWebsite(web),
          onTap: () => _open(_websiteLaunchUrl(web)),
        ),
    ];
    if (links.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Wrap(
        spacing: 8,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          for (var i = 0; i < links.length; i++) ...[
            if (i > 0) _Dot(),
            links[i],
          ],
        ],
      ),
    );
  }
}

class _SocialLink extends StatelessWidget {
  final Widget icon;
  final String label;
  final VoidCallback onTap;
  const _SocialLink({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Clickable(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          icon,
          const SizedBox(width: 5),
          Text(label, style: Pt.b2.copyWith(color: pInk50)),
        ],
      ),
    );
  }
}

/// Self: Edit profile (outlined) + Share (pink). Public: Follow.
class _ActionButtons extends ConsumerWidget {
  final String handle;
  final PublicProfile profile;
  const _ActionButtons({required this.handle, required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!profile.isSelf) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
        child: FollowButton(
          handle: handle,
          userId: profile.userId,
          relationship: profile.viewerRelationship,
          followsYou: profile.followsYou,
          targetIsSoko: profile.isOfficial,
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      child: Row(
        children: [
          Expanded(
            child: _SqButton(
              icon: LucideIcons.square_pen,
              label: Lt.of(context).profileEditButton,
              filled: false,
              onTap: () => context.push(AppRoutes.editProfile),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: _SqButton(
              icon: LucideIcons.share,
              label: Lt.of(context).profileShareButton,
              filled: true,
              // Same as "Invite friends" in Find people: system share of the
              // canonical profile link with the invite message.
              onTap: () {
                ref
                    .read(unifiedAnalyticsProvider)
                    .trackInviteShared(source: 'profile_share');
                shareItem(
                  context: context,
                  ref: ref,
                  title: Lt.of(context).inviteShareMessageTitle,
                  url: _profileShareUrl(profile.handle ?? handle),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// Bt_Sq_Ico — 40-tall, radius-6, icon + Zalando-14 label. Pink fill or
/// ink-8 outline.
class _SqButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool filled;
  final VoidCallback onTap;
  const _SqButton({
    required this.icon,
    required this.label,
    required this.filled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 40,
        decoration: BoxDecoration(
          color: filled ? AppColors.sokoPink : Colors.transparent,
          border: filled ? null : Border.all(color: pInk8),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: AppColors.sokoInk),
            const SizedBox(width: 8),
            Text(label, style: Pt.b2),
          ],
        ),
      ),
    );
  }
}

/// Viewer-relative social proof under the Follow button: the mutual followers'
/// mini photos (in order) + "Followed by {names} and others", tappable to the
/// full list. Bio-toned text (per request — same as the user's description).
class _SocialProofLine extends ConsumerWidget {
  final String handle;
  const _SocialProofLine({required this.handle});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final proof = ref.watch(profileSocialProofProvider(handle)).valueOrNull;
    if (proof == null || proof.mutualFollowers.isEmpty) {
      return const SizedBox.shrink();
    }
    final mutuals = proof.mutualFollowers;
    final total = proof.mutualFollowersCount > 0
        ? proof.mutualFollowersCount
        : mutuals.length;
    // Up to 3 names, in the same order as their photos (first photo = first
    // name). "… and others" when there are more than shown.
    final names = mutuals
        .take(3)
        .map((u) => u.fullName ?? '@${u.handle ?? ''}')
        .join(', ');
    final text = total > mutuals.take(3).length
        ? l10n.profileFollowedByNamesMore(names)
        : l10n.profileFollowedByNames(names);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Sandbox (onboarding): the mutual-followers list is an escape hatch.
        onTap: _ProfileSandbox.of(context)
            ? null
            : () => context.push(AppRoutes.followListPath(handle, 'mutual')),
        child: MutualAvatarsRow(
          avatars: [for (final u in mutuals) u.avatarUrl ?? ''],
          totalCount: total,
          text: text,
          // Same tone as the user's bio/description (per request).
          textStyle: Pt.b2,
        ),
      ),
    );
  }
}

/// Accept/Reject bar shown at the top of a profile when that person has a
/// pending request to follow YOU.
class _IncomingRequestBanner extends ConsumerStatefulWidget {
  final String userId;
  final String name;
  const _IncomingRequestBanner({required this.userId, required this.name});

  @override
  ConsumerState<_IncomingRequestBanner> createState() =>
      _IncomingRequestBannerState();
}

class _IncomingRequestBannerState
    extends ConsumerState<_IncomingRequestBanner> {
  bool _busy = false;

  Future<void> _act({required bool accept}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final api = ref.read(followsApiProvider);
      if (accept) {
        await api.acceptRequest(widget.userId);
      } else {
        await api.rejectRequest(widget.userId);
      }
      invalidateMyFollowerCounts(ref);
      ref.read(pendingRequestCountProvider.notifier).decrement();
      ref.invalidate(followRequestsProvider);
      // Same action as the requests screen, different surface — the `source`
      // split is what tells us whether the inline banner is worth keeping.
      ref
          .read(unifiedAnalyticsProvider)
          .trackFollowRequestAction(
            action: accept ? 'accept' : 'reject',
            source: 'profile_banner',
          );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(Lt.of(context).commonSomethingWrong)),
        );
        setState(() => _busy = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 10, 10, 10),
        decoration: BoxDecoration(
          color: pInk8,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                Lt.of(context).profileFollowRequestedYou(widget.name),
                style: Pt.b2,
              ),
            ),
            const SizedBox(width: 8),
            if (_busy)
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else ...[
              _MiniPill(
                label: Lt.of(context).commonAccept,
                filled: true,
                onTap: () => _act(accept: true),
              ),
              const SizedBox(width: 6),
              _MiniPill(
                label: Lt.of(context).commonReject,
                filled: false,
                onTap: () => _act(accept: false),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _MiniPill extends StatelessWidget {
  final String label;
  final bool filled;
  final VoidCallback onTap;
  const _MiniPill({
    required this.label,
    required this.filled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: filled ? AppColors.sokoPink : Colors.transparent,
          border: filled ? null : Border.all(color: pInk8),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(label, style: Pt.b2),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Private states — Soko "seating and reading" illustration
// ---------------------------------------------------------------------------

class _PrivateIllustration extends StatelessWidget {
  final double height;
  const _PrivateIllustration({this.height = 130});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/images/illustrations/soko-reading.png',
      height: height,
      fit: BoxFit.contain,
    );
  }
}

/// Empty-state block — the Soko reading illustration + a short message. Used for
/// every "nothing here yet" surface (own profile and profiles you visit).
class _EmptyState extends StatelessWidget {
  final String text;
  const _EmptyState(this.text);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _PrivateIllustration(height: 96),
            const SizedBox(height: 14),
            Text(
              text,
              textAlign: TextAlign.center,
              style: Pt.b2.copyWith(color: pInk50),
            ),
          ],
        ),
      ),
    );
  }
}

/// Whole-profile private block (private account, non-follower).
class _PrivateProfileBlock extends StatelessWidget {
  final String name;
  const _PrivateProfileBlock({required this.name});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 8),
      child: Column(
        children: [
          const _PrivateIllustration(),
          const SizedBox(height: 18),
          Text(
            l10n.profilePrivateProfileTitle,
            textAlign: TextAlign.center,
            style: Pt.display,
          ),
          const SizedBox(height: 12),
          Text(
            l10n.profilePrivateProfileBody(name),
            textAlign: TextAlign.center,
            style: Pt.b2.copyWith(color: pInk50, height: 1.4),
          ),
        ],
      ),
    );
  }
}

/// Per-section private lock (a section the owner keeps private).
class _PrivateSectionCard extends StatelessWidget {
  final String name;
  const _PrivateSectionCard({required this.name});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 30, 24, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _PrivateIllustration(),
            const SizedBox(height: 18),
            Text(
              l10n.profilePrivateSectionTitle,
              textAlign: TextAlign.center,
              style: Pt.display,
            ),
            const SizedBox(height: 10),
            Text(
              l10n.profilePrivateSectionBody(name),
              textAlign: TextAlign.center,
              style: Pt.b2.copyWith(color: pInk50, height: 1.4),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Zines tab
// ---------------------------------------------------------------------------

class _ZinesTab extends ConsumerWidget {
  final String handle;
  final bool isSelf;
  const _ZinesTab({required this.handle, required this.isSelf});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // A single grid of ALL the owner's zines — no public/private sub-tab. Each
    // card already carries a visibility badge (🌐 public · 👥 followers · 🔒
    // private) in its top-left corner, so the state reads at a glance. Visitors
    // only ever receive the viewer-visible subset from the backend, so the
    // grid is correct for self and others alike.
    final async = ref.watch(profileZinesProvider(handle));
    // On your own profile a "Cria nova zine" row heads the grid — scrolling
    // with it, not pinned above it, so a long grid isn't permanently short a
    // row of chrome.
    return _ZineGrid(
      async: async,
      handle: handle,
      header: isSelf ? _CreateZineEntry(handle: handle) : null,
    );
  }
}

/// Top-of-Zines shortcut into the create-zine flow — the exact CTA the
/// library's action bar carries (yellow [BtSqIco] → `discoveryListCreate`),
/// right-aligned above your grid. Refetches the grid on return so a zine
/// created here lands without a manual refresh.
class _CreateZineEntry extends ConsumerWidget {
  final String handle;
  const _CreateZineEntry({required this.handle});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Align(
        alignment: Alignment.centerRight,
        child: BtSqIco(
          icon: LucideIcons.circle_plus,
          label: Lt.of(context).discoveryActionBarCreateZine,
          variant: BtSqIcoVariant.yellow,
          onTap: () async {
            await context.push(AppRoutes.discoveryListCreate);
            ref.invalidate(profileZinesProvider(handle));
          },
        ),
      ),
    );
  }
}

/// Horizontal padding around the zine grid, and the gap between its two
/// columns — named because [_zineCellAspectRatio] has to back them out of the
/// incoming width to know how wide one card actually is.
const double _kZineGridPadding = 16;
const double _kZineGridCrossGap = 10;

/// Height of one zine cell, expressed as the aspect ratio the grid delegate
/// wants, for a card [column] px wide.
///
/// The cell is exactly the cover (Figma's 195×242) plus the caption block, and
/// the caption block is measured against the CURRENT text scale rather than
/// assumed at the app's 1.3× ceiling (`app.dart`). A fixed ratio has to reserve
/// for that ceiling always, which leaves ~13 px of dead space under every card
/// for the majority of users who never scale their text — and dead space in a
/// uniform grid reads as a too-big gap between rows.
///
/// The block reserves BOTH caption lines (readers + pages) even though a zine
/// with no followers only draws one: every cell in a grid is the same height,
/// so it has to fit the tallest card — a zine WITH followers has to show both
/// lines in full. That reserved-but-unused line is the one remaining source of
/// slack, and removing it would mean letting the cover flex — which makes
/// covers different heights within a row.
double _zineCellAspectRatio(BuildContext context, double column) {
  // Pt.b2 — 14 px at height 1.2. Rounded UP because that is what the text
  // engine paints: a 16.8 px line box measures 17.0 on screen, so computing
  // with the raw product under-reserves by 0.2 px a line. The 9 and 2 are the
  // fixed gaps in _ZineCard.
  final line = (MediaQuery.textScalerOf(context).scale(14) * 1.2)
      .ceilToDouble();
  final caption = 9 + line + 2 + line + _kZineCaptionSafety;
  final cover = column * 242 / 195;
  return column / (cover + caption);
}

/// Breathing room on top of the measured caption height.
///
/// Without it the cell is sized to the caption EXACTLY, and a card that draws
/// both lines has nothing left to absorb sub-pixel differences — the painted
/// line box can land a fraction above `fontSize × height`, and the grid rounds
/// the cell height off the aspect ratio. Either is enough to clip the second
/// line and paint the overflow stripe. 4 px is invisible between rows and puts
/// the two-line card comfortably inside its cell.
const double _kZineCaptionSafety = 4;

class _ZineGrid extends StatelessWidget {
  final AsyncValue<UserListsResponse> async;
  final String handle;

  /// Optional row rendered above the grid, inside the same scrollable so it
  /// scrolls away with the cards instead of pinning to the top of the tab.
  final Widget? header;

  const _ZineGrid({required this.async, required this.handle, this.header});

  @override
  Widget build(BuildContext context) {
    return async.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, _) => _TabMessage(Lt.of(context).profileZinesLoadError),
      data: (res) {
        final items = res.items;
        return LayoutBuilder(
          builder: (context, constraints) {
            final column =
                (constraints.maxWidth -
                    _kZineGridPadding * 2 -
                    _kZineGridCrossGap) /
                2;
            return CustomScrollView(
              slivers: [
                if (header != null) SliverToBoxAdapter(child: header!),
                if (items.isEmpty)
                  // Still scrollable, so the header row above stays reachable.
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: _EmptyState(Lt.of(context).profileNoZines),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(
                      _kZineGridPadding,
                      16,
                      _kZineGridPadding,
                      24,
                    ),
                    sliver: SliverGrid.builder(
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        mainAxisSpacing: 14,
                        crossAxisSpacing: _kZineGridCrossGap,
                        childAspectRatio: _zineCellAspectRatio(context, column),
                      ),
                      itemCount: items.length,
                      itemBuilder: (_, i) =>
                          _ZineCard(list: items[i], handle: handle),
                    ),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

class _ZineCard extends ConsumerWidget {
  final UserList list;
  final String handle;
  const _ZineCard({required this.list, required this.handle});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final sandbox = _ProfileSandbox.of(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () async {
        // Sandbox (onboarding): open the zine in the read-only sandbox reader
        // on the root navigator (back-only) instead of routing to /lists/:id,
        // which would leave onboarding.
        if (sandbox) {
          await Navigator.of(context, rootNavigator: true).push(
            MaterialPageRoute<void>(
              builder: (_) => SandboxZinePage(listId: list.id),
            ),
          );
          return;
        }
        await context.push('/lists/${list.id}');
        // The cover / details may have changed in the zine editor — refetch so
        // the profile grid reflects it immediately (as the library does). Also
        // refresh the Saved-tab "Zines" segment in case a follow was toggled.
        ref.invalidate(profileZinesProvider(handle));
        ref.invalidate(profileSavedZinesProvider(handle));
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 195 / 242,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // The real zine cover — title + logo rendered ON the cover
                  // (as everywhere else in the app), gated by the zine's own
                  // recipe, instead of a blank cover with the title below.
                  ListZineCover(
                    recipe: ZineCoverRecipe.fromUserList(list),
                    title: list.name,
                    showTitle: true,
                    showLogo: true,
                  ),
                  // Visibility badge — 🌐 public · 👥 followers · 🔒 private.
                  Positioned(
                    top: 8,
                    left: 8,
                    child: _VisBadge(list.visibility),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 9),
          // A zine nobody follows yet shows no "0 followers" line — the count
          // only appears once it says something.
          // Both lines are single-line by contract: the cell reserves exactly
          // two lines' worth of height, so a wrap (a long translation at 1.3 ×
          // scaling) would overflow the card rather than push the grid.
          if (list.followerCount > 0) ...[
            Text(
              l10n.profileZineReaders(list.followerCount),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Pt.b2,
            ),
            const SizedBox(height: 2),
          ],
          Text(
            l10n.profileZinePages(list.itemCount),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Pt.b2.copyWith(color: pInk30),
          ),
        ],
      ),
    );
  }
}

/// Small visibility symbol overlaid on a zine cover (🌐 public · 🔒 private) on
/// a translucent paper chip. The legacy `followers`-only tier was retired — any
/// leftover `followers` zine is shown as public.
class _VisBadge extends StatelessWidget {
  final ListVisibility visibility;
  const _VisBadge(this.visibility);

  @override
  Widget build(BuildContext context) {
    final vis = visibility == ListVisibility.followers
        ? ListVisibility.public
        : visibility;
    return Container(
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        color: AppColors.sokoPaper.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(visibilityIcon(vis), size: 13, color: AppColors.sokoInk),
    );
  }
}

// ---------------------------------------------------------------------------
// Editor Picks tab (official Soko profile only)
// ---------------------------------------------------------------------------

/// The official Soko profile's "Editor picks" tab — the Discovery Editor Picks
/// shelf surfaced on the profile: public lists flagged `editor_pick=true` by
/// Soko admins. Rendered with the same zine-cover grid as the Zines tab.
class _EditorPicksTab extends ConsumerWidget {
  final String handle;
  const _EditorPicksTab({required this.handle});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(sokoEditorPicksProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // "Editor picks" lettering above the grid — same display type + size
        // as the Discovery "Editor picks" shelf title (DiscoveryShelf).
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text(
            Lt.of(context).discoveryShelfEditorPicksTitle,
            style: AppTheme.displayPrimary(
              fontSize: 42,
              fontWeight: FontWeight.w300,
              color: AppColors.sokoInk,
              height: 0.94,
            ),
          ),
        ),
        Expanded(
          child: _ZineGrid(async: async, handle: handle),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Saved tab
// ---------------------------------------------------------------------------

class _SavedTab extends ConsumerStatefulWidget {
  final String handle;
  final PublicProfile profile;
  final bool hiddenFromOthers;
  const _SavedTab({
    required this.handle,
    required this.profile,
    this.hiddenFromOthers = false,
  });

  @override
  ConsumerState<_SavedTab> createState() => _SavedTabState();
}

class _SavedTabState extends ConsumerState<_SavedTab> {
  // Category tabs (SearchCategoryTabs), each pill painting its category colour
  // when selected (yellow / green / blue) with its Lucide icon. On the profile
  // Saved surface Zines lead and are the default selection (a profile is
  // zine-first), unlike Discovery which defaults to Events/Places.
  static const _savedOrder = [
    DiscoverySearchCategory.zines,
    DiscoverySearchCategory.eventos,
    DiscoverySearchCategory.sitios,
  ];
  DiscoverySearchCategory _cat = DiscoverySearchCategory.zines;

  @override
  Widget build(BuildContext context) {
    final profile = widget.profile;

    if (!profile.isSelf && !profile.showSaved) {
      return _PrivateSectionCard(name: _shortName(profile, widget.handle));
    }
    if (!profile.canViewPrivateSections) {
      return _LockedMessage(Lt.of(context).profileSavedPrivate);
    }

    // Watched here, not down in `_buildSavedItems`, so the subscription spans
    // the whole tab: the provider is autoDispose, and watching it only from the
    // Events/Places branch would drop and refetch it on every hop through the
    // Zines segment.
    //
    // Liked items are a second request, so they land after the saved list. The
    // list must wait for them to SETTLE — not to succeed — before painting:
    // rendering the saves first and merging the likes in on arrival made rows
    // appear and the list jump a beat later, which reads as a glitch.
    //
    // Settled, not successful, is the whole point: an error still releases the
    // paint (merging as empty), so a failing likes request delays the saved
    // list by its own duration and never blocks it outright.
    final AsyncValue<SavedListResponse?> likedAsync = _showLikes
        ? ref.watch(myLikedItemsProvider)
        : const AsyncData<SavedListResponse?>(null);
    final likesSettled = likedAsync.hasValue || likedAsync.hasError;
    final liked = likedAsync.valueOrNull?.items ?? const <SavedItem>[];

    final Widget body = _cat == DiscoverySearchCategory.zines
        ? _SavedZinesList(handle: widget.handle)
        : _buildSavedItems(liked, likesSettled: likesSettled);

    return _withPrivacyNotice(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: SearchCategoryTabs(
              selected: _cat,
              onSelect: (c) => setState(() => _cat = c),
              fillWidth: true,
              categoryOrder: _savedOrder,
            ),
          ),
          Expanded(child: body),
        ],
      ),
      widget.hiddenFromOthers,
    );
  }

  /// Whether the liked items are merged in. Owner only — a like is not public,
  /// so a visitor's view stays byte-identical to what it was before PROD-3779.
  bool get _showLikes => widget.profile.isSelf;

  Widget _buildSavedItems(List<SavedItem> liked, {required bool likesSettled}) {
    final async = ref.watch(profileSavedProvider(widget.handle));

    if (!likesSettled) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    return async.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, _) => _LockedMessage(Lt.of(context).profileSavedPrivate),
      data: (res) {
        final rows = mergeSavedAndLiked(
          saved: res.items,
          liked: liked,
          wantEvent: _cat == DiscoverySearchCategory.eventos,
          showLikes: _showLikes,
        );
        if (rows.isEmpty) {
          return _EmptyState(
            _showLikes
                ? Lt.of(context).profileNothingSavedOrLiked
                : Lt.of(context).profileNothingSaved,
          );
        }
        return ListView.separated(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
          itemCount: rows.length,
          separatorBuilder: (_, __) => const SizedBox(height: 10),
          itemBuilder: (_, i) => _SaveRowCard(
            item: rows[i].item,
            saved: rows[i].saved,
            liked: rows[i].liked,
          ),
        );
      },
    );
  }
}

/// The "Zines" segment of the Saved tab — the public zines this user follows.
class _SavedZinesList extends ConsumerWidget {
  final String handle;
  const _SavedZinesList({required this.handle});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(profileSavedZinesProvider(handle));
    return async.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, _) => _LockedMessage(Lt.of(context).profileSavedPrivate),
      data: (res) {
        if (res.items.isEmpty) {
          return _EmptyState(Lt.of(context).profileNoSavedZines);
        }
        // Same metrics as the Zines grid, so the two read alike.
        return LayoutBuilder(
          builder: (context, constraints) {
            final column =
                (constraints.maxWidth -
                    _kZineGridPadding * 2 -
                    _kZineGridCrossGap) /
                2;
            return GridView.builder(
              padding: const EdgeInsets.fromLTRB(
                _kZineGridPadding,
                16,
                _kZineGridPadding,
                24,
              ),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                mainAxisSpacing: 14,
                crossAxisSpacing: _kZineGridCrossGap,
                childAspectRatio: _zineCellAspectRatio(context, column),
              ),
              itemCount: res.items.length,
              itemBuilder: (_, i) =>
                  _ZineCard(list: res.items[i], handle: handle),
            );
          },
        );
      },
    );
  }
}

Widget _withPrivacyNotice(Widget body, bool hidden, {bool editable = true}) {
  if (!hidden) return body;
  return Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _PrivacyNotice(editable: editable),
      Expanded(child: body),
    ],
  );
}

class _SaveRowCard extends StatelessWidget {
  final SavedItem item;

  /// Why this row is in the list. Both can be true — saving ("I want to go")
  /// and liking ("I liked it") are independent axes, so the row shows both
  /// markers rather than picking one and hiding the other fact.
  final bool saved;
  final bool liked;

  const _SaveRowCard({
    required this.item,
    this.saved = false,
    this.liked = false,
  });

  void _openDetail(BuildContext context) {
    if (item.eventId != null) {
      context.push('/events/${item.eventId}');
    } else if (item.venueId != null) {
      context.push('/venues/${item.venueId}');
    }
  }

  @override
  Widget build(BuildContext context) {
    final isEvent = item.eventId != null;
    final title = item.title ?? item.venueName ?? 'Saved item';
    final subtitleParts = <String>[
      if (item.category != null && item.category!.isNotEmpty) item.category!,
      if (item.city != null && item.city!.isNotEmpty) item.city!,
    ];
    final image = item.imageUrl;
    // Fixed order (bookmark, then thumb) so the column scans straight down the
    // list. Same assets the user tapped on the detail page, so they need no
    // legend. Deliberately NOT tappable — the whole row already opens the
    // detail; these are labels, not actions.
    final markers = <Widget>[
      if (saved) _rowMarker('bookmark-fill'),
      if (liked) _rowMarker('thumb-up-fill'),
    ];
    // Sandbox (onboarding): the row stays visible but doesn't open the
    // event/venue detail — that would leave onboarding.
    final sandbox = _ProfileSandbox.of(context);
    return Clickable(
      onTap: sandbox ? null : () => _openDetail(context),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: (image != null && image.isNotEmpty)
                ? CachedImage(imageUrl: image, width: 56, height: 56)
                : Container(
                    width: 56,
                    height: 56,
                    color: isEvent ? AppColors.sokoGreen : AppColors.sokoBlue,
                    child: Icon(
                      isEvent ? LucideIcons.calendar : LucideIcons.map_pin,
                      size: 22,
                      color: AppColors.sokoInk,
                    ),
                  ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Pt.b1,
                ),
                // The markers ride the SUBTITLE line, never the title's. In a
                // trailing slot they would shorten every title by ~40px and
                // ellipsize names sooner on every row (in the merged list every
                // row carries at least one marker). The subtitle has slack to
                // spare and is the right thing to truncate. Costs no height:
                // the row is already 56px tall because of the thumbnail.
                if (subtitleParts.isNotEmpty || markers.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          subtitleParts.join('  ·  '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Pt.b2.copyWith(color: pInk50),
                        ),
                      ),
                      ...markers,
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One saved/liked marker. The assets carry their own colours (pink fill +
/// brown outline), so no `colorFilter` — they must read as the same icon the
/// detail page shows in its selected state.
Widget _rowMarker(String asset) => Padding(
  padding: const EdgeInsets.only(left: 8),
  child: SvgPicture.asset('assets/images/icons/detail/$asset.svg', height: 16),
);

// ---------------------------------------------------------------------------
// Calendar tab (self only)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Connections tab (visited profile) — Followers / Following sub-tabs
// ---------------------------------------------------------------------------

/// The "Connections" tab. Followers / Following are chosen with the same
/// segmented pill toggle the Zines tab uses, each rendering the same person
/// list as the standalone follow-list screen via [FollowListBody]. On your own
/// profile it also carries a third "Locals" sub-tab (the suggested-people list),
/// which a visited profile omits.
class _ConnectionsTab extends StatefulWidget {
  final String handle;
  final bool includeLocals;
  const _ConnectionsTab({required this.handle, this.includeLocals = false});

  @override
  State<_ConnectionsTab> createState() => _ConnectionsTabState();
}

class _ConnectionsTabState extends State<_ConnectionsTab> {
  // Own profile: 0 = Locals, 1 = Followers, 2 = Following (Locals leads and is
  // pre-selected). Visited profile: 0 = Followers, 1 = Following (no Locals).
  int _filter = 0;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final includeLocals = widget.includeLocals;
    final labels = <String>[
      if (includeLocals) l10n.profileTabLocalsV2,
      l10n.profileTabFollowers,
      l10n.profileTabFollowing,
    ];
    // Guard the index in case includeLocals changes across rebuilds.
    final filter = _filter.clamp(0, labels.length - 1);

    // Locals leads (index 0) when present, shifting the follow lists by one.
    final Widget body;
    if (includeLocals && filter == 0) {
      body = const _LocalsTab();
    } else {
      final followersIndex = includeLocals ? 1 : 0;
      final isFollowers = filter == followersIndex;
      final list = FollowListBody(
        handle: widget.handle,
        mode: isFollowers ? FollowListMode.followers : FollowListMode.following,
      );
      // On your OWN Connections (includeLocals), lead each follow list with a
      // line clarifying it's your own list ("People who follow you" / "People
      // you follow"). Visitors just see the list.
      body = includeLocals
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                  child: Text(
                    isFollowers
                        ? l10n.profileConnectionsFollowersHeader
                        : l10n.profileConnectionsFollowingHeader,
                    style: Pt.b2.copyWith(color: pInk50),
                  ),
                ),
                Expanded(child: list),
              ],
            )
          : list;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SegmentedTabs(
          labels: labels,
          // Locals sub-tab carries the person-with-plus glyph (the old Locals
          // top-tab icon); Followers / Following stay label-only.
          icons: includeLocals
              ? const [LucideIcons.user_plus, null, null]
              : null,
          selected: filter,
          selectedColor: AppColors.sokoPurple,
          onChanged: (i) => setState(() => _filter = i),
        ),
        Expanded(child: body),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Locals tab
// ---------------------------------------------------------------------------

class _LocalsTab extends ConsumerStatefulWidget {
  const _LocalsTab();

  @override
  ConsumerState<_LocalsTab> createState() => _LocalsTabState();
}

class _LocalsTabState extends ConsumerState<_LocalsTab> {
  bool _suggestionsTracked = false;

  /// The funnel denominator for the Locals surface. Batched once per view and
  /// carries `source: 'profile_locals_tab'` so it's distinguishable from the
  /// Find People impressions — the taps already arrive as `user_follow` with
  /// `source: 'suggestions'`, this is just how many suggestions were shown.
  void _trackSuggestionsViewed(int count) {
    if (_suggestionsTracked || count == 0) return;
    _suggestionsTracked = true;
    ref
        .read(unifiedAnalyticsProvider)
        .trackSuggestedUsersViewed(
          suggestionCount: count,
          source: 'profile_locals_tab',
        );
  }

  @override
  Widget build(BuildContext context) {
    // Paginated, like Find People — same notifier, so the two surfaces share
    // page 1 and neither re-fetches what the other already loaded.
    final async = ref.watch(suggestedUsersPagedProvider);
    return async.when(
      loading: () =>
          const Center(child: CircularProgressIndicator(strokeWidth: 2)),
      error: (e, _) => _TabMessage(Lt.of(context).profileSuggestionsLoadError),
      data: (state) {
        final dismissed = ref.watch(dismissedSuggestionsProvider);
        final items = state.items
            .where((i) => !dismissed.contains(i.userId))
            .toList();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _trackSuggestionsViewed(items.length);
        });
        final Widget body = items.isEmpty
            ? _EmptyState(Lt.of(context).profileNoSuggestions)
            // One row past the items: the load-more sentinel, which collapses
            // to nothing once the ranked pool is drained.
            : ListView.separated(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                itemCount: items.length + 1,
                separatorBuilder: (_, __) => const SizedBox(height: 16),
                itemBuilder: (_, i) {
                  if (i == items.length) {
                    return SuggestionsLoadMore(
                      state: state,
                      keyId: 'profile-locals',
                    );
                  }
                  final row = _LocalRow(
                    item: items[i],
                    onDismiss: () => ref
                        .read(dismissedSuggestionsProvider.notifier)
                        .dismiss(items[i].userId),
                  );
                  // Start the next page a few rows early, so the request is
                  // already in flight by the time the bottom arrives.
                  return i == items.length - kSuggestionsPrefetchLookahead
                      ? SuggestionsPrefetch(keyId: 'profile-locals', child: row)
                      : row;
                },
              );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _FindPeopleEntry(),
            Expanded(child: body),
          ],
        );
      },
    );
  }
}

/// Top-of-Locals shortcut into Find People — a reinforcement of the top-bar
/// "+" button.
class _FindPeopleEntry extends StatelessWidget {
  const _FindPeopleEntry();

  @override
  Widget build(BuildContext context) {
    return Clickable(
      onTap: () => context.push(AppRoutes.findPeople),
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          // White fill with an ink-8 hairline outline, radius 6.
          color: Colors.white,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: pInk8),
        ),
        child: Row(
          children: [
            // Soko-purple person-plus tile.
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(
                color: AppColors.sokoPurple,
                borderRadius: BorderRadius.circular(8),
              ),
              alignment: Alignment.center,
              child: const Icon(
                LucideIcons.user_plus,
                size: 18,
                color: AppColors.sokoInk,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(Lt.of(context).profileFindPeople, style: Pt.b2),
            ),
            Icon(LucideIcons.chevron_right, size: 18, color: pInk30),
          ],
        ),
      ),
    );
  }
}

class _LocalRow extends StatelessWidget {
  final UserSearchItem item;
  final VoidCallback? onDismiss;
  const _LocalRow({required this.item, this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final name = item.fullName ?? item.handle;
    final handle = item.handle;
    // Subtitle: "{city} · <signal>" — location first, then the best available
    // signal: mutual followers' mini photos ("N em comum"), else shared tastes,
    // else zines created. City / signal each optional; nothing if both absent.
    final city = (item.city != null && item.city!.isNotEmpty)
        ? item.city!
        : null;
    Widget? signal;
    if (item.mutualFollowersCount > 0) {
      signal = MutualAvatarsRow(
        avatars: item.mutualFollowerAvatars,
        totalCount: item.mutualFollowersCount,
        text: l10n.profileMutualFollowersCount(item.mutualFollowersCount),
        textStyle: Pt.b2,
      );
    } else if (item.sharedTastesCount > 0) {
      signal = Text(
        l10n.profileLocalsInCommon(item.sharedTastesCount),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Pt.b2,
      );
    } else if (item.zinesCount > 0) {
      signal = Text(
        l10n.profileLocalsZinesCreated(item.zinesCount),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Pt.b2,
      );
    }
    Widget? subtitle;
    if (city != null || signal != null) {
      subtitle = Row(
        children: [
          if (city != null)
            Text(signal != null ? '$city · ' : city, style: Pt.b2),
          if (signal != null) Flexible(child: signal),
        ],
      );
    }
    return Row(
      children: [
        // Whole left area (avatar + name + subtitle) opens their profile; the
        // follow button keeps its own tap.
        Expanded(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // Sandbox (onboarding): tapping a connection would recurse into
            // another profile and escape onboarding — disable it.
            onTap:
                (handle == null ||
                    handle.isEmpty ||
                    _ProfileSandbox.of(context))
                ? null
                : () => context.push(AppRoutes.publicProfilePath(handle)),
            child: Row(
              children: [
                TexturedAvatar(
                  url: item.avatarUrl,
                  name: name,
                  colorSeed: item.userId,
                  width: 48,
                  height: 48,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name ?? '@${handle ?? ''}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        // Same type + colour as the section title ("A tua
                        // memória") — non-bold, per Figma.
                        style: Pt.b1,
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 3),
                        subtitle,
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
          // The Locals tab is a suggestions surface, same as Find People —
          // same source value so the two read as one funnel in PostHog.
          analyticsSource: 'suggestions',
        ),
        if (onDismiss != null) ...[
          const SizedBox(width: 2),
          _DismissButton(onTap: onDismiss!),
        ],
      ],
    );
  }
}

/// Small "X" to dismiss a suggestion (client-side hide for the session).
class _DismissButton extends StatelessWidget {
  final VoidCallback onTap;
  const _DismissButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Icon(LucideIcons.x, size: 18, color: pInk30),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Shared bits
// ---------------------------------------------------------------------------

/// A pill-segmented control for the in-tab filters — 40-tall, radius-6,
/// pink-fill active / ink-8 outline.
///
/// One call site today: the Connections tab, which builds
/// Locals / Followers / Following (`profileTabLocalsV2`, `profileTabFollowers`,
/// `profileTabFollowing`). The earlier Public/Private/Followed and
/// Places/Events filter sets are gone, and their ARB strings
/// (`profileZineFilter*`, `profileSavedFilter*`) are dead.
class _SegmentedTabs extends StatelessWidget {
  final List<String> labels;
  final int selected;
  final ValueChanged<int> onChanged;

  /// Optional per-segment leading icon (rendered before the label). When
  /// provided it must be the same length as [labels]; a null entry renders
  /// label-only. Used by the Connections tab to put the person-with-plus glyph
  /// on Locals, leaving Followers / Following label-only. (It previously
  /// carried the globe / users / lock visibility glyphs for a Zines-tab filter
  /// that no longer exists.)
  final List<IconData?>? icons;

  /// Fill colour of the selected segment. Defaults to the Zines-tab pink; the
  /// Connections tab passes soko purple to set its Followers/Following toggle
  /// apart from the pink Zines toggle.
  final Color selectedColor;

  const _SegmentedTabs({
    required this.labels,
    required this.selected,
    required this.onChanged,
    this.icons,
    this.selectedColor = AppColors.sokoPink,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++) ...[
            if (i > 0) const SizedBox(width: 6),
            Expanded(
              child: GestureDetector(
                onTap: () => onChanged(i),
                behavior: HitTestBehavior.opaque,
                child: Container(
                  height: 40,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: i == selected ? selectedColor : Colors.transparent,
                    border: i == selected ? null : Border.all(color: pInk8),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (icons != null && icons![i] != null) ...[
                        Icon(icons![i], size: 14, color: AppColors.sokoInk),
                        const SizedBox(width: 6),
                      ],
                      Flexible(
                        child: Text(
                          labels[i],
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Pt.b2,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// Subtle "Only visible to you" banner shown atop a hidden section.
class _PrivacyNotice extends StatelessWidget {
  /// [editable] = the section has a visibility toggle (Saved): the notice is
  /// tappable → Edit profile, with an "Edit" affordance. When false (Activity,
  /// which is self-only with no toggle) it's a plain reassurance — "This is
  /// only visible to you", no tap and no Edit button, since there's nothing to
  /// change.
  final bool editable;
  const _PrivacyNotice({this.editable = true});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final card = Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: pInk8,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.eye_off, size: 13, color: pInk30),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              editable
                  ? l10n.profileOnlyVisibleToYou
                  : l10n.profileActivityOnlyVisibleToYou,
              style: Pt.b2.copyWith(color: pInk50),
            ),
          ),
          if (editable) ...[
            const SizedBox(width: 6),
            Text(
              l10n.profileEditButton,
              style: Pt.b2.copyWith(fontWeight: FontWeight.w500),
            ),
          ],
        ],
      ),
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: editable
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => context.push(AppRoutes.editProfile),
              child: card,
            )
          : card,
    );
  }
}

// ---------------------------------------------------------------------------
// Calendar tab (self only)
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Connections tab (visited profile) — Followers / Following sub-tabs
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Locals tab
// ---------------------------------------------------------------------------

// ---------------------------------------------------------------------------
// Shared bits
// ---------------------------------------------------------------------------

/// Round icon button in the profile header (self-only hub actions).
/// Spacing between the 36 px header buttons — matches the 6 px the action bar
/// puts between its own circle buttons.
const double _headerActionGap = 6;

/// One button in the profile header row: the same 36 px `Soko/Ink @8%` circle
/// with a 16 px glyph that `NotificationsTopButton` and `ChatBarCircleButton`
/// draw, so the header reads as a peer of the icon buttons everywhere else in
/// the app instead of a row of bare glyphs.
class _HeaderAction extends StatelessWidget {
  final IconData? icon;

  /// Draw a custom glyph instead of a Lucide one — the memory action uses the
  /// Figma `Icon/Brain` SVG. Exactly one of [icon] / [glyph] is set.
  final Widget? glyph;
  final String tooltip;
  final VoidCallback onTap;
  const _HeaderAction({
    this.icon,
    this.glyph,
    required this.tooltip,
    required this.onTap,
  }) : assert(
         (icon == null) != (glyph == null),
         'Provide exactly one of `icon` or `glyph`.',
       );

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: CircleIconButton(
        icon: icon,
        glyphBuilder: glyph == null ? null : (_) => glyph!,
        background: AppColors.sokoInk8,
        iconColor: AppColors.sokoInk,
        semanticLabel: tooltip,
        size: 36,
        iconSize: 16,
        onTap: onTap,
      ),
    );
  }
}

class _TabMessage extends StatelessWidget {
  final String text;
  const _TabMessage(this.text);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: Pt.b2.copyWith(color: pInk50),
        ),
      ),
    );
  }
}

class _LockedMessage extends StatelessWidget {
  final String text;
  const _LockedMessage(this.text);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(30),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _PrivateIllustration(),
            const SizedBox(height: 12),
            Text(
              text,
              textAlign: TextAlign.center,
              style: Pt.b2.copyWith(color: pInk50),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileError extends StatelessWidget {
  final String handle;

  /// True only for a genuine 404 (handle doesn't exist). False for transient
  /// failures (timeout / network / 5xx), which get a "try again" copy instead
  /// of the misleading "profile may not exist".
  final bool notFound;
  final VoidCallback onRetry;
  const _ProfileError({
    required this.handle,
    this.notFound = false,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              notFound ? LucideIcons.user_x : LucideIcons.circle_alert,
              size: 40,
              color: pInk30,
            ),
            const SizedBox(height: 12),
            Text(
              notFound
                  ? l10n.profileLoadError(handle)
                  : l10n.profileLoadErrorTransient(handle),
              textAlign: TextAlign.center,
              style: Pt.b2.copyWith(color: pInk50),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: onRetry,
              child: Text(Lt.of(context).commonRetry),
            ),
          ],
        ),
      ),
    );
  }
}

/// Marks the subtree as "render my own profile as a VISITOR would see it".
///
/// Same shape as [_ProfileSandbox], and for the same reason: the self/visitor
/// split is read by leaf widgets (the top bar, the stats, the tabs), so an
/// inherited flag beats threading a bool through every constructor between
/// here and them.
class _VisitorPreview extends InheritedWidget {
  const _VisitorPreview({required this.enabled, required super.child});

  final bool enabled;

  static bool of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_VisitorPreview>()?.enabled ??
      false;

  @override
  bool updateShouldNotify(_VisitorPreview oldWidget) =>
      oldWidget.enabled != enabled;
}

/// PROD-4164 — your own profile, redesigned around Memory.
///
/// Identity block (avatar + name + Editar perfil / Partilhar), a four-column
/// stats row, the location · @handle line, bio and social links; then a dotted
/// rule and the Memória section.
///
/// The design pairs Memória with an Emblemas tab, but badges do not exist yet,
/// so there is nothing to switch between: with a single surface, the tab
/// header is omitted entirely and Memória renders directly under the rule.
/// (When Emblemas ships, reinstate a real TabBar here.)
class _SelfProfileBody extends ConsumerWidget {
  final String handle;
  final PublicProfile profile;
  const _SelfProfileBody({required this.handle, required this.profile});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SelfTopBar(),
        Expanded(
          child: NestedScrollView(
            headerSliverBuilder: (context, _) => [
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _IdentityBlock(handle: handle, profile: profile),
                    _StatsBlock(handle: handle, profile: profile),
                    _MetaLine(handle: handle, profile: profile),
                    const OwnedBusinessesProfileShelf(),
                    _SocialLinksRow(profile: profile),
                    const _DottedRule(),
                  ],
                ),
              ),
            ],
            body: const MemoryTabView(),
          ),
        ),
      ],
    );
  }
}

/// Bell · "Perfil" · settings. No back button — this is a shell tab, not a
/// pushed route.
class _SelfTopBar extends StatelessWidget {
  const _SelfTopBar();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 12, 15, 0),
      child: Row(
        children: [
          const NotificationsTopButton(),
          Expanded(
            child: Text(
              Lt.of(context).profileTitle,
              textAlign: TextAlign.center,
              style: Pt.b1Bold,
            ),
          ),
          _HeaderAction(
            icon: LucideIcons.settings,
            tooltip: Lt.of(context).discoveryNavMenu,
            onTap: () => context.go(AppRoutes.menu),
          ),
        ],
      ),
    );
  }
}

/// Avatar + name, with the caller's action row directly under the name:
/// "Editar perfil · Partilhar" on your own profile, the follow pill on
/// someone else's. Shared so both profiles keep one identity layout.
class _IdentityBlock extends ConsumerWidget {
  final String handle;
  final PublicProfile profile;

  /// Sits under the name. Null renders the self actions.
  final Widget? actions;
  const _IdentityBlock({
    required this.handle,
    required this.profile,
    this.actions,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final handleStr = profile.handle ?? handle;
    final hasName = profile.fullName != null && profile.fullName!.isNotEmpty;
    final displayName = hasName ? profile.fullName! : handleStr;
    // This block renders on BOTH profiles (self, and someone else's with a
    // follow pill), so anything self-only has to be gated. Preview-as-visitor
    // takes the visitor path — hiding your own chrome is the point of it.
    final canEditProfile = profile.isSelf && !_VisitorPreview.of(context);

    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 20, 15, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          GestureDetector(
            onTap: (profile.avatarUrl != null && profile.avatarUrl!.isNotEmpty)
                // With a photo: tap enlarges it.
                ? () => _showAvatarViewer(
                    context,
                    profile.avatarUrl!,
                    displayName,
                  )
                // No photo (initial placeholder): only your own profile jumps
                // to Edit profile to add one. On someone else's it does
                // nothing — this block is shared by both profiles.
                : (canEditProfile
                      ? () => context.push(AppRoutes.editProfile)
                      : null),
            child: _Avatar(
              url: profile.avatarUrl,
              name: displayName,
              seed: profile.userId,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayName,
                  style: Pt.name.copyWith(fontSize: 36, height: 0.95),
                ),
                if (profile.isExpert) ...[
                  const SizedBox(height: 8),
                  const ExpertBadge(),
                ],
                const SizedBox(height: 12),
                if (actions case final a?)
                  a
                else
                  Wrap(
                    spacing: 10,
                    runSpacing: 6,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      _InlineAction(
                        icon: LucideIcons.square_pen,
                        label: l10n.profileEditButton,
                        onTap: () => context.push(AppRoutes.editProfile),
                      ),
                      _Dot(),
                      _InlineAction(
                        icon: LucideIcons.share,
                        label: l10n.profileShareButton,
                        onTap: () {
                          ref
                              .read(unifiedAnalyticsProvider)
                              .trackInviteShared(source: 'profile_share');
                          shareItem(
                            context: context,
                            ref: ref,
                            title: l10n.inviteShareMessageTitle,
                            url: _profileShareUrl(handleStr),
                          );
                        },
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Tells you the profile you are looking at is your own, rendered the way a
/// visitor sees it. Without it the preview is indistinguishable from a bug —
/// your own profile showing a "Seguir" button and none of your tools.
class _PreviewBanner extends StatelessWidget {
  const _PreviewBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(15, 12, 15, 0),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.sokoShade5,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        children: [
          Icon(LucideIcons.eye, size: 15, color: pInk50),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              Lt.of(context).profilePreviewBanner,
              style: Pt.b2.copyWith(color: pInk50),
            ),
          ),
        ],
      ),
    );
  }
}

/// The follow control on someone else's profile, as the mock draws it: a small
/// pink pill sitting under the name ("Segues" / "Seguir"), not a full-width
/// button below the header.
class _FollowPill extends StatelessWidget {
  final String handle;
  final PublicProfile profile;
  const _FollowPill({required this.handle, required this.profile});

  @override
  Widget build(BuildContext context) {
    if (_ProfileSandbox.of(context)) return const SizedBox.shrink();
    // Previewing your own profile still shows the pill — a visitor would see
    // one — but it cannot act: following yourself would 4xx.
    final inert = profile.isSelf;
    return Align(
      alignment: Alignment.centerLeft,
      // IntrinsicWidth is load-bearing. `CompactFollowButton` is a `Container`
      // with `alignment: center`, and such a Container expands to fill LOOSE
      // constraints — which is exactly what `Align` hands it, so the pill
      // stretched the full width of the header instead of hugging its label.
      // In the list rows it was always inside a tight Row, so the behaviour
      // never showed up there.
      child: IgnorePointer(
        ignoring: inert,
        child: IntrinsicWidth(
          child: CompactFollowButton(
            userId: profile.userId,
            initialFollowing: profile.viewerRelationship == 'following',
            requested: profile.viewerRelationship == 'requested',
            followsYou: profile.followsYou,
            analyticsSource: 'profile',
            // Figma: 76x30, radius 6, 14 of side padding. `minWidth` rather than
            // a fixed 76 so "Seguir" and "A Seguir" match while the longer
            // "Seguir também" / "Pedido enviado" states stay unclipped.
            height: 30,
            minWidth: 76,
            horizontalPadding: 14,
            borderRadius: 6,
          ),
        ),
      ),
    );
  }
}

/// An icon + label that behaves as a link, not a button.
class _InlineAction extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _InlineAction({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Clickable(
      onTap: onTap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: AppColors.sokoInk),
          const SizedBox(width: 6),
          Text(label, style: Pt.b2),
        ],
      ),
    );
  }
}

/// Four stacked stats — count over label — instead of the visitor view's
/// dot-separated inline line.
class _StatsBlock extends ConsumerWidget {
  final String handle;
  final PublicProfile profile;
  const _StatsBlock({required this.handle, required this.profile});

  /// Tab positions on a visited profile. Zines always leads; Guardados sits
  /// second, except on the official Soko account where Editor Picks takes that
  /// slot. Kept next to the tab lists in [_ProfileBody] — if those reorder,
  /// these move with them.
  static const int _zinesTabIndex = 0;
  int get savedTabIndex => profile.isOfficial ? 2 : 1;

  /// `maybeOf`, because the self profile has no TabBar at all — a hard `of`
  /// would throw there rather than simply doing nothing.
  void _openTab(BuildContext context, int index) {
    DefaultTabController.maybeOf(context)?.animateTo(index);
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    // The optimistic deltas track MY follow/unfollow taps, so they only apply
    // to my own counts. Another user's totals move only on a server refetch.
    final isSelf = profile.isSelf && !_VisitorPreview.of(context);
    final int followingRaw =
        profile.followingCount +
        (isSelf ? ref.watch(myFollowingCountDeltaProvider) : 0);
    final int followersRaw =
        profile.followersCount +
        (isSelf ? ref.watch(myFollowerCountDeltaProvider) : 0);
    // Follower / following lists open on your own profile, and on someone
    // else's only where the backend would let you see them anyway.
    final canOpenLists =
        (isSelf || profile.canViewPrivateSections) &&
        !_ProfileSandbox.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 22, 15, 0),
      child: Wrap(
        spacing: 30,
        runSpacing: 12,
        children: [
          _StackedStat(
            value: followersRaw < 0 ? 0 : followersRaw,
            label: l10n.profileStatFollowers,
            onTap: canOpenLists
                ? () => context.push(
                    AppRoutes.followListPath(handle, 'followers'),
                  )
                : null,
          ),
          _StackedStat(
            value: followingRaw < 0 ? 0 : followingRaw,
            label: l10n.profileStatFollowing,
            onTap: canOpenLists
                ? () => context.push(
                    AppRoutes.followListPath(handle, 'following'),
                  )
                : null,
          ),
          // Guardados / Zines. On your OWN profile these live in the Library
          // (the old tabs moved there), so the counters go there — `go`, not
          // `push`, because the Library is a sibling shell tab. The target is
          // `/library` (the redesigned hub), NOT the legacy `/yours` hub that
          // it replaced; Zines lands on its own tag. On someone else's profile
          // the Library is yours, not theirs; the counters switch to that
          // person's tab instead.
          _StackedStat(
            value: profile.savedCount,
            label: l10n.profileStatSaved,
            onTap: isSelf
                ? () => context.go(AppRoutes.libraryAll)
                : () => _openTab(context, savedTabIndex),
          ),
          _StackedStat(
            value: profile.zinesCount,
            label: l10n.profileStatZines,
            onTap: isSelf
                ? () => context.go(
                    AppRoutes.libraryWithTag(LibraryCategory.zines),
                  )
                : () => _openTab(context, _zinesTabIndex),
          ),
        ],
      ),
    );
  }
}

class _StackedStat extends StatelessWidget {
  final int value;
  final String label;
  final VoidCallback? onTap;
  const _StackedStat({required this.value, required this.label, this.onTap});

  @override
  Widget build(BuildContext context) {
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          '$value',
          style: Pt.b2.copyWith(fontSize: 18, fontWeight: FontWeight.w400),
        ),
        const SizedBox(height: 2),
        Text(label, style: Pt.b2.copyWith(color: pInk50)),
      ],
    );
    if (onTap == null) return content;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: content,
    );
  }
}

/// "📍 City · 👤 @handle", then the bio underneath — full width, below the
/// stats, rather than crammed into the column beside the avatar.
class _MetaLine extends StatelessWidget {
  final String handle;
  final PublicProfile profile;
  const _MetaLine({required this.handle, required this.profile});

  @override
  Widget build(BuildContext context) {
    final handleStr = profile.handle ?? handle;
    final city = profile.city;
    final bio = _bioText(profile.bio);
    return Padding(
      padding: const EdgeInsets.fromLTRB(15, 18, 15, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 6,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              if (city != null && city.isNotEmpty) ...[
                Icon(LucideIcons.map_pin, size: 15, color: AppColors.sokoInk),
                Text(city, style: Pt.b2),
                _Dot(),
              ],
              Icon(LucideIcons.user, size: 15, color: AppColors.sokoInk),
              Text('@$handleStr', style: Pt.b2),
            ],
          ),
          if (bio != null) ...[
            const SizedBox(height: 12),
            Text(bio, style: Pt.b2.copyWith(height: 1.35)),
          ],
        ],
      ),
    );
  }
}

/// The dotted rule that separates the identity block from the tabs.
class _DottedRule extends StatelessWidget {
  const _DottedRule();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(15, 22, 15, 0),
    child: CustomPaint(
      size: const Size(double.infinity, 1),
      painter: _DottedRulePainter(),
    ),
  );
}

class _DottedRulePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppColors.sokoInk.withValues(alpha: 0.22)
      ..strokeWidth = 1
      ..strokeCap = StrokeCap.round;
    const dash = 1.5;
    const gap = 5.0;
    for (var x = 0.0; x < size.width; x += dash + gap) {
      canvas.drawLine(Offset(x, 0.5), Offset(x + dash, 0.5), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
