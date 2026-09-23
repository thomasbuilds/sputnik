// Audit helper: a minimal NIP-01 relay on 127.0.0.1 for end-to-end tests that
// go through the app's real RelayConnectionPool. Never binds a public address.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sputnik/nostr/nostr.dart';

class LocalRelay {
  LocalRelay._(this._server);

  final HttpServer _server;
  final events = <NostrEvent>[];
  final published = <NostrEvent>[];
  final reqs = <Map<String, dynamic>>[];

  /// Honor NIP-09 deletion requests (kind 5) like a compliant relay.
  bool honorDeletions = true;

  String get url => 'ws://127.0.0.1:${_server.port}';

  static Future<LocalRelay> start([List<NostrEvent> seed = const []]) async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final relay = LocalRelay._(server)..events.addAll(seed);
    server.listen((request) async {
      final socket = await WebSocketTransformer.upgrade(request);
      socket.listen((raw) => relay._handle(socket, raw as String));
    });
    return relay;
  }

  Future<void> close() => _server.close(force: true);

  void _handle(WebSocket socket, String raw) {
    final msg = jsonDecode(raw) as List<dynamic>;
    switch (msg.first) {
      case 'REQ':
        final sub = msg[1] as String;
        final filters = [
          for (final f in msg.skip(2)) (f as Map).cast<String, dynamic>(),
        ];
        reqs.addAll(filters);
        final sent = <String>{};
        for (final filter in filters) {
          final matching = events.where((e) => _matches(e, filter)).toList()
            ..sort(compareNewestFirst);
          final limit = filter['limit'] as int?;
          for (final e in limit == null ? matching : matching.take(limit)) {
            if (sent.add(e.id)) {
              socket.add(jsonEncode(['EVENT', sub, e.toJson()]));
            }
          }
        }
        socket.add(jsonEncode(['EOSE', sub]));
      case 'EVENT':
        final event = NostrEvent.fromJson(
          (msg[1] as Map).cast<String, dynamic>(),
        );
        published.add(event);
        if (event.kind == 5 && honorDeletions) {
          final ids = {
            for (final t in event.tags)
              if (t.length > 1 && t[0] == 'e') t[1],
          };
          events.removeWhere(
            (e) => ids.contains(e.id) && e.pubkey == event.pubkey,
          );
        }
        final replaceable =
            event.kind == 0 ||
            event.kind == 3 ||
            (event.kind >= 10000 && event.kind < 20000);
        if (replaceable) {
          events.removeWhere(
            (e) => e.pubkey == event.pubkey && e.kind == event.kind,
          );
        }
        events.add(event);
        socket.add(jsonEncode(['OK', event.id, true, '']));
      case 'CLOSE':
        break;
    }
  }

  static bool _matches(NostrEvent e, Map<String, dynamic> f) {
    final ids = (f['ids'] as List?)?.cast<String>();
    if (ids != null && !ids.contains(e.id)) return false;
    final authors = (f['authors'] as List?)?.cast<String>();
    if (authors != null && !authors.contains(e.pubkey)) return false;
    final kinds = (f['kinds'] as List?)?.cast<int>();
    if (kinds != null && !kinds.contains(e.kind)) return false;
    final t = e.createdAt.millisecondsSinceEpoch ~/ 1000;
    if (f['since'] != null && t < (f['since'] as int)) return false;
    if (f['until'] != null && t > (f['until'] as int)) return false;
    for (final entry in f.entries) {
      if (!entry.key.startsWith('#')) continue;
      final name = entry.key.substring(1);
      final values = (entry.value as List).cast<String>();
      final hit = e.tags.any(
        (tag) => tag.length > 1 && tag[0] == name && values.contains(tag[1]),
      );
      if (!hit) return false;
    }
    return true;
  }
}
