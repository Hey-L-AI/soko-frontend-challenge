import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/services/location_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../data/models/models.dart';
import '../../../features/lists/models/search_scope.dart';
import '../../../features/lists/widgets/location_scope_picker_sheet.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart';
import '../../../providers/city_auto_scope_provider.dart';
import '../../../providers/location_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../providers/user_profiling_provider.dart';

/// Step 0 — capture the user's home city via a centered, underline-style
/// "input" that opens the country+city scope picker on tap, plus an
/// optional free-text neighbourhood.
///
/// The input displays only the city name (no country suffix) — country
/// selection happens inside the picker sheet. City entries come from
/// `/geo/cities` autocomplete, so typing arbitrary strings can no longer
/// leak into the submit payload.
///
/// Auto-prefill on mount:
///   - If GPS permission is already granted → silently fetch the device
///     fix and resolve the city.
///   - Otherwise → use `cityAutoScopeProvider` (IP cascade) to prefill.
class LocationStep extends ConsumerStatefulWidget {
  const LocationStep({super.key});

  @override
  ConsumerState<LocationStep> createState() => _LocationStepState();
}

class _LocationStepState extends ConsumerState<LocationStep> {
  late final TextEditingController _cityController;
  late final TextEditingController _neighbourhoodController;
  bool _isLocating = false;
  bool _isPrefilling = false;
  bool _autoPrefilled = false;

  @override
  void initState() {
    super.initState();
    final state = ref.read(userProfilingProvider);
    _cityController = TextEditingController(text: state.cityName ?? '');
    _neighbourhoodController = TextEditingController(text: state.neighbourhood);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _autoPrefill();
    });
  }

  @override
  void dispose() {
    _cityController.dispose();
    _neighbourhoodController.dispose();
    super.dispose();
  }

  // ---- Auto-prefill on entry --------------------------------------------

  /// GPS-first prefill: if the OS already granted location, silently
  /// reverse-resolve the city via locationProvider and apply. Otherwise
  /// fall back to the IP cascade. Silent — no toasts, no errors. The
  /// user can always tap the input to override.
  Future<void> _autoPrefill() async {
    if (_autoPrefilled) return;
    if (ref.read(userProfilingProvider).cityName != null) return;
    setState(() => _isPrefilling = true);
    try {
      final locNotifier = ref.read(locationProvider.notifier);
      final status = await locNotifier.checkPermission();
      if (!mounted) return;

      if (status == LocationPermissionStatus.granted) {
        // requestPermissionOnly() is idempotent when status==granted —
        // it fetches a fresh GPS fix and PUTs /users/me/location, which
        // populates `resolvedCityName` + `resolvedCountryCode` from the
        // backend's reverse-geocode.
        var locState = ref.read(locationProvider);
        if (locState.lastLocation == null ||
            locState.resolvedCityName == null ||
            locState.resolvedCountryCode == null) {
          await locNotifier.requestPermissionOnly();
          if (!mounted) return;
          locState = ref.read(locationProvider);
        }
        final snap = locState.lastLocation;
        final cityName = locState.resolvedCityName;
        final country = _normalizeCountry(locState.resolvedCountryCode);
        if (snap != null && cityName != null && country != null) {
          if (ref.read(userProfilingProvider).cityName != null) return;
          final geoCity = await _resolveGeoCity(
            iso2: country.iso2,
            name: cityName,
          );
          if (!mounted) return;
          if (ref.read(userProfilingProvider).cityName != null) return;
          ref
              .read(userProfilingProvider.notifier)
              .setLocation(
                cityId: geoCity?.id ?? 'gps:${snap.lat},${snap.lon}',
                cityName: geoCity?.name ?? cityName,
                iso2: country.iso2,
                countryName: country.countryName,
                latitude: snap.lat,
                longitude: snap.lon,
              );
          _autoPrefilled = true;
          return;
        }
      }

      // No GPS permission, or GPS granted but no usable fix → IP cascade.
      final scope = await ref.read(cityAutoScopeProvider.future);
      if (!mounted) return;
      if (scope is SearchScopeCountryCity &&
          ref.read(userProfilingProvider).cityName == null) {
        ref
            .read(userProfilingProvider.notifier)
            .setLocation(
              cityId: scope.city.id,
              cityName: scope.city.name,
              iso2: scope.iso2,
              countryName: scope.countryName,
              latitude: scope.city.latitude,
              longitude: scope.city.longitude,
            );
        _autoPrefilled = true;
      }
    } catch (_) {
      // Silent — the user can still tap the input to pick manually.
    } finally {
      if (mounted) setState(() => _isPrefilling = false);
    }
  }

  /// Normalize whatever `locationProvider` returns as `resolvedCountryCode`
  /// into a proper ISO-2 + canonical name pair.
  ///
  /// The field name is a misnomer: the backend returns a full country name
  /// (e.g. "Portugal") via `LocationUpdateResponse.country`, which the
  /// provider uppercases → "PORTUGAL". We need a clean ISO-2 ("PT") and
  /// proper-case name ("Portugal") to drive the picker and the submit.
  ///
  /// Returns null when the raw value isn't recognisable — caller should
  /// then skip this branch and fall back to the IP cascade.
  ({String iso2, String countryName})? _normalizeCountry(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    // Already a 2-letter ISO code.
    if (raw.length == 2) {
      final upper = raw.toUpperCase();
      return (
        iso2: upper,
        countryName: kSokoCountryNamesByIso2[upper] ?? upper,
      );
    }
    // Full name in any case — title-case it and look up the ISO-2.
    final titled = raw
        .split(' ')
        .map(
          (w) => w.isEmpty
              ? w
              : '${w[0].toUpperCase()}${w.substring(1).toLowerCase()}',
        )
        .join(' ');
    final iso2 = kSokoCountryCodes[titled];
    if (iso2 != null) return (iso2: iso2, countryName: titled);
    return null;
  }

  /// Hit `/geo/cities` with the reverse-geocoded city name so we end up
  /// with a real `GeoCity` (id + display name + coords). Returns null on
  /// failure; the caller falls back to a synthetic `gps:<lat>,<lon>` id.
  Future<GeoCity?> _resolveGeoCity({
    required String iso2,
    required String name,
  }) async {
    try {
      final geoApi = ref.read(geoApiProvider);
      final sessionToken = const Uuid().v4();
      final locale = Localizations.localeOf(context).toLanguageTag();
      final response = await geoApi.searchCities(
        countryCode: iso2,
        q: name,
        sessionToken: sessionToken,
        locale: locale,
        limit: 5,
      );
      if (response.items.isEmpty) return null;
      final lower = name.toLowerCase();
      for (final c in response.items) {
        if (c.name.toLowerCase() == lower) return c;
      }
      return response.items.first;
    } catch (_) {
      return null;
    }
  }

  // ---- Picker on tap ---------------------------------------------------

  Future<void> _openPicker() async {
    // Drop focus so the placeholder/value text settles before the sheet
    // animates in (the field is read-only but tap still gives it focus).
    FocusManager.instance.primaryFocus?.unfocus();

    final state = ref.read(userProfilingProvider);
    final autoScope = await ref.read(cityAutoScopeProvider.future);
    if (!mounted) return;

    // Build the current scope from state (if any) so the picker opens
    // with the user's prior pick selected.
    SearchScope? currentScope;
    if (state.cityName != null && state.iso2 != null) {
      currentScope = SearchScopeCountryCity(
        iso2: state.iso2!,
        countryName: state.countryName ?? state.iso2!,
        city: GeoCity(
          id: state.cityId ?? 'gps:${state.latitude},${state.longitude}',
          name: state.cityName!,
          displayName: state.cityName!,
          source: 'local',
          latitude: state.latitude,
          longitude: state.longitude,
          countryCode: state.iso2,
        ),
      );
    }

    // Open the map picker seeded with the user's prior pick (or the
    // auto-detected scope). The "Use my exact location" CTA covers the GPS
    // path separately, so profiling doesn't need a reset-to-auto affordance.
    final picked = await showLocationScopePicker(
      context,
      ref,
      currentScope: currentScope ?? autoScope,
    );
    if (!mounted || picked == null) return;
    // Accept either producer: the old country/city sheet or the map picker's
    // area (once it resolved a seeded city). A point-pick area with no
    // containing boundary yields no city → leave the prior selection intact.
    final selection = cityScopeSelection(picked);
    if (selection != null) {
      final city = selection.city;
      ref
          .read(userProfilingProvider.notifier)
          .setLocation(
            cityId: city.id,
            cityName: city.name,
            iso2: selection.iso2,
            countryName:
                kSokoCountryNamesByIso2[selection.iso2] ?? selection.iso2,
            latitude: city.latitude,
            longitude: city.longitude,
          );
    }
  }

  // ---- "Use my current location" CTA ------------------------------------

  Future<void> _handleUseMyLocation() async {
    if (_isLocating) return;
    setState(() => _isLocating = true);
    try {
      final l = Lt.of(context);
      final locNotifier = ref.read(locationProvider.notifier);

      // Native permission prompt (no-op when already granted) + GPS fetch
      // + PUT /users/me/location. Populates resolvedCityName/Country from
      // the backend's reverse-geocode.
      final status = await locNotifier.requestPermissionOnly();
      if (!mounted) return;

      if (status == LocationPermissionStatus.granted) {
        final locState = ref.read(locationProvider);
        final snap = locState.lastLocation;
        final cityName = locState.resolvedCityName;
        final country = _normalizeCountry(locState.resolvedCountryCode);
        if (snap != null && cityName != null && country != null) {
          final geoCity = await _resolveGeoCity(
            iso2: country.iso2,
            name: cityName,
          );
          if (!mounted) return;
          ref
              .read(userProfilingProvider.notifier)
              .setLocation(
                cityId: geoCity?.id ?? 'gps:${snap.lat},${snap.lon}',
                cityName: geoCity?.name ?? cityName,
                iso2: country.iso2,
                countryName: country.countryName,
                latitude: snap.lat,
                longitude: snap.lon,
              );
          showSoko(
            ref,
            message: l.personaOnboardingLocationCaptured,
            variant: SokoVariant.success,
          );
          return;
        }
      }

      // Denied / no GPS fix / web w/o hardware → IP cascade fallback.
      final scope = await ref.read(cityAutoScopeProvider.future);
      if (!mounted) return;
      if (scope is SearchScopeCountryCity) {
        ref
            .read(userProfilingProvider.notifier)
            .setLocation(
              cityId: scope.city.id,
              cityName: scope.city.name,
              iso2: scope.iso2,
              countryName: scope.countryName,
              latitude: scope.city.latitude,
              longitude: scope.city.longitude,
            );
        showSoko(
          ref,
          message: l.personaOnboardingLocationCaptured,
          variant: SokoVariant.success,
        );
      } else {
        showSoko(
          ref,
          message: l.personaOnboardingLocationFailed,
          variant: SokoVariant.error,
        );
      }
    } catch (_) {
      if (!mounted) return;
      showSoko(
        ref,
        message: Lt.of(context).personaOnboardingLocationFailed,
        variant: SokoVariant.error,
      );
    } finally {
      if (mounted) setState(() => _isLocating = false);
    }
  }

  // ---- Build ------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(userProfilingProvider.notifier);

    // Mirror provider-driven city updates (auto-prefill, picker pick, GPS
    // capture) into the read-only city input so the visible value stays
    // in sync.
    ref.listen<String?>(userProfilingProvider.select((s) => s.cityName), (
      _,
      next,
    ) {
      final text = next ?? '';
      if (_cityController.text != text) {
        _cityController.value = TextEditingValue(
          text: text,
          selection: TextSelection.collapsed(offset: text.length),
        );
      }
    });

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: IntrinsicHeight(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 40, 24, 32),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Text(
                      Lt.of(context).personaOnboardingLocationTitle,
                      textAlign: TextAlign.center,
                      style: AppTheme.displayPrimary(
                        fontSize: 42,
                        fontWeight: FontWeight.w300,
                        color: AppColors.sokoInk,
                        height: 0.94,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          _UnderlineField(
                            controller: _cityController,
                            placeholder: Lt.of(
                              context,
                            ).personaOnboardingCityPlaceholder,
                            readOnly: true,
                            showSpinner: _isPrefilling,
                            onTap: _openPicker,
                          ),
                          const SizedBox(height: 20),
                          _UnderlineField(
                            controller: _neighbourhoodController,
                            placeholder: Lt.of(
                              context,
                            ).personaOnboardingNeighbourhoodPlaceholder,
                            onChanged: notifier.setNeighbourhood,
                          ),
                          const SizedBox(height: 48),
                          SokoCtaButton(
                            label: Lt.of(
                              context,
                            ).personaOnboardingUseMyLocation,
                            icon: Icons.place_outlined,
                            variant: SokoCtaVariant.green,
                            expand: false,
                            loading: _isLocating,
                            onPressed: _handleUseMyLocation,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _UnderlineField extends StatelessWidget {
  final TextEditingController controller;
  final String placeholder;
  final ValueChanged<String>? onChanged;
  final VoidCallback? onTap;
  final bool readOnly;
  final bool showSpinner;

  const _UnderlineField({
    required this.controller,
    required this.placeholder,
    this.onChanged,
    this.onTap,
    this.readOnly = false,
    this.showSpinner = false,
  });

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      onChanged: onChanged,
      onTap: onTap,
      readOnly: readOnly,
      // Read-only inputs should not grab system focus / mount the soft
      // keyboard — they only open the picker sheet.
      canRequestFocus: !readOnly,
      showCursor: !readOnly,
      textAlign: TextAlign.center,
      style: AppTheme.body(
        fontSize: 24,
        fontWeight: FontWeight.w400,
        color: AppColors.textPrimary,
      ),
      decoration: InputDecoration(
        hintText: placeholder,
        hintStyle: AppTheme.body(
          fontSize: 24,
          fontWeight: FontWeight.w400,
          color: AppColors.textTertiary,
        ),
        // Override the global `filled: true` theme — the location step uses
        // a flat underline-only look, not a filled rounded-rect.
        filled: false,
        fillColor: Colors.transparent,
        contentPadding: const EdgeInsets.symmetric(vertical: 12),
        border: const UnderlineInputBorder(
          borderSide: BorderSide(color: AppColors.textPrimary),
        ),
        enabledBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: AppColors.textPrimary),
        ),
        focusedBorder: const UnderlineInputBorder(
          borderSide: BorderSide(color: AppColors.textPrimary, width: 1.5),
        ),
        suffixIcon: showSpinner
            ? const SizedBox(
                width: 18,
                height: 18,
                child: Padding(
                  padding: EdgeInsets.all(2),
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.textPrimary,
                  ),
                ),
              )
            : null,
        suffixIconConstraints: const BoxConstraints(
          minWidth: 24,
          minHeight: 24,
        ),
      ),
    );
  }
}
