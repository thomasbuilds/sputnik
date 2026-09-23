import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/nostr/nostr.dart';
import 'package:sputnik/nostr/relay_connection_pool.dart';

// A local relay that answers each REQ with whatever [script] builds.
Future<HttpServer> _serve(List<String> Function(String subId) script) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((request) async {
    final socket = await WebSocketTransformer.upgrade(request);
    socket.listen((message) {
      final decoded = jsonDecode(message as String) as List<dynamic>;
      if (decoded.first != 'REQ') return;
      script(decoded[1] as String).forEach(socket.add);
    });
  });
  return server;
}

String _eventMsg(String subId, NostrEvent event) =>
    jsonEncode(['EVENT', subId, event.toJson()]);

String _eose(String subId) => jsonEncode(['EOSE', subId]);

/// Makes every TCP connect hang, then fail after [failAfter], like a host
/// that drops SYNs until the kernel gives up.
final class _SlowToFail extends IOOverrides {
  _SlowToFail(this.failAfter);

  final Duration failAfter;

  @override
  Future<ConnectionTask<Socket>> socketStartConnect(
    dynamic host,
    int port, {
    dynamic sourceAddress,
    int sourcePort = 0,
  }) {
    final socket = Completer<Socket>();
    final timer = Timer(failAfter, () {
      socket.completeError(const SocketException('Connection timed out'));
    });
    return Future.value(
      ConnectionTask.fromSocket(socket.future, () {
        timer.cancel();
        if (!socket.isCompleted) {
          socket.completeError(const SocketException('Cancelled'));
        }
      }),
    );
  }
}

void main() {
  const client = RelayClient(timeout: Duration(seconds: 2));
  final key = generateNostrKeyPair();
  final otherKey = generateNostrKeyPair();

  NostrEvent sign({
    NostrKeyPair? by,
    int kind = 1,
    String content = 'hi',
    DateTime? at,
  }) {
    final signer = by ?? key;
    return signEvent(
      seckeyHex: signer.privateKeyHex,
      pubkeyHex: signer.publicKeyHex,
      kind: kind,
      content: content,
      createdAt: at,
    );
  }

  Future<RelayQueryResult> query(HttpServer server, NostrFilter filter) =>
      client.queryWithStatus({'ws://127.0.0.1:${server.port}'}, filter);

  group('what a relay returns is checked against the filter', () {
    test('drops events of another kind or author', () async {
      final wanted = sign(kind: 0, content: '{}');
      final wrongKind = sign(kind: 3, content: 'x');
      final wrongAuthor = sign(by: otherKey, kind: 0, content: '{}');
      final server = await _serve(
        (sub) => [
          _eventMsg(sub, wrongKind),
          _eventMsg(sub, wrongAuthor),
          _eventMsg(sub, wanted),
          _eose(sub),
        ],
      );
      addTearDown(() => server.close(force: true));

      final result = await query(
        server,
        NostrFilter(kinds: const [0], authors: [key.publicKeyHex]),
      );

      expect(result.events.map((e) => e.id), [wanted.id]);
      expect(result.allRelaysAnswered, isTrue);
    });

    test('drops events outside since and until', () async {
      final now = DateTime.now();
      final old = sign(
        content: 'old',
        at: now.subtract(const Duration(days: 3)),
      );
      final fresh = sign(
        content: 'fresh',
        at: now.subtract(const Duration(hours: 1)),
      );
      final server = await _serve(
        (sub) => [_eventMsg(sub, old), _eventMsg(sub, fresh), _eose(sub)],
      );
      addTearDown(() => server.close(force: true));

      final result = await query(
        server,
        NostrFilter(since: now.subtract(const Duration(days: 1))),
      );

      expect(result.events.map((e) => e.id), [fresh.id]);
    });

    test('keeps only events carrying a requested tag', () async {
      final tagged = signEvent(
        seckeyHex: key.privateKeyHex,
        pubkeyHex: key.publicKeyHex,
        kind: 1,
        tags: [
          ['e', 'a' * 64],
        ],
        content: 'tagged',
      );
      final plain = sign(content: 'plain');
      final server = await _serve(
        (sub) => [_eventMsg(sub, plain), _eventMsg(sub, tagged), _eose(sub)],
      );
      addTearDown(() => server.close(force: true));

      final result = await query(
        server,
        NostrFilter(
          tags: {
            'e': ['a' * 64],
          },
        ),
      );

      expect(result.events.map((e) => e.id), [tagged.id]);
    });

    test('an event repeated by the relay counts once', () async {
      final event = sign();
      final server = await _serve(
        (sub) => [
          for (var i = 0; i < 5; i++) _eventMsg(sub, event),
          _eose(sub),
        ],
      );
      addTearDown(() => server.close(force: true));

      final result = await query(server, const NostrFilter(kinds: [1]));

      expect(result.events, hasLength(1));
    });

    test('events beyond the limit are dropped but EOSE still counts', () async {
      final events = [for (var i = 0; i < 5; i++) sign(content: 'n$i')];
      final server = await _serve(
        (sub) => [for (final e in events) _eventMsg(sub, e), _eose(sub)],
      );
      addTearDown(() => server.close(force: true));

      final result = await query(server, const NostrFilter(limit: 2));

      expect(result.events, hasLength(2));
      expect(result.allRelaysAnswered, isTrue);
    });

    test('a relay overshooting the limit oldest-first still yields the '
        'newest', () async {
      final now = DateTime.now();
      final old = sign(
        kind: 3,
        content: '',
        at: now.subtract(const Duration(days: 30)),
      );
      final fresh = sign(
        kind: 3,
        content: '',
        at: now.subtract(const Duration(minutes: 1)),
      );
      final server = await _serve(
        (sub) => [_eventMsg(sub, old), _eventMsg(sub, fresh), _eose(sub)],
      );
      addTearDown(() => server.close(force: true));

      final result = await query(
        server,
        NostrFilter(kinds: const [3], authors: [key.publicKeyHex], limit: 1),
      );

      expect(result.events.map((e) => e.id), [fresh.id]);
    });

    test('an event for another subscription is ignored', () async {
      final stray = sign(content: 'stray');
      final mine = sign(content: 'mine');
      final server = await _serve(
        (sub) => [
          _eventMsg('someone-elses-sub', stray),
          _eventMsg(sub, mine),
          _eose(sub),
        ],
      );
      addTearDown(() => server.close(force: true));

      final result = await query(server, const NostrFilter(kinds: [1]));

      expect(result.events.map((e) => e.id), [mine.id]);
    });

    test('an event dated far in the future is dropped', () async {
      final future = sign(
        content: 'future',
        at: DateTime.now().add(const Duration(days: 30)),
      );
      final mine = sign(content: 'mine');
      final server = await _serve(
        (sub) => [_eventMsg(sub, future), _eventMsg(sub, mine), _eose(sub)],
      );
      addTearDown(() => server.close(force: true));

      final result = await query(server, const NostrFilter(kinds: [1]));

      expect(result.events.map((e) => e.id), [mine.id]);
    });
  });

  test('a relay that fails to connect only after the timeout', () async {
    final watch = Stopwatch()..start();
    final result = await IOOverrides.runWithIOOverrides(
      () => const RelayClient(timeout: Duration(seconds: 1)).queryWithStatus({
        'ws://unreachable.example',
      }, const NostrFilter(kinds: [1])),
      _SlowToFail(const Duration(seconds: 3)),
    ).timeout(const Duration(seconds: 10));

    expect(result.answeredRelays, 0);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  group('a relay whose answers wait behind others on its connection', () {
    // Frames are parsed one at a time per connection, so a burst of heavy
    // events for one query delays the next query's answer on that relay.
    test('is not given up on before its queued answer is parsed', () async {
      final heavy = sign(content: 'x' * 60000);
      final light = sign(kind: 0, content: '{}');
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        final socket = await WebSocketTransformer.upgrade(request);
        socket.listen((message) {
          final decoded = jsonDecode(message as String) as List<dynamic>;
          if (decoded.first != 'REQ') return;
          final sub = decoded[1] as String;
          final kinds = (decoded[2] as Map<String, dynamic>)['kinds'] as List;
          if (kinds.contains(1)) {
            for (var i = 0; i < 400; i++) {
              socket.add(_eventMsg(sub, heavy));
            }
          } else {
            socket.add(_eventMsg(sub, light));
          }
          socket.add(_eose(sub));
        });
      });
      final relay = {'ws://127.0.0.1:${server.port}'};

      final burst = client.queryWithStatus(
        relay,
        const NostrFilter(kinds: [1]),
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // Answered at once, but only parsed once the burst ahead of it is.
      const impatient = RelayClient(timeout: Duration(milliseconds: 100));
      final answer = await impatient.queryWithStatus(
        relay,
        const NostrFilter(kinds: [0]),
      );
      await burst;

      expect(answer.events.map((e) => e.id), [light.id]);
      expect(answer.allRelaysAnswered, isTrue);
    });
  });

  group('removeIfCurrent', () {
    test('removes the connection it was given', () {
      final connection = Object();
      final connections = {'wss://a.example': connection};

      expect(
        removeIfCurrent(connections, 'wss://a.example', connection),
        isTrue,
      );
      expect(connections, isEmpty);
    });

    test('leaves a newer connection to the same relay alone', () {
      final stale = Object();
      final fresh = Object();
      final connections = {'wss://a.example': fresh};

      expect(removeIfCurrent(connections, 'wss://a.example', stale), isFalse);
      expect(connections['wss://a.example'], same(fresh));
    });

    test('does nothing when the relay has no connection', () {
      final connections = <String, Object>{};

      expect(
        removeIfCurrent(connections, 'wss://a.example', Object()),
        isFalse,
      );
    });
  });

  test('a query joining a connection that never finishes opening gives up '
      'after its own timeout', () async {
    // Accepts TCP but never answers the WebSocket upgrade.
    final hole = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final sockets = <Socket>[];
    hole.listen((socket) {
      sockets.add(socket);
      socket.listen((_) {});
    });
    addTearDown(() async {
      for (final socket in sockets) {
        socket.destroy();
      }
      await hole.close();
    });
    final url = 'ws://127.0.0.1:${hole.port}';

    // The first query opens the connection; the second joins it.
    client.queryWithStatus({url}, const NostrFilter(kinds: [1])).ignore();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final joined = await client
        .queryWithStatus({url}, const NostrFilter(kinds: [0]))
        .timeout(const Duration(seconds: 8));

    expect(joined.answeredRelays, 0);
  });
}
