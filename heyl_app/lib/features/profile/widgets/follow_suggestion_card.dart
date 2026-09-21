import 'package:flutter/material.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/social/user_search_item.dart';
import '../../../l10n/generated/l10n.dart';
import 'follow_add_badge.dart';
import 'mutual_avatars_row.dart';
import 'textured_avatar.dart';

/// The optional extra line(s) under the handle on the people feed — the
/// **details row** (PROD-4443, Figma `7740:46953`).
///
/// [text] arrives **final and localized from the backend and is rendered
/// verbatim**: the app does not pluralise it, join names into it, or count
/// anything. The field is called `details` rather than "social proof" precisely
/// because what fills it is the backend's to change (mutuals today; shared
/// tastes, public zines or a home city tomorrow) without the app knowing.
///
/// [avatars] are the faces drawn **before** the text, on the same line. Pass
/// them as [MutualAvatar]s — never as bare URLs — so a person with no profile
/// photo draws a seeded initial placeholder instead of vanishing, which would
/// leave two faces standing beside the words "3 pessoas em comum".
///
/// Three shapes, all supported and all the backend's choice: faces + text,
/// text alone (`avatars: []`), or no row at all (`details: null`).
@immutable
class FollowSuggestionDetails {
  final String text;
  final List<MutualAvatar> avatars;

  const FollowSuggestionDetails({required this.text, this.avatars = const []});
}

/// One suggested person (Figma `7304:24157`, extended for the people feed by
/// `7740:46909`): a rounded-square avatar carrying a circled-"+" follow badge
/// over its right edge, then the name (up to two lines), the @handle, and —
/// on the feed only — a [details] row.
///
/// The single card for "here is someone you could follow", shared by three
/// surfaces: the onboarding follow carousel, the Discovery "Locals" shelf, and
/// the people feed's grid. Everything about it is derived from [avatarSize] so
/// a shelf can scale the whole card down without the badge drifting off the
/// avatar's edge — the design is 80 px with a 40 px badge, and the ratios below
/// come straight from that frame.
///
/// ⚠️ **Its height cannot be predicted when [details] is set.** The details row
/// is 0–3 lines of backend-supplied text at an unknown length, so the static
/// calculators below ([textBlockHeight], [knownAsBlockHeight]) deliberately do
/// **not** cover it — a function returning a plausible-but-wrong height would
/// silently clip the row. The two fixed-height callers never pass [details];
/// the grid that does measures instead (PROD-4444).
class FollowSuggestionCard extends StatelessWidget {
  const FollowSuggestionCard({
    super.key,
    required this.item,
    required this.analyticsSource,
    this.onTap,
    this.onboardingStep,
    this.onFollowToggled,
    this.avatarSize = designAvatarSize,
    this.knownAs,
    this.details,
    this.width,
  });

  final UserSearchItem item;

  /// The local device address-book name for this person ("known as"), shown as a
  /// muted italic "Saved as …" line under the handle. Only supplied on the
  /// onboarding contact-match surface; null everywhere else (Discovery Locals).
  final String? knownAs;

  /// The people feed's details row, under the handle. Null on the onboarding
  /// carousel and the Locals shelf — see [FollowSuggestionDetails].
  final FollowSuggestionDetails? details;

  /// Which surface this card lives on — see [FollowAddBadge.analyticsSource].
  final String analyticsSource;

  /// Opens the person. The badge keeps its own tap (a child gesture wins inside
  /// its own bounds), so this fires for the rest of the card only.
  final VoidCallback? onTap;

  /// Onboarding funnel step for the badge, when this card is in onboarding.
  final String? onboardingStep;

  /// PROD-4521 — forwarded to [FollowAddBadge.onFollowToggled]. Supplied only
  /// by the feed's people grid; see that field for why the emission is the
  /// caller's and not this shared card's.
  final ValueChanged<bool>? onFollowToggled;

  /// Side of the square avatar. Everything else scales with it.
  final double avatarSize;

  /// Cell width, when the caller has one of its own.
  ///
  /// Null — the two scrolling surfaces — means the card sizes itself to
  /// [widthForAvatar], the width Figma's carousel cell gives an avatar plus its
  /// badge overhang. The feed grid instead derives the cell from the available
  /// page width and the avatar from the cell, so it passes the cell here and
  /// the text wraps across all of it (Figma's feed card is 125 wide around the
  /// same 80 avatar, not 118).
  final double? width;

  /// Figma's card: an 80×80 avatar, a 40×40 badge at x=74 y=20 (so it straddles
  /// the right edge, vertically centred), inside a 118-wide cell.
  static const double designAvatarSize = 80;
  static const double _badgeRatio = 40 / 80;
  static const double _badgeLeftRatio = 74 / 80;
  static const double _badgeTopRatio = 20 / 80;
  static const double _stackWidthRatio = 114 / 80; // badge left + badge width
  static const double _cardWidthRatio = 118 / 80;

  /// Gaps below the avatar do NOT scale with it, and neither does the type: the
  /// design system's B1/B2 are fixed sizes, and shrinking them to honour a
  /// ratio would buy nothing.
  ///
  /// Both gaps are 12 in the feed frame (`7740:46910`: avatar ends at 80, name
  /// starts at 92; the name block ends at 128, the handle group starts at 140)
  /// and the onboarding/Locals cards adopt them with the type — one card, one
  /// scale.
  static const double _avatarToName = 12;
  static const double _nameToHandle = 12;

  /// Handle → details row (`7740:46951`: handle ends at 14, the row starts at
  /// 22). Only ever spent when [details] is set.
  static const double _handleToDetails = 8;

  /// The optional "Saved as …" (known-as) line under the handle — a 4th line
  /// only rendered on the onboarding contact-match surface. Its height is added
  /// to a caller's row height via [knownAsBlockHeight] when it can appear. Its
  /// own 12 px / 1.2 type is untouched by the B1/B2 adoption above.
  static const double _handleToKnownAs = 2;
  static const double _knownAsFontSize = 12;
  static const double _knownAsLineHeight = 1.2;

  /// The details row's faces: 20 px circles on a 16 px step (so 4 px of
  /// overlap), 6 px before the text (`7740:46953` — cluster at x=0 w=52 for
  /// three, text at x=26 for one).
  static const double _detailsAvatarSize = 20;
  static const double _detailsAvatarStep = 16;
  static const double _detailsAvatarsToText = 6;

  /// Faces the row draws, however many the backend sends.
  static const int _detailsMaxAvatars = 3;

  /// Lines the row wraps to before truncating (Zé, 2026-09-15).
  static const int _detailsMaxLines = 3;

  /// Lookup handle for the details row. The card paints several `Text`s — the
  /// avatar's initial placeholder among them — so "the last one" is not a
  /// stable way to find this from outside.
  static const Key detailsRowKey = ValueKey('follow-suggestion-details');

  /// **Mobile/B1 Reg** — Zalando Sans Light 18 / lh 1.0 / ls −0.36.
  static final TextStyle _nameStyle = AppTheme.mobileB1Reg(
    color: AppColors.sokoInk,
  );

  /// **Mobile/B2 Reg** at `Soko/Ink 50` — the handle and the details row share
  /// this exactly (`get_variable_defs` on `7740:46956` returns both together).
  static final TextStyle _handleStyle = AppTheme.mobileB2Reg(
    color: AppColors.sokoInk50,
  );

  /// The rendered line box of [style] — read back off the style itself so the
  /// height calculators below cannot drift from the type they measure.
  static double _lineBox(TextStyle style) =>
      (style.fontSize ?? 14) * (style.height ?? 1.0);

  /// The follow badge's tap square at this avatar size — at least 44 px, which
  /// is usually larger than the disc it paints.
  static double _badgeTapTarget(double avatarSize) =>
      FollowAddBadge.tapTargetFor(avatarSize * _badgeRatio);

  /// Cell width for a given avatar — the avatar plus the badge's overhang plus
  /// Figma's trailing sliver. The default when [width] is null.
  static double widthForAvatar(double avatarSize) =>
      avatarSize * _cardWidthRatio;

  /// Inverse of [widthForAvatar]: the avatar a cell of [width] can hold.
  static double avatarForWidth(double width) => width / _cardWidthRatio;

  /// A couple of pixels over the exact block, so a font whose rendered line box
  /// rounds up by a fraction doesn't paint an overflow stripe in the shelf's
  /// fixed-height row.
  static const double _slack = 4;

  /// Height of everything under the avatar, at the OS [textScale]. Reserved by
  /// callers that must state a row height up front (the Discovery shelf, the
  /// onboarding carousel).
  ///
  /// ⚠️ **Covers the name + handle only.** [details] is deliberately absent —
  /// see the class doc. Do not extend this to guess at it.
  /// ⚠️ **[textScale] multiplies the TEXT only.** The gaps and [_slack] are
  /// fixed `SizedBox`es and a fixed fudge — they do not grow with the OS text
  /// scale, and scaling them here made the reserve drift away from what the
  /// card paints (over-reserving on the shelf, which reads as a too-tall row).
  static double textBlockHeight([double textScale = 1.0]) =>
      _avatarToName +
      2 * _lineBox(_nameStyle) * textScale +
      _nameToHandle +
      _lineBox(_handleStyle) * textScale +
      _slack;

  /// Extra height the optional known-as line adds, for callers that must fix a
  /// row height up front (the onboarding contacts list). Add to the base row
  /// height only when a card in the row can render a known-as line.
  /// [textScale] multiplies the text only — see [textBlockHeight].
  static double knownAsBlockHeight([double textScale = 1.0]) =>
      _handleToKnownAs + _knownAsFontSize * _knownAsLineHeight * textScale;

  @override
  Widget build(BuildContext context) {
    final name = item.fullName ?? item.handle ?? '';
    final handle = item.handle;
    final details = this.details;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: SizedBox(
        width: width ?? widthForAvatar(avatarSize),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // The SizedBox sizes the Stack to contain the overhanging badge.
            // Without it the Stack shrinks to the avatar and the badge's
            // overflow, while still painted (Clip.none), is NOT hit-testable —
            // taps on the visible "+" would fall through to the card's
            // GestureDetector and open the profile instead of following. See
            // docs/learnings.
            SizedBox(
              width: avatarSize * _stackWidthRatio,
              height: avatarSize,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  TexturedAvatar(
                    url: item.avatarUrl,
                    name: name,
                    colorSeed: item.userId,
                    width: avatarSize,
                    height: avatarSize,
                  ),
                  // Positioned by where the DISC must land, not by where the
                  // badge widget's box starts — the box is at least 44 px
                  // (PROD-4444) and hangs off the disc's left, so its own
                  // top-left is not Figma's badge origin.
                  //
                  // Right edge of the box == right edge of the disc ==
                  // `_stackWidthRatio`, and the box is centred on the disc's
                  // vertical centre (`avatarSize / 2`, i.e. `_badgeTopRatio +
                  // _badgeRatio / 2`). At the design size that puts the disc at
                  // exactly x74 y20 / 40×40, unchanged from before.
                  //
                  // ⚠️ **The full 44 is only reachable while the avatar is ≥
                  // 44.** Below that the box is taller than the Stack that
                  // contains it, and area outside a Stack is painted but not
                  // hit-testable, so the overhang is inert and the effective
                  // target shrinks to the avatar's height. Fixing it properly
                  // would mean growing the Stack, which changes the card's
                  // layout on all three surfaces for a case none of them reach:
                  // onboarding is 80, and the Locals shelf bottoms out near 68
                  // at a 375-wide viewport. An avatar under 44 needs a feed
                  // content column under ~230 — i.e. a browser window around
                  // 260 px. Accepted, not overlooked.
                  Positioned(
                    left:
                        avatarSize * (_badgeLeftRatio + _badgeRatio) -
                        _badgeTapTarget(avatarSize),
                    top:
                        avatarSize * (_badgeTopRatio + _badgeRatio / 2) -
                        _badgeTapTarget(avatarSize) / 2,
                    child: FollowAddBadge(
                      userId: item.userId,
                      initialFollowing: item.isFollowing,
                      requested: item.requested,
                      followsYou: item.followsYou,
                      analyticsSource: analyticsSource,
                      onboardingStep: onboardingStep,
                      onFollowToggled: onFollowToggled,
                      size: avatarSize * _badgeRatio,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: _avatarToName),
            Text(
              name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: _nameStyle,
            ),
            if (handle != null && handle.isNotEmpty) ...[
              const SizedBox(height: _nameToHandle),
              Text(
                '@$handle',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: _handleStyle,
              ),
            ],
            if (knownAs != null && knownAs!.isNotEmpty) ...[
              const SizedBox(height: _handleToKnownAs),
              Text(
                Lt.of(context).findContactsSavedAs(knownAs!),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.body(
                  fontSize: _knownAsFontSize,
                  color: AppColors.sokoShade3,
                  height: _knownAsLineHeight,
                ).copyWith(fontStyle: FontStyle.italic),
              ),
            ],
            if (details != null) ...[
              const SizedBox(height: _handleToDetails),
              _detailsRow(details),
            ],
          ],
        ),
      ),
    );
  }

  /// The details row: faces, then the backend's sentence, **on the same line**,
  /// wrapping to at most [_detailsMaxLines] left-aligned with the faces.
  ///
  /// A leading `WidgetSpan` inside a wrapping `Text.rich` is what buys that
  /// shape, and it is why this is not a `Row`: a `Row` would hold the faces and
  /// the text side by side and force the text to wrap inside its own narrower
  /// column, indenting every line after the first. Here the faces are simply
  /// the first thing on line 1, and line 2 starts at the card's left edge —
  /// which is where the faces start.
  ///
  /// ⚠️ Figma's cards 1 and 2 draw the text on its own line *below* the faces.
  /// That is a design bug, not the spec (Zé, 2026-09-15, pointing at card 3 —
  /// `7740:46953` — as correct for all of them).
  Widget _detailsRow(FollowSuggestionDetails details) {
    final faces = details.avatars
        .take(_detailsMaxAvatars)
        .toList(growable: false);

    return Text.rich(
      key: detailsRowKey,
      TextSpan(
        children: [
          if (faces.isNotEmpty)
            WidgetSpan(
              // Centres the cluster on the first line's text rather than
              // sitting it on the baseline, which is what the frame draws: a
              // 20 px circle against a 14 px line, the text at y=3 of a 20-tall
              // row.
              alignment: PlaceholderAlignment.middle,
              child: Padding(
                padding: const EdgeInsets.only(right: _detailsAvatarsToText),
                child: MutualAvatarCluster(
                  people: faces,
                  size: _detailsAvatarSize,
                  overlap: _detailsAvatarSize - _detailsAvatarStep,
                  // Exactly the ringed circles. No "+" badge and no room for
                  // one: the backend caps `avatars` at three and its `text`
                  // already says whatever the count is, so a "+" here would be
                  // the app inventing a meaning the sentence does not carry.
                  height:
                      _detailsAvatarSize + 2 * MutualAvatarCluster.ringWidth,
                ),
              ),
            ),
          TextSpan(text: details.text),
        ],
      ),
      maxLines: _detailsMaxLines,
      overflow: TextOverflow.ellipsis,
      style: _handleStyle,
    );
  }
}
