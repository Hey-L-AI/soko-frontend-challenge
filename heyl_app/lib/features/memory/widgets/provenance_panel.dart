import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/soko_card_image.dart';
import '../../lists/utils/zine_cover_recipe.dart';
import '../../lists/widgets/zine/list_zine_cover.dart';
import '../utils/memory_certainty.dart';
import 'memory_ticks.dart';

class ProvenancePanel extends StatefulWidget {
  final ObservationView observation;
  final VoidCallback? onDelete;

  /// Manual − / + on the chip's tick level. `increase == true` is the "+" tap.
  final void Function(bool increase)? onNudge;

  /// Whether to show the strength signal (level phrase + tick meter + − / +).
  /// False for the resolved home location: it's a known fact at fixed certainty,
  /// not a graded preference, so a meter there is meaningless.
  final bool showSignal;

  const ProvenancePanel({
    super.key,
    required this.observation,
    this.onDelete,
    this.onNudge,
    this.showSignal = true,
  });

  @override
  State<ProvenancePanel> createState() => _ProvenancePanelState();
}

class _ProvenancePanelState extends State<ProvenancePanel> {
  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final facts = widget.observation.backingFacts;

    // What we show as "the text behind this memory" depends on where the memory
    // came from (provenance_kind, PROD-2331):
    //  • message  → the literal excerpt you typed (evidence_text), as a quote.
    //  • otherwise → a plain descriptor label ("From your onboarding", etc.).
    // We never quote a non-message kind: its evidence_text is a system-generated
    // descriptor (e.g. "Profiling survey: …"), not something you actually said.
    // Legacy payloads (kind == null, pre-PROD-2331) keep the old behavior:
    // quote evidence_text whenever it's present.
    final kind = widget.observation.provenanceKind;
    final isLegacy = kind == null;
    final evidence = widget.observation.evidenceText?.trim();
    final hasEvidence = evidence != null && evidence.isNotEmpty;
    final quote = (isLegacy || kind == 'message') && hasEvidence
        ? evidence
        : null;
    // A chip can come from several sources at once (onboarding + collection +
    // activity). Show them all, in a stable order, joined by " · ".
    const provOrder = [
      'onboarding',
      'location',
      'action',
      'activity',
      'inferred',
    ];
    final sourceLabel = () {
      // PROD-2799: compute the non-message source labels even when this chip
      // also has a chat quote, so a chip fed by chat + a save shows BOTH the
      // quote and "From your saves and likes" (they used to be exclusive).
      if (isLegacy) return null;
      final kinds =
          widget.observation.allProvenanceKinds
              .where((k) => k != 'message')
              .toList()
            ..sort(
              (a, b) => provOrder.indexOf(a).compareTo(provOrder.indexOf(b)),
            );
      final labels = kinds
          .map((k) => _provenanceLabel(l10n, k))
          .whereType<String>()
          .toList();
      return labels.isEmpty ? null : labels.join(' · ');
    }();
    // The "N chats" count only makes sense for chat-derived (message) memories.
    final showChatCount = isLegacy || kind == 'message';

    final firstSeen = facts.isEmpty
        ? null
        : facts.map((f) => f.validFrom).reduce((a, b) => a.isBefore(b) ? a : b);
    final lastSeen =
        widget.observation.observedAt ??
        (facts.isEmpty
            ? null
            : facts
                  .map((f) => f.lastSeenAt ?? f.validFrom)
                  .reduce((a, b) => a.isAfter(b) ? a : b));

    return Padding(
      // The expanded detail sits on its own white, lifted card (see
      // CompactFamilySection); the panel itself is transparent so the two read
      // as one cohesive surface — no second background, no hard divider.
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Soko voice for the strength level — set in the heading face for an
          // editorial accent. Only for graded preferences; the home location is
          // a fact (no level phrase / meter).
          if (widget.showSignal) ...[
            Text(
              _levelPhrase(l10n, certaintyTicks(widget.observation.certainty)),
              style: const TextStyle(
                fontFamily: 'UnJamoBatang',
                fontSize: 19,
                fontWeight: FontWeight.w400,
                letterSpacing: -0.6,
                height: 1.1,
                color: AppColors.sokoInk,
              ),
            ),
            const SizedBox(height: 12),
          ],
          _Strip(
            ticks: certaintyTicks(widget.observation.certainty),
            firstSeen: firstSeen,
            lastSeen: lastSeen,
            // The meter (and − / +) only for graded preferences, not facts.
            showMeter: widget.showSignal,
            // Persona priors aren't user signals, so they can't be nudged.
            onNudge: (widget.observation.isPersonaPrior || !widget.showSignal)
                ? null
                : widget.onNudge,
          ),
          if (widget.observation.isPersonaPrior) ...[
            const SizedBox(height: 14),
            Text(
              l10n.memoryProvPersonaPriorNote,
              style: const TextStyle(
                color: AppColors.sokoShade3,
                fontSize: 12,
                fontWeight: FontWeight.w300,
                letterSpacing: -0.3,
              ),
            ),
          ] else ...[
            const SizedBox(height: 16),
            // Hairline separating the signal strip from the provenance section.
            Container(
              height: 1,
              color: AppColors.sokoInk.withValues(alpha: 0.06),
            ),
            const SizedBox(height: 14),
            // "Where Soko learned this" — the source header. A chat memory also
            // shows the N-chats count; the per-fact date rows were removed (the
            // first/last seen strip above covers timing).
            Row(
              children: [
                Text(
                  l10n.memoryProvSourcesHeader.toUpperCase(),
                  style: const TextStyle(
                    color: AppColors.sokoShade3,
                    fontSize: 10.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.8,
                  ),
                ),
                if (showChatCount && facts.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.sokoShade5,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(
                      l10n.memoryProvSourcesCount(facts.length),
                      style: const TextStyle(
                        color: AppColors.sokoInk,
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            // Where this memory came from ("Da tua coleção · Da tua atividade")
            // or the literal message you typed.
            if (quote != null) _MessageText(text: quote),
            if (sourceLabel != null) ...[
              if (quote != null) const SizedBox(height: 6),
              _SourceLabel(text: sourceLabel),
            ],
            // Action-sourced facts surface the referenced venue/event/zine
            // inline so the user can tap straight through to the entity.
            _EntityCardsRow(facts: facts),
            const SizedBox(height: 16),
            if (widget.observation.canDelete && widget.onDelete != null)
              Align(
                alignment: Alignment.centerLeft,
                child: GestureDetector(
                  onTap: widget.onDelete,
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    padding: const EdgeInsets.fromLTRB(13, 8, 15, 8),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: AppColors.sokoInk.withValues(alpha: 0.14),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          LucideIcons.trash_2,
                          size: 13,
                          color: AppColors.sokoInk.withValues(alpha: 0.6),
                        ),
                        const SizedBox(width: 7),
                        Text(
                          l10n.memoryActionDeleteThisMemory,
                          style: TextStyle(
                            fontFamily: 'ZalandoSans',
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            letterSpacing: -0.2,
                            color: AppColors.sokoInk.withValues(alpha: 0.7),
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

class _Strip extends StatelessWidget {
  final int ticks; // 1..4, the single strength scale (no % / no word)
  final DateTime? firstSeen;
  final DateTime? lastSeen;
  final void Function(bool increase)? onNudge;
  final bool showMeter;
  const _Strip({
    required this.ticks,
    required this.firstSeen,
    required this.lastSeen,
    this.onNudge,
    this.showMeter = true,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final df = DateFormat.yMMMd(Localizations.localeOf(context).toString());
    return Wrap(
      spacing: 12,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        if (showMeter) _stripMeter(l10n.memoryProvSignal, ticks),
        if (firstSeen != null)
          _stripItem(l10n.memoryProvFirstSeen, df.format(firstSeen!)),
        if (lastSeen != null)
          _stripItem(l10n.memoryProvLastSeen, df.format(lastSeen!)),
      ],
    );
  }

  Widget _stripMeter(String label, int ticks) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: AppColors.sokoShade3,
            fontSize: 10.5,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(width: 10),
        // − on the left / + on the right lets the user nudge the signal.
        // − is disabled at the floor (1 tick), + at the ceiling (4 ticks).
        if (onNudge != null) ...[
          _NudgeButton(
            icon: LucideIcons.minus,
            onTap: ticks > 1 ? () => onNudge!(false) : null,
          ),
          const SizedBox(width: 12),
        ],
        MemoryTicks(ticks: ticks, barWidth: 4, barHeight: 16, gap: 2.5),
        if (onNudge != null) ...[
          const SizedBox(width: 12),
          _NudgeButton(
            icon: LucideIcons.plus,
            onTap: ticks < 4 ? () => onNudge!(true) : null,
          ),
        ],
      ],
    );
  }

  Widget _stripItem(String label, String value) {
    return RichText(
      text: TextSpan(
        style: const TextStyle(
          color: AppColors.sokoShade2,
          fontSize: 12,
          fontWeight: FontWeight.w300,
          letterSpacing: -0.2,
        ),
        children: [
          TextSpan(
            text: label.toUpperCase(),
            style: const TextStyle(
              color: AppColors.sokoShade3,
              fontSize: 10.5,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.6,
            ),
          ),
          const TextSpan(text: '  '),
          TextSpan(text: value),
        ],
      ),
    );
  }
}

/// A small round − / + control flanking the tick meter. Disabled (greyed,
/// non-tappable) when [onTap] is null — i.e. at the tick floor/ceiling.
class _NudgeButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onTap;
  const _NudgeButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Container(
        width: 30,
        height: 30,
        decoration: BoxDecoration(
          color: Colors.white,
          shape: BoxShape.circle,
          border: Border.all(
            color: AppColors.sokoInk.withValues(alpha: enabled ? 0.22 : 0.08),
            width: 1.2,
          ),
        ),
        child: Icon(
          icon,
          size: 17,
          color: AppColors.sokoInk.withValues(alpha: enabled ? 0.75 : 0.22),
        ),
      ),
    );
  }
}

/// The literal message excerpt behind a memory — the actual words the user
/// typed — rendered in a card as a quote (wrapped in quotes, italic).
class _MessageText extends StatelessWidget {
  final String text;
  const _MessageText({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
      decoration: BoxDecoration(
        color: AppColors.sokoPaper,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(4),
          bottomLeft: Radius.circular(4),
          topRight: Radius.circular(14),
          bottomRight: Radius.circular(14),
        ),
        // A pull-quote accent: these are the user's own words.
        border: Border(
          left: BorderSide(
            color: AppColors.sokoInk.withValues(alpha: 0.35),
            width: 3,
          ),
        ),
      ),
      child: Text(
        '"$text"',
        style: const TextStyle(
          color: AppColors.sokoInk,
          fontSize: 13.5,
          fontStyle: FontStyle.italic,
          fontWeight: FontWeight.w400,
          height: 1.4,
          letterSpacing: -0.3,
        ),
      ),
    );
  }
}

/// A plain descriptor for a non-message memory ("From your onboarding", etc.).
/// Never quoted — this text is a label Soko applies, not the user's own words.
class _SourceLabel extends StatelessWidget {
  final String text;
  const _SourceLabel({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(12, 10, 14, 11),
      decoration: BoxDecoration(
        color: AppColors.sokoPaper,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(
              LucideIcons.sparkles,
              size: 13,
              color: AppColors.sokoInk.withValues(alpha: 0.5),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 13,
                fontWeight: FontWeight.w400,
                height: 1.35,
                letterSpacing: -0.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Soko-voice phrase for the tick level (1..4): how strongly Soko reads this
/// signal, from a hunch up to "knows you love it". Pairs with the tick meter.
String _levelPhrase(Lt l10n, int ticks) {
  switch (ticks) {
    case 4:
      return l10n.memoryLevel4;
    case 3:
      return l10n.memoryLevel3;
    case 2:
      return l10n.memoryLevel2;
    default:
      return l10n.memoryLevel1;
  }
}

/// Localized descriptor for a non-`message` provenance kind. Returns null for
/// `message` (which renders a quote instead) and for unknown/null kinds.
String? _provenanceLabel(Lt l10n, String? provenanceKind) {
  switch (provenanceKind) {
    case 'onboarding':
      return l10n.memoryProvSourceOnboarding;
    case 'location':
      return l10n.memoryProvSourceLocation;
    case 'action':
      return l10n.memoryProvSourceAction;
    case 'activity':
      return l10n.memoryProvSourceActivity;
    case 'inferred':
      return l10n.memoryProvSourceInferred;
    default:
      return null;
  }
}

/// Inline horizontal row of mini-cards, one per action-sourced backing
/// fact that carries entity info. Renders only when at least one fact
/// satisfies the criteria — otherwise short-circuits to an empty box.
/// Each card is a compact recolour of the in-chat venue/event card: the
/// kind tint as background, `SokoCardImage` on the left (real `imageUrl`
/// when the backend populated it, seed-coloured fallback otherwise), and
/// the entity name + subtitle on the right. Tap navigates to the
/// canonical detail page.
class _EntityCardsRow extends StatelessWidget {
  final List<MemoryFactView> facts;

  const _EntityCardsRow({required this.facts});

  @override
  Widget build(BuildContext context) {
    final entities = _collectEntities(facts);
    if (entities.isEmpty) return const SizedBox.shrink();

    // Reserve room for the "From your zine «…»" caption when any card has one,
    // so every card lines up at the same height.
    final hasZineCaptions = entities.any((e) => e.inZines.isNotEmpty);

    return Padding(
      // No top gap: the source label above already carries its own bottom
      // margin, so an extra 10px here read as a frustrating empty band.
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 4),
      child: SizedBox(
        height: hasZineCaptions ? 94 : 72,
        child: ListView.separated(
          scrollDirection: Axis.horizontal,
          padding: EdgeInsets.zero,
          itemCount: entities.length,
          separatorBuilder: (_, __) => const SizedBox(width: 8),
          itemBuilder: (context, i) => _EntityMiniCard(entity: entities[i]),
        ),
      ),
    );
  }
}

class _EntityRef {
  final String name;
  final String? subtitle;
  final String? imageUrl;
  final String entityId;
  final _EntityKind kind;
  final String factId;
  final List<String> inZines;

  /// PROD-2799 #5-img: cover recipe for list entities (zines), so the card
  /// renders the real cover instead of a generic block. Null otherwise.
  final EntityCoverView? cover;

  const _EntityRef({
    required this.name,
    required this.subtitle,
    required this.imageUrl,
    required this.entityId,
    required this.kind,
    required this.factId,
    this.inZines = const [],
    this.cover,
  });
}

enum _EntityKind { venue, event, list }

class _EntityMiniCard extends StatelessWidget {
  final _EntityRef entity;
  const _EntityMiniCard({required this.entity});

  @override
  Widget build(BuildContext context) {
    final cardColor = switch (entity.kind) {
      _EntityKind.venue => AppColors.sokoVenue,
      _EntityKind.event => AppColors.sokoEvent,
      _EntityKind.list => AppColors.sokoLilac,
    };
    final imageKind = switch (entity.kind) {
      _EntityKind.venue => SokoEntityKind.venue,
      _EntityKind.event => SokoEntityKind.event,
      _EntityKind.list => SokoEntityKind.neutral,
    };
    final icon = switch (entity.kind) {
      _EntityKind.venue => LucideIcons.map_pin,
      _EntityKind.event => LucideIcons.calendar_days,
      _EntityKind.list => LucideIcons.book_open_text,
    };
    final hasSubtitle =
        entity.subtitle != null && entity.subtitle!.trim().isNotEmpty;

    final card = GestureDetector(
      onTap: () => _navigate(context, entity),
      child: Container(
        width: 220,
        height: 68,
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(12),
          boxShadow: [
            BoxShadow(
              color: AppColors.sokoInk.withValues(alpha: 0.06),
              blurRadius: 4,
              offset: const Offset(0, 1),
            ),
          ],
        ),
        padding: const EdgeInsets.all(6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 56,
              height: 56,
              // PROD-2799 #5-img: render a zine's real cover (colour+texture or
              // uploaded photo) via the shared ListZineCover, instead of the
              // generic seed block, for list entities that carry a cover recipe.
              child: (entity.kind == _EntityKind.list && entity.cover != null)
                  ? ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: ListZineCover(
                        recipe: ZineCoverRecipe.fromFields(
                          listId: entity.entityId,
                          coverType: entity.cover!.type,
                          coverColor: entity.cover!.color,
                          coverTexture: entity.cover!.texture,
                          coverTextColor: entity.cover!.textColor,
                          // item_image covers aren't resolvable from the memory
                          // fact (no item id sent) → degrade to colour+texture.
                          coverItemId: null,
                          legacyCoverImageUrl: entity.cover!.imageUrl,
                        ),
                        title: entity.name,
                        showTitle: false,
                        showLogo: false,
                      ),
                    )
                  : SokoCardImage(
                      imageUrl: entity.imageUrl,
                      seed: entity.entityId,
                      kind: imageKind,
                      width: 56,
                      height: 56,
                      borderRadius: BorderRadius.circular(8),
                    ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    entity.name,
                    style: const TextStyle(
                      fontFamily: 'ZalandoSans',
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      height: 1.15,
                      letterSpacing: -0.15,
                      color: AppColors.sokoInk,
                    ),
                    maxLines: hasSubtitle ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  Row(
                    children: [
                      Icon(
                        icon,
                        size: 11,
                        color: AppColors.sokoInk.withValues(alpha: 0.6),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          hasSubtitle
                              ? entity.subtitle!
                              : _kindLabel(entity.kind),
                          style: TextStyle(
                            fontFamily: 'ZalandoSans',
                            fontSize: 10,
                            fontWeight: FontWeight.w400,
                            color: AppColors.sokoInk.withValues(alpha: 0.6),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );

    if (entity.inZines.isEmpty) return card;

    final l10n = Lt.of(context);
    final muted = AppColors.sokoInk.withValues(alpha: 0.55);
    final strong = AppColors.sokoInk.withValues(alpha: 0.85);
    // "Da tua zine <a> · <b>" — prefix muted, every zine name in bold, joined
    // by " · " (no quotes). Truncates with "…" if it overflows one line.
    final nameStyle = TextStyle(fontWeight: FontWeight.w600, color: strong);
    final zineSpans = <TextSpan>[
      TextSpan(text: '${l10n.memoryEntityInZinePrefix} '),
    ];
    for (var i = 0; i < entity.inZines.length; i++) {
      if (i > 0) zineSpans.add(const TextSpan(text: ' · '));
      zineSpans.add(TextSpan(text: entity.inZines[i], style: nameStyle));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        card,
        const SizedBox(height: 5),
        SizedBox(
          width: 220,
          child: Row(
            children: [
              Icon(LucideIcons.book_open_text, size: 11, color: muted),
              const SizedBox(width: 5),
              Expanded(
                child: RichText(
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  text: TextSpan(
                    style: TextStyle(
                      fontFamily: 'ZalandoSans',
                      fontSize: 11,
                      fontWeight: FontWeight.w400,
                      letterSpacing: -0.1,
                      color: muted,
                    ),
                    children: zineSpans,
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _navigate(BuildContext context, _EntityRef entity) {
    switch (entity.kind) {
      case _EntityKind.venue:
        context.push('/venues/${entity.entityId}');
        break;
      case _EntityKind.event:
        context.push('/events/${entity.entityId}');
        break;
      case _EntityKind.list:
        context.push('/lists/${entity.entityId}');
        break;
    }
  }

  String _kindLabel(_EntityKind kind) {
    return switch (kind) {
      _EntityKind.venue => 'Place',
      _EntityKind.event => 'Event',
      _EntityKind.list => 'Zine',
    };
  }
}

List<_EntityRef> _collectEntities(List<MemoryFactView> facts) {
  final out = <_EntityRef>[];
  final seen = <String>{};
  for (final fact in facts) {
    if (fact.source != 'enriched') continue;
    if (fact.entityId == null) continue;
    final key = '${fact.entityId}|${fact.content}';
    if (seen.contains(key)) continue;
    seen.add(key);
    _EntityKind? kind;
    String? parsedName;
    if (fact.content.startsWith("Saved venue '")) {
      kind = _EntityKind.venue;
      parsedName = _stripPrefix(fact.content, "Saved venue '");
    } else if (fact.content.startsWith("Saved event '")) {
      kind = _EntityKind.event;
      parsedName = _stripPrefix(fact.content, "Saved event '");
    } else if (fact.content.startsWith("Followed list '")) {
      kind = _EntityKind.list;
      parsedName = _stripPrefix(fact.content, "Followed list '");
    }
    if (kind == null || parsedName == null) continue;
    out.add(
      _EntityRef(
        name: parsedName,
        subtitle: fact.entitySubtitle,
        imageUrl: fact.entityImageUrl,
        entityId: fact.entityId!,
        kind: kind,
        factId: fact.id,
        inZines: fact.inZines,
        cover: fact.entityCover,
      ),
    );
  }
  return out;
}

String _stripPrefix(String content, String prefix) {
  var name = content.substring(prefix.length);
  if (name.endsWith("'")) name = name.substring(0, name.length - 1);
  return name;
}
