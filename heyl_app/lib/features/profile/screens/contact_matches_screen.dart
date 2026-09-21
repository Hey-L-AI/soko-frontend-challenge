import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/constants/api_constants.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../data/models/social/user_search_item.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart';
import '../../../shared/utils/share_helpers.dart';
import '../../../shared/widgets/expert_badge.dart';
import '../../../shared/widgets/soko_back_button.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../providers/follow_state_provider.dart';
import '../providers/people_providers.dart';
import '../providers/public_profile_providers.dart';
import '../services/contact_sync_service.dart';
import '../utils/profile_style.dart';
import '../widgets/compact_follow_button.dart';
import '../widgets/textured_avatar.dart';

/// "Find contacts" — the mobile contact-discovery flow: a pre-permission
/// explainer, the OS Contacts prompt, then the Soko users found among the
/// device's contacts. Raw numbers never leave the device (only hashes).
class ContactMatchesScreen extends ConsumerStatefulWidget {
  const ContactMatchesScreen({super.key});

  @override
  ConsumerState<ContactMatchesScreen> createState() =>
      _ContactMatchesScreenState();
}

enum _Phase { intro, loading, results, denied, empty, error }

class _ContactMatchesScreenState extends ConsumerState<ContactMatchesScreen> {
  _Phase _phase = _Phase.intro;
  ContactSyncResult? _result;

  /// Persisted marker that a contact sync completed successfully on this
  /// device. The in-memory [contactSyncCacheProvider] only lives for the app
  /// session, so without this the pre-permission intro reappeared on every
  /// app restart even though the OS permission was already granted.
  static const _kSyncedOnceKey = 'contacts_synced_once';

  @override
  void initState() {
    super.initState();
    // Restore a previous successful sync so returning to this screen shows the
    // matched list instead of the "Sync contacts" prompt again.
    final cached = ref.read(contactSyncCacheProvider);
    if (cached != null) {
      _phase = _resolve(cached);
      _result = cached;
    } else {
      _skipIntroIfSyncedBefore();
    }
  }

  /// After an app restart the session cache is empty but the device may have
  /// synced before — then the intro adds nothing (the permission prompt won't
  /// show again), so jump straight into a fresh sync: loading → results.
  Future<void> _skipIntroIfSyncedBefore() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted || _phase != _Phase.intro) return;
    if (prefs.getBool(_kSyncedOnceKey) ?? false) {
      _sync();
    }
  }

  /// Map a sync outcome to the phase to render. `ok` shows the results surface
  /// when there's anything at all — Soko matches OR invite candidates.
  static _Phase _resolve(ContactSyncResult result) {
    switch (result.status) {
      case ContactSyncStatus.ok:
        final hasMatches = (result.matches?.items.isNotEmpty ?? false);
        final hasInvitable = result.invitable.isNotEmpty;
        return (hasMatches || hasInvitable) ? _Phase.results : _Phase.empty;
      case ContactSyncStatus.empty:
        return _Phase.empty;
      case ContactSyncStatus.permissionDenied:
        return _Phase.denied;
      case ContactSyncStatus.unsupported:
        return _Phase.error;
    }
  }

  Future<void> _sync() async {
    setState(() => _phase = _Phase.loading);
    final analytics = ref.read(unifiedAnalyticsProvider);
    // Contact sync imports a social graph that already exists outside the app,
    // so it's plausibly the biggest growth lever here — and until now we
    // couldn't even tell how many people started it, let alone how many
    // matches they got. 'started' is the funnel's denominator: a drop between
    // it and 'completed' is the OS permission prompt doing the damage.
    analytics.trackContactSync(status: 'started');
    try {
      final result = await ref.read(contactSyncServiceProvider).sync();
      if (!mounted) return;
      analytics.trackContactSync(
        status: switch (result.status) {
          ContactSyncStatus.ok => 'completed',
          ContactSyncStatus.permissionDenied => 'permission_denied',
          // Permission granted but no usable numbers — kept distinct from
          // 'completed' with zero matches, which means the opposite problem
          // (we read the address book fine, nobody there is on Soko).
          ContactSyncStatus.empty => 'empty',
          ContactSyncStatus.unsupported => 'failed',
        },
        matchCount: result.matches?.items.length,
        contactCount:
            result.invitable.length + (result.matches?.items.length ?? 0),
      );
      final phase = _resolve(result);
      // Cache only a successful result; transient outcomes
      // (denied/error/empty) stay uncached so the user lands back on the intro
      // and can retry.
      if (phase == _Phase.results) {
        ref.read(contactSyncCacheProvider.notifier).store(result);
        // Remember across restarts that a sync has succeeded, so the intro
        // (whose only job is to preface the OS permission prompt) is skipped
        // on future visits. Fire-and-forget — losing it just re-shows intro.
        SharedPreferences.getInstance().then(
          (p) => p.setBool(_kSyncedOnceKey, true),
        );
      }
      setState(() {
        _phase = phase;
        _result = result;
      });
    } catch (_) {
      if (mounted) setState(() => _phase = _Phase.error);
    }
  }

  @override
  Widget build(BuildContext context) {
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
                    // The intro carries its own illustration + heading (Figma)
                    // so it shows no app-bar title; list states get the serif.
                    if (_phase != _Phase.intro) ...[
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          Lt.of(context).findContactsTitle,
                          style: Pt.display,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              Expanded(child: _body()),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    final l10n = Lt.of(context);
    switch (_phase) {
      case _Phase.loading:
        return const Center(child: CircularProgressIndicator(strokeWidth: 2));
      case _Phase.results:
        return _Results(result: _result!);
      case _Phase.empty:
        return _Info(
          icon: LucideIcons.users_round,
          title: l10n.findContactsEmptyTitle,
          body: l10n.findContactsEmptyBody,
        );
      case _Phase.denied:
        return _Info(
          icon: LucideIcons.lock,
          title: l10n.findContactsDeniedTitle,
          body: l10n.findContactsDeniedBody,
          actionLabel: l10n.findContactsOpenSettings,
          onAction: () => ref.read(contactSyncServiceProvider).openSettings(),
        );
      case _Phase.error:
        return _Info(
          icon: LucideIcons.circle_alert,
          title: l10n.commonSomethingWrong,
          body: l10n.findContactsErrorBody,
          actionLabel: l10n.commonRetry,
          onAction: _sync,
        );
      case _Phase.intro:
        return _Intro(onSync: _sync);
    }
  }
}

class _Intro extends StatelessWidget {
  final VoidCallback onSync;
  const _Intro({required this.onSync});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        children: [
          const Spacer(flex: 2),
          // Binoculars "spotting" illustration (Figma 7140:22379) — replaces the
          // old flat pink icon tile.
          Image.asset(
            'assets/images/illustrations/soko-binoculars.png',
            height: 140,
            fit: BoxFit.contain,
          ),
          const SizedBox(height: 28),
          Text(
            l10n.findContactsIntroTitleV2,
            style: Pt.display,
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 12),
          Text(
            l10n.findContactsIntroBodyV2,
            textAlign: TextAlign.center,
            style: Pt.b2.copyWith(color: pInk50),
          ),
          const SizedBox(height: 28),
          // Same pink CTA + contacts icon as before — only the copy changes to
          // the friendlier "Find your friends" (per Figma).
          SokoCtaButton(
            label: l10n.findContactsFindFriendsCta,
            icon: LucideIcons.contact_round,
            onPressed: onSync,
          ),
          const Spacer(flex: 3),
        ],
      ),
    );
  }
}

class _Results extends StatelessWidget {
  final ContactSyncResult result;
  const _Results({required this.result});

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final matches = result.matches?.items ?? const <UserSearchItem>[];
    final invitable = result.invitable;

    // A flat, lazily-built list: a section header + its rows for whichever of
    // "on Soko" / "invite" have entries. Entries are typed (header String vs
    // match vs invite) and dispatched in the item builder.
    final entries = <Object>[];
    if (matches.isNotEmpty) {
      entries.add(
        _Header(
          l10n.findContactsOnSokoHeader,
          trailing: _FollowAllButton(matches: matches),
        ),
      );
      entries.addAll(matches);
    }
    if (invitable.isNotEmpty) {
      entries.add(_Header(l10n.findContactsInviteHeader));
      entries.addAll(invitable);
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: entries.length,
      separatorBuilder: (_, i) => SizedBox(
        // Rows self-space via their own vertical padding; add breathing room
        // only right above a section header.
        height: entries[i + 1] is _Header ? 12 : 0,
      ),
      itemBuilder: (_, i) {
        final e = entries[i];
        if (e is _Header) return e;
        if (e is UserSearchItem) {
          return _ContactRow(
            item: e,
            youMayKnowAs: e.phoneHash == null
                ? null
                : result.hashToName[e.phoneHash],
          );
        }
        return _InviteRow(contact: e as InvitableContact);
      },
    );
  }
}

class _Header extends StatelessWidget {
  final String text;

  /// Optional action rendered at the row's end (e.g. "Follow all").
  final Widget? trailing;
  const _Header(this.text, {this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: trailing == null
        ? Text(text, style: Pt.b1)
        : Row(
            children: [
              Expanded(child: Text(text, style: Pt.b1)),
              trailing!,
            ],
          ),
  );
}

/// "Follow all" next to the "On Soko" header — follows every matched contact
/// the viewer doesn't follow yet, one API call per user. Rows flip to
/// "Following"/"Requested" as each write lands (via the shared follow store),
/// and the button removes itself once nobody is left to follow.
class _FollowAllButton extends ConsumerStatefulWidget {
  final List<UserSearchItem> matches;
  const _FollowAllButton({required this.matches});

  @override
  ConsumerState<_FollowAllButton> createState() => _FollowAllButtonState();
}

class _FollowAllButtonState extends ConsumerState<_FollowAllButton> {
  bool _busy = false;

  /// Matches still in relationship 'none' — shared follow store wins over the
  /// server-seeded row state, same resolution as [CompactFollowButton].
  List<UserSearchItem> _pending(Map<String, String> store) =>
      widget.matches.where((m) {
        final rel =
            store[m.userId] ??
            (m.isFollowing
                ? 'following'
                : (m.requested ? 'requested' : 'none'));
        return rel == 'none';
      }).toList();

  Future<void> _followAll() async {
    if (_busy) return;
    setState(() => _busy = true);
    final api = ref.read(followsApiProvider);
    final analytics = ref.read(unifiedAnalyticsProvider);
    final actionContext = analytics.actionContext;
    var failures = 0;
    for (final m in _pending(ref.read(followStateProvider))) {
      try {
        final res = await api.follow(m.userId);
        final next = res.requested ? 'requested' : 'following';
        analytics.trackUserFollow(
          actionContext: actionContext,
          targetUserId: m.userId,
          source: 'contact_match',
          resultingState: next,
          isSoko: false,
          wasFollowBack: m.followsYou,
        );
        ref.read(followStateProvider.notifier).set(m.userId, next);
        final d = followingCountDelta('none', next);
        if (d != 0) ref.read(myFollowingCountDeltaProvider.notifier).bump(d);
      } catch (_) {
        // Keep going — one bad follow shouldn't abort the batch; the failed
        // row simply keeps its pink Follow button for a manual retry.
        failures++;
      }
    }
    ref.invalidate(suggestedUsersProvider);
    if (!mounted) return;
    if (failures > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(Lt.of(context).commonSomethingWrong)),
      );
    }
    setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    // Watch the store so the button disappears the moment the last pending
    // match is followed — whether via this button or the per-row ones.
    final pending = _pending(ref.watch(followStateProvider));
    if (pending.isEmpty) return const SizedBox.shrink();
    return GestureDetector(
      onTap: _busy ? null : _followAll,
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: AppColors.sokoPink,
          borderRadius: BorderRadius.circular(8),
        ),
        child: _busy
            ? const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.sokoInk,
                ),
              )
            : Text(Lt.of(context).findContactsFollowAll, style: Pt.b2),
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  final UserSearchItem item;

  /// How this contact is saved locally ("you may know as …"). Shown only when it
  /// adds information — i.e. differs from the Soko name — so an unnamed user
  /// (`user7463276`) reads as "Pai" but an identical name isn't echoed.
  final String? youMayKnowAs;

  const _ContactRow({required this.item, this.youMayKnowAs});

  @override
  Widget build(BuildContext context) {
    final handle = item.handle;
    final knownAs = youMayKnowAs?.trim();
    final showKnownAs =
        knownAs != null &&
        knownAs.isNotEmpty &&
        knownAs.toLowerCase() != (item.fullName ?? '').toLowerCase();
    // Borderless — flat on the paper (Figma). A followed contact stays listed
    // (it's still a contact); only the follow button flips to the grey
    // "Following" — the row is NOT dropped like a suggestion.
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
                  _Avatar(
                    url: item.avatarUrl,
                    name: item.fullName ?? item.handle,
                    seed: item.userId,
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
                        if (item.handle != null)
                          Text(
                            '@${item.handle}',
                            style: Pt.b2.copyWith(color: pInk50),
                          ),
                        if (showKnownAs)
                          Padding(
                            padding: const EdgeInsets.only(top: 2),
                            child: Text(
                              Lt.of(context).findContactsSavedAs(knownAs),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Pt.b2.copyWith(
                                color: pInk50,
                                fontStyle: FontStyle.italic,
                              ),
                            ),
                          ),
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
            refreshSuggestionsOnChange: true,
            analyticsSource: 'contact_match',
          ),
        ],
      ),
    );
  }
}

/// A non-Soko contact row with an Invite action. Tapping Invite opens the
/// platform-native share sheet (via [shareItem]) carrying the generic app
/// install link — the user picks the recipient and app themselves.
class _InviteRow extends ConsumerWidget {
  final InvitableContact contact;
  const _InviteRow({required this.contact});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          _Avatar(name: contact.name),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              contact.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Pt.b1Bold,
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: () {
              ref
                  .read(unifiedAnalyticsProvider)
                  .trackInviteShared(source: 'contact_match');
              shareItem(
                context: context,
                ref: ref,
                title: Lt.of(context).inviteShareMessageTitle,
                url: ApiConstants.appInstallUrl,
              );
            },
            child: Container(
              height: 34,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                // Venue blue — sets Invite apart from the pink Follow action.
                color: AppColors.sokoVenue,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                Lt.of(context).findContactsInviteButton,
                style: Pt.b2,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Avatar extends StatelessWidget {
  final String? url;
  final String? name;

  /// Per-person placeholder seed (user id for Soko matches; invite rows have
  /// no id and fall back to the contact's name inside [TexturedAvatar]).
  final String? seed;
  const _Avatar({this.url, this.name, this.seed});

  @override
  Widget build(BuildContext context) {
    return TexturedAvatar(
      url: url,
      name: name,
      colorSeed: seed,
      width: 50,
      height: 50,
      initialFontScale: 0.34,
    );
  }
}

class _Info extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final String? actionLabel;
  final VoidCallback? onAction;
  const _Info({
    required this.icon,
    required this.title,
    required this.body,
    this.actionLabel,
    this.onAction,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 34, color: pInk30),
          const SizedBox(height: 14),
          Text(title, style: Pt.b1Bold, textAlign: TextAlign.center),
          const SizedBox(height: 8),
          Text(
            body,
            textAlign: TextAlign.center,
            style: Pt.b2.copyWith(color: pInk50),
          ),
          if (actionLabel != null && onAction != null) ...[
            const SizedBox(height: 20),
            SokoCtaButton(
              label: actionLabel!,
              onPressed: onAction,
              expand: false,
            ),
          ],
        ],
      ),
    );
  }
}
