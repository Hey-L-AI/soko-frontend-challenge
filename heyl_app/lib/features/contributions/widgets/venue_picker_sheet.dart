import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/utils/google_maps_url.dart';
import '../../../data/datasources/api/resolve_url_failure.dart';
import '../../../data/models/chat_message.dart' show ItemSuggestion;
import '../../../data/models/resolve_url_result.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/soko_text_field.dart';

/// Result of [showVenuePickerSheet]. `null` on dismiss; [VenuePicked] on
/// selection; [VenueCleared] when the user removes a previously-picked
/// venue (only renders when `preselectedVenueId` is non-null).
sealed class VenuePickerResult {
  const VenuePickerResult();
}

class VenuePicked extends VenuePickerResult {
  final ItemSuggestion venue;
  const VenuePicked(this.venue);
}

class VenueCleared extends VenuePickerResult {
  const VenueCleared();
}

const _minQueryLength = 2;
const _debounceDuration = Duration(milliseconds: 300);

/// Venue picker scoped to the local DB (`SearchApi.searchPlaces` mode='fast',
/// `country: <iso2>`). Google-fallback rows are filtered out because the
/// contribution API requires a UUID `venue_id`; backend text-resolves
/// unknown venues from the LLM + `city`.
Future<VenuePickerResult?> showVenuePickerSheet(
  BuildContext context,
  WidgetRef ref, {
  required String countryIso2,
  String? preselectedVenueId,
  String? preselectedVenueName,
}) {
  return showBottomSheetWithHiddenNav<VenuePickerResult>(
    context: context,
    ref: ref,
    builder: (_) => _VenuePickerSheet(
      countryIso2: countryIso2,
      preselectedVenueId: preselectedVenueId,
      preselectedVenueName: preselectedVenueName,
    ),
  );
}

class _VenuePickerSheet extends ConsumerStatefulWidget {
  final String countryIso2;
  final String? preselectedVenueId;
  final String? preselectedVenueName;

  const _VenuePickerSheet({
    required this.countryIso2,
    required this.preselectedVenueId,
    required this.preselectedVenueName,
  });

  @override
  ConsumerState<_VenuePickerSheet> createState() => _VenuePickerSheetState();
}

class _VenuePickerSheetState extends ConsumerState<_VenuePickerSheet> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  CancelToken? _searchToken;
  int _searchGeneration = 0;
  String _lastQuery = '';

  bool _loading = false;
  String? _error;
  List<ItemSuggestion> _results = const [];

  /// Google Maps link paste flow (PROD-2429 item 5). When the search box
  /// contains a recognised Maps URL, the body switches to a resolve-link
  /// CTA instead of running the local DB search.
  bool _resolving = false;
  ResolveUrlFailure? _resolveError;
  int _resolveGeneration = 0;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onChanged);
  }

  @override
  void dispose() {
    _searchToken?.cancel('disposed');
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onChanged() {
    final q = _searchController.text.trim();
    if (q == _lastQuery) return;
    _lastQuery = q;

    _debounce?.cancel();
    _searchToken?.cancel('new query');
    _searchToken = CancelToken();
    _searchGeneration++;
    // Any in-flight resolve attempt for a previous URL is invalidated by
    // bumping the generation so its async setState becomes a no-op.
    _resolveGeneration++;

    // Maps URL → switch to resolve-link mode, skip the DB search.
    if (GoogleMapsUrl.looksLike(q)) {
      setState(() {
        _results = const [];
        _loading = false;
        _error = null;
        _resolving = false;
        _resolveError = null;
      });
      return;
    }

    if (q.length < _minQueryLength) {
      setState(() {
        _results = const [];
        _loading = false;
        _error = null;
        _resolveError = null;
      });
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
      _resolveError = null;
    });

    _debounce = Timer(_debounceDuration, _search);
  }

  Future<void> _search() async {
    final q = _searchController.text.trim();
    final gen = _searchGeneration;
    final token = _searchToken;
    if (token == null || q.length < _minQueryLength) return;

    try {
      final items = await ref
          .read(searchApiProvider)
          .searchPlaces(
            query: q,
            mode: 'fast',
            country: widget.countryIso2,
            cancelToken: token,
          );
      if (gen != _searchGeneration || !mounted) return;
      // Local-only: contribution API requires UUID venue_id. Google-fallback
      // rows (venueId == null) get filtered out here.
      final local = items.where((it) => it.venueId != null).toList();
      setState(() {
        _results = local;
        _loading = false;
      });
    } catch (e) {
      if (e is DioException && e.type == DioExceptionType.cancel) return;
      if (gen != _searchGeneration || !mounted) return;
      setState(() {
        _loading = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _resolveUrl(String url) async {
    final gen = ++_resolveGeneration;
    setState(() {
      _resolving = true;
      _resolveError = null;
    });

    try {
      final result = await ref.read(venuesApiProvider).resolveVenueFromUrl(url);
      if (gen != _resolveGeneration || !mounted) return;
      switch (result) {
        case ResolveUrlPlace(:final suggestion):
          _pick(suggestion);
        case ResolveUrlListImport():
          // This picker attributes a photo to ONE venue; a shared list can't
          // be picked. Surface it as an unrecognized-URL error.
          setState(() {
            _resolving = false;
            _resolveError = const ResolveUrlUnrecognized();
          });
      }
    } on ResolveUrlFailure catch (failure) {
      if (gen != _resolveGeneration || !mounted) return;
      setState(() {
        _resolving = false;
        _resolveError = failure;
      });
    } catch (_) {
      if (gen != _resolveGeneration || !mounted) return;
      setState(() {
        _resolving = false;
        _resolveError = const ResolveUrlUnknown();
      });
    }
  }

  void _pick(ItemSuggestion venue) {
    Navigator.of(context).pop(VenuePicked(venue));
  }

  void _clear() {
    Navigator.of(context).pop(const VenueCleared());
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return DSSheetShell(
      maxHeightFraction: 0.85,
      header: _Header(
        title: l10n.photoContributionVenuePickerTitle,
        onClose: () => Navigator.of(context).pop(),
      ),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 10),
            child: SokoTextField(
              controller: _searchController,
              hintText: l10n.photoContributionVenueHint,
              autofocus: true,
              prefix: const Icon(
                Icons.search_rounded,
                size: 18,
                color: AppColors.sokoShade3,
              ),
              suffix: _searchController.text.isNotEmpty
                  ? IconButton(
                      icon: const Icon(
                        Icons.clear_rounded,
                        size: 18,
                        color: AppColors.sokoShade3,
                      ),
                      onPressed: _searchController.clear,
                    )
                  : null,
            ),
          ),
          Expanded(child: _buildBody(l10n)),
        ],
      ),
    );
  }

  Widget _buildBody(Lt l10n) {
    final q = _searchController.text.trim();

    // PROD-2429 item 5: pasted Google Maps link → resolve flow instead of
    // a local DB search. `GoogleMapsUrl.extract` is tolerant of surrounding
    // text so a copy-pasted message body still works.
    final mapsUrl = GoogleMapsUrl.extract(q);
    if (mapsUrl != null) {
      return _ResolveLinkBody(
        url: mapsUrl,
        loading: _resolving,
        error: _resolveError,
        onResolve: () => _resolveUrl(mapsUrl),
        l10n: l10n,
      );
    }

    if (q.length < _minQueryLength) {
      if (widget.preselectedVenueId == null) {
        return const SizedBox.shrink();
      }
      return ListView(
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          _ClearVenueRow(
            onTap: _clear,
            venueName: widget.preselectedVenueName,
            l10n: l10n,
          ),
        ],
      );
    }

    if (_loading) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 32),
        child: Center(child: CircularProgressIndicator()),
      );
    }

    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          _error!,
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 13, color: AppColors.sokoShade3),
        ),
      );
    }

    final removeCount = widget.preselectedVenueId != null ? 1 : 0;
    final totalRows = removeCount + _results.length;

    if (_results.isEmpty) {
      return ListView(
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          if (widget.preselectedVenueId != null)
            _ClearVenueRow(
              onTap: _clear,
              venueName: widget.preselectedVenueName,
              l10n: l10n,
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 32, 24, 24),
            child: Text(
              l10n.photoContributionVenuePickerEmpty(q),
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 13, color: AppColors.sokoShade3),
            ),
          ),
        ],
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.only(bottom: 8),
      itemCount: totalRows,
      itemBuilder: (ctx, i) {
        if (widget.preselectedVenueId != null && i == 0) {
          return _ClearVenueRow(
            onTap: _clear,
            venueName: widget.preselectedVenueName,
            l10n: l10n,
          );
        }
        final venue = _results[i - removeCount];
        final isSelected = venue.venueId == widget.preselectedVenueId;
        return _VenueRow(
          venue: venue,
          isSelected: isSelected,
          onTap: () => _pick(venue),
        );
      },
    );
  }
}

class _Header extends StatelessWidget {
  final String title;
  final VoidCallback onClose;
  const _Header({required this.title, required this.onClose});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 8, 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: const TextStyle(
              fontFamily: 'Zalando Sans',
              fontSize: 18,
              fontWeight: FontWeight.w500,
              height: 1.2,
              letterSpacing: -0.36,
              color: AppColors.sokoInk,
            ),
          ),
        ),
        IconButton(
          icon: const Icon(Icons.close_rounded, color: AppColors.sokoInk),
          onPressed: onClose,
          tooltip: MaterialLocalizations.of(context).closeButtonLabel,
        ),
      ],
    ),
  );
}

class _ClearVenueRow extends StatelessWidget {
  final VoidCallback onTap;
  final String? venueName;
  final Lt l10n;
  const _ClearVenueRow({
    required this.onTap,
    required this.venueName,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    final label = venueName != null
        ? l10n.photoContributionVenueClearNamed(venueName!)
        : l10n.photoContributionVenueClear;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: AppColors.sokoLight3,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 14),
          child: Row(
            children: [
              const Icon(
                Icons.close_rounded,
                size: 18,
                color: AppColors.sokoShade3,
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: const TextStyle(
                  fontFamily: 'Zalando Sans',
                  fontSize: 14,
                  fontWeight: FontWeight.w400,
                  letterSpacing: -0.14,
                  color: AppColors.sokoShade3,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _VenueRow extends StatelessWidget {
  final ItemSuggestion venue;
  final bool isSelected;
  final VoidCallback onTap;
  const _VenueRow({
    required this.venue,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final secondary = venue.address ?? venue.city;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        hoverColor: AppColors.sokoLight3,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
          child: Row(
            children: [
              const Icon(
                Icons.place_outlined,
                size: 18,
                color: AppColors.sokoShade3,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      venue.name,
                      style: TextStyle(
                        fontFamily: 'Zalando Sans',
                        fontSize: 16,
                        fontWeight: isSelected
                            ? FontWeight.w500
                            : FontWeight.w400,
                        letterSpacing: -0.16,
                        color: AppColors.sokoInk,
                      ),
                    ),
                    if (secondary != null && secondary.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        secondary,
                        style: const TextStyle(
                          fontFamily: 'Zalando Sans',
                          fontSize: 12,
                          fontWeight: FontWeight.w300,
                          letterSpacing: -0.12,
                          color: AppColors.sokoShade3,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              if (isSelected)
                const Icon(
                  Icons.check_rounded,
                  size: 20,
                  color: AppColors.sokoPink,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// PROD-2429 item 5: rendered when the search box contains a Google Maps
/// URL. One-tap call to `resolveVenueFromUrl`; on success the parent pops
/// the sheet with `VenuePicked`. Errors reuse the `searchUrlError*` copy
/// from the chat add-to-list flow for consistency.
class _ResolveLinkBody extends StatelessWidget {
  final String url;
  final bool loading;
  final ResolveUrlFailure? error;
  final VoidCallback onResolve;
  final Lt l10n;

  const _ResolveLinkBody({
    required this.url,
    required this.loading,
    required this.error,
    required this.onResolve,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.link_rounded, size: 28, color: AppColors.sokoShade3),
          const SizedBox(height: 8),
          Text(
            l10n.photoContributionVenuePickerLinkDetected,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontFamily: 'Zalando Sans',
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            url,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontFamily: 'Zalando Sans',
              fontSize: 12,
              fontWeight: FontWeight.w300,
              color: AppColors.sokoShade3,
            ),
          ),
          const SizedBox(height: 16),
          Material(
            color: AppColors.sokoPink,
            borderRadius: BorderRadius.circular(6),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              onTap: loading ? null : onResolve,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (loading) ...[
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 1.5,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            AppColors.sokoInk,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                    ],
                    Text(
                      l10n.photoContributionVenuePickerResolveLinkCta,
                      style: const TextStyle(
                        fontFamily: 'Zalando Sans',
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                        letterSpacing: -0.14,
                        color: AppColors.sokoInk,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (error != null) ...[
            const SizedBox(height: 12),
            Text(
              _errorCopy(l10n, error!),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Zalando Sans',
                fontSize: 13,
                color: Color(0xFFE45757),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _errorCopy(Lt l10n, ResolveUrlFailure failure) {
    switch (failure) {
      case ResolveUrlInvalid():
        return l10n.searchUrlErrorInvalid;
      case ResolveUrlNotFound():
        return l10n.searchUrlErrorNotFound;
      case ResolveUrlUnrecognized():
        return l10n.searchUrlErrorUnrecognized;
      case ResolveUrlRateLimited():
        return l10n.searchUrlErrorRateLimited;
      case ResolveUrlNetworkError():
        return l10n.searchUrlErrorNetwork;
      case ResolveUrlUnknown():
        return l10n.searchUrlErrorNetwork;
    }
  }
}
