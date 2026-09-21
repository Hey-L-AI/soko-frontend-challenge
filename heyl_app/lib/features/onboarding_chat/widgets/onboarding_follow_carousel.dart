import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/social/user_search_item.dart';
import '../../profile/providers/people_providers.dart';
import '../../profile/screens/public_profile_screen.dart';
import '../../profile/widgets/follow_suggestion_card.dart';
import 'onboarding_card_entrance.dart';

/// The onboarding follow-people carousel (Figma `7304:24156`): suggested users
/// to follow, each an 80×80 rounded-square avatar carrying a 40×40 circled-"+"
/// follow badge over its right edge, with a name + @handle below. Reads the global
/// `orderedSuggestedUsersProvider` (the same Locals fetch used across the app),
/// bracketed by a hairline divider.
///
/// Non-blocking: while loading it shows a slim spinner; on error or an empty
/// result it renders nothing, so a thin suggestion pool never traps the user.
class OnboardingFollowCarousel extends ConsumerWidget {
  const OnboardingFollowCarousel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(orderedSuggestedUsersProvider);
    final users = async.valueOrNull?.items ?? const <UserSearchItem>[];

    if (async.isLoading && users.isEmpty) {
      return SizedBox(
        height: OnboardingFollowList.rowHeightOf(context),
        child: const Center(
          child: CircularProgressIndicator(color: AppColors.sokoPink),
        ),
      );
    }
    if (users.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(height: 1, thickness: 1, color: AppColors.sokoInk8),
        const SizedBox(height: 12),
        OnboardingFollowList(items: users),
        const SizedBox(height: 12),
        const Divider(height: 1, thickness: 1, color: AppColors.sokoInk8),
      ],
    );
  }
}

/// A fixed-height horizontal row of follow cards, driven by an arbitrary list of
/// [UserSearchItem]s. Reused by the suggestions carousel above and the inline
/// "from your contacts" matches in the onboarding profile step.
class OnboardingFollowList extends StatelessWidget {
  const OnboardingFollowList({super.key, required this.items, this.hashToName});

  final List<UserSearchItem> items;

  /// Device address-book display names keyed by SHA-256 phone hash — the same
  /// `ContactSyncResult.hashToName` map the profile contact-matches screen
  /// resolves against. Only supplied by the "from your contacts" matches; null
  /// for the generic suggestions carousel (which never populates `phoneHash`),
  /// so those cards keep the 3-line layout and the shorter [rowHeight].
  final Map<String, String>? hashToName;

  /// Tall enough for a two-line name, derived rather than declared — **and
  /// derived at this context's OS text scale**.
  ///
  /// This was a hardcoded `156` until PROD-4443 gave all three surfaces the
  /// design system's B1/B2 type. Two things were wrong with the constant and
  /// only one of them was visible:
  ///
  ///  * the text block grew ~13 px, so `156` became an overflow — which is why
  ///    this now reads off the card's own calculator, and a future type change
  ///    moves the row with it;
  ///  * `156` never accounted for the **OS text scale** either. It got away
  ///    with it because it happened to sit ~11 px above what the card painted,
  ///    and that accidental slack absorbed a modest scale-up. Deriving the
  ///    height removes the slack, so the scale has to be real from here on.
  ///
  /// Mirrors `DiscoveryShelf`'s own derivation (`discovery_shelf.dart:478`),
  /// including the clamp: a text scale below 1 shrinks the type but must not
  /// shrink the row, because the avatar does not scale at all.
  static double rowHeightOf(BuildContext context, {bool withKnownAs = false}) {
    final raw = MediaQuery.textScalerOf(context).scale(14) / 14;
    final textScale = raw < 1.0 ? 1.0 : raw;
    return FollowSuggestionCard.designAvatarSize +
        FollowSuggestionCard.textBlockHeight(textScale) +
        (withKnownAs ? FollowSuggestionCard.knownAsBlockHeight(textScale) : 0);
  }

  @override
  Widget build(BuildContext context) {
    // Contact-match cards can render a 4th "Saved as …" line, so reserve the
    // extra height for them; the suggestions carousel (no map) does not.
    final height = rowHeightOf(context, withKnownAs: hashToName != null);
    return SizedBox(
      height: height,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        clipBehavior: Clip.none,
        itemCount: items.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (context, index) => OnboardingCardEntrance(
          index: index,
          child: OnboardingFollowPersonCard(
            item: items[index],
            hashToName: hashToName,
          ),
        ),
      ),
    );
  }
}

/// Onboarding's suggested-user card: the shared [FollowSuggestionCard] wired to
/// onboarding's own tap target (a read-only sandbox profile) and funnel step.
class OnboardingFollowPersonCard extends StatelessWidget {
  const OnboardingFollowPersonCard({
    super.key,
    required this.item,
    this.hashToName,
  });

  final UserSearchItem item;

  /// Device address-book display names keyed by phone hash. When this card is a
  /// contact match (`item.phoneHash` set + present here), the resolved local
  /// "known as" name is shown under the handle. Null for suggestions.
  final Map<String, String>? hashToName;

  /// Opens this person's full profile in read-only sandbox mode on the root
  /// navigator — the profile's own back button pops straight back to
  /// onboarding, and every escape hatch is disabled (see [PublicProfileScreen]'s
  /// `sandbox`). Disabled when the person has no handle.
  void _openProfile(BuildContext context) {
    final handle = item.handle;
    if (handle == null || handle.isEmpty) return;
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute<void>(
        builder: (_) => Scaffold(
          backgroundColor: AppColors.sokoPaper,
          body: PublicProfileScreen(handle: handle, sandbox: true),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // "Known as" (device address-book name) — shown only when it adds info, i.e.
    // differs from the Soko name (mirrors contact_matches_screen). Null unless
    // this is a contact match with a resolvable local name.
    final hash = item.phoneHash;
    final localName = hash == null ? null : hashToName?[hash]?.trim();
    final knownAs =
        (localName != null &&
            localName.isNotEmpty &&
            localName.toLowerCase() != (item.fullName ?? '').toLowerCase())
        ? localName
        : null;
    return FollowSuggestionCard(
      item: item,
      analyticsSource: 'onboarding',
      // Also counted in the onboarding funnel, so we can see how many follows a
      // user makes while onboarding.
      onboardingStep: 'profile.follows',
      onTap: () => _openProfile(context),
      knownAs: knownAs,
    );
  }
}
