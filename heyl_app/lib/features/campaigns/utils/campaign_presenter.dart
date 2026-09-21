import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/campaign.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../screens/campaign_flow_screen.dart';

/// Surfaces [campaign]'s flow according to its `presentation` hint
/// (`sheet` / `fullscreen` / `page` — see [campaignSurfaceFromPresentation]).
///
/// This is the single entry point the in-app triggers use (the Discovery
/// warm-up today; chat-surfaced campaigns later). The `/campaign/:key`
/// deep-link route does NOT go through here — a deep link is a routed
/// destination and always renders [CampaignSurface.page] directly.
///
/// - `sheet` — a bottom sheet over the current screen via the design-system
///   [showBottomSheetWithHiddenNav] (drag handle, paper shell, hidden nav).
/// - `fullscreen` — a full-screen modal takeover (`fullscreenDialog` route).
/// - `page` — a routed page pushed on the stack (back button returns).
///
/// All three mount on the **root** navigator so they overlay the whole app,
/// matching how sheets/dialogs already present. [CampaignFlowScreen]'s
/// `initState` reserves the campaign slot and its `dispose` releases it, so
/// dismissing by any means (swipe, barrier, ×, back) cleans up on its own.
/// [surfaceOverride] forces a specific surface regardless of the campaign's
/// `presentation` — used by the admin campaign test box to preview a campaign
/// in each mode. Production triggers leave it null.
Future<void> presentCampaign(
  BuildContext context,
  WidgetRef ref,
  Campaign campaign, {
  String? sessionId,
  CampaignSurface? surfaceOverride,
}) {
  final surface =
      surfaceOverride ?? campaignSurfaceFromPresentation(campaign.presentation);
  switch (surface) {
    case CampaignSurface.sheet:
      return showBottomSheetWithHiddenNav(
        context: context,
        ref: ref,
        builder: (_) => CampaignFlowScreen(
          campaign: campaign,
          sessionId: sessionId,
          surface: CampaignSurface.sheet,
        ),
      );
    case CampaignSurface.fullscreen:
      return Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute<void>(
          fullscreenDialog: true,
          builder: (_) => CampaignFlowScreen(
            campaign: campaign,
            sessionId: sessionId,
            surface: CampaignSurface.fullscreen,
          ),
        ),
      );
    case CampaignSurface.page:
      // A plain routed page (not `context.push('/campaign/:key')`): pushing
      // the campaign object directly keeps [sessionId] and avoids a
      // redundant fetch through `CampaignDeepLinkScreen`. Still a normal
      // page — the back button pops it.
      return Navigator.of(context, rootNavigator: true).push<void>(
        MaterialPageRoute<void>(
          builder: (_) => CampaignFlowScreen(
            campaign: campaign,
            sessionId: sessionId,
            surface: CampaignSurface.page,
          ),
        ),
      );
  }
}
