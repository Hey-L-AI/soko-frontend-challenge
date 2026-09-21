import 'package:web/web.dart' as web;

/// Navigate to [url] via a hidden form submission.
///
/// On iOS, `window.open()` triggers Universal Link handling which causes
/// Safari/Chrome to open the Instagram app instead of staying in the browser.
/// Form submissions (even JS-triggered) do NOT trigger Universal Links,
/// so we build a hidden GET form and submit it programmatically.
void navigateViaFormImpl(String url) {
  final uri = Uri.parse(url);
  final baseUrl = '${uri.scheme}://${uri.host}${uri.path}';

  final form = web.document.createElement('form') as web.HTMLFormElement;
  form.method = 'GET';
  form.action = baseUrl;
  form.style.display = 'none';

  for (final entry in uri.queryParameters.entries) {
    final input = web.document.createElement('input') as web.HTMLInputElement;
    input.type = 'hidden';
    input.name = entry.key;
    input.value = entry.value;
    form.appendChild(input);
  }

  web.document.body!.appendChild(form);
  form.submit();
}
