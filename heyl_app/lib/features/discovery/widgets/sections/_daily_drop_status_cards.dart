import 'package:auto_size_text/auto_size_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:intl/intl.dart';

import '../../../../core/theme/app_colors.dart';
import '../../../../core/theme/app_theme.dart';
import '../../../../core/utils/month_abbr.dart';
import '../../../../core/utils/soko_texture.dart';
import '../../../../shared/widgets/soko_grunge_surface.dart';
import '../../../daily_drop/widgets/daily_drop_wordmark.dart';

/// PROD-3730 — the two non-photo states of the Discovery Daily Drop slot.
///
/// Both hold the same 399 × 213 footprint as `DiscoveryImageTemplateCard` so
/// the shelves below never move when the real drop swaps in.
///
/// ## What these are copying, and how closely
///
/// A *best-effort* alignment to the PROD-3438 card frames (`7204-21018`
/// countdown, `7204-22437` open), not a reproduction — Zé, 2026-08-07: *"we
/// don't need to implement the exact new card design on this ticket… do our
/// best effort to align to the new design without needing to faithfully
/// rendering it."*
///
/// Taken from those frames, after Zé reviewed the first attempt on device
/// (2026-08-09) and found it didn't share their feel:
///
/// * **the sticker wordmark at the TOP**, not the bottom, and rendered with
///   the real [DailyDropWordmark] (PROD-3439) rather than flat text. The first
///   version painted a plain coloured `Text`, which is exactly the inverted
///   two-pass version that widget's docs warn about — the design is dark rim →
///   coloured band → dark core, not coloured letters with a dark outline;
/// * **the date row at the BOTTOM** (`Ago. 9` … `2026`), under a dotted rule;
/// * a coloured outer frame around a flat field, with a **dashed rectangle**
///   inset from it.
///
/// Deliberately dropped: **the countdown pill** (we have no deadline, only "in
/// progress" — PROD-3438 owns the countdown) and **the thumbnail image** (these
/// states have nothing to show yet). Height stays 213 rather than the frames'
/// 165/308 so the swap to the ready card doesn't move the feed; PROD-3438
/// restyles every state to its own heights together, later.
///
/// Colour ships as [kDailyDropCardPaletteDefault], chosen on device from six
/// candidates (2026-08-10). It is deliberately **not**
/// seeded through `dailyDropWordmarkColor` (PROD-3439): that helper keys on
/// `SokoEntityKind`, and while a drop is generating there is no entity — so
/// seeding it would silently pick a palette and could change colour the moment
/// the drop lands. heyl-webapp-2 confirmed the card is a different rule from
/// their header (2026-08-07): share the seed, not the colour function.

/// The inset rule style on a ritual card's frame.
enum RitualCardBorder { dashed, dotted }

/// How a ritual card wears its printed grain: which sheet, where that sheet
/// lands relative to the card, and how it is turned.
///
/// **The rect is the load-bearing part, and it is not "cover the card".** Both
/// frames hang a sheet BIGGER than the card and show a window onto it, which is
/// the difference between paper you are printed on and a picture of paper:
/// cover-fitting the Daily Drop's sheet packs every crease into 399 px and the
/// grain comes out ~1.7× too fine. Measured against Figma's own 4× render of
/// the card, the rect below scores **+0.88** and cover-fitting scores **+0.05**.
///
/// Rects are in fractions of the card, so they hold at any card width.
class RitualCardTexture {
  const RitualCardTexture({
    required this.asset,
    required this.rect,
    this.quarterTurns = 0,
  });

  final String asset;

  /// The sheet's rect **after** [quarterTurns], as fractions of the card box.
  final Rect rect;

  /// Clockwise quarter turns, matching [RotatedBox]. `3` is Figma's
  /// `rotate(-90deg)`.
  final int quarterTurns;
}

/// Daily Drop — `Gstaik Textures (5) 3`, turned a quarter and hung off the
/// top-left (Figma `7675:37871`).
///
/// Figma nests this as a 551 × 380 box at `calc(87.5% - 30.75px)` /
/// `calc(37.5% + 7.88px)` holding a `-rotate-90` child whose image over-fills it
/// 116.66 % × 100.55 % at a small negative offset. Those collapse to the single
/// rect below — the rotated sheet's own bounding box — so there is one
/// transform here rather than four, and it was checked to score identically to
/// the nested original.
///
/// The turn is not cosmetic: upright, the sheet's diagonal crease crosses the
/// card and reads as a scratch on the screen.
const RitualCardTexture kDailyDropCardTexture = RitualCardTexture(
  asset: kSokoDailyDropCardTexture,
  rect: Rect.fromLTWH(-0.00866, -0.92957, 1.58286, 2.37262),
  quarterTurns: 3,
);

/// Weekly Bundle — `Texturelabs_Grunge_340S 2`, unturned, the card's own width
/// and 1.16× its height, centred (Figma `7675:37893`: 350.229 × 217.069 at
/// `calc(50% + 0.11px)` / `calc(50% + 0.2px)`).
///
/// Simpler than the Daily Drop's because it is barely oversized and not rotated
/// — and the sheet's aspect matches that box exactly, so Figma's `object-cover`
/// crops nothing and the whole sheet shows.
const RitualCardTexture kWeeklyBundleCardTexture = RitualCardTexture(
  asset: kSokoWeeklyBundleCardTexture,
  rect: Rect.fromLTWH(-0.00001, -0.07981, 1.00065, 1.16179),
);

/// A card colour pairing: flat [field], accent [band] (the wordmark's middle
/// band and the outer frame), and [ink] for the letterform core, rules and copy.
class DailyDropCardPalette {
  const DailyDropCardPalette(this.name, this.field, this.band, this.ink);

  final String name;
  final Color field;
  final Color band;
  final Color ink;
}

/// The shipped pairing — the countdown frame `7204-21018` as drawn.
const DailyDropCardPalette kDailyDropCardPaletteDefault = DailyDropCardPalette(
  'blue/green',
  AppColors.sokoBlue,
  AppColors.sokoGreen,
  AppColors.sokoInk,
);

/// The Weekly Bundle's pairing — Figma `7285:24364`.
///
/// Field and band are the SAME yellow on purpose: the frame reads as a wider
/// margin rather than a contrasting mat, which is what the frame draws. Daily
/// Drop keeps its two-tone mat, so the two cards are told apart by colour and
/// by the rule style, not by structure.
const DailyDropCardPalette kWeeklyBundleCardPalette = DailyDropCardPalette(
  'yellow',
  AppColors.sokoYellow,
  AppColors.sokoYellow,
  AppColors.sokoInk,
);

/// Grey pairing for the terminal failure state — Zé, 2026-08-09: *"the failure
/// card can be in grey tones instead of the colored version"*. Same layout, no
/// colour: a spent card, visibly not one that is still working.
const DailyDropCardPalette kDailyDropCardPaletteSpent = DailyDropCardPalette(
  'grey',
  AppColors.sokoShade5,
  // sokoShade45 sits too close to the sokoShade5 field — the outer frame
  // disappeared against it. sokoShade4 is the first token with enough
  // separation to still read as a frame.
  AppColors.sokoShade4,
  AppColors.sokoShade2,
);

/// Shared shell: coloured frame → flat field → dashed inset → content.
class _DailyDropStatusCard extends StatelessWidget {
  const _DailyDropStatusCard({
    required this.palette,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
  });

  final DailyDropCardPalette palette;
  final String title;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();
    final now = DateTime.now();

    final card = DailyDropCardShell(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          // The lockup leads, as in both PROD-3438 frames. Sized by its
          // own `FittedBox(fitWidth)` rather than a flex share: a fixed
          // share left a dead band under it, because the lockup's height
          // is set by its aspect at this width, not by what it's given.
          DailyDropWordmark(bandColor: palette.band, inkColor: palette.ink),
          // Absorbs whatever the lockup didn't take, and keeps the copy
          // optically centred in the gap rather than pinned to the top.
          //
          //
          // Do NOT wrap this in `FittedBox` as an overflow guard — tried
          // it, and it unbounds the width, which `AutoSizeText` cannot
          // lay out against: the whole copy block silently disappeared.
          // `AutoSizeText`'s own `minFontSize` IS the shrink mechanism
          // here (down to 12/9 pt), which is what keeps a long locale
          // string or large-font scaling inside the card.
          Expanded(
            child: Center(
              child: _StatusCopy(
                title: title,
                subtitle: subtitle,
                color: palette.ink,
                trailing: trailing,
              ),
            ),
          ),
          const SizedBox(height: 6),
          RitualCardDottedRule(color: palette.ink),
          const SizedBox(height: 6),
          _DateRow(date: now, locale: locale, color: palette.ink),
        ],
      ),
    );

    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: card,
      ),
    );
  }
}

/// The card frame every non-photo Daily Drop state shares: coloured mat →
/// flat field → dashed inset → content.
///
/// Extracted from [_DailyDropStatusCard] when the **ready** state stopped being
/// a photo card and became a third user of the same frame. The 399 × 213
/// footprint is the load-bearing part — every state must hold it so the shelves
/// below never move as the drop resolves.
class DailyDropCardShell extends StatelessWidget {
  const DailyDropCardShell({
    super.key,
    required this.palette,
    required this.child,
    this.border = RitualCardBorder.dashed,
    this.texture = kDailyDropCardTexture,
  });

  final DailyDropCardPalette palette;
  final Widget child;

  /// The printed grain. Defaults to the Daily Drop's sheet; the Weekly Bundle
  /// passes its own, because the two frames use different paper AND place it
  /// differently — see [RitualCardTexture].
  final RitualCardTexture texture;

  /// Which inset rule to draw. Daily Drop is dashed, the Weekly Bundle dotted
  /// — the one thing that tells the two ritual cards apart at a glance beyond
  /// their colour.
  final RitualCardBorder border;

  /// Mat thickness. See the note at the call site.
  static const double _frameWidth = 8;

  /// The solid ink outline around the field, and the field's own corner. Both
  /// measured off `7265:23219`: the outline is ~4/1406 of the card width, and
  /// the field's corners are visibly tighter than the mat's 10.
  static const double _fieldStroke = 1.5;
  static const double _fieldRadius = 6;

  /// The card's outer corner. Named because the texture overlay has to clip to
  /// the same curve the mat draws — two literals here and the grain would
  /// square off the corners the mat rounds.
  static const double _cardRadius = 10;

  @override
  Widget build(BuildContext context) {
    return AspectRatio(
      aspectRatio: 399 / 213,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(_cardRadius),
        child: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            _field(),
            // The printed grain, over EVERYTHING — mat, field, inset rule and
            // content alike, exactly as Figma stacks it (`7675:37837`: the
            // texture is the frame's last child). Putting it under the content
            // instead would be the tempting "keep the copy crisp" version and
            // is wrong here: the card is meant to look like ink printed ON
            // this paper, and at 40 % Hard Light the ink barely moves anyway.
            IgnorePointer(
              child: BlendMask(
                blendMode: BlendMode.hardLight,
                opacity: kSokoRitualCardTextureOpacity,
                child: LayoutBuilder(
                  builder: (context, constraints) => Stack(
                    // Clips the overhang to the card, and keeps the blend's
                    // own save-layer to the card's bounds while it does.
                    clipBehavior: Clip.hardEdge,
                    children: <Widget>[
                      Positioned(
                        left: texture.rect.left * constraints.maxWidth,
                        top: texture.rect.top * constraints.maxHeight,
                        width: texture.rect.width * constraints.maxWidth,
                        height: texture.rect.height * constraints.maxHeight,
                        // `fill`, not `cover`: the rect IS the sheet's own
                        // rect, so there is nothing left to crop — and the
                        // Daily Drop's scale is slightly non-uniform, which no
                        // `BoxFit` value reproduces. The rect carries it.
                        child: RotatedBox(
                          quarterTurns: texture.quarterTurns,
                          child: sokoTextureImage(texture.asset),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Mat → field → inset rule → content. Everything except the grain above it.
  Widget _field() {
    return Container(
      // The frame is a MAT, not a hairline. Measured off `7204-22437`:
      // ~14 px of green on a 710-px-wide render ≈ 2 % of card width, so
      // ~8 px at our 399. The first pass used 3 px and read as a thin
      // outline round a blue card instead of a card sitting on a green
      // mat — Zé, 2026-08-09: *"the outer outline must be thicker"*.
      decoration: BoxDecoration(
        color: palette.band,
        borderRadius: BorderRadius.circular(10),
      ),
      padding: const EdgeInsets.all(_frameWidth),
      child: Container(
        // **The solid outline, and it is a separate line from the dashed
        // one.** `7265:23219` draws BOTH: a continuous ink rule at the
        // field's edge, and the dashed/dotted rule inset inside it. Shipping
        // only the dashed one left the field bleeding into the mat with no
        // edge — Zé, 2026-08-27: *"they are both lacking a full line
        // border"*.
        decoration: BoxDecoration(
          color: palette.field,
          borderRadius: BorderRadius.circular(_fieldRadius),
          border: Border.all(color: palette.ink, width: _fieldStroke),
        ),
        // Gap between the solid edge and the inset rule. Measured off the
        // frame at ~20/1406 of the width ≈ 5.7 px at our 399.
        padding: const EdgeInsets.all(5),
        child: CustomPaint(
          painter: _DashedRectPainter(color: palette.ink, border: border),
          child: Padding(
            // 8 + 1.5 + 5 + 11 ≈ 25 per side. Was 24 before the solid
            // outline; the lockup is a `FittedBox`, so it absorbs the 1.5.
            padding: const EdgeInsets.fromLTRB(11, 9, 11, 8),
            child: child,
          ),
        ),
      ),
    );
  }
}

/// The **ready** Daily Drop card — Figma `7285:24358`.
///
/// Replaces the photo card (`DiscoveryImageTemplateCard` + cover image + title
/// + byline) that the ready state used to render, so all three Daily Drop
/// states now share one frame and one palette instead of the resolved state
/// looking like a different product from the two that precede it.
///
/// Two deliberate departures from the frame, both from Zé (2026-08-27):
///
/// * **no countdown pill.** The frame shows `4h 35m 36s` between the header and
///   the lockup; we drop it and let the lockup take the whole remaining column.
///   PROD-3438 owns the countdown and is parked.
/// * **the colour comes from the palette the other status cards already use**,
///   not from the frame's lavender/pink. One rule for every non-photo state.
///
/// Note the layout is the *inverse* of [_DailyDropStatusCard]: there the lockup
/// leads and the date closes; here the date leads (now carrying the Soko
/// wordmark) and the lockup sits at the foot of what is left.
class DailyDropReadyCard extends StatelessWidget {
  const DailyDropReadyCard({
    super.key,
    required this.date,
    this.palette = kDailyDropCardPaletteDefault,
    this.onTap,
  });

  /// The drop's own date, not `DateTime.now()` — a drop opened after midnight
  /// still belongs to the day it was generated for.
  final DateTime date;
  final DailyDropCardPalette palette;
  final VoidCallback? onTap;

  /// Extra inset on the lockup, over and above what [DailyDropCardShell]
  /// already pads, so the wordmark sits the SAME distance from the left, the
  /// right and the bottom edge of the card (Zé, 2026-09-01).
  ///
  /// The frame (`7675:37837`, 350 wide) puts the wordmark's ink 27.6 from the
  /// left, 27.1 from the right and 27.7 from the bottom — one number, three
  /// sides. Scaled to our 399-wide card that is **31.3**; the shell already
  /// pads 25.5 horizontally and 22.5 at the foot, so the remainder is what
  /// these two constants carry.
  ///
  /// Held as the *remainder* rather than as the total because the shell owns
  /// the mat, the field stroke and the rule gap, and it is the one that should
  /// keep owning them — a total here would be a second, silently-drifting
  /// statement of the shell's own geometry. `daily_drop_card_polish_test.dart`
  /// measures the three gaps off the rendered card instead of trusting either.
  static const double _lockupSideInset = 5.8;
  static const double _lockupBottomInset = 8.8;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).toString();

    final card = DailyDropCardShell(
      palette: palette,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          RitualCardHeaderRow(date: date, locale: locale, color: palette.ink),
          // Everything the header did not take, with the lockup at the FOOT of
          // it rather than centred in it (Zé, 2026-09-01: *"push the daily drop
          // text to not be vertically centered on the space available"*).
          // Centring left a wide band of empty field under the wordmark and a
          // narrow one over it, which read as a mis-set card.
          //
          // `Align` rather than a `Column` with a `Spacer`: the lockup is a
          // `FittedBox`, so it takes the height its aspect implies at this
          // width and nothing here should be trying to predict that height.
          Expanded(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(
                  left: _lockupSideInset,
                  right: _lockupSideInset,
                  bottom: _lockupBottomInset,
                ),
                child: DailyDropWordmark(
                  bandColor: palette.band,
                  inkColor: palette.ink,
                  // The title flies up into the drop detail's header on open.
                  heroTag: dailyDropWordmarkHeroTag,
                ),
              ),
            ),
          ),
        ],
      ),
    );

    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: card,
      ),
    );
  }
}

/// `Mar. 19` · Soko · `2026` — the header strip both ritual cards lead with.
///
/// Same shape as the editorial overlay's header (`_editorial_overlay.dart`) and
/// the same recoloured SVG, but it lives here rather than being shared: that
/// one is absolutely positioned inside a 399x213 template at fractional
/// offsets, and this one is the first row of a `Column`.
class RitualCardHeaderRow extends StatelessWidget {
  const RitualCardHeaderRow({
    super.key,
    required this.date,
    required this.locale,
    required this.color,
  });

  final DateTime date;
  final String locale;
  final Color color;

  /// Matches `_DateRow`, so the header reads at the same weight as the footer
  /// it replaces.
  static const double _fontSize = 13;

  @override
  Widget build(BuildContext context) {
    final style = AppTheme.body(
      fontSize: _fontSize,
      fontWeight: FontWeight.w500,
      color: color,
      height: 1.0,
    );
    return Row(
      children: <Widget>[
        Expanded(
          child: Text(
            '${formatMonthAbbr(date, locale)}. ${date.day}',
            textAlign: TextAlign.left,
            style: style,
          ),
        ),
        // Explicit height: without it the SVG falls back to its intrinsic
        // 1619 px width and blows the Row apart.
        SvgPicture.asset(
          'assets/images/logos/soko-logo-paper.svg',
          height: _fontSize * 1.25,
          fit: BoxFit.contain,
          colorFilter: ColorFilter.mode(color, BlendMode.srcIn),
        ),
        Expanded(
          child: Text(
            DateFormat('y', locale).format(date),
            textAlign: TextAlign.right,
            style: style,
          ),
        ),
      ],
    );
  }
}

/// `Ago. 9` … `2026`, the footer row of `7204-22437`.
///
/// `formatMonthAbbr` capitalises in every locale as of PROD-3439 — do not
/// re-add a local title-caser (`docs/learnings/intl-mmm-pt-pt-trailing-dot.md`).
class _DateRow extends StatelessWidget {
  const _DateRow({
    required this.date,
    required this.locale,
    required this.color,
  });

  final DateTime date;
  final String locale;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final style = AppTheme.body(
      fontSize: 13,
      fontWeight: FontWeight.w500,
      color: color,
      height: 1.0,
    );
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: <Widget>[
        Text('${formatMonthAbbr(date, locale)}. ${date.day}', style: style),
        Text(DateFormat('y', locale).format(date), style: style),
      ],
    );
  }
}

/// Headline over a supporting line, left-aligned under the lockup.
class _StatusCopy extends StatelessWidget {
  const _StatusCopy({
    required this.title,
    required this.color,
    this.subtitle,
    this.trailing,
  });

  final String title;
  final Color color;

  /// Null on the generating card — Zé, 2026-08-10: *"the text 'Pode demorar
  /// alguns minutos. Toca … pronto.' can be removed. We just need the
  /// 'Estamos a encontrar algo para ti' and we want to show the loading three
  /// dots centered."* With no subtitle the [trailing] indicator centres under
  /// the headline instead of sitting beside a line of copy.
  ///
  /// Note this also drops the card's "a few minutes" expectation and its
  /// "tap to be notified" hint. Both still appear in the sheet the card opens;
  /// the card itself is now headline-only by design, so the tap is an
  /// undiscoverable affordance on purpose.
  final String? subtitle;

  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final titleText = AutoSizeText(
      title,
      maxLines: 2,
      minFontSize: 12,
      stepGranularity: 1,
      overflow: TextOverflow.ellipsis,
      textAlign: subtitle == null ? TextAlign.center : TextAlign.start,
      style: AppTheme.body(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: color,
        height: 1.1,
      ),
    );

    if (subtitle == null) {
      return Column(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          titleText,
          if (trailing != null) ...<Widget>[
            const SizedBox(height: 10),
            trailing!,
          ],
        ],
      );
    }

    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        titleText,
        const SizedBox(height: 3),
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Flexible(
              child: AutoSizeText(
                subtitle!,
                maxLines: 2,
                minFontSize: 9,
                stepGranularity: 1,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.body(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w300,
                  color: color,
                  height: 1.2,
                ),
              ),
            ),
            if (trailing != null) ...<Widget>[
              const SizedBox(width: 8),
              trailing!,
            ],
          ],
        ),
      ],
    );
  }
}

/// "Soko is picking your Daily Drop" — rendered while `isGenerating`.
///
/// Replaces the `SizedBox.shrink()` the section used to return, which left an
/// on-demand user staring at a feed with no Daily Drop and no explanation.
class DailyDropGeneratingCard extends StatelessWidget {
  const DailyDropGeneratingCard({
    super.key,
    required this.title,
    this.onTap,
    this.palette = kDailyDropCardPaletteDefault,
  });

  final String title;

  /// Null on web, where there is no push to offer, so the card is inert.
  final VoidCallback? onTap;

  /// Kept as a parameter so PROD-3438 can restyle these states without
  /// reopening the widget.
  final DailyDropCardPalette palette;

  @override
  Widget build(BuildContext context) {
    return _DailyDropStatusCard(
      palette: palette,
      title: title,
      onTap: onTap,
      trailing: _WorkingDots(color: palette.ink),
    );
  }
}

/// "We couldn't find one today" — rendered on `DailyDropState.hasTimedOut`.
///
/// No retry control by design (Decision 15): re-running costs a full LLM
/// pipeline on a ticket whose umbrella exists to cut that cost, and a task
/// that hit Celery's `soft_time_limit` will likely hit it again. If the task
/// does finish server-side, the existing `daily_drop_ready` push still fires.
class DailyDropTimedOutCard extends StatelessWidget {
  const DailyDropTimedOutCard({
    super.key,
    required this.title,
    required this.subtitle,
    this.onTap,
    this.palette = kDailyDropCardPaletteSpent,
  });

  final String title;
  final String subtitle;

  /// Tappable for the same reason the generating card is — Zé, 2026-08-10:
  /// *"when the daily drop generation fails we want it to have similar
  /// behavior when users with notifications disabled click it"*. The promise
  /// differs, though: today's drop is not coming, so the sheet offers to tell
  /// them about **tomorrow's**. Null on web, where there is no push to offer.
  final VoidCallback? onTap;

  /// Kept as a parameter so PROD-3438 can restyle these states without
  /// reopening the widget.
  final DailyDropCardPalette palette;

  @override
  Widget build(BuildContext context) {
    return _DailyDropStatusCard(
      palette: palette,
      title: title,
      subtitle: subtitle,
      onTap: onTap,
    );
  }
}

/// The dashed rectangle inset from the coloured frame, as in both PROD-3438
/// frames.
///
/// Not `SokoDottedRule` (PROD-3439): that draws a horizontal run of dots, and
/// this is a dashed rounded rectangle. Same visual family, different shape.
class _DashedRectPainter extends CustomPainter {
  _DashedRectPainter({required this.color, required this.border});

  final Color color;
  final RitualCardBorder border;

  static const double _radius = 4;

  /// Daily Drop's rule is a **two-beat pattern — short dash, long dash** — not
  /// a uniform one (Zé, 2026-08-27). Uniform dashes read as a generic border;
  /// the alternation is what makes it look like a ticket stub.
  ///
  /// The pattern repeats every `short + gap + long + gap`, so it does not
  /// divide evenly into the perimeter and the two ends meet mid-beat at the
  /// start corner. That is fine at this scale and is why the cycle is not
  /// phase-aligned to the corners.
  static const double _dashShort = 2.5;
  static const double _dashLong = 7;
  static const double _dashGap = 3.4;
  static const double _dashStroke = 1.2;

  /// Dots are drawn as zero-length round-capped strokes, so the cap IS the dot
  /// and its diameter is the stroke width — thinner dots mean a thinner stroke,
  /// nothing else. Pitch tightens with them so the rule keeps its density
  /// rather than thinning out into a sparse line.
  static const double _dotStroke = 1.4;
  static const double _dotPitch = 4;

  @override
  void paint(Canvas canvas, Size size) {
    final dotted = border == RitualCardBorder.dotted;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeCap = dotted ? StrokeCap.round : StrokeCap.butt
      ..strokeWidth = dotted ? _dotStroke : _dashStroke;

    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      const Radius.circular(_radius),
    );
    for (final metric in (Path()..addRRect(rrect)).computeMetrics()) {
      var d = 0.0;
      // Flips every dash so the short/long beats alternate around the whole
      // perimeter, corners included.
      var long = false;
      while (d < metric.length) {
        if (dotted) {
          // `extractPath(d, d)` is empty and draws nothing, so take the
          // shortest real segment and let the round cap do the work.
          canvas.drawPath(metric.extractPath(d, d + 0.01), paint);
          d += _dotPitch;
        } else {
          final end = (d + (long ? _dashLong : _dashShort)).clamp(
            0.0,
            metric.length,
          );
          canvas.drawPath(metric.extractPath(d, end), paint);
          d = end + _dashGap;
          long = !long;
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DashedRectPainter old) =>
      old.color != color || old.border != border;
}

/// The ritual cards' hairline dotted rule — the horizontal run of dots that
/// separates one band of a card from the next.
///
/// Two callers, and they want the same rule for the same reason: the Daily Drop
/// status card sets it above its date row, and the Weekly Bundle sets it between
/// the thumbnail strip and the lockup (Figma `7675:37875` — a 0.877-wide stroke
/// with `stroke-dasharray: 0.06 3` and a round cap, i.e. dots, not dashes).
///
/// Public so the Weekly Bundle can reach it. It stays *here* rather than moving
/// to `shared/widgets/` because it is a ritual-card part, sized and weighted for
/// this frame — the design system's general-purpose rule is `ScallopDivider`.
class RitualCardDottedRule extends StatelessWidget {
  const RitualCardDottedRule({super.key, required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
    height: 2,
    child: CustomPaint(
      painter: _DottedRulePainter(color: color),
      size: Size.infinite,
    ),
  );
}

class _DottedRulePainter extends CustomPainter {
  _DottedRulePainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = color;
    const r = 0.9;
    const step = r * 2 + 2.6;
    final cy = size.height / 2;
    for (double cx = r; cx <= size.width; cx += step) {
      canvas.drawCircle(Offset(cx, cy), r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DottedRulePainter old) => old.color != color;
}

/// Three softly pulsing dots — the only motion on the card.
///
/// Deliberately a looping animation rather than a `CircularProgressIndicator`:
/// generation is p50 ~15 s but p99 ~70 s, and a spinner at that duration reads
/// as a hang.
///
/// **Testing note:** this repeats forever, so `pumpAndSettle()` on a tree
/// containing this widget never returns. Use `pump(Duration(...))`.
class _WorkingDots extends StatefulWidget {
  const _WorkingDots({required this.color});

  final Color color;

  @override
  State<_WorkingDots> createState() => _WorkingDotsState();
}

class _WorkingDotsState extends State<_WorkingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1100),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List<Widget>.generate(3, (i) {
            // Each dot trails the previous by a fifth of the cycle.
            final phase = (_controller.value - i * 0.18) % 1.0;
            // Triangle wave: brightest at the midpoint of this dot's slot.
            final t = phase < 0.5 ? phase * 2 : (1 - phase) * 2;
            return Padding(
              padding: EdgeInsets.only(right: i == 2 ? 0 : 4),
              child: Opacity(
                opacity: 0.25 + 0.75 * t,
                child: Container(
                  width: 5,
                  height: 5,
                  decoration: BoxDecoration(
                    color: widget.color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}
