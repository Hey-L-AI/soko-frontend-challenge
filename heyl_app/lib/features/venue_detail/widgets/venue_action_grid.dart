import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/backend_analytics_service.dart'
    show OriginSource;
import '../../../core/services/experiment_service.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/moderation.dart';
import '../../../l10n/generated/l10n.dart';
import '../../moderation/widgets/report_sheet.dart';
import '../../venue_claim/providers/venue_claim_provider.dart';
import '../../venue_claim/widgets/venue_claim_sheet.dart';
import '../../venue_claim/widgets/venue_owner_edit_sheet.dart';
import '../../../providers/auth_provider.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../providers/venue_detail_provider.dart';
import '../utils/maps_launcher.dart';

/// Venue actions below the events-here block.
///
///   Row 1: (Claim this business) · Report.
///   Row 2: (Visit website) · (Open in Maps).
///
/// Each row collapses gracefully when an action is unavailable. Claim is
/// controlled by the business-ownership rollout and server claim state.
class VenueActionGrid extends ConsumerWidget {
  final VenueDetailSnapshot snapshot;

  const VenueActionGrid({super.key, required this.snapshot});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    // Overlay any in-flight owner edit so re-opening the editor shows the
    // just-saved values (the detail fetch is not re-issued in-session — reading
    // the raw venue here made a re-edit look "reset"). Mirrors the details grid.
    final venue = ownerMergedVenue(ref, snapshot.venue);
    final hasWebsite = (venue.website ?? '').isNotEmpty;
    // Only surface "Abrir no Maps" when we have a verified Google Place ID.
    // Without it, the maps launcher falls back to a name+lat/lng search that
    // resolves to unrelated places for venues that don't actually exist
    // (e.g. Foursquare-only ghosts). [PROD-2220]
    final hasMap = (venue.googlePlaceId ?? '').isNotEmpty;
    final ownershipEnabled = ref.watch(
      experimentServiceProvider.select(
        (state) => state.enableBusinessOwnership,
      ),
    );
    final isAuthenticated = ref.watch(isAuthenticatedProvider);
    final claimState = ownershipEnabled && isAuthenticated
        ? ref.watch(venueClaimStateProvider(venue.id))
        : null;
    final canClaim =
        claimState?.maybeWhen(
          data: (state) =>
              !state.isOwner &&
              state.claim?.status != 'pending' &&
              state.claim?.status != 'verified',
          orElse: () => false,
        ) ??
        false;
    // Owners get an "Edit business" button in the same slot the "Claim" button
    // occupies for non-owners (the two are mutually exclusive). Driven by
    // ownedVenueIdsProvider, the same source as the pencil affordance.
    final isOwner = ownershipEnabled && isAuthenticated
        ? ref
              .watch(ownedVenueIdsProvider)
              .maybeWhen(
                data: (ids) => ids.contains(venue.id),
                orElse: () => false,
              )
        : false;

    final primaryActions = <_ActionButton>[
      if (canClaim)
        _ActionButton(
          iconWidget: const Icon(
            LucideIcons.shield_check,
            size: 14,
            color: AppColors.sokoInk,
          ),
          label: l10n.businessOwnershipClaimCta,
          onTap: () => showBottomSheetWithHiddenNav(
            context: context,
            ref: ref,
            builder: (_) =>
                VenueClaimSheet(venueId: venue.id, venueName: venue.name),
          ),
        ),
      if (isOwner)
        _ActionButton(
          iconWidget: const Icon(
            LucideIcons.pencil,
            size: 14,
            color: AppColors.sokoInk,
          ),
          label: l10n.businessOwnershipEditCta,
          onTap: () => showBottomSheetWithHiddenNav(
            context: context,
            ref: ref,
            builder: (_) => VenueOwnerEditSheet(
              venue: venue,
              onSaved: () => ref.invalidate(
                venueDetailProvider(
                  VenueDetailKey(
                    venueId: venue.id,
                    listId: snapshot.effectiveListId,
                  ),
                ),
              ),
            ),
          ),
        ),
      _ActionButton(
        iconWidget: const Icon(
          LucideIcons.flag,
          size: 14,
          color: AppColors.sokoInk,
        ),
        label: l10n.moderationMenuReport,
        onTap: () => _onReport(context),
      ),
    ];
    final secondaryActions = <_ActionButton>[
      if (hasWebsite)
        _ActionButton(
          iconWidget: SvgPicture.asset(
            'assets/images/icons/detail/external-link.svg',
            width: 14,
            height: 14,
          ),
          label: l10n.venueDetailButtonVerSite,
          onTap: () => _onWebsite(ref, venue.website!),
        ),
      if (hasMap)
        _ActionButton(
          iconWidget: SvgPicture.asset(
            'assets/images/icons/detail/map.svg',
            width: 14,
            height: 14,
          ),
          label: l10n.venueDetailButtonAbrirNoMaps,
          onTap: () => _onMaps(context, ref),
        ),
    ];

    return _TwoRowsLayout(
      primaryActions: primaryActions,
      secondaryActions: secondaryActions,
    );
  }

  void _onReport(BuildContext context) {
    showReportSheet(
      context,
      targetType: ReportTargetType.venue,
      targetId: snapshot.venue.id,
    );
  }

  Future<void> _onWebsite(WidgetRef ref, String websiteUrl) async {
    ref
        .read(unifiedAnalyticsProvider)
        .trackWebsiteClick(
          url: websiteUrl,
          venueId: snapshot.venue.id,
          originSource: OriginSource.detailView,
          originEntityId: snapshot.effectiveListId,
        );
    final uri = Uri.parse(websiteUrl);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _onMaps(BuildContext context, WidgetRef ref) async {
    final venue = snapshot.venue;
    final url =
        venue.googleMapsUrl ??
        'https://www.google.com/maps/search/?api=1&query='
            '${Uri.encodeComponent(venue.name)}';
    final provider = await openVenueInMaps(context, venue: venue);
    if (provider == null) return;
    ref
        .read(unifiedAnalyticsProvider)
        .trackMapsClick(
          provider: provider,
          url: url,
          venueId: venue.id,
          originSource: OriginSource.detailView,
          originEntityId: snapshot.effectiveListId,
        );
  }
}

class _ActionButton {
  final Widget iconWidget;
  final String label;
  final VoidCallback onTap;

  _ActionButton({
    required this.iconWidget,
    required this.label,
    required this.onTap,
  });
}

class _ActionButtonView extends StatelessWidget {
  final _ActionButton spec;

  const _ActionButtonView({required this.spec});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: AppColors.sokoInk.withValues(alpha: 0.06),
      borderRadius: BorderRadius.circular(6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: spec.onTap,
        child: SizedBox(
          height: 40,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              spec.iconWidget,
              const SizedBox(width: 5),
              Flexible(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Text(
                    spec.label,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontFamily: 'ZalandoSans',
                      fontWeight: FontWeight.w300,
                      fontSize: 14,
                      height: 1.2,
                      letterSpacing: -0.14,
                      color: AppColors.sokoInk,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TwoRowsLayout extends StatelessWidget {
  const _TwoRowsLayout({
    required this.primaryActions,
    required this.secondaryActions,
  });

  final List<_ActionButton> primaryActions;
  final List<_ActionButton> secondaryActions;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _ActionRow(actions: primaryActions),
        if (secondaryActions.isNotEmpty) ...[
          const SizedBox(height: 6),
          _ActionRow(actions: secondaryActions),
        ],
      ],
    );
  }
}

class _ActionRow extends StatelessWidget {
  const _ActionRow({required this.actions});

  final List<_ActionButton> actions;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        for (var i = 0; i < actions.length; i++) ...[
          if (i > 0) const SizedBox(width: 6),
          Expanded(child: _ActionButtonView(spec: actions[i])),
        ],
      ],
    );
  }
}
