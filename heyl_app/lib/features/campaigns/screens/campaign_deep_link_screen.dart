import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/services/experiment_service.dart';
import '../../../data/models/campaign.dart';
import '../../../providers/api_provider.dart';
import '../providers/campaign_service.dart';
import 'campaign_flow_screen.dart';

/// Deep-link entry point for a single fake-door campaign (ticket #8),
/// reached via `/campaign/:key` — a push notification's `route_path`, a
/// future share link, or the Discovery warm-up trigger
/// (`_CampaignWarmupTrigger` in `discovery_screen.dart`, which pushes this
/// same route once it finds an eligible campaign rather than duplicating
/// this screen's fetch/gate logic).
///
/// The route itself is auth-gated (`_isProtectedRoute` in `app_router.dart`
/// treats any `/campaign/` path as protected, mirroring
/// `businessConnections`), so this screen only ever mounts for a signed-in
/// user — no guest branch to handle here.
///
/// On mount it fetches the campaign directly by key
/// (`ICampaignApi.getCampaign`, NOT the `/active` list — a deep link is
/// allowed to reach a campaign even if the caller's notion of "currently
/// active" hasn't caught up yet) and either presents the shared
/// [CampaignFlowScreen] flow or falls back to Discovery when the backend has
/// nothing to show: a 404 (`getCampaign` rethrows on 404 per `CampaignApi`'s
/// doc comment), a network error, or `campaignServiceProvider` already
/// recording this key as responded.
///
/// Audience gating (the campaign's PostHog flag) is enforced server-side in
/// the warm-up (`GET /campaigns/active`); a user who tapped a Klaviyo push to
/// reach this route was already targeted, so this route just fetches the
/// campaign by key and renders it.
class CampaignDeepLinkScreen extends ConsumerStatefulWidget {
  const CampaignDeepLinkScreen({super.key, required this.campaignKey});

  final String campaignKey;

  @override
  ConsumerState<CampaignDeepLinkScreen> createState() =>
      _CampaignDeepLinkScreenState();
}

class _CampaignDeepLinkScreenState
    extends ConsumerState<CampaignDeepLinkScreen> {
  Campaign? _campaign;
  bool _bailed = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _resolve());
  }

  bool get _alreadyResponded =>
      ref.read(campaignServiceProvider).responded.contains(widget.campaignKey);

  Future<void> _resolve() async {
    if (!mounted) return;
    // Master feature gate — fake-door campaigns are admin-only for now
    // (PostHog `fake-door-campaigns` flag, targeted to is_admin). A non-admin
    // tapping a campaign push just bounces to Discovery.
    if (!ref.read(experimentServiceProvider).enableFakeDoorCampaigns) {
      _bailToDiscovery();
      return;
    }
    if (_alreadyResponded) {
      _bailToDiscovery();
      return;
    }
    try {
      final campaign = await ref
          .read(campaignApiProvider)
          .getCampaign(widget.campaignKey);
      if (!mounted) return;
      // Re-check: `markResponded` could have landed while the request was
      // in flight (e.g. the user answered this same campaign on another
      // device and `_syncFromServer` raced ahead of this fetch).
      if (_alreadyResponded) {
        _bailToDiscovery();
        return;
      }
      setState(() => _campaign = campaign);
    } catch (_) {
      // 404 / network error — nothing to show for this key.
      _bailToDiscovery();
    }
  }

  void _bailToDiscovery() {
    if (!mounted || _bailed) return;
    _bailed = true;
    if (context.canPop()) {
      context.pop();
    } else {
      // String literal (not `AppRoutes.home`) — importing `app_router.dart`
      // here would cycle (it imports this screen for the `/campaign/:key`
      // route), the same reason `DiscoveryScreen`'s own deep-link handlers
      // use literals for their fallback destinations.
      context.go('/');
    }
  }

  @override
  Widget build(BuildContext context) {
    final campaign = _campaign;
    if (campaign == null) {
      // Loading, or a frame away from `_bailToDiscovery` popping/replacing
      // this route — either way there's nothing worth painting yet.
      return const Scaffold(body: SizedBox.shrink());
    }
    // A deep link is a routed destination — always render as a page,
    // regardless of the campaign's `presentation` (which drives the in-app
    // warm-up surface via `presentCampaign`).
    return CampaignFlowScreen(
      campaign: campaign,
      surface: CampaignSurface.page,
    );
  }
}
