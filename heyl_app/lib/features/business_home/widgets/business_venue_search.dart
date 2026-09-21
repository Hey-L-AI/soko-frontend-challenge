import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart' show AppRoutes;
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/google_maps_url.dart';
import '../../../data/models/business_portal.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../../shared/widgets/soko_load_more_row.dart';
import '../../venue_claim/widgets/venue_claim_sheet.dart';
import '../providers/business_search_area_providers.dart';
import '../providers/business_venue_google_tier.dart';
import '../providers/business_venue_providers.dart';
import 'business_area_chooser_sheet.dart';

/// Input decoration that fully opts OUT of the app's `InputDecorationTheme`
/// (which is `filled: true` + rounded outline borders). The Business Connect
/// fields draw their own bordered `sokoPaper` container, so the theme's fill +
/// borders would otherwise paint a second, inset box inside them ("box in a
/// box"). `border` alone is not enough — the per-state borders
/// (enabled/focused/disabled/error) each fall back to the theme, so every one
/// is overridden to none.
InputDecoration _bareInputDecoration(String hint) => InputDecoration(
  isCollapsed: true,
  filled: false,
  contentPadding: const EdgeInsets.symmetric(vertical: 14),
  border: InputBorder.none,
  enabledBorder: InputBorder.none,
  focusedBorder: InputBorder.none,
  disabledBorder: InputBorder.none,
  errorBorder: InputBorder.none,
  focusedErrorBorder: InputBorder.none,
  hintText: hint,
  hintStyle: const TextStyle(fontSize: 15, color: AppColors.sokoShade3),
);

/// Venue search → claim entry (PROD-4040 T2.2, PROD-4266 S1). A local-only
/// autocomplete field plus an always-visible "paste a Google Maps link"
/// fallback for venues not yet in the index. Selecting a candidate routes by
/// its caller-relative [PortalClaimStatus]: claim it, open it (already yours),
/// or explain it's taken by someone else.
///
/// PROD-4266 makes link entry work before typing and makes Enter do something:
/// the paste affordance sits directly below the field (independent of focus,
/// query length, loading, results or errors); Enter / the submit button cancel
/// the debounce and submit the trimmed text once (never auto-selecting a
/// result, never calling Google); a recognised Google Maps link typed or
/// pasted into the main field opens the paste sheet prefilled and bypasses
/// keyword search; and URL-like input that isn't a supported Maps link shows an
/// inline hint instead of being searched as a name.
class BusinessVenueSearch extends ConsumerStatefulWidget {
  const BusinessVenueSearch({super.key, this.onChanged, this.focusNode});

  /// Called after a claim is started or a candidate resolved, so the host can
  /// refresh the owned-venues list.
  final VoidCallback? onChanged;

  /// Optional external focus node so a host affordance ("+ Add another venue")
  /// can focus the field. When null, the widget owns its own node.
  final FocusNode? focusNode;

  @override
  ConsumerState<BusinessVenueSearch> createState() =>
      _BusinessVenueSearchState();
}

class _BusinessVenueSearchState extends ConsumerState<BusinessVenueSearch> {
  final _controller = TextEditingController();
  late final FocusNode _focusNode = widget.focusNode ?? FocusNode();
  bool get _ownsFocusNode => widget.focusNode == null;

  /// Focus scope for the whole finder (field, submit, area row, paste row and
  /// the results panel). The panel is gated on focus being ANYWHERE inside this
  /// scope — not on the field alone — so Tab / Shift+Tab can traverse the result
  /// rows and "Find more" without the panel unmounting, and a screen-reader
  /// activation of a row (which moves focus to that row) keeps the panel and
  /// its Google-tier state alive (PROD-4295).
  final _scopeNode = FocusNode(
    debugLabel: 'BusinessVenueSearch',
    skipTraversal: true,
    canRequestFocus: false,
  );
  Timer? _debounce;
  String _debouncedQuery = '';
  bool _focused = false;

  /// Keyboard highlight over the panel's activatable items (result rows, then
  /// the "Find more" / Retry footer action). ArrowDown/ArrowUp move it while
  /// the field keeps focus; Enter activates it (combobox pattern, spec §4.2).
  /// Null = nothing highlighted (Enter submits the query as before).
  int? _highlight;
  final _panelItems = _PanelItemsRegistry();

  /// Keep-alive subscriptions for the current query's local + Google-tier
  /// providers. Both are autoDispose; without a holder they die whenever the
  /// panel unmounts (a blur to somewhere outside the finder), which discarded
  /// the Google rows and un-spent the attempt (PROD-4295). The finder holds
  /// them for the lifetime of the query instead.
  ProviderSubscription<Object?>? _localKeepAlive;
  ProviderSubscription<Object?>? _tierKeepAlive;

  /// Watches the search area for the lifetime of the finder: the Google tier
  /// is keyed by query only, so a location change must reset it explicitly
  /// (`resetForContext`) — otherwise the keep-alive above would hand the new
  /// area the old area's rows and spent attempt (codex review, PROD-4295).
  ProviderSubscription<BusinessSearchArea>? _areaSub;

  /// The derived Google `region_code` can change without the area changing —
  /// the IP-detected country resolves after a Find more already ran on the
  /// locale fallback (codex review, PROD-4296). Region is part of the tier's
  /// context, so it gets the same reset as coordinates.
  ProviderSubscription<String?>? _regionSub;

  /// True when the current input looks like a link but isn't a supported
  /// Google Maps place link — we keep the text and show a hint instead of
  /// searching it as a venue name.
  bool _showUrlHint = false;

  /// Set by Escape: hides the results panel without clearing the query. Reset
  /// as soon as the query changes again (combobox pattern, spec §4.2).
  bool _dismissedResults = false;

  static const _debounceWindow = Duration(milliseconds: 500);

  /// Conservative "looks like a link" heuristic for input that isn't a
  /// recognised Maps place link: an explicit scheme, a leading `www.`, or a
  /// single space-free host+path token. Deliberately strict so ordinary venue
  /// names ("Bar da Praça", "St. Louis") don't trip it.
  static final _urlLike = RegExp(
    r'(https?://|www\.)|(^[^\s]+\.[a-z]{2,}(/|$))',
    caseSensitive: false,
  );

  @override
  void initState() {
    super.initState();
    _areaSub = ref.listenManual(businessSearchAreaProvider, _onAreaChanged);
    _regionSub = ref.listenManual(businessSearchRegionProvider, (prev, next) {
      if (prev != next) _resetTierForContext();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _areaSub?.close();
    _regionSub?.close();
    _localKeepAlive?.close();
    _tierKeepAlive?.close();
    _controller.dispose();
    _scopeNode.dispose();
    if (_ownsFocusNode) _focusNode.dispose();
    super.dispose();
  }

  /// Focus entered or left the finder scope (field, controls or panel rows).
  /// Only a change of the whole scope's focus toggles the panel; moving focus
  /// from the field to a row inside the panel is not a change here.
  void _onScopeFocusChange(bool hasFocus) {
    if (mounted && hasFocus != _focused) setState(() => _focused = hasFocus);
  }

  /// The effective search area changed (pick, "Use my location", "Search
  /// without an area"): the current query's Google tier belongs to the old
  /// location context, so reset it (drops rows, un-spends the attempt, and
  /// invalidates any in-flight response) and clear the keyboard highlight.
  void _onAreaChanged(BusinessSearchArea? previous, BusinessSearchArea next) {
    if (previous != null &&
        previous.latitude == next.latitude &&
        previous.longitude == next.longitude) {
      return; // a country-only change is caught by the region listener
    }
    _resetTierForContext();
  }

  /// Drop the current query's Google tier (rows, spent attempt, in-flight
  /// response) because its location context — coordinates or region — moved.
  void _resetTierForContext() {
    final query = _debouncedQuery;
    if (query.length >= kBusinessVenueSearchMinChars) {
      ref
          .read(businessVenueGoogleTierProvider(query).notifier)
          .resetForContext();
    }
    if (_highlight != null && mounted) setState(() => _highlight = null);
  }

  /// ArrowDown / ArrowUp from anywhere inside the finder move the keyboard
  /// highlight — but only while the panel is showing and has something to
  /// highlight. Otherwise the event is *ignored* (not merely no-op'd) so the
  /// field's own caret handling and any ancestor shortcuts still see it.
  KeyEventResult _onScopeKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final delta = key == LogicalKeyboardKey.arrowDown
        ? 1
        : key == LogicalKeyboardKey.arrowUp
        ? -1
        : 0;
    if (delta == 0 || !_showResults || _panelItems.items.isEmpty) {
      return KeyEventResult.ignored;
    }
    _moveHighlight(delta);
    return KeyEventResult.handled;
  }

  /// Hold the current query's local + Google-tier providers alive for as long
  /// as the query stands, independent of whether the panel is mounted.
  void _syncKeepAlive() {
    _localKeepAlive?.close();
    _tierKeepAlive?.close();
    _localKeepAlive = null;
    _tierKeepAlive = null;
    final query = _debouncedQuery;
    if (query.length < kBusinessVenueSearchMinChars) return;
    _localKeepAlive = ref.listenManual(
      businessVenueSearchProvider(query),
      (_, __) {},
    );
    _tierKeepAlive = ref.listenManual(
      businessVenueGoogleTierProvider(query),
      (_, __) {},
    );
  }

  /// ArrowDown / ArrowUp from the field: move the keyboard highlight across
  /// the panel's activatable items, clamped at both ends. A no-op while the
  /// panel is hidden so the arrows keep their text-editing meaning there.
  void _moveHighlight(int delta) {
    if (!_showResults) return;
    final count = _panelItems.items.length;
    if (count == 0) return;
    final current = _highlight;
    final next = current == null
        ? (delta > 0 ? 0 : count - 1)
        : (current + delta).clamp(0, count - 1);
    if (next != current) setState(() => _highlight = next);
  }

  /// Enter with a highlighted item activates it instead of re-submitting the
  /// query. Returns false when nothing is highlighted.
  bool _activateHighlight() {
    final index = _highlight;
    if (index == null || !_showResults) return false;
    final items = _panelItems.items;
    if (index >= items.length) return false;
    items[index].activate();
    return true;
  }

  void _onChanged(String value) {
    _debounce?.cancel();
    _highlight = null;
    final trimmed = value.trim();

    // A recognised Google Maps link routes to the paste resolver instead of
    // keyword search. Recognition alone never resolves — the paste sheet still
    // requires an explicit submit (spec §4.2). No unsolicited clipboard read.
    final mapsUrl = GoogleMapsUrl.extract(trimmed);
    if (mapsUrl != null) {
      setState(() {
        _showUrlHint = false;
        _dismissedResults = false;
      });
      _openPasteSheet(initialUrl: mapsUrl);
      return;
    }

    // URL-like but unsupported: hint, keep the text, never search it as a name.
    if (_urlLike.hasMatch(trimmed)) {
      setState(() {
        _showUrlHint = true;
        _dismissedResults = false;
      });
      return;
    }

    setState(() {
      _showUrlHint = false;
      _dismissedResults = false;
    });
    _debounce = Timer(_debounceWindow, () {
      if (!mounted) return;
      setState(() => _debouncedQuery = trimmed);
      _syncKeepAlive();
    });
  }

  /// Enter / the submit button: cancel the debounce and submit the trimmed
  /// text once. Never silently picks the first result, never calls Google.
  /// With a keyboard-highlighted row or footer action, Enter activates that
  /// item instead (combobox pattern) — a deliberate highlight, never the first
  /// result by default.
  void _onSubmit() {
    _debounce?.cancel();
    if (_activateHighlight()) {
      // The field's submit action unfocused it; keep the finder focused so the
      // panel (and its highlight) survive the activation.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_scopeNode.hasFocus) _focusNode.requestFocus();
      });
      return;
    }
    final trimmed = _controller.text.trim();
    if (trimmed.isEmpty) return;

    final mapsUrl = GoogleMapsUrl.extract(trimmed);
    if (mapsUrl != null) {
      setState(() {
        _showUrlHint = false;
        _dismissedResults = false;
      });
      _openPasteSheet(initialUrl: mapsUrl);
      return;
    }

    if (_urlLike.hasMatch(trimmed)) {
      setState(() {
        _showUrlHint = true;
        _dismissedResults = false;
      });
      return;
    }

    setState(() {
      _showUrlHint = false;
      _dismissedResults = false;
      _highlight = null;
      _debouncedQuery = trimmed;
    });
    _syncKeepAlive();
    // The field's default submit action unfocuses it (Enter finalizes editing),
    // which would immediately hide the focus-gated results panel. Re-focus
    // after the current frame so the submitted results stay on screen.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  void _dismissResults() {
    if (_showResults) {
      setState(() {
        _dismissedResults = true;
        _highlight = null;
      });
    }
  }

  bool get _showResults =>
      _focused &&
      !_dismissedResults &&
      _debouncedQuery.length >= kBusinessVenueSearchMinChars;

  Future<void> _handleCandidate(PortalVenueCandidate candidate) async {
    final l10n = Lt.of(context);
    switch (candidate.claimStatus) {
      case PortalClaimStatus.ownedByMe:
        context.push('/venues/${candidate.venueId}');
      case PortalClaimStatus.claimedByOther:
        showSoko(
          ref,
          message: l10n.businessHomeVenueClaimedByOther,
          variant: SokoVariant.info,
        );
      case PortalClaimStatus.unclaimed:
      case PortalClaimStatus.unknown:
        await _startClaim(candidate);
    }
  }

  Future<void> _startClaim(PortalVenueCandidate candidate) async {
    final name = candidate.name ?? Lt.of(context).businessHomeVenueFallbackName;
    await showBottomSheetWithHiddenNav<void>(
      context: context,
      ref: ref,
      builder: (_) => VenueClaimSheet(
        venueId: candidate.venueId,
        venueName: name,
        // Return to the portal after the claim's OAuth round-trip so the owner
        // sees the venue under "Your venues", not /home (PROD-4040).
        businessReturnPath: AppRoutes.businessHome,
      ),
    );
    // Guard against the Business screen being popped while the claim sheet was
    // open — otherwise onChanged invalidates providers through a disposed ref.
    if (!mounted) return;
    widget.onChanged?.call();
  }

  /// Open the editable "Search area" chooser (PROD-4268, S3). It writes the
  /// picked area to the local Business Connect area provider itself, so there's
  /// no return value to route. Restore focus to the field afterwards so the
  /// retained query + results reappear (spec §4.2).
  Future<void> _openAreaChooser() async {
    await showBottomSheetWithHiddenNav<void>(
      context: context,
      ref: ref,
      builder: (_) => const BusinessAreaChooserSheet(),
    );
    if (!mounted) return;
    _focusNode.requestFocus();
  }

  Future<void> _openPasteSheet({String? initialUrl}) async {
    _debounce?.cancel();
    final candidate = await showBottomSheetWithHiddenNav<PortalVenueCandidate>(
      context: context,
      ref: ref,
      builder: (_) => _BusinessVenuePasteSheet(initialUrl: initialUrl),
    );
    if (!mounted) return;
    if (candidate == null) {
      // Dismissed without resolving: restore focus to the main field so the
      // retained query and its results reappear (spec §4.2 — paste-triggered
      // sheets return to the main field).
      _focusNode.requestFocus();
      return;
    }
    await _handleCandidate(candidate);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    // Business Home has no Scaffold (ColoredBox > PageContent > SafeArea >
    // Column), so nothing supplies a Material ancestor. The TextField tolerates
    // that in release, but the candidate/paste-link InkWells resolve
    // `Material.of` when tapped and silently drop the tap without one — the
    // "can't pick a venue" bug. A transparent Material makes this widget
    // self-sufficient, matching how PickerSelectRow / _VenueCardShell each
    // carry their own Material on these Scaffold-less detail screens.
    return Material(
      type: MaterialType.transparency,
      child: Focus(
        focusNode: _scopeNode,
        skipTraversal: true,
        canRequestFocus: false,
        onFocusChange: _onScopeFocusChange,
        // ArrowDown / ArrowUp move the keyboard highlight through the panel
        // (spec §4.2, PROD-4295). A key handler rather than a shortcut so the
        // arrows are only consumed when there is something to highlight; being
        // closer to the focused field than the app-level
        // DefaultTextEditingShortcuts, it wins over the caret moves then.
        onKeyEvent: _onScopeKey,
        child: CallbackShortcuts(
          // Escape dismisses the results without clearing the query.
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): _dismissResults,
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _SearchField(
                controller: _controller,
                focusNode: _focusNode,
                hint: l10n.businessHomeSearchHint,
                submitLabel: l10n.businessHomeSearchSubmit,
                onChanged: _onChanged,
                onSubmit: _onSubmit,
              ),
              if (_showUrlHint) ...[
                const SizedBox(height: 8),
                _UrlHint(text: l10n.businessHomeSearchUrlHint),
              ],
              const SizedBox(height: 12),
              // Editable "Search area" row (PROD-4268, S3): sits directly below
              // the field, above the paste affordance (spec §4.1 order). Inside a
              // TextFieldTapRegion so tapping it doesn't blur the field / unmount
              // the results panel (the PROD-4040 fix, applied here too).
              TextFieldTapRegion(
                child: _SearchAreaRow(onTap: _openAreaChooser),
              ),
              const SizedBox(height: 10),
              // Always-visible paste-a-link affordance (PROD-4266): sits directly
              // below the field, independent of focus / query / loading /
              // results / errors. Inside a TextFieldTapRegion so tapping it
              // doesn't blur the field and unmount the panel (PROD-4040).
              TextFieldTapRegion(
                child: _PasteLinkRow(
                  label: l10n.businessHomePasteLinkOption,
                  onTap: () => _openPasteSheet(),
                ),
              ),
              if (_showResults) ...[
                const SizedBox(height: 8),
                // The results panel only renders while the field is focused
                // (`_showResults`). Without this, tapping a row blurs the field
                // (the row sits outside the field's tap region), which unmounts
                // the panel on pointer-down — so the row's `onTap` never lands and
                // the venue can't be picked (only reproduced on web; verified live
                // on staging). `TextFieldTapRegion` marks the panel as part of the
                // field, so tapping inside it keeps focus and the row stays mounted
                // through the tap.
                TextFieldTapRegion(
                  child: _ResultsPanel(
                    query: _debouncedQuery,
                    onSelect: _handleCandidate,
                    onNeedArea: _openAreaChooser,
                    highlight: _highlight,
                    items: _panelItems,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// One keyboard-activatable item in the results panel: a local row, a Google
/// row, or the footer action ("Find more" / Retry). Registered by the panel on
/// every build so the finder's ArrowDown/Enter handling addresses the same
/// list the panel is rendering (PROD-4295).
class _PanelItem {
  const _PanelItem(this.activate);

  final VoidCallback activate;
}

/// Mutable holder the panel writes into during build and the finder reads on
/// key events. Plain state, not a ChangeNotifier: the finder never needs to
/// rebuild because the list changed — it only reads it when a key arrives.
class _PanelItemsRegistry {
  List<_PanelItem> items = const [];
}

/// Filled, bordered search field with a trailing submit button (frame 2c/2d).
class _SearchField extends StatelessWidget {
  const _SearchField({
    required this.controller,
    required this.focusNode,
    required this.hint,
    required this.submitLabel,
    required this.onChanged,
    required this.onSubmit,
  });

  final TextEditingController controller;
  final FocusNode focusNode;
  final String hint;
  final String submitLabel;
  final ValueChanged<String> onChanged;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: AppColors.sokoPaper,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppColors.sokoInk8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14),
            // No leading search icon — the pink submit button already signals
            // "search", so the glyph would be redundant (design feedback).
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              onSubmitted: (_) => onSubmit(),
              textInputAction: TextInputAction.search,
              style: const TextStyle(fontSize: 15, color: AppColors.sokoInk),
              // This widget draws its own bordered `sokoPaper` box, so strip the
              // app theme's InputDecorationTheme (filled + outline borders) —
              // otherwise the field paints a second, inset white box inside ours
              // ("box in a box"). Override every border state, not just `border`.
              decoration: _bareInputDecoration(hint),
            ),
          ),
        ),
        const SizedBox(width: 8),
        // Inside the field's tap region so a pointer-down on submit doesn't
        // blur the field (which would unmount the focus-gated results panel
        // before the tap lands — the PROD-4040 fix, applied to submit too).
        TextFieldTapRegion(
          child: _SubmitButton(label: submitLabel, onTap: onSubmit),
        ),
      ],
    );
  }
}

/// Pink square submit button beside the field (frame 2c/2d). Carries its own
/// Material so it works on the Scaffold-less Business Home screen, and an
/// explicit [Semantics] name because its only child is an icon.
class _SubmitButton extends StatelessWidget {
  const _SubmitButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: label,
      child: Material(
        color: AppColors.sokoPink,
        borderRadius: BorderRadius.circular(10),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: const SizedBox(
            width: 48,
            height: 48,
            child: Icon(
              LucideIcons.arrow_right,
              size: 20,
              color: AppColors.sokoInk,
            ),
          ),
        ),
      ),
    );
  }
}

/// Inline hint shown when the field holds URL-like text that isn't a supported
/// Google Maps place link. Pairs an icon with the text so the message never
/// relies on colour alone (spec §4.6).
class _UrlHint extends StatelessWidget {
  const _UrlHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const Icon(LucideIcons.info, size: 14, color: AppColors.sokoShade3),
        const SizedBox(width: 6),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(fontSize: 13, color: AppColors.sokoShade3),
          ),
        ),
      ],
    );
  }
}

/// Editable "Search area" row (PROD-4268, S3). Shows the effective Business
/// Connect search area — "Search area: {city, country} · Change" when one is
/// known, or "Search area: Not set · Choose area" otherwise — with a muted hint.
/// The whole row taps through to the area chooser; the trailing action is
/// underlined (not colour-only) so the affordance never relies on colour (§4.6).
class _SearchAreaRow extends ConsumerWidget {
  const _SearchAreaRow({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final area = ref.watch(businessSearchAreaProvider);
    final label = area.label;
    final hasLabel = label != null && label.isNotEmpty;
    final value = hasLabel ? label : l10n.businessHomeSearchAreaNotSet;
    final action = hasLabel
        ? l10n.businessHomeSearchAreaChange
        : l10n.businessHomeSearchAreaChoose;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Exposed as a button so assistive tech lists it as an action (it is
        // focusable already; the role was missing — PROD-4295).
        Semantics(
          button: true,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  const Icon(
                    LucideIcons.map_pin,
                    size: 14,
                    color: AppColors.sokoShade3,
                  ),
                  const SizedBox(width: 6),
                  Flexible(
                    child: RichText(
                      text: TextSpan(
                        style: const TextStyle(
                          fontSize: 13,
                          color: AppColors.sokoShade3,
                        ),
                        children: [
                          TextSpan(
                            text: '${l10n.businessHomeSearchAreaLabel}: ',
                          ),
                          TextSpan(
                            text: value,
                            style: const TextStyle(
                              color: AppColors.sokoInk,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          const TextSpan(text: '  ·  '),
                          TextSpan(
                            text: action,
                            style: const TextStyle(
                              color: AppColors.sokoInk,
                              fontWeight: FontWeight.w500,
                              decoration: TextDecoration.underline,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 2),
        Text(
          l10n.businessHomeSearchAreaHint,
          style: const TextStyle(fontSize: 12, color: AppColors.sokoShade3),
        ),
      ],
    );
  }
}

/// Always-visible "paste a Google Maps link" affordance (PROD-4266). Reads as a
/// text link (underlined `sokoInk`) rather than a bordered row, since it no
/// longer lives inside the results panel.
class _PasteLinkRow extends StatelessWidget {
  const _PasteLinkRow({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(LucideIcons.link, size: 16, color: AppColors.sokoInk),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  color: AppColors.sokoInk,
                  decoration: TextDecoration.underline,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Autocomplete results (or loading / empty state). The paste-link fallback now
/// lives above this panel, always visible (PROD-4266).
/// Autocomplete results, plus the manual "Find more" Google tier (PROD-4270
/// S5). The local (Meilisearch) rows render first; tapping "Find more" runs a
/// transient Google search whose deduplicated candidates append to the SAME
/// list (one row style, no separate section, no attribution — decided
/// 2026-09-08). The paste-link fallback lives above this panel, always visible
/// (PROD-4266).
class _ResultsPanel extends ConsumerWidget {
  const _ResultsPanel({
    required this.query,
    required this.onSelect,
    required this.onNeedArea,
    required this.items,
    this.highlight,
  });

  final String query;
  final ValueChanged<PortalVenueCandidate> onSelect;

  /// "Find more" with neither coordinates nor any country signal would run an
  /// IP-biased Google search from the backend host (PROD-4296); instead the
  /// panel asks the finder to open the area chooser.
  final VoidCallback onNeedArea;

  /// Index of the keyboard-highlighted item (over [items]), or null.
  final int? highlight;

  /// Registry the panel fills on every build with the activatable items in
  /// render order, so the finder's ArrowDown/Enter address exactly what is on
  /// screen (PROD-4295).
  final _PanelItemsRegistry items;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final local = ref.watch(businessVenueSearchProvider(query));
    final tier = ref.watch(businessVenueGoogleTierProvider(query));
    final tierNotifier = ref.read(
      businessVenueGoogleTierProvider(query).notifier,
    );
    // Same search-area source the local search uses (PROD-4268 S3): a bias,
    // never a restriction, and only when a full coordinate pair is known.
    final area = ref.watch(businessSearchAreaProvider);
    // Google `region_code` (PROD-4296): one effective value (area country →
    // IP-detected country → app-locale region) from the same provider the
    // finder listens to for tier resets. Google otherwise defaults to IP bias
    // — the *backend host's* IP, not the owner's.
    final region = ref.watch(businessSearchRegionProvider);

    final localRows = local.maybeWhen(
      data: (rows) => rows,
      orElse: () => const <PortalVenueCandidate>[],
    );
    // "Find more" is offered once the local tier has settled — loaded (with 0,
    // some or 8 rows) or failed — never while it's still loading.
    final localReady = !local.isLoading;

    void findMore() {
      // Nothing to bias with at all: ask for an area rather than search blind
      // (spec §4.3 — "otherwise allow unscoped search with a visible area
      // chooser"). The attempt is not spent; Find more stays available.
      if (!area.hasCoordinates && region == null) {
        onNeedArea();
        return;
      }
      tierNotifier.findMore(
        localRows: localRows,
        latitude: area.hasCoordinates ? area.latitude : null,
        longitude: area.hasCoordinates ? area.longitude : null,
        region: region,
        language: Localizations.localeOf(context).toLanguageTag(),
      );
    }

    // Activatable items in render order: local rows, Google rows, then the
    // footer action when it has one (Find more idle, or Retry). Registered
    // before the widgets are built so `highlight` indexes the same list.
    final registered = <_PanelItem>[
      if (!local.isLoading && !local.hasError)
        for (final candidate in localRows)
          _PanelItem(() => onSelect(candidate)),
      for (final candidate in tier.rows)
        if (tier.resolvingPlaceId != candidate.googlePlaceId)
          _PanelItem(
            () => _resolveAndRoute(context, ref, tierNotifier, candidate),
          ),
    ];
    final footerActivatable =
        localReady && !tier.isFinding && (tier.canFindMore || tier.canRetry);
    final footerIndex = footerActivatable ? registered.length : null;
    if (footerActivatable) registered.add(_PanelItem(findMore));
    items.items = registered;

    var index = 0;
    final children = <Widget>[
      if (local.isLoading)
        const _PanelSpinner()
      else if (local.hasError)
        _MutedRow(text: l10n.businessHomeSearchError, live: true)
      else
        for (final candidate in localRows)
          _CandidateRow(
            name: candidate.name ?? l10n.businessHomeVenueFallbackName,
            subtitle: candidate.neighborhood ?? candidate.address,
            claimStatus: candidate.claimStatus,
            highlighted: highlight == index++,
            onTap: () => onSelect(candidate),
          ),
      // Google candidates append in returned order, same row style.
      for (final candidate in tier.rows)
        _CandidateRow(
          name: candidate.name ?? l10n.businessHomeVenueFallbackName,
          subtitle: _googleSubtitle(candidate),
          claimStatus: candidate.claimStatus,
          isResolving: tier.resolvingPlaceId == candidate.googlePlaceId,
          highlighted:
              tier.resolvingPlaceId != candidate.googlePlaceId &&
              highlight == index++,
          onTap: () => _resolveAndRoute(context, ref, tierNotifier, candidate),
        ),
      if (localReady)
        _FindMoreFooter(
          tier: tier,
          highlighted: footerIndex != null && highlight == footerIndex,
          onFindMore: findMore,
        ),
    ];

    return Container(
      decoration: BoxDecoration(
        color: AppColors.sokoPaper,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.sokoInk8),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }

  /// Google row subtitle: `address · city, country`, skipping missing parts.
  String? _googleSubtitle(PortalGoogleVenueCandidate c) {
    final locality = [
      c.city,
      c.country,
    ].where((p) => (p ?? '').isNotEmpty).join(', ');
    final parts = [
      c.address,
      locality,
    ].where((p) => (p ?? '').isNotEmpty).cast<String>().toList();
    return parts.isEmpty ? null : parts.join('  ·  ');
  }

  /// Resolve the tapped Google place to a canonical venue, then run the same
  /// claim/open routing as a local row. A null result means a resolve is
  /// already in flight (duplicate-resolve prevention). On failure, re-enable the
  /// row and surface an error (spec §4.4 resolve-failure).
  Future<void> _resolveAndRoute(
    BuildContext context,
    WidgetRef ref,
    BusinessVenueGoogleTierNotifier notifier,
    PortalGoogleVenueCandidate candidate,
  ) async {
    // Capture up front so nothing touches [context]/[ref] across the await: the
    // localized message, and the (long-lived) analytics service.
    final errorMessage = Lt.of(context).businessHomeResolveError;
    final analytics = ref.read(unifiedAnalyticsProvider);
    try {
      final resolved = await notifier.resolveCandidate(candidate.googlePlaceId);
      // Null means a resolve was already in flight — not an attempt outcome.
      if (resolved == null) return;
      analytics.trackBusinessVenueFindMoreResolve(outcome: 'resolved');
      if (!context.mounted) return;
      onSelect(resolved);
    } catch (_) {
      analytics.trackBusinessVenueFindMoreResolve(outcome: 'failed');
      // Don't notify from a panel the user has already left.
      if (context.mounted) {
        showSoko(ref, message: errorMessage, variant: SokoVariant.error);
      }
    }
  }
}

/// The 20 px panel spinner used for the initial local fetch and (reused) for
/// the "Find more" in-flight slot.
class _PanelSpinner extends StatelessWidget {
  const _PanelSpinner();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: SizedBox(
          height: 20,
          width: 20,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: AppColors.sokoPink,
          ),
        ),
      ),
    );
  }
}

/// The trailing "Find more" affordance and all of its §4.4 states: the tappable
/// row (idle), the in-flight spinner + "Finding more venues…", the "no
/// additions" line (complete + empty), the partial/failure message with a Retry
/// button, and the rate-limit cooldown notice. Status lines are live regions so
/// a screen reader announces them.
class _FindMoreFooter extends StatelessWidget {
  const _FindMoreFooter({
    required this.tier,
    required this.onFindMore,
    this.highlighted = false,
  });

  final BusinessVenueGoogleTierState tier;
  final VoidCallback onFindMore;

  /// Keyboard highlight on the footer action (Find more / Retry), PROD-4295.
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    if (tier.isFinding) {
      return Row(
        children: [
          const _PanelSpinner(),
          Expanded(
            child: _MutedRow(
              text: l10n.businessHomeFindMoreFinding,
              live: true,
            ),
          ),
        ],
      );
    }
    if (tier.canFindMore) {
      return _HighlightScroll(
        highlighted: highlighted,
        child: SokoLoadMoreRow(
          label: l10n.businessHomeFindMore,
          highlighted: highlighted,
          onTap: onFindMore,
        ),
      );
    }
    if (tier.isCoolingDown) {
      return _MutedRow(text: l10n.businessHomeFindMoreCooldown, live: true);
    }
    if (tier.canRetry) {
      final message = switch (tier.phase) {
        GoogleTierPhase.partial => l10n.businessHomeFindMorePartial,
        _ =>
          tier.errorKind == GoogleTierError.providerUnavailable
              ? l10n.businessHomeFindMoreProviderError
              : l10n.businessHomeFindMoreError,
      };
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _MutedRow(text: message, live: true),
          _HighlightScroll(
            highlighted: highlighted,
            child: Container(
              padding: const EdgeInsets.fromLTRB(14, 0, 14, 12),
              decoration: highlighted ? _kHighlightDecoration : null,
              child: SokoCtaButton(
                icon: LucideIcons.refresh_cw,
                label: l10n.businessHomeFindMoreRetry,
                variant: SokoCtaVariant.ghost,
                expand: false,
                onPressed: onFindMore,
              ),
            ),
          ),
        ],
      );
    }
    // Spent (complete): rows already appended above. Only speak up when the
    // Google search added nothing.
    if (tier.isSpent && tier.rows.isEmpty) {
      return _MutedRow(text: l10n.businessHomeFindMoreNoResults, live: true);
    }
    return const SizedBox.shrink();
  }
}

/// Keyboard-highlight treatment shared by every activatable panel item: a
/// `sokoShade5` wash plus a 3 px `sokoInk` leading bar, so the highlight never
/// relies on colour alone and reads on the already-tinted load-more row too
/// (spec §4.6, PROD-4295).
const _kHighlightDecoration = BoxDecoration(
  color: AppColors.sokoShade5,
  border: Border(left: BorderSide(color: AppColors.sokoInk, width: 3)),
);

/// Scrolls its child into view the frame it becomes keyboard-highlighted, so
/// ArrowDown through a long panel never moves the highlight off screen.
class _HighlightScroll extends StatefulWidget {
  const _HighlightScroll({required this.highlighted, required this.child});

  final bool highlighted;
  final Widget child;

  @override
  State<_HighlightScroll> createState() => _HighlightScrollState();
}

class _HighlightScrollState extends State<_HighlightScroll> {
  @override
  void didUpdateWidget(covariant _HighlightScroll oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.highlighted && !oldWidget.highlighted) _reveal();
  }

  @override
  void initState() {
    super.initState();
    if (widget.highlighted) _reveal();
  }

  void _reveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      Scrollable.ensureVisible(
        context,
        alignment: 0.5,
        duration: const Duration(milliseconds: 120),
      );
    });
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _CandidateRow extends StatelessWidget {
  const _CandidateRow({
    required this.name,
    required this.onTap,
    this.subtitle,
    this.claimStatus,
    this.isResolving = false,
    this.highlighted = false,
  });

  final String name;
  final String? subtitle;
  final PortalClaimStatus? claimStatus;

  /// Google row being resolved: disables the tap and shows a trailing spinner.
  final bool isResolving;

  /// Keyboard highlight (ArrowDown/ArrowUp from the field). Rendered with the
  /// shared highlight decoration and exposed as `selected` + a live region so
  /// a screen reader announces the row the highlight lands on (PROD-4295).
  final bool highlighted;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final subtitle = this.subtitle;
    return _HighlightScroll(
      highlighted: highlighted,
      child: Semantics(
        selected: highlighted,
        liveRegion: highlighted,
        child: InkWell(
          onTap: isResolving ? null : onTap,
          child: Container(
            decoration: highlighted ? _kHighlightDecoration : null,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Expanded(
                  child: RichText(
                    text: TextSpan(
                      style: const TextStyle(
                        fontSize: 14,
                        color: AppColors.sokoInk,
                      ),
                      children: [
                        TextSpan(text: name),
                        if (subtitle != null && subtitle.isNotEmpty)
                          TextSpan(
                            text: '  ·  $subtitle',
                            style: const TextStyle(color: AppColors.sokoShade3),
                          ),
                      ],
                    ),
                  ),
                ),
                if (isResolving)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppColors.sokoPink,
                      ),
                    ),
                  )
                else if (claimStatus == PortalClaimStatus.ownedByMe)
                  _StatusPill(
                    label: l10n.businessHomeStatusYours,
                    background: AppColors.sokoGreen,
                  )
                else if (claimStatus == PortalClaimStatus.claimedByOther)
                  _StatusPill(
                    label: l10n.businessHomeStatusTaken,
                    background: AppColors.sokoShade4,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label, required this.background});

  final String label;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w500,
          color: AppColors.sokoInk,
        ),
      ),
    );
  }
}

class _MutedRow extends StatelessWidget {
  const _MutedRow({required this.text, this.live = false});

  final String text;

  /// When true, wrap in a live region so screen readers announce the status as
  /// it appears (finding / no additions / failure / cooldown — spec §4.5 a11y).
  final bool live;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      liveRegion: live,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        child: Text(
          text,
          style: const TextStyle(fontSize: 14, color: AppColors.sokoShade3),
        ),
      ),
    );
  }
}

/// Paste-a-Maps-link fallback (frame 2g "resolved preview → claim"). Resolves
/// the pasted URL, previews the venue, and pops the resolved candidate back so
/// the caller runs the same claim/open routing as a search result.
///
/// Opened either from the always-visible paste row or from a recognised Maps
/// link in the main field — [initialUrl] prefills the input in the latter case,
/// but resolving always requires an explicit submit (spec §4.2, PROD-4266).
class _BusinessVenuePasteSheet extends ConsumerStatefulWidget {
  const _BusinessVenuePasteSheet({this.initialUrl});

  final String? initialUrl;

  @override
  ConsumerState<_BusinessVenuePasteSheet> createState() =>
      _BusinessVenuePasteSheetState();
}

class _BusinessVenuePasteSheetState
    extends ConsumerState<_BusinessVenuePasteSheet> {
  late final _urlController = TextEditingController(
    text: widget.initialUrl ?? '',
  );
  bool _resolving = false;
  String? _error;
  PortalVenueCandidate? _resolved;

  @override
  void initState() {
    super.initState();
    // Rebuild as the input changes so the submit button enables/disables with
    // it (empty input disables submit, spec §4.2).
    _urlController.addListener(_onUrlChanged);
  }

  @override
  void dispose() {
    _urlController.removeListener(_onUrlChanged);
    _urlController.dispose();
    super.dispose();
  }

  void _onUrlChanged() {
    if (mounted) setState(() {});
  }

  Future<void> _resolve() async {
    if (_resolving) return;
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _resolving = true;
      _error = null;
      // Drop any previous result so a stale candidate can't be claimed while
      // a new resolve is in flight.
      _resolved = null;
    });
    try {
      final candidate = await ref
          .read(venueClaimApiProvider)
          .resolveBusinessVenue(url);
      if (!mounted) return;
      setState(() {
        _resolved = candidate;
        _resolving = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = Lt.of(context).businessHomeResolveError;
        _resolving = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final resolved = _resolved;
    final canSubmit = _urlController.text.trim().isNotEmpty && !_resolving;
    return DSSheetShell(
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.businessHomePasteTitle,
              style: const TextStyle(
                fontFamily: 'UnJamoBatang',
                fontSize: 24,
                height: .96,
                letterSpacing: -1,
                color: AppColors.sokoInk,
              ),
            ),
            const SizedBox(height: 12),
            // Persistent field label (spec §4.2).
            Text(
              l10n.businessHomePasteLabel,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w500,
                color: AppColors.sokoInk,
              ),
            ),
            const SizedBox(height: 6),
            Container(
              decoration: BoxDecoration(
                color: AppColors.sokoPaper,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _error != null
                      ? AppColors.sokoRed
                      : AppColors.sokoInk8,
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: TextField(
                controller: _urlController,
                autofocus: true,
                keyboardType: TextInputType.url,
                onSubmitted: (_) => _resolve(),
                style: const TextStyle(fontSize: 15, color: AppColors.sokoInk),
                // See `_bareInputDecoration`: this sheet draws its own box too.
                decoration: _bareInputDecoration(l10n.businessHomePasteHint),
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(fontSize: 13, color: AppColors.sokoRed),
              ),
            ],
            if (resolved != null) ...[
              const SizedBox(height: 16),
              _ResolvedPreview(candidate: resolved),
            ],
            const SizedBox(height: 20),
            if (resolved == null)
              SokoCtaButton(
                icon: LucideIcons.search,
                label: l10n.businessHomeResolveCta,
                loading: _resolving,
                onPressed: canSubmit ? _resolve : null,
              )
            else
              SokoCtaButton(
                icon: resolved.claimStatus == PortalClaimStatus.ownedByMe
                    ? LucideIcons.arrow_right
                    : LucideIcons.instagram,
                label: resolved.claimStatus == PortalClaimStatus.ownedByMe
                    ? l10n.businessHomeOpenCta
                    : l10n.businessOwnershipClaimCta,
                variant: SokoCtaVariant.lilac,
                onPressed: () => Navigator.of(context).pop(resolved),
              ),
          ],
        ),
      ),
    );
  }
}

class _ResolvedPreview extends StatelessWidget {
  const _ResolvedPreview({required this.candidate});

  final PortalVenueCandidate candidate;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return Container(
      decoration: BoxDecoration(
        color: AppColors.sokoShade5,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.sokoInk8),
      ),
      padding: const EdgeInsets.all(14),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.sokoShade4,
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              LucideIcons.map_pin,
              size: 20,
              color: AppColors.sokoShade3,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  candidate.name ?? l10n.businessHomeVenueFallbackName,
                  style: const TextStyle(
                    fontFamily: 'UnJamoBatang',
                    fontSize: 18,
                    color: AppColors.sokoInk,
                  ),
                ),
                if ((candidate.address ?? '').isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    candidate.address!,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.sokoShade3,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
