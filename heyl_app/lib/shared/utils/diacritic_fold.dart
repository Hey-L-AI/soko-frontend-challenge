/// Lowercase + strip common Latin diacritics for accent-insensitive
/// prefix/substring matching. Handles PT/ES/FR/DE/IT characters.
///
/// Extracted from the lists country picker so any sheet doing
/// accent-tolerant search can reuse the same fold (search "acores" matches
/// "Açores", "espana" matches "España").
String foldDiacritics(String s) {
  const from =
      'áàâãäåāéèêëēíìîïīóòôõöōúùûüūçñýÿžšß'
      'ÁÀÂÃÄÅĀÉÈÊËĒÍÌÎÏĪÓÒÔÕÖŌÚÙÛÜŪÇÑÝŸŽŠ';
  const to =
      'aaaaaaaeeeeeiiiiiooooooouuuuucnyyzss'
      'AAAAAAAEEEEEIIIIIOOOOOOUUUUUCNYYZS';
  final sb = StringBuffer();
  for (final r in s.runes) {
    final ch = String.fromCharCode(r);
    final i = from.indexOf(ch);
    sb.write(i >= 0 ? to[i] : ch);
  }
  return sb.toString().toLowerCase();
}
