// Utility functions for calendar integration

/// Generates a Google Calendar URL for creating a new event.
///
/// Returns a URL that, when opened, will open Google Calendar with a
/// pre-filled event form containing the provided details.
///
/// Parameters:
/// - [title]: The event title (required)
/// - [startDate]: The event start date/time (required)
/// - [endDate]: The event end date/time (defaults to startDate + 2 hours)
/// - [description]: Optional event description
/// - [location]: Optional event location (venue name, address, etc.)
///
/// Returns `null` if required parameters are missing.
String? generateGoogleCalendarUrl({
  required String title,
  required DateTime startDate,
  DateTime? endDate,
  String? description,
  String? location,
}) {
  final start = _formatCalendarDate(startDate);
  final end = _formatCalendarDate(endDate ?? startDate.add(const Duration(hours: 2)));

  final params = <String, String>{
    'action': 'TEMPLATE',
    'text': title,
    'dates': '$start/$end',
  };

  if (description != null && description.isNotEmpty) {
    params['details'] = description;
  }

  if (location != null && location.isNotEmpty) {
    params['location'] = location;
  }

  return Uri.https('calendar.google.com', '/calendar/render', params).toString();
}

/// Formats a DateTime for Google Calendar URL format.
/// Format: YYYYMMDDTHHMMSS (local time, no Z suffix)
String _formatCalendarDate(DateTime dt) {
  return '${dt.year}'
      '${_pad(dt.month)}'
      '${_pad(dt.day)}'
      'T'
      '${_pad(dt.hour)}'
      '${_pad(dt.minute)}'
      '00';
}

/// Pads a number with leading zero if needed.
String _pad(int value) => value.toString().padLeft(2, '0');
