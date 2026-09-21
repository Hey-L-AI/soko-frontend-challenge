import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../data/models/social_proof.dart';
import '../../../data/models/venue_claim.dart';
import '../../../l10n/generated/l10n.dart';
import '../../../providers/api_provider.dart';
import '../../../shared/notifications/heyl_notification.dart';
import '../../../shared/notifications/notification_state.dart';
import '../../../shared/widgets/bottom_sheet/ds_sheet_shell.dart';
import '../../../shared/widgets/soko_cta_button.dart';
import '../../../shared/widgets/soko_text_field.dart';
import '../providers/venue_claim_provider.dart';
import '../utils/owner_hours.dart';
import 'owner_hours_editor.dart';
import 'venue_gallery_section.dart';

/// D1 owner editor. It intentionally submits only changed fields so fields the
/// detail response did not expose are never accidentally cleared.
///
/// Beyond the text fields it also lets the owner upload a cover photo (which
/// overrides the Google image) and remove their ownership connection entirely.
class VenueOwnerEditSheet extends ConsumerStatefulWidget {
  const VenueOwnerEditSheet({
    super.key,
    required this.venue,
    required this.onSaved,
  });

  final VenueDetailResponse venue;
  final VoidCallback onSaved;

  @override
  ConsumerState<VenueOwnerEditSheet> createState() =>
      _VenueOwnerEditSheetState();
}

class _VenueOwnerEditSheetState extends ConsumerState<VenueOwnerEditSheet> {
  late final Map<String, TextEditingController> _controllers;
  bool _saving = false;
  bool _uploadingPhoto = false;
  bool _removing = false;
  Uint8List? _pickedPhoto;
  late List<DayHours> _hours;
  late final Map<String, dynamic> _hoursBaseline;

  @override
  void initState() {
    super.initState();
    final venue = widget.venue;
    _controllers = {
      'name': TextEditingController(text: venue.name),
      'address': TextEditingController(text: venue.address ?? ''),
      'description_short': TextEditingController(
        text: venue.descriptionShort ?? '',
      ),
      'description_long': TextEditingController(
        text: venue.descriptionLong ?? '',
      ),
      'phone': TextEditingController(text: venue.phone ?? ''),
      'website': TextEditingController(text: venue.website ?? ''),
      'instagram': TextEditingController(text: venue.instagram ?? ''),
      'twitter': TextEditingController(text: venue.twitter ?? ''),
      'facebook': TextEditingController(text: venue.facebook ?? ''),
    };
    // Structured opening-hours editor state; baseline is the serialised initial
    // (compared against on save, not the raw backend map, whose slot formatting
    // may differ).
    _hours = parseOwnerHours(venue.openingHours);
    _hoursBaseline = serializeOwnerHours(_hours);
  }

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  String _value(String key) => _controllers[key]!.text.trim();

  Future<void> _save() async {
    final l10n = Lt.of(context);
    final venue = widget.venue;
    final fields = <String, dynamic>{};
    final initial = <String, String>{
      'name': venue.name,
      'address': venue.address ?? '',
      'description_short': venue.descriptionShort ?? '',
      'description_long': venue.descriptionLong ?? '',
      'phone': venue.phone ?? '',
      'website': venue.website ?? '',
      'instagram': venue.instagram ?? '',
      'twitter': venue.twitter ?? '',
      'facebook': venue.facebook ?? '',
    };
    for (final entry in initial.entries) {
      final current = _value(entry.key);
      if (current == entry.value) continue;
      // Name and address cannot be cleared — skip an empty change rather than
      // sending a null the server would reject (address re-geocodes on the BE).
      if ((entry.key == 'name' || entry.key == 'address') && current.isEmpty) {
        continue;
      }
      fields[entry.key] = current.isEmpty && entry.key != 'name'
          ? null
          : current;
    }
    // Opening hours: include only when the structured editor changed. An empty
    // map (everything cleared) sends null to clear it.
    final hoursMap = serializeOwnerHours(_hours);
    if (!ownerHoursMapsEqual(hoursMap, _hoursBaseline)) {
      fields['opening_hours'] = hoursMap.isEmpty ? null : hoursMap;
    }
    if (fields.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    if (fields['name'] != null && (fields['name'] as String).isEmpty) {
      showSoko(
        ref,
        message: l10n.businessOwnershipEditNameRequired,
        variant: SokoVariant.error,
      );
      return;
    }
    setState(() => _saving = true);
    ref.read(optimisticOwnerVenueEditsProvider(venue.id).notifier).state =
        fields;
    try {
      await ref
          .read(venueClaimApiProvider)
          .updateOwnedVenue(venue.id, OwnerVenueUpdate(fields));
      if (!mounted) return;
      widget.onSaved();
      showSoko(
        ref,
        message: l10n.businessOwnershipEditSaved,
        variant: SokoVariant.success,
      );
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      ref.read(optimisticOwnerVenueEditsProvider(venue.id).notifier).state =
          null;
      setState(() => _saving = false);
      showSoko(
        ref,
        message: l10n.businessOwnershipEditFailed,
        variant: SokoVariant.error,
      );
    }
  }

  Future<void> _pickAndUploadPhoto() async {
    if (_uploadingPhoto) return;
    final l10n = Lt.of(context);
    final XFile? file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      maxWidth: 1920,
      maxHeight: 1920,
      imageQuality: 85,
    );
    if (file == null) return;
    final bytes = await file.readAsBytes();
    if (!mounted) return;
    setState(() {
      _pickedPhoto = bytes;
      _uploadingPhoto = true;
    });
    try {
      await ref
          .read(venueClaimApiProvider)
          .uploadOwnedVenuePhoto(
            widget.venue.id,
            bytes: bytes,
            filename: file.name.isNotEmpty ? file.name : 'cover.jpg',
          );
      if (!mounted) return;
      setState(() => _uploadingPhoto = false);
      // Refresh the detail behind the sheet so the new cover renders everywhere.
      widget.onSaved();
      showSoko(
        ref,
        message: l10n.businessOwnershipEditPhotoSaved,
        variant: SokoVariant.success,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _pickedPhoto = null;
        _uploadingPhoto = false;
      });
      showSoko(
        ref,
        message: l10n.businessOwnershipEditPhotoFailed,
        variant: SokoVariant.error,
      );
    }
  }

  Future<void> _removeBusiness() async {
    if (_removing) return;
    final l10n = Lt.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l10n.businessOwnershipRemoveConfirmTitle),
        content: Text(l10n.businessOwnershipRemoveConfirmBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(l10n.businessOwnershipRemoveCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(
              l10n.businessOwnershipRemoveConfirmCta,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _removing = true);
    try {
      await ref.read(venueClaimApiProvider).removeOwnedVenue(widget.venue.id);
      if (!mounted) return;
      // The venue is no longer owned — refresh the detail + every claim-aware
      // surface so the "Claim" CTA returns and the owner affordance disappears.
      widget.onSaved();
      ref.invalidate(venueClaimStateProvider(widget.venue.id));
      ref.invalidate(ownedVenueIdsProvider);
      ref.invalidate(ownedBusinessProfileEntriesProvider);
      showSoko(
        ref,
        message: l10n.businessOwnershipRemoved,
        variant: SokoVariant.success,
      );
      Navigator.of(context).pop();
    } catch (_) {
      if (!mounted) return;
      setState(() => _removing = false);
      showSoko(
        ref,
        message: l10n.businessOwnershipRemoveFailed,
        variant: SokoVariant.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = Lt.of(context);
    return DSSheetShell(
      body: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
        children: [
          Text(
            l10n.businessOwnershipEditTitle,
            style: const TextStyle(
              fontFamily: 'UnJamoBatang',
              fontSize: 28,
              height: .96,
            ),
          ),
          const SizedBox(height: 20),
          _CoverPhotoSection(
            label: l10n.businessOwnershipEditPhotoLabel,
            actionLabel: (_pickedPhoto != null || widget.venue.imageUrl != null)
                ? l10n.businessOwnershipEditPhotoChange
                : l10n.businessOwnershipEditPhotoAdd,
            currentImageUrl: widget.venue.imageUrl,
            pickedBytes: _pickedPhoto,
            uploading: _uploadingPhoto,
            onPick: _pickAndUploadPhoto,
          ),
          const SizedBox(height: 20),
          VenueGallerySection(venueId: widget.venue.id),
          const SizedBox(height: 20),
          for (final field in _fields(l10n)) ...[
            Text(
              field.label,
              style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            ),
            const SizedBox(height: 6),
            SokoTextField(
              controller: _controllers[field.key]!,
              minLines: field.multiline ? 3 : 1,
              maxLines: field.multiline ? 8 : 1,
              keyboardType: field.key == 'website'
                  ? TextInputType.url
                  : TextInputType.text,
              maxLength: field.maxLength,
              textAlignVertical: field.multiline ? TextAlignVertical.top : null,
            ),
            const SizedBox(height: 16),
          ],
          Text(
            l10n.businessOwnershipEditHoursLabel,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 6),
          OwnerHoursEditor(
            initial: _hours,
            onChanged: (hours) => _hours = hours,
          ),
          const SizedBox(height: 20),
          SokoCtaButton(
            label: l10n.profileEditSave,
            loading: _saving,
            onPressed: _save,
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _removing ? null : _removeBusiness,
            child: Text(
              l10n.businessOwnershipRemove,
              style: const TextStyle(color: Colors.red),
            ),
          ),
        ],
      ),
    );
  }

  List<_EditableField> _fields(Lt l10n) => [
    _EditableField('name', l10n.businessOwnershipEditName, maxLength: 500),
    _EditableField(
      'address',
      l10n.businessOwnershipEditAddress,
      maxLength: 1000,
    ),
    _EditableField(
      'description_short',
      l10n.businessOwnershipEditShortDescription,
      multiline: true,
      maxLength: 1000,
    ),
    _EditableField(
      'description_long',
      l10n.businessOwnershipEditLongDescription,
      multiline: true,
      maxLength: 10000,
    ),
    _EditableField('phone', l10n.businessOwnershipEditPhone, maxLength: 255),
    _EditableField('website', l10n.profileEditWebsite, maxLength: 2000),
    _EditableField('instagram', l10n.profileEditInstagram, maxLength: 500),
    _EditableField(
      'twitter',
      l10n.businessOwnershipEditTwitter,
      maxLength: 500,
    ),
    _EditableField(
      'facebook',
      l10n.businessOwnershipEditFacebook,
      maxLength: 500,
    ),
  ];
}

class _CoverPhotoSection extends StatelessWidget {
  const _CoverPhotoSection({
    required this.label,
    required this.actionLabel,
    required this.currentImageUrl,
    required this.pickedBytes,
    required this.uploading,
    required this.onPick,
  });

  final String label;
  final String actionLabel;
  final String? currentImageUrl;
  final Uint8List? pickedBytes;
  final bool uploading;
  final VoidCallback onPick;

  @override
  Widget build(BuildContext context) {
    Widget preview;
    if (pickedBytes != null) {
      preview = Image.memory(pickedBytes!, fit: BoxFit.cover);
    } else if (currentImageUrl != null) {
      preview = Image.network(currentImageUrl!, fit: BoxFit.cover);
    } else {
      preview = const ColoredBox(color: Color(0x11000000));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: AspectRatio(
            aspectRatio: 16 / 9,
            child: Stack(
              fit: StackFit.expand,
              children: [
                preview,
                if (uploading)
                  const ColoredBox(
                    color: Color(0x66000000),
                    child: Center(child: CircularProgressIndicator()),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: uploading ? null : onPick,
          icon: const Icon(Icons.photo_camera_outlined, size: 18),
          label: Text(actionLabel),
        ),
      ],
    );
  }
}

class _EditableField {
  const _EditableField(
    this.key,
    this.label, {
    this.multiline = false,
    this.maxLength,
  });
  final String key;
  final String label;
  final bool multiline;
  final int? maxLength;
}
