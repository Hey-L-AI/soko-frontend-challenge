import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:visibility_detector/visibility_detector.dart';

import '../../../core/config/research_invitation.dart';
import '../../../core/services/experiment_service.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/research_invitation_status.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/auth_provider.dart';
import '../../../providers/research_invitation_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/widgets/bt_sq_ico.dart';

final researchBookingLauncherProvider = Provider<Future<bool> Function(Uri)>(
  (ref) =>
      (uri) => launchUrl(
        uri,
        mode: LaunchMode.externalApplication,
        webOnlyWindowName: '_blank',
      ),
);

/// Lives inside the feed's scrollable, after its safe-area inset.
class ResearchInvitationBanner extends ConsumerWidget {
  const ResearchInvitationBanner({super.key, this.scrollController});
  final ScrollController? scrollController;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final accountId = ref.watch(currentUserProvider)?.id;
    if (accountId == null) return const SizedBox.shrink();
    return _AccountInvitation(
      key: ValueKey(accountId),
      accountId: accountId,
      scrollController: scrollController,
    );
  }
}

class _AccountInvitation extends ConsumerStatefulWidget {
  const _AccountInvitation({
    super.key,
    required this.accountId,
    this.scrollController,
  });
  final ScrollController? scrollController;
  final String accountId;

  @override
  ConsumerState<_AccountInvitation> createState() => _AccountInvitationState();
}

class _AccountInvitationState extends ConsumerState<_AccountInvitation>
    with WidgetsBindingObserver {
  ResearchInvitation? _invitation;
  int? _revision;
  bool _statusRequested = false;
  Timer? _dwell;
  VisibilityInfo? _lastVisibility;
  Timer? _expiry;
  bool _scrolled = false;
  bool _viewed = false;
  bool _hidden = false;
  bool _opening = false;
  bool _foreground = true;
  final _visibilityKey = UniqueKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    widget.scrollController?.addListener(_onScroll);
    _onScroll();
    _selectInvitation();
  }

  void _onScroll() {
    final controller = widget.scrollController;
    if (controller != null &&
        controller.hasClients &&
        controller.offset.abs() > 1) {
      _scrolled = true;
    }
  }

  void _selectInvitation() {
    if (_statusRequested || _scrolled || _hidden) return;
    final flags = ref.read(experimentServiceProvider);
    final candidate = flags.researchInvitation;
    // Accept late flags only before scrolling starts; otherwise wait for the
    // next visit. The initial load commonly precedes post-identify flags.
    if (flags.flagsConfirmed &&
        flags.loaded &&
        candidate != null &&
        candidate.distinctId == widget.accountId &&
        candidate.isActive(DateTime.now())) {
      _statusRequested = true;
      unawaited(_loadStatus());
    }
  }

  Future<void> _loadStatus() async {
    try {
      final status = await ref
          .read(researchInvitationsApiProvider)
          .status(widget.accountId);
      if (!mounted || _scrolled || _hidden || status.shouldSuppress) return;
      final flags = ref.read(experimentServiceProvider);
      final candidate = flags.researchInvitation;
      if (!flags.flagsConfirmed ||
          !flags.loaded ||
          candidate == null ||
          candidate.distinctId != widget.accountId ||
          ref.read(currentUserProvider)?.id != widget.accountId ||
          !candidate.isActive(DateTime.now())) {
        return;
      }
      // The server pins the first assigned arm. A reset never changes its reward
      // even if PostHog's current split now resolves this user differently.
      setState(() {
        _revision = status.revision;
        _invitation = ResearchInvitation(
          offer: status.offer ?? candidate.offer,
          endsAt: candidate.endsAt,
          distinctId: candidate.distinctId,
        );
      });
      _expiry = Timer(candidate.endsAt.difference(DateTime.now()), () {
        if (mounted) setState(() => _hidden = true);
      });
    } catch (_) {
      // Unknown server status must not expose an already-suppressed invitation.
      // Retry on the next visit; do not fall back to legacy browser state.
      debugPrint('[ResearchInvitation] Status unavailable; hiding this visit');
    }
  }

  bool get _eligible {
    final flags = ref.read(experimentServiceProvider);
    final current = flags.researchInvitation;
    return !_hidden &&
        _invitation != null &&
        flags.flagsConfirmed &&
        flags.loaded &&
        current != null &&
        ref.read(currentUserProvider)?.id == widget.accountId &&
        current.distinctId == widget.accountId &&
        current.isActive(DateTime.now());
  }

  void _remember(ResearchInvitationAction action) {
    // Capture the display's immutable revision. Ignore the POST response: a view
    // must not hide this visit, and a newer revision must not relabel old events.
    unawaited(
      ref
          .read(researchInvitationsApiProvider)
          .record(
            widget.accountId,
            action: action,
            offer: _invitation!.offer,
            revision: _revision!,
          )
          .then<void>(
            (_) {},
            onError: (Object _, StackTrace __) {
              debugPrint('[ResearchInvitation] Action could not be persisted');
            },
          ),
    );
  }

  void _visibility(VisibilityInfo info) {
    _lastVisibility = info;
    _dwell?.cancel();
    if (_viewed ||
        !_eligible ||
        !_foreground ||
        info.visibleFraction < 0.5 ||
        ModalRoute.of(context)?.isCurrent == false) {
      return;
    }
    _dwell = Timer(const Duration(seconds: 1), () {
      if (!mounted ||
          !_eligible ||
          !_foreground ||
          ModalRoute.of(context)?.isCurrent == false) {
        return;
      }
      _viewed = true;
      _remember(ResearchInvitationAction.viewed);
      ref
          .read(unifiedAnalyticsProvider)
          .trackResearchInvitationViewed(
            campaignId: ResearchInvitation.campaign,
            variant: _invitation!.offer.flagValue,
          );
    });
  }

  void _dismiss() {
    if (!_eligible) return;
    _dwell?.cancel();
    _remember(ResearchInvitationAction.dismissed);
    ref
        .read(unifiedAnalyticsProvider)
        .trackResearchInvitationDismissed(
          campaignId: ResearchInvitation.campaign,
          variant: _invitation!.offer.flagValue,
        );
    setState(() => _hidden = true);
  }

  Future<void> _book() async {
    if (_opening || !_eligible) return;
    final invitation = _invitation!;
    ref
        .read(unifiedAnalyticsProvider)
        .trackResearchInterviewClicked(
          campaignId: ResearchInvitation.campaign,
          variant: invitation.offer.flagValue,
        );
    setState(() => _opening = true);
    try {
      // Invoke directly in the tap callback, before awaiting storage/network,
      // so web browsers preserve the user gesture needed for a new tab.
      final opened = await ref.read(researchBookingLauncherProvider)(
        invitation.bookingUri,
      );
      if (!mounted || !_eligible) return;
      if (!opened) throw StateError('Booking destination did not open');
      _dwell?.cancel();
      _remember(ResearchInvitationAction.bookingLinkClicked);
      setState(() => _hidden = true);
    } catch (_) {
      if (mounted && _eligible) {
        showSoko(ref, message: Lt.of(context).researchBookingError);
      }
    } finally {
      if (mounted) setState(() => _opening = false);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _dwell?.cancel();
    if (_foreground && _lastVisibility != null) _visibility(_lastVisibility!);
  }

  @override
  void dispose() {
    _dwell?.cancel();
    _expiry?.cancel();
    widget.scrollController?.removeListener(_onScroll);
    WidgetsBinding.instance.removeObserver(this);
    VisibilityDetectorController.instance.forget(_visibilityKey);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(experimentServiceProvider);
    if (widget.scrollController != null) _selectInvitation();
    if (!_eligible) return const SizedBox.shrink();
    final l10n = Lt.of(context);
    return VisibilityDetector(
      key: _visibilityKey,
      onVisibilityChanged: _visibility,
      child: Material(
        color: AppColors.sokoPink,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 8, 6, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.researchInvitationTitle,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: AppColors.sokoInk,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      l10n.researchInvitationBody,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.sokoInk,
                      ),
                    ),
                    if (_invitation!.offer == ResearchOffer.amazon10) ...[
                      const SizedBox(height: 6),
                      Text(
                        l10n.researchInvitationReward,
                        style: const TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                          color: AppColors.sokoInk,
                        ),
                      ),
                    ],
                    const SizedBox(height: 8),
                    Semantics(
                      label: l10n.researchBookingAccessibility,
                      child: BtSqIco(
                        icon: LucideIcons.external_link,
                        label: l10n.researchBookChat,
                        variant: BtSqIcoVariant.selected,
                        selectedBackgroundOverride: AppColors.sokoInk,
                        foregroundOverride: AppColors.sokoPaper,
                        // Keep the canonical button's vertical padding and
                        // allow the label to grow with accessibility text.
                        height:
                            40 *
                            (MediaQuery.textScalerOf(context).scale(14) / 14)
                                .clamp(1.0, double.infinity),
                        loading: _opening,
                        onTap: _opening ? null : _book,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: l10n.researchDismiss,
                icon: const Icon(LucideIcons.x, size: 18),
                color: AppColors.sokoInk,
                onPressed: _dismiss,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
