import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/theme/app_colors.dart';
import '../../../data/models/models.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/utils/bottom_sheet_utils.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';

/// Bottom sheet showing places that failed to import, with CTAs to ask Soko.
class ImportFailedPlacesSheet extends StatelessWidget {
  final List<ImportFailedPlace> failedPlaces;
  final String? listId;
  final String? listName;

  const ImportFailedPlacesSheet({
    super.key,
    required this.failedPlaces,
    this.listId,
    this.listName,
  });

  /// Show the failed places sheet using the bottom nav hiding utility.
  /// Returns `true` if the user chose "Ask Soko" (import state should be kept
  /// so the failed-places banner reappears when they return to Lists).
  static Future<bool?> show(
    BuildContext context,
    WidgetRef ref, {
    required List<ImportFailedPlace> failedPlaces,
    String? listId,
    String? listName,
  }) {
    return showBottomSheetWithHiddenNav<bool>(
      context: context,
      ref: ref,
      builder: (context) => ImportFailedPlacesSheet(
        failedPlaces: failedPlaces,
        listId: listId,
        listName: listName,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final textSecondary = isDark
        ? AppColors.textSecondaryDark
        : AppColors.textSecondary;

    return DSSheetShell(
      // Canonical 14 px gap from buttons → sheet bottom. 24 px sides
      // preserved to match the existing failed-places typography spec.
      bodyPadding: const EdgeInsets.fromLTRB(24, 8, 24, 14),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Title
          Text(
            l10n.importFailedPlacesTitle(failedPlaces.length),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: textPrimary,
            ),
          ),
          const SizedBox(height: 16),
          // Failed places list
          ...failedPlaces.map(
            (place) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(Icons.place_outlined, size: 20, color: textSecondary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      place.name,
                      style: TextStyle(fontSize: 15, color: textPrimary),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(width: 8),
                  GestureDetector(
                    onTap: () {
                      _askSokoAbout(context, place.name);
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: primaryColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Text(
                        l10n.importFailedPlacesAskSoko,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: primaryColor,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          // View list button (if list was created)
          if (listId != null)
            ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                context.push('/lists/$listId');
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: primaryColor,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                minimumSize: const Size(double.infinity, 48),
                shape: const StadiumBorder(),
                elevation: 0,
              ),
              child: Text(
                l10n.importFailedPlacesViewList,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          if (listId != null) const SizedBox(height: 8),
          // Got it button
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              foregroundColor: textSecondary,
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
            child: Text(l10n.importFailedPlacesGotIt),
          ),
        ],
      ),
    );
  }

  void _askSokoAbout(BuildContext context, String placeName) {
    final l10n = Lt.of(context);
    final message = l10n.importFailedPlacesAskSokoMessage(placeName);
    final router = GoRouter.of(context);
    // Pop with true to signal "Ask Soko" was chosen — import state is preserved
    // so the failed-places banner reappears when user returns to Lists.
    Navigator.of(context).pop(true);
    // TODO: When list-as-context conversations are supported, pass listId/listName
    // so the conversation has the imported list as context (similar to how venue
    // cards appear as context in conversations today).
    router.push(AppRoutes.chat, extra: {'autoSendMessage': message});
  }
}
