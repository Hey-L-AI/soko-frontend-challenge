import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/bt_sq_ico.dart';
import '../../../shared/widgets/soko_cta_button.dart';

/// Bottom sheet explaining how Soko's chat shares data with third-party AI
/// providers (PROD-2265 — Apple Guideline 5.1.1(i) / 5.1.2(i)). Scoped to the
/// chat experience — the copy makes clear the AI is used for the conversation,
/// not across the rest of the app.
///
/// Two modes share the same body:
/// - **Informational** ([show]) — single "Close" button. Opened from the auth
///   "By continuing…" disclaimer, the in-chat disclosure line, and Settings →
///   "AI & data" (review).
/// - **Consent gate** ([showConsent], Phase 2) — a "Don't Allow" / "Agree"
///   button pair that **blocks the first AI send** until the user agrees
///   (Apple R3). Resolves to `true` on Agree, `false` on Don't-Allow or
///   dismissal — declining is safe (no data is sent).
///
/// Uses the design-system sheet chrome ([DSSheetShell] +
/// [showBottomSheetWithHiddenNav]).
class AiDisclosureSheet extends StatelessWidget {
  const AiDisclosureSheet({super.key, this.consentMode = false});

  /// When `true`, render the blocking consent footer (Don't Allow / Agree) and
  /// pop with a `bool` result instead of the informational Close button.
  final bool consentMode;

  /// PROD-2265 — **easy-revert toggle.** Whether to list the per-provider
  /// "what's sent" bullets (OpenAI + Google/Gemini) on the sheet. Currently
  /// `false`: the minimal copy names the providers only via the linked Privacy
  /// Policy. If Apple **re-rejects** citing generic in-app provider language,
  /// flip this to `true` to restore the named-provider bullets — a one-line
  /// change. The ARB strings (`aiDisclosureSheetOpenAi` / `…Gemini`) and
  /// [_Bullet] are kept in place precisely so this revert needs no re-translation.
  /// Non-`const` on purpose so the guarded block isn't flagged as dead code.
  static final bool _showProviderBullets = false;

  /// Present the disclosure sheet via the design-system bottom-sheet helper
  /// (sokoPaper shell, drag handle, hidden bottom nav). Informational — resolves
  /// when dismissed.
  static Future<void> show(BuildContext context, WidgetRef ref) {
    return showBottomSheetWithHiddenNav<void>(
      context: context,
      ref: ref,
      builder: (_) => const AiDisclosureSheet(),
    );
  }

  /// Present the sheet as a **blocking consent gate** (Phase 2). Returns `true`
  /// only if the user taps Agree; `false` on Don't-Allow or any dismissal
  /// (barrier tap / drag-down) — the caller must not transmit data on `false`.
  static Future<bool> showConsent(BuildContext context, WidgetRef ref) async {
    final result = await showBottomSheetWithHiddenNav<bool>(
      context: context,
      ref: ref,
      builder: (_) => const AiDisclosureSheet(consentMode: true),
    );
    return result ?? false;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final theme = Theme.of(context);

    return DSSheetShell(
      bodyPadding: const EdgeInsets.symmetric(horizontal: 24),
      header: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 0),
        child: Text(
          l10n.aiDisclosureSheetTitle,
          style: theme.textTheme.headlineSmall,
        ),
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 12),
            // Para 1 — what's processed + purposes + never-shared (generic;
            // providers are named in the Privacy Policy, see the note below).
            Text(
              l10n.aiDisclosureSheetIntro,
              style: theme.textTheme.bodyMedium,
            ),
            // PROD-2265 easy-revert: flip [_showProviderBullets] to true to
            // restore the named-provider "what's sent" bullets on the gate.
            if (_showProviderBullets) ...[
              const SizedBox(height: 16),
              _Bullet(l10n.aiDisclosureSheetOpenAi),
              _Bullet(l10n.aiDisclosureSheetGemini),
            ],
            const SizedBox(height: 12),
            // Para 2 — providers may change; defer the current list to the
            // Privacy Policy (R2 by reference).
            Text(
              l10n.aiDisclosureSheetProviderList,
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 16),
            Align(
              alignment: Alignment.centerLeft,
              child: GestureDetector(
                onTap: () {
                  // Capture the router before popping the sheet, then open the
                  // full Privacy Policy on the root navigator.
                  final router = GoRouter.of(context);
                  Navigator.of(context).pop();
                  router.push(AppRoutes.privacy);
                },
                child: Text(
                  l10n.aiDisclosureSheetPolicyLink,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: AppColors.sokoInk,
                    decoration: TextDecoration.underline,
                    decorationColor: AppColors.sokoInk,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      footer: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 14),
        child: consentMode
            // Blocking consent gate (Phase 2): paired Don't Allow / Agree row,
            // same sticky-footer convention as the DS confirmation sheets.
            // Don't Allow pops `false` (no data sent); Agree pops `true`.
            ? Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Don't Allow gets less width; Agree gets more so longer
                  // translations (e.g. "Concordar e continuar") don't truncate.
                  Expanded(
                    flex: 2,
                    child: BtSqIco(
                      icon: null,
                      label: l10n.aiConsentSheetDecline,
                      variant: BtSqIcoVariant.normal,
                      expand: true,
                      onTap: () => Navigator.of(context).pop(false),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
                    child: BtSqIco(
                      icon: null,
                      label: l10n.aiConsentSheetAgree,
                      variant: BtSqIcoVariant.selected,
                      expand: true,
                      onTap: () => Navigator.of(context).pop(true),
                    ),
                  ),
                ],
              )
            : SokoCtaButton(
                label: l10n.aiDisclosureSheetClose,
                onPressed: () => Navigator.of(context).pop(),
              ),
      ),
    );
  }
}

class _Bullet extends StatelessWidget {
  const _Bullet(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Container(
              width: 4,
              height: 4,
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface,
                shape: BoxShape.circle,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
  }
}
