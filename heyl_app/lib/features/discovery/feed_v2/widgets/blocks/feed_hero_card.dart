// PROD-4006 — one `event_hero` card. Figma `7304-23446` (400 × 500).
//
// A poster filling the content column, with everything else laid over its
// bottom edge: eyebrow, title, short description, three meta lines and the
// save / like / dislike cluster. The block carries `items`, so the v0 layout
// draws **two** of these stacked (`feed_layout.py`, `count=2`).
//
// "Content column", not "screen": Figma's 400 px hero frame is the column
// against a 430 px viewport, and `FeedPageContent` supplies the 15 px margin
// for the whole page. This card adds no horizontal inset of its own.

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/theme/app_colors.dart';
import '../../../../../shared/widgets/soko_card_image.dart';
import '../../../../../core/theme/app_theme.dart';
import '../../../../../core/utils/feed_event_date.dart';
import '../../../../../data/models/discovery_engagement.dart';
import '../../../../../data/models/entity_signal.dart';
import '../../../../../data/models/feed_home.dart';
import '../../../../../providers/api_provider.dart';
import '../../../../../l10n/generated/l10n.dart';
import '../../../../../shared/widgets/cached_image.dart';
import '../../../../../shared/widgets/impression_detector.dart';
import '../../../../../shared/widgets/soko_overlay_toggle.dart';
import '../../../../../shared/widgets/soko_toggle_glyph.dart';
import '../../../../../shared/widgets/clickable.dart';
import '../../../../../shared/widgets/notched_edge.dart';
import '../../../../entity_signals/providers/signal_controller.dart';
import '../../utils/feed_item_save.dart';
import 'feed_block_atoms.dart';

/// Notch diameter on the hero, from `7304:23768` (Ø12 on a 400 px card).
const double kHeroNotchDiameter = 12;

/// Inset at each end of the notch strip — 7 px on the frame's 400 px card,
/// leaving the 386 px run the design distributes 18 circles across.
const double kHeroNotchInset = 7;

class FeedHeroCard extends ConsumerWidget {
  final FeedEventItem item;

  /// The block's eyebrow, drawn on the **first card only**.
  ///
  /// It belongs to the block, not the item (`hero-lead` carries "Em destaque",
  /// `hero-tail` carries nothing), so repeating it above every card in a
  /// two-item block would claim each one is separately featured.
  final String? eyebrow;

  /// Opens the card's entity (PROD-4076). Null leaves the card inert.
  ///
  /// **The card body only** — the save / like / dislike buttons sit on the
  /// overlay as children of this card and win the hit test, so they keep
  /// acting rather than navigating.
  final VoidCallback? onTap;

  const FeedHeroCard({super.key, required this.item, this.eyebrow, this.onTap});

  /// Frame height. Fixed rather than aspect-derived: the poster is a `cover`
  /// crop of whatever the source supplied, so the card must define the box.
  static const double cardHeight = 500;

  /// Gaussian sigma for the scrim's blur, at full effect.
  ///
  /// Figma declares `backdrop-blur: 20` on the content overlay (`7304:23466`).
  /// CSS `blur()` and `ImageFilter.blur` both take a standard deviation, so the
  /// number carries over as-is. Tunable — it is a strong blur by design (in the
  /// frame the poster's lineup text behind the scrim is fully illegible).
  static const double scrimBlurSigma = 20;

  /// Foot of the darkening ramp, at full effect.
  ///
  /// **Figma stops at 50 %** (`rgba(0,0,0,0.5)`), which the card already
  /// matched. Going deeper is a deliberate divergence for legibility over
  /// bright, busy posters — see D282.
  ///
  /// Eased back from 65 % to 55 % (Zé, 2026-08-28): 65 read as too heavy once
  /// the ramp was lengthened, and the longer runway does some of the work the
  /// extra darkness was doing. Still above the frame's 50 %, so the legibility
  /// divergence survives — this is the knob to nudge, and the ramp's *length*
  /// is the other one.
  static const Color scrimFoot = Color(0x8C000000); // 55 %

  /// Top padding of the scrim's content box, and therefore where the first
  /// line of copy starts. Figma's own `pt` on `7304:23466`.
  static const double _contentTopPadding = 60;

  /// How far above the first line of copy the effect must already be at full
  /// strength.
  ///
  /// **Zero — the ramp lands exactly on the copy** (Zé, 2026-08-28, lowering
  /// the end by 15 from the 15 px clearance it shipped with). The start does
  /// not move, so dropping the finish 15 px lengthens the transition by the
  /// same 15 rather than sliding it down: a longer, gentler fade that is at
  /// full strength precisely where the text begins.
  ///
  /// Raising this again shortens the ramp from the bottom; see
  /// [_contentTopPadding] for the other lever, which lengthens it from the top.
  static const double _fullEffectGapAboveText = 0;

  /// Distance from the scrim's top edge at which blur and darkening reach full
  /// strength. Everything above this is the transition; everything below holds.
  ///
  /// Derived rather than typed, so moving [_contentTopPadding] keeps
  /// [_fullEffectGapAboveText]'s promise instead of silently breaking it.
  /// Lengthening that padding is also the lever for a *longer* transition — it
  /// is the ramp's whole runway.
  static const double _fullEffectTop =
      _contentTopPadding - _fullEffectGapAboveText;

  /// Bottom-only, 6 px — the top edge is square because the scallop sits on it.
  static final BorderRadius _radius = const BorderRadius.only(
    bottomLeft: Radius.circular(6),
    bottomRight: Radius.circular(6),
  );

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return RepaintBoundary(
      // The scrim paints the poster a second time through a blur and a mask,
      // and the v0 layout puts four of these on a page. Nothing inside a card
      // changes while the feed scrolls, so caching the card's layer means the
      // scroll moves it rather than re-running the filter every frame.
      //
      // ⚠️ Not a substitute for measuring. The blur is the most expensive thing
      // on this page and web (CanvasKit/Skwasm) is where it will show first.
      child: Clickable(
        onTap: onTap,
        child: SizedBox(
          height: cardHeight,
          // `7304:23768` — half-circle notches bitten out of the card's top edge,
          // replacing the scallop wave this card used to carry. The frame draws
          // 18 circles of Ø12 at a 22 px pitch across a 386 px strip inset 7 px
          // inside the 400 px card; only the Ø and the inset are fixed here, and
          // the count and gap fit whatever width the card actually gets, so the
          // treatment survives a tablet without becoming a different one.
          //
          // **The card's whole shape is cut in one pass**, notches and bottom
          // corners together. That is why neither the poster nor this `Stack`
          // clips any more: two clips cannot make one shape, and the corner clip
          // would round a rectangle the notch clip had already bitten into.
          child: NotchedTopEdgeClip(
            diameter: kHeroNotchDiameter,
            horizontalInset: kHeroNotchInset,
            borderRadius: _radius,
            child: Stack(
              // Nothing overhangs, and the clip above already bounds the card, so
              // the Stack does not need a clip layer of its own.
              clipBehavior: Clip.none,
              children: [
                Positioned.fill(child: _posterImage()),
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _overlay(context, ref),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// The bare image, shared by the sharp poster and the blurred copy the scrim
  /// lays over it. Same widget, same `BoxFit.cover` crop, and the provider is
  /// shared — so the second layer is a second *paint*, not a second fetch.
  Widget _posterImage() => CachedImage(
    imageUrl: item.imageUrl ?? '',
    fit: BoxFit.cover,
    // A poster that will not load leaves the card standing — the copy and
    // controls are legible on the scrim either way, and dropping the card
    // would be the client inventing a policy the backend did not ask for.
    // The floor is the event brand colour (not flat grey) so a slow photo
    // reveals over the type colour instead of popping from a grey block.
    placeholder: ColoredBox(color: SokoEntityKind.event.floorColor),
    errorWidget: ColoredBox(color: SokoEntityKind.event.floorColor),
  );

  /// The bottom scrim and everything on it.
  ///
  /// **The effect ramps in; it does not switch on.** Zero effect at this box's
  /// top edge, reaching full [scrimBlurSigma] and [scrimFoot] at
  /// [_fullEffectTop] — which is [_fullEffectGapAboveText] above the first line
  /// of copy, i.e. exactly on it — and holding it from there down. Shipping a uniform blur (which
  /// is what the Figma node literally declares) put a hard sharp-to-blurred
  /// seam straight across the poster; Zé, 2026-08-27, after seeing it on the
  /// feed. The ramp is a deliberate divergence from the frame.
  ///
  /// **Why not `BackdropFilter`.** It cannot be gradient-masked — it filters
  /// whatever is behind it, uniformly, and there is no per-pixel alpha to hand
  /// it. Approximating a ramp with it means N stacked banded filters. The only
  /// thing behind this scrim is the poster, so the cheaper and exact route is
  /// to paint the poster a **second time**, blurred, and mask that copy with
  /// the ramp. [_posterImage] is shared, so it is a second paint, not a second
  /// fetch.
  ///
  /// **Why the copy is not simply sized to this box.** It has to show the same
  /// pixels the sharp poster shows underneath, and a `BoxFit.cover` crop into
  /// a short box is a *different* crop. `OverflowBox` re-imposes the full card
  /// height and bottom-aligns it, so both layers crop identically and the blur
  /// registers with the image behind it.
  ///
  /// Height is content-dependent, so the effect is anchored to the copy rather
  /// than to a fixed fraction of the 500 px card: a three-line title lengthens
  /// the treated region instead of overflowing it. Both ramps read their stops
  /// from the box they are actually painted into, which is why the shader and
  /// the painter take a `Rect`/`Size` rather than a constant fraction.
  Widget _overlay(BuildContext context, WidgetRef ref) {
    return ClipRRect(
      borderRadius: _radius,
      child: Stack(
        children: [
          // The blurred copy, faded in across the ramp. `dstIn` keeps the
          // destination (the blurred poster) only where the mask is opaque.
          Positioned.fill(
            child: ShaderMask(
              blendMode: BlendMode.dstIn,
              shaderCallback: _rampShader,
              child: ImageFiltered(
                imageFilter: ImageFilter.blur(
                  sigmaX: scrimBlurSigma,
                  sigmaY: scrimBlurSigma,
                  // The scrim is flush with the card's bottom and side edges,
                  // so without clamping the filter samples transparent black
                  // from beyond them and leaves a washed-out rim.
                  tileMode: TileMode.clamp,
                ),
                child: OverflowBox(
                  alignment: Alignment.bottomCenter,
                  minHeight: cardHeight,
                  maxHeight: cardHeight,
                  child: _posterImage(),
                ),
              ),
            ),
          ),
          // The darkening, on the SAME ramp. Two ramps that disagree read as a
          // smudge rather than as one effect, so both are derived from
          // [_fullEffectTop] and neither carries its own stops.
          CustomPaint(
            painter: const _ScrimDarkening(foot: scrimFoot),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(
                20,
                _contentTopPadding,
                20,
                20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                spacing: 12,
                children: [
                  if (eyebrow != null && eyebrow!.isNotEmpty)
                    _eyebrow(eyebrow!),
                  _title(),
                  if (item.descriptionShort != null &&
                      item.descriptionShort!.isNotEmpty)
                    _description(item.descriptionShort!),
                  _metaAndActions(context, ref),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Mask for the blurred copy: transparent at the scrim's top edge, opaque
  /// from [_fullEffectTop] down.
  ///
  /// Stops come from `bounds` rather than being constants because the scrim's
  /// height follows its copy — a fixed fraction would put the ramp somewhere
  /// different on a three-line title than on a one-line one.
  static Shader _rampShader(Rect bounds) => rampGradient(
    from: const Color(0x00FFFFFF),
    to: const Color(0xFFFFFFFF),
    end: rampStopFor(bounds.height),
  ).createShader(bounds);

  /// How many stops approximate the eased curve. Twelve is past the point where
  /// the segments themselves are visible; the cost is a longer stop list, once,
  /// at paint time.
  static const int _rampSamples = 12;

  /// Smoothstep — `3t² − 2t³`. Its **slope is zero at both ends**, which is the
  /// whole point.
  ///
  /// A two-stop linear gradient is continuous in colour but not in its
  /// derivative, and the eye resolves that slope discontinuity as a hard line
  /// (Mach banding) exactly where the ramp reaches full strength. Zé saw it as
  /// "too abrupt at the end" on 2026-08-27. Easing in and out removes the
  /// crease without moving where the ramp starts or finishes.
  static double _ease(double t) => t * t * (3 - 2 * t);

  /// The scrim's ramp, as a multi-stop eased gradient from [from] to [to],
  /// reaching [to] at the [end] fraction and holding it below.
  ///
  /// **Both the blur mask and the darkening go through here.** Two ramps on
  /// different curves read as a smudge rather than as one effect, so there is
  /// deliberately no second way to build one.
  static LinearGradient rampGradient({
    required Color from,
    required Color to,
    required double end,
  }) => LinearGradient(
    begin: Alignment.topCenter,
    end: Alignment.bottomCenter,
    colors: <Color>[
      for (var i = 0; i <= _rampSamples; i++)
        Color.lerp(from, to, _ease(i / _rampSamples))!,
    ],
    stops: <double>[
      for (var i = 0; i <= _rampSamples; i++) end * i / _rampSamples,
    ],
  );

  /// Where the ramp reaches full strength, as a fraction of a scrim of
  /// [scrimHeight].
  ///
  /// **The blur mask and the darkening both call this**, which is what stops
  /// them drifting apart — two ramps that disagree read as a smudge rather than
  /// as one effect. It is public so the geometry can be tested directly: the
  /// promise is "full effect [_fullEffectGapAboveText] above the copy", and
  /// that is an arithmetic claim about this function, not something a widget
  /// test can see.
  static double rampStopFor(double scrimHeight) =>
      scrimHeight <= 0 ? 1.0 : (_fullEffectTop / scrimHeight).clamp(0.01, 1.0);

  /// Distance from the copy at which the effect is already at full strength.
  /// Exposed for the same reason as [rampStopFor].
  static double get fullEffectGapAboveText => _fullEffectGapAboveText;

  /// Where the scrim's first line of copy starts, from its top edge.
  static double get contentTopPadding => _contentTopPadding;

  /// Figma specifies **ABC ROM Compressed Medium**, which this app does not
  /// bundle and `docs/ui/design-tokens.md` does not list. Uppercase `Mobile/B2`
  /// with the frame's own +0.14 tracking is the substitution — recorded in
  /// `docs/ui/design-decisions.md` rather than adding a font for one label.
  Widget _eyebrow(String text) => Text(
    text.toUpperCase(),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: AppTheme.body(
      fontSize: 14,
      fontWeight: FontWeight.w500,
      color: AppColors.sokoPaper,
      height: 1.2,
    ).copyWith(letterSpacing: 0.14),
  );

  /// `Mobile/H1` — Season Mix 42, leading 0.9.
  Widget _title() => Text(
    item.title,
    maxLines: 3,
    overflow: TextOverflow.ellipsis,
    style: AppTheme.displayPrimary(
      fontSize: 42,
      color: AppColors.sokoPaper,
      height: 0.9,
    ),
  );

  Widget _description(String text) => Text(
    text,
    maxLines: 2,
    overflow: TextOverflow.ellipsis,
    style: AppTheme.body(
      fontSize: 14,
      fontWeight: FontWeight.w300,
      color: AppColors.sokoPaper,
      height: 1,
    ),
  );

  Widget _metaAndActions(BuildContext context, WidgetRef ref) {
    final category = item.category;
    final price = item.priceLabel;
    final hasCategory = category != null && category.isNotEmpty;
    final hasPrice = price != null && price.isNotEmpty;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        // `Expanded`, not the frame's fixed w218: a long venue name has to
        // ellipsize rather than run under the buttons.
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            spacing: 8,
            children: [
              FeedMetaLine(
                icon: LucideIcons.calendar,
                text: formatFeedEventDate(context, item),
                color: AppColors.sokoPaper,
              ),
              if (item.locationLine != null)
                FeedMetaLine(
                  icon: LucideIcons.map_pin,
                  text: item.locationLine!,
                  color: AppColors.sokoPaper,
                ),
              // Category and price share a line. Either can be absent, and the
              // separator belongs to the pair rather than to one of them — a
              // dangling "•" is the tell that it was attached to the wrong side.
              // Each half is `Flexible` so a long category yields to the price
              // rather than pushing it off the card. `FeedMetaLine` flexes its
              // own label, but that only helps once this Row hands the child a
              // bounded width to ellipsize against — without it the category
              // took its full intrinsic width and the row overflowed (measured
              // at 755 px with a real backend category string).
              if (hasCategory || hasPrice)
                Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: 10,
                  children: [
                    if (hasCategory)
                      Flexible(
                        child: FeedMetaLine(
                          icon: LucideIcons.move_right,
                          // Backend-localized display label, never a slug —
                          // render exactly as received, do not title-case.
                          text: category,
                          color: AppColors.sokoPaper,
                          expand: false,
                        ),
                      ),
                    if (hasCategory && hasPrice)
                      const FeedMetaSeparator(color: AppColors.sokoPaper),
                    if (hasPrice)
                      Flexible(
                        child: FeedMetaLine(
                          icon: LucideIcons.shopping_cart,
                          // Already formatted and localized by the backend
                          // (`price_label`) — never re-format from
                          // price_min/max.
                          text: price,
                          color: AppColors.sokoPaper,
                          expand: false,
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        _actions(context, ref),
      ],
    );
  }

  Widget _actions(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final key = (type: SignalEntityType.event, id: item.id);
    final signal = ref.watch(signalControllerProvider(key));
    final taste = signal.signal.taste;
    final saved = isFeedItemSaved(ref, item);

    // Read HERE, not after the await — `ref` may be deactivated by then. The
    // provider is keepAlive so the captured instance outlives the card.
    final tracker = ref.read(discoverySessionTrackerProvider);

    Future<void> tap(SignalAction action) async {
      final notifier = ref.read(signalControllerProvider(key).notifier);
      await notifier.apply(action);
      // Confirmed-only engagement action (contract v2): `apply` writes the
      // server-returned signal on success and restores the prior one on error,
      // so emit only when the confirmed taste equals the tapped one. A re-tap
      // that CLEARS a held thumb confirms with a different taste and emits
      // nothing — the action enum has no un-like/un-dislike.
      final SignalControllerState confirmed;
      try {
        confirmed = ref.read(signalControllerProvider(key));
      } catch (_) {
        return; // card unmounted while the mutation was in flight
      }
      // `mutating` too: a tap made while an earlier write is out returns from
      // `apply` as soon as it is queued, so this await can resolve with the
      // optimistic paint still standing. Reading that as confirmed would emit
      // an action the server has not answered yet; the settling call emits.
      if (confirmed.error != null || confirmed.mutating) return;
      final confirmedTaste = confirmed.signal.taste;
      final emits = switch (action) {
        SignalAction.like when confirmedTaste == SignalTaste.liked =>
          DiscoveryEngagementAction.like,
        SignalAction.dislike when confirmedTaste == SignalTaste.disliked =>
          DiscoveryEngagementAction.dislike,
        _ => null,
      };
      if (emits == null) return;
      // Exposure resolves first so it precedes the action in `seq` order
      // (contract v2).
      ImpressionDetector.resolveForItem(item.id, endReason: 'action');
      tracker.action(
        actionKind: emits,
        itemId: item.id,
        itemType: 'event',
        blockType: 'event_hero',
      );
    }

    // The poster's own chrome, and the only place that departs from the shared
    // widget's thumbnail defaults: 40 px on `Soko/Paper 30`, unblurred. A large
    // photo already reads as a scrim behind a paper tint, so the blur the
    // 30 px chips need to stay legible would only cost a saveLayer here.
    Widget toggle({
      required bool selected,
      required String semanticLabel,
      required VoidCallback onTap,
      required Widget Function(bool active, Color color) glyph,
      bool flip = false,
    }) => SokoOverlayToggle(
      selected: selected,
      semanticLabel: semanticLabel,
      onTap: onTap,
      glyph: glyph,
      flip: flip,
      size: 40,
      ground: SokoOverlayToggle.frostedPaper30,
      blurSigma: 0,
    );

    return Row(
      mainAxisSize: MainAxisSize.min,
      spacing: 6,
      children: [
        toggle(
          selected: saved,
          semanticLabel: l10n.feedHeroSaveA11y,
          onTap: () => openFeedItemSave(context, ref, item),
          glyph: (active, color) => SokoToggleGlyph.bookmarkChip(
            active: active,
            fillColor: color,
            lineColor: color,
          ),
        ),
        toggle(
          selected: taste == SignalTaste.liked,
          semanticLabel: l10n.feedHeroLikeA11y,
          onTap: () => tap(SignalAction.like),
          glyph: (active, color) => SokoToggleGlyph.thumbUp(
            active: active,
            height: 14,
            fillColor: color,
            lineColor: color,
          ),
        ),
        toggle(
          selected: taste == SignalTaste.disliked,
          semanticLabel: l10n.feedHeroDislikeA11y,
          onTap: () => tap(SignalAction.dislike),
          // 👎 is the 👍 glyph rotated 180°, not a second asset — the same
          // relationship the detail row and the chat/onboarding cards use.
          flip: true,
          glyph: (active, color) => SokoToggleGlyph.thumbUp(
            active: active,
            height: 14,
            fillColor: color,
            lineColor: color,
          ),
        ),
      ],
    );
  }
}

/// The scrim's darkening, on the same ramp as the blur mask.
///
/// A `BoxDecoration` gradient cannot express this: its stops are fractions, and
/// the scrim's height follows its copy, so a fraction would land the ramp in a
/// different place on a three-line title than on a one-line one. `paint` gets
/// the real `Size`, which is the whole reason this is a painter.
class _ScrimDarkening extends CustomPainter {
  const _ScrimDarkening({required this.foot});

  final Color foot;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final rect = Offset.zero & size;
    canvas.drawRect(
      rect,
      Paint()
        ..shader = FeedHeroCard.rampGradient(
          from: const Color(0x00000000),
          to: foot,
          end: FeedHeroCard.rampStopFor(size.height),
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(covariant _ScrimDarkening old) => old.foot != foot;
}
