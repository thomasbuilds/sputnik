import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/nostr/nostr.dart';

// A local relay that answers each REQ with whatever [script] builds, and
// each EVENT published to it with [reply].
Future<HttpServer> _serve({
  List<String> Function(String subId)? script,
  void Function(WebSocket socket, String eventId)? reply,
}) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    socket.listen((message) {
      final decoded = jsonDecode(message as String) as List<dynamic>;
      if (decoded.first == 'REQ' && script != null) {
        script(decoded[1] as String).forEach(socket.add);
      } else if (decoded.first == 'EVENT' && reply != null) {
        reply(socket, (decoded[1] as Map<String, dynamic>)['id'] as String);
      }
    });
  });
  return server;
}

String _eventMsg(String subId, NostrEvent event) =>
    jsonEncode(['EVENT', subId, event.toJson()]);

String _eose(String subId) => jsonEncode(['EOSE', subId]);

void main() {
  const client = RelayClient(timeout: Duration(seconds: 2));
  final key = generateNostrKeyPair();

  NostrEvent sign({
    String content = 'hi',
    DateTime? at,
    List<List<String>> tags = const [],
  }) => signEvent(
    seckeyHex: key.privateKeyHex,
    pubkeyHex: key.publicKeyHex,
    kind: 1,
    tags: tags,
    content: content,
    createdAt: at,
  );

  Future<List<String>> idsFrom(
    List<NostrEvent> sent,
    NostrFilter filter,
  ) async {
    final server = await _serve(
      script: (sub) => [for (final e in sent) _eventMsg(sub, e), _eose(sub)],
    );
    addTearDown(() => server.close(force: true));
    final result = await client.queryWithStatus({
      'ws://127.0.0.1:${server.port}',
    }, filter);
    return [for (final e in result.events) e.id];
  }

  group('what a relay returns is checked against the filter', () {
    test('keeps events from since to until inclusive, and no others', () async {
      final since = DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000);
      final until = since.add(const Duration(minutes: 1));
      final first = sign(content: 'first', at: since);
      final last = sign(content: 'last', at: until);
      final sent = [
        sign(content: 'before', at: since.subtract(const Duration(seconds: 1))),
        first,
        last,
        sign(content: 'after', at: until.add(const Duration(seconds: 1))),
      ];

      final ids = await idsFrom(sent, NostrFilter(since: since, until: until));

      expect(ids, unorderedEquals([first.id, last.id]));
    });

    test('a value under another tag name does not match', () async {
      final tagged = sign(
        content: 'tagged',
        tags: [
          ['e', 'a' * 64],
        ],
      );
      final otherTag = sign(
        content: 'same value, other tag',
        tags: [
          ['p', 'a' * 64],
        ],
      );

      final ids = await idsFrom(
        [otherTag, tagged],
        NostrFilter(
          tags: {
            'e': ['a' * 64],
          },
        ),
      );

      expect(ids, [tagged.id]);
    });

    test('drops events whose id was not asked for', () async {
      final wanted = sign(content: 'wanted');
      final substitute = sign(content: 'substitute');

      final ids = await idsFrom([
        substitute,
        wanted,
      ], NostrFilter(ids: [wanted.id]));

      expect(ids, [wanted.id]);
    });

    test('repeats of one event do not use up the limit', () async {
      final repeated = sign(content: 'repeated');
      final next = sign(content: 'next');

      final ids = await idsFrom([
        for (var i = 0; i < 5; i++) repeated,
        next,
      ], const NostrFilter(limit: 2));

      expect(ids, unorderedEquals([repeated.id, next.id]));
    });
  });

  group('what a relay says about a publish', () {
    test('only OK true is accepted, and a refusal keeps its reason', () async {
      final accepting = await _serve(
        reply: (socket, id) => socket.add(jsonEncode(['OK', id, true, ''])),
      );
      final refusing = await _serve(
        reply: (socket, id) =>
            socket.add(jsonEncode(['OK', id, false, 'blocked: spam'])),
      );
      addTearDown(() => accepting.close(force: true));
      addTearDown(() => refusing.close(force: true));
      final acceptingUrl = 'ws://127.0.0.1:${accepting.port}';
      final refusingUrl = 'ws://127.0.0.1:${refusing.port}';

      final results = await client.publish(sign(), {acceptingUrl, refusingUrl});

      expect(results[acceptingUrl]!.outcome, RelayPublishOutcome.accepted);
      expect(results[refusingUrl]!.outcome, RelayPublishOutcome.rejected);
      expect(results[refusingUrl]!.message, 'blocked: spam');
    });

    test('an OK for another event does not settle the publish', () async {
      final server = await _serve(
        reply: (socket, id) =>
            socket.add(jsonEncode(['OK', 'ab' * 32, true, ''])),
      );
      addTearDown(() => server.close(force: true));
      const impatient = RelayClient(timeout: Duration(milliseconds: 500));

      final results = await impatient.publish(sign(), {
        'ws://127.0.0.1:${server.port}',
      });

      expect(results.values.single.outcome, RelayPublishOutcome.noResponse);
    });

    test('a relay that hangs up is reported as a failed connection', () async {
      final server = await _serve(reply: (socket, id) => socket.close());
      addTearDown(() => server.close(force: true));

      final results = await client.publish(sign(), {
        'ws://127.0.0.1:${server.port}',
      });

      expect(
        results.values.single.outcome,
        RelayPublishOutcome.connectionFailed,
      );
    });
  });
}
