import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';

import '../../../../core/router/app_router.dart';
import '../../../../data/models/weekly_bundle.dart';
import '../../../../l10n/generated/l10n.dart';
import '../../../weekly_bundle/providers/weekly_bundle_provider.dart';
import '../../../weekly_bundle/weekly_bundle_nav.dart';
import '_image_template_card.dart';
import '_weekly_bundle_cover.dart';

/// Discovery — Weekly Bundle section (PROD-1518).
///
/// Renders a fully-composed editorial cover (lime background + dotted
/// rules + date/Soko/year header + up to 5 portrait thumbnails of the
/// bundle's items + "Weekly Bundle" lockup) when the bundle is ready.
/// Tapping opens the existing journal-style overlay at `/weekly-bundle`
/// (a future ticket may swap that for a direct list navigation per the
/// original ticket spec — "click → open list").
///
/// Layout-shift handling: while the provider resolves, a fixed-height
/// skeleton holds the layout. When the bundle isn't ready, the section
/// animates a collapse to zero height via `AnimatedSize`.
class WeeklyBundleSection extends ConsumerStatefulWidget {
  /// Whether to reserve the 12 px gap above the card.
  ///
  /// True on the legacy home, where this section is stacked directly under
  /// Daily Drop. False in the feed-v2 top carousel, where the two cards sit
  /// side by side and the gap would drop this one 12 px below its neighbour.
  final bool showLeadingGap;

  /// Whether to render the title + byline under the card.
  ///
  /// True on the legacy home and in the feed's `weekly_bundle` block. False in
  /// the top rituals carousel, where the slot shows cards and nothing else
  /// (Zé, 2026-08-27) — the cover is a complete, self-titled card, so the
  /// "Weekly Bundle edt. … by Soko" line under it was saying it twice.
  final bool showCaption;

  const WeeklyBundleSection({
    super.key,
    this.showLeadingGap = true,
    this.showCaption = true,
  });

  @override
  ConsumerState<WeeklyBundleSection> createState() =>
      _WeeklyBundleSectionState();
}

class _WeeklyBundleSectionState extends ConsumerState<WeeklyBundleSection> {
  bool _initialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _initialized) return;
      _initialized = true;
      final state = ref.read(weeklyBundleProvider);
      if (state.bundle == null &&
          !state.isGenerating &&
          !state.isReady &&
          !state.isUnsupportedCity) {
        ref.read(weeklyBundleProvider.notifier).initialize();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(weeklyBundleProvider);

    return AnimatedSize(
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeInOut,
      alignment: Alignment.topCenter,
      child: _buildBody(context, state),
    );
  }

  /// Leading gap above the Weekly Bundle card so it doesn't sit flush
  /// against the Daily Drop card above. Kept inside the section so it
  /// collapses with the rest of the body when there's no bundle to show
  /// (preserving the tight `DailyDrop → Em destaque` rhythm — PROD-1961).
  static const double _leadingGap = 12;

  Widget _withLeadingGap(Widget child) => widget.showLeadingGap
      ? Padding(
          padding: const EdgeInsets.only(top: _leadingGap),
          child: child,
        )
      : child;

  Widget _buildBody(BuildContext context, WeeklyBundleState state) {
    // PROD-2036 / PROD-2045 — resolved city is outside the supported
    // launch markets. Hide the section entirely (no card, no skeleton);
    // collapse via the surrounding `AnimatedSize`. Analytics still fires
    // once per session from the notifier.
    if (state.isUnsupportedCity) {
      return const SizedBox.shrink();
    }

    if (state.bundle == null) {
      // Errored, or BE confirmed no bundle and is generating one in the
      // background — collapse so we don't reserve empty space.
      if (state.hasError || state.isGenerating) {
        return const SizedBox.shrink();
      }
      // Pre-init / first fetch in flight: hold layout with a skeleton.
      return _withLeadingGap(DiscoveryImageTemplateCard.skeleton());
    }

    final bundle = state.bundle!;
    if (!bundle.isReady) {
      return const SizedBox.shrink();
    }

    final l10n = Lt.of(context);
    final locale = Localizations.localeOf(context).toString();
    final dateForTitle = _resolveDate(bundle);

    final cover = WeeklyBundleCover(
      imageUrls: [
        for (final it in bundle.items)
          if (it.imageUrl != null) it.imageUrl!,
      ],
      date: dateForTitle,
      locale: locale,
    );

    // Caption off: the cover goes straight in, WITHOUT the template card's
    // wrapper. That wrapper exists to pair a photo with a caption — it clips
    // the cover to a 6 px radius, and the ritual frame's own corners are 10.
    // Routing a complete card through it would shave them and put this card
    // subtly out of step with the Daily Drop one beside it.
    if (!widget.showCaption) {
      return _withLeadingGap(
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: _onTap,
            borderRadius: BorderRadius.circular(10),
            child: cover,
          ),
        ),
      );
    }

    return _withLeadingGap(
      DiscoveryImageTemplateCard(
        cover: cover,
        titleBold: l10n.discoveryWeeklyBundleTitle,
        titleLight: l10n.discoveryWeeklyBundleDateSuffix(
          DateFormat('d MMMM', locale).format(dateForTitle),
        ),
        byline: l10n.discoveryWeeklyBundleByline,
        onTap: _onTap,
      ),
    );
  }

  DateTime _resolveDate(WeeklyBundle bundle) {
    final iso = bundle.weekStart ?? bundle.generatedAt;
    if (iso != null) {
      try {
        return DateTime.parse(iso).toLocal();
      } catch (_) {
        /* fall through */
      }
    }
    return DateTime.now();
  }

  void _onTap() {
    // PROD-2564: the overlay fires `weekly_bundle_open` on mount (single
    // source — see Decision #7), so the section no longer fires it here (which
    // double-counted). The `WeeklyBundleNav.inApp()` extra tells the
    // `/weekly-bundle` redirect to render the overlay rather than bounce the
    // in-app tap through Discovery.
    context.push(AppRoutes.weeklyBundle, extra: const WeeklyBundleNav.inApp());
  }
}
