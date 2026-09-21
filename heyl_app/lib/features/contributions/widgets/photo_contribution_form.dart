import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/theme/app_colors.dart';
import '../../../data/models/chat_message.dart' show ItemSuggestion;
import '../../../l10n/generated/l10n.dart';
import '../../../providers/city_auto_scope_provider.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../../shared/widgets/soko_text_field.dart';
import '../../lists/models/search_scope.dart';
import '../../lists/widgets/location_scope_picker_sheet.dart';
import 'photo_contribution_image_picker.dart';
import 'venue_picker_sheet.dart';

/// Form values captured from [PhotoContributionForm].
class PhotoContributionFormValues {
  final String city;

  /// ISO-3166-1 alpha-2 country code (uppercase) of the city. Paired with
  /// [city] so the backend can disambiguate ambiguous city names for the
  /// venue resolver.
  final String country;
  final String? note;

  /// Set when the user picked a venue from the picker (UUID from the local
  /// places DB). Backend text-resolves the venue from the LLM + [city] when
  /// this is null.
  final String? venueId;

  /// Optional `https://` URL the submitter attached (typically a ticket
  /// page or the event's official site). Backend screens via Google Web
  /// Risk (PROD-2430).
  final String? link;

  const PhotoContributionFormValues({
    required this.city,
    required this.country,
    this.note,
    this.venueId,
    this.link,
  });
}

/// Form widget for the contribution sheet — portrait photo preview,
/// location trigger (opens the shared map location picker via
/// `showLocationScopePicker`, same as Discovery), optional venue picker,
/// optional note, and a Cancel/Submit footer.
///
/// Submission is owned by the parent sheet (so the gate / API call lives
/// next to the polling/submit providers).
class PhotoContributionForm extends ConsumerStatefulWidget {
  final PickedContributionImage image;
  final ValueChanged<PhotoContributionFormValues> onSubmit;
  final VoidCallback onRetake;
  final VoidCallback onCancel;
  final bool isSubmitting;
  final String? topLevelError;

  const PhotoContributionForm({
    super.key,
    required this.image,
    required this.onSubmit,
    required this.onRetake,
    required this.onCancel,
    this.isSubmitting = false,
    this.topLevelError,
  });

  @override
  ConsumerState<PhotoContributionForm> createState() =>
      _PhotoContributionFormState();
}

class _PhotoContributionFormState extends ConsumerState<PhotoContributionForm> {
  static const int _noteMaxLength = 500;
  static const int _linkMaxLength = 2048;

  late final TextEditingController _noteController;
  late final TextEditingController _linkController;
  String? _linkError;

  /// Current location selection — must resolve to a city (via
  /// [cityScopeSelection]) before the form can be submitted: the old
  /// country/city sheet's [SearchScopeCountryCity], or the map picker's
  /// [SearchScopeArea] once it resolved a seeded `boundary.city` (PROD-3202).
  /// Seeded from [cityAutoScopeProvider] in [initState] so users in a
  /// resolved country/city land on a sensible default and only have to tap
  /// the trigger when correcting.
  SearchScope? _scope;

  ItemSuggestion? _pickedVenue;

  String? _scopeError;

  @override
  void initState() {
    super.initState();
    _noteController = TextEditingController();
    _noteController.addListener(_onNoteChanged);
    _linkController = TextEditingController();
    _linkController.addListener(_onLinkChanged);
    // Seed location from the user's auto-detected scope (profile city → IP
    // city → country-only). Same cascade Discovery uses, so users get
    // identical default placement.
    ref.read(cityAutoScopeProvider.future).then((scope) {
      if (!mounted) return;
      setState(() {
        _scope ??= scope;
      });
    });
  }

  @override
  void dispose() {
    _noteController.removeListener(_onNoteChanged);
    _noteController.dispose();
    _linkController.removeListener(_onLinkChanged);
    _linkController.dispose();
    super.dispose();
  }

  void _onNoteChanged() {
    setState(() {});
  }

  void _onLinkChanged() {
    if (_linkError != null) {
      setState(() => _linkError = null);
    }
  }

  /// Display string for the location trigger: `<flag> <Country> · <City>`
  /// when a city is picked, just `<flag> <Country>` for a country-only
  /// scope, null when no scope has been seeded yet.
  String? get _displayLocation {
    final scope = _scope;
    switch (scope) {
      case null:
        return null;
      case SearchScopeCountryCity(
        :final countryName,
        :final flagEmoji,
        :final city,
      ):
        final flag = flagEmoji.isEmpty ? '' : '$flagEmoji ';
        return '$flag$countryName · ${city.name}';
      case SearchScopeCountry(:final countryName, :final flagEmoji):
        final flag = flagEmoji.isEmpty ? '' : '$flagEmoji ';
        return '$flag$countryName';
      // The map picker's area scope (PROD-3202): show "<Country> · <City>"
      // once it resolved a seeded city. A point pick with no containing
      // boundary carries no city → show nothing rather than imply a scope.
      case SearchScopeArea():
        final sel = cityScopeSelection(scope);
        if (sel == null) return null;
        final countryName = kSokoCountryNamesByIso2[sel.iso2] ?? sel.iso2;
        return '$countryName · ${sel.city.name}';
    }
  }

  /// ISO-2 of the currently-selected scope, for scoping the venue picker.
  /// Area scopes resolve their ISO-2 from the seeded `boundary.city`
  /// (PROD-3202); a point pick with no city stays unscoped.
  String? get _scopeIso2 => switch (_scope) {
    null => null,
    SearchScopeCountry(:final iso2) => iso2,
    SearchScopeCountryCity(:final iso2) => iso2,
    SearchScopeArea() => cityScopeSelection(_scope)?.iso2,
  };

  Future<void> _openLocationPicker() async {
    setState(() => _scopeError = null);
    final picked = await showLocationScopePicker(
      context,
      ref,
      currentScope: _scope,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _scope = picked;
      _scopeError = null;
    });
  }

  Future<void> _openVenuePicker() async {
    final iso2 = _scopeIso2;
    if (iso2 == null) {
      setState(
        () =>
            _scopeError = Lt.of(context).photoContributionErrorLocationMissing,
      );
      return;
    }
    final result = await showVenuePickerSheet(
      context,
      ref,
      countryIso2: iso2,
      preselectedVenueId: _pickedVenue?.venueId,
      preselectedVenueName: _pickedVenue?.name,
    );
    if (result == null || !mounted) return;
    switch (result) {
      case VenuePicked(:final venue):
        setState(() => _pickedVenue = venue);
      case VenueCleared():
        setState(() => _pickedVenue = null);
    }
  }

  void _handleSubmit() {
    final l10n = Lt.of(context);
    // Accept a city from either producer (country/city sheet or a map-picked
    // area that resolved a seeded city). Defensive re-check of the picker's
    // `requireCity` gate — a point-pick area with no city fails here.
    final selection = cityScopeSelection(_scope);
    if (selection == null) {
      setState(() => _scopeError = l10n.photoContributionErrorLocationMissing);
      return;
    }
    final note = _noteController.text.trim();
    final link = _linkController.text.trim();
    String? linkValue;
    if (link.isNotEmpty) {
      final invalid = _validateLink(link, l10n);
      if (invalid != null) {
        setState(() => _linkError = invalid);
        return;
      }
      linkValue = link;
    }
    widget.onSubmit(
      PhotoContributionFormValues(
        city: selection.city.name,
        country: selection.iso2,
        note: note.isEmpty ? null : note,
        venueId: _pickedVenue?.venueId,
        link: linkValue,
      ),
    );
  }

  /// Client-side `link` validation. Mirrors the backend gates so the
  /// most common malformed inputs get caught before the POST and we
  /// only round-trip for `LINK_UNSAFE` / `LINK_VALIDATION_UNAVAILABLE`.
  String? _validateLink(String raw, Lt l10n) {
    if (raw.length > _linkMaxLength) {
      return l10n.photoContributionLinkErrorTooLong;
    }
    final uri = Uri.tryParse(raw);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      return l10n.photoContributionLinkErrorMalformed;
    }
    if (uri.scheme != 'https') {
      return l10n.photoContributionLinkErrorNotHttps;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final remaining = _noteMaxLength - _noteController.text.length;

    return SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(
        20,
        16,
        20,
        // Keep the form scroll above the soft keyboard so focusing the
        // note field doesn't hide it (PROD-2429 item 3). Same pattern as
        // `instagram_share_sheet.dart:201` / `import_list_sheet.dart:211`.
        20 + MediaQuery.viewInsetsOf(context).bottom,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.photoContributionSheetTitle,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w500,
              color: AppColors.sokoInk,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.photoContributionSheetSubtitle,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w300,
              color: AppColors.sokoInk.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 16),

          // Photo on the left + section header + city/venue pickers on
          // the right. IntrinsicHeight + crossAxisAlignment.stretch lets
          // the photo grow to the column's natural height (which now
          // includes the "Onde é?" header above the pickers).
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 140,
                  child: _PhotoPreview(
                    image: widget.image,
                    onRetake: widget.onRetake,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Section header for the where-block.
                      _SectionTitle(l10n.photoContributionSectionWhere),
                      const SizedBox(height: 10),
                      // Location — single trigger that opens the shared
                      // country+city scope picker (same sheet Discovery
                      // uses). `requireCity: true` gates Apply on a city
                      // pick — submit-time validation is a defensive
                      // re-check.
                      _FieldLabel(l10n.photoContributionLocationLabel),
                      const SizedBox(height: 6),
                      _PickerTriggerRow(
                        value: _displayLocation,
                        placeholder: l10n.photoContributionLocationPlaceholder,
                        onTap: _openLocationPicker,
                      ),
                      if (_scopeError != null) ...[
                        const SizedBox(height: 4),
                        Text(
                          _scopeError!,
                          style: const TextStyle(
                            fontSize: 12,
                            color: Color(0xFFE45757),
                          ),
                        ),
                      ],
                      const SizedBox(height: 12),

                      // Venue — optional, opens the local-only picker.
                      _FieldLabel(l10n.photoContributionVenueLabel),
                      const SizedBox(height: 6),
                      _PickerTriggerRow(
                        value: _pickedVenue?.name,
                        placeholder: l10n.photoContributionVenuePlaceholder,
                        onTap: _openVenuePicker,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Section header for the note/tip block.
          _SectionTitle(l10n.photoContributionSectionTip),
          const SizedBox(height: 10),

          // Note — optional, capped at 500 chars.
          _FieldLabel(l10n.photoContributionNoteLabel),
          const SizedBox(height: 6),
          SokoTextField(
            controller: _noteController,
            hintText: l10n.photoContributionNoteHint,
            maxLines: 3,
            minLines: 2,
            textCapitalization: TextCapitalization.sentences,
          ),
          const SizedBox(height: 4),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Text(
              l10n.photoContributionNoteCounter(remaining),
              style: TextStyle(
                fontSize: 12,
                color: remaining < 0
                    ? const Color(0xFFE45757)
                    : AppColors.sokoInk.withValues(alpha: 0.5),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Link — optional, capped at 2048 chars (PROD-2430). Backend
          // screens via Google Web Risk; client-side we only validate
          // `https://` shape so the most common typos are caught
          // before the POST.
          _FieldLabel(l10n.photoContributionLinkLabel),
          const SizedBox(height: 6),
          SokoTextField(
            controller: _linkController,
            hintText: l10n.photoContributionLinkHint,
            keyboardType: TextInputType.url,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            enableSuggestions: false,
          ),
          if (_linkError != null) ...[
            const SizedBox(height: 4),
            Text(
              _linkError!,
              style: const TextStyle(fontSize: 12, color: Color(0xFFE45757)),
            ),
          ],

          if (widget.topLevelError != null) ...[
            const SizedBox(height: 12),
            _ErrorBox(message: widget.topLevelError!),
          ],

          const SizedBox(height: 20),

          // Cancel + Submit pair using the design-system BtSqIco button
          // (same shape as IG-share's sticky footer at instagram_share_sheet.dart:339).
          Row(
            children: [
              Expanded(
                child: BtSqIco(
                  icon: LucideIcons.x,
                  label: l10n.photoContributionCancelButton,
                  variant: BtSqIcoVariant.normal,
                  expand: true,
                  onTap: widget.isSubmitting ? () {} : widget.onCancel,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: widget.isSubmitting
                    ? _SubmittingButton(
                        label: l10n.photoContributionSubmitButton,
                      )
                    : BtSqIco(
                        icon: LucideIcons.send,
                        label: l10n.photoContributionSubmitButton,
                        variant: BtSqIcoVariant.selected,
                        expand: true,
                        onTap: _handleSubmit,
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  const _FieldLabel(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: AppColors.sokoInk,
      ),
    );
  }
}

/// Section heading that groups related inputs (e.g. "Onde é?" over the
/// city + venue pickers). One step up from `_FieldLabel`: 16 px medium,
/// inherits the sokoInk colour.
class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.label);
  final String label;
  @override
  Widget build(BuildContext context) {
    return Text(
      label,
      style: const TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w500,
        color: AppColors.sokoInk,
      ),
    );
  }
}

/// Tappable row styled like [SokoTextField] (sokoShade5 fill, 6 px radius,
/// 48 px tall) showing a value + trailing chevron. Used for city + venue
/// triggers that open a picker sheet.
class _PickerTriggerRow extends StatelessWidget {
  const _PickerTriggerRow({
    required this.value,
    required this.placeholder,
    required this.onTap,
  });

  final String? value;
  final String placeholder;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final hasValue = value != null && value!.isNotEmpty;
    return Material(
      color: AppColors.sokoShade5,
      borderRadius: BorderRadius.circular(6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  hasValue ? value! : placeholder,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'Zalando Sans',
                    fontSize: 14,
                    fontWeight: FontWeight.w300,
                    letterSpacing: -0.14,
                    color: hasValue
                        ? AppColors.sokoInk
                        : AppColors.sokoInk.withValues(alpha: 0.30),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Icon(
                Icons.keyboard_arrow_down_rounded,
                size: 18,
                color: AppColors.sokoInk.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PhotoPreview extends StatelessWidget {
  const _PhotoPreview({required this.image, required this.onRetake});
  final PickedContributionImage image;
  final VoidCallback onRetake;

  /// Hero tag pairs the inline preview with the fullscreen viewer.
  /// One active preview at a time, so a static tag is sufficient.
  static const String _heroTag = 'photo-contribution-preview';

  void _openFullscreen(BuildContext context) {
    Navigator.of(context, rootNavigator: true).push(
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor: Colors.black,
        pageBuilder: (_, __, ___) =>
            _FullscreenPhotoViewer(bytes: image.bytes, heroTag: _heroTag),
        transitionDuration: const Duration(milliseconds: 250),
        reverseTransitionDuration: const Duration(milliseconds: 200),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        // ALL children are Positioned* so the Stack reports zero intrinsic.
        // This stops `Image.memory`'s natural pixel dimensions from leaking
        // up through Stack → SizedBox(width:140) → Row and dominating the
        // IntrinsicHeight calculation in the form (which would stretch the
        // right column to the image's source height — hundreds of px tall
        // for a typical screenshot).
        children: [
          // Image tap → fullscreen viewer (mirrors VenueHeroPhoto pattern).
          // Below the retake badge in the stack so the badge's InkWell
          // consumes its own taps first.
          Positioned.fill(
            child: GestureDetector(
              onTap: () => _openFullscreen(context),
              child: Hero(
                tag: _heroTag,
                child: Image.memory(
                  image.bytes,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                ),
              ),
            ),
          ),
          Positioned(
            right: 6,
            top: 6,
            child: Material(
              color: Colors.black.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(20),
              child: InkWell(
                borderRadius: BorderRadius.circular(20),
                onTap: onRetake,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.refresh, size: 12, color: Colors.white),
                      const SizedBox(width: 4),
                      Text(
                        l10n.photoContributionRetakePhoto,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Fullscreen pinch-zoom viewer for the picked contribution photo.
/// Mirrors `VenueHeroPhoto._FullscreenPhotoViewer` but reads
/// `Uint8List` bytes (the photo isn't uploaded yet) instead of a URL.
class _FullscreenPhotoViewer extends StatelessWidget {
  final Uint8List bytes;
  final String heroTag;

  const _FullscreenPhotoViewer({required this.bytes, required this.heroTag});

  @override
  Widget build(BuildContext context) {
    return Focus(
      autofocus: true,
      onKeyEvent: (node, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          Navigator.of(context).pop();
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(
          fit: StackFit.expand,
          children: [
            SafeArea(
              child: InteractiveViewer(
                minScale: 1,
                maxScale: 4,
                child: Hero(
                  tag: heroTag,
                  child: Image.memory(
                    bytes,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              ),
            ),
            Positioned(
              top: 0,
              right: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Material(
                    color: Colors.black.withValues(alpha: 0.4),
                    shape: const CircleBorder(),
                    child: IconButton(
                      icon: const Icon(Icons.close, color: Colors.white),
                      onPressed: () => Navigator.of(context).pop(),
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonLabel,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorBox extends StatelessWidget {
  const _ErrorBox({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFDECEC),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFFE45757), width: 1),
      ),
      child: Text(
        message,
        style: const TextStyle(fontSize: 13, color: Color(0xFFB12B2B)),
      ),
    );
  }
}

/// In-flight Submit variant — mirrors IG-share's `_SubmittingButton`
/// (`instagram_share_sheet.dart:374`). Visual parity with `BtSqIco` selected
/// (40 px tall, sokoPink bg, sokoInk fg) plus a 14 px spinner.
class _SubmittingButton extends StatelessWidget {
  const _SubmittingButton({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppColors.sokoPink,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.max,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const SizedBox(
            width: 14,
            height: 14,
            child: CircularProgressIndicator(
              strokeWidth: 1.5,
              valueColor: AlwaysStoppedAnimation<Color>(AppColors.sokoInk),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: const TextStyle(
              fontFamily: 'Zalando Sans',
              fontSize: 14,
              fontWeight: FontWeight.w300,
              height: 1.2,
              letterSpacing: -0.14,
              color: AppColors.sokoInk,
            ),
          ),
        ],
      ),
    );
  }
}
