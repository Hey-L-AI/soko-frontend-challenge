import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:smooth_page_indicator/smooth_page_indicator.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/services/attribution_service.dart';
import '../../../core/services/backend_analytics_service.dart';
import '../../../core/services/posthog_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/defer_provider_write.dart';
import '../../../data/datasources/interfaces/campaign_api.dart';
import '../../../data/models/campaign.dart';
import '../../../providers/api_provider.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/picker_select_row.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../../shared/widgets/soko_tag.dart';
import '../../../shared/widgets/soko_text_field.dart';
import '../providers/campaign_service.dart';

/// Campaign keys the app has already emitted `campaign_shown` for this
/// process lifetime. Module-level (not per-widget-instance) so re-mounting
/// the same campaign screen within one app session — e.g. navigating away
/// and back — doesn't double-count the exposure event. Cleared naturally
/// on cold start.
final Set<String> _shownCampaignKeysThisSession = {};

/// How a campaign flow is surfaced, derived from `campaign.presentation`.
enum CampaignSurface {
  /// Bottom sheet over the current screen — the low-friction warm-up default.
  sheet,

  /// Full-screen modal takeover with an explicit close.
  fullscreen,

  /// Routed page pushed on the nav stack — best fit for the deep-link entry.
  page,
}

/// Maps the backend `presentation` hint onto a [CampaignSurface]. Unknown or
/// empty values fall back to [CampaignSurface.sheet] — the product default
/// the warm-up flow expects. `modal` is accepted as a legacy synonym for
/// `fullscreen`.
CampaignSurface campaignSurfaceFromPresentation(String presentation) {
  switch (presentation) {
    case 'fullscreen':
    case 'modal':
      return CampaignSurface.fullscreen;
    case 'page':
      return CampaignSurface.page;
    case 'sheet':
    default:
      return CampaignSurface.sheet;
  }
}

/// Generic renderer for a fake-door campaign's flow.
///
/// Drives a small state machine over `campaign.content.screens`, starting
/// at `campaign.content.entry`. All display text arrives already
/// personalized from the backend — this widget only lays it out; it does
/// not resolve merge tags or own any campaign-specific copy.
///
/// Button behaviour:
///   * `goto` — switch to another screen in the same flow.
///   * `submit` — POST the accumulated response (choice + selected
///     options + free text + visited path), mark the campaign responded
///     locally, then `goto` (if set) or close.
///   * `dismiss` — record a dismiss response (durable POST via
///     [_recordDismiss], using the button's own `choice`) and close.
///   * `external` — open `url` in an external browser/app.
///
/// Closing the flow by any *other* means — the × button, tapping the
/// barrier, swiping the sheet down, or the system back button — is also a
/// dismiss: [dispose] records an ambient `dismissed` response for it so the
/// outcome is never silently lost (see [_recordDismiss]).
class CampaignFlowScreen extends ConsumerStatefulWidget {
  const CampaignFlowScreen({
    super.key,
    required this.campaign,
    this.sessionId,
    this.surface = CampaignSurface.page,
  });

  final Campaign campaign;

  /// Attached to the response POST when this campaign was surfaced inside
  /// a chat session. Null everywhere else.
  final String? sessionId;

  /// Outer chrome to render the flow in. The presenter
  /// (`presentCampaign`) picks this from `campaign.presentation`; the
  /// deep-link route always uses [CampaignSurface.page]. `sheet` renders
  /// inside a [DSSheetShell] (no Scaffold); `page`/`fullscreen` render a
  /// full-screen [Scaffold] (the difference between them lives in how the
  /// presenter pushes the route, not in this widget).
  final CampaignSurface surface;

  @override
  ConsumerState<CampaignFlowScreen> createState() => _CampaignFlowScreenState();
}

class _CampaignFlowScreenState extends ConsumerState<CampaignFlowScreen> {
  late String _currentScreenKey;
  final List<String> _path = [];
  final Set<String> _selectedOptions = {};
  final TextEditingController _freeTextController = TextEditingController();
  bool _submitting = false;

  /// True once this on-screen instance has actually rendered (set in the
  /// post-frame callback). Gates the ambient-dismiss fallback in [dispose] so
  /// an instance torn down before it ever displayed can't emit a spurious
  /// dismiss.
  bool _shownThisInstance = false;

  /// True once a durable outcome (a `submit`, or an explicit dismiss) has been
  /// recorded for this instance. Guards [_recordDismiss] against double
  /// recording and stops [dispose]'s ambient-dismiss fallback from firing
  /// after the user has already chosen.
  bool _outcomeRecorded = false;

  // Service handles captured in [initState] while `ref` is still usable.
  // [dispose] runs *after* Riverpod tears down the widget's `ref` (reading a
  // provider there throws "Cannot use ref after the widget was disposed" on
  // flutter_riverpod 2.6.x), so the teardown paths — the slot [release] and
  // the ambient [_recordDismiss] — must go through these cached references,
  // never `ref`.
  late final CampaignNotifier _campaignNotifier;
  late final ICampaignApi _campaignApi;
  late final AttributionService _attributionService;
  late final PostHogService _postHogService;

  Campaign get _campaign => widget.campaign;

  CampaignScreen? get _screen => _campaign.content.screens[_currentScreenKey];

  @override
  void initState() {
    super.initState();
    _currentScreenKey = _campaign.content.entry;
    _path.add(_currentScreenKey);
    // Cache the stable service handles now (see field docs) — [dispose] can't
    // read `ref`. Reads only; the slot reservation (a mutation) still defers
    // to the post-frame callback below.
    _campaignNotifier = ref.read(campaignServiceProvider.notifier);
    _campaignApi = ref.read(campaignApiProvider);
    _attributionService = ref.read(attributionServiceProvider);
    _postHogService = ref.read(postHogServiceProvider);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Deferred to post-frame: reserving the "one campaign at a time" slot
      // mutates `campaignServiceProvider`, which is illegal during the build
      // that mounts this widget (e.g. a `sheet`-presentation campaign shown
      // via `showModalBottomSheet`). Idempotent — the warm-up path already
      // reserved this key before pushing.
      _shownThisInstance = true;
      _campaignNotifier.tryReserve(_campaign.key);
      _trackShownOnce();
      _trackScreenView(_currentScreenKey);
    });
  }

  @override
  void dispose() {
    _freeTextController.dispose();
    // Ambient dismiss: closing the flow by any means that isn't an explicit
    // button outcome — the × button, tapping the barrier, swiping the sheet
    // down, or the system back button — still funnels through here. Record it
    // as a `dismissed` response (once, and only if the flow actually
    // displayed) so the backoffice funnel and the server-side re-show gate see
    // it. Without this, only taps on an explicit dismiss/submit button were
    // ever recorded, so gesture-closes were silently lost.
    if (_shownThisInstance && !_outcomeRecorded) {
      _recordDismiss();
    }
    // `release()` writes provider state (`state = ...`). A provider write
    // during dispose() runs in the build phase and throws "Tried to modify a
    // provider while the widget tree was building", silently aborting the rest
    // of dispose() — so defer it past the frame. `release()` re-checks that it
    // still owns the slot, so a campaign that grabbed the slot in the same
    // frame is safe. See [[provider-write-in-dispose-throws-even-with-a-captured-notifier]].
    deferProviderWrite(() => _campaignNotifier.release(_campaign.key));
    super.dispose();
  }

  // ---- analytics -----------------------------------------------------------
  //
  // Every campaign event is dual-lane: a PostHog capture (as before) plus a
  // fire-and-forget relay to the backend DB lane (`POST
  // /api/v1/app/analytics/track`, via `BackendAnalyticsService.trackGeneric`)
  // so the backoffice responses dashboard can compute the shown -> responded
  // funnel straight from `analytics_events`. `trackGeneric` already swallows
  // its own errors and never blocks the UI; `unawaited` just documents that
  // this call site deliberately doesn't wait on it.

  /// Relays [eventName]/[properties] to the backend DB lane. Never awaited
  /// by callers — analytics must not gate campaign rendering or navigation.
  void _relayToBackend(String eventName, Map<String, dynamic> properties) {
    unawaited(
      ref
          .read(backendAnalyticsServiceProvider)
          .trackGeneric(eventName, properties),
    );
  }

  void _trackShownOnce() {
    if (_shownCampaignKeysThisSession.contains(_campaign.key)) return;
    _shownCampaignKeysThisSession.add(_campaign.key);
    final properties = {
      'campaign_key': _campaign.key,
      'template': _campaign.template,
    };
    ref
        .read(postHogServiceProvider)
        .capture('campaign_shown', properties: properties);
    _relayToBackend('campaign_shown', properties);
  }

  void _trackScreenView(String screenKey) {
    final properties = {'campaign_key': _campaign.key, 'screen_key': screenKey};
    ref
        .read(postHogServiceProvider)
        .capture('campaign_screen_view', properties: properties);
    _relayToBackend('campaign_screen_view', properties);
  }

  void _trackButtonTap(CampaignButton button) {
    final properties = {
      'campaign_key': _campaign.key,
      'screen_key': _currentScreenKey,
      'button_key': button.key,
      'action': button.action.name,
    };
    ref
        .read(postHogServiceProvider)
        .capture('campaign_button_tap', properties: properties);
    _relayToBackend('campaign_button_tap', properties);
  }

  /// Fired once a `submit` response is actually recorded (the durable POST
  /// to `/campaigns/{key}/responses` has been issued) — the funnel-terminal
  /// event distinct from `campaign_button_tap`, which fires for every
  /// button including `goto`/`dismiss`/`external`.
  void _trackResponse(CampaignButton button) {
    final choice = button.choice;
    final properties = {
      'campaign_key': _campaign.key,
      'screen_key': _currentScreenKey,
      if (choice != null) 'choice': choice,
    };
    // One-emitter rule (PROD-3213): the client emits `campaign_response` to
    // PostHog only. The durable POST in [_submit] makes the SERVER emit the
    // DB-lane (`analytics_events`) event — relaying it from here too would
    // double-count every response in the backoffice funnel.
    ref
        .read(postHogServiceProvider)
        .capture('campaign_response', properties: properties);
  }

  // ---- navigation / actions --------------------------------------------------

  void _goto(String? targetKey) {
    if (targetKey == null ||
        !_campaign.content.screens.containsKey(targetKey)) {
      _close();
      return;
    }
    setState(() {
      _currentScreenKey = targetKey;
      _path.add(targetKey);
      _selectedOptions.clear();
      _freeTextController.clear();
    });
    _trackScreenView(targetKey);
  }

  void _close() {
    ref.read(campaignServiceProvider.notifier).release(_campaign.key);
    if (mounted && Navigator.of(context).canPop()) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _handleButtonTap(CampaignButton button) async {
    if (_submitting) return;
    _trackButtonTap(button);
    switch (button.action) {
      case CampaignButtonAction.goto:
        _goto(button.goto);
        break;
      case CampaignButtonAction.dismiss:
        // An explicit dismiss button records its own configured choice (e.g.
        // 'no'); the ambient 'dismissed' default is reserved for gesture / ×
        // / back closes recorded in [dispose].
        _recordDismiss(choice: button.choice ?? 'dismissed');
        _close();
        break;
      case CampaignButtonAction.external:
        final url = button.url;
        final uri = url == null ? null : Uri.tryParse(url);
        if (uri != null) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
        break;
      case CampaignButtonAction.submit:
        await _submit(button);
        break;
    }
  }

  /// Records a dismiss as a durable outcome, not just a local skip: POST a
  /// response so the server's `/campaigns/active` excludes this campaign for
  /// this user on EVERY device from now on (matches feature-spotlights' "mark
  /// seen").
  ///
  /// [choice] is `'dismissed'` for an ambient close (×, barrier, swipe, back —
  /// recorded from [dispose]) and the dismiss button's own
  /// [CampaignButton.choice] (e.g. `'no'`) for an explicit dismiss-button tap.
  ///
  /// Idempotent via [_outcomeRecorded] so the button path and the [dispose]
  /// fallback can't both fire. Everything here is fire-and-forget: it runs
  /// from [dispose], so it must not await, touch `context`, or `ref` — it uses
  /// the handles cached in [initState] instead. The network call and
  /// `markResponded` run detached; a failed POST is non-fatal, as the local
  /// `markResponded` still suppresses re-show on this device.
  void _recordDismiss({String choice = 'dismissed'}) {
    if (_outcomeRecorded) return;
    _outcomeRecorded = true;
    final props = {
      'campaign_key': _campaign.key,
      'screen_key': _currentScreenKey,
      'choice': choice,
    };
    // One-emitter rule (PROD-3213): PostHog from the client, DB lane from the
    // server (triggered by the POST below) — never relay `campaign_response`
    // to the DB lane from here.
    _postHogService.capture('campaign_response', properties: props);
    final request = CampaignResponseRequest(
      choice: choice,
      selectedOptions: null,
      freeText: null,
      path: List.unmodifiable(_path),
      sessionId: widget.sessionId,
      visitorId: _attributionService.cachedVisitorId,
    );
    unawaited(() async {
      try {
        await _campaignApi.submitCampaignResponse(_campaign.key, request);
      } catch (_) {
        // Non-fatal: local markResponded still suppresses re-show on this device.
      }
    }());
    // `markResponded()` writes provider state, so it must be deferred past the
    // frame too (this runs from dispose()). Deferring is harmless on the
    // button-tap path — it just lands the "responded" flag a frame later, and
    // `_close()` has already popped the flow by then. The `.catchError`
    // swallows the `StateError` a torn-down `ProviderScope` throws at app exit.
    deferProviderWrite(
      () => unawaited(
        _campaignNotifier.markResponded(_campaign.key).catchError((_) {}),
      ),
    );
  }

  Future<void> _submit(CampaignButton button) async {
    setState(() => _submitting = true);
    try {
      final request = CampaignResponseRequest(
        choice: button.choice,
        selectedOptions: _selectedOptions.isEmpty
            ? null
            : _selectedOptions.toList(growable: false),
        freeText: _freeTextController.text.trim().isEmpty
            ? null
            : _freeTextController.text.trim(),
        path: List.unmodifiable(_path),
        sessionId: widget.sessionId,
        visitorId: ref.read(attributionServiceProvider).cachedVisitorId,
      );
      await ref
          .read(campaignApiProvider)
          .submitCampaignResponse(_campaign.key, request);
      _outcomeRecorded = true;
      _trackResponse(button);
      await ref
          .read(campaignServiceProvider.notifier)
          .markResponded(_campaign.key);
      if (!mounted) return;
      if (button.goto != null &&
          _campaign.content.screens.containsKey(button.goto)) {
        setState(() => _submitting = false);
        _goto(button.goto);
      } else {
        _close();
      }
    } catch (_) {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _toggleOption(String key) {
    setState(() {
      if (_selectedOptions.contains(key)) {
        _selectedOptions.remove(key);
      } else {
        _selectedOptions.add(key);
      }
    });
  }

  // ---- build -----------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final screen = _screen;
    final closeBar = _CloseBar(onClose: _close);

    // Sheet surface: host the same content inside the design-system sheet
    // chrome (drag handle + paper shell), header = close, footer = the
    // sticky button row. No Scaffold.
    if (widget.surface == CampaignSurface.sheet) {
      return DSSheetShell(
        header: closeBar,
        body: screen == null ? const SizedBox(height: 40) : _screenBody(screen),
        // Lift the sticky button row above the on-screen keyboard (the free
        // text field lives in the scrollable body). A Scaffold does this via
        // `resizeToAvoidBottomInset`, but a bottom sheet must add the inset
        // itself — same `AnimatedPadding(viewInsets.bottom)` pattern as
        // `app_feedback_sheet.dart`.
        footer: screen == null
            ? null
            : AnimatedPadding(
                duration: const Duration(milliseconds: 150),
                curve: Curves.easeOut,
                padding: EdgeInsets.only(
                  bottom: MediaQuery.viewInsetsOf(context).bottom,
                ),
                child: _ButtonRow(
                  buttons: screen.buttons,
                  submitting: _submitting,
                  onTap: _handleButtonTap,
                ),
              ),
      );
    }

    // Page / fullscreen surface: full-screen Scaffold. The two differ only
    // in how the presenter pushes the route (normal push vs fullscreen
    // dialog), not in the chrome here.
    return Scaffold(
      backgroundColor: AppColors.sokoPaper,
      body: SafeArea(
        child: screen == null
            ? _EmptyState(onClose: _close)
            : Column(
                children: [
                  closeBar,
                  Expanded(child: _screenBody(screen)),
                  _ButtonRow(
                    buttons: screen.buttons,
                    submitting: _submitting,
                    onTap: _handleButtonTap,
                  ),
                ],
              ),
      ),
    );
  }

  /// Scrollable content for [screen] (media, badge, title/subtitle, body
  /// blocks, options, free text) — shared by every surface. The outer
  /// chrome (Scaffold vs sheet) and the pinned button row live in [build].
  Widget _screenBody(CampaignScreen screen) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (screen.media.isNotEmpty) ...[
            _MediaCarousel(media: screen.media),
            const SizedBox(height: 16),
          ],
          // Guard on non-empty, not just non-null: the campaign editor can
          // persist `badge: ""` (blank field), which would otherwise paint
          // an empty yellow tag.
          if (screen.badge?.trim().isNotEmpty ?? false) ...[
            _Badge(text: screen.badge!.trim()),
            const SizedBox(height: 8),
          ],
          Text(
            screen.title,
            style: AppTheme.display(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: AppColors.sokoInk,
              height: 1.1,
            ),
          ),
          if (screen.subtitle != null) ...[
            const SizedBox(height: 8),
            Text(
              screen.subtitle!,
              style: AppTheme.body(
                fontSize: 14,
                color: AppColors.sokoInk.withValues(alpha: 0.7),
                height: 1.3,
              ),
            ),
          ],
          if (screen.body.isNotEmpty) ...[
            const SizedBox(height: 16),
            for (final block in screen.body)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _BodyBlockWidget(block: block),
              ),
          ],
          if (screen.options.isNotEmpty) ...[
            const SizedBox(height: 8),
            for (final option in screen.options)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: PickerSelectRow(
                  title: option.title,
                  subtitle: option.description ?? '',
                  isSelected: _selectedOptions.contains(option.key),
                  leading: option.icon == null
                      ? null
                      : Text(
                          option.icon!,
                          style: const TextStyle(fontSize: 20),
                        ),
                  onTap: () => _toggleOption(option.key),
                ),
              ),
          ],
          if (screen.freeText?.enabled ?? false) ...[
            const SizedBox(height: 8),
            SokoTextField(
              controller: _freeTextController,
              hintText: screen.freeText?.prompt,
              minLines: 3,
              maxLines: 6,
              textAlignVertical: TextAlignVertical.top,
            ),
          ],
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _CloseBar(onClose: onClose),
        const Expanded(child: SizedBox.shrink()),
      ],
    );
  }
}

class _CloseBar extends StatelessWidget {
  const _CloseBar({required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          IconButton(
            onPressed: onClose,
            icon: const Icon(LucideIcons.x, size: 20),
            color: AppColors.sokoInk,
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: SokoTag(
        background: AppColors.sokoYellow,
        child: Text(text, style: SokoTag.textStyleCompact),
      ),
    );
  }
}

/// Image carousel with dot pagination for a screen's `media` list.
class _MediaCarousel extends StatefulWidget {
  const _MediaCarousel({required this.media});

  final List<CampaignMedia> media;

  @override
  State<_MediaCarousel> createState() => _MediaCarouselState();
}

class _MediaCarouselState extends State<_MediaCarousel> {
  final PageController _controller = PageController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.media.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: PageView.builder(
              controller: _controller,
              itemCount: widget.media.length,
              itemBuilder: (context, i) => _MediaTile(item: widget.media[i]),
            ),
          ),
        ),
        if (widget.media.length > 1) ...[
          const SizedBox(height: 8),
          // Same expanding-dot indicator as the onboarding carousel
          // (`onboarding_screen.dart`) so pagination reads consistently.
          SmoothPageIndicator(
            controller: _controller,
            count: widget.media.length,
            effect: const ExpandingDotsEffect(
              dotHeight: 6,
              dotWidth: 6,
              expansionFactor: 3,
              spacing: 6,
              activeDotColor: AppColors.sokoInk,
              dotColor: AppColors.sokoShade4,
            ),
          ),
        ],
      ],
    );
  }
}

class _MediaTile extends StatelessWidget {
  const _MediaTile({required this.item});

  final CampaignMedia item;

  @override
  Widget build(BuildContext context) {
    final url = item.url;
    if (url == null || url.isEmpty) return const _MediaPlaceholder();
    return Image.network(
      url,
      fit: BoxFit.cover,
      width: double.infinity,
      semanticLabel: item.alt,
      errorBuilder: (context, error, stackTrace) => const _MediaPlaceholder(),
      loadingBuilder: (context, child, progress) {
        if (progress == null) return child;
        return const _MediaPlaceholder();
      },
    );
  }
}

class _MediaPlaceholder extends StatelessWidget {
  const _MediaPlaceholder();

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.sokoShade5,
      alignment: Alignment.center,
      child: const Icon(
        LucideIcons.image,
        size: 32,
        color: AppColors.sokoShade4,
      ),
    );
  }
}

/// One paragraph or bullet line, with `**bold**` inline-markdown support.
class _BodyBlockWidget extends StatelessWidget {
  const _BodyBlockWidget({required this.block});

  final CampaignBodyBlock block;

  static final _boldPattern = RegExp(r'\*\*(.+?)\*\*');

  static InlineSpan _richText(String text, TextStyle style) {
    final spans = <InlineSpan>[];
    var last = 0;
    for (final match in _boldPattern.allMatches(text)) {
      if (match.start > last) {
        spans.add(TextSpan(text: text.substring(last, match.start)));
      }
      spans.add(
        TextSpan(
          text: match.group(1),
          style: const TextStyle(fontWeight: FontWeight.w700),
        ),
      );
      last = match.end;
    }
    if (last < text.length) {
      spans.add(TextSpan(text: text.substring(last)));
    }
    return TextSpan(children: spans, style: style);
  }

  static IconData _bulletIcon(String? name) {
    switch (name) {
      case 'check':
        return LucideIcons.check;
      case 'star':
        return LucideIcons.star;
      case 'heart':
        return LucideIcons.heart;
      case 'sparkles':
        return LucideIcons.sparkles;
      default:
        return LucideIcons.circle;
    }
  }

  @override
  Widget build(BuildContext context) {
    final style = AppTheme.body(
      fontSize: 14,
      color: AppColors.sokoInk,
      height: 1.35,
    );
    if (block.type == CampaignBodyBlockType.bullet) {
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 8),
            child: Icon(
              _bulletIcon(block.icon),
              size: 14,
              color: AppColors.sokoInk.withValues(alpha: 0.7),
            ),
          ),
          Expanded(child: Text.rich(_richText(block.text, style))),
        ],
      );
    }
    return Text.rich(_richText(block.text, style));
  }
}

/// 1-3 stacked full-width buttons mapped from `style` to a Soko CTA
/// variant: `primary` -> pink, `danger` -> red, `secondary` -> ink,
/// `ghost` -> a borderless CTA (transparent bg, `sokoInk` label).
class _ButtonRow extends StatelessWidget {
  const _ButtonRow({
    required this.buttons,
    required this.submitting,
    required this.onTap,
  });

  final List<CampaignButton> buttons;
  final bool submitting;
  final ValueChanged<CampaignButton> onTap;

  @override
  Widget build(BuildContext context) {
    if (buttons.isEmpty) return const SizedBox.shrink();
    return Container(
      color: AppColors.sokoPaper,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < buttons.length; i++)
            Padding(
              padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
              child: _CampaignButtonWidget(
                button: buttons[i],
                loading:
                    submitting &&
                    buttons[i].action == CampaignButtonAction.submit,
                enabled: !submitting,
                onTap: () => onTap(buttons[i]),
              ),
            ),
        ],
      ),
    );
  }
}

class _CampaignButtonWidget extends StatelessWidget {
  const _CampaignButtonWidget({
    required this.button,
    required this.loading,
    required this.enabled,
    required this.onTap,
  });

  final CampaignButton button;
  final bool loading;
  final bool enabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final onPressed = enabled ? onTap : null;
    switch (button.style) {
      case CampaignButtonStyle.primary:
        return SokoCtaButton(
          label: button.label,
          onPressed: onPressed,
          loading: loading,
        );
      case CampaignButtonStyle.danger:
        return SokoCtaButton(
          label: button.label,
          onPressed: onPressed,
          loading: loading,
          variant: SokoCtaVariant.red,
        );
      case CampaignButtonStyle.secondary:
        return SokoCtaButton(
          label: button.label,
          onPressed: onPressed,
          loading: loading,
          variant: SokoCtaVariant.ink,
        );
      case CampaignButtonStyle.ghost:
        return SokoCtaButton(
          label: button.label,
          onPressed: onPressed,
          loading: loading,
          variant: SokoCtaVariant.ghost,
        );
    }
  }
}
