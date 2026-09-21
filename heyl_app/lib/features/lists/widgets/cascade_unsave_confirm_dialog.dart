import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/soko_cta_button.dart';

/// PROD-3873 — compact modal shown before a cascading unsave.
///
/// Removing a saved item removes it from every list the owner holds it in
/// (Saved Items ledger, the auto-filed typed lists, and any curated zine).
/// The backend does this unconditionally, so we disclose it first — but only
/// name the user's own **curated** lists ([listNames]); the auto-managed lists
/// are implied and naming them would surface concepts the user never filed
/// into by hand.
///
/// Returns `true` when the user confirms the removal, `false`/`null` (coerced
/// to `false`) when they cancel or dismiss.
Future<bool> showCascadeUnsaveConfirmDialog(
  BuildContext context, {
  required List<String> listNames,
}) async {
  final result = await showDialog<bool>(
    context: context,
    builder: (dialogContext) =>
        _CascadeUnsaveConfirmDialog(listNames: listNames),
  );
  return result ?? false;
}

class _CascadeUnsaveConfirmDialog extends StatelessWidget {
  const _CascadeUnsaveConfirmDialog({required this.listNames});

  final List<String> listNames;

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return AlertDialog(
      backgroundColor: AppColors.sokoPaper,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      titlePadding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
      contentPadding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
      title: Text(
        l10n.cascadeUnsaveTitle,
        style: AppTheme.subtitle(color: AppColors.sokoInk),
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            // With curated zines to name, list them; otherwise (the item is
            // only in the auto-managed saved lists) use generic copy.
            listNames.isEmpty
                ? l10n.cascadeUnsaveBodyGeneric
                : l10n.cascadeUnsaveBody,
            style: AppTheme.body(fontSize: 14, color: AppColors.sokoInk),
          ),
          if (listNames.isNotEmpty) const SizedBox(height: 12),
          // Curated lists rendered as compact, left-aligned app rows. Capped
          // height + scroll so a long list stays a compact modal.
          if (listNames.isNotEmpty)
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 180),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final name in listNames)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 5),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              const Icon(
                                LucideIcons.bookmark,
                                size: 15,
                                color: AppColors.sokoInk,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: AppTheme.body(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: AppColors.sokoInk,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(
            l10n.listsButtonCancel,
            style: AppTheme.body(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: AppColors.sokoInk,
            ),
          ),
        ),
        SokoCtaButton(
          label: l10n.cascadeUnsaveButtonRemove,
          variant: SokoCtaVariant.red,
          expand: false,
          onPressed: () => Navigator.of(context).pop(true),
        ),
      ],
    );
  }
}
