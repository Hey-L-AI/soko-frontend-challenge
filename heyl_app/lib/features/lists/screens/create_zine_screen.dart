import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_lucide/flutter_lucide.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/exceptions/api_exceptions.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/theme/page_layout.dart';
import '../../../data/models/user_list.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/lists_provider.dart';
import '../../discovery/widgets/shell_sliver_page.dart';
import '../../moderation/content_blocked_handler.dart';
import '../utils/zine_cover_recipe.dart';
import '../widgets/list_visibility_toggle.dart';
import '../../../shared/widgets/bt_sq_ico.dart';

/// Extra payload for the `/discovery/lists/new` route — lets callers
/// (e.g. chat) hook into the post-create lifecycle without coupling the
/// screen to call-site state. Pass via `context.push(.., extra: ...)`.
class CreateZineRouteExtra {
  final String? initialName;
  final String? source;
  final Future<void> Function(UserList list)? onListCreated;

  /// When true, after `onListCreated` resolves the screen transitions
  /// to an in-screen success state with "Ver lista" / "Continuar"
  /// actions instead of navigating to the new zine. Used by chat so
  /// the user can either jump to the list or stay in the conversation.
  final bool showSuccessState;

  const CreateZineRouteExtra({
    this.initialName,
    this.source,
    this.onListCreated,
    this.showSuccessState = false,
  });
}

/// Single-input "name your zine" screen — Figma node `6197:5456`
/// (PROD-1764). Hosted under `DiscoveryShell` at `/discovery/lists/new`.
class CreateZineScreen extends ConsumerStatefulWidget {
  final String? initialName;
  final String? source;
  final Future<void> Function(UserList list)? onListCreated;
  final bool showSuccessState;

  const CreateZineScreen({
    super.key,
    this.initialName,
    this.source,
    this.onListCreated,
    this.showSuccessState = false,
  });

  @override
  ConsumerState<CreateZineScreen> createState() => _CreateZineScreenState();
}

class _CreateZineScreenState extends ConsumerState<CreateZineScreen> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;
  bool _submitting = false;
  String? _errorText;
  UserList? _createdList;
  ListVisibility _visibility = ListVisibility.public;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialName ?? '');
    _focusNode = FocusNode();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting) return;
    final name = _controller.text.trim();
    if (name.isEmpty) return;

    setState(() {
      _submitting = true;
      _errorText = null;
    });

    final l10n = Lt.of(context);
    try {
      final list = await ref
          .read(listsProvider.notifier)
          .createList(
            UserListCreate(
              name: name,
              visibility: _visibility,
              source: widget.source ?? ListSource.listUi,
              // PROD-1908 — random texture from the FE catalog.
              coverTexture: pickRandomZineTextureId(),
            ),
          );
      if (widget.onListCreated != null) {
        await widget.onListCreated!(list);
      }
      if (!mounted) return;

      if (widget.showSuccessState) {
        // Drop focus so the keyboard doesn't cover the success buttons.
        _focusNode.unfocus();
        setState(() {
          _submitting = false;
          _createdList = list;
        });
      } else {
        _popThenPushList(list);
      }
    } catch (e) {
      if (!mounted) return;
      // PROD-2264 — wordlist filter rejection on list name. Use the
      // backend's message inline (matches the existing
      // [_errorText] surface). The shared handler also fires
      // `content_blocked` analytics and shows a snackbar — keeping the
      // inline message in addition because the create flow already
      // anchors errors there.
      final blocked = ContentBlockedException.tryFrom(e);
      if (blocked != null) {
        final message = resolveContentBlockedMessage(
          blocked,
          l10n,
          field: ContentBlockedField.listName,
        );
        handleContentBlocked(
          ref,
          context,
          blocked,
          field: ContentBlockedField.listName,
        );
        setState(() {
          _submitting = false;
          _errorText = message;
        });
        return;
      }
      setState(() {
        _submitting = false;
        _errorText = l10n.createZineErrorGeneric;
      });
    }
  }

  void _cancel() {
    if (_submitting) return;
    Navigator.of(context).maybePop();
  }

  void _viewList() {
    final list = _createdList;
    if (list == null) return;
    _popThenPushList(list, viewQuery: '?view=list');
  }

  /// Pop the create screen, then push the list-detail route on the next
  /// frame. `context.pushReplacement` was leaving
  /// `discoveryNavObserver.topRouteName` stuck on the create page's
  /// (unset) name in this in-shell sibling-route transition, so
  /// [PinnedPageChrome] never resolved the list-name title. Sequencing
  /// pop → push as two discrete navigator operations fires `didPop` +
  /// `didPush` cleanly so the observer captures `listDetailPageName` and
  /// the listId arguments, and back navigation from the list returns to
  /// the entry point (Discovery / Lists hub / Chat) instead of the
  /// create screen.
  void _popThenPushList(UserList list, {String viewQuery = ''}) {
    final router = GoRouter.of(context);
    final pendingRoute = '/lists/${list.urlIdentifier}$viewQuery';
    Navigator.of(context).pop();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      router.push(pendingRoute);
    });
  }

  void _continueInChat() {
    if (_createdList == null) return;
    Navigator.of(context).maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final mediaQuery = MediaQuery.of(context);
    final inSuccess = _createdList != null;

    // The page lives inside [DiscoveryShell]'s shared
    // [SingleChildScrollView], which hands its child an unbounded
    // vertical extent. Spacer/Expanded need a finite parent, so we
    // bind the body to a SizedBox sized to the visible viewport.
    //
    // Body height = screen − viewInsets − navHeight, where navHeight
    // collapses to 0 (via `AnimatedSize` in the shell) while the
    // keyboard rises. The two animations run roughly in lockstep —
    // the nav starts collapsing the frame viewInsets first goes > 0,
    // and both finish around the same time — so `max(viewInsets,
    // navReservation)` tracks the actual body height continuously
    // through the transition. Switching `navReservation` discretely
    // on `viewInsets > 0` (an earlier attempt) created a single-frame
    // step where the page was ~navHeight taller than the body, which
    // let the SCV scroll and TextField focus drift the back button
    // up off-screen.
    //
    // navReservation ≈ nav content (~84 px: 20 + 44 + 20 from
    // `discovery_bottom_nav.dart`) + home-indicator inset (0 or
    // ~34 px). `viewPadding.bottom` is the system inset that the nav
    // bakes into its own SafeArea.
    final navReservation = 84.0 + mediaQuery.viewPadding.bottom;
    final availableHeight =
        mediaQuery.size.height -
        math.max(mediaQuery.viewInsets.bottom, navReservation);

    // PROD-1977: page owns its scrollable via [ShellSliverHost].
    return ShellSliverHost(
      slivers: [
        SliverToBoxAdapter(
          child: PageContent(
            child: ColoredBox(
              color: AppColors.sokoPaper,
              child: SizedBox(
                height: availableHeight,
                child: SafeArea(
                  bottom: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(15, 8, 15, 0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Align(
                          alignment: Alignment.centerLeft,
                          child: Semantics(
                            button: true,
                            label: MaterialLocalizations.of(
                              context,
                            ).backButtonTooltip,
                            child: IconButton(
                              onPressed: _submitting ? null : _cancel,
                              icon: const Icon(
                                Icons.arrow_back,
                                color: AppColors.sokoInk,
                                size: 24,
                              ),
                              // 48×48 hit target (Material guideline). Earlier
                              // 40×40 + compact density left only ~8 px of margin
                              // around the 24 px glyph, which felt icon-only.
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints(
                                minWidth: 48,
                                minHeight: 48,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 24),
                        Text(
                          inSuccess
                              ? l10n.chatCreateListSuccessTitle(
                                  _createdList!.name,
                                )
                              : l10n.createZineTitle,
                          textAlign: TextAlign.center,
                          style: AppTheme.displayPrimary(
                            fontSize: 42,
                            fontWeight: FontWeight.w300,
                            color: AppColors.sokoInk,
                            height: 0.94,
                            letterSpacing: -0.84,
                          ),
                        ),
                        if (!inSuccess) ...[
                          const SizedBox(height: 16),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 24),
                            child: Text(
                              l10n.createZineDescription,
                              textAlign: TextAlign.center,
                              style: AppTheme.body(
                                fontSize: 14,
                                color: AppColors.sokoInk.withValues(alpha: 0.7),
                              ),
                            ),
                          ),
                        ],
                        const Spacer(),
                        if (!inSuccess) ...[
                          Center(
                            child: ListVisibilityToggle(
                              selected: _visibility,
                              enabled: !_submitting,
                              onSelect: (v) => setState(() => _visibility = v),
                            ),
                          ),
                          const SizedBox(height: 30),
                        ],
                        if (!inSuccess)
                          Center(
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(maxWidth: 400),
                              child: SizedBox(
                                height: 60,
                                child: TextField(
                                  controller: _controller,
                                  focusNode: _focusNode,
                                  textAlign: TextAlign.center,
                                  enabled: !_submitting,
                                  maxLength: 72,
                                  textInputAction: TextInputAction.done,
                                  onSubmitted: (_) => _submit(),
                                  onChanged: (_) {
                                    if (_errorText != null) {
                                      setState(() => _errorText = null);
                                    }
                                  },
                                  cursorColor: AppColors.sokoInk,
                                  style: AppTheme.displayPrimary(
                                    fontSize: 42,
                                    fontWeight: FontWeight.w300,
                                    color: AppColors.sokoInk,
                                    height: 0.94,
                                    letterSpacing: -0.84,
                                  ),
                                  decoration: InputDecoration(
                                    counterText: '',
                                    isCollapsed: true,
                                    filled: false,
                                    contentPadding: const EdgeInsets.only(
                                      bottom: 8,
                                    ),
                                    hintText: l10n.createZineInputPlaceholder,
                                    hintStyle: AppTheme.displayPrimary(
                                      fontSize: 42,
                                      fontWeight: FontWeight.w300,
                                      color: AppColors.sokoInk.withValues(
                                        alpha: 0.3,
                                      ),
                                      height: 0.94,
                                      letterSpacing: -0.84,
                                    ),
                                    border: const UnderlineInputBorder(
                                      borderSide: BorderSide(
                                        color: AppColors.sokoInk,
                                        width: 1,
                                      ),
                                    ),
                                    enabledBorder: const UnderlineInputBorder(
                                      borderSide: BorderSide(
                                        color: AppColors.sokoInk,
                                        width: 1,
                                      ),
                                    ),
                                    focusedBorder: const UnderlineInputBorder(
                                      borderSide: BorderSide(
                                        color: AppColors.sokoInk,
                                        width: 1,
                                      ),
                                    ),
                                    disabledBorder: const UnderlineInputBorder(
                                      borderSide: BorderSide(
                                        color: AppColors.sokoInk,
                                        width: 1,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        const SizedBox(height: 30),
                        if (inSuccess)
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              BtSqIco(
                                icon: LucideIcons.message_circle,
                                label: l10n.chatCreateListSuccessContinue,
                                variant: BtSqIcoVariant.normal,
                                onTap: _continueInChat,
                              ),
                              const SizedBox(width: 6),
                              BtSqIco(
                                icon: LucideIcons.book_open,
                                label: l10n.chatCreateListSuccessViewList,
                                variant: BtSqIcoVariant.selected,
                                onTap: _viewList,
                              ),
                            ],
                          )
                        else
                          ValueListenableBuilder<TextEditingValue>(
                            valueListenable: _controller,
                            builder: (context, value, _) {
                              final hasName = value.text.trim().isNotEmpty;
                              return Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  BtSqIco(
                                    icon: LucideIcons.x,
                                    label: l10n.createZineCancelButton,
                                    variant: BtSqIcoVariant.normal,
                                    onTap: _submitting ? () {} : _cancel,
                                  ),
                                  const SizedBox(width: 6),
                                  Opacity(
                                    opacity: hasName && !_submitting
                                        ? 1.0
                                        : 0.5,
                                    child: _submitting
                                        ? _CreatingButton(
                                            label: l10n.createZineCreateButton,
                                          )
                                        : BtSqIco(
                                            icon: LucideIcons.book_open,
                                            label: l10n.createZineCreateButton,
                                            variant: BtSqIcoVariant.selected,
                                            onTap: hasName ? _submit : () {},
                                          ),
                                  ),
                                ],
                              );
                            },
                          ),
                        if (_errorText != null) ...[
                          const SizedBox(height: 12),
                          Center(
                            child: Text(
                              _errorText!,
                              textAlign: TextAlign.center,
                              style: AppTheme.body(
                                fontSize: 14,
                                color: AppColors.sokoInk,
                              ),
                            ),
                          ),
                        ],
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CreatingButton extends StatelessWidget {
  final String label;

  const _CreatingButton({required this.label});

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
        mainAxisSize: MainAxisSize.min,
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
