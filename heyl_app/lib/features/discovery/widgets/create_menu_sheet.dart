import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/router/app_router.dart';
import '../../../core/services/unified_analytics_service.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/auth_gating.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/providers.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/coming_soon_snackbar.dart';
import '../../contributions/widgets/photo_contribution_sheet.dart';
import '../../instagram_share/widgets/instagram_share_sheet.dart';
import '../../lists/widgets/import_list_sheet.dart';
import '../../product_tour/models/tour_step.dart';
import '../../product_tour/providers/product_tour_keys_provider.dart';
import '../../product_tour/widgets/tour_spotlight.dart';

/// Create menu, shown as a **persistent** bottom sheet inside the
/// DiscoveryShell's Scaffold (PROD-1952, replacing the legacy
/// `showCreateStubSheet` modal flow).
///
/// Why persistent (`Scaffold.showBottomSheet`) and not modal
/// (`showModalBottomSheet`):
///   • The sheet lives inside the Scaffold body, above the
///     `bottomNavigationBar` slot — so the bottom nav stays visible
///     AND tappable while the sheet is open.
///   • It's viewport-anchored (the Scaffold slot doesn't scroll with
///     page content), whereas a modal mounted on the shell's nested
///     Navigator would scroll with the body's `CustomScrollView`.
///   • The controller (`PersistentBottomSheetController.close`) gives
///     us a programmatic close handle for the tap-again-to-dismiss
///     behavior and the dismiss-overlay.
///
/// Five rows wired to existing flows where they exist; the rest show a
/// "Em breve" snackbar.
///   • Importa lista do Google Maps → opens the Google Maps list-import sheet
///   • Sugere um evento → opens the photo→event contribution sheet (PROD-2404)
///   • Partilha link do Instagram → opens the share-from-Instagram sheet
///   • Cria uma nova zine → existing `/discovery/lists/new` route
///   • Cria uma nova memória → coming soon
class CreateMenuSheet extends ConsumerWidget {
  const CreateMenuSheet({super.key, required this.onDismiss});

  /// Called by menu options that want to close the sheet before doing
  /// their own action (navigation, opening a follow-up sheet, etc.).
  /// Wires through to the live [PersistentBottomSheetController.close].
  final VoidCallback onDismiss;

  /// Toggle: open the sheet if it's closed, close it if it's open.
  ///
  /// Single entry point used by every trigger (Criar bottom-nav button,
  /// chat bar's "Add" pill, dismiss-overlay) so the open/close state
  /// stays consistent. The controller is held in
  /// [createMenuControllerProvider]; the `.closed` listener clears it
  /// when the sheet dismisses by any means (drag, programmatic close,
  /// scaffold rebuild).
  static void toggle(
    BuildContext context,
    WidgetRef ref, {
    required String entryPoint,
  }) {
    final existing = ref.read(createMenuControllerProvider);
    if (existing != null) {
      existing.close();
      return;
    }
    // PROD-1979 — block the create menu for guests. The bottom-nav
    // Criar button, the chat-bar Add pill and the discovery end-action
    // "Adiciona à Soko" all funnel through here, so one gate covers
    // every entry point.
    if (!ref.read(isAuthenticatedProvider)) {
      // ignore: discarded_futures
      requireAuth(
        context,
        ref,
        action: Lt.of(context).guestCreateMenuAction,
        referrer: AuthReferrer.guestGateCreate,
        onAuthenticated: () {},
      );
      return;
    }
    final scaffold = Scaffold.of(context);
    _openOn(scaffold, ref, entryPoint: entryPoint);
  }

  /// Same as [toggle] but takes a [ScaffoldState] directly. Used by the
  /// product-tour controller, whose captured context lives ABOVE the
  /// scaffold in the tree and so can't use `Scaffold.of`. The scaffold
  /// reference is stashed in `tourDiscoveryScaffoldKeyProvider` by the
  /// discovery shell.
  static void openWithScaffoldState(ScaffoldState scaffold, WidgetRef ref) {
    final existing = ref.read(createMenuControllerProvider);
    if (existing != null) return;
    if (!ref.read(isAuthenticatedProvider)) return;
    // No entryPoint → no create_open (this is a product-tour demo open, not a
    // real user create intent). PROD-3168.
    _openOn(scaffold, ref);
  }

  static void _openOn(
    ScaffoldState scaffold,
    WidgetRef ref, {
    String? entryPoint,
  }) {
    // PROD-3168: fire create_open only when the sheet actually opens (guests are
    // gated before this) and only for real user entry points.
    if (entryPoint != null) {
      ref
          .read(unifiedAnalyticsProvider)
          .trackCreateOpen(entryPoint: entryPoint);
    }
    // PROD-3674 — capture the notifier BEFORE the async gap, and never touch
    // `ref` after it. This `ref` belongs to the CALLER, which is usually
    // [DiscoveryBottomNav]; any nav-hiding sheet disposes that widget by
    // construction (`showBottomSheetWithHiddenNav` flips
    // `bottomNavVisibleProvider` and `discovery_shell.dart` swaps the nav
    // subtree for a `SizedBox.shrink()`). `ref.read` on a disposed
    // `ConsumerState` **throws**, so reading it inside `closed.then` is a
    // latent crash — and it also leaves `createMenuControllerProvider`
    // pointing at a dead controller, so Criar reads as open and won't reopen.
    //
    // Reachable via: open Criar from the nav → tap another tab on `/map` →
    // `_closeCreateSheetIfOpen()` starts this close while the map's leave
    // prompt disposes the nav. Whether `closed` resolves before or after that
    // disposal is a race (the leave flow's boundary lookup is cached), which
    // is exactly why it must not depend on the widget being alive.
    // Safe because `createMenuControllerProvider` is a plain `StateProvider`
    // (not `autoDispose`), so the notifier outlives the widget.
    final controllerNotifier = ref.read(createMenuControllerProvider.notifier);
    final controller = scaffold.showBottomSheet(
      (sheetContext) => CreateMenuSheet(
        onDismiss: () => controllerNotifier.state?.close(),
      ),
      // DSSheetShell owns the visible chrome (rounded top corners,
      // sokoPaper bg, drag handle) — keep the persistent sheet's own
      // Material transparent so it doesn't double up.
      backgroundColor: Colors.transparent,
      // Swipe-down-to-dismiss.
      enableDrag: true,
    );
    controllerNotifier.state = controller;
    controller.closed.then((_) {
      // Defensive: only clear if the provider still points at THIS
      // controller (avoids clobbering a fresh open that landed between
      // close() and this microtask).
      if (controllerNotifier.state == controller) {
        controllerNotifier.state = null;
      }
    });
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = isDark
        ? AppColors.textPrimaryDark
        : AppColors.textPrimary;
    final dividerColor = (isDark ? AppColors.borderDarkMode : AppColors.border)
        .withValues(alpha: 0.5);
    // PROD-2222 — the Adiciona step's tooltip card is rendered
    // OUTSIDE the showcaseview package as a bottom-anchored card
    // (`_TourAdicionaTooltip` in product_tour_host.dart). The
    // showcase would otherwise place the tooltip above the sheet
    // body, which covered the AddToSoko pill in the chat bar.
    //
    // Per user spec (2026-06-01): the createSheet step plays a
    // drawer-rect → connector → card sequence (mirroring step 1's
    // chat-bar rect). The Soko-Blue rectangle is drawn by
    // [TourSecondaryHighlight] wrapping the [DSSheetShell] below,
    // keyed by [productTourKeysProvider.createSheet] so
    // [_TourAdicionaTooltip] can read the drawer's actual rect to
    // anchor the connector + (on desktop) the card.
    final tourKeys = ref.watch(productTourKeysProvider);
    return TourSecondaryHighlight(
      activeOnSteps: const {TourStep.createSheet},
      borderRadius: 20,
      strokeWidth: 6.0,
      child: KeyedSubtree(
        key: tourKeys.createSheet,
        child: DSSheetShell(
          body: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _CreateOption(
                icon: Icons.place_outlined,
                label: l10n.createMenuSuggestPlace,
                textColor: textPrimary,
                onTap: () {
                  ref
                      .read(unifiedAnalyticsProvider)
                      .trackCreateOptionSelected(
                        option: CreateOption.googleMapsImport,
                      );
                  onDismiss();
                  showImportListSheet(context, ref: ref, source: 'create_menu');
                },
              ),
              Divider(height: 1, indent: 56, color: dividerColor),
              // PROD-2404 — "Sugere um evento" opens the photo→event
              // contribution sheet (previously a coming-soon placeholder).
              _CreateOption(
                icon: Icons.event_outlined,
                label: l10n.createMenuSuggestEvent,
                textColor: textPrimary,
                onTap: () {
                  ref
                      .read(unifiedAnalyticsProvider)
                      .trackCreateOptionSelected(
                        option: CreateOption.suggestEvent,
                      );
                  onDismiss();
                  showPhotoContributionSheet(
                    context,
                    ref: ref,
                    source: 'create_menu',
                  );
                },
              ),
              Divider(height: 1, indent: 56, color: dividerColor),
              _CreateOption(
                icon: Icons.visibility_outlined,
                label: l10n.createMenuSuggestInstagram,
                textColor: textPrimary,
                onTap: () {
                  ref
                      .read(unifiedAnalyticsProvider)
                      .trackCreateOptionSelected(
                        option: CreateOption.instagramLink,
                      );
                  onDismiss();
                  showInstagramShareSheet(
                    context,
                    ref: ref,
                    source: 'create_menu',
                  );
                },
              ),
              Divider(height: 1, indent: 56, color: dividerColor),
              _CreateOption(
                icon: Icons.menu_book_outlined,
                label: l10n.createMenuCreateZine,
                textColor: textPrimary,
                onTap: () {
                  ref
                      .read(unifiedAnalyticsProvider)
                      .trackCreateOptionSelected(option: CreateOption.newZine);
                  onDismiss();
                  context.push(AppRoutes.discoveryListCreate);
                },
              ),
              Divider(height: 1, indent: 56, color: dividerColor),
              _CreateOption(
                icon: Icons.bookmark_outline,
                label: l10n.createMenuCreateMemory,
                textColor: textPrimary,
                onTap: () {
                  ref
                      .read(unifiedAnalyticsProvider)
                      .trackCreateOptionSelected(
                        option: CreateOption.newMemory,
                      );
                  _comingSoon(context, l10n);
                },
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  void _comingSoon(BuildContext context, Lt l10n) {
    onDismiss();
    showComingSoonSnackBar(context, l10n.discoveryCreateStubTitle);
  }
}

class _CreateOption extends StatelessWidget {
  const _CreateOption({
    required this.icon,
    required this.label,
    required this.textColor,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color textColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        child: Row(
          children: [
            Icon(icon, size: 20, color: textColor),
            const SizedBox(width: 20),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w400,
                  color: textColor,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
