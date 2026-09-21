import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pointer_interceptor/pointer_interceptor.dart';

import '../../../core/services/experiment_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/geo_boundary.dart';
import '../../../data/models/resolved_search_location.dart';
import '../../../data/models/map_debug.dart';
import '../../../providers/resolved_search_location_provider.dart';
import '../../../shared/utils/map_debug_overlay.dart';
import '../../../shared/widgets/admin_location_debug_box.dart';
import '../../../shared/widgets/map_marker_model.dart';
import '../../../shared/widgets/right_edge_tab_slots.dart';
import '../providers/map_markers_provider.dart';
import '../providers/map_personalization_provider.dart';
import '../providers/map_query_provider.dart';
import '../providers/map_selection_provider.dart';
import '../providers/map_ui_state_provider.dart';
import '../utils/map_dot_hints.dart';
import '../utils/map_grid_selection.dart';
import '../utils/map_leave_prompt.dart';

/// ADMIN-ONLY map diagnostics tab (PROD-2971). Mounted only for admins (gated at
/// the mount site in `MapScreen`) so it's usable in prod for bug-hunting the pin
/// algorithms — not compiled out like the old `kDebugMode` gate.
///
/// Mirrors [FeedbackSideTab]'s look — a semi-transparent right-edge tab with
/// rounded left corners, an icon above a rotated label — but in soko-yellow so
/// it reads as a dev tool. Tapping it toggles the **docked** [MapDebugPanel]
/// (non-modal, so the map stays tappable underneath for live per-pin inspection).
///
/// Returns a [Positioned]; add it directly to the Map page's body `Stack`.
/// Positioned via [RightEdgeTabSlots] (PROD-3124): the Feedback tab keeps its
/// fixed 40% anchor; this tab claims the first free slot below it, so it never
/// overlaps the shell's Loc tab (they used to hard-code the same spot).
class MapDebugTab extends ConsumerStatefulWidget {
  const MapDebugTab({super.key});

  @override
  ConsumerState<MapDebugTab> createState() => _MapDebugTabState();
}

class _MapDebugTabState extends ConsumerState<MapDebugTab> {
  int? _slot;

  @override
  void initState() {
    super.initState();
    // Mount-gated (isAdmin || kDebugMode in MapScreen), so if we exist we
    // render — claim unconditionally.
    _slot = RightEdgeTabSlots.claim();
  }

  @override
  void dispose() {
    RightEdgeTabSlots.release(_slot);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final open = ref.watch(mapDebugPanelOpenProvider);
    return Positioned(
      right: 0,
      top: rightEdgeTabSlotTop(context, _slot ?? 0),
      child: PointerInterceptor(
        child: Opacity(
          opacity: open ? 0.95 : 0.62,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: () =>
                  ref.read(mapDebugPanelOpenProvider.notifier).state = !open,
              borderRadius: const BorderRadius.only(
                topLeft: Radius.circular(10),
                bottomLeft: Radius.circular(10),
              ),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 12,
                ),
                decoration: BoxDecoration(
                  color: AppColors.sokoYellow,
                  borderRadius: const BorderRadius.only(
                    topLeft: Radius.circular(10),
                    bottomLeft: Radius.circular(10),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: AppColors.sokoInk.withValues(alpha: 0.15),
                      blurRadius: 8,
                      offset: const Offset(-2, 0),
                    ),
                  ],
                ),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(LucideIcons.bug, size: 14, color: AppColors.sokoInk),
                    SizedBox(height: 6),
                    RotatedBox(
                      quarterTurns: 3,
                      child: Text(
                        'Debug',
                        style: TextStyle(
                          fontFamily: 'Zalando Sans',
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.4,
                          color: AppColors.sokoInk,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The docked (non-modal) debug panel — a top-left card that stays open while
/// the map underneath remains interactive. Renders only when
/// [mapDebugPanelOpenProvider] is on. Client-side rows (zoom + pin size) are
/// always shown; turning on "Debug mode" requests the admin `/map/pins` `debug`
/// block and reveals the shape legend + server sections + per-pin scoring.
///
/// Because it's non-modal, tapping a pin while it's open (in debug mode)
/// inspects that pin — [MapScreen] routes the tap to [mapFocusedPinProvider]
/// instead of opening the detail sheet — and the per-pin section updates live.
class MapDebugPanel extends ConsumerWidget {
  const MapDebugPanel({
    super.key,
    required this.settledBoundary,
    required this.boundaryResolving,
  });

  /// The administrative boundary at the last settled map camera centre. It is
  /// deliberately passed from [MapScreen], where the debounce/cache controller
  /// lives, rather than resolved again just for diagnostics.
  final GeoBoundary? settledBoundary;
  final bool boundaryResolving;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(mapDebugPanelOpenProvider)) return const SizedBox.shrink();

    final media = MediaQuery.of(context);
    final zoom = ref.watch(mapLiveViewportProvider)?.zoom;
    final iconSize = zoom == null
        ? null
        : MapPinIconTokens.iconSizeForZoom(zoom);
    final pinW = iconSize == null
        ? null
        : MapPinIconTokens.sourceWidthPx * iconSize;
    final pinH = iconSize == null
        ? null
        : MapPinIconTokens.sourceHeightPx * iconSize;

    final debugOn = ref.watch(mapDebugEnabledProvider);
    final cellCounts = ref.watch(mapDebugCellCountsProvider);
    final debug = ref.watch(mapPinsProvider).data?.debug;

    // PROD-2671 (from develop): the FE-computed **search-area** overlay is a
    // kDebugMode-only dev tool (distinct from the admin backend-`debug` overlay
    // above). Its readouts mirror the committed query; its web-only toggle
    // writes [mapDebugSearchAreaProvider] (drawn via `_syncDebugSearchArea` in
    // mapbox_map_web.dart). Gated on kDebugMode below to match its map_screen
    // gate, so it only appears when it actually draws.
    final q = ref.watch(mapQueryProvider);
    final wantV2 = ref.watch(
      experimentServiceProvider.select((s) => s.enableMapPinsV2),
    );
    final v2Active = wantV2 && q.hasBounds;
    final scoped = q.scopeWire != null; // yours/following → radius ignored
    final searchOverlayOn = ref.watch(mapDebugSearchAreaProvider);
    final searchCenter = ref.watch(resolvedSearchLocationProvider).valueOrNull;

    return Positioned(
      left: 12,
      top: media.padding.top + 130,
      child: PointerInterceptor(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxWidth: 340,
            maxHeight: media.size.height * 0.62,
          ),
          child: Material(
            color: Colors.transparent,
            child: Container(
              decoration: BoxDecoration(
                color: AppColors.sokoPaper,
                borderRadius: BorderRadius.circular(16),
                boxShadow: [
                  BoxShadow(
                    color: AppColors.sokoInk.withValues(alpha: 0.2),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              padding: const EdgeInsets.fromLTRB(16, 12, 10, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(
                        LucideIcons.bug,
                        size: 16,
                        color: AppColors.sokoInk,
                      ),
                      const SizedBox(width: 8),
                      const Text(
                        'Map debug',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: AppColors.sokoInk,
                        ),
                      ),
                      const Spacer(),
                      if (debug != null) _CopyJsonButton(debug: debug),
                      InkWell(
                        onTap: () {
                          ref.read(mapDebugPanelOpenProvider.notifier).state =
                              false;
                          // Clear the inspect highlight so the map un-dims.
                          ref.read(mapFocusedPinProvider.notifier).state = null;
                        },
                        borderRadius: BorderRadius.circular(6),
                        child: const Padding(
                          padding: EdgeInsets.all(6),
                          child: Icon(
                            LucideIcons.x,
                            size: 18,
                            color: AppColors.sokoInk,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Flexible(
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // Location diagnostics (GPS / user loc / chat +
                          // discovery search centers) — the Map page's debug
                          // panel is the official home for these (no separate
                          // Loc tab here).
                          const AdminLocationDebugContent(title: 'Location'),
                          const _DebugDivider(),
                          const _DebugSection('Leave prompt comparison'),
                          _DebugRow(
                            label: 'Search Center (C)',
                            value: _searchCenterLabel(searchCenter),
                          ),
                          _DebugRow(
                            label: 'C boundary ID',
                            value: searchCenter?.boundaryId ?? '— (city/point)',
                          ),
                          _DebugRow(
                            label: 'Map centre area',
                            value: _mapBoundaryLabel(
                              settledBoundary,
                              resolving: boundaryResolving,
                            ),
                          ),
                          _DebugRow(
                            label: 'Map boundary ID',
                            value: settledBoundary?.id ?? '—',
                          ),
                          _DebugRow(
                            label: 'Leave prompt',
                            value: _leavePromptState(
                              searchCenter: searchCenter,
                              settledBoundary: settledBoundary,
                              resolving: boundaryResolving,
                            ),
                          ),
                          const _DebugDivider(),
                          _DebugRow(label: 'Zoom', value: _fmt(zoom)),
                          _DebugRow(
                            label: 'Pin size',
                            value: iconSize == null
                                ? '—'
                                : '${_fmt(iconSize)}×  →  ${_fmt(pinW, frac: 0)} × '
                                      '${_fmt(pinH, frac: 0)} px',
                          ),
                          // PROD-2671 search-area overlay (kDebugMode-only dev
                          // tool; distinct from the admin backend-debug overlay).
                          if (kDebugMode) ...[
                            const _DebugDivider(),
                            const _DebugSection('Search area (FE → /map/pins)'),
                            _DebugRow(
                              label: 'Radius',
                              value: q.hasCenter
                                  ? '${_fmt(q.radiusMeters, frac: 0)} m'
                                        '${scoped ? '  (ignored — scoped)' : ''}'
                                  : '—',
                            ),
                            _DebugRow(
                              label: 'Viewport',
                              value: v2Active
                                  ? 'v2 rect sent'
                                  : (wantV2
                                        ? 'v2 on (no bounds yet)'
                                        : 'v1 (no rect)'),
                            ),
                            _DebugRow(
                              label: 'Bounds',
                              value: q.hasBounds
                                  ? 'SW ${_fmt(q.swLat, frac: 4)}, ${_fmt(q.swLng, frac: 4)}\n'
                                        'NE ${_fmt(q.neLat, frac: 4)}, ${_fmt(q.neLng, frac: 4)}'
                                  : '—',
                            ),
                            // Overlay renders on web only (`_syncDebugSearchArea`).
                            if (kIsWeb)
                              _DebugSwitchRow(
                                label: 'Search-area overlay',
                                value: searchOverlayOn,
                                onChanged: (v) =>
                                    ref
                                            .read(
                                              mapDebugSearchAreaProvider
                                                  .notifier,
                                            )
                                            .state =
                                        v,
                              ),
                          ],
                          const _DebugDivider(),
                          // PROD-3124: live-tuning sliders for the dot hints
                          // (client-side re-selection over the cached pool).
                          const _DotHintsSection(),
                          const _DebugDivider(),
                          // PROD-2948 (from develop): admin-only personalization
                          // strength picker (off/low/medium/high) → sends
                          // `personalization_level`; backend gates the effect.
                          const _PersonalizationSection(),
                          const _DebugDivider(),
                          _DebugSwitchRow(
                            label: 'Debug mode',
                            value: debugOn,
                            onChanged: (v) =>
                                ref
                                        .read(mapDebugEnabledProvider.notifier)
                                        .state =
                                    v,
                          ),
                          if (debugOn)
                            _DebugSwitchRow(
                              label: 'Per-cell counts',
                              value: cellCounts,
                              onChanged: (v) =>
                                  ref
                                          .read(
                                            mapDebugCellCountsProvider.notifier,
                                          )
                                          .state =
                                      v,
                            ),
                          if (debugOn) ...[
                            const _DebugDivider(),
                            const _DebugSection('Overlay shapes'),
                            _ShapeLegend(),
                            const _DebugDivider(),
                            if (debug == null)
                              const _DebugHint(
                                'Waiting for the debug block — pan/zoom to '
                                'refetch. (If it never arrives, this user may '
                                'not be admin.)',
                              )
                            else
                              ..._serverSections(debug, zoom, ref),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The server-`debug`-block sections: request → retrieval → grid → drift →
  /// pins. Each returns a flat run of rows so the parent Column stays simple.
  List<Widget> _serverSections(MapDebug debug, double? zoom, WidgetRef ref) {
    final area = debug.area;
    final grid = area?.grid;
    final selection = area?.selectionViewport;
    final retrieval = debug.retrieval;

    // Grid-drift: FE base level (from live zoom) vs server-reported grid_level.
    // Only the v2 `selection_viewport.grid_level` is a comparable grid *level*;
    // don't fall back to `cells_across` (a count, not a level) — on a v1 request
    // there's no server level to diff, so the row just shows "—".
    final feLevel = zoom == null ? null : feBaseGridLevel(zoom);
    final serverLevel = selection?.gridLevel;
    final levelDrift =
        feLevel != null && serverLevel != null && feLevel != serverLevel;

    // Per-pin scoring: prefer the currently-focused pin's breakdown; otherwise
    // list the top few by score.
    final breakdowns = debug.pinBreakdowns.values.toList()
      ..sort((a, b) => (b.score ?? 0).compareTo(a.score ?? 0));
    // The focused-pin provider holds the MARKER id, which is built as
    // `${entity}_${id}` in map_selection_provider — so match the breakdown's
    // `${entity}_${id}`, not its raw id, or inspection never resolves.
    final focusedId = ref.watch(mapFocusedPinProvider);
    MapPinScoreBreakdown? focused;
    if (focusedId != null) {
      for (final b in breakdowns) {
        if ('${b.entity}_${b.id}' == focusedId) {
          focused = b;
          break;
        }
      }
    }

    return [
      const _DebugSection('Request'),
      _DebugRow(label: 'pins_version', value: '${debug.pinsVersion ?? '—'}'),
      _DebugRow(label: 'radius_enforced', value: _bool(debug.radiusEnforced)),
      _DebugRow(label: 'source venue', value: debug.sourcePath?.venue ?? '—'),
      _DebugRow(label: 'source event', value: debug.sourcePath?.event ?? '—'),

      const _DebugSection('Retrieval'),
      _DebugRow(label: 'venue', value: _leg(retrieval?.venue)),
      _DebugRow(label: 'event', value: _leg(retrieval?.event)),

      const _DebugSection('Grid'),
      _DebugRow(
        label: 'cell size',
        value: grid?.cellSizeDeg == null
            ? '—'
            : '${_fmt(grid!.cellSizeDeg!.lat, frac: 5)} × '
                  '${_fmt(grid.cellSizeDeg!.lng, frac: 5)}°',
      ),
      _DebugRow(label: 'cells across', value: '${grid?.cellsAcross ?? '—'}'),
      _DebugRow(label: 'occupied', value: '${grid?.occupiedCells ?? '—'}'),
      _DebugRow(label: 'grid level', value: '${selection?.gridLevel ?? '—'}'),
      _DebugRow(label: 'band cap', value: '${selection?.bandCap ?? '—'}'),
      _DebugRow(label: 'clusters', value: _bool(selection?.clustersAllowed)),
      _DebugRow(
        label: 'low-zoom supp.',
        value: _bool(selection?.lowZoomSuppressed),
      ),

      const _DebugSection('Grid drift (FE vs server)'),
      _DebugRow(
        label: 'base level',
        value:
            '${feLevel ?? '—'} / ${serverLevel ?? '—'}'
            '${levelDrift ? '  ⚠' : ''}',
      ),
      _DebugRow(
        label: 'target cell px',
        value: '${kTargetCellPx.toStringAsFixed(0)} (FE)',
      ),
      _DebugRow(label: 'selection cap', value: '$kSelectionCap (FE)'),

      _DebugSection('Pins (${debug.pinBreakdowns.length} scored)'),
      if (focused != null) ...[
        const _DebugHint('Focused pin:'),
        ..._pinBreakdownRows(focused),
        const _DebugDivider(),
      ] else
        const _DebugHint('Tap a pin to inspect its score breakdown.'),
      if (breakdowns.isEmpty)
        const _DebugHint('No per-pin scoring in this response.')
      else ...[
        for (final b in breakdowns.take(5))
          _DebugRow(
            label: '${b.entity} ${_short(b.id)}',
            value:
                'score ${_fmt(b.score)}'
                '${b.distanceM == null ? '' : ' · ${_fmt(b.distanceM, frac: 0)}m'}'
                '${b.cellX == null ? '' : ' · (${b.cellX},${b.cellY})'}',
          ),
        if (breakdowns.length > 5)
          _DebugHint('+${breakdowns.length - 5} more (top 5 by score shown)'),
      ],
    ];
  }

  /// Full breakdown rows for a single pin (the focused one). Renders only the
  /// axes actually present, so venue pins (list/quality/blend/personalization)
  /// and event pins (time/meili relevance) each show their own signals — the
  /// `score_breakdown` shape is entity-dependent (BE heads-up 2026-07-09).
  List<Widget> _pinBreakdownRows(MapPinScoreBreakdown b) => [
    _DebugRow(label: '${b.entity} id', value: _short(b.id)),
    _DebugRow(label: 'score', value: _fmt(b.score)),
    _DebugRow(
      label: 'distance',
      value: b.distanceM == null ? '—' : '${_fmt(b.distanceM, frac: 0)} m',
    ),
    _DebugRow(
      label: 'cell',
      value: b.cellX == null ? '—' : '(${b.cellX}, ${b.cellY})',
    ),
    // Event axes.
    if (b.timeRelevance != null)
      _DebugRow(label: 'time relevance', value: _fmt(b.timeRelevance)),
    if (b.meiliRelevance != null)
      _DebugRow(label: 'meili relevance', value: _fmt(b.meiliRelevance)),
    // Venue axes.
    if (b.listBoost != null)
      _DebugRow(label: 'list boost', value: _axis(b.listBoost)),
    if (b.qualitySignal != null)
      _DebugRow(label: 'quality', value: _axis(b.qualitySignal)),
    if (b.blendList != null || b.blendQuality != null)
      _DebugRow(
        label: 'blend l/q',
        value: '${_fmt(b.blendList)} / ${_fmt(b.blendQuality)}',
      ),
    if (b.personalization != null)
      _DebugRow(
        label: 'personalization',
        value:
            '${b.personalization!.level ?? '—'} · w ${_fmt(b.personalization!.weight)}',
      ),
  ];

  static String _fmt(double? v, {int frac = 2}) =>
      v == null ? '—' : v.toStringAsFixed(frac);

  static String _searchCenterLabel(ResolvedSearchLocation? searchCenter) {
    if (searchCenter == null) return 'Loading…';
    return searchCenterPromptName(searchCenter).isEmpty
        ? '— (unnamed)'
        : searchCenterPromptName(searchCenter);
  }

  static String _mapBoundaryLabel(
    GeoBoundary? boundary, {
    required bool resolving,
  }) {
    if (boundary == null) return resolving ? 'Resolving…' : '— (unresolved)';
    return '${boundary.displayName} (${boundary.level.name})';
  }

  static String _leavePromptState({
    required ResolvedSearchLocation? searchCenter,
    required GeoBoundary? settledBoundary,
    required bool resolving,
  }) {
    if (searchCenter == null) return 'Waiting for Search Center';
    if (settledBoundary == null) {
      return resolving
          ? 'Waiting for map boundary'
          : 'No — unresolved map area';
    }
    return shouldPromptToUpdateSearchCenter(
          searchCenter: searchCenter,
          settledBoundary: settledBoundary,
        )
        ? 'Yes — leaving should ask'
        : 'No — same/unsupported area';
  }

  static String _bool(bool? v) => v == null ? '—' : (v ? 'yes' : 'no');

  static String _short(String id) =>
      id.length <= 8 ? id : '${id.substring(0, 8)}…';

  /// A retrieval leg: `fetched (capped) · budget N · Xms`.
  static String _leg(MapDebugRetrievalLeg? leg) {
    if (leg == null) return '—';
    final capped = leg.capped == true ? ' (capped)' : '';
    final budget = leg.budget == null ? '' : ' · budget ${leg.budget}';
    final ms = leg.ms == null ? '' : ' · ${_fmt(leg.ms, frac: 1)}ms';
    return '${leg.fetched ?? '—'}$capped$budget$ms';
  }

  /// A scoring axis: `raw R · norm N · <extras>`.
  static String _axis(ScoreAxis? a) {
    if (a == null) return '—';
    final parts = <String>[
      if (a.raw != null) 'raw ${_fmt(a.raw)}',
      if (a.norm != null) 'norm ${_fmt(a.norm)}',
      for (final e in a.extras.entries) '${e.key} ${e.value}',
    ];
    return parts.isEmpty ? '—' : parts.join(' · ');
  }
}

/// PROD-2971 — copy the raw `debug` block JSON to the clipboard (for filing bugs
/// / sharing with the BE team). Flips to a "Copied" tick for a moment on tap.
class _CopyJsonButton extends StatefulWidget {
  const _CopyJsonButton({required this.debug});

  final MapDebug debug;

  @override
  State<_CopyJsonButton> createState() => _CopyJsonButtonState();
}

class _CopyJsonButtonState extends State<_CopyJsonButton> {
  bool _copied = false;
  Timer? _resetTimer;

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  void _copy() {
    const encoder = JsonEncoder.withIndent('  ');
    Clipboard.setData(ClipboardData(text: encoder.convert(widget.debug.raw)));
    setState(() => _copied = true);
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: _copy,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              _copied ? LucideIcons.check : LucideIcons.copy,
              size: 14,
              color: AppColors.sokoInk,
            ),
            const SizedBox(width: 4),
            Text(
              _copied ? 'Copied' : 'JSON',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: AppColors.sokoInk,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// PROD-2971 — the overlay-shape legend + per-shape on/off toggles. Each row is
/// a colour swatch (matching the drawn shape) + label + a check; tapping toggles
/// that shape in [mapDebugShapesProvider].
class _ShapeLegend extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final enabled = ref.watch(mapDebugShapesProvider);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final style in kMapDebugShapeStyles)
          _ShapeToggleRow(
            style: style,
            on: enabled.contains(style.shape),
            onTap: () {
              final next = {...enabled};
              if (next.contains(style.shape)) {
                next.remove(style.shape);
              } else {
                next.add(style.shape);
              }
              ref.read(mapDebugShapesProvider.notifier).state = next;
            },
          ),
      ],
    );
  }
}

class _ShapeToggleRow extends StatelessWidget {
  const _ShapeToggleRow({
    required this.style,
    required this.on,
    required this.onTap,
  });

  final MapDebugShapeStyle style;
  final bool on;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5, horizontal: 2),
        child: Row(
          children: [
            Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: on
                    ? style.legendColor
                    : style.legendColor.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(3),
                border: Border.all(color: style.legendColor, width: 1.2),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                style.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppColors.sokoInk.withValues(alpha: on ? 1 : 0.5),
                ),
              ),
            ),
            Icon(
              on ? LucideIcons.check : LucideIcons.minus,
              size: 15,
              color: AppColors.sokoInk.withValues(alpha: on ? 0.8 : 0.35),
            ),
          ],
        ),
      ),
    );
  }
}

class _DebugSection extends StatelessWidget {
  const _DebugSection(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 2),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
          color: AppColors.sokoInk.withValues(alpha: 0.5),
        ),
      ),
    );
  }
}

class _DebugDivider extends StatelessWidget {
  const _DebugDivider();

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Divider(height: 1, color: AppColors.sokoInk.withValues(alpha: 0.1)),
  );
}

class _DebugHint extends StatelessWidget {
  const _DebugHint(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12,
          fontStyle: FontStyle.italic,
          color: AppColors.sokoInk.withValues(alpha: 0.6),
        ),
      ),
    );
  }
}

class _DebugSwitchRow extends StatelessWidget {
  const _DebugSwitchRow({
    required this.label,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.sokoInk,
              ),
            ),
          ),
          Switch.adaptive(
            value: value,
            activeThumbColor: AppColors.sokoInk,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}

class _DebugRow extends StatelessWidget {
  const _DebugRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 108,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: AppColors.sokoInk.withValues(alpha: 0.6),
              ),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.sokoInk,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// PROD-3124 — live-tuning sliders for the dot hints. "Max dots" overrides the
/// zoom-band allowance (30–200); "Events share" overrides the 80/20
/// event/venue split. Both write DEBUG-KNOB overrides
/// ([mapDotAllowanceOverrideProvider] / [mapDotEventShareOverrideProvider])
/// that [mapDotHintsProvider] watches — dragging re-runs dot selection over
/// the **cached** pool instantly, no refetch. Overrides reset when the map
/// page is left (autoDispose); "Reset" clears them back to the shipped
/// constants.
class _DotHintsSection extends ConsumerWidget {
  const _DotHintsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final q = ref.watch(mapQueryProvider);
    final capOverride = ref.watch(mapDotAllowanceOverrideProvider);
    final shareOverride = ref.watch(mapDotEventShareOverrideProvider);

    // The effective values the selection is running with right now.
    final bandCap = dotCapFor(q.source, q.zoom);
    final cap = (capOverride ?? bandCap).clamp(30, 200);
    final share = shareOverride ?? kDotEventShare;
    final eventPct = (share * 100).round();
    final overridden = capOverride != null || shareOverride != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(
              LucideIcons.circle_dot,
              size: 14,
              color: AppColors.sokoInk,
            ),
            const SizedBox(width: 6),
            const Text(
              'Dot hints',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.sokoInk,
              ),
            ),
            const Spacer(),
            if (overridden)
              InkWell(
                onTap: () {
                  ref.read(mapDotAllowanceOverrideProvider.notifier).state =
                      null;
                  ref.read(mapDotEventShareOverrideProvider.notifier).state =
                      null;
                },
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 4,
                  ),
                  child: Text(
                    'Reset',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: AppColors.sokoInk.withValues(alpha: 0.7),
                    ),
                  ),
                ),
              ),
          ],
        ),
        _DebugSliderRow(
          label: 'Max dots',
          value: '$cap${capOverride == null ? ' (band)' : ''}',
          slider: Slider.adaptive(
            value: cap.toDouble(),
            min: 30,
            max: 200,
            divisions: 17,
            label: '$cap',
            activeColor: AppColors.sokoInk,
            onChanged: (v) =>
                ref.read(mapDotAllowanceOverrideProvider.notifier).state = v
                    .round(),
          ),
        ),
        _DebugSliderRow(
          label: 'Split',
          value:
              '$eventPct% events / ${100 - eventPct}% venues'
              '${shareOverride == null ? ' (default)' : ''}',
          slider: Slider.adaptive(
            value: eventPct.toDouble(),
            min: 0,
            max: 100,
            divisions: 20,
            label: '$eventPct% ev',
            activeColor: AppColors.sokoInk,
            onChanged: (v) =>
                ref.read(mapDotEventShareOverrideProvider.notifier).state =
                    v.round() / 100,
          ),
        ),
        Text(
          'Client-side re-selection over the cached pool — no refetch. '
          'Resets on leaving the map.',
          style: TextStyle(
            fontSize: 11,
            height: 1.3,
            color: AppColors.sokoInk.withValues(alpha: 0.55),
          ),
        ),
      ],
    );
  }
}

/// A labelled slider row for the debug panel: value read-out on the label
/// line, the slider full-width below it (the panel is too narrow for both
/// side-by-side).
class _DebugSliderRow extends StatelessWidget {
  const _DebugSliderRow({
    required this.label,
    required this.value,
    required this.slider,
  });

  final String label;
  final String value;
  final Widget slider;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 108,
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    color: AppColors.sokoInk.withValues(alpha: 0.6),
                  ),
                ),
              ),
              Expanded(
                child: Text(
                  value,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.sokoInk,
                  ),
                ),
              ),
            ],
          ),
        ),
        SizedBox(
          height: 28,
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 2,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
            ),
            child: slider,
          ),
        ),
      ],
    );
  }
}

/// PROD-2948 (FE-2) — admin-only personalization picker inside the debug panel.
/// Writes [mapPersonalizationLevelProvider]; the map refetches + re-ranks via the
/// listener in `MapPinsNotifier`. Sends `personalization_level` (backend clamps
/// non-admins to `off`), so it's inert unless the caller is an admin AND the
/// server axis flags are on.
class _PersonalizationSection extends ConsumerWidget {
  const _PersonalizationSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final level = ref.watch(mapPersonalizationLevelProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Row(
          children: [
            Icon(
              LucideIcons.sliders_horizontal,
              size: 14,
              color: AppColors.sokoInk,
            ),
            SizedBox(width: 6),
            Text(
              'Personalization',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppColors.sokoInk,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final l in MapPersonalizationLevel.values)
              _LevelChip(
                label: l.label,
                selected: l == level,
                onTap: () =>
                    ref.read(mapPersonalizationLevelProvider.notifier).state =
                        l,
              ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Sent as personalization_level. Needs the staging axis flags on to '
          'change ranking.',
          style: TextStyle(
            fontSize: 11,
            height: 1.3,
            color: AppColors.sokoInk.withValues(alpha: 0.55),
          ),
        ),
      ],
    );
  }
}

/// One selectable pill in the [_PersonalizationSection] row. Selected = filled
/// ink; unselected = outlined.
class _LevelChip extends StatelessWidget {
  const _LevelChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: selected ? AppColors.sokoInk : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: selected
                  ? AppColors.sokoInk
                  : AppColors.sokoInk.withValues(alpha: 0.3),
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: selected ? AppColors.sokoPaper : AppColors.sokoInk,
            ),
          ),
        ),
      ),
    );
  }
}
