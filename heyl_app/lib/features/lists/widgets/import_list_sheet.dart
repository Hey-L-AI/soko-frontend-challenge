import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/import_list_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../../shared/widgets/soko_text_field.dart';

/// Regex patterns for Google Maps URLs
final _googleMapsUrlPattern = RegExp(
  r'(https?://)?(maps\.app\.goo\.gl/\S+|'
  r'maps\.google\.\w+/\S*|'
  r'(www\.)?google\.\w+/maps/\S+|'
  r'goo\.gl/maps/\S+)',
  caseSensitive: false,
);

/// Shows the Google Maps list import sheet (hides the bottom nav while open).
///
/// [source] identifies which surface opened the sheet for analytics — one
/// of `discovery_help_us` (today's only entry, the "Help us" Maps pill on
/// Discovery), plus any future entry (e.g. a Create-menu tile). Mirrors
/// [showInstagramShareSheet] (PROD-1863) so callsites read identically
/// across the import-style flows.
///
/// Refuses to open while a previous import is still active — shows an
/// info Soko pointing back at the in-flight progress notification
/// instead. Mirrors [showInstagramShareSheet]'s `isProcessing` gate.
/// Without this, double-tapping the pill during a 1–5 min import would
/// open a fresh sheet over the active progress, and a second submit
/// would supersede the first job (the provider's `startImport` resets
/// state) — surprising UX.
Future<void> showImportListSheet(
  BuildContext context, {
  required WidgetRef ref,
  required String source,
}) async {
  final importState = ref.read(importListProvider);
  if (importState.isActive) {
    showSoko(
      ref,
      message: Lt.of(context).importWaitForPrevious,
      variant: SokoVariant.info,
    );
    return;
  }
  ref.read(unifiedAnalyticsProvider).trackListImportOpen(source: source);
  await showBottomSheetWithHiddenNav(
    context: context,
    ref: ref,
    builder: (context) => const ImportListSheet(),
  );
}

/// Bottom sheet for importing a Google Maps list.
///
/// PROD-1931: rebuilt on the `DSSheetShell` foundation (PROD-1860) with
/// `SokoTextField` for input and a `BtSqIco`-based Cancel/Submit footer —
/// same template as `InstagramShareSheet` (PROD-1863). Entry point moved
/// from the (now-deleted) Lists Hub create-menu to the Discovery
/// "Help us" Maps pill (`discovery_help_us_actions.dart`), see also
/// `docs/features/google-maps-import-ui.md`.
class ImportListSheet extends ConsumerStatefulWidget {
  /// Pre-filled URL (e.g. from a retry).
  final String? initialUrl;

  const ImportListSheet({super.key, this.initialUrl});

  @override
  ConsumerState<ImportListSheet> createState() => _ImportListSheetState();
}

class _ImportListSheetState extends ConsumerState<ImportListSheet> {
  final _urlController = TextEditingController();
  final _nameController = TextEditingController();
  bool _clipboardPasted = false;
  bool _helpExpanded = false;

  /// When true, the "How to get the link" help button is emphasised (rose
  /// border) to point the user at the instructions after the backend rejects
  /// a link as not-a-Google-Maps-list (PROD-2426). The section is NOT
  /// auto-expanded. Cleared when the user edits the field or taps the section.
  bool _highlightHelp = false;

  /// Bumped on each invalid submit so the help button re-runs its breathing
  /// pulse even when [_highlightHelp] is already true (repeated bad submits).
  int _helpPulseNonce = 0;

  /// Inline validation error for the URL field — same pattern as
  /// `InstagramShareSheet._validationError`. Cleared on text change.
  String? _urlError;

  /// Banner-style submit error (rate-limited / unknown / network). Distinct
  /// from `_urlError` because it surfaces below the form, not below the
  /// URL field, and persists until the user edits + resubmits.
  String? _submitError;

  @override
  void initState() {
    super.initState();
    _urlController.addListener(_onUrlChanged);
    if (widget.initialUrl != null) {
      _urlController.text = widget.initialUrl!;
    } else {
      // Delay clipboard check to avoid triggering the iOS system "Paste"
      // permission prompt during the bottom sheet opening animation, which
      // can overlay and block user interaction with the sheet.
      Future.delayed(const Duration(milliseconds: 800), () {
        if (mounted) _checkClipboard();
      });
    }
  }

  @override
  void dispose() {
    _urlController.removeListener(_onUrlChanged);
    _urlController.dispose();
    _nameController.dispose();
    super.dispose();
  }

  void _onUrlChanged() {
    // Mirror IG-share: clear inline error on edit, and rebuild so the
    // suffix icon (paste vs clear) tracks keystrokes. Also drop the help
    // highlight once the user starts correcting the link (PROD-2426).
    setState(() {
      _urlError = null;
      _highlightHelp = false;
    });
  }

  Future<void> _checkClipboard() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim() ?? '';
      if (text.isNotEmpty && _googleMapsUrlPattern.hasMatch(text)) {
        _urlController.text = text;
        setState(() => _clipboardPasted = true);
      }
    } catch (_) {
      // Clipboard access denied or unavailable - ignore.
    }
  }

  Future<void> _pasteFromClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    final text = data?.text?.trim();
    if (text == null || text.isEmpty) return;
    _urlController.text = text;
    _urlController.selection = TextSelection.collapsed(offset: text.length);
    setState(() => _clipboardPasted = true);
  }

  Future<void> _handleSubmit() async {
    final l10n = Lt.of(context);
    final url = _urlController.text.trim();
    final name = _nameController.text.trim();

    if (url.isEmpty) {
      setState(() => _urlError = l10n.importUrlRequired);
      return;
    }

    // No client-side format pre-validation (PROD-2426): the backend
    // normalizes the scheme and is the single source of truth for what counts
    // as a Google Maps list link. Send the link exactly as typed and react to
    // the response — an invalid link comes back as a structured 400.
    setState(() {
      _urlError = null;
      _submitError = null;
    });

    final notifier = ref.read(importListProvider.notifier);

    try {
      await notifier.startImport(url, listName: name.isEmpty ? null : name);

      // Check if it failed immediately. The provider sets `state.isFailed`
      // synchronously in startImport's catch path, so this read is up-to-date
      // by the time `await` returns.
      final state = ref.read(importListProvider);
      if (state.isFailed) {
        _showSubmitFailure(state.error, state.errorMessage, l10n);
        return;
      }

      // Success — dismiss the sheet. Soko-notification progress is
      // wired by `NotificationHost` (PROD-1931, see notification_host.dart).
      if (mounted) Navigator.of(context).pop();
    } catch (_) {
      if (mounted) setState(() => _submitError = l10n.importErrorGeneric);
    }
  }

  /// Route a failed submit to the right surface (PROD-2426). The invalid-link
  /// case shows an inline error under the URL field and highlights the help
  /// button (no auto-expand); everything else uses the bottom banner. The
  /// `_submitError`/`_urlError` fields now hold the resolved display string.
  void _showSubmitFailure(String? code, String? backendMessage, Lt l10n) {
    if (!mounted) return;
    setState(() {
      switch (code) {
        case 'invalid_url':
          _urlError = l10n.importErrorInvalidLink;
          _highlightHelp = true;
          _helpPulseNonce++;
        case 'rate_limited':
          _submitError = l10n.importErrorRateLimited;
        case 'backend':
          _submitError = backendMessage ?? l10n.importErrorGeneric;
        default:
          _submitError = l10n.importErrorGeneric;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final importState = ref.watch(importListProvider);
    final isSubmitting = importState.isSubmitting;
    final hasUrl = _urlController.text.trim().isNotEmpty;
    final canSubmit = hasUrl && !isSubmitting;

    // Keyboard-aware padding so the sheet rides above the soft keyboard
    // (`showModalBottomSheet` with `isScrollControlled: true` doesn't
    // auto-apply `viewInsets`; same pattern as `instagram_share_sheet.dart`).
    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: DSSheetShell(
        header: _Header(title: l10n.importFromGoogleMaps),
        body: Padding(
          padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Subtitle — explanatory copy under the title.
              Text(
                l10n.importSheetDescription,
                style: TextStyle(
                  fontFamily: 'Zalando Sans',
                  fontSize: 14,
                  fontWeight: FontWeight.w300,
                  height: 1.3,
                  letterSpacing: -0.14,
                  color: AppColors.sokoInk.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 16),

              // URL field — DS SokoTextField with link prefix + paste/clear suffix.
              SokoTextField(
                controller: _urlController,
                hintText: l10n.importUrlPlaceholder,
                autofocus: false,
                textInputAction: TextInputAction.next,
                prefix: const Icon(
                  Icons.link,
                  size: 18,
                  color: AppColors.sokoShade3,
                ),
                suffix: _urlController.text.isEmpty
                    ? IconButton(
                        icon: const Icon(Icons.content_paste, size: 18),
                        color: AppColors.sokoShade3,
                        splashRadius: 18,
                        onPressed: _pasteFromClipboard,
                      )
                    : IconButton(
                        icon: const Icon(Icons.clear, size: 18),
                        color: AppColors.sokoShade3,
                        splashRadius: 18,
                        onPressed: () {
                          _urlController.clear();
                          setState(() {
                            _urlError = null;
                            _clipboardPasted = false;
                          });
                        },
                      ),
              ),
              if (_urlError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: Text(
                    _urlError!,
                    style: const TextStyle(
                      fontFamily: 'Zalando Sans',
                      fontSize: 13,
                      fontWeight: FontWeight.w400,
                      height: 1.3,
                      letterSpacing: -0.13,
                      color: AppColors.error,
                    ),
                  ),
                )
              else if (_clipboardPasted)
                Padding(
                  padding: const EdgeInsets.only(top: 6, left: 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.content_paste,
                        size: 13,
                        color: AppColors.sokoInk.withValues(alpha: 0.5),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        l10n.importClipboardPasted,
                        style: TextStyle(
                          fontFamily: 'Zalando Sans',
                          fontSize: 12,
                          fontWeight: FontWeight.w300,
                          color: AppColors.sokoInk.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 16),

              // Name field — SokoTextField, optional, hint-only.
              SokoTextField(
                controller: _nameController,
                hintText: l10n.importNamePlaceholder,
                textCapitalization: TextCapitalization.sentences,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) {
                  if (canSubmit) _handleSubmit();
                },
              ),
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Text(
                  l10n.importNameHint,
                  style: TextStyle(
                    fontFamily: 'Zalando Sans',
                    fontSize: 12,
                    fontWeight: FontWeight.w300,
                    color: AppColors.sokoInk.withValues(alpha: 0.5),
                  ),
                ),
              ),

              // Submit error banner (rate-limited / network / unknown).
              if (_submitError != null) ...[
                const SizedBox(height: 16),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: AppColors.error.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: AppColors.error.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.warning_amber_rounded,
                        size: 18,
                        color: AppColors.error,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          _submitError!,
                          style: const TextStyle(
                            fontFamily: 'Zalando Sans',
                            fontSize: 13,
                            fontWeight: FontWeight.w400,
                            height: 1.3,
                            color: AppColors.error,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 16),

              // Help section — expandable instructions. Highlighted (breathing
              // pulse) when the user submits a link the backend rejects
              // (PROD-2426); tapping to expand clears the highlight and stops
              // the animation.
              _HelpSection(
                expanded: _helpExpanded,
                highlighted: _highlightHelp,
                pulseNonce: _helpPulseNonce,
                onToggle: () => setState(() {
                  _helpExpanded = !_helpExpanded;
                  _highlightHelp = false;
                }),
              ),
            ],
          ),
        ),
        footer: _Footer(
          cancelLabel: MaterialLocalizations.of(context).cancelButtonLabel,
          submitLabel: isSubmitting
              ? l10n.importButtonSubmitting
              : l10n.importButtonSubmit,
          canSubmit: canSubmit,
          isSubmitting: isSubmitting,
          onCancel: () => Navigator.of(context).pop(),
          onSubmit: _handleSubmit,
        ),
      ),
    );
  }
}

/// Left-aligned title in Zalando Sans Medium 18 / sokoInk — same shape as
/// `instagram_share_sheet.dart`'s `_Header`.
class _Header extends StatelessWidget {
  final String title;
  const _Header({required this.title});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
    child: Align(
      alignment: Alignment.centerLeft,
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
  );
}

/// Sticky Cancel + Submit footer using the DS `BtSqIco` button — verbatim
/// shape from `instagram_share_sheet.dart` `_Footer` (PROD-1863).
class _Footer extends StatelessWidget {
  final String cancelLabel;
  final String submitLabel;
  final bool canSubmit;
  final bool isSubmitting;
  final VoidCallback onCancel;
  final VoidCallback onSubmit;

  const _Footer({
    required this.cancelLabel,
    required this.submitLabel,
    required this.canSubmit,
    required this.isSubmitting,
    required this.onCancel,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      color: AppColors.sokoPaper,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
      child: Row(
        children: [
          Expanded(
            child: BtSqIco(
              icon: LucideIcons.x,
              label: cancelLabel,
              variant: BtSqIcoVariant.normal,
              expand: true,
              onTap: isSubmitting ? () {} : onCancel,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Opacity(
              opacity: canSubmit ? 1.0 : 0.5,
              child: isSubmitting
                  ? _SubmittingButton(label: submitLabel)
                  : BtSqIco(
                      icon: LucideIcons.download,
                      label: submitLabel,
                      variant: BtSqIcoVariant.selected,
                      expand: true,
                      onTap: canSubmit ? onSubmit : () {},
                    ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Loading variant of the submit button — mirrors `_SubmittingButton` in
/// `instagram_share_sheet.dart`. Kept private until a third caller appears.
class _SubmittingButton extends StatelessWidget {
  final String label;

  const _SubmittingButton({required this.label});

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

/// Expandable help section with instructions for getting a shared
/// Google Maps list link.
///
/// When [highlighted] (PROD-2426) it runs a brief "breathing" rose-tint pulse
/// to draw the eye, then rests with a thin rose border — WITHOUT auto-expanding.
/// [pulseNonce] re-triggers the pulse on a repeated invalid submit; clearing
/// [highlighted] (the user edits the field or taps to expand) stops it.
class _HelpSection extends StatefulWidget {
  final bool expanded;
  final bool highlighted;
  final int pulseNonce;
  final VoidCallback onToggle;

  const _HelpSection({
    required this.expanded,
    required this.highlighted,
    required this.pulseNonce,
    required this.onToggle,
  });

  @override
  State<_HelpSection> createState() => _HelpSectionState();
}

class _HelpSectionState extends State<_HelpSection>
    with SingleTickerProviderStateMixin {
  // One forward+reverse = one slow "breathe" (~1.2s with easing); repeat a few
  // times then rest. A status-listener loop drives this (no awaited ticker
  // futures, so it stays dispose-safe).
  late final AnimationController _pulse;
  late final Animation<double> _pulseCurve;
  int _breathsDone = 0;
  static const _maxBreaths = 3;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..addStatusListener(_onPulseStatus);
    _pulseCurve = CurvedAnimation(parent: _pulse, curve: Curves.easeInOut);
    if (widget.highlighted) _startBreathing();
  }

  void _onPulseStatus(AnimationStatus status) {
    // Stopped highlighting mid-pulse — don't queue another breath.
    if (!widget.highlighted) return;
    if (status == AnimationStatus.completed) {
      _pulse.reverse();
    } else if (status == AnimationStatus.dismissed) {
      _breathsDone++;
      if (_breathsDone < _maxBreaths) _pulse.forward();
    }
  }

  void _startBreathing() {
    _breathsDone = 0;
    _pulse.forward(from: 0.0);
  }

  @override
  void didUpdateWidget(_HelpSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.highlighted &&
        (!oldWidget.highlighted || widget.pulseNonce != oldWidget.pulseNonce)) {
      _startBreathing();
    } else if (!widget.highlighted && oldWidget.highlighted) {
      // User edited the field or tapped to expand — stop and clear the tint.
      _pulse.stop();
      _pulse.value = 0.0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;
    final borderColor = isDark ? AppColors.borderDarkMode : AppColors.border;

    final expanded = widget.expanded;
    final highlighted = widget.highlighted;

    return AnimatedBuilder(
      animation: _pulseCurve,
      builder: (context, child) {
        return Container(
          decoration: BoxDecoration(
            // Rose tint breathes in→out during the pulse; transparent at rest.
            color: primaryColor.withValues(alpha: 0.10 * _pulseCurve.value),
            border: Border.all(
              color: highlighted
                  ? primaryColor
                  : borderColor.withValues(alpha: 0.5),
              width: highlighted ? 1.25 : 1.0,
            ),
            borderRadius: BorderRadius.circular(8),
          ),
          child: child,
        );
      },
      child: Column(
        children: [
          InkWell(
            onTap: widget.onToggle,
            borderRadius: expanded
                ? const BorderRadius.vertical(top: Radius.circular(8))
                : BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
              child: Row(
                children: [
                  Icon(Icons.help_outline, size: 18, color: primaryColor),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l10n.importHelpTitle,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        color: highlighted ? primaryColor : textPrimary,
                      ),
                    ),
                  ),
                  Icon(
                    expanded
                        ? Icons.keyboard_arrow_up
                        : Icons.keyboard_arrow_down,
                    size: 20,
                    color: textSecondary,
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            Divider(height: 1, color: borderColor.withValues(alpha: 0.5)),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _HelpStep(number: '1', text: l10n.importHelpStep1),
                  _HelpStep(number: '2', text: l10n.importHelpStep2),
                  _HelpStep(number: '3', text: l10n.importHelpStep3),
                  _HelpStep(number: '4', text: l10n.importHelpStep4),
                  _HelpStep(number: '5', text: l10n.importHelpStep5),
                  _HelpStep(number: '6', text: l10n.importHelpStep6),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _HelpStep extends StatelessWidget {
  final String number;
  final String text;

  const _HelpStep({required this.number, required this.text});

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 20,
            child: Text(
              '$number.',
              style: TextStyle(fontSize: 13, color: textSecondary),
            ),
          ),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 13, color: textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
