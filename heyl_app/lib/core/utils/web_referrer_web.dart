import 'package:web/web.dart' as web;

/// Web implementation — reads document.referrer.
String? getDocumentReferrer() {
  try {
    final referrer = web.document.referrer;
    if (referrer.isNotEmpty) {
      return referrer;
    }
    return null;
  } catch (_) {
    return null;
  }
}
