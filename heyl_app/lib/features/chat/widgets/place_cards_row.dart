import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/event_timing_chip.dart';
import '../../../data/models/entity_signal.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/navigation/detail_siblings.dart';
import '../../../shared/widgets/clickable.dart';
import '../../../shared/widgets/soko_card_image.dart';
import '../../../shared/widgets/soko_turn_entrance.dart';
import '../../../shared/utils/suggestion_category_icon.dart';
import '../../../shared/widgets/soko_entity_card.dart';
import '../../../shared/widgets/soko_tag.dart';
import '../../entity_signals/providers/signal_controller.dart';

/// Horizontal carousel of recommendation cards (events, places, generic)
/// shown in chat replies. PROD-1894 unified mobile + desktop to a single
/// carousel layout (mobile used to be a vertical stack) and added an
/// optional "Show more" terminator card at the end.
class PlaceCardsRow extends StatelessWidget {
  final List<CardItem> items;
  final void Function(ItemSuggestion item, DetailSiblings siblings)? onTap;

  /// [position] is the card's index within this row (PROD-3209 —
  /// chat_card_dismissed analytics).
  final void Function(CardItem card, int position)? onDismiss;

  /// PROD-1894: when non-null, an extra "Show more" card is appended at
  /// the end of the carousel; tapping it invokes [onShowMore] (which
  /// should post a follow-up message in the conversation, e.g. "Show me
  /// more"). When null, no terminator is rendered.
  final VoidCallback? onShowMore;

  /// Portrait-poster sizing shared with the onboarding vibe cards, bumped a
  /// little for chat readability.
  static const double _cardWidth = 150;
  static const double _imageHeight = 200;

  const PlaceCardsRow({
    super.key,
    required this.items,
    this.onTap,
    this.onDismiss,
    this.onShowMore,
    this.animate = false,
  });

  /// When true, the cards reveal one at a time (staggered fade/slide) on this
  /// build — the first frame they appear for a turn. `false` renders them
  /// already settled (rebuilds, scroll-back). See [_cardStaggerStep].
  final bool animate;

  /// Delay between each card's entrance in the staggered first-time reveal.
  static const Duration _cardStaggerStep = Duration(milliseconds: 90);

  /// Wraps a card in its staggered entrance (delay grows with [index]).
  Widget _staggered(int index, Widget child) => SokoTurnEntrance(
    animate: animate,
    startDelay: _cardStaggerStep * index,
    beginOffset: const Offset(-0.06, 0),
    child: child,
  );

  /// Builds the swipe-siblings context for the card at [originalIndex],
  /// including only items with a navigable detail (event with eventId or
  /// place with venueId). Generic cards and items missing an id are
  /// excluded; the tapped item's position is remapped to its index in
  /// the filtered list.
  DetailSiblings _siblingsForTap(int originalIndex) {
    final filtered = <DetailSibling>[];
    int? mappedIndex;
    for (int i = 0; i < items.length; i++) {
      final item = items[i];
      final type = item.type;
      if (type != CardItemType.event && type != CardItemType.place) continue;
      final id = type == CardItemType.event ? item.eventId : item.venueId;
      if (id == null || id.isEmpty) continue;
      if (i == originalIndex) mappedIndex = filtered.length;
      filtered.add(
        DetailSibling(
          type: type == CardItemType.event
              ? DetailSiblingType.event
              : DetailSiblingType.place,
          id: id,
        ),
      );
    }
    return DetailSiblings(items: filtered, currentIndex: mappedIndex ?? 0);
  }

  /// Build the shared portrait-poster card for [item]. Place/event items with a
  /// navigable id get thumbs wired to the entity-signal controller (provenance
  /// `chat`); generic/idless items render the poster without thumbs.
  Widget _buildCard(CardItem item, int index) {
    final suggestion = item.toItemSuggestion();
    final tap = onTap != null
        ? () => onTap!(suggestion, _siblingsForTap(index))
        : null;

    final type = item.type;
    final signalId = type == CardItemType.event
        ? item.eventId
        : (type == CardItemType.place ? item.venueId : null);

    Widget card;
    if ((type == CardItemType.event || type == CardItemType.place) &&
        signalId != null &&
        signalId.isNotEmpty) {
      card = _ChatEntityCard(
        suggestion: suggestion,
        signalType: type == CardItemType.event
            ? SignalEntityType.event
            : SignalEntityType.venue,
        signalId: signalId,
        kind: type == CardItemType.event
            ? SokoEntityKind.event
            : SokoEntityKind.venue,
        width: _cardWidth,
        imageHeight: _imageHeight,
        onTap: tap,
      );
    } else {
      // Generic / idless items: no signal target, so no thumbs.
      card = SokoEntityCard(
        name: suggestion.name,
        subtitle: suggestion.locationSubtitle(),
        subcategoryLabel: suggestion.typeLabel,
        subcategoryIcon: suggestionCategoryIcon(suggestion),
        imageUrl: suggestion.imageUrl,
        seed: suggestion.id,
        kind: SokoEntityKind.neutral,
        onTap: tap,
        width: _cardWidth,
        imageHeight: _imageHeight,
      );
    }

    // Wrap with dismiss button if callback provided
    if (onDismiss == null) return card;

    return _DismissableCard(
      card: card,
      fixedWidth: _cardWidth,
      onDismiss: () => onDismiss!(item, index),
    );
  }

  /// The carousel header tag pill(s) — "Places" (Soko/Venue) and/or "Events"
  /// (Soko/Event) for the item types present, mirroring the onboarding vibe
  /// shelf's tag. Homogeneous carousels (the norm) show a single pill.
  Widget? _carouselTags(BuildContext context) {
    final l10n = Lt.of(context);
    final hasPlaces = items.any((i) => i.type == CardItemType.place);
    final hasEvents = items.any((i) => i.type == CardItemType.event);
    if (!hasPlaces && !hasEvents) return null;

    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasPlaces)
            SokoTag(
              background: AppColors.sokoVenue,
              child: Text(l10n.chatCardsTagPlaces, style: SokoTag.textStyle),
            ),
          if (hasPlaces && hasEvents) const SizedBox(width: 6),
          if (hasEvents)
            SokoTag(
              background: AppColors.sokoEvent,
              child: Text(l10n.chatCardsTagEvents, style: SokoTag.textStyle),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final isDesktop = screenWidth >= 768;

    // Max width cap of the scroll region. Desktop matches the content column;
    // on mobile it spans the available width so the peek-next-card behavior
    // works.
    final maxWidth = isDesktop ? screenWidth * 0.70 : screenWidth;
    final tags = _carouselTags(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (tags != null) tags,
        ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            // Vertical 8 keeps the _DismissableCard's top:-6 X-badge overflow
            // inside the viewport. Left 8 gives the first card breathing room
            // from the message column's edge instead of jamming against it.
            padding: const EdgeInsets.fromLTRB(8, 8, 0, 8),
            // IntrinsicHeight + CrossAxisAlignment.stretch lets the
            // _ShowMoreCard match the height of the poster cards next to it.
            child: IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (int i = 0; i < items.length; i++) ...[
                    _staggered(i, _buildCard(items[i], i)),
                    if (i < items.length - 1) const SizedBox(width: 12),
                  ],
                  if (onShowMore != null) ...[
                    const SizedBox(width: 16),
                    _staggered(items.length, _ShowMoreCard(onTap: onShowMore!)),
                    const SizedBox(width: 8),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A chat carousel poster wired to the entity-signal controller: watches the
/// current 👍/👎 taste and applies like/dislike with the `chat` provenance —
/// mirroring `signal_chips_section.dart` on the detail page.
class _ChatEntityCard extends ConsumerWidget {
  const _ChatEntityCard({
    required this.suggestion,
    required this.signalType,
    required this.signalId,
    required this.kind,
    required this.width,
    required this.imageHeight,
    this.onTap,
  });

  final ItemSuggestion suggestion;
  final SignalEntityType signalType;
  final String signalId;
  final SokoEntityKind kind;
  final double width;
  final double imageHeight;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final key = (type: signalType, id: signalId);
    final taste = ref.watch(signalControllerProvider(key)).signal.taste;

    void act(SignalAction action) => ref
        .read(signalControllerProvider(key).notifier)
        .apply(action, provenance: SignalProvenance.chat);

    return SokoEntityCard(
      name: suggestion.name,
      subtitle: suggestion.locationSubtitle(),
      subcategoryLabel: suggestion.typeLabel,
      subcategoryIcon: suggestionCategoryIcon(suggestion),
      imageUrl: suggestion.imageUrl,
      seed: signalId,
      kind: kind,
      taste: taste,
      dateChip: signalType == SignalEntityType.event
          ? chipForItemSuggestion(context, suggestion)
          : null,
      onLike: () => act(SignalAction.like),
      onDislike: () => act(SignalAction.dislike),
      onTap: onTap,
      width: width,
      imageHeight: imageHeight,
    );
  }
}

/// Wraps a card widget with an X dismiss button at the top-right
class _DismissableCard extends StatelessWidget {
  final Widget card;
  final double? fixedWidth;
  final VoidCallback onDismiss;

  const _DismissableCard({
    required this.card,
    required this.onDismiss,
    this.fixedWidth,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: fixedWidth,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          card,
          Positioned(
            top: -6,
            left: -6,
            // `Clickable` switches the web cursor to a pointer on hover
            // (bare GestureDetector leaves the default arrow).
            child: Clickable(
              onTap: onDismiss,
              child: Container(
                width: 22,
                height: 22,
                decoration: const BoxDecoration(
                  color: AppColors.sokoShade5,
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.close,
                  size: 14,
                  color: AppColors.sokoInk,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Terminator at the end of the carousel — a compact circular arrow
/// button with a "Show more" label below. No card chrome, no fixed width
/// (the column sizes to its content). Tapping triggers a follow-up
/// "Show me more" message in the conversation (PROD-1894).
class _ShowMoreCard extends StatefulWidget {
  final VoidCallback onTap;

  const _ShowMoreCard({required this.onTap});

  @override
  State<_ShowMoreCard> createState() => _ShowMoreCardState();
}

class _ShowMoreCardState extends State<_ShowMoreCard>
    with SingleTickerProviderStateMixin {
  bool _isPressed = false;
  bool _isHovered = false;

  // PROD-1894: one-shot tap animation — a scale pulse on the button plus
  // a 90° clockwise rotation of the arrow so it visually pivots to point
  // down, telegraphing the scroll-to-bottom about to happen. Returns to
  // resting state before invoking [widget.onTap].
  late final AnimationController _tapController;
  late final Animation<double> _tapScale;
  late final Animation<double> _arrowTurns;

  @override
  void initState() {
    super.initState();
    _tapController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 320),
    );
    _tapScale = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 0.88), weight: 1),
      TweenSequenceItem(
        tween: Tween(
          begin: 0.88,
          end: 1.0,
        ).chain(CurveTween(curve: Curves.easeOutBack)),
        weight: 2,
      ),
    ]).animate(_tapController);
    // Quarter turn down (pi/2 rad) and back, weighted so it lingers at the
    // bottom for a beat before springing back.
    _arrowTurns = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(
          begin: 0.0,
          end: math.pi / 2,
        ).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 2,
      ),
      TweenSequenceItem(
        tween: Tween(
          begin: math.pi / 2,
          end: 0.0,
        ).chain(CurveTween(curve: Curves.easeInCubic)),
        weight: 3,
      ),
    ]).animate(_tapController);
  }

  @override
  void dispose() {
    _tapController.dispose();
    super.dispose();
  }

  Future<void> _handleTap() async {
    setState(() => _isPressed = false);
    await _tapController.forward(from: 0);
    if (!mounted) return;
    widget.onTap();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final fgColor = isDark ? AppColors.sokoPaper : AppColors.sokoInk;
    final hoverPressScale = _isPressed ? 0.97 : (_isHovered ? 1.02 : 1.0);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _isPressed = true),
        onTapUp: (_) => _handleTap(),
        onTapCancel: () => setState(() => _isPressed = false),
        child: AnimatedScale(
          scale: hoverPressScale,
          duration: const Duration(milliseconds: 150),
          // No explicit size — sized by content. Parent Row's
          // IntrinsicHeight + CrossAxisAlignment.stretch makes the
          // column take the carousel's height; mainAxisAlignment.center
          // keeps the icon + label vertically centered.
          child: AnimatedBuilder(
            animation: _tapController,
            builder: (context, child) {
              return Transform.scale(scale: _tapScale.value, child: child);
            },
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: AppColors.sokoPink,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: AnimatedBuilder(
                      animation: _arrowTurns,
                      builder: (context, child) {
                        return Transform.rotate(
                          angle: _arrowTurns.value,
                          child: child,
                        );
                      },
                      child: const Icon(
                        LucideIcons.arrow_right,
                        color: AppColors.sokoInk,
                        size: 20,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  l10n.chatShowMoreButton,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: fgColor,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
