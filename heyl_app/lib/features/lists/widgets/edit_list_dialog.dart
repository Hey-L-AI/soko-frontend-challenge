import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_lucide/flutter_lucide.dart';

import '../../../core/theme/app_colors.dart';
import '../../../l10n/generated/l10n.dart';

/// Dialog for editing list name and description
class EditListDialog extends StatefulWidget {
  final String currentName;
  final String? currentDescription;
  final String? currentPrompt;

  /// If true, focus on description field instead of name field
  final bool focusDescription;
  final Future<bool> Function(String name, String? description, String? prompt)
  onSave;

  /// Optional callback that opens the cover-selection sheet. When
  /// non-null, the dialog renders an extra "Escolher capa" / "Choose
  /// cover" row below the form fields. Only the new zine list page
  /// passes this today; the legacy dialog callsites omit it (cover
  /// selection lives in their action-bar overflow menu).
  final VoidCallback? onChooseCover;

  const EditListDialog({
    super.key,
    required this.currentName,
    this.currentDescription,
    this.currentPrompt,
    this.focusDescription = false,
    required this.onSave,
    this.onChooseCover,
  });

  /// Show dialog for editing name, description, and prompt
  static Future<bool?> show(
    BuildContext context, {
    required String currentName,
    String? currentDescription,
    String? currentPrompt,
    bool focusDescription = false,
    required Future<bool> Function(
      String name,
      String? description,
      String? prompt,
    )
    onSave,
    VoidCallback? onChooseCover,
  }) {
    return showDialog<bool>(
      context: context,
      builder: (context) => EditListDialog(
        currentName: currentName,
        currentDescription: currentDescription,
        currentPrompt: currentPrompt,
        focusDescription: focusDescription,
        onSave: onSave,
        onChooseCover: onChooseCover,
      ),
    );
  }

  @override
  State<EditListDialog> createState() => _EditListDialogState();
}

class _EditListDialogState extends State<EditListDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _descriptionController;
  late final TextEditingController _promptController;
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.currentName);
    _descriptionController = TextEditingController(
      text: widget.currentDescription ?? '',
    );
    _promptController = TextEditingController(text: widget.currentPrompt ?? '');
  }

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    _promptController.dispose();
    super.dispose();
  }

  Future<void> _handleSave() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);

    try {
      final success = await widget.onSave(
        _nameController.text.trim(),
        _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
        _promptController.text.trim().isEmpty
            ? null
            : _promptController.text.trim(),
      );

      if (mounted) {
        Navigator.of(context).pop(success);
      }
    } finally {
      if (mounted) {
        setState(() => _isLoading = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final primaryColor = isDark ? AppColors.primaryDarkMode : AppColors.primary;

    // Responsive sizing
    final screenWidth = MediaQuery.of(context).size.width;
    final isMobile = screenWidth < 600;
    // More lines on mobile for better touch experience
    final descriptionMaxLines = isMobile ? 5 : 4;

    return AlertDialog(
      title: Text(l10n.listsEditList),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 500, minWidth: 280),
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Name field
                TextFormField(
                  controller: _nameController,
                  decoration: InputDecoration(
                    labelText: l10n.listsNameLabel,
                    hintText: l10n.listsNamePlaceholder,
                    border: const OutlineInputBorder(),
                  ),
                  // PROD-1805: cap at 72 to match `create_zine_screen.dart`
                  // and the inline editor in `pinned_page_chrome.dart`.
                  // 72 = length of the worst-case sample that still reads
                  // cleanly across the chrome's 2-line slot. Backend still
                  // allows 100 (UserListUpdate.name maxLength) pending the
                  // sibling backend ticket.
                  maxLength: 72,
                  maxLengthEnforcement: MaxLengthEnforcement.enforced,
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return l10n.listsNameRequired;
                    }
                    return null;
                  },
                  autofocus: !widget.focusDescription,
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 16),

                // Description field
                TextFormField(
                  controller: _descriptionController,
                  decoration: InputDecoration(
                    labelText: l10n.listsDescriptionLabel,
                    hintText: l10n.listsDescriptionPlaceholder,
                    border: const OutlineInputBorder(),
                  ),
                  maxLines: descriptionMaxLines,
                  // Mirror the API contract on
                  // `UserListCreate.description`
                  // (`heyl/apps/user/schemas/user_list.py:47-49`,
                  // max_length=2000). Hard-enforce on web/iOS — see
                  // `docs/learnings/flutter-textfield-maxlength-not-enforced.md`.
                  maxLength: 2000,
                  maxLengthEnforcement: MaxLengthEnforcement.enforced,
                  autofocus: widget.focusDescription,
                  textCapitalization: TextCapitalization.sentences,
                ),
                const SizedBox(height: 16),

                // Prompt field (Soko suggestions)
                TextFormField(
                  controller: _promptController,
                  decoration: InputDecoration(
                    labelText: l10n.listsPromptLabel,
                    hintText: l10n.listSuggestionsPromptPlaceholder,
                    border: const OutlineInputBorder(),
                  ),
                  maxLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                ),
                if (widget.onChooseCover != null) ...[
                  const SizedBox(height: 12),
                  // Choose-cover row — pops the dialog and opens the
                  // shared cover-selection sheet.
                  OutlinedButton.icon(
                    onPressed: _isLoading
                        ? null
                        : () {
                            Navigator.of(context).pop(false);
                            widget.onChooseCover!();
                          },
                    icon: const Icon(LucideIcons.image, size: 18),
                    label: Text(l10n.editListChooseCover),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: primaryColor,
                      side: BorderSide(
                        color: primaryColor.withValues(alpha: 0.5),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.listsButtonCancel),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _handleSave,
          style: ElevatedButton.styleFrom(
            backgroundColor: primaryColor,
            foregroundColor: Colors.white,
          ),
          child: _isLoading
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(Colors.white),
                  ),
                )
              : Text(l10n.listsButtonSave),
        ),
      ],
    );
  }
}
