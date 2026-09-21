import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/auth_gating.dart';
import '../../../core/utils/soko_texture.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../shared/widgets/clickable.dart';
import '../../../shared/widgets/soko_grunge_surface.dart';
import '../../contributions/widgets/photo_contribution_sheet.dart';
import '../../instagram_share/widgets/instagram_share_sheet.dart';
import '../../lists/widgets/import_list_sheet.dart';
import '../../profile/screens/discover_people_screen.dart';
import '../models/library_filter.dart';
import 'library_item_row.dart';

/// Analytics `source` on the Instagram / Maps / photo sheets opened from
/// these rows. Distinct from `create_menu` so the funnel can split them.
const String kLibraryEndAnalyticsSource = 'library_end';

enum LibraryEndActionKind { instagram, place, event, zine, contacts }

/// Regular grain on every library add row — same 340S cardstock as IG import.
String libraryEndTextureFor(LibraryEndActionKind kind) =>
    kSokoWeeklyBundleCardTexture;

/// Which foot-of-list rows a `/library` tab shows.
///
/// Instagram on every tab except Pessoas. The type-specific create row
/// matches the tab. Landing (no category) keeps all four. Pessoas is
/// Figma `7660:31485` — import contacts only.
List<LibraryEndActionKind> libraryEndActionsFor(LibraryCategory? category) {
  return switch (category) {
    null => const [
      LibraryEndActionKind.instagram,
      LibraryEndActionKind.place,
      LibraryEndActionKind.event,
      LibraryEndActionKind.zine,
    ],
    LibraryCategory.eventos => const [
      LibraryEndActionKind.instagram,
      LibraryEndActionKind.event,
    ],
    LibraryCategory.sitios => const [
      LibraryEndActionKind.instagram,
      LibraryEndActionKind.place,
    ],
    LibraryCategory.zines => const [
      LibraryEndActionKind.instagram,
      LibraryEndActionKind.zine,
    ],
    LibraryCategory.pessoas => const [LibraryEndActionKind.contacts],
  };
}

/// Figma `7660:30620`–`7660:30641` + people row `7660:31485`.
class LibraryEndActions extends ConsumerWidget {
  const LibraryEndActions({super.key, this.category});

  final LibraryCategory? category;

  static const _iconSize = 18.667;
  static const _tileRadius = 8 / 3;
  static const _igAsset = 'assets/images/icons/discovery/icon-ig.svg';

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final kinds = libraryEndActionsFor(category);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < kinds.length; i++) ...[
          if (i > 0) const SizedBox(height: kLibraryRowGap),
          _rowFor(context, ref, kinds[i]),
        ],
      ],
    );
  }

  Widget _rowFor(
    BuildContext context,
    WidgetRef ref,
    LibraryEndActionKind kind,
  ) {
    final lt = Lt.of(context);
    return switch (kind) {
      LibraryEndActionKind.instagram => _row(
        context,
        ref,
        kind: LibraryEndActionKind.instagram,
        fill: AppColors.sokoPurple,
        icon: SvgPicture.asset(
          _igAsset,
          width: _iconSize,
          height: _iconSize,
          colorFilter: const ColorFilter.mode(
            AppColors.sokoInk,
            BlendMode.srcIn,
          ),
        ),
        label: lt.libraryEndImportInstagram,
        option: CreateOption.instagramLink,
        onAuthenticated: () => showInstagramShareSheet(
          context,
          ref: ref,
          source: kLibraryEndAnalyticsSource,
        ),
      ),
      LibraryEndActionKind.place => _row(
        context,
        ref,
        kind: LibraryEndActionKind.place,
        fill: AppColors.sokoBlue,
        icon: const Icon(
          LucideIcons.map_pin,
          size: _iconSize,
          color: AppColors.sokoInk,
        ),
        label: lt.libraryEndAddPlace,
        option: CreateOption.googleMapsImport,
        onAuthenticated: () => showImportListSheet(
          context,
          ref: ref,
          source: kLibraryEndAnalyticsSource,
        ),
      ),
      LibraryEndActionKind.event => _row(
        context,
        ref,
        kind: LibraryEndActionKind.event,
        fill: AppColors.sokoGreen,
        icon: const Icon(
          LucideIcons.calendar,
          size: _iconSize,
          color: AppColors.sokoInk,
        ),
        label: lt.libraryEndAddEvent,
        option: CreateOption.suggestEvent,
        onAuthenticated: () => showPhotoContributionSheet(
          context,
          ref: ref,
          source: kLibraryEndAnalyticsSource,
        ),
      ),
      LibraryEndActionKind.zine => _row(
        context,
        ref,
        kind: LibraryEndActionKind.zine,
        fill: AppColors.sokoRed,
        icon: const Icon(
          LucideIcons.book_open,
          size: _iconSize,
          color: AppColors.sokoInk,
        ),
        label: lt.libraryEndCreateZine,
        option: CreateOption.newZine,
        onAuthenticated: () => context.push(AppRoutes.discoveryListCreate),
      ),
      LibraryEndActionKind.contacts => _row(
        context,
        ref,
        kind: LibraryEndActionKind.contacts,
        fill: AppColors.sokoYellow,
        icon: const Icon(
          LucideIcons.user,
          size: _iconSize,
          color: AppColors.sokoInk,
        ),
        label: lt.libraryEndImportContacts,
        onAuthenticated: () {
          if (kIsWeb) {
            showFindPeopleOnAppSheet(
              context,
              title: lt.findContactsTitle,
              body: lt.findPeopleContactsOnAppBody,
            );
          } else {
            context.push(AppRoutes.findPeopleContacts);
          }
        },
      ),
    };
  }

  Widget _row(
    BuildContext context,
    WidgetRef ref, {
    required LibraryEndActionKind kind,
    required Color fill,
    required Widget icon,
    required String label,
    required VoidCallback onAuthenticated,
    String? option,
  }) {
    return Clickable(
      onTap: () => requireAuth(
        context,
        ref,
        action: Lt.of(context).guestCreateMenuAction,
        referrer: AuthReferrer.guestGateCreate,
        onAuthenticated: () {
          if (option != null) {
            ref
                .read(unifiedAnalyticsProvider)
                .trackCreateOptionSelected(option: option);
          }
          onAuthenticated();
        },
      ),
      child: SizedBox(
        height: kLibraryRowHeight,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SokoGrungeSurface(
              width: kLibraryThumbWidth,
              height: kLibraryRowHeight,
              radius: _tileRadius,
              color: fill,
              texture: libraryEndTextureFor(kind),
              textureOpacity: kSokoRitualCardTextureOpacity,
              child: icon,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: AppTheme.mobileB1Reg(color: AppColors.sokoInk),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
