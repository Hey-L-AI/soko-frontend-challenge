import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/services/unified_analytics_service.dart'
    show unifiedAnalyticsProvider;
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/memory_twin_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../chat/widgets/typing_placeholder_controller.dart';
import '../../../shared/widgets/soko_cta_button.dart';

/// "Conta-nos sobre ti" — a small self-description entry at the top of the
/// Memory page. The user writes free text about themselves; on submit the
/// backend turns it into user_stated memory facts immediately and the twin
/// silently refreshes so the new interests appear inline below.
///
/// Collapsed by default (a single inviting prompt row); expands into a text
/// field + submit when tapped, so it never dominates the page.
class MemoryTellUsCard extends ConsumerStatefulWidget {
  /// When true the card starts expanded (composer open). Used when the user
  /// arrives from the profile "conta-nos sobre ti" shortcut, which should land
  /// with the text field already open.
  final bool startExpanded;

  /// Profile styling (PROD-4164 redesign): the resting state is a content-width
  /// pill with a brain mark — "Adiciona algo às tuas memórias" — instead of the
  /// legacy two-line lilac card. The composer itself is identical.
  final bool compact;
  const MemoryTellUsCard({
    super.key,
    this.startExpanded = false,
    this.compact = false,
  });

  @override
  ConsumerState<MemoryTellUsCard> createState() => _MemoryTellUsCardState();
}

class _MemoryTellUsCardState extends ConsumerState<MemoryTellUsCard> {
  final _controller = TextEditingController();
  bool _expanded = false;
  bool _submitting = false;

  static const int _maxChars = 2000;

  /// Cycles short example phrases through the empty field, typewriter-style —
  /// the same controller the chat bar uses, so the two surfaces animate
  /// identically. Only the compact (profile) card runs it.
  late final TypingPlaceholderController _typing;
  List<String> _lastPhrases = const [];

  @override
  void initState() {
    super.initState();
    _expanded = widget.startExpanded;
    _typing = TypingPlaceholderController(const []);
    // Typing your own answer should stop the demo mid-word, not race it.
    _controller.addListener(_onTextChanged);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!widget.compact) return;
    final phrases = _examplePhrases();
    if (!listEquals(phrases, _lastPhrases)) {
      _lastPhrases = phrases;
      _typing.restart(phrases);
      if (_controller.text.trim().isNotEmpty) _typing.pause();
    }
  }

  void _onTextChanged() {
    if (!widget.compact) return;
    final hasText = _controller.text.trim().isNotEmpty;
    if (hasText && !_typing.isPaused) {
      _typing.pause();
    } else if (!hasText && _typing.isPaused) {
      _typing.resume();
    }
    setState(() {});
  }

  List<String> _examplePhrases() {
    final l10n = Lt.of(context);
    return [
      l10n.memoryTellUsExample1,
      l10n.memoryTellUsExample2,
      l10n.memoryTellUsExample3,
      l10n.memoryTellUsExample4,
      l10n.memoryTellUsExample5,
      l10n.memoryTellUsExample6,
      l10n.memoryTellUsExample7,
      l10n.memoryTellUsExample8,
    ];
  }

  @override
  void dispose() {
    _controller.removeListener(_onTextChanged);
    _controller.dispose();
    _typing.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _submitting) return;
    setState(() => _submitting = true);

    final l10n = Lt.of(context);
    String message;
    // Variant carries the outcome visually: a win reads green, a cap or a
    // failure reads as an error, and "nothing landed" is merely informational.
    SokoVariant variant;
    try {
      final result = await ref.read(memoryTwinProvider.notifier).tellUs(text);
      if (result.applied) {
        // PROD-3211: user-stated memory is an L3 contribution act.
        ref
            .read(unifiedAnalyticsProvider)
            .trackMemoryFreetextSubmit(
              length: text.length,
              factsWritten: result.factsWritten,
            );
        message = l10n.memoryTellUsSuccess(result.factsWritten);
        variant = SokoVariant.success;
        _controller.clear();
        if (mounted) setState(() => _expanded = false);
      } else if (result.status == 'too_short') {
        ref
            .read(unifiedAnalyticsProvider)
            .trackMemoryFreetextRejected(
              status: 'too_short',
              length: text.length,
            );
        message = l10n.memoryTellUsTooShort;
        variant = SokoVariant.info;
      } else if (result.status == 'duplicate') {
        // An identical earlier submission was already applied — the memory is
        // up to date (the provider silent-refreshed it). Reads as a win, not
        // as "nothing found".
        ref
            .read(unifiedAnalyticsProvider)
            .trackMemoryFreetextRejected(
              status: 'duplicate',
              length: text.length,
            );
        message = l10n.memoryTellUsDuplicate;
        variant = SokoVariant.success;
        _controller.clear();
        if (mounted) setState(() => _expanded = false);
      } else {
        // disabled / empty_input / no_facts / no_client / error all
        // read the same to the user: nothing durable was added this time.
        // PROD-3211: previously an uncountable failure state.
        ref
            .read(unifiedAnalyticsProvider)
            .trackMemoryFreetextRejected(
              status: result.status,
              length: text.length,
            );
        message = l10n.memoryTellUsNothing;
        variant = SokoVariant.info;
      }
    } on DioException catch (e) {
      // 429 = per-user daily/weekly cap hit.
      message = e.response?.statusCode == 429
          ? l10n.memoryTellUsRateLimited
          : l10n.memoryTellUsError;
      variant = SokoVariant.error;
    } catch (_) {
      message = l10n.memoryTellUsError;
      variant = SokoVariant.error;
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
    if (!mounted) return;
    showSoko(ref, message: message, variant: variant);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);

    // The redesigned (profile) card keeps the pill on screen and grows the
    // composer underneath it; the legacy card swaps one for the other.
    if (widget.compact) return _buildCompact(l10n);

    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 8),
      // Resting state is a bare inline link (no box); the quiet box only
      // appears once the composer is open.
      padding: _expanded ? const EdgeInsets.all(14) : EdgeInsets.zero,
      decoration: _expanded
          ? BoxDecoration(
              color: AppColors.sokoLilac.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: AppColors.sokoLilac.withValues(alpha: 0.22),
              ),
            )
          : null,
      child: AnimatedSize(
        duration: const Duration(milliseconds: 180),
        curve: Curves.easeOut,
        alignment: Alignment.topCenter,
        child: _expanded ? _buildExpanded(l10n) : _buildCollapsed(l10n),
      ),
    );
  }

  /// PROD-4164 — the profile's composer.
  ///
  /// The pill never leaves: tapping it unfolds the writing surface directly
  /// below, in the same ink tint, so the two read as one growing block rather
  /// than a swap.
  Widget _buildCompact(Lt l10n) {
    return Container(
      margin: const EdgeInsets.only(top: 6, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _compactPill(l10n),
          AnimatedSize(
            duration: const Duration(milliseconds: 260),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: _expanded
                ? Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: AnimatedOpacity(
                      opacity: _expanded ? 1 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          // Same ink tint as the pill, one step lighter so the
                          // pill still reads as the control and this as its
                          // surface.
                          color: AppColors.sokoInk.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: AppColors.sokoInk.withValues(alpha: 0.10),
                          ),
                        ),
                        child: _buildExpanded(l10n, compact: true),
                      ),
                    ),
                  )
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  /// The always-visible pill.
  ///
  /// Figma `7532:24627` is a `Bt_Sq_Ico` instance (249x40, `Icon/Brain` 14x14
  /// at x=14, label from x=36), so this is the design-system component rather
  /// than a bespoke container — that is where the 40 height, 6 radius, ink@6%
  /// fill, 14 px icon and 8 px gap all come from, and the pressed-state fill
  /// comes free with it.
  Widget _compactPill(Lt l10n) {
    return Align(
      alignment: Alignment.centerLeft,
      child: BtSqIco(
        icon: null,
        iconAsset: 'assets/images/icons/memory/brain.svg',
        label: l10n.memoryAddToMemories,
        variant: BtSqIcoVariant.normal,
        onTap: () => setState(() => _expanded = !_expanded),
      ),
    );
  }

  Widget _buildCollapsed(Lt l10n) {
    // A "quiet button": a barely-there neutral fill + hairline border + a
    // chevron. Monochrome and subtle (no colours, no icon), but the surface,
    // border and chevron make it read clearly as tappable — unlike a bare link.
    return InkWell(
      onTap: () => setState(() => _expanded = true),
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: AppColors.sokoLilac.withValues(alpha: 0.22),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: AppColors.sokoLilac.withValues(alpha: 0.40),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.memoryTellUsTitle,
                    style: const TextStyle(
                      color: AppColors.sokoInk,
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      letterSpacing: -0.2,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l10n.memoryTellUsPrompt,
                    style: const TextStyle(
                      color: AppColors.sokoShade3,
                      fontSize: 13,
                      fontWeight: FontWeight.w300,
                      height: 1.3,
                      letterSpacing: -0.2,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(
              LucideIcons.chevron_right,
              size: 16,
              color: AppColors.sokoShade3,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildExpanded(Lt l10n, {bool compact = false}) {
    // The caret and focus ring take this card's CTA colour — ink on the
    // profile, lilac on the legacy page — instead of the theme's pink accent,
    // which was the only pink on an otherwise neutral surface.
    final accent = compact ? AppColors.sokoInk : AppColors.sokoLilac;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // The pill above already names the action in the compact layout, so
        // repeating the title inside the panel is pure duplication — but the
        // panel still needs a way out: a top-left X collapses it.
        if (compact) ...[
          if (!_submitting)
            Align(
              alignment: Alignment.centerLeft,
              child: GestureDetector(
                onTap: () => setState(() => _expanded = false),
                child: const Icon(
                  LucideIcons.x,
                  size: 18,
                  color: AppColors.sokoShade3,
                ),
              ),
            ),
          const SizedBox(height: 8),
        ],
        if (!compact) ...[
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.memoryTellUsTitle,
                  style: const TextStyle(
                    color: AppColors.sokoInk,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    letterSpacing: -0.3,
                  ),
                ),
              ),
              if (!_submitting)
                GestureDetector(
                  onTap: () => setState(() => _expanded = false),
                  child: const Icon(
                    LucideIcons.x,
                    size: 18,
                    color: AppColors.sokoShade3,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 10),
        ],
        // The animated examples ride ABOVE the field rather than through
        // `hintText`: setting the hint each tick would rebuild the whole
        // TextField ~20x a second. Same reason the chat bar overlays its own.
        Stack(
          children: [
            TextField(
              controller: _controller,
              cursorColor: accent,
              autofocus: true,
              enabled: !_submitting,
              minLines: 3,
              maxLines: 6,
              maxLength: _maxChars,
              textCapitalization: TextCapitalization.sentences,
              style: const TextStyle(
                color: AppColors.sokoInk,
                fontSize: 14,
                height: 1.35,
                letterSpacing: -0.2,
              ),
              decoration: InputDecoration(
                // Compact runs the typewriter overlay instead of a static hint.
                hintText: compact ? null : l10n.memoryTellUsHint,
                hintStyle: const TextStyle(
                  color: AppColors.sokoShade3,
                  fontSize: 14,
                  fontWeight: FontWeight.w300,
                ),
                filled: true,
                fillColor: compact ? Colors.white : AppColors.sokoPaper,
                counterText: '',
                contentPadding: const EdgeInsets.all(12),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: accent, width: 1.5),
                ),
              ),
            ),
            if (compact && _controller.text.isEmpty)
              Positioned(
                // Indented past the caret. At the field's own 12 px the phrase
                // began exactly where the cursor blinks, so the caret drew on
                // top of its first letters; this puts it just before the text.
                left: 21,
                top: 12,
                right: 12,
                child: IgnorePointer(
                  child: AnimatedBuilder(
                    animation: _typing,
                    builder: (context, _) => Text(
                      _typing.displayText,
                      // Two lines: the examples are full sentences now, and a
                      // single line would ellipsize them mid-phrase while the
                      // typewriter is still running.
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: AppColors.sokoShade3,
                        fontSize: 14,
                        height: 1.35,
                        letterSpacing: -0.2,
                        fontWeight: FontWeight.w300,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerRight,
          child: SokoCtaButton(
            label: l10n.memoryTellUsSubmit,
            // Ink on the profile (the panel is a neutral ink tint, so a lilac
            // CTA would be the only colour on the surface); lilac on the legacy
            // page, where the whole card is lilac.
            variant: compact ? SokoCtaVariant.ink : SokoCtaVariant.lilac,
            loading: _submitting,
            expand: false,
            onPressed: _submitting ? null : _submit,
          ),
        ),
      ],
    );
  }
}
