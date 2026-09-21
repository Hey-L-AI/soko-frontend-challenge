import 'dart:convert';
import 'dart:ui' show PlatformDispatcher;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_contacts/flutter_contacts.dart';
// `PermissionStatus` collides with flutter_contacts' enum; we only use
// `openAppSettings` from permission_handler, so hide the conflicting name.
import 'package:permission_handler/permission_handler.dart'
    hide PermissionStatus;
import 'package:phone_numbers_parser/phone_numbers_parser.dart';

import '../../../data/datasources/api/people_api.dart';
import '../../../data/models/social/user_search_item.dart';

/// Outcome of a contact-discovery attempt.
enum ContactSyncStatus {
  /// Not runnable on this platform (web has no reliable contacts API).
  unsupported,

  /// The user declined the Contacts permission.
  permissionDenied,

  /// Permission granted but no usable phone numbers were found.
  empty,

  /// Matched successfully (see [ContactSyncResult.matches]).
  ok,
}

/// A device contact that is NOT on Soko — an invite candidate. Only the local
/// display name is kept (the invite shares a generic install link, so no number
/// is needed).
class InvitableContact {
  final String name;
  const InvitableContact(this.name);
}

class ContactSyncResult {
  final ContactSyncStatus status;
  final UserSearchListResponse? matches;

  /// Map from a matched phone hash → the local address-book display name, so the
  /// UI can show "you may know as …" under each matched user (the same hashes
  /// the client sent; the backend echoes which one matched each user).
  final Map<String, String> hashToName;

  /// Device contacts (with a name) that matched no Soko user — the invite list.
  final List<InvitableContact> invitable;

  const ContactSyncResult(
    this.status, {
    this.matches,
    this.hashToName = const {},
    this.invitable = const [],
  });
}

/// A device contact reduced to its display name + the set of phone hashes it
/// produced, used transiently to classify Soko-vs-invite after matching.
class _RawContact {
  final String name;
  final Set<String> hashes;
  const _RawContact(this.name, this.hashes);
}

/// Contact discovery (mobile-only): request the OS Contacts permission, read
/// the address book, normalize each phone to E.164, hash it (SHA-256), and ask
/// the backend which hashes belong to Soko users. The raw address book never
/// leaves the device — only hashes are sent.
class ContactSyncService {
  final PeopleApi _api;
  ContactSyncService(this._api);

  /// Whether this platform can read contacts at all (native iOS/Android only).
  static bool get isSupported => !kIsWeb;

  Future<ContactSyncResult> sync() async {
    if (!isSupported) {
      return const ContactSyncResult(ContactSyncStatus.unsupported);
    }

    // OS permission prompt (flutter_contacts drives the native dialog).
    // flutter_contacts 2.x moved permissions under `FlutterContacts.permissions`
    // and returns a status enum instead of a bool. `read` = read-only access;
    // `limited` (iOS 18 partial-access) still lets us read the granted subset,
    // so both `granted` and `limited` count as usable.
    final status = await FlutterContacts.permissions.request(
      PermissionType.read,
    );
    final granted =
        status == PermissionStatus.granted ||
        status == PermissionStatus.limited;
    if (!granted) {
      return const ContactSyncResult(ContactSyncStatus.permissionDenied);
    }

    // 2.x: `getContacts(withProperties: true)` → `getAll(properties: {...})`.
    // We only read phone numbers, so fetch just that property (leaner than all).
    // `displayName` is always populated regardless of the property set.
    final contacts = await FlutterContacts.getAll(
      properties: {ContactProperty.phone},
    );

    // Parse phones against the device's region so locally-formatted numbers
    // (no country code) still resolve to E.164. We keep a hash→name map (for
    // "you may know as …") and each contact's hashes (to classify invite
    // candidates after the match). The raw address book never leaves the device.
    final IsoCode? region = _deviceRegion();
    final allHashes = <String>{};
    final hashToName = <String, String>{};
    final rawContacts = <_RawContact>[];
    for (final contact in contacts) {
      final name = (contact.displayName ?? '').trim();
      final contactHashes = <String>{};
      for (final phone in contact.phones) {
        final e164 = _toE164(phone.number, region);
        if (e164 != null) contactHashes.add(_sha256(e164));
      }
      if (contactHashes.isEmpty) continue;
      allHashes.addAll(contactHashes);
      if (name.isNotEmpty) {
        for (final h in contactHashes) {
          hashToName.putIfAbsent(h, () => name);
        }
      }
      rawContacts.add(_RawContact(name, contactHashes));
    }
    if (allHashes.isEmpty) {
      return const ContactSyncResult(ContactSyncStatus.empty);
    }

    final matches = await _api.matchContacts(allHashes.toList());

    // Hashes that belong to a Soko user (from the per-user phone_hash echo).
    final matchedHashes = <String>{
      for (final u in matches.items)
        if (u.phoneHash != null) u.phoneHash!,
    };

    // Contacts not on Soko, with a usable name → invite candidates. Dedup by
    // name (case-insensitive) and sort alphabetically for a stable list.
    final seenNames = <String>{};
    final invitable = <InvitableContact>[];
    for (final c in rawContacts) {
      if (c.name.isEmpty) continue;
      if (c.hashes.any(matchedHashes.contains)) continue;
      if (!seenNames.add(c.name.toLowerCase())) continue;
      invitable.add(InvitableContact(c.name));
    }
    invitable.sort(
      (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
    );

    return ContactSyncResult(
      ContactSyncStatus.ok,
      matches: matches,
      hashToName: hashToName,
      invitable: invitable,
    );
  }

  /// Open the OS app settings so the user can grant Contacts after declining.
  Future<void> openSettings() => openAppSettings();

  String _sha256(String value) => sha256.convert(utf8.encode(value)).toString();

  /// Normalize a raw contact number to E.164 ("+351912345678"), or null if it
  /// can't be parsed to a valid number.
  String? _toE164(String raw, IsoCode? region) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return null;
    try {
      final parsed = PhoneNumber.parse(trimmed, callerCountry: region);
      if (!parsed.isValid()) return null;
      return '+${parsed.countryCode}${parsed.nsn}';
    } catch (_) {
      return null;
    }
  }

  IsoCode? _deviceRegion() {
    final country = PlatformDispatcher.instance.locale.countryCode;
    if (country == null || country.isEmpty) return null;
    try {
      return IsoCode.values.byName(country.toUpperCase());
    } catch (_) {
      return null;
    }
  }
}
