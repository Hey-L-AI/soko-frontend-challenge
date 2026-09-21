import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/page_layout.dart';
import '../../../data/models/profile_update.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart'
    show authMethodsApiProvider, socialProfileApiProvider;
import '../../../providers/auth_provider.dart'
    show authStateProvider, currentUserProvider;
import '../../../shared/widgets/clickable.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../../shared/widgets/soko_text_field.dart';
import '../../profile/providers/public_profile_providers.dart';
import '../../profile/screens/crop_avatar_screen.dart';
import '../../profile/widgets/textured_avatar.dart';

/// Opens the onboarding edit-profile page on the root navigator (over the
/// onboarding gate). Returns `true` if the user saved changes.
///
/// A dedicated page rather than the production [EditProfileScreen], which
/// assumes an existing handle and hard-navigates to `/profile` on save. Reuses
/// the same building blocks: [TexturedAvatar], the pick→crop→upload flow
/// ([CropAvatarScreen] + `uploadAvatar`), live handle-availability, and
/// `updateProfile` + `refreshUserProfile`.
Future<bool?> openOnboardingEditProfile(BuildContext context) {
  return Navigator.of(context, rootNavigator: true).push<bool>(
    MaterialPageRoute(builder: (_) => const OnboardingEditProfilePage()),
  );
}

class OnboardingEditProfilePage extends ConsumerStatefulWidget {
  const OnboardingEditProfilePage({super.key});

  @override
  ConsumerState<OnboardingEditProfilePage> createState() =>
      _OnboardingEditProfilePageState();
}

class _OnboardingEditProfilePageState
    extends ConsumerState<OnboardingEditProfilePage> {
  static final _handlePattern = RegExp(r'^[a-zA-Z][a-zA-Z0-9_]{2,19}$');

  final _nameCtrl = TextEditingController();
  final _handleCtrl = TextEditingController();
  final _bioCtrl = TextEditingController();

  String? _originalHandle;
  String? _avatarUrl;
  bool _uploadingAvatar = false;
  bool _saving = false;
  bool _prefilled = false;

  Timer? _handleDebounce;
  bool _checkingHandle = false;
  String? _handleError;

  @override
  void initState() {
    super.initState();
    final user = ref.read(currentUserProvider);
    _nameCtrl.text = user?.fullName ?? '';
    _handleCtrl.text = user?.handle ?? '';
    _originalHandle = user?.handle;
    _handleCtrl.addListener(_onHandleChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _prefillFromProfile());
  }

  /// Best-effort prefill of avatar + bio from the by-handle public profile
  /// (a freshly-onboarded user usually has neither yet — tolerate absence).
  Future<void> _prefillFromProfile() async {
    if (_prefilled) return;
    _prefilled = true;
    final handle = _originalHandle;
    if (handle == null || handle.isEmpty) return;
    try {
      final profile = await ref.read(publicProfileProvider(handle).future);
      if (!mounted) return;
      setState(() {
        _avatarUrl = profile.avatarUrl;
        if (_bioCtrl.text.isEmpty) _bioCtrl.text = profile.bio ?? '';
      });
    } catch (_) {
      /* no profile yet — leave blank */
    }
  }

  @override
  void dispose() {
    _handleDebounce?.cancel();
    _nameCtrl.dispose();
    _handleCtrl.dispose();
    _bioCtrl.dispose();
    super.dispose();
  }

  void _onHandleChanged() {
    final candidate = _handleCtrl.text.trim();
    _handleDebounce?.cancel();
    if (candidate == (_originalHandle ?? '')) {
      setState(() {
        _handleError = null;
        _checkingHandle = false;
      });
      return;
    }
    if (!_handlePattern.hasMatch(candidate)) {
      setState(() {
        _handleError = Lt.of(context).onboardingChatProfileEditHandleInvalid;
        _checkingHandle = false;
      });
      return;
    }
    setState(() {
      _handleError = null;
      _checkingHandle = true;
    });
    _handleDebounce = Timer(const Duration(milliseconds: 450), () async {
      try {
        final res = await ref
            .read(authMethodsApiProvider)
            .checkHandleAvailability(candidate);
        if (!mounted || _handleCtrl.text.trim() != candidate) return;
        setState(() {
          _checkingHandle = false;
          _handleError = res.available
              ? null
              : Lt.of(context).onboardingChatProfileEditHandleTaken;
        });
      } catch (_) {
        if (!mounted) return;
        setState(() => _checkingHandle = false);
      }
    });
  }

  Future<void> _pickAndUploadAvatar() async {
    if (_uploadingAvatar) return;
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1024,
      maxHeight: 1024,
      imageQuality: 85,
    );
    if (file == null) return;
    final raw = await file.readAsBytes();
    if (!mounted) return;
    // Square-crop before upload — the result comes back via the
    // AvatarCropRequest completer (web-router-rebuild safe). CropAvatarScreen
    // pops itself with Navigator.maybePop, so a root-navigator push is fine.
    final req = AvatarCropRequest(raw);
    ref.read(avatarCropRequestProvider.notifier).state = req;
    await Navigator.of(
      context,
      rootNavigator: true,
    ).push(MaterialPageRoute(builder: (_) => const CropAvatarScreen()));
    final Uint8List? bytes = await req.result;
    ref.read(avatarCropRequestProvider.notifier).state = null;
    if (!mounted || bytes == null) return;
    setState(() => _uploadingAvatar = true);
    try {
      final res = await ref
          .read(socialProfileApiProvider)
          .uploadAvatar(bytes, 'avatar.png');
      if (!mounted) return;
      ref
          .read(unifiedAnalyticsProvider)
          .trackOnboardingStep(step: 'profile.card', action: 'avatar_uploaded');
      setState(() => _avatarUrl = res.avatarUrl);
    } catch (_) {
      /* swallow — the user can retry */
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  bool get _canSave => !_saving && !_checkingHandle && _handleError == null;

  Future<void> _save() async {
    if (!_canSave) return;
    setState(() => _saving = true);
    final name = _nameCtrl.text.trim();
    final handle = _handleCtrl.text.trim();
    final bio = _bioCtrl.text.trim();
    try {
      await ref
          .read(authMethodsApiProvider)
          .updateProfile(
            ProfileUpdateRequest(
              fullName: name.isEmpty ? null : name,
              handle: (handle.isNotEmpty && handle != _originalHandle)
                  ? handle
                  : null,
              bio: bio,
            ),
          );
      await ref.read(authStateProvider.notifier).refreshUserProfile();
      if (handle.isNotEmpty) {
        ref.invalidate(publicProfileProvider(handle));
      }
      if (_originalHandle != null && _originalHandle!.isNotEmpty) {
        ref.invalidate(publicProfileProvider(_originalHandle!));
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (_) {
      if (!mounted) return;
      setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final name = _nameCtrl.text.trim();
    return Scaffold(
      backgroundColor: AppColors.sokoPaper,
      appBar: AppBar(
        backgroundColor: AppColors.sokoPaper,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        leading: const BackButton(color: AppColors.sokoInk),
        title: Text(
          l10n.onboardingChatProfileEditTitle,
          style: AppTheme.body(
            fontSize: 18,
            fontWeight: FontWeight.w600,
            color: AppColors.sokoInk,
          ),
        ),
        centerTitle: true,
      ),
      body: SafeArea(
        top: false,
        child: PageContent(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Center(
                  child: Clickable(
                    onTap: _pickAndUploadAvatar,
                    child: Stack(
                      alignment: Alignment.bottomRight,
                      children: [
                        TexturedAvatar(
                          url: _avatarUrl,
                          name: name.isEmpty ? '?' : name,
                          colorSeed: ref.read(currentUserProvider)?.userId,
                          width: 96,
                          height: 96,
                        ),
                        Container(
                          width: 30,
                          height: 30,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: AppColors.sokoPink,
                          ),
                          alignment: Alignment.center,
                          child: _uploadingAvatar
                              ? const SizedBox(
                                  width: 14,
                                  height: 14,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppColors.sokoInk,
                                  ),
                                )
                              : const Icon(
                                  Icons.camera_alt_outlined,
                                  size: 16,
                                  color: AppColors.sokoInk,
                                ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Center(
                  child: Clickable(
                    onTap: _pickAndUploadAvatar,
                    child: Text(
                      l10n.onboardingChatProfileEditPhoto,
                      style: AppTheme.body(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: AppColors.sokoInk,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                _Label(l10n.onboardingChatProfileEditName),
                SokoTextField(
                  controller: _nameCtrl,
                  hintText: l10n.onboardingChatProfileEditName,
                  textCapitalization: TextCapitalization.words,
                  maxLength: 40,
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 16),
                _Label(l10n.onboardingChatProfileEditHandle),
                SokoTextField(
                  controller: _handleCtrl,
                  hintText: l10n.onboardingChatProfileEditHandle,
                  maxLength: 20,
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(RegExp('[a-zA-Z0-9_]')),
                  ],
                  prefix: const Padding(
                    padding: EdgeInsets.only(left: 12, right: 4),
                    child: Text(
                      '@',
                      style: TextStyle(
                        fontSize: 14,
                        color: AppColors.sokoShade3,
                      ),
                    ),
                  ),
                  suffix: _checkingHandle
                      ? const Padding(
                          padding: EdgeInsets.only(right: 12),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: AppColors.sokoPink,
                            ),
                          ),
                        )
                      : null,
                ),
                if (_handleError != null) ...[
                  const SizedBox(height: 4),
                  Text(
                    _handleError!,
                    style: AppTheme.body(
                      fontSize: 12,
                      color: AppColors.sokoRed,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                _Label(l10n.onboardingChatProfileEditBio),
                SokoTextField(
                  controller: _bioCtrl,
                  hintText: l10n.onboardingChatProfileEditBio,
                  maxLines: 4,
                  minLines: 3,
                  maxLength: 160,
                  textAlignVertical: TextAlignVertical.top,
                ),
                const SizedBox(height: 28),
                SokoCtaButton(
                  label: l10n.onboardingChatProfileEditSave,
                  loading: _saving,
                  onPressed: _canSave ? _save : null,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Label extends StatelessWidget {
  const _Label(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8, left: 2),
    child: Text(
      text,
      style: AppTheme.body(
        fontSize: 13,
        fontWeight: FontWeight.w500,
        color: AppColors.sokoShade3,
      ),
    ),
  );
}
