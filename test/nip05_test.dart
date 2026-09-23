import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sputnik/nostr/nip05.dart';

class _RealHttp extends HttpOverrides {}

/// A real client whose every connection goes to a local plain-HTTP server,
/// whatever host the URL names, and which keeps that routing when the code
/// under test installs its own connection factory.
class _LocalClient implements HttpClient {
  _LocalClient(int port)
    : _inner = HttpOverrides.runWithHttpOverrides(HttpClient.new, _RealHttp()) {
    _inner.connectionFactory = (uri, proxyHost, proxyPort) =>
        Socket.startConnect(InternetAddress.loopbackIPv4, port);
  }

  final HttpClient _inner;

  @override
  set connectionFactory(
    Future<ConnectionTask<Socket>> Function(Uri, String?, int?)? factory,
  ) {}

  @override
  Future<HttpClientRequest> getUrl(Uri url) => _inner.getUrl(url);

  @override
  void close({bool force = false}) => _inner.close(force: force);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final pubkey = 'aa' * 32;

  group('parseNip05', () {
    test('splits local-part and domain on @', () {
      final parsed = parseNip05('Bob@example.com');
      expect(parsed, isNotNull);
      expect(parsed!.local, 'bob');
      expect(parsed.domain, 'example.com');
    });

    test('a bare domain is shorthand for the _@domain root identifier', () {
      final parsed = parseNip05('example.com');
      expect(parsed, isNotNull);
      expect(parsed!.local, '_');
      expect(parsed.domain, 'example.com');
    });

    test('rejects an empty identifier', () {
      expect(parseNip05(''), isNull);
      expect(parseNip05('   '), isNull);
    });

    test('rejects a local-part with disallowed characters', () {
      expect(parseNip05('bo b@example.com'), isNull);
      expect(parseNip05(r'bo$b@example.com'), isNull);
    });

    test('rejects an identifier with no domain', () {
      expect(parseNip05('bob@'), isNull);
    });

    test('rejects a domain that is not a plain host name', () {
      // Uri.https would fetch from evil.example, with good.example as userinfo.
      expect(parseNip05('bob@good.example@evil.example'), isNull);
      expect(parseNip05('bob@good.example:8443'), isNull);
      expect(parseNip05('bob@example.com/x'), isNull);
      expect(parseNip05('bob@localhost'), isNull);
    });
  });

  group('verifyNip05', () {
    test('an unparseable identifier is unreachable, not a crash', () async {
      final status = await verifyNip05(identifier: '', pubkeyHex: pubkey);
      expect(status, Nip05Status.unreachable);
    });

    // Regression test: connectionFactory must actually complete a real
    // TLS handshake, which fakes can't catch.
    test('completes a real TLS handshake and verifies a known identifier', () async {
      final verified = await verifyNip05(
        identifier: 'jb55@damus.io',
        pubkeyHex:
            '32e1827635450ebb3c5a7d12c1f8e7b2b514439ac10a67eef3d9fd9c5c68e245',
      );
      expect(verified, Nip05Status.verified);

      final mismatch = await verifyNip05(
        identifier: 'jb55@damus.io',
        pubkeyHex: pubkey,
      );
      expect(mismatch, Nip05Status.mismatch);
    });
  });

  group('verifyNip05 against a local server', () {
    late HttpServer server;
    final asked = <String>[];
    late void Function(HttpRequest request) answer;

    setUp(() async {
      asked.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) {
        asked.add('${request.headers.host}${request.uri}');
        answer(request);
      });
    });

    tearDown(() => server.close(force: true));

    Future<Nip05Status> verify(String identifier) => HttpOverrides.runZoned(
      () => verifyNip05(identifier: identifier, pubkeyHex: pubkey),
      createHttpClient: (_) => _LocalClient(server.port),
    );

    void names(HttpRequest request, Map<String, String> names) {
      request.response
        ..write(jsonEncode({'names': names}))
        ..close();
    }

    test('asks the domain for the name and compares the pubkey', () async {
      answer = (request) => names(request, {'bob': pubkey});

      expect(await verify('bob@one.example'), Nip05Status.verified);
      expect(asked, ['one.example/.well-known/nostr.json?name=bob']);
    });

    test('a different pubkey is a mismatch', () async {
      answer = (request) => names(request, {'bob': 'bb' * 32});

      expect(await verify('bob@two.example'), Nip05Status.mismatch);
    });

    test('does not follow a redirect', () async {
      answer = (request) {
        if (request.uri.path == '/.well-known/nostr.json') {
          request.response
            ..statusCode = HttpStatus.found
            ..headers.set('location', '/moved.json')
            ..close();
        } else {
          names(request, {'bob': pubkey});
        }
      };

      expect(await verify('bob@three.example'), Nip05Status.unreachable);
      expect(asked, hasLength(1));
    });

    test('a failure is asked again next time', () async {
      var up = false;
      answer = (request) {
        if (up) return names(request, {'bob': pubkey});
        request.response
          ..statusCode = HttpStatus.serviceUnavailable
          ..close();
      };

      expect(await verify('bob@four.example'), Nip05Status.unreachable);
      up = true;
      expect(await verify('bob@four.example'), Nip05Status.verified);
    });
  });
}
