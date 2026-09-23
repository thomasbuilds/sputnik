import 'dart:io';

/// Relays selected until the user changes their selection.
const defaultRelays = [
  'wss://relay.damus.io',
  'wss://nos.lol',
  'wss://relay.primal.net',
  'wss://relay.snort.social',
  'wss://relay.ditto.pub',
];

/// Maximum number of user-added relays.
const maxCustomRelays = 20;

/// Hostname label, as relaxed by RFC 1123 to allow a leading digit.
final _hostLabelPattern = RegExp(
  r'^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$',
);

/// Letters only, so a dotted-number string is not mistaken for a domain.
final _tldPattern = RegExp(r'^[a-zA-Z]{2,}$');

/// Rejects single-label hosts such as `localhost`.
bool _isValidDomain(String host) {
  if (host.isEmpty || host.length > 253) return false;

  final labels = host.split('.');
  if (labels.length < 2) return false;
  if (!_tldPattern.hasMatch(labels.last)) return false;
  return labels.every(_hostLabelPattern.hasMatch);
}

bool _isValidHost(String host) =>
    InternetAddress.tryParse(host) != null || _isValidDomain(host);

/// Whether [input] is a ws(s) URL, without userinfo, with a domain or IP host.
bool isRelayUrl(String input) {
  final uri = Uri.tryParse(input);
  if (uri == null || !uri.hasAuthority) return false;
  if (uri.scheme != 'ws' && uri.scheme != 'wss') return false;
  if (uri.userInfo.isNotEmpty) return false;
  return _isValidHost(uri.host);
}

/// Lowercases scheme and host and drops the default port, trailing slashes,
/// an empty query and any fragment, so one relay has one spelling.
String canonicalRelayUrl(String input) {
  final uri = Uri.tryParse(input.trim());
  if (uri == null || !uri.hasAuthority) return input.trim();
  final defaultPort = switch (uri.scheme) {
    'wss' => 443,
    'ws' => 80,
    _ => null,
  };
  var path = uri.path;
  while (path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  return Uri(
    scheme: uri.scheme,
    userInfo: uri.userInfo.isEmpty ? null : uri.userInfo,
    host: uri.host,
    port: uri.hasPort && uri.port != defaultPort ? uri.port : null,
    path: path,
    query: uri.query.isEmpty ? null : uri.query,
  ).toString();
}
