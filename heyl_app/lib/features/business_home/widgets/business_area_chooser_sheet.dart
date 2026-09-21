import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/location_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/area_prediction.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/locale_provider.dart';
import '../../../providers/location_provider.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/soko_text_field.dart';
import '../../map/utils/map_boundary_scope.dart' as boundary_scope;
import '../../map/widgets/area_search_controller.dart';
import '../../map/widgets/area_search_dropdown.dart';
import '../providers/business_search_area_providers.dart';

/// The map-less "Search area" chooser for the Business Connect claim finder
/// (PROD-4268, S3). Reuses the same `AreaSearchController` + `AreaSearchDropdown`
/// pair the map location picker composes (`lists/widgets/location_scope_sheet.dart`),
/// minus the map: type a city/area, pick it, or use **Use my location** /
/// **Search without an area**.
///
/// It only ever calls the local Business Connect area provider — it does not
/// touch `cityScopeProvider` or global Discovery location. Location permission
/// is requested **only** on the explicit "Use my location" tap (spec §4.3), and
/// a denial/failure keeps the previous choice.
class BusinessAreaChooserSheet extends ConsumerStatefulWidget {
  const BusinessAreaChooserSheet({super.key});

  @override
  ConsumerState<BusinessAreaChooserSheet> createState() =>
      _BusinessAreaChooserSheetState();
}

class _BusinessAreaChooserSheetState
    extends ConsumerState<BusinessAreaChooserSheet> {
  final _searchTextController = TextEditingController();
  final _searchFocusNode = FocusNode();
  late final AreaSearchController _search;

  bool _searchFocused = false;
  bool _searchDropdownFocused = false;
  bool _submittedSearchOpen = false;
  bool _searchError = false;
  bool _resolving = false;
  bool _locating = false;
  bool _locationDenied = false;

  CancelToken? _resolveCancel;
  late String _locale;
  bool _localeInitialized = false;

  @override
  void initState() {
    super.initState();
    // Bias autocomplete toward the already-available fix when there is one; a
    // read (never a subscription) so this sheet doesn't rebuild on GPS ticks.
    final fix = ref.read(locationStateProvider).lastLocation;
    _search = AreaSearchController(
      search: (q, token, cancel) => ref
          .read(geoApiProvider)
          .searchAreas(
            q: q,
            sessionToken: token,
            locale: _locale,
            nearLat: fix?.lat,
            nearLng: fix?.lon,
            cancelToken: cancel,
          ),
      deepSearch: (q, cancel) => ref
          .read(geoApiProvider)
          .deepSearch(
            q: q,
            locale: _locale,
            nearLat: fix?.lat,
            nearLng: fix?.lon,
            cancelToken: cancel,
          ),
    );
    _searchTextController.addListener(() {
      setState(() {
        if (_searchError) _searchError = false;
        _submittedSearchOpen = false;
      });
      _search.onQueryChanged(_searchTextController.text);
    });
    _searchFocusNode.addListener(
      () => setState(() => _searchFocused = _searchFocusNode.hasFocus),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_localeInitialized) {
      // The API locale code (matches Accept-Language), NOT
      // Localizations.localeOf — see location_scope_sheet.dart.
      _locale = ref.read(apiLocaleCodeProvider) ?? 'en';
      _localeInitialized = true;
    }
  }

  @override
  void dispose() {
    _resolveCancel?.cancel('disposed');
    _searchTextController.dispose();
    _searchFocusNode.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _submitSearch(String raw) async {
    if (raw.trim().length < _search.minChars) return;
    setState(() => _submittedSearchOpen = true);
    await _search.submitQuery(raw);
  }

  Future<void> _handleSearchSelect(AreaPrediction prediction) async {
    _resolveCancel?.cancel('superseded');
    _resolveCancel = CancelToken();
    _searchDropdownFocused = false;
    _searchFocusNode.unfocus();
    setState(() {
      _resolving = true;
      _searchError = false;
      _submittedSearchOpen = false;
    });

    ResolvedArea? area;
    try {
      area = await boundary_scope.resolveSearchPrediction(
        prediction,
        () => ref
            .read(geoApiProvider)
            .resolveArea(
              id: prediction.id,
              sessionToken: _search.sessionToken,
              locale: _locale,
              cancelToken: _resolveCancel,
            ),
      );
    } catch (_) {
      area = null;
    }
    if (!mounted) return;
    _search.afterResolve();

    if (area == null) {
      setState(() {
        _resolving = false;
        _searchError = true;
      });
      return;
    }

    final boundary = area.boundary;
    ref
        .read(businessSearchAreaProvider.notifier)
        .setArea(
          latitude: boundary.centroidLat,
          longitude: boundary.centroidLon,
          label: businessAreaLabelForBoundary(boundary),
          countryCode: boundary.countryCode,
        );
    Navigator.of(context).pop();
  }

  Future<void> _useMyLocation() async {
    if (_locating) return;
    setState(() {
      _locating = true;
      _locationDenied = false;
    });
    // Permission is requested here and ONLY here (spec §4.3) — getCurrentLocation
    // may prompt. A denial/failure keeps the previous choice.
    final result = await ref.read(locationServiceProvider).getCurrentLocation();
    if (!mounted) return;
    if (!result.isSuccess) {
      setState(() {
        _locating = false;
        _locationDenied = true;
      });
      return;
    }

    final lat = result.latitude!;
    final lng = result.longitude!;
    // Reverse-geocode once for a {city, country} label (D1). A null boundary
    // (coverage gap) still yields a usable area, labelled generically.
    String? label;
    String? countryCode;
    try {
      final boundary = await ref
          .read(geoApiProvider)
          .resolveBoundaryAt(lat: lat, lng: lng, locale: _locale);
      if (boundary != null) {
        label = businessAreaLabelForBoundary(boundary);
        countryCode = boundary.countryCode;
      }
    } catch (_) {
      label = null;
    }
    if (!mounted) return;
    label ??= Lt.of(context).businessHomeAreaCurrentLocation;

    ref
        .read(businessSearchAreaProvider.notifier)
        .setArea(
          latitude: lat,
          longitude: lng,
          label: label,
          countryCode: countryCode,
        );
    Navigator.of(context).pop();
  }

  void _searchWithoutArea() {
    ref.read(businessSearchAreaProvider.notifier).useNoArea();
    Navigator.of(context).pop();
  }

  void _handleSearchDropdownFocusChanged(bool focused) {
    if (!mounted || _searchDropdownFocused == focused) return;
    setState(() => _searchDropdownFocused = focused);
  }

  bool get _showDropdown =>
      _searchTextController.text.trim().isNotEmpty &&
      (_searchFocused || _searchDropdownFocused || _submittedSearchOpen);

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return DSSheetShell(
      bodyPadding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.businessHomeAreaChooserTitle,
            style: const TextStyle(
              fontFamily: 'UnJamoBatang',
              fontSize: 24,
              height: .96,
              letterSpacing: -1,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 12),
          SokoTextField(
            controller: _searchTextController,
            focusNode: _searchFocusNode,
            hintText: l10n.businessHomeAreaChooserSearchHint,
            textInputAction: TextInputAction.search,
            onSubmitted: _submitSearch,
            prefix: const Icon(
              LucideIcons.search,
              size: 18,
              color: AppColors.sokoInk,
            ),
          ),
          if (_showDropdown) ...[
            const SizedBox(height: 8),
            Material(
              borderRadius: BorderRadius.circular(12),
              clipBehavior: Clip.antiAlias,
              color: AppColors.sokoPaper,
              child: AreaSearchDropdown(
                controller: _search,
                onSelect: _handleSearchSelect,
                onFocusChanged: _handleSearchDropdownFocusChanged,
                searchFocusNode: _searchFocusNode,
                onLoadMore: () => _submitSearch(_searchTextController.text),
              ),
            ),
          ],
          if (_resolving) ...[
            const SizedBox(height: 12),
            const Center(
              child: SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: AppColors.sokoPink,
                ),
              ),
            ),
          ],
          if (_searchError) ...[
            const SizedBox(height: 8),
            Text(
              l10n.businessHomeSearchError,
              style: const TextStyle(fontSize: 13, color: AppColors.sokoRed),
            ),
          ],
          const SizedBox(height: 16),
          _ActionRow(
            icon: LucideIcons.locate_fixed,
            label: l10n.businessHomeAreaUseMyLocation,
            loading: _locating,
            onTap: _useMyLocation,
          ),
          if (_locationDenied) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                const Icon(
                  LucideIcons.info,
                  size: 14,
                  color: AppColors.sokoShade3,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    l10n.businessHomeAreaLocationDenied,
                    style: const TextStyle(
                      fontSize: 13,
                      color: AppColors.sokoShade3,
                    ),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 4),
          _ActionRow(
            icon: LucideIcons.globe,
            label: l10n.businessHomeAreaNoArea,
            onTap: _searchWithoutArea,
          ),
        ],
      ),
    );
  }
}

/// A full-width tappable row in the chooser (an icon + label). Carries its own
/// `InkWell`; the sheet supplies the Material ancestor.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.loading = false,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: loading ? null : onTap,
      borderRadius: BorderRadius.circular(10),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: loading
                  ? const CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.sokoInk,
                    )
                  : Icon(icon, size: 20, color: AppColors.sokoInk),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: AppColors.sokoInk,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
