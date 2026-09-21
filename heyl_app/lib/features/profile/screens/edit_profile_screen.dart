import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart'
    show unifiedAnalyticsProvider;
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/page_layout.dart';
import '../../../data/models/profile_update.dart';
import '../../../data/models/social/public_profile.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart';
import '../../../data/models/user_profile.dart' show UserRole;
import '../../../providers/auth_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/widgets/soko_back_button.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../providers/public_profile_providers.dart';
import '../utils/bio_text.dart';
import '../utils/edit_profile_dirty.dart';
import '../utils/profile_style.dart';
import '../widgets/textured_avatar.dart';
import '../widgets/unsaved_changes_sheet.dart';
import 'crop_avatar_screen.dart';

/// Edit the current user's social profile — display name, bio, privacy and
/// the section-visibility toggles (PROD-2814, phase 3). Admin-gated pilot.
///
/// Prefilled from the user's own by-handle profile (which carries bio /
/// is_private / show_* — the app's cached user model predates them).
class EditProfileScreen extends ConsumerStatefulWidget {
  const EditProfileScreen({super.key});

  @override
  ConsumerState<EditProfileScreen> createState() => _EditProfileScreenState();
}

/// Blocking load-error state. Kept as a kind (not a pre-built string) so the
/// message can be localized at build time, where a BuildContext is available.
enum _EditLoadError { none, noHandle, loadFailed }

class _EditProfileScreenState extends ConsumerState<EditProfileScreen> {
  final _nameCtrl = TextEditingController();
  final _handleCtrl = TextEditingController();
  final _bioCtrl = TextEditingController();
  final _cityCtrl = TextEditingController();
  final _instagramCtrl = TextEditingController();
  final _tiktokCtrl = TextEditingController();
  final _websiteCtrl = TextEditingController();

  /// The bio is multiline, so its Return key inserts a newline instead of
  /// dismissing the keyboard. We track its focus to show a "Done" bar above
  /// the keyboard (single-line fields don't need it — Return dismisses them).
  final _bioFocus = FocusNode();
  bool _isPrivate = false;
  bool _showBioMemories = true;
  bool _showSaved = true;

  String? _handle;
  String? _avatarUrl;
  Uint8List? _pickedBytes;
  // Loaded originals, kept so _save can report WHICH fields changed
  // (profile_updated.fields_changed, PROD-3211).
  String _origName = '';
  String _origBio = '';
  String _origCity = '';
  // The social links had no captured original — the analytics `fields_changed`
  // payload doesn't cover them either. Without these, editing only a link and
  // tapping back would discard it silently (PROD-3806).
  String _origInstagram = '';
  String _origTiktok = '';
  String _origWebsite = '';
  bool _origIsPrivate = false;
  bool _origShowBioMemories = true;
  bool _origShowSaved = true;
  bool _uploadingAvatar = false;
  bool _loading = true;
  bool _saving = false;
  _EditLoadError _errorKind = _EditLoadError.none;

  /// Inline error under the username field — set live by the debounced
  /// availability check (taken handle / bad format), so the user learns
  /// BEFORE saving, not from a failed save toast.
  String? _handleError;
  Timer? _handleCheckDebounce;

  @override
  void initState() {
    super.initState();
    // Rebuild when the bio gains/loses focus so the "Done" bar shows/hides.
    _bioFocus.addListener(_onBioFocusChanged);
    _handleCtrl.addListener(_onHandleChanged);
    _load();
  }

  void _onBioFocusChanged() {
    if (mounted) setState(() {});
  }

  /// Debounced live availability check for the username field. Runs only on
  /// an actual CHANGE from the current handle (typing your own handle back
  /// clears any error); malformed input shows the format error inline.
  void _onHandleChanged() {
    _handleCheckDebounce?.cancel();
    final candidate = _handleCtrl.text.trim();
    if (candidate == (_handle ?? '')) {
      if (_handleError != null) setState(() => _handleError = null);
      return;
    }
    _handleCheckDebounce = Timer(const Duration(milliseconds: 450), () async {
      if (!mounted) return;
      final l10n = Lt.of(context);
      if (!_handlePattern.hasMatch(candidate)) {
        setState(() => _handleError = l10n.profileEditInvalidUsername);
        return;
      }
      try {
        final res = await ref
            .read(authMethodsApiProvider)
            .checkHandleAvailability(candidate);
        // Stale response guard — the field may have changed while in flight.
        if (!mounted || _handleCtrl.text.trim() != candidate) return;
        setState(
          () => _handleError = res.available
              ? null
              : l10n.profileEditUsernameUnavailable,
        );
      } catch (_) {
        // Availability is best-effort; a failed check stays silent and the
        // save-path validation still catches a taken handle.
      }
    });
  }

  @override
  void dispose() {
    _handleCheckDebounce?.cancel();
    _handleCtrl.removeListener(_onHandleChanged);
    _nameCtrl.dispose();
    _handleCtrl.dispose();
    _bioCtrl.dispose();
    _cityCtrl.dispose();
    _instagramCtrl.dispose();
    _tiktokCtrl.dispose();
    _websiteCtrl.dispose();
    _bioFocus.removeListener(_onBioFocusChanged);
    _bioFocus.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final handle = ref.read(currentUserProvider)?.handle;
    if (handle == null || handle.isEmpty) {
      setState(() {
        _loading = false;
        _errorKind = _EditLoadError.noHandle;
      });
      return;
    }
    _handle = handle;
    try {
      final PublicProfile p = await ref
          .read(socialProfileApiProvider)
          .getProfile(handle);
      _nameCtrl.text = p.fullName ?? '';
      _handleCtrl.text = p.handle ?? handle;
      _bioCtrl.text = p.bio ?? '';
      _cityCtrl.text = p.city ?? '';
      _instagramCtrl.text = p.instagramHandle ?? '';
      _tiktokCtrl.text = p.tiktokHandle ?? '';
      _websiteCtrl.text = p.websiteUrl ?? '';
      _avatarUrl = p.avatarUrl;
      _isPrivate = p.isPrivate;
      _showBioMemories = p.showBioMemories;
      _showSaved = p.showSaved;
      _origName = _nameCtrl.text;
      _origBio = _bioCtrl.text;
      _origCity = _cityCtrl.text;
      _origInstagram = _instagramCtrl.text;
      _origTiktok = _tiktokCtrl.text;
      _origWebsite = _websiteCtrl.text;
      _origIsPrivate = _isPrivate;
      _origShowBioMemories = _showBioMemories;
      _origShowSaved = _showSaved;
    } catch (_) {
      _errorKind = _EditLoadError.loadFailed;
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Backend handle format: 3–20 chars, must start with a letter, then
  /// letters / numbers / underscores. Mirrors the OpenAPI `handle` pattern so
  /// we reject an empty or malformed username locally before hitting the API.
  static final _handlePattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{2,19}$');

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    // Capture context-bound objects before any await — a handle change refreshes
    // the auth state, which rebuilds the router and leaves `context` stale, so a
    // post-await `Navigator.of(context)` pop would silently no-op (PROD-2986).
    final router = GoRouter.of(context);
    final l10n = Lt.of(context);
    final newHandle = _handleCtrl.text.trim();

    // The edit screen is only reachable with an existing handle (see `_load`),
    // so an empty or malformed field means the user cleared/broke a valid one.
    // A handle can't be deleted (the backend has no empty/null handle), so treat
    // it as invalid instead of silently reporting success (PROD-2986).
    if (!_handlePattern.hasMatch(newHandle)) {
      setState(() {
        _handleError = l10n.profileEditInvalidUsername;
        _saving = false;
      });
      return;
    }

    // The live availability check already flagged this handle as taken —
    // surface it inline instead of "saving" into a guaranteed 400.
    if (newHandle != _handle && _handleError != null) {
      setState(() => _saving = false);
      return;
    }

    final handleChanged = newHandle != _handle;
    try {
      final request = ProfileUpdateRequest(
        fullName: _nameCtrl.text.trim(),
        // Only send the handle when it actually changed — the backend treats
        // any non-null handle as a change request (uniqueness + format checks).
        handle: handleChanged ? newHandle : null,
        bio: collapseBioWhitespace(_bioCtrl.text),
        city: _cityCtrl.text.trim(),
        instagramHandle: _normalizeSocialHandle(_instagramCtrl.text),
        tiktokHandle: _normalizeSocialHandle(_tiktokCtrl.text),
        websiteUrl: _normalizeWebsite(_websiteCtrl.text),
        isPrivate: _isPrivate,
        showBioMemories: _showBioMemories,
        showSaved: _showSaved,
      );
      await ref.read(authMethodsApiProvider).updateProfile(request);
      // PROD-3211: report WHICH fields changed (diff vs loaded originals);
      // privacy flips additionally get their own event per the tracking spec.
      final fieldsChanged = <String>[
        if (_nameCtrl.text.trim() != _origName.trim()) 'full_name',
        if (handleChanged) 'handle',
        if (collapseBioWhitespace(_bioCtrl.text) !=
            collapseBioWhitespace(_origBio))
          'bio',
        if (_cityCtrl.text.trim() != _origCity.trim()) 'city',
        if (_isPrivate != _origIsPrivate) 'is_private',
        if (_showBioMemories != _origShowBioMemories) 'show_bio_memories',
        if (_showSaved != _origShowSaved) 'show_saved',
      ];
      if (fieldsChanged.isNotEmpty) {
        ref
            .read(unifiedAnalyticsProvider)
            .trackProfileUpdated(fieldsChanged: fieldsChanged);
      }
      if (_isPrivate != _origIsPrivate) {
        ref
            .read(unifiedAnalyticsProvider)
            .trackProfilePrivacyChange(toPrivate: _isPrivate);
      }
      _origName = _nameCtrl.text;
      _origBio = _bioCtrl.text;
      _origCity = _cityCtrl.text;
      _origIsPrivate = _isPrivate;
      _origShowBioMemories = _showBioMemories;
      _origShowSaved = _showSaved;
      // A handle change moves the profile to a new @handle, so refresh the
      // cached user (the self-profile route resolves its handle from it) and
      // invalidate both the old and new by-handle caches.
      if (handleChanged) {
        await ref.read(authStateProvider.notifier).refreshUserProfile();
        // The new @handle isn't always instantly resolvable by the by-handle
        // lookup (backend read-after-write lag), which flashes a "couldn't find
        // user" on the profile we're about to open. Warm it with a bounded
        // retry so we land on an already-loaded page (PROD-2986).
        await _warmProfile(newHandle);
      }
      if (_handle != null) {
        ref.invalidate(publicProfileProvider(_handle!));
      }
      if (handleChanged) _handle = newHandle;
      showSoko(
        ref,
        message: l10n.profileEditSavedToast,
        variant: SokoVariant.success,
      );
      // Return to the profile page. `go` is declarative — unlike `pop` it
      // doesn't need a poppable stack entry, which a handle change destroys:
      // `refreshUserProfile` mutates the auth state, so GoRouter re-resolves the
      // current `/profile/edit` location on the next frame and would clobber an
      // immediate navigation. Defer to a post-frame callback so our `go` runs
      // AFTER that re-resolution settles, using the captured router (not the
      // now-stale `context`). The self profile reads the refreshed handle, so it
      // shows the new @handle (PROD-2986).
      WidgetsBinding.instance.addPostFrameCallback((_) {
        router.go(AppRoutes.profile);
      });
    } catch (e) {
      if (mounted) {
        showSoko(
          ref,
          message: _saveErrorMessage(l10n, e, handleChanged),
          variant: SokoVariant.error,
        );
        setState(() => _saving = false);
      }
    }
  }

  /// Pre-fetch a freshly-changed handle's profile, retrying briefly while the
  /// backend catches up (read-after-write lag on the by-handle lookup). Leaves
  /// the result cached so the profile screen we navigate to reads it without a
  /// "couldn't find user" flash. Gives up quietly after a few tries — the
  /// profile screen keeps its own retry affordance as a fallback (PROD-2986).
  Future<void> _warmProfile(String handle) async {
    for (var attempt = 0; attempt < 4; attempt++) {
      ref.invalidate(publicProfileProvider(handle));
      try {
        await ref.read(publicProfileProvider(handle).future);
        return;
      } catch (_) {
        if (attempt < 3) {
          await Future<void>.delayed(const Duration(milliseconds: 400));
        }
      }
    }
  }

  /// People paste social handles as '@name' or as a full profile URL; store
  /// just the bare handle. Empty result clears the field on the backend.
  static String _normalizeSocialHandle(String raw) {
    var v = raw.trim();
    v = v.replaceFirst(
      RegExp(
        r'^https?://(www\.)?(instagram\.com|tiktok\.com)/',
        caseSensitive: false,
      ),
      '',
    );
    if (v.startsWith('@')) v = v.substring(1);
    // Drop anything past the handle segment of a pasted URL (query, subpaths).
    return v.replaceFirst(RegExp(r'[/?#].*$'), '');
  }

  /// Keep the website as typed (scheme optional) — just trimmed, so the
  /// profile row can render it bare and the launcher adds https:// if needed.
  static String _normalizeWebsite(String raw) => raw.trim();

  /// Surface the backend's handle validation errors (taken / bad format)
  /// instead of a generic failure, so the user knows what to fix.
  String _saveErrorMessage(Lt l10n, Object e, bool handleChanged) {
    if (e is DioException) {
      final data = e.response?.data;
      if (data is Map && data['detail'] is String) {
        return data['detail'] as String;
      }
      if (handleChanged) {
        return l10n.profileEditUsernameUnavailable;
      }
    }
    return l10n.profileEditSaveError;
  }

  Future<void> _pickAndUploadAvatar() async {
    if (_uploadingAvatar) return;
    final picker = ImagePicker();
    final XFile? file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (file == null) return;
    final raw = await file.readAsBytes();
    if (!mounted) return;
    // Square-crop step before upload (works on web + native). The bytes go in
    // and the result comes back through an AvatarCropRequest completer — NOT
    // GoRouter `extra` or `context.push`'s return value, both of which the web
    // router rebuild (refresh-listenable) drops mid-crop, so the upload never
    // fired. See AvatarCropRequest.
    final req = AvatarCropRequest(raw);
    ref.read(avatarCropRequestProvider.notifier).state = req;
    context.push(AppRoutes.editProfileCrop);
    final Uint8List? bytes = await req.result;
    ref.read(avatarCropRequestProvider.notifier).state = null;
    if (!mounted) return;
    if (bytes == null) return; // cancelled crop
    setState(() {
      _pickedBytes = bytes;
      _uploadingAvatar = true;
    });
    try {
      final res = await ref
          .read(socialProfileApiProvider)
          .uploadAvatar(bytes, 'avatar.png');
      _avatarUrl = res.avatarUrl;
      // PROD-3211: confirmed upload only — failures land in the catch.
      ref.read(unifiedAnalyticsProvider).trackProfilePhotoAdded();
      if (_handle != null) {
        ref.invalidate(publicProfileProvider(_handle!));
      }
      if (mounted) {
        showSoko(
          ref,
          message: Lt.of(context).profileEditPhotoUpdated,
          variant: SokoVariant.success,
        );
      }
    } catch (_) {
      _pickedBytes = null;
      if (mounted) {
        showSoko(
          ref,
          message: Lt.of(context).profileEditPhotoUploadError,
          variant: SokoVariant.error,
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  Future<void> _removeAvatar() async {
    if (_uploadingAvatar) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final l10n = Lt.of(ctx);
        return AlertDialog(
          backgroundColor: AppColors.sokoPaper,
          title: Text(l10n.profileEditRemovePhotoTitle),
          content: Text(l10n.profileEditRemovePhotoBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l10n.profileEditRemovePhotoCancel),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: Text(l10n.profileEditRemovePhotoConfirm),
            ),
          ],
        );
      },
    );
    if (confirmed != true) return;
    setState(() => _uploadingAvatar = true);
    try {
      final res = await ref.read(socialProfileApiProvider).deleteAvatar();
      _avatarUrl = res.avatarUrl;
      _pickedBytes = null;
      if (_handle != null) ref.invalidate(publicProfileProvider(_handle!));
      if (mounted) {
        showSoko(
          ref,
          message: Lt.of(context).profileEditPhotoRemoved,
          variant: SokoVariant.success,
        );
      }
    } catch (_) {
      if (mounted) {
        showSoko(
          ref,
          message: Lt.of(context).profileEditPhotoRemoveError,
          variant: SokoVariant.error,
        );
      }
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  /// Whether the form differs from what was loaded. False while the initial
  /// load runs or errored — the originals and the fields are both empty then,
  /// so a back tap must not prompt about nothing.
  /// Latched once the user has chosen to leave without saving. `canPop` is
  /// read at build time, so discarding has to flip this via `setState` and pop
  /// on the NEXT frame — popping immediately is intercepted by our own guard
  /// (the form is still dirty; discarding doesn't reset the fields) and
  /// re-opens the sheet forever. Same shape as the map's `_allowRoutePop`
  /// latch, and the same bug it exists to prevent.
  bool _leaving = false;

  /// Guards against a second sheet while one is open — a double tap on the
  /// arrow, or the browser's back arriving while the sheet is up.
  bool _promptOpen = false;

  bool get _hasUnsavedChanges {
    if (_leaving) return false;
    if (_loading || _errorKind != _EditLoadError.none) return false;
    return hasUnsavedProfileChanges(
      original: EditProfileSnapshot(
        name: _origName,
        handle: _handle ?? '',
        bio: _origBio,
        city: _origCity,
        instagram: _origInstagram,
        tiktok: _origTiktok,
        website: _origWebsite,
        isPrivate: _origIsPrivate,
        showBioMemories: _origShowBioMemories,
        showSaved: _origShowSaved,
      ),
      current: EditProfileSnapshot(
        name: _nameCtrl.text,
        handle: _handleCtrl.text,
        bio: _bioCtrl.text,
        city: _cityCtrl.text,
        instagram: _instagramCtrl.text,
        tiktok: _tiktokCtrl.text,
        website: _websiteCtrl.text,
        isPrivate: _isPrivate,
        showBioMemories: _showBioMemories,
        showSaved: _showSaved,
      ),
      pickedAvatar: _pickedBytes != null,
    );
  }

  /// The one exit path for the back arrow, the iOS swipe gesture and the
  /// browser's back button. Guarding only the arrow would leave the two most
  /// accidental exits unguarded (PROD-3806).
  ///
  /// A clean form leaves immediately. A dirty one asks; `save` delegates to
  /// [_save], which already navigates on success and stays put with its error
  /// visible on failure — so a failed save can never leave someone believing
  /// their edits were kept.
  Future<void> _handleBack() async {
    if (_saving || _promptOpen) return;
    if (!_hasUnsavedChanges) {
      Navigator.of(context).maybePop();
      return;
    }
    _promptOpen = true;
    final UnsavedChangesChoice? choice;
    try {
      choice = await showUnsavedChangesSheet(context, ref: ref);
    } finally {
      _promptOpen = false;
    }
    if (!mounted) return;
    switch (choice) {
      case UnsavedChangesChoice.save:
        await _save();
      case UnsavedChangesChoice.discard:
        _leaveWithoutSaving();
      case null:
        break; // dismissed — no intent expressed, so stay
    }
  }

  /// Pop past our own guard: open the latch, let the frame that reads
  /// `canPop` rebuild, and only then pop.
  void _leaveWithoutSaving() {
    setState(() => _leaving = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).maybePop();
    });
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      // Intercept the pop while dirty; `_handleBack` decides and navigates
      // itself. A clean form pops normally, so the guard is invisible when
      // there is nothing to lose.
      canPop: !_hasUnsavedChanges,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _handleBack();
      },
      child: ColoredBox(
        color: AppColors.sokoPaper,
        child: PageContent(
          child: Stack(
            children: [
              SafeArea(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Row(
                        children: [
                          SokoBackButton(onTap: _handleBack),
                          const SizedBox(width: 8),
                          Text(
                            Lt.of(context).profileEditButton,
                            style: Pt.b1Bold,
                          ),
                        ],
                      ),
                    ),
                    Expanded(child: _body()),
                  ],
                ),
              ),
              // "Done" bar pinned just above the keyboard while the multiline
              // bio is focused — its Return key inserts newlines, so this is the
              // way to dismiss the keyboard and reach the Save button.
              if (_bioFocus.hasFocus &&
                  MediaQuery.of(context).viewInsets.bottom > 0)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: MediaQuery.of(context).viewInsets.bottom,
                  child: _KeyboardDoneBar(onDone: _bioFocus.unfocus),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    }
    final l10n = Lt.of(context);
    final isAdmin = ref.watch(currentUserProvider)?.role == UserRole.admin;
    if (_errorKind != _EditLoadError.none) {
      final msg = _errorKind == _EditLoadError.noHandle
          ? l10n.profileNoHandle
          : l10n.profileEditLoadError;
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            msg,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppColors.sokoInkSecondary),
          ),
        ),
      );
    }
    return SingleChildScrollView(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _avatarSection(),
          const SizedBox(height: 12),
          _FieldLabel(l10n.profileEditDisplayName),
          TextField(
            controller: _nameCtrl,
            style: Pt.b2,
            maxLength: 255,
            decoration: _inputDecoration(l10n.profileEditDisplayNameHint),
          ),
          const SizedBox(height: 12),
          _FieldLabel(l10n.profileEditUsername),
          TextField(
            controller: _handleCtrl,
            style: Pt.b2,
            maxLength: 20,
            autocorrect: false,
            enableSuggestions: false,
            // Handles are letters / numbers / underscores only (backend format).
            inputFormatters: [
              FilteringTextInputFormatter.allow(RegExp(r'[a-zA-Z0-9_]')),
            ],
            decoration: _inputDecoration(l10n.profileEditUsernameHint).copyWith(
              prefixText: '@',
              prefixStyle: const TextStyle(
                color: AppColors.sokoInk,
                fontWeight: FontWeight.w600,
              ),
              counterText: '',
              helperText: l10n.profileEditUsernameHelper,
              helperStyle: const TextStyle(
                fontSize: 11,
                color: AppColors.sokoInkSecondary,
              ),
              // Live availability verdict — red line under the field the
              // moment the debounce resolves, before any save attempt.
              errorText: _handleError,
              errorStyle: const TextStyle(
                fontSize: 11,
                color: AppColors.sokoRed,
              ),
            ),
          ),
          const SizedBox(height: 12),
          _FieldLabel(l10n.profileEditBio),
          TextField(
            controller: _bioCtrl,
            focusNode: _bioFocus,
            style: Pt.b2,
            maxLength: 160,
            maxLines: kBioMaxParagraphs,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            inputFormatters: const [BioParagraphLimiter()],
            decoration: _inputDecoration(l10n.profileEditBioHint),
          ),
          const SizedBox(height: 12),
          _FieldLabel(l10n.profileEditCity),
          TextField(
            controller: _cityCtrl,
            style: Pt.b2,
            maxLength: 80,
            decoration: _inputDecoration(l10n.profileEditCityHint),
          ),
          const SizedBox(height: 12),
          _FieldLabel(l10n.profileEditInstagram),
          TextField(
            controller: _instagramCtrl,
            style: Pt.b2,
            maxLength: 80,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            decoration: _inputDecoration(l10n.profileEditInstagramHint)
                .copyWith(
                  prefixIcon: _fieldIcon(
                    _iconWithAt(
                      Icon(LucideIcons.instagram, size: 16, color: pInk50),
                    ),
                  ),
                  prefixIconConstraints: _fieldIconConstraints,
                  counterText: '',
                ),
          ),
          const SizedBox(height: 12),
          _FieldLabel(l10n.profileEditTiktok),
          TextField(
            controller: _tiktokCtrl,
            style: Pt.b2,
            maxLength: 80,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            decoration: _inputDecoration(l10n.profileEditTiktokHint).copyWith(
              prefixIcon: _fieldIcon(
                _iconWithAt(
                  SvgPicture.asset(
                    'assets/images/tiktok.svg',
                    width: 15,
                    height: 15,
                    colorFilter: ColorFilter.mode(pInk50, BlendMode.srcIn),
                  ),
                ),
              ),
              prefixIconConstraints: _fieldIconConstraints,
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          _FieldLabel(l10n.profileEditWebsite),
          TextField(
            controller: _websiteCtrl,
            style: Pt.b2,
            maxLength: 200,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.url,
            decoration: _inputDecoration(l10n.profileEditWebsiteHint).copyWith(
              prefixIcon: _fieldIcon(
                Icon(LucideIcons.globe, size: 16, color: pInk50),
              ),
              prefixIconConstraints: _fieldIconConstraints,
              counterText: '',
            ),
          ),
          const SizedBox(height: 8),
          _Toggle(
            title: l10n.profileEditPrivateAccountTitle,
            subtitle: l10n.profileEditPrivateAccountSubtitle,
            value: _isPrivate,
            onChanged: (v) => setState(() => _isPrivate = v),
          ),
          const Divider(color: AppColors.sokoInk8),
          Padding(
            padding: const EdgeInsets.only(bottom: 6, top: 4),
            child: Text(l10n.profileEditSectionsTitle, style: Pt.b2Bold),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              l10n.profileEditSectionsSubtitle,
              style: Pt.b2.copyWith(color: pInk50),
            ),
          ),
          // Bio memories are a memory surface — admin-only, even though the
          // rest of Edit profile is open to everyone.
          if (isAdmin)
            _Toggle(
              title: l10n.profileEditSectionBioMemories,
              value: _showBioMemories,
              onChanged: (v) => setState(() => _showBioMemories = v),
            ),
          // Activity is now self-only (never shared with other users), so the
          // enable/disable toggle was removed — there's nothing to hide from
          // others. The activity feed always shows on your own profile with an
          // "only visible to you" notice.
          _Toggle(
            title: l10n.profileEditSectionSaved,
            value: _showSaved,
            onChanged: (v) => setState(() => _showSaved = v),
          ),
          const SizedBox(height: 20),
          SokoCtaButton(
            label: l10n.profileEditSave,
            loading: _saving,
            onPressed: _save,
          ),
        ],
      ),
    );
  }

  Widget _avatarSection() {
    // Square, with the paper texture. The just-picked photo overlays the same
    // texture; otherwise the shared TexturedAvatar renders the current photo or
    // an initial. The editor has to show the same crop the rest of the app
    // will, so both branches use the avatar's own corner ratio.
    const w = 104.0, h = 104.0;
    final previewRadius = w * TexturedAvatar.kRadiusRatio;
    Widget image;
    if (_pickedBytes != null) {
      image = ClipRRect(
        borderRadius: BorderRadius.circular(previewRadius),
        child: SizedBox(
          width: w,
          height: h,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.memory(_pickedBytes!, fit: BoxFit.cover),
              const IgnorePointer(
                child: Opacity(
                  opacity: 0.5,
                  child: Image(
                    image: AssetImage(
                      'assets/images/textures/avatar-texture.png',
                    ),
                    fit: BoxFit.cover,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    } else {
      image = TexturedAvatar(
        url: _avatarUrl,
        name: _nameCtrl.text,
        // Same seed as the profile header, so the no-photo tint matches.
        colorSeed: ref.read(currentUserProvider)?.id,
        width: w,
        height: h,
      );
    }
    return Center(
      child: Column(
        children: [
          Stack(
            alignment: Alignment.center,
            children: [
              // Session-replay: mask the user's own photo (just-picked bytes or
              // uploaded avatar) in native recordings. This is the surface where
              // the photo is viewed/changed; the Change/Remove buttons below stay
              // visible. See posthog_service.dart and auth_shell.dart.
              PostHogMaskWidget(child: image),
              if (_uploadingAvatar)
                const SizedBox(
                  width: 24,
                  height: 24,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: _uploadingAvatar ? null : _pickAndUploadAvatar,
                child: Text(
                  _hasAvatar
                      ? Lt.of(context).profileEditChangePhoto
                      : Lt.of(context).profileEditAddPhoto,
                ),
              ),
              // Remove is only offered when there's a photo to remove.
              if (_hasAvatar)
                TextButton(
                  onPressed: _uploadingAvatar ? null : _removeAvatar,
                  child: Text(
                    Lt.of(context).profileEditRemovePhoto,
                    style: const TextStyle(color: AppColors.sokoRed),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  bool get _hasAvatar =>
      _pickedBytes != null || (_avatarUrl != null && _avatarUrl!.isNotEmpty);

  /// Compact leading icon for the social-link fields (Icon/IG, Icon/Tiktok,
  /// Icon/Globe). Default prefixIcon constraints reserve 48px; these keep the
  /// field as tight as the plain text inputs.
  static const _fieldIconConstraints = BoxConstraints(
    minWidth: 0,
    minHeight: 0,
  );

  Widget _fieldIcon(Widget icon) =>
      Padding(padding: const EdgeInsets.only(left: 14, right: 8), child: icon);

  /// Icon + a permanently visible '@' for the handle fields. As `prefixText`
  /// only renders while the field is focused (Flutter behavior), the '@'
  /// lives in the always-visible prefixIcon slot instead.
  Widget _iconWithAt(Widget icon) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      icon,
      const SizedBox(width: 8),
      const Text(
        '@',
        style: TextStyle(color: AppColors.sokoInk, fontWeight: FontWeight.w600),
      ),
    ],
  );

  InputDecoration _inputDecoration(String hint) {
    return InputDecoration(
      hintText: hint,
      hintStyle: Pt.b2.copyWith(color: pInk30),
      filled: true,
      fillColor: Colors.white,
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.sokoInk8),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.sokoInk8),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: AppColors.sokoPink, width: 1.5),
      ),
    );
  }
}

/// Thin toolbar that sits directly above the keyboard, giving multiline fields
/// (the bio) a way to dismiss the keyboard — matching the iOS input-accessory
/// convention without swapping the keyboard type.
class _KeyboardDoneBar extends StatelessWidget {
  final VoidCallback onDone;
  const _KeyboardDoneBar({required this.onDone});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: const Color(0xFFF2EDED),
      child: Container(
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: AppColors.sokoInk8)),
        ),
        child: Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: onDone,
            child: Text(
              Lt.of(context).profileEditDoneBar,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _FieldLabel extends StatelessWidget {
  final String text;
  const _FieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, top: 4),
      child: Text(text, style: Pt.b2.copyWith(color: pInk50)),
    );
  }
}

class _Toggle extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const _Toggle({
    required this.title,
    this.subtitle,
    required this.value,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    return SwitchListTile.adaptive(
      contentPadding: EdgeInsets.zero,
      activeThumbColor: AppColors.sokoPink,
      title: Text(title, style: Pt.b2Bold),
      subtitle: subtitle == null
          ? null
          : Text(subtitle!, style: Pt.b2.copyWith(color: pInk50)),
      value: value,
      onChanged: onChanged,
    );
  }
}
